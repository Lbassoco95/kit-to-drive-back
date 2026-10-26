-- ============================================================================
-- PAQUETE 2 · 2 de 3: kárdex de VARIOS artículos (y filtro de almacén)
--
-- `kardex_refaccion` sigue igual (un artículo). `kardex_refacciones_multi` agrega: varios artículos a la vez
-- (hasta 50), filtro opcional de almacén, saldo corrido por artículo y saldo inicial por artículo.
-- Misma puerta de acceso que `kardex_refaccion` (compras/inventario o almacén físico); el VENDEDOR NO entra
-- (decisión de Polo: Kardex y Rotación son de inventario). SECURITY DEFINER porque los movimientos del almacén
-- no tienen política de lectura para todos los roles que sí pasan la puerta; la puerta se revisa dentro, el
-- modo prueba se respeta con `exigir_lectura_prueba` por artículo, search_path fijo y sin EXECUTE para anon.
--
-- Saldo inicial: sin filtro de almacén usa `saldo_refaccion_a_fecha` (igual que el kárdex de un artículo);
-- con filtro de almacén suma solo los movimientos de ese almacén (el saldo inicial «sin documento» no tiene almacén
-- y no se atribuye a ninguno). Sin escrituras. Idempotente.
-- Reversa: supabase/reversas/20261108000002_paquete2_kardex_varios_articulos_reversa.sql
-- ============================================================================
CREATE OR REPLACE FUNCTION public.kardex_refacciones_multi(
  _productos uuid[],
  _desde date DEFAULT NULL,
  _hasta date DEFAULT NULL,
  _almacen text DEFAULT NULL
)
RETURNS TABLE (
  producto_id uuid, codigo text, descripcion text,
  fecha date, registrado timestamptz, tipo text, documento_tipo text, folio text, cliente text,
  motivo text, notas text, entrada integer, salida integer, saldo integer, almacen text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
#variable_conflict use_column
DECLARE
  v_desde date := coalesce(_desde, '1900-01-01'::date);
  v_hasta date := coalesce(_hasta, '2999-12-31'::date);
  v_prod uuid;
BEGIN
  IF auth.uid() IS NULL OR (NOT public.puede_leer_compras_inventario(auth.uid())
                            AND NOT public.puede_ver_almacen_refacciones(auth.uid())) THEN
    RAISE EXCEPTION 'Sin acceso al kárdex' USING ERRCODE = '42501';
  END IF;
  IF _productos IS NULL OR cardinality(_productos) = 0 THEN
    RAISE EXCEPTION 'Elige al menos un artículo';
  END IF;
  IF cardinality(_productos) > 50 THEN
    RAISE EXCEPTION 'Máximo 50 artículos por consulta';
  END IF;
  FOREACH v_prod IN ARRAY _productos LOOP
    PERFORM public.exigir_lectura_prueba('almacen_refacciones_productos', v_prod);
  END LOOP;

  RETURN QUERY
  WITH p AS (
    SELECT a.id, a.codigo_nuevo AS cod, coalesce(a.descripcion_corta, a.descripcion) AS des, a.linea_catalogo
      FROM public.almacen_refacciones_productos a WHERE a.id = ANY (_productos)
  ), ini AS (
    SELECT p.id,
           CASE WHEN _almacen IS NULL THEN public.saldo_refaccion_a_fecha(p.id, v_desde - 1)
                ELSE coalesce((SELECT sum(m.cantidad) FROM public.almacen_refacciones_movimientos m
                                WHERE m.producto_id = p.id AND m.almacen = _almacen AND m.fecha_efectiva <= v_desde - 1), 0)::integer
           END AS saldo
      FROM p
  ), filas AS (
    SELECT p.id AS pid, p.cod, p.des, 0 AS orden, v_desde - 1 AS f, NULL::timestamptz AS reg, 'saldo_inicial'::text AS tipo,
           'saldo_inicial'::text AS dtipo, NULL::text AS folio, NULL::text AS cli, NULL::text AS mot,
           ('Saldo al ' || to_char(v_desde - 1, 'DD/MM/YYYY'))::text AS nts,
           NULL::integer AS ent, NULL::integer AS sal, ini.saldo AS sld, coalesce(_almacen, p.linea_catalogo) AS alm, NULL::uuid AS mid
      FROM p JOIN ini ON ini.id = p.id
     WHERE _desde IS NOT NULL OR ini.saldo <> 0
    UNION ALL
    SELECT p.id, p.cod, p.des, 1, m.fecha_efectiva, m.created_at, m.tipo, m.documento_tipo, m.documento_folio,
           coalesce(cl.nombre_comercial, cl.razon_social, cl.codigo_erp), m.motivo_clave, m.notas,
           CASE WHEN m.cantidad > 0 THEN m.cantidad END, CASE WHEN m.cantidad < 0 THEN -m.cantidad END,
           (ini.saldo + sum(m.cantidad) OVER (PARTITION BY m.producto_id ORDER BY m.fecha_efectiva, m.created_at, m.id))::integer,
           m.almacen, m.id
      FROM public.almacen_refacciones_movimientos m
      JOIN p ON p.id = m.producto_id
      JOIN ini ON ini.id = m.producto_id
      LEFT JOIN public.clientes cl ON cl.id = m.cliente_id
     WHERE m.fecha_efectiva BETWEEN v_desde AND v_hasta
       AND (_almacen IS NULL OR m.almacen = _almacen)
  )
  SELECT f.pid, f.cod, f.des, f.f, f.reg, f.tipo, f.dtipo, f.folio, f.cli, f.mot, f.nts, f.ent, f.sal, f.sld, f.alm
    FROM filas f
   ORDER BY f.cod, f.pid, f.orden, f.f, f.reg, f.mid;
END;
$$;

REVOKE ALL ON FUNCTION public.kardex_refacciones_multi(uuid[], date, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.kardex_refacciones_multi(uuid[], date, date, text) TO authenticated, service_role;

COMMENT ON FUNCTION public.kardex_refacciones_multi(uuid[], date, date, text) IS
  'Kárdex de varios artículos (máx. 50) con saldo corrido por artículo y filtro de almacén. Misma puerta que kardex_refaccion; el vendedor no entra.';

-- Verificación: existe, es DEFINER con search_path fijo, authenticated sí y anon no la ejecutan.
SELECT
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'kardex_refacciones_multi' AND p.prosecdef
      AND EXISTS (SELECT 1 FROM unnest(p.proconfig) x WHERE x LIKE 'search_path=%')) AS funcion_definer_con_search_path,
  has_function_privilege('authenticated', 'public.kardex_refacciones_multi(uuid[], date, date, text)', 'EXECUTE') AS authenticated_ejecuta,
  has_function_privilege('anon', 'public.kardex_refacciones_multi(uuid[], date, date, text)', 'EXECUTE') AS anon_ejecuta;

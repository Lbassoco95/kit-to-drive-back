-- ============================================================================
-- PAQUETE 2 · 3 de 3: rotación de refacciones con filtro de artículos y de almacén
--
-- `resumen_rotacion_refacciones` sigue igual. `resumen_rotacion_refacciones_filtrado` devuelve las mismas
-- columnas pero (a) solo los artículos indicados (si se indican) y (b) las ventas del periodo de un almacén
-- (si se indica). La clasificación ABC la calcula el front (`clasificarABC`) sobre el conjunto que recibe: para
-- ver «la del conjunto filtrado» y «la del total» el front llama a las dos funciones.
-- Es una función con otro nombre (no una sobrecarga) a propósito: dos sobrecargas con parámetros opcionales
-- vuelven ambiguas las llamadas por RPC (PostgREST «could not choose the best candidate function»).
-- Misma puerta que la original (compras/inventario); el VENDEDOR NO entra. SECURITY DEFINER con search_path fijo,
-- modo prueba igual que la original, sin EXECUTE para anon. Sin escrituras. Idempotente.
-- Reversa: supabase/reversas/20261108000003_paquete2_rotacion_filtrada_reversa.sql
-- ============================================================================
CREATE OR REPLACE FUNCTION public.resumen_rotacion_refacciones_filtrado(
  _desde date,
  _hasta date,
  _incluir_prueba boolean DEFAULT false,
  _productos uuid[] DEFAULT NULL,
  _almacen text DEFAULT NULL
)
RETURNS TABLE (
  producto_id uuid, codigo text, codigo_antiguo text, descripcion text, linea text, marca text, unidad_venta text,
  piezas_por_unidad_venta integer, piezas_caja_cerrada integer, precio numeric, piezas_vendidas integer,
  monto_vendido numeric, meses_con_venta integer, existencia integer, apartado integer, en_transito integer,
  ultima_compra date, compatibilidades text, es_prueba boolean
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
#variable_conflict use_column
BEGIN
  IF auth.uid() IS NULL OR NOT public.puede_leer_compras_inventario(auth.uid()) THEN
    RAISE EXCEPTION 'Sin acceso a rotación' USING ERRCODE = '42501';
  END IF;
  IF _productos IS NOT NULL AND cardinality(_productos) > 500 THEN
    RAISE EXCEPTION 'Máximo 500 artículos por consulta';
  END IF;
  RETURN QUERY
  SELECT p.id, p.codigo_nuevo, p.codigo_antiguo, coalesce(p.descripcion_corta, p.descripcion), p.linea_catalogo, p.marca,
         p.unidad_venta, p.piezas_por_unidad_venta, p.piezas_caja_cerrada, p.precio,
         coalesce(v.piezas, 0)::integer, coalesce(v.monto, 0)::numeric, coalesce(v.meses, 0)::integer,
         p.stock, public.stock_bloqueado_producto(p.id),
         coalesce((SELECT sum(l.cantidad) FROM public.compra_refaccion_lineas l
                     JOIN public.compras_refacciones c ON c.id = l.compra_id
                    WHERE l.producto_id = p.id AND c.estatus = 'no_confirmada'), 0)::integer,
         (SELECT max(m.fecha_efectiva) FROM public.almacen_refacciones_movimientos m
           WHERE m.producto_id = p.id AND m.documento_tipo IN ('compra', 'inicial')),
         (SELECT string_agg(u.nombre, ', ' ORDER BY u.nombre)
            FROM public.almacen_refacciones_producto_compat pc
            JOIN public.almacen_refacciones_unidades u ON u.id = pc.unidad_id
           WHERE pc.producto_id = p.id),
         p.es_prueba
    FROM public.almacen_refacciones_productos p
    LEFT JOIN LATERAL (
      SELECT sum(-m.cantidad) AS piezas,
             sum(-m.cantidad * coalesce(m.precio_unitario, p.precio, 0)) AS monto,
             count(DISTINCT date_trunc('month', m.fecha_efectiva)) AS meses
        FROM public.almacen_refacciones_movimientos m
       WHERE m.producto_id = p.id AND m.tipo = 'venta'
         AND m.fecha_efectiva BETWEEN _desde AND _hasta
         AND (_almacen IS NULL OR m.almacen = _almacen)
    ) v ON true
   WHERE (coalesce(_incluir_prueba, false) OR NOT p.es_prueba)
     AND (p.es_prueba OR NOT public.es_usuario_prueba(auth.uid()))
     AND (_productos IS NULL OR p.id = ANY (_productos));
END;
$$;

REVOKE ALL ON FUNCTION public.resumen_rotacion_refacciones_filtrado(date, date, boolean, uuid[], text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resumen_rotacion_refacciones_filtrado(date, date, boolean, uuid[], text) TO authenticated, service_role;

COMMENT ON FUNCTION public.resumen_rotacion_refacciones_filtrado(date, date, boolean, uuid[], text) IS
  'Rotación de refacciones con filtro de artículos y de almacén. Misma puerta que resumen_rotacion_refacciones; el vendedor no entra.';

-- Verificación: existe, es DEFINER con search_path fijo, authenticated sí y anon no la ejecutan; la original sigue.
SELECT
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'resumen_rotacion_refacciones_filtrado' AND p.prosecdef
      AND EXISTS (SELECT 1 FROM unnest(p.proconfig) x WHERE x LIKE 'search_path=%')) AS funcion_definer_con_search_path,
  has_function_privilege('authenticated', 'public.resumen_rotacion_refacciones_filtrado(date, date, boolean, uuid[], text)', 'EXECUTE') AS authenticated_ejecuta,
  has_function_privilege('anon', 'public.resumen_rotacion_refacciones_filtrado(date, date, boolean, uuid[], text)', 'EXECUTE') AS anon_ejecuta,
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'resumen_rotacion_refacciones') AS original_sigue;

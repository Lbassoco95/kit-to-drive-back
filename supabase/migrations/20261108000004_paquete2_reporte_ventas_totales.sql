-- ============================================================================
-- PAQUETE 2 · 4 de 4: TOTALES del reporte de ventas, con remisiones DISTINTAS
--
-- Hallazgo del front del Paquete 2: `reporte_ventas_refacciones` devuelve una fila por mes × almacén × vendedor × artículo
-- y en cada fila `remisiones` cuenta las remisiones distintas DE ESA FILA. Una remisión con dos artículos (o dos almacenes) sale
-- en dos filas, así que sumar la columna `remisiones` la cuenta dos veces. Decisión de Polo (26 oct 2026): el back devuelve el
-- total de remisiones distintas.
--
-- `reporte_ventas_refacciones_totales` recibe los MISMOS filtros y devuelve UNA fila con el total de remisiones distintas, las piezas
-- y el monto neto del mismo conjunto (el mismo criterio de venta: partidas no canceladas de remisiones no canceladas, fecha de la
-- remisión, sin prueba salvo que se pida, importe vigente). SECURITY INVOKER: la visibilidad es la de las remisiones de quien llama
-- (el vendedor solo cuenta las suyas). No cambia la función anterior. STABLE, sin escrituras. Idempotente.
-- Reversa: supabase/reversas/20261108000004_paquete2_reporte_ventas_totales_reversa.sql
-- ============================================================================
CREATE OR REPLACE FUNCTION public.reporte_ventas_refacciones_totales(
  _desde date,
  _hasta date,
  _almacenes text[] DEFAULT NULL,
  _vendedores uuid[] DEFAULT NULL,
  _productos uuid[] DEFAULT NULL,
  _incluir_prueba boolean DEFAULT false
)
RETURNS TABLE (remisiones bigint, piezas bigint, monto_neto numeric)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = public AS $$
#variable_conflict use_column
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Sin sesión' USING ERRCODE = '42501';
  END IF;
  IF _desde IS NULL OR _hasta IS NULL OR _hasta < _desde THEN
    RAISE EXCEPTION 'Indica el periodo (desde y hasta, con hasta no menor que desde)';
  END IF;
  RETURN QUERY
  SELECT count(DISTINCT r.id),
         coalesce(sum(i.cantidad_surtida + i.cantidad_bloqueada), 0)::bigint,
         coalesce(sum(public.importe_partida_refaccion(i.precio_unitario, i.cantidad_surtida + i.cantidad_bloqueada,
                                                       i.descuento_pct, r.descuento_pct)), 0)::numeric
    FROM public.remisiones_refacciones r
    JOIN public.remision_refaccion_items i ON i.remision_id = r.id
   WHERE r.etapa <> 'cancelada'
     AND i.estatus <> 'cancelada'
     AND i.cantidad_surtida + i.cantidad_bloqueada > 0
     AND r.fecha_remision BETWEEN _desde AND _hasta
     AND (coalesce(_incluir_prueba, false) OR NOT r.es_prueba)
     AND (_almacenes IS NULL OR i.almacen = ANY (_almacenes))
     AND (_vendedores IS NULL OR r.vendedor_id = ANY (_vendedores))
     AND (_productos IS NULL OR i.producto_id = ANY (_productos));
END;
$$;

REVOKE ALL ON FUNCTION public.reporte_ventas_refacciones_totales(date, date, text[], uuid[], uuid[], boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reporte_ventas_refacciones_totales(date, date, text[], uuid[], uuid[], boolean) TO authenticated, service_role;

COMMENT ON FUNCTION public.reporte_ventas_refacciones_totales(date, date, text[], uuid[], uuid[], boolean) IS
  'Totales del reporte de ventas de refacciones con remisiones DISTINTAS (una fila). SECURITY INVOKER: la visibilidad es la de las remisiones de quien llama.';

-- Verificación: existe, es INVOKER, authenticated sí y anon no la ejecutan; la función de filas sigue.
SELECT
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'reporte_ventas_refacciones_totales' AND NOT p.prosecdef) AS funcion_invoker,
  has_function_privilege('authenticated', 'public.reporte_ventas_refacciones_totales(date, date, text[], uuid[], uuid[], boolean)', 'EXECUTE') AS authenticated_ejecuta,
  has_function_privilege('anon', 'public.reporte_ventas_refacciones_totales(date, date, text[], uuid[], uuid[], boolean)', 'EXECUTE') AS anon_ejecuta,
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'reporte_ventas_refacciones') AS reporte_de_filas_sigue;

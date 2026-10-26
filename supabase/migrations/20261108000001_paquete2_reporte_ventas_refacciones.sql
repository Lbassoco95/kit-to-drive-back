-- ============================================================================
-- PAQUETE 2 (reportes y buscadores, SOLO LECTURA) · 1 de 3: reporte de ventas de refacciones
--
-- Decisiones de Polo (26 oct 2026): «ventas» = refacciones (no motocarros); venta = partida de una remisión
-- de refacciones NO cancelada, fechada por la fecha de la remisión, sin datos de prueba; administrativos y
-- supervisores ven todas las ventas; el vendedor solo las suyas.
--
-- Cómo se garantiza «el vendedor solo ve las suyas»: la función es SECURITY INVOKER. Lee remisiones_refacciones
-- y remision_refaccion_items con los permisos de quien llama, así que la visibilidad la decide la política
-- «leer remisiones refacciones» / `puede_leer_remision_refaccion` (Paquete 1) y el modo prueba. No hay una segunda
-- regla que mantener. Quien no ve ninguna remisión recibe 0 filas.
--
-- Importe: el mismo que usa la cobranza (`importe_partida_refaccion` sobre cantidad_surtida + cantidad_bloqueada,
-- con el descuento de la partida y el general de la remisión), o sea el monto vigente, no el pedido original.
-- Una fila por mes × almacén × vendedor × artículo; el front agrega como necesite.
--
-- Objeto nuevo: 1 función (reporte_ventas_refacciones). STABLE, sin escrituras. Idempotente.
-- Reversa: supabase/reversas/20261108000001_paquete2_reporte_ventas_refacciones_reversa.sql
-- ============================================================================
CREATE OR REPLACE FUNCTION public.reporte_ventas_refacciones(
  _desde date,
  _hasta date,
  _almacenes text[] DEFAULT NULL,
  _vendedores uuid[] DEFAULT NULL,
  _productos uuid[] DEFAULT NULL,
  _incluir_prueba boolean DEFAULT false
)
RETURNS TABLE (
  mes date, almacen text, vendedor_id uuid, nombre_vendedor text,
  producto_id uuid, codigo text, descripcion text,
  remisiones bigint, piezas bigint, monto_neto numeric
)
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
  SELECT date_trunc('month', r.fecha_remision)::date,
         i.almacen, r.vendedor_id, r.nombre_vendedor,
         i.producto_id, i.codigo_nuevo, i.descripcion,
         count(DISTINCT r.id),
         sum(i.cantidad_surtida + i.cantidad_bloqueada)::bigint,
         sum(public.importe_partida_refaccion(i.precio_unitario, i.cantidad_surtida + i.cantidad_bloqueada,
                                              i.descuento_pct, r.descuento_pct))
    FROM public.remisiones_refacciones r
    JOIN public.remision_refaccion_items i ON i.remision_id = r.id
   WHERE r.etapa <> 'cancelada'
     AND i.estatus <> 'cancelada'
     AND r.fecha_remision BETWEEN _desde AND _hasta
     AND (coalesce(_incluir_prueba, false) OR NOT r.es_prueba)
     AND (_almacenes IS NULL OR i.almacen = ANY (_almacenes))
     AND (_vendedores IS NULL OR r.vendedor_id = ANY (_vendedores))
     AND (_productos IS NULL OR i.producto_id = ANY (_productos))
   GROUP BY 1, 2, 3, 4, 5, 6, 7
  HAVING sum(i.cantidad_surtida + i.cantidad_bloqueada) > 0
   ORDER BY 1, 2, 4, 6;
END;
$$;

REVOKE ALL ON FUNCTION public.reporte_ventas_refacciones(date, date, text[], uuid[], uuid[], boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reporte_ventas_refacciones(date, date, text[], uuid[], uuid[], boolean) TO authenticated, service_role;

COMMENT ON FUNCTION public.reporte_ventas_refacciones(date, date, text[], uuid[], uuid[], boolean) IS
  'Ventas de refacciones por mes, almacén, vendedor y artículo (SECURITY INVOKER: la visibilidad es la de las remisiones de quien llama). Sin canceladas; sin prueba salvo que se pida.';

-- Verificación: existe, es INVOKER (no DEFINER), authenticated sí y anon no la ejecutan.
SELECT
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'reporte_ventas_refacciones' AND NOT p.prosecdef) AS funcion_invoker,
  has_function_privilege('authenticated', 'public.reporte_ventas_refacciones(date, date, text[], uuid[], uuid[], boolean)', 'EXECUTE') AS authenticated_ejecuta,
  has_function_privilege('anon', 'public.reporte_ventas_refacciones(date, date, text[], uuid[], uuid[], boolean)', 'EXECUTE') AS anon_ejecuta;

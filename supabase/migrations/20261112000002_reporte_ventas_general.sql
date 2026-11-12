-- ============================================================================
-- Reporte de ventas general (formato de Peter): por mes y por COBRO
-- ============================================================================
-- 1. config_general: tipo de cambio de presentación (cuántos CNY / USD vale 1 MXN).
--    Hoy se captura a mano (0.38 y 0.05, los del Excel de Peter). Queda en un solo
--    lugar para que una sincronización con Banxico —como la de Kawiil Central—
--    pueda escribirlo sin tocar el reporte.
-- 2. reporte_ventas_general(_anio, _incluir_prueba): 12 filas (una por mes) con
--      · Línea dorada / Línea azul / Refacciones de motocarro: lo COBRADO en el mes
--        (aplicaciones de Cobranza vigentes), repartido entre las líneas en
--        proporción al importe de cada partida de la remisión.
--      · Motocarros: monto_cobrado de las remisiones pagadas con fecha_cobro en el
--        mes y sus unidades.
--      · motocarros_sin_monto: remisiones de motocarro pagadas del año sin monto
--        capturado (para completarlas; no suman pesos).
--    Sólo lectura. Mismo acceso que reporte_ventas_refacciones + administración global.
--
-- Sólo AGREGA columnas con valor por omisión y una función. Idempotente, para el
-- SQL editor de Supabase. NO usar `supabase db push`.
-- Requiere 20261112000001 (remisiones.monto_cobrado / fecha_cobro).
--
-- Para revertir:
--   DROP FUNCTION IF EXISTS public.reporte_ventas_general(integer, boolean);
--   ALTER TABLE public.config_general DROP COLUMN IF EXISTS tc_cny_por_mxn,
--     DROP COLUMN IF EXISTS tc_usd_por_mxn, DROP COLUMN IF EXISTS tc_fuente, DROP COLUMN IF EXISTS tc_actualizado_at;
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := '{}';
BEGIN
  IF to_regclass('public.config_general') IS NULL THEN _faltan := _faltan || 'tabla config_general'::text; END IF;
  IF to_regclass('public.cobranza_aplicaciones') IS NULL THEN _faltan := _faltan || 'tabla cobranza_aplicaciones'::text; END IF;
  IF to_regclass('public.cobranza_pagos') IS NULL THEN _faltan := _faltan || 'tabla cobranza_pagos'::text; END IF;
  IF to_regclass('public.remisiones_refacciones') IS NULL THEN _faltan := _faltan || 'tabla remisiones_refacciones'::text; END IF;
  IF to_regclass('public.remision_refaccion_items') IS NULL THEN _faltan := _faltan || 'tabla remision_refaccion_items'::text; END IF;
  IF to_regprocedure('public.importe_partida_refaccion(numeric,integer,numeric,numeric)') IS NULL THEN _faltan := _faltan || 'función importe_partida_refaccion'::text; END IF;
  IF to_regprocedure('public.puede_leer_compras_inventario(uuid)') IS NULL THEN _faltan := _faltan || 'función puede_leer_compras_inventario'::text; END IF;
  IF to_regprocedure('public.rol_comercial(uuid)') IS NULL THEN _faltan := _faltan || 'función rol_comercial'::text; END IF;
  IF to_regprocedure('public.es_admin_global(uuid)') IS NULL THEN _faltan := _faltan || 'función es_admin_global'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema='public' AND table_name='remisiones' AND column_name='monto_cobrado') THEN
    _faltan := _faltan || 'columna remisiones.monto_cobrado (corre antes 20261112000001)'::text;
  END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ', ');
  END IF;
END $preflight$;

-- ── 1. Tipo de cambio de presentación ───────────────────────────────────────
ALTER TABLE public.config_general
  ADD COLUMN IF NOT EXISTS tc_cny_por_mxn numeric(10, 4) NOT NULL DEFAULT 0.38,
  ADD COLUMN IF NOT EXISTS tc_usd_por_mxn numeric(10, 4) NOT NULL DEFAULT 0.05,
  ADD COLUMN IF NOT EXISTS tc_fuente text NOT NULL DEFAULT 'manual',
  ADD COLUMN IF NOT EXISTS tc_actualizado_at timestamptz;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'config_general_tc_positivo') THEN
    ALTER TABLE public.config_general
      ADD CONSTRAINT config_general_tc_positivo CHECK (tc_cny_por_mxn > 0 AND tc_usd_por_mxn > 0);
  END IF;
END $$;

-- ── 2. Reporte general por mes (por cobro) ──────────────────────────────────
DROP FUNCTION IF EXISTS public.reporte_ventas_general(integer, boolean);
CREATE OR REPLACE FUNCTION public.reporte_ventas_general(_anio integer, _incluir_prueba boolean DEFAULT false)
RETURNS TABLE(
  mes integer,
  linea_dorada numeric,
  linea_azul numeric,
  ref_motocarro numeric,
  motocarros_monto numeric,
  motocarros_unidades integer,
  motocarros_sin_monto integer
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
#variable_conflict use_column
BEGIN
  IF NOT (public.puede_leer_compras_inventario(auth.uid())
          OR public.rol_comercial(auth.uid()) IN ('global', 'supervisor')
          OR public.es_admin_global(auth.uid())) THEN
    RAISE EXCEPTION 'Sin acceso al reporte de ventas';
  END IF;
  IF _anio IS NULL OR _anio < 2000 OR _anio > 2100 THEN
    RAISE EXCEPTION 'Indica un año válido';
  END IF;

  RETURN QUERY
  WITH partidas AS (
    SELECT r.id AS rid,
           coalesce(i.almacen, p.linea_catalogo) AS linea,
           public.importe_partida_refaccion(i.precio_unitario, i.cantidad_surtida + i.cantidad_bloqueada, i.descuento_pct, r.descuento_pct) AS importe
      FROM public.remisiones_refacciones r
      JOIN public.remision_refaccion_items i ON i.remision_id = r.id
      LEFT JOIN public.almacen_refacciones_productos p ON p.id = i.producto_id
     WHERE r.etapa <> 'cancelada'
       AND (i.cantidad_surtida + i.cantidad_bloqueada) > 0
       AND (coalesce(_incluir_prueba, false) OR NOT r.es_prueba)
  ), totales AS (
    SELECT rid, sum(importe) AS total FROM partidas GROUP BY rid
  ), cobros AS (
    SELECT a.remision_id AS rid, a.monto,
           CASE a.tipo WHEN 'pago' THEN cp.fecha ELSE a.created_at::date END AS fecha
      FROM public.cobranza_aplicaciones a
      LEFT JOIN public.cobranza_pagos cp ON cp.id = a.pago_id
     WHERE a.revertida_at IS NULL
       AND (a.tipo <> 'pago' OR cp.estatus <> 'revertido')
       AND (coalesce(_incluir_prueba, false) OR NOT a.es_prueba)
  ), refacc AS (
    SELECT extract(month FROM c.fecha)::integer AS m, pa.linea,
           sum(c.monto * pa.importe / nullif(t.total, 0)) AS cobrado
      FROM cobros c
      JOIN totales t ON t.rid = c.rid
      JOIN partidas pa ON pa.rid = c.rid
     WHERE extract(year FROM c.fecha) = _anio
     GROUP BY 1, 2
  ), moto AS (
    SELECT extract(month FROM r.fecha_cobro)::integer AS m,
           sum(coalesce(r.monto_cobrado, 0)) AS monto,
           sum((SELECT coalesce(sum(ri.cantidad), 0) FROM public.remision_items ri
                 WHERE ri.remision_id = r.id AND ri.tipo_servicio = 'motocarro'))::integer AS unidades
      FROM public.remisiones r
     WHERE r.pagado AND r.estatus::text <> 'CANCELADA'
       AND r.fecha_cobro IS NOT NULL AND extract(year FROM r.fecha_cobro) = _anio
     GROUP BY 1
  ), sin_monto AS (
    SELECT count(*)::integer AS n
      FROM public.remisiones r
     WHERE r.pagado AND r.estatus::text <> 'CANCELADA' AND r.monto_cobrado IS NULL
       AND extract(year FROM coalesce(r.fecha_cobro, r.fecha_remision)) = _anio
       AND EXISTS (SELECT 1 FROM public.remision_items ri WHERE ri.remision_id = r.id AND ri.tipo_servicio = 'motocarro')
  )
  SELECT g.m,
         round(coalesce((SELECT sum(x.cobrado) FROM refacc x WHERE x.m = g.m AND x.linea = 'linea_dorada'), 0), 2),
         round(coalesce((SELECT sum(x.cobrado) FROM refacc x WHERE x.m = g.m AND x.linea = 'linea_azul'), 0), 2),
         round(coalesce((SELECT sum(x.cobrado) FROM refacc x WHERE x.m = g.m AND x.linea NOT IN ('linea_dorada', 'linea_azul')), 0), 2),
         round(coalesce((SELECT mo.monto FROM moto mo WHERE mo.m = g.m), 0), 2),
         coalesce((SELECT mo.unidades FROM moto mo WHERE mo.m = g.m), 0),
         CASE WHEN g.m = 1 THEN (SELECT n FROM sin_monto) ELSE 0 END
    FROM generate_series(1, 12) AS g(m)
   ORDER BY g.m;
END;
$$;
REVOKE ALL ON FUNCTION public.reporte_ventas_general(integer, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reporte_ventas_general(integer, boolean) TO authenticated;

DO $postflight$
BEGIN
  IF to_regprocedure('public.reporte_ventas_general(integer,boolean)') IS NULL THEN
    RAISE EXCEPTION 'reporte_ventas_general no se creó.';
  END IF;
  IF has_function_privilege('anon', 'public.reporte_ventas_general(integer,boolean)', 'execute') THEN
    RAISE EXCEPTION 'reporte_ventas_general no debe estar abierta a anon.';
  END IF;
END $postflight$;

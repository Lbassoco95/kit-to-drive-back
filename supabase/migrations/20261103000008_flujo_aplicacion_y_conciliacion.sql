-- ============================================================================
-- El flujo muestra lo aplicado en Cobranza y Crédito, y se concilia solo
-- (2026-11-03)
--
-- Un solo punto: el efectivo nace en el Flujo de dinero y Cobranza / Crédito /
-- Control Financiero se actualizan desde ahí por un solo proceso (20261103000002
-- a 000006). Esta migración agrega lo que faltaba para verlo todo conectado:
--
--  1. v_flujo_dinero agrega `aplicacion` (jsonb) con lo aplicado de ese pago o
--     abono: monto aplicado, saldo a favor generado y a qué remisiones o cuenta por
--     cobrar se aplicó. Se calcula al leer, así que siempre está al día (pagos
--     parciales, créditos, reversiones). Lo arma flujo_resumen_aplicacion, con
--     permisos propios, porque quien lleva el flujo no necesariamente lee Cobranza.
--  2. flujo_conciliacion(): solo para administradores del flujo. Lista lo que NO
--     está conectado: pagos de Cobranza o abonos de Crédito sin renglón en el flujo
--     (los anteriores al espejo), renglones en caja sin movimiento, movimientos de
--     Control Financiero que no vienen del flujo y renglones desfasados. Solo lee.
--
-- Idempotente. Para el SQL editor de Supabase; NO usar `supabase db push`.
-- Para revertir: DROP FUNCTION flujo_conciliacion(); y recrear v_flujo_dinero sin `aplicacion`.
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := '{}';
BEGIN
  IF to_regclass('public.flujo_dinero') IS NULL THEN _faltan := _faltan || 'tabla flujo_dinero'::text; END IF;
  IF to_regclass('public.cobranza_aplicaciones') IS NULL THEN _faltan := _faltan || 'tabla cobranza_aplicaciones'::text; END IF;
  IF to_regclass('public.cxc_abonos') IS NULL THEN _faltan := _faltan || 'tabla cxc_abonos'::text; END IF;
  IF to_regprocedure('public.flujo_es_admin(uuid)') IS NULL THEN _faltan := _faltan || 'función flujo_es_admin'::text; END IF;
  IF to_regprocedure('public.flujo_cap(text,uuid)') IS NULL THEN _faltan := _faltan || 'función flujo_cap'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='flujo_dinero' AND column_name='comprobacion_notas') THEN
    _faltan := _faltan || 'columna flujo_dinero.comprobacion_notas (20261103000005)'::text;
  END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ', ');
  END IF;
END;
$preflight$;

-- ── 1. Lo aplicado de un pago de Cobranza o de un abono de Crédito ──────────
CREATE OR REPLACE FUNCTION public.flujo_resumen_aplicacion(_pago uuid, _abono uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_aplicado numeric;
  v_saldo numeric;
  v_rem jsonb;
BEGIN
  IF _pago IS NULL AND _abono IS NULL THEN RETURN NULL; END IF;
  IF NOT (public.flujo_es_admin() OR public.flujo_cap('recibe') OR public.flujo_cap('caja') OR public.flujo_cap('aplica')) THEN
    RETURN NULL;
  END IF;

  IF _pago IS NOT NULL THEN
    SELECT coalesce(sum(a.monto), 0) INTO v_aplicado
      FROM public.cobranza_aplicaciones a WHERE a.pago_id = _pago AND a.revertida_at IS NULL;
    SELECT coalesce(sum(s.monto), 0) INTO v_saldo
      FROM public.cobranza_saldos_favor s WHERE s.pago_origen_id = _pago AND s.cancelado_at IS NULL;
    SELECT coalesce(jsonb_agg(jsonb_build_object('folio', x.folio, 'monto', x.monto) ORDER BY x.folio), '[]'::jsonb) INTO v_rem
      FROM (SELECT r.folio, sum(a.monto) AS monto
              FROM public.cobranza_aplicaciones a JOIN public.remisiones_refacciones r ON r.id = a.remision_id
             WHERE a.pago_id = _pago AND a.revertida_at IS NULL GROUP BY r.folio) x;
    RETURN jsonb_build_object('aplicado', v_aplicado, 'saldo_favor', v_saldo, 'destinos', v_rem);
  END IF;

  -- Abono de Crédito: ya está aplicado a su cuenta por cobrar.
  SELECT jsonb_build_object('aplicado', b.monto, 'saldo_favor', 0,
           'destinos', jsonb_build_array(jsonb_build_object('folio', coalesce(c.folio, 'CxC'), 'monto', b.monto)))
    INTO v_rem
    FROM public.cxc_abonos b LEFT JOIN public.cuentas_por_cobrar c ON c.id = b.cxc_id WHERE b.id = _abono;
  RETURN v_rem;
END;
$$;
REVOKE ALL ON FUNCTION public.flujo_resumen_aplicacion(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_resumen_aplicacion(uuid, uuid) TO authenticated;

-- La vista fija sus columnas: se recrea (mismo orden) y `aplicacion` va al final.
CREATE OR REPLACE VIEW public.v_flujo_dinero
WITH (security_invoker = true) AS
SELECT f.id, f.folio, f.tipo, f.etapa, f.monto, f.moneda, f.tipo_cambio, f.metodo_pago, f.fecha,
       f.contraparte_nombre, f.cliente_id, f.concepto, f.referencia, f.es_prueba,
       f.recibido_por, f.recibido_at, f.cuenta_id, f.caja_por, f.caja_at, f.caja_notas, f.movimiento_id,
       f.destino, f.aplicado_por, f.aplicado_at, f.aplicado_notas, f.cobranza_pago_id,
       f.rechazado_por, f.rechazado_at, f.motivo_rechazo, f.created_at,
       public.flujo_nombre(f.recibido_por) AS recibido_por_nombre,
       public.flujo_nombre(f.caja_por)     AS caja_por_nombre,
       public.flujo_nombre(f.aplicado_por) AS aplicado_por_nombre,
       f.cxc_abono_id,
       f.requiere_comprobacion, f.intermediario_nombre, f.comprobado, f.monto_comprobado, f.monto_devuelto,
       f.comprobado_por, f.comprobado_at, f.comprobacion_notas,
       public.flujo_nombre(f.comprobado_por) AS comprobado_por_nombre,
       public.flujo_resumen_aplicacion(f.cobranza_pago_id, f.cxc_abono_id) AS aplicacion
  FROM public.flujo_dinero f;
GRANT SELECT ON public.v_flujo_dinero TO authenticated;

-- ── 2. Conciliación: qué NO está conectado al flujo ─────────────────────────
CREATE OR REPLACE FUNCTION public.flujo_conciliacion()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_items jsonb;
BEGIN
  IF NOT public.flujo_es_admin() THEN
    RAISE EXCEPTION 'Solo un administrador del flujo consulta la conciliación';
  END IF;

  WITH problemas AS (
    -- Pagos de Cobranza (reales, que no nacieron del flujo) sin renglón en el flujo.
    SELECT 'pago_cobranza_sin_flujo'::text AS tipo, p.folio, p.monto, p.estatus || ' · ' || p.fecha::text AS detalle
      FROM public.cobranza_pagos p
     WHERE NOT p.es_prueba AND coalesce(p.notas, '') NOT LIKE 'Flujo de dinero %'
       AND NOT EXISTS (SELECT 1 FROM public.flujo_dinero f WHERE f.cobranza_pago_id = p.id)
    UNION ALL
    -- Abonos de Crédito (MXN, clientes reales) sin renglón en el flujo.
    SELECT 'abono_credito_sin_flujo', coalesce(c.folio, 'CxC'), b.monto, b.fecha_abono::text
      FROM public.cxc_abonos b
      JOIN public.cuentas_por_cobrar c ON c.id = b.cxc_id
      JOIN public.clientes cl ON cl.id = c.cliente_id
     WHERE coalesce(c.moneda, 'MXN') = 'MXN' AND NOT cl.es_prueba
       AND NOT EXISTS (SELECT 1 FROM public.flujo_dinero f WHERE f.cxc_abono_id = b.id)
    UNION ALL
    -- Dinero ya en caja o aplicado sin su movimiento en Control Financiero.
    SELECT 'flujo_sin_movimiento', f.folio, f.monto, f.etapa || ' · ' || f.tipo
      FROM public.flujo_dinero f
     WHERE NOT f.es_prueba AND f.etapa IN ('EN_CAJA', 'APLICADO') AND f.movimiento_id IS NULL
    UNION ALL
    -- Movimientos de Control Financiero que no vienen del flujo (anteriores al candado).
    SELECT 'movimiento_sin_flujo', m.folio, m.monto, m.estatus::text || ' · ' || m.concepto
      FROM public.movimientos_financieros m
     WHERE NOT EXISTS (SELECT 1 FROM public.flujo_dinero f WHERE f.movimiento_id = m.id)
    UNION ALL
    -- Renglones espejo desfasados de su pago de Cobranza.
    SELECT 'etapa_desfasada', f.folio, f.monto, 'flujo ' || f.etapa || ' · cobranza ' || p.estatus
      FROM public.flujo_dinero f JOIN public.cobranza_pagos p ON p.id = f.cobranza_pago_id
     WHERE coalesce(p.notas, '') NOT LIKE 'Flujo de dinero %'
       AND ((p.estatus = 'revertido' AND f.etapa <> 'RECHAZADO')
         OR (p.estatus = 'registrado' AND f.etapa <> 'RECIBIDO')
         OR (p.estatus = 'validado' AND f.etapa NOT IN ('EN_CAJA', 'APLICADO')))
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object('tipo', tipo, 'folio', folio, 'monto', monto, 'detalle', detalle) ORDER BY tipo, folio), '[]'::jsonb)
    INTO v_items FROM problemas;

  RETURN jsonb_build_object(
    'total', jsonb_array_length(v_items),
    'problemas', v_items
  );
END;
$$;
REVOKE ALL ON FUNCTION public.flujo_conciliacion() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_conciliacion() TO authenticated;

DO $postflight$
BEGIN
  IF has_function_privilege('anon', 'public.flujo_conciliacion()', 'execute')
     OR has_function_privilege('anon', 'public.flujo_resumen_aplicacion(uuid,uuid)', 'execute') THEN
    RAISE EXCEPTION 'Las funciones del flujo no deben estar abiertas a anon.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'v_flujo_dinero' AND column_name = 'aplicacion') THEN
    RAISE EXCEPTION 'v_flujo_dinero no quedó con la columna aplicacion.';
  END IF;
END $postflight$;

-- ── Verificación (solo lectura) ─────────────────────────────────────────────
-- SELECT public.flujo_conciliacion();   -- como administrador del flujo
-- SELECT folio, aplicacion FROM v_flujo_dinero WHERE aplicacion IS NOT NULL;

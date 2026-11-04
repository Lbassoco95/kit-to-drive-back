-- ============================================================================
-- Limpieza puntual de los datos de demostración de Cobranza y Crédito
-- (2026-11-03)
--
-- Decisión de Polo/Martín: quitar lo que el equipo cargó como prueba para dejar
-- los datos de origen correctos. Alcance CONFIRMADO (nada más se toca):
--
--  · Pagos de Cobranza CP-00001, CP-00002 y CP-00003 (cliente E073 «M MOTORS»),
--    con sus aplicaciones, y los saldos a favor SF-00001 a SF-00006.
--  · El abono de $9,602 de CxC-000002 (la cuenta por cobrar se queda y su saldo
--    regresa a lo que era antes del abono: $19,602, ABIERTA).
--  · Sus renglones del flujo (FD-000010 y FD-000011), los avisos de esos pagos y los
--    eventos «pago aplicado / revertido» de las remisiones.
--  · Los ingresos ING-000007, ING-000008 e ING-000009 capturados HOY en Control
--    Financiero por el equipo (Martín Arcuschin), con sus renglones del flujo
--    (FD-000012 a FD-000014). Se borran porque son del equipo; lo que ya estaba
--    en producción (ING-000006 y demás) no se toca.
--
-- NO se toca: remisiones, inventario, CxC-000001, ING-000006, FD-000009 ni lo ya
-- marcado como prueba (FD-000001 a FD-000008, P-RF-*, artículos de prueba).
--
-- Respaldo: antes de borrar, cada registro se guarda completo (JSON) en
-- bitacora_eliminaciones con el motivo «Limpieza de datos de demostración
-- 2026-11-03»; con eso se puede reconstruir cualquiera.
--
-- Cobranza no permite borrar (triggers de inmutabilidad): la función los apaga SOLO
-- sobre las tablas afectadas, dentro de esta misma transacción, y los vuelve a
-- encender; si algo falla, todo se revierte. La función queda sin permisos para la
-- app (solo el SQL editor la puede correr).
--
-- Idempotente: si los registros ya no están, no hace nada. Para el SQL editor de
-- Supabase; NO usar `supabase db push`.
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := '{}';
BEGIN
  IF to_regclass('public.bitacora_eliminaciones') IS NULL THEN _faltan := _faltan || 'tabla bitacora_eliminaciones'::text; END IF;
  IF to_regclass('public.cobranza_pagos') IS NULL THEN _faltan := _faltan || 'tabla cobranza_pagos'::text; END IF;
  IF to_regclass('public.cxc_abonos') IS NULL THEN _faltan := _faltan || 'tabla cxc_abonos'::text; END IF;
  IF to_regprocedure('public.flujo_conciliacion()') IS NULL THEN _faltan := _faltan || 'función flujo_conciliacion (20261103000008)'::text; END IF;
  IF to_regprocedure('public._conectar_movimiento_al_flujo(uuid)') IS NULL THEN _faltan := _faltan || 'función _conectar_movimiento_al_flujo (20261103000009)'::text; END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ', ');
  END IF;
END;
$preflight$;

CREATE OR REPLACE FUNCTION public._limpiar_demostracion_cobranza_credito(
  _pagos text[], _saldos text[], _cxc_folio text, _movimientos text[], _motivo text
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_pagos uuid[];
  v_saldos uuid[];
  v_movs uuid[];
  v_apl uuid[];
  v_flujos uuid[];
  v_abonos uuid[];
  v_cxc uuid;
  v_rems uuid[];
  v_restaurar numeric := 0;
  v_folios text[];
  v_n jsonb := '{}'::jsonb;
  c integer;
BEGIN
  SELECT coalesce(array_agg(id), '{}') INTO v_pagos FROM public.cobranza_pagos WHERE folio = ANY (_pagos);
  SELECT coalesce(array_agg(id), '{}') INTO v_saldos FROM public.cobranza_saldos_favor WHERE folio = ANY (_saldos);
  SELECT coalesce(array_agg(id), '{}') INTO v_movs FROM public.movimientos_financieros WHERE folio = ANY (_movimientos);
  SELECT id INTO v_cxc FROM public.cuentas_por_cobrar WHERE folio = _cxc_folio;
  SELECT coalesce(array_agg(id), '{}') INTO v_abonos FROM public.cxc_abonos WHERE cxc_id = v_cxc;
  SELECT coalesce(array_agg(id), '{}') INTO v_apl FROM public.cobranza_aplicaciones
   WHERE pago_id = ANY (v_pagos) OR saldo_favor_id = ANY (v_saldos);
  SELECT coalesce(array_agg(id), '{}') INTO v_flujos FROM public.flujo_dinero
   WHERE cobranza_pago_id = ANY (v_pagos) OR movimiento_id = ANY (v_movs);
  SELECT coalesce(array_agg(DISTINCT remision_id), '{}') INTO v_rems FROM public.cobranza_aplicaciones WHERE id = ANY (v_apl);
  SELECT coalesce(array_agg(folio), '{}') INTO v_folios FROM (
    SELECT folio FROM public.cobranza_pagos WHERE id = ANY (v_pagos)
    UNION ALL SELECT folio FROM public.cobranza_saldos_favor WHERE id = ANY (v_saldos)) x;

  -- 1. Respaldo completo antes de borrar.
  INSERT INTO public.bitacora_eliminaciones (tabla, registro_id, eliminado_por, nombre_usuario, motivo, datos_eliminados)
  SELECT 'flujo_dinero', id, NULL::uuid, 'Limpieza de datos de demostración', _motivo, to_jsonb(t) FROM public.flujo_dinero t WHERE id = ANY (v_flujos)
  UNION ALL SELECT 'cobranza_aplicaciones', id, NULL, 'Limpieza de datos de demostración', _motivo, to_jsonb(t) FROM public.cobranza_aplicaciones t WHERE id = ANY (v_apl)
  UNION ALL SELECT 'cobranza_saldos_favor', id, NULL, 'Limpieza de datos de demostración', _motivo, to_jsonb(t) FROM public.cobranza_saldos_favor t WHERE id = ANY (v_saldos)
  UNION ALL SELECT 'cobranza_pagos', id, NULL, 'Limpieza de datos de demostración', _motivo, to_jsonb(t) FROM public.cobranza_pagos t WHERE id = ANY (v_pagos)
  UNION ALL SELECT 'cxc_abonos', id, NULL, 'Limpieza de datos de demostración', _motivo,
         to_jsonb(t) || jsonb_build_object('cxc_antes', (SELECT to_jsonb(x) FROM public.cuentas_por_cobrar x WHERE x.id = t.cxc_id))
         FROM public.cxc_abonos t WHERE id = ANY (v_abonos)
  UNION ALL SELECT 'movimientos_financieros', id, NULL, 'Limpieza de datos de demostración', _motivo, to_jsonb(t) FROM public.movimientos_financieros t WHERE id = ANY (v_movs);

  -- 2. Cobranza no se borra: se apagan SOLO sus triggers de inmutabilidad y el espejo, dentro de esta transacción.
  ALTER TABLE public.cobranza_aplicaciones DISABLE TRIGGER trg_cobranza_aplicaciones_inmutable;
  ALTER TABLE public.cobranza_aplicaciones DISABLE TRIGGER trg_espejo_flujo_aplic;
  ALTER TABLE public.cobranza_pagos DISABLE TRIGGER trg_cobranza_pagos_inmutable;
  ALTER TABLE public.cobranza_pagos DISABLE TRIGGER trg_espejo_flujo_pago;
  ALTER TABLE public.cobranza_saldos_favor DISABLE TRIGGER trg_cobranza_saldos_favor_inmutable;
  ALTER TABLE public.cobranza_saldos_favor DISABLE TRIGGER trg_espejo_flujo_saldo;
  ALTER TABLE public.flujo_dinero DISABLE TRIGGER trg_flujo_dinero_sin_borrar;

  -- 3. Borrar en orden de dependencias.
  DELETE FROM public.avisos WHERE (datos ? 'pago_id') AND (datos->>'pago_id')::uuid = ANY (v_pagos);
  GET DIAGNOSTICS c = ROW_COUNT; v_n := v_n || jsonb_build_object('avisos', c);
  DELETE FROM public.remision_refaccion_eventos e
   WHERE e.accion IN ('pago_aplicado', 'pago_revertido') AND e.remision_id = ANY (v_rems)
     AND EXISTS (SELECT 1 FROM unnest(v_folios) f WHERE e.detalle LIKE '%' || f || '%');
  GET DIAGNOSTICS c = ROW_COUNT; v_n := v_n || jsonb_build_object('eventos', c);
  DELETE FROM public.flujo_dinero WHERE id = ANY (v_flujos);
  GET DIAGNOSTICS c = ROW_COUNT; v_n := v_n || jsonb_build_object('flujo', c);
  DELETE FROM public.cobranza_aplicaciones WHERE id = ANY (v_apl);
  GET DIAGNOSTICS c = ROW_COUNT; v_n := v_n || jsonb_build_object('aplicaciones', c);
  DELETE FROM public.cobranza_saldos_favor WHERE id = ANY (v_saldos);
  GET DIAGNOSTICS c = ROW_COUNT; v_n := v_n || jsonb_build_object('saldos_favor', c);
  DELETE FROM public.cobranza_pagos WHERE id = ANY (v_pagos);
  GET DIAGNOSTICS c = ROW_COUNT; v_n := v_n || jsonb_build_object('pagos', c);

  ALTER TABLE public.cobranza_aplicaciones ENABLE TRIGGER trg_cobranza_aplicaciones_inmutable;
  ALTER TABLE public.cobranza_aplicaciones ENABLE TRIGGER trg_espejo_flujo_aplic;
  ALTER TABLE public.cobranza_pagos ENABLE TRIGGER trg_cobranza_pagos_inmutable;
  ALTER TABLE public.cobranza_pagos ENABLE TRIGGER trg_espejo_flujo_pago;
  ALTER TABLE public.cobranza_saldos_favor ENABLE TRIGGER trg_cobranza_saldos_favor_inmutable;
  ALTER TABLE public.cobranza_saldos_favor ENABLE TRIGGER trg_espejo_flujo_saldo;
  ALTER TABLE public.flujo_dinero ENABLE TRIGGER trg_flujo_dinero_sin_borrar;

  -- 4. Abono de Crédito: se borra y la cuenta por cobrar recupera su saldo.
  SELECT coalesce(sum(monto), 0) INTO v_restaurar FROM public.cxc_abonos WHERE id = ANY (v_abonos);
  DELETE FROM public.cxc_abonos WHERE id = ANY (v_abonos);
  GET DIAGNOSTICS c = ROW_COUNT; v_n := v_n || jsonb_build_object('abonos', c);
  IF v_cxc IS NOT NULL AND v_restaurar > 0 THEN
    UPDATE public.cuentas_por_cobrar
       SET saldo = least(monto, saldo + v_restaurar),
           estatus = CASE WHEN estatus = 'CANCELADA' THEN estatus
                          WHEN least(monto, saldo + v_restaurar) >= monto THEN 'ABIERTA' ELSE 'PARCIAL' END
     WHERE id = v_cxc;
  END IF;

  -- 5. Movimientos de Control Financiero (el SQL editor no tiene usuario de sesión, el candado lo permite).
  DELETE FROM public.movimientos_financieros WHERE id = ANY (v_movs);
  GET DIAGNOSTICS c = ROW_COUNT; v_n := v_n || jsonb_build_object('movimientos', c);

  -- 6. Remisiones que perdieron pagos: ya no quedan pagadas por esos pagos.
  UPDATE public.remisiones_refacciones r SET pagado = false, pagado_at = NULL
   WHERE r.id = ANY (v_rems) AND r.pagado
     AND NOT EXISTS (SELECT 1 FROM public.cobranza_aplicaciones a WHERE a.remision_id = r.id AND a.revertida_at IS NULL);

  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public._limpiar_demostracion_cobranza_credito(text[], text[], text, text[], text) FROM PUBLIC, anon, authenticated;

-- ── Verificación del estado esperado ANTES de borrar: si no coincide, no se toca nada ──
DO $limpiar$
DECLARE
  v_n jsonb;
  v_pagos integer; v_saldos integer; v_movs integer; v_abonos integer;
BEGIN
  SELECT count(*) INTO v_pagos FROM public.cobranza_pagos WHERE folio IN ('CP-00001', 'CP-00002', 'CP-00003');
  SELECT count(*) INTO v_saldos FROM public.cobranza_saldos_favor WHERE folio IN ('SF-00001', 'SF-00002', 'SF-00003', 'SF-00004', 'SF-00005', 'SF-00006');
  SELECT count(*) INTO v_movs FROM public.movimientos_financieros WHERE folio IN ('ING-000007', 'ING-000008', 'ING-000009');
  SELECT count(*) INTO v_abonos FROM public.cxc_abonos b JOIN public.cuentas_por_cobrar c ON c.id = b.cxc_id WHERE c.folio = 'CxC-000002';
  IF v_pagos = 0 AND v_saldos = 0 AND v_movs = 0 AND v_abonos = 0 THEN
    RAISE NOTICE 'Nada que limpiar: los datos de demostración ya no están.';
    RETURN;
  END IF;
  IF v_pagos NOT IN (0, 3) OR v_saldos NOT IN (0, 6) OR v_movs NOT IN (0, 3) OR v_abonos NOT IN (0, 1) THEN
    RAISE EXCEPTION 'El estado no es el esperado (pagos %, saldos %, movimientos %, abonos %): no se borró nada.', v_pagos, v_saldos, v_movs, v_abonos;
  END IF;
  -- Los ingresos de hoy se borran solo si los capturó el equipo (Martín Arcuschin) y siguen sin movimientos ligados.
  IF EXISTS (SELECT 1 FROM public.movimientos_financieros m
              WHERE m.folio IN ('ING-000007', 'ING-000008', 'ING-000009') AND m.created_at < timestamptz '2026-11-03 00:00:00-06') THEN
    RAISE EXCEPTION 'Alguno de los ingresos es anterior al 2026-11-03: no se borra nada.';
  END IF;

  v_n := public._limpiar_demostracion_cobranza_credito(
    ARRAY['CP-00001', 'CP-00002', 'CP-00003'],
    ARRAY['SF-00001', 'SF-00002', 'SF-00003', 'SF-00004', 'SF-00005', 'SF-00006'],
    'CxC-000002',
    ARRAY['ING-000007', 'ING-000008', 'ING-000009'],
    'Limpieza de datos de demostración 2026-11-03');
  RAISE NOTICE 'Limpieza: %', v_n;
END
$limpiar$;

DO $postflight$
BEGIN
  IF EXISTS (SELECT 1 FROM public.cobranza_pagos WHERE folio IN ('CP-00001', 'CP-00002', 'CP-00003'))
     OR EXISTS (SELECT 1 FROM public.cobranza_saldos_favor WHERE folio LIKE 'SF-0000%' AND folio IN ('SF-00001', 'SF-00002', 'SF-00003', 'SF-00004', 'SF-00005', 'SF-00006'))
     OR EXISTS (SELECT 1 FROM public.movimientos_financieros WHERE folio IN ('ING-000007', 'ING-000008', 'ING-000009')) THEN
    RAISE EXCEPTION 'La limpieza no quedó completa.';
  END IF;
  -- Los triggers de inmutabilidad quedaron encendidos.
  IF (SELECT count(*) FROM pg_trigger WHERE tgname IN ('trg_cobranza_aplicaciones_inmutable', 'trg_cobranza_pagos_inmutable',
        'trg_cobranza_saldos_favor_inmutable', 'trg_flujo_dinero_sin_borrar', 'trg_espejo_flujo_aplic', 'trg_espejo_flujo_pago', 'trg_espejo_flujo_saldo')
        AND tgenabled = 'O') <> 7 THEN
    RAISE EXCEPTION 'Algún trigger quedó apagado.';
  END IF;
END $postflight$;

-- ── Verificación (solo lectura) ─────────────────────────────────────────────
-- SELECT folio, saldo, estatus FROM cuentas_por_cobrar;                       -- CxC-000002: 19,602 ABIERTA
-- SELECT tabla, count(*) FROM bitacora_eliminaciones WHERE motivo LIKE 'Limpieza de datos de demostración%' GROUP BY 1;

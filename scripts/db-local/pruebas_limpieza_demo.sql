-- Pruebas de 20261103000010_limpiar_demo_cobranza_credito.sql
-- Requiere antes pruebas_pendientes_martin.sql (usuarios y ayudantes). Todo en una transacción que se revierte.
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

\echo 'L1. La limpieza borra solo lo indicado, respalda, restaura el saldo y deja intactos los triggers'
BEGIN;
SELECT set_config('request.jwt.claim.sub', '', true);
-- Pago de demostración con aplicación y saldo a favor (por las funciones reales).
SELECT public._m_como('vendedor.a@mm.test');
DO $$ DECLARE v jsonb; BEGIN
  v := public.crear_remision_refacciones(public._m_cli(), 'LIMP1', NULL,
    jsonb_build_array(jsonb_build_object('producto_id', public._m_prod('MM-ART-1'), 'cantidad', 1)),
    '{"tipo_envio":"recoge","tipo_pago":"credito"}'::jsonb);
  PERFORM set_config('kit.l_rem', v->>'id', true);
END $$;
RESET ROLE;
SELECT public._m_surtir(current_setting('kit.l_rem')::uuid);
SELECT public._m_como('martin.real@ejemplo.mx');
DO $$ DECLARE v jsonb; BEGIN
  v := public.registrar_pago_cobranza(jsonb_build_object('cliente_id', public._m_cli(), 'monto', 500, 'forma', 'efectivo', 'evidencia_path', 'x/v.pdf'));
  PERFORM set_config('kit.l_pago', v->>'id', true);
END $$;
RESET ROLE;
SELECT public._m_como('finanzas.real@ejemplo.mx');
SELECT public.validar_pago_cobranza(current_setting('kit.l_pago')::uuid, true, NULL);
RESET ROLE;
SELECT public._m_como('martin.real@ejemplo.mx');
SELECT public.aplicar_pago_cobranza(current_setting('kit.l_pago')::uuid,
  jsonb_build_array(jsonb_build_object('remision_id', current_setting('kit.l_rem')::uuid, 'monto', 100)));
RESET ROLE;
SELECT set_config('request.jwt.claim.sub', '', true);
-- Abono de crédito y un ingreso de Control Financiero.
INSERT INTO public.cuentas_por_cobrar (cliente_id, concepto, monto, saldo, fecha_emision, fecha_vencimiento, created_by)
VALUES (public._m_cli(), 'Crédito demo', 1000, 1000, current_date, current_date + 30, '00000000-0000-0000-0000-0000000000b1')
RETURNING id, folio \gset cxc_
INSERT INTO public.cxc_abonos (cxc_id, monto, fecha_abono, metodo_pago, created_by)
VALUES (:'cxc_id', 400, current_date, 'Transferencia SPEI', '00000000-0000-0000-0000-0000000000b1');
INSERT INTO public.movimientos_financieros (tipo, estatus, concepto, monto, moneda, fecha_movimiento, metodo_pago, cuenta_id, contraparte_tipo, contraparte_nombre, created_by, confirmado_por, confirmado_at)
VALUES ('INGRESO', 'CONFIRMADO', 'Ingreso demo', 777, 'MXN', current_date, 'TRANSFERENCIA',
        (SELECT id FROM public.cuentas_financieras WHERE nombre = 'Banco principal'), 'OTRO', 'Demo', '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', now());
SELECT folio AS mov_folio FROM public.movimientos_financieros WHERE concepto = 'Ingreso demo' \gset
SELECT folio AS pago_folio FROM public.cobranza_pagos WHERE id = current_setting('kit.l_pago')::uuid \gset
SELECT string_agg(folio, ',') AS sf_folios FROM public.cobranza_saldos_favor WHERE pago_origen_id = current_setting('kit.l_pago')::uuid \gset
-- Controles que NO deben tocarse: otro ingreso y otra cuenta por cobrar.
INSERT INTO public.movimientos_financieros (tipo, estatus, concepto, monto, moneda, fecha_movimiento, metodo_pago, cuenta_id, contraparte_tipo, contraparte_nombre, created_by, confirmado_por, confirmado_at)
VALUES ('INGRESO', 'CONFIRMADO', 'Ingreso real', 55, 'MXN', current_date, 'TRANSFERENCIA',
        (SELECT id FROM public.cuentas_financieras WHERE nombre = 'Banco principal'), 'OTRO', 'Real', '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', now());
SELECT set_config('kit.pago_folio', :'pago_folio', true), set_config('kit.sf_folios', :'sf_folios', true), set_config('kit.cxc_folio', :'cxc_folio', true), set_config('kit.mov_folio', :'mov_folio', true);
DO $$ BEGIN ASSERT (SELECT saldo FROM public.cuentas_por_cobrar WHERE folio = current_setting('kit.cxc_folio')) = 600, 'saldo antes'; END $$;
DO $$ DECLARE r jsonb; BEGIN
  r := public._limpiar_demostracion_cobranza_credito(ARRAY[current_setting('kit.pago_folio')], string_to_array(current_setting('kit.sf_folios'), ','), current_setting('kit.cxc_folio'), ARRAY[current_setting('kit.mov_folio')], 'Prueba');
  RAISE NOTICE 'resultado %', r;
  ASSERT (r->>'pagos')::int = 1 AND (r->>'abonos')::int = 1 AND (r->>'movimientos')::int = 1 AND (r->>'aplicaciones')::int >= 1, r::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public.cobranza_pagos WHERE folio = current_setting('kit.pago_folio')), 'pago borrado';
  ASSERT NOT EXISTS (SELECT 1 FROM public.cobranza_saldos_favor WHERE pago_origen_id = current_setting('kit.l_pago')::uuid), 'saldos borrados';
  ASSERT NOT EXISTS (SELECT 1 FROM public.flujo_dinero WHERE cobranza_pago_id = current_setting('kit.l_pago')::uuid), 'flujo borrado';
  ASSERT NOT EXISTS (SELECT 1 FROM public.movimientos_financieros WHERE folio = current_setting('kit.mov_folio')), 'movimiento borrado';
  ASSERT EXISTS (SELECT 1 FROM public.movimientos_financieros WHERE concepto = 'Ingreso real'), 'el otro ingreso sigue';
  ASSERT (SELECT saldo FROM public.cuentas_por_cobrar WHERE folio = current_setting('kit.cxc_folio')) = 1000
     AND (SELECT estatus FROM public.cuentas_por_cobrar WHERE folio = current_setting('kit.cxc_folio')) = 'ABIERTA', 'saldo restaurado';
  ASSERT NOT EXISTS (SELECT 1 FROM public.cxc_abonos WHERE cxc_id = (SELECT id FROM public.cuentas_por_cobrar WHERE folio = current_setting('kit.cxc_folio'))), 'abono borrado';
  ASSERT (SELECT count(*) FROM public.bitacora_eliminaciones WHERE motivo = 'Prueba') >= 5, 'respaldo en bitácora';
  ASSERT (SELECT count(*) FROM public.bitacora_eliminaciones WHERE motivo = 'Prueba' AND tabla = 'cobranza_pagos' AND datos_eliminados->>'folio' = current_setting('kit.pago_folio')) = 1, 'respaldo del pago';
  ASSERT (SELECT count(*) FROM pg_trigger WHERE tgname IN ('trg_cobranza_aplicaciones_inmutable','trg_cobranza_pagos_inmutable','trg_cobranza_saldos_favor_inmutable','trg_flujo_dinero_sin_borrar','trg_espejo_flujo_aplic','trg_espejo_flujo_pago','trg_espejo_flujo_saldo') AND tgenabled = 'O') = 7, 'triggers encendidos';
  -- Idempotente: segunda corrida no encuentra nada.
  r := public._limpiar_demostracion_cobranza_credito(ARRAY[current_setting('kit.pago_folio')], string_to_array(current_setting('kit.sf_folios'), ','), current_setting('kit.cxc_folio'), ARRAY[current_setting('kit.mov_folio')], 'Prueba');
  ASSERT (r->>'pagos')::int = 0 AND (r->>'movimientos')::int = 0, 'idempotente';
END $$;
ROLLBACK;

\echo 'L2. La app no puede ejecutar la limpieza'
DO $$ BEGIN
  ASSERT NOT has_function_privilege('authenticated', 'public._limpiar_demostracion_cobranza_credito(text[],text[],text,text[],text)', 'execute'), 'authenticated sin permiso';
  ASSERT NOT has_function_privilege('anon', 'public._limpiar_demostracion_cobranza_credito(text[],text[],text,text[],text)', 'execute'), 'anon sin permiso';
END $$;
\echo 'OK: limpieza'

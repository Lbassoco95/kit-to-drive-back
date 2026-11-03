-- ============================================================================
-- Pruebas (base de datos) de 20261103000002_cobranza_espeja_en_flujo.sql
-- Requiere antes pruebas_pendientes_martin.sql (usa sus usuarios y ayudantes).
-- ============================================================================
\set ON_ERROR_STOP 1
SET client_min_messages = warning;
CREATE TABLE IF NOT EXISTS public._e_ids (clave text PRIMARY KEY, id uuid);
GRANT SELECT, INSERT ON public._e_ids TO authenticated;
DELETE FROM public._e_ids;

\echo 'E1. Registrar en Cobranza crea su renglón en el flujo (RECIBIDO)'
BEGIN;
SELECT public._m_como('martin.real@ejemplo.mx');
DO $$ DECLARE v jsonb; BEGIN
  v := public.registrar_pago_cobranza(jsonb_build_object('cliente_id', public._m_cli(), 'monto', 300, 'forma', 'efectivo',
         'evidencia_path', 'x/vale.pdf'));
  INSERT INTO public._e_ids VALUES ('p1', (v->>'id')::uuid);
END $$;
RESET ROLE;
DO $$ DECLARE f public.flujo_dinero%ROWTYPE; BEGIN
  SELECT * INTO f FROM public.flujo_dinero WHERE cobranza_pago_id = (SELECT id FROM public._e_ids WHERE clave = 'p1');
  ASSERT FOUND, 'debe existir el renglón del flujo';
  ASSERT f.etapa = 'RECIBIDO' AND f.tipo = 'PAGO_CLIENTE' AND f.monto = 300 AND f.metodo_pago = 'EFECTIVO', format('renglón: %s', to_jsonb(f));
  ASSERT f.cliente_id = public._m_cli(), 'mismo cliente';
  ASSERT f.movimiento_id IS NULL, 'sin movimiento hasta validar';
  ASSERT f.folio LIKE 'FD-%', 'folio del flujo';
END $$;
-- Un segundo registro no duplica el renglón.
DO $$ BEGIN
  PERFORM public._espejo_flujo_sincronizar((SELECT id FROM public._e_ids WHERE clave = 'p1'));
  ASSERT (SELECT count(*) FROM public.flujo_dinero WHERE cobranza_pago_id = (SELECT id FROM public._e_ids WHERE clave = 'p1')) = 1;
END $$;
-- El flujo no puede mover un renglón que vive en Cobranza.
DO $$ BEGIN
  PERFORM public._m_falla($q$UPDATE public.flujo_dinero SET etapa = 'EN_CAJA' WHERE cobranza_pago_id IS NOT NULL$q$, 'viene de Cobranza');
END $$;
COMMIT;

\echo 'E2. Finanzas valida: pasa a EN_CAJA y entra a Control Financiero (Caja chica)'
BEGIN;
SELECT public._m_como('finanzas.real@ejemplo.mx');
SELECT public.validar_pago_cobranza((SELECT id FROM public._e_ids WHERE clave = 'p1'), true, NULL);
RESET ROLE;
DO $$ DECLARE f public.flujo_dinero%ROWTYPE; m public.movimientos_financieros%ROWTYPE; BEGIN
  SELECT * INTO f FROM public.flujo_dinero WHERE cobranza_pago_id = (SELECT id FROM public._e_ids WHERE clave = 'p1');
  ASSERT f.etapa = 'EN_CAJA', format('etapa %s', f.etapa);
  ASSERT f.movimiento_id IS NOT NULL, 'tiene movimiento';
  SELECT * INTO m FROM public.movimientos_financieros WHERE id = f.movimiento_id;
  ASSERT m.tipo = 'INGRESO' AND m.estatus = 'CONFIRMADO' AND m.monto = 300, format('mov %s', to_jsonb(m));
  ASSERT (SELECT nombre FROM public.cuentas_financieras WHERE id = m.cuenta_id) = 'Caja chica', 'efectivo → Caja chica';
  ASSERT f.cuenta_id = m.cuenta_id, 'misma cuenta';
END $$;
COMMIT;

\echo 'E3. Compras aplica el pago a una remisión: pasa a APLICADO'
BEGIN;
SELECT public._m_como('vendedor.a@mm.test');
DO $$ DECLARE v jsonb; BEGIN
  v := public.crear_remision_refacciones(public._m_cli(), 'ESP1', NULL,
    jsonb_build_array(jsonb_build_object('producto_id', public._m_prod('MM-ART-1'), 'cantidad', 3)),
    '{"tipo_envio":"recoge","tipo_pago":"credito"}'::jsonb);
  INSERT INTO public._e_ids VALUES ('r1', (v->>'id')::uuid);
END $$;
RESET ROLE;
SELECT public._m_surtir((SELECT id FROM public._e_ids WHERE clave = 'r1'));
SELECT public._m_como('martin.real@ejemplo.mx');
SELECT public.aplicar_pago_cobranza((SELECT id FROM public._e_ids WHERE clave = 'p1'),
  jsonb_build_array(jsonb_build_object('remision_id', (SELECT id FROM public._e_ids WHERE clave = 'r1'), 'monto', 300)));
RESET ROLE;
DO $$ DECLARE f public.flujo_dinero%ROWTYPE; BEGIN
  SELECT * INTO f FROM public.flujo_dinero WHERE cobranza_pago_id = (SELECT id FROM public._e_ids WHERE clave = 'p1');
  ASSERT f.etapa = 'APLICADO' AND f.destino = 'REMISION', format('etapa %s destino %s', f.etapa, f.destino);
  ASSERT f.movimiento_id IS NOT NULL, 'conserva el movimiento';
END $$;
COMMIT;

\echo 'E4. Revertir el pago en Cobranza: RECHAZADO y el movimiento queda CANCELADO (no se borra)'
BEGIN;
SELECT public._m_como('martin.real@ejemplo.mx');
SELECT public.revertir_pago_cobranza((SELECT id FROM public._e_ids WHERE clave = 'p1'), 'Prueba de reversión del espejo');
RESET ROLE;
DO $$ DECLARE f public.flujo_dinero%ROWTYPE; BEGIN
  SELECT * INTO f FROM public.flujo_dinero WHERE cobranza_pago_id = (SELECT id FROM public._e_ids WHERE clave = 'p1');
  ASSERT f.etapa = 'RECHAZADO', format('etapa %s', f.etapa);
  ASSERT f.motivo_rechazo = 'Prueba de reversión del espejo', 'motivo copiado';
  ASSERT (SELECT estatus FROM public.movimientos_financieros WHERE id = f.movimiento_id) = 'CANCELADO', 'movimiento cancelado';
  ASSERT f.destino IS NULL AND f.aplicado_por IS NULL, 'sin datos de aplicación';
END $$;
COMMIT;

\echo 'E5. Transferencia validada al registrar → Banco principal; pagos de prueba y de flujo no se espejean'
BEGIN;
SELECT public._m_como('finanzas.real@ejemplo.mx');
DO $$ DECLARE v jsonb; BEGIN
  v := public.registrar_pago_cobranza(jsonb_build_object('cliente_id', public._m_cli(), 'monto', 500, 'forma', 'transferencia',
         'referencia', 'SPEI-1', 'evidencia_path', 'x/spei.pdf', 'validar', true, 'conciliado', true));
  INSERT INTO public._e_ids VALUES ('p2', (v->>'id')::uuid);
END $$;
RESET ROLE;
DO $$ DECLARE f public.flujo_dinero%ROWTYPE; BEGIN
  SELECT * INTO f FROM public.flujo_dinero WHERE cobranza_pago_id = (SELECT id FROM public._e_ids WHERE clave = 'p2');
  ASSERT f.etapa = 'EN_CAJA' AND f.metodo_pago = 'TRANSFERENCIA' AND f.referencia = 'SPEI-1', format('%s', to_jsonb(f));
  ASSERT (SELECT nombre FROM public.cuentas_financieras WHERE id = f.cuenta_id) = 'Banco principal', 'transferencia → Banco';
END $$;
RESET ROLE;
-- Pago que nace del propio flujo (nota «Flujo de dinero FD-…»): sin duplicar.
INSERT INTO public.cobranza_pagos (folio, cliente_id, fecha, monto, forma, notas, estatus, conciliado, capturado_por)
VALUES ('CP-ESP-FLUJO', public._m_cli(), current_date, 10, 'efectivo', 'Flujo de dinero FD-999999', 'validado', true, '00000000-0000-0000-0000-0000000000b5');
DO $$ BEGIN ASSERT NOT EXISTS (SELECT 1 FROM public.flujo_dinero f JOIN public.cobranza_pagos p ON p.id = f.cobranza_pago_id WHERE p.folio = 'CP-ESP-FLUJO'), 'no se espejea lo que viene del flujo'; END $$;
-- Pago de prueba: tampoco.
INSERT INTO public.cobranza_pagos (folio, cliente_id, fecha, monto, forma, estatus, capturado_por, es_prueba)
VALUES ('CP-ESP-PRUEBA', public._m_cli(), current_date, 10, 'efectivo', 'registrado', '00000000-0000-0000-0000-0000000000b5', true);
DO $$ BEGIN ASSERT NOT EXISTS (SELECT 1 FROM public.flujo_dinero f JOIN public.cobranza_pagos p ON p.id = f.cobranza_pago_id WHERE p.folio = 'CP-ESP-PRUEBA'), 'prueba no se espejea'; END $$;
ROLLBACK;

\echo 'E6. Ya existente en prod: los flujos que nacieron en el flujo siguen avanzando normal (la guarda no los toca)'
BEGIN;
DO $$ DECLARE v_id uuid; BEGIN
  INSERT INTO public.flujo_dinero (tipo, monto, metodo_pago, fecha, contraparte_nombre, recibido_por, etapa)
  VALUES ('SALIDA', 10, 'EFECTIVO', current_date, 'x', '00000000-0000-0000-0000-0000000000b5', 'RECIBIDO') RETURNING id INTO v_id;
  UPDATE public.flujo_dinero SET etapa = 'EN_CAJA' WHERE id = v_id;
  UPDATE public.flujo_dinero SET etapa = 'RECHAZADO', motivo_rechazo = 'x' WHERE id = v_id;
END $$;
ROLLBACK;
\echo 'OK: pruebas del espejo Cobranza → Flujo'

-- ============================================================================
-- Pruebas (base de datos) de 20261103000003_abonos_credito_en_flujo.sql
-- Orden: pruebas_compras.sql (solo siembra usuarios) → pruebas_pendientes_martin.sql
--        → pruebas_cobranza_espejo.sql → esta.
-- ============================================================================
\set ON_ERROR_STOP 1
SET client_min_messages = warning;
CREATE TABLE IF NOT EXISTS public._a_ids (clave text PRIMARY KEY, id uuid);
GRANT SELECT, INSERT ON public._a_ids TO authenticated;
DELETE FROM public._a_ids;

-- Caja para Finanzas (b5) y para Compras (b1, que recibe: no puede ser su propia caja).
BEGIN;
SELECT public._m_como('global@mm.test');
SELECT public.flujo_asignar_capacidad('00000000-0000-0000-0000-0000000000b5', 'caja', true);
SELECT public.flujo_asignar_capacidad('00000000-0000-0000-0000-0000000000b1', 'caja', true);
COMMIT;

\echo 'A1. Un abono de Crédito crea su renglón en el flujo (RECIBIDO)'
BEGIN;
INSERT INTO public.cuentas_por_cobrar (cliente_id, concepto, monto, saldo, fecha_emision, fecha_vencimiento, created_by)
VALUES (public._m_cli(), 'Venta a crédito de prueba', 1000, 1000, current_date, current_date + 30, '00000000-0000-0000-0000-0000000000b1')
RETURNING id \gset cxc_
INSERT INTO public._a_ids VALUES ('cxc', :'cxc_id');
INSERT INTO public.cxc_abonos (cxc_id, monto, fecha_abono, metodo_pago, referencia, created_by)
VALUES (:'cxc_id', 400, current_date, 'Transferencia SPEI', 'REF-ABONO-1', '00000000-0000-0000-0000-0000000000b1')
RETURNING id \gset ab_
INSERT INTO public._a_ids VALUES ('ab1', :'ab_id');
DO $$ DECLARE f public.flujo_dinero%ROWTYPE; BEGIN
  ASSERT (SELECT saldo FROM public.cuentas_por_cobrar WHERE id = (SELECT id FROM public._a_ids WHERE clave = 'cxc')) = 600, 'el abono bajó el saldo';
  SELECT * INTO f FROM public.flujo_dinero WHERE cxc_abono_id = (SELECT id FROM public._a_ids WHERE clave = 'ab1');
  ASSERT FOUND, 'debe existir el renglón del flujo';
  ASSERT f.etapa = 'RECIBIDO' AND f.tipo = 'PAGO_CLIENTE' AND f.monto = 400 AND f.metodo_pago = 'TRANSFERENCIA' AND f.referencia = 'REF-ABONO-1', format('%s', to_jsonb(f));
  ASSERT f.cobranza_pago_id IS NULL, 'no es un pago de Cobranza';
END $$;
COMMIT;

\echo 'A2. Caja (otra persona) confirma: APLICADO, ingreso en Banco principal y el abono guarda su movimiento'
BEGIN;
SELECT public._m_como('finanzas.real@ejemplo.mx');
SELECT public.flujo_confirmar_caja((SELECT id FROM public.v_flujo_dinero WHERE cxc_abono_id = (SELECT id FROM public._a_ids WHERE clave = 'ab1')),
  (SELECT id FROM public.cuentas_financieras WHERE nombre = 'Banco principal'), 'conciliado');
RESET ROLE;
DO $$ DECLARE f public.flujo_dinero%ROWTYPE; m public.movimientos_financieros%ROWTYPE; BEGIN
  SELECT * INTO f FROM public.flujo_dinero WHERE cxc_abono_id = (SELECT id FROM public._a_ids WHERE clave = 'ab1');
  ASSERT f.etapa = 'APLICADO' AND f.destino = 'OTRO' AND f.movimiento_id IS NOT NULL, format('%s', to_jsonb(f));
  SELECT * INTO m FROM public.movimientos_financieros WHERE id = f.movimiento_id;
  ASSERT m.tipo = 'INGRESO' AND m.estatus = 'CONFIRMADO' AND m.monto = 400, format('mov %s', to_jsonb(m));
  ASSERT (SELECT movimiento_id FROM public.cxc_abonos WHERE id = (SELECT id FROM public._a_ids WHERE clave = 'ab1')) = f.movimiento_id, 'el abono guarda su movimiento';
  ASSERT (SELECT saldo FROM public.cuentas_por_cobrar WHERE id = (SELECT id FROM public._a_ids WHERE clave = 'cxc')) = 600, 'el saldo no se vuelve a mover';
END $$;
COMMIT;

\echo 'A3. Quien registró el abono no puede ser su propia caja; el abono no se rechaza ni se aplica en el flujo'
BEGIN;
INSERT INTO public.cxc_abonos (cxc_id, monto, fecha_abono, metodo_pago, created_by)
VALUES ((SELECT id FROM public._a_ids WHERE clave = 'cxc'), 100, current_date, 'efectivo', '00000000-0000-0000-0000-0000000000b1')
RETURNING id \gset ab_
INSERT INTO public._a_ids VALUES ('ab2', :'ab_id');
SELECT public._m_como('martin.real@ejemplo.mx');
DO $$ BEGIN
  PERFORM public._m_falla(format($q$SELECT public.flujo_confirmar_caja(%L, %L)$q$,
    (SELECT id FROM public.v_flujo_dinero WHERE cxc_abono_id = (SELECT id FROM public._a_ids WHERE clave = 'ab2')),
    (SELECT id FROM public.cuentas_financieras WHERE nombre = 'Caja chica')), 'otra persona');
END $$;
RESET ROLE;
DO $$ BEGIN
  PERFORM public._m_falla(format($q$UPDATE public.flujo_dinero SET etapa = 'RECHAZADO', motivo_rechazo = 'x' WHERE cxc_abono_id = %L$q$,
    (SELECT id FROM public._a_ids WHERE clave = 'ab2')), 'abono de Crédito');
  PERFORM public._m_falla(format($q$UPDATE public.flujo_dinero SET etapa = 'EN_CAJA' WHERE cxc_abono_id = %L$q$,
    (SELECT id FROM public._a_ids WHERE clave = 'ab2')), 'abono de Crédito');
END $$;
-- Efectivo en la caja de efectivo: la regla de cuenta por método sigue vigente.
SELECT public._m_como('finanzas.real@ejemplo.mx');
DO $$ BEGIN
  PERFORM public._m_falla(format($q$SELECT public.flujo_confirmar_caja(%L, %L)$q$,
    (SELECT id FROM public.v_flujo_dinero WHERE cxc_abono_id = (SELECT id FROM public._a_ids WHERE clave = 'ab2')),
    (SELECT id FROM public.cuentas_financieras WHERE nombre = 'Banco principal')), 'solo se registra en una caja de efectivo');
END $$;
SELECT public.flujo_confirmar_caja((SELECT id FROM public.v_flujo_dinero WHERE cxc_abono_id = (SELECT id FROM public._a_ids WHERE clave = 'ab2')),
  (SELECT id FROM public.cuentas_financieras WHERE nombre = 'Caja chica'));
RESET ROLE;
DO $$ BEGIN ASSERT (SELECT etapa FROM public.flujo_dinero WHERE cxc_abono_id = (SELECT id FROM public._a_ids WHERE clave = 'ab2')) = 'APLICADO'; END $$;
COMMIT;

\echo 'A4. Un fallo del espejo no frena el abono; USD y clientes de prueba no se espejean'
BEGIN;
INSERT INTO public.cuentas_por_cobrar (cliente_id, concepto, monto, saldo, moneda, fecha_emision, fecha_vencimiento, created_by)
VALUES (public._m_cli(), 'CxC en USD', 500, 500, 'USD', current_date, current_date + 30, '00000000-0000-0000-0000-0000000000b1')
RETURNING id \gset usd_
INSERT INTO public.cxc_abonos (cxc_id, monto, fecha_abono, metodo_pago, created_by)
VALUES (:'usd_id', 50, current_date, 'efectivo', '00000000-0000-0000-0000-0000000000b1') RETURNING id \gset abu_
DO $$ BEGIN ASSERT NOT EXISTS (SELECT 1 FROM public.flujo_dinero WHERE cxc_abono_id = (SELECT id FROM public.cxc_abonos ORDER BY created_at DESC LIMIT 1)), 'USD no se espejea'; END $$;
-- Abono sin created_by ni dueño de la CxC: no hay quién lo recibió; el abono igual se guarda.
INSERT INTO public.cuentas_por_cobrar (cliente_id, concepto, monto, saldo, fecha_emision, fecha_vencimiento)
VALUES (public._m_cli(), 'CxC sin dueño', 200, 200, current_date, current_date + 30) RETURNING id \gset sd_
INSERT INTO public.cxc_abonos (cxc_id, monto, fecha_abono) VALUES (:'sd_id', 20, current_date);
DO $$ BEGIN ASSERT (SELECT saldo FROM public.cuentas_por_cobrar WHERE concepto = 'CxC sin dueño') = 180, 'el abono se guardó y bajó el saldo'; END $$;
ROLLBACK;
\echo 'OK: pruebas del espejo de abonos de Crédito'

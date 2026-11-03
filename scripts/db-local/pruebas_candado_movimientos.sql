-- ============================================================================
-- Pruebas de 20261103000004_control_financiero_solo_consulta.sql
-- Requiere antes pruebas_pendientes_martin.sql (usuarios y ayudantes).
-- ============================================================================
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

\echo 'C1. Un usuario (aunque sea admin) no puede crear, editar ni borrar movimientos directo'
BEGIN;
DO $$ BEGIN
  PERFORM public._m_como('admin.real@ejemplo.mx');
  PERFORM public._m_falla($q$INSERT INTO public.movimientos_financieros (tipo, concepto, monto, contraparte_nombre) VALUES ('INGRESO', 'directo', 10, 'x')$q$, 'solo de consulta');
END $$;
RESET ROLE;
SELECT set_config('request.jwt.claim.sub', '', true);  -- sin usuario de sesión, como el SQL editor
-- Un movimiento legítimo (SQL editor).
INSERT INTO public.movimientos_financieros (id, tipo, concepto, monto, contraparte_nombre)
VALUES ('22222222-2222-2222-2222-222222222222', 'INGRESO', 'legado', 10, 'x');
DO $$ BEGIN
  PERFORM public._m_como('admin.real@ejemplo.mx');
  PERFORM public._m_falla($q$UPDATE public.movimientos_financieros SET monto = 99 WHERE id = '22222222-2222-2222-2222-222222222222'$q$, 'solo de consulta');
  PERFORM public._m_falla($q$UPDATE public.movimientos_financieros SET estatus = 'CANCELADO' WHERE id = '22222222-2222-2222-2222-222222222222'$q$, 'solo de consulta');
  PERFORM public._m_falla($q$DELETE FROM public.movimientos_financieros WHERE id = '22222222-2222-2222-2222-222222222222'$q$, 'solo de consulta');
  -- Los campos de factura (los mantiene el expediente) sí se pueden.
  UPDATE public.movimientos_financieros SET tiene_factura = true WHERE id = '22222222-2222-2222-2222-222222222222';
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT monto FROM public.movimientos_financieros WHERE id = '22222222-2222-2222-2222-222222222222') = 10, 'el monto no cambió';
  ASSERT (SELECT tiene_factura FROM public.movimientos_financieros WHERE id = '22222222-2222-2222-2222-222222222222'), 'la factura sí';
END $$;
ROLLBACK;

\echo 'C2. El flujo sigue creando y cancelando movimientos (caja y rechazo), y el candado se cierra solo'
BEGIN;
SELECT public._m_como('global@mm.test');
SELECT public.flujo_asignar_capacidad('00000000-0000-0000-0000-0000000000b1', 'recibe', true);
SELECT public.flujo_asignar_capacidad('00000000-0000-0000-0000-0000000000b5', 'caja', true);
RESET ROLE;
SELECT public._m_como('martin.real@ejemplo.mx');
DO $$ DECLARE v jsonb; BEGIN
  v := public.flujo_recibir('SALIDA', 123, 'MXN', 'EFECTIVO', current_date, 'Proveedor X', NULL, 'Pago de prueba', NULL, NULL);
  CREATE TEMP TABLE IF NOT EXISTS t_f (id uuid); INSERT INTO t_f VALUES ((v->>'id')::uuid);
  GRANT ALL ON t_f TO authenticated;
END $$;
RESET ROLE;
SELECT public._m_como('finanzas.real@ejemplo.mx');
SELECT public.flujo_confirmar_caja((SELECT id FROM t_f), (SELECT id FROM public.cuentas_financieras WHERE nombre = 'Caja chica'));
DO $$ DECLARE m public.movimientos_financieros%ROWTYPE; BEGIN
  SELECT * INTO m FROM public.movimientos_financieros WHERE id = (SELECT movimiento_id FROM public.flujo_dinero WHERE id = (SELECT id FROM t_f));
  ASSERT m.tipo = 'EGRESO' AND m.estatus = 'CONFIRMADO' AND m.monto = 123, format('%s', to_jsonb(m));
  -- Ya fuera de la función la llave del candado quedó cerrada.
  ASSERT coalesce(current_setting('kit.flujo_escribe', true), '') <> 'on', 'la llave del candado no debe quedar abierta';
END $$;
RESET ROLE;
SELECT public._m_como('admin.real@ejemplo.mx');
DO $$ BEGIN
  PERFORM public._m_falla(format($q$UPDATE public.movimientos_financieros SET concepto = 'x' WHERE id = (SELECT movimiento_id FROM public.flujo_dinero WHERE id = %L)$q$, (SELECT id FROM t_f)), 'solo de consulta');
END $$;
RESET ROLE;
SELECT public._m_como('finanzas.real@ejemplo.mx');
SELECT public.flujo_rechazar((SELECT id FROM t_f), 'Se rechaza desde el flujo');
DO $$ BEGIN
  ASSERT (SELECT estatus FROM public.movimientos_financieros WHERE id = (SELECT movimiento_id FROM public.flujo_dinero WHERE id = (SELECT id FROM t_f))) = 'CANCELADO', 'el rechazo cancela el movimiento';
END $$;
ROLLBACK;
\echo 'OK: candado de movimientos'

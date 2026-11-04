-- Pruebas de 20261104000002_control_financiero_por_confirmar.sql
-- Requiere pruebas_pendientes_martin.sql y pruebas_abono_flujo.sql (usuarios reales y caja de Finanzas).
\set ON_ERROR_STOP 1
SET client_min_messages = warning;
CREATE TABLE IF NOT EXISTS public._pc_ids (clave text PRIMARY KEY, id uuid);
GRANT SELECT, INSERT ON public._pc_ids TO authenticated;
DELETE FROM public._pc_ids;

\echo 'PC1. Un pago real registrado en el flujo aparece en Control Financiero «por confirmar» sin mover saldos'
BEGIN;
SELECT public._m_como('martin.real@ejemplo.mx');
DO $$ DECLARE v jsonb; f public.flujo_dinero%ROWTYPE; m public.movimientos_financieros%ROWTYPE; BEGIN
  v := public.flujo_recibir('PAGO_CLIENTE', 900, 'MXN', 'EFECTIVO', current_date, 'Cliente MM', public._m_cli());
  INSERT INTO public._pc_ids VALUES ('f1', (v->>'id')::uuid);
END $$;
RESET ROLE;
DO $$ DECLARE f public.flujo_dinero%ROWTYPE; m public.movimientos_financieros%ROWTYPE; BEGIN
  SELECT * INTO f FROM public.flujo_dinero WHERE id = (SELECT id FROM public._pc_ids WHERE clave = 'f1');
  ASSERT f.movimiento_id IS NOT NULL AND f.cobranza_pago_id IS NOT NULL AND NOT f.es_prueba, 'ligado a movimiento y pago';
  SELECT * INTO m FROM public.movimientos_financieros WHERE id = f.movimiento_id;
  ASSERT m.estatus = 'PENDIENTE' AND m.monto = 900 AND m.cuenta_id IS NULL AND m.tipo = 'INGRESO' AND m.cliente_id = public._m_cli(), format('%s', to_jsonb(m));
  INSERT INTO public._pc_ids VALUES ('m1', m.id);
END $$;
COMMIT;

\echo 'PC2. Caja confirma el MISMO ingreso (no crea otro) y toma la cuenta'
BEGIN;
SELECT public._m_como('finanzas.real@ejemplo.mx');
SELECT public.flujo_confirmar_caja((SELECT id FROM public._pc_ids WHERE clave = 'f1'),
  (SELECT id FROM public.cuentas_financieras WHERE tipo::text = 'EFECTIVO' AND moneda = 'MXN' AND activo ORDER BY nombre LIMIT 1));
RESET ROLE;
DO $$ DECLARE m public.movimientos_financieros%ROWTYPE; BEGIN
  SELECT * INTO m FROM public.movimientos_financieros WHERE id = (SELECT id FROM public._pc_ids WHERE clave = 'm1');
  ASSERT m.estatus = 'CONFIRMADO' AND m.cuenta_id IS NOT NULL AND m.confirmado_por IS NOT NULL, format('%s', to_jsonb(m));
  ASSERT (SELECT movimiento_id FROM public.flujo_dinero WHERE id = (SELECT id FROM public._pc_ids WHERE clave = 'f1')) = m.id, 'sigue ligado al mismo movimiento';
  ASSERT (SELECT count(*) FROM public.movimientos_financieros WHERE descripcion LIKE 'Flujo de dinero ' || (SELECT folio FROM public.flujo_dinero WHERE id = (SELECT id FROM public._pc_ids WHERE clave = 'f1')) || '%') = 1, 'un solo movimiento';
END $$;
COMMIT;

\echo 'PC3. Rechazar antes de caja cancela el ingreso por confirmar'
BEGIN;
SELECT public._m_como('martin.real@ejemplo.mx');
DO $$ DECLARE v jsonb; BEGIN
  v := public.flujo_recibir('PAGO_CLIENTE', 250, 'MXN', 'EFECTIVO', current_date, 'Cliente MM', public._m_cli());
  INSERT INTO public._pc_ids VALUES ('f2', (v->>'id')::uuid);
END $$;
RESET ROLE;
SELECT public._m_como('finanzas.real@ejemplo.mx');
SELECT public.flujo_rechazar((SELECT id FROM public._pc_ids WHERE clave = 'f2'), 'No llegó el dinero');
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT m.estatus::text FROM public.movimientos_financieros m JOIN public.flujo_dinero f ON f.movimiento_id = m.id WHERE f.id = (SELECT id FROM public._pc_ids WHERE clave = 'f2')) = 'CANCELADO', 'ingreso cancelado';
END $$;
COMMIT;

\echo 'OK: por confirmar'

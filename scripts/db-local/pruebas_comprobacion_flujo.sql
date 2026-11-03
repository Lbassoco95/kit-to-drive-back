-- ============================================================================
-- Pruebas de 20261103000005_comprobacion_efectivo_en_flujo.sql
-- Requiere antes pruebas_pendientes_martin.sql (usuarios y ayudantes).
-- ============================================================================
\set ON_ERROR_STOP 1
SET client_min_messages = warning;
CREATE TABLE IF NOT EXISTS public._k_ids (clave text PRIMARY KEY, id uuid);
GRANT SELECT, INSERT ON public._k_ids TO authenticated;
DELETE FROM public._k_ids;

BEGIN;
SELECT public._m_como('global@mm.test');
SELECT public.flujo_asignar_capacidad('00000000-0000-0000-0000-0000000000b1', 'recibe', true);
SELECT public.flujo_asignar_capacidad('00000000-0000-0000-0000-0000000000b5', 'caja', true);
COMMIT;

\echo 'K1. Salida en efectivo con intermediario queda «por comprobar»; el intermediario solo aplica a salidas en efectivo'
BEGIN;
SELECT public._m_como('martin.real@ejemplo.mx');
DO $$ DECLARE v jsonb; f public.flujo_dinero%ROWTYPE; BEGIN
  v := public.flujo_recibir('SALIDA', 500, 'MXN', 'EFECTIVO', current_date, 'Proveedor Z', NULL, 'Compra de material', NULL, NULL, 'Juan Pérez');
  INSERT INTO public._k_ids VALUES ('s1', (v->>'id')::uuid);
  v := public.flujo_recibir('SALIDA', 80, 'MXN', 'EFECTIVO', current_date, 'Papelería', NULL, 'Papelería', NULL, NULL, NULL);
  INSERT INTO public._k_ids VALUES ('s2', (v->>'id')::uuid);
  PERFORM public._m_falla($q$SELECT public.flujo_recibir('SALIDA', 10, 'MXN', 'TRANSFERENCIA', current_date, 'x', NULL, 'x', 'REF', NULL, 'Juan')$q$, 'solo aplica a una salida de dinero en efectivo');
  PERFORM public._m_falla(format($q$SELECT public.flujo_recibir('PAGO_CLIENTE', 10, 'MXN', 'EFECTIVO', current_date, 'x', %L, NULL, NULL, NULL, 'Juan')$q$, public._m_cli()), 'solo aplica a una salida de dinero en efectivo');
END $$;
RESET ROLE;
DO $$ DECLARE f public.flujo_dinero%ROWTYPE; BEGIN
  SELECT * INTO f FROM public.flujo_dinero WHERE id = (SELECT id FROM public._k_ids WHERE clave = 's1');
  ASSERT f.requiere_comprobacion AND NOT f.comprobado AND f.intermediario_nombre = 'Juan Pérez', format('%s', to_jsonb(f));
  ASSERT NOT (SELECT requiere_comprobacion FROM public.flujo_dinero WHERE id = (SELECT id FROM public._k_ids WHERE clave = 's2')), 'sin intermediario no requiere';
END $$;
COMMIT;

\echo 'K2. Antes de caja no se comprueba; caja saca el egreso «vía intermediario»'
BEGIN;
SELECT public._m_como('finanzas.real@ejemplo.mx');
DO $$ BEGIN
  PERFORM public._m_falla(format($q$SELECT public.flujo_comprobar(%L, 100, 0)$q$, (SELECT id FROM public._k_ids WHERE clave = 's1')), 'ya salió de caja');
END $$;
SELECT public.flujo_confirmar_caja((SELECT id FROM public._k_ids WHERE clave = 's1'), (SELECT id FROM public.cuentas_financieras WHERE nombre = 'Caja chica'));
SELECT public.flujo_confirmar_caja((SELECT id FROM public._k_ids WHERE clave = 's2'), (SELECT id FROM public.cuentas_financieras WHERE nombre = 'Caja chica'));
RESET ROLE;
DO $$ DECLARE m public.movimientos_financieros%ROWTYPE; BEGIN
  SELECT * INTO m FROM public.movimientos_financieros WHERE id = (SELECT movimiento_id FROM public.flujo_dinero WHERE id = (SELECT id FROM public._k_ids WHERE clave = 's1'));
  ASSERT m.tipo = 'EGRESO' AND m.via = 'INTERMEDIARIO' AND m.intermediario_nombre = 'Juan Pérez' AND m.requiere_comprobacion AND NOT m.comprobado, format('%s', to_jsonb(m));
  SELECT * INTO m FROM public.movimientos_financieros WHERE id = (SELECT movimiento_id FROM public.flujo_dinero WHERE id = (SELECT id FROM public._k_ids WHERE clave = 's2'));
  ASSERT m.via = 'DIRECTO' AND NOT m.requiere_comprobacion, 'la salida directa no requiere comprobación';
END $$;
COMMIT;

\echo 'K3. Comprobar: validaciones, permisos y se copia a Control Financiero'
BEGIN;
SELECT public._m_como('vendedor.a@mm.test');
DO $$ BEGIN
  PERFORM public._m_falla(format($q$SELECT public.flujo_comprobar(%L, 100, 0)$q$, (SELECT id FROM public._k_ids WHERE clave = 's1')), 'Solo Caja, Aplicación');
END $$;
RESET ROLE;
SELECT public._m_como('finanzas.real@ejemplo.mx');
DO $$ DECLARE r jsonb; id1 uuid := (SELECT id FROM public._k_ids WHERE clave = 's1'); BEGIN
  PERFORM public._m_falla(format($q$SELECT public.flujo_comprobar(%L, 450, 100)$q$, id1), 'supera lo entregado');
  PERFORM public._m_falla(format($q$SELECT public.flujo_comprobar(%L, -1, 0)$q$, id1), 'Captura lo comprobado');
  PERFORM public._m_falla(format($q$SELECT public.flujo_comprobar(%L, 10, -5)$q$, id1), 'no puede ser negativo');
  PERFORM public._m_falla(format($q$SELECT public.flujo_comprobar(%L, 10, 0)$q$, (SELECT id FROM public._k_ids WHERE clave = 's2')), 'no requiere comprobación');
  r := public.flujo_comprobar(id1, 450, 30, 'Tickets y 30 de cambio');
  ASSERT (r->>'sin_comprobar')::numeric = 20, format('%s', r);
  PERFORM public._m_falla(format($q$SELECT public.flujo_comprobar(%L, 10, 0)$q$, id1), 'ya está comprobado');
END $$;
RESET ROLE;
DO $$ DECLARE f public.flujo_dinero%ROWTYPE; m public.movimientos_financieros%ROWTYPE; BEGIN
  SELECT * INTO f FROM public.flujo_dinero WHERE id = (SELECT id FROM public._k_ids WHERE clave = 's1');
  ASSERT f.comprobado AND f.monto_comprobado = 450 AND f.monto_devuelto = 30 AND f.comprobado_por IS NOT NULL AND f.comprobacion_notas = 'Tickets y 30 de cambio', format('%s', to_jsonb(f));
  SELECT * INTO m FROM public.movimientos_financieros WHERE id = f.movimiento_id;
  ASSERT m.comprobado AND m.monto_comprobado = 450 AND m.monto_devuelto = 30 AND m.comprobado_por IS NOT NULL, 'Control Financiero lo muestra comprobado';
  ASSERT EXISTS (SELECT 1 FROM public.movimiento_bitacora b WHERE b.movimiento_id = m.id AND b.accion = 'COMPROBADO'), 'queda en la bitácora del movimiento';
END $$;
COMMIT;

\echo 'K4. El cambio devuelto suma a la caja: renglón del flujo (reembolso aplicado) e ingreso en Control Financiero'
DO $$ DECLARE c public.flujo_dinero%ROWTYPE; m public.movimientos_financieros%ROWTYPE; orig public.flujo_dinero%ROWTYPE; BEGIN
  SELECT * INTO orig FROM public.flujo_dinero WHERE id = (SELECT id FROM public._k_ids WHERE clave = 's1');
  SELECT * INTO c FROM public.flujo_dinero WHERE tipo = 'REEMBOLSO' AND referencia = orig.folio;
  ASSERT FOUND, 'debe existir el renglón del cambio';
  ASSERT c.etapa = 'APLICADO' AND c.monto = 30 AND c.metodo_pago = 'EFECTIVO' AND c.destino = 'REEMBOLSO_EMPLEADO' AND c.cuenta_id = orig.cuenta_id AND c.concepto = 'Cambio devuelto de ' || orig.folio, format('%s', to_jsonb(c));
  SELECT * INTO m FROM public.movimientos_financieros WHERE id = c.movimiento_id;
  ASSERT m.tipo = 'INGRESO' AND m.estatus = 'CONFIRMADO' AND m.monto = 30 AND m.cuenta_id = orig.cuenta_id, format('%s', to_jsonb(m));
  -- Una comprobación sin cambio no genera ingreso.
  ASSERT (SELECT count(*) FROM public.flujo_dinero WHERE tipo = 'REEMBOLSO' AND concepto LIKE 'Cambio devuelto de %') = 1, 'solo el cambio de s1';
END $$;
BEGIN;
SELECT public._m_como('martin.real@ejemplo.mx');
DO $$ DECLARE v jsonb; BEGIN
  v := public.flujo_recibir('SALIDA', 200, 'MXN', 'EFECTIVO', current_date, 'Proveedor W', NULL, 'Otra compra', NULL, NULL, 'Ana Gómez');
  INSERT INTO public._k_ids VALUES ('s3', (v->>'id')::uuid);
END $$;
RESET ROLE;
SELECT public._m_como('finanzas.real@ejemplo.mx');
SELECT public.flujo_confirmar_caja((SELECT id FROM public._k_ids WHERE clave = 's3'), (SELECT id FROM public.cuentas_financieras WHERE nombre = 'Caja chica'));
DO $$ DECLARE r jsonb; BEGIN
  r := public.flujo_comprobar((SELECT id FROM public._k_ids WHERE clave = 's3'), 200, 0);
  ASSERT r->>'cambio_folio' IS NULL, 'sin cambio no hay renglón de cambio';
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.flujo_dinero WHERE tipo = 'REEMBOLSO' AND concepto LIKE 'Cambio devuelto de %') = 1, 'sin cambio no se crea ingreso';
END $$;
COMMIT;
\echo 'OK: comprobación de efectivo en el flujo'

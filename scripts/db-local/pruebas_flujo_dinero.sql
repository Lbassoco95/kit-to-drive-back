-- ============================================================================
-- Pruebas (base de datos) del flujo de dinero en tres etapas.
--   PGHOST=/tmp/pgd PGPORT=5433 PGUSER=postgres scripts/db-local/probar_flujo_dinero.sh
-- Mismo método que pruebas_compras.sql: cada prueba entra como un usuario y se
-- revierte al final.
-- ============================================================================
\set ON_ERROR_STOP 1
SET client_min_messages = notice;

INSERT INTO auth.users (id, email, raw_app_meta_data)
SELECT id::uuid, email, '{"created_via_admin": "true"}'::jsonb FROM (VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'prueba.compras@dazon.demo'),
  ('00000000-0000-0000-0000-0000000000a2', 'prueba.almacen@dazon.demo'),
  ('00000000-0000-0000-0000-0000000000a3', 'prueba.finanzas@dazon.demo'),
  ('00000000-0000-0000-0000-0000000000a4', 'prueba.ventas@dazon.demo'),
  ('00000000-0000-0000-0000-0000000000a5', 'prueba.super@dazon.demo'),
  ('00000000-0000-0000-0000-0000000000a6', 'prueba.logistica@dazon.demo'),
  ('00000000-0000-0000-0000-0000000000b1', 'martin.real@ejemplo.mx'),
  ('00000000-0000-0000-0000-0000000000b3', 'almacen.real@ejemplo.mx'),
  ('00000000-0000-0000-0000-0000000000b4', 'admin.real@ejemplo.mx')
) AS u(id, email) ON CONFLICT (id) DO NOTHING;
INSERT INTO public.profiles (id, nombre_completo, activo, email)
SELECT id, split_part(email, '@', 1), true, email FROM auth.users
 WHERE id::text LIKE '00000000-0000-0000-0000-0000000000%' ON CONFLICT (id) DO NOTHING;
DELETE FROM public.user_roles WHERE user_id::text LIKE '00000000-0000-0000-0000-0000000000%';
INSERT INTO public.user_roles (user_id, role, area, nivel) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'compras',   'compras',           'operador'),
  ('00000000-0000-0000-0000-0000000000a2', 'logistica', 'almacen_logistica', 'operador'),
  ('00000000-0000-0000-0000-0000000000a3', 'finanzas',  'administracion',    'operador'),
  ('00000000-0000-0000-0000-0000000000a4', 'ventas',    'comercial',         'operador'),
  ('00000000-0000-0000-0000-0000000000a5', 'admin',     'direccion',         'admin'),
  ('00000000-0000-0000-0000-0000000000a6', 'logistica', 'almacen_logistica', 'operador'),
  ('00000000-0000-0000-0000-0000000000b1', 'compras',   'compras',           'operador'),
  ('00000000-0000-0000-0000-0000000000b3', 'logistica', 'almacen_logistica', 'operador'),
  ('00000000-0000-0000-0000-0000000000b4', 'admin',     'direccion',         'admin');
SELECT public.reiniciar_datos_prueba_compras('REINICIAR DATOS DE PRUEBA') IS NOT NULL AS sembrado;

CREATE OR REPLACE FUNCTION public._t_como(_email text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', (SELECT id::text FROM auth.users WHERE email = _email), true);
  EXECUTE 'SET LOCAL ROLE authenticated';
END $$;
CREATE OR REPLACE FUNCTION public._t_falla(_sql text, _patron text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE _sql;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM !~* _patron THEN RAISE EXCEPTION 'Falló con otro mensaje. Esperado /%/, llegó: %', _patron, SQLERRM; END IF;
    RETURN;
  END;
  RAISE EXCEPTION 'Debió fallar (esperado /%/): %', _patron, _sql;
END $$;
CREATE OR REPLACE FUNCTION public._t_uid(_email text) RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$
  SELECT id FROM auth.users WHERE email = _email $$;
CREATE OR REPLACE FUNCTION public._t_cli(_codigo text) RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$
  SELECT id FROM public.clientes WHERE codigo_erp = _codigo $$;
CREATE OR REPLACE FUNCTION public._t_cuenta_mxn() RETURNS TABLE (id uuid) LANGUAGE sql SECURITY DEFINER AS $$
  SELECT c.id FROM public.cuentas_financieras c WHERE c.moneda = 'MXN' AND c.tipo = 'EFECTIVO' AND c.activo ORDER BY c.orden LIMIT 1 $$;
CREATE OR REPLACE FUNCTION public._t_saldo(_cta uuid) RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$
  SELECT saldo_actual FROM public.v_saldos_cuentas WHERE id = _cta $$;
GRANT EXECUTE ON FUNCTION public._t_cuenta_mxn(), public._t_saldo(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public._t_como(text), public._t_falla(text, text), public._t_uid(text), public._t_cli(text) TO authenticated;

-- Quién hace qué: a1 recibe, a2 caja, a3 aplica (admin: a5).
\echo '1. Sólo un administrador asigna perfiles; sin el perfil no se puede la etapa'
BEGIN;
SELECT public._t_como('prueba.compras@dazon.demo');
DO $$ BEGIN
  PERFORM public._t_falla($q$SELECT public.flujo_asignar_perfil(public._t_uid('prueba.compras@dazon.demo'), 'recepcion_cobros', true)$q$, 'Sólo un administrador');
  PERFORM public._t_falla($q$SELECT public.flujo_recibir('PAGO_CLIENTE', 100, 'MXN', 'EFECTIVO', current_date, 'Juan', public._t_cli('TST-C02'))$q$, 'etapa de recepción');
END $$;
RESET ROLE;
SELECT public._t_como('prueba.super@dazon.demo');
SELECT public.flujo_asignar_perfil(public._t_uid('prueba.compras@dazon.demo'), 'recepcion_cobros', true);
SELECT public.flujo_asignar_perfil(public._t_uid('prueba.almacen@dazon.demo'), 'cajera', true);
SELECT public.flujo_asignar_perfil(public._t_uid('prueba.finanzas@dazon.demo'), 'aplicacion_cobranza', true);
SELECT public.flujo_asignar_perfil(public._t_uid('prueba.ventas@dazon.demo'), 'recepcion_cobros', true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.flujo_listar_perfiles() WHERE 'recepcion_cobros' = ANY (perfiles)) = 2, 'listado de perfiles';
END $$;
COMMIT;
-- (se confirma: las demás pruebas parten de estas asignaciones)

\echo '2. Pago de cliente: recibe → caja → aplica a remisiones, con separación de funciones'
BEGIN;
SELECT public._t_como('prueba.compras@dazon.demo');
CREATE TEMP TABLE t_fd (id uuid, rem uuid, pend numeric);
GRANT ALL ON t_fd TO authenticated;
DO $$
DECLARE v jsonb; v_rem uuid; v_pend numeric;
BEGIN
  SELECT id, saldo_pendiente INTO v_rem, v_pend FROM public.v_cobranza_remisiones
   WHERE es_prueba AND documento = 'confirmada' AND saldo_pendiente > 100 AND cliente_id = public._t_cli('TST-C02')
   ORDER BY fecha_remision LIMIT 1;
  ASSERT v_rem IS NOT NULL, 'se necesita una remisión de prueba con saldo';
  -- Validaciones de recepción.
  PERFORM public._t_falla($q$SELECT public.flujo_recibir('PAGO_CLIENTE', 100, 'USD', 'EFECTIVO', current_date, 'Juan', public._t_cli('TST-C02'), NULL, NULL, 17)$q$, 'MXN');
  PERFORM public._t_falla($q$SELECT public.flujo_recibir('PAGO_CLIENTE', 100, 'MXN', 'TRANSFERENCIA', current_date, 'Juan', public._t_cli('TST-C02'))$q$, 'referencia');
  PERFORM public._t_falla($q$SELECT public.flujo_recibir('PAGO_CLIENTE', 100, 'MXN', 'CHEQUE', current_date, 'Juan', public._t_cli('TST-C02'), NULL, 'CH1')$q$, 'efectivo, transferencia o depósito');
  PERFORM public._t_falla($q$SELECT public.flujo_recibir('PAGO_CLIENTE', 100, 'MXN', 'EFECTIVO', current_date, 'Juan', NULL)$q$, 'Elige el cliente');
  ASSERT (SELECT count(*) FROM public.flujo_clientes() WHERE codigo = 'TST-C02') = 1, 'recibe ve los clientes por flujo_clientes()';
  PERFORM public._t_falla($q$SELECT * FROM public.flujo_cuentas()$q$, 'etapa de caja');
  v := public.flujo_recibir('PAGO_CLIENTE', v_pend + 500, 'MXN', 'EFECTIVO', current_date, 'Juan Pérez', public._t_cli('TST-C02'));
  INSERT INTO t_fd VALUES ((v->>'id')::uuid, v_rem, v_pend);
  ASSERT (SELECT etapa FROM public.flujo_dinero WHERE id = (v->>'id')::uuid) = 'RECIBIDO';
  -- Quien recibió no mete su propio dinero a caja, ni lo aplica (aunque tuviera las capacidades).
  PERFORM public._t_falla(format('SELECT public.flujo_confirmar_caja(%L, (SELECT id FROM public._t_cuenta_mxn()))', (v->>'id')), 'No tienes asignada la etapa de caja');
END $$;
RESET ROLE;
-- Caja: otra persona.
SELECT public._t_como('prueba.almacen@dazon.demo');
DO $$
DECLARE v_id uuid := (SELECT id FROM t_fd); v_cta uuid; v_cta_usd uuid;
BEGIN
  SELECT c.id INTO v_cta FROM public.flujo_cuentas() c WHERE c.moneda = 'MXN' AND c.tipo = 'EFECTIVO' ORDER BY c.orden LIMIT 1;
  SELECT c.id INTO v_cta_usd FROM public.flujo_cuentas() c WHERE c.moneda <> 'MXN' LIMIT 1;
  ASSERT v_cta IS NOT NULL, 'caja ve las cuentas por flujo_cuentas()';
  PERFORM public._t_falla(format('SELECT public.flujo_aplicar(%L, ''REMISION'', ''[]'')', v_id), 'etapa de aplicación');
  IF v_cta_usd IS NOT NULL THEN
    PERFORM public._t_falla(format('SELECT public.flujo_confirmar_caja(%L, %L)', v_id, v_cta_usd), 'maneja');
  END IF;
  PERFORM public.flujo_confirmar_caja(v_id, v_cta, 'Contado completo');
  ASSERT (SELECT etapa FROM public.flujo_dinero WHERE id = v_id) = 'EN_CAJA';
  ASSERT (SELECT movimiento_id FROM public.flujo_dinero WHERE id = v_id) IS NULL, 'un flujo de prueba no escribe en el libro mayor real';
  PERFORM public._t_falla(format('SELECT public.flujo_confirmar_caja(%L, %L)', v_id, v_cta), 'no está pendiente de caja');
END $$;
RESET ROLE;
-- Aplicación: tercera persona.
SELECT public._t_como('prueba.finanzas@dazon.demo');
DO $$
DECLARE r t_fd%ROWTYPE; v jsonb; v_saldo numeric;
BEGIN
  SELECT * INTO r FROM t_fd;
  ASSERT (SELECT saldo_pendiente FROM public.flujo_remisiones_para_aplicar(r.id) WHERE id = r.rem) = r.pend, 'aplica ve las remisiones con saldo';
  PERFORM public._t_falla(format('SELECT public.flujo_aplicar(%L, ''GASTO'', ''[]'')', r.id), 'no corresponde');
  PERFORM public._t_falla(format('SELECT public.flujo_aplicar(%L, ''REMISION'', ''[]'')', r.id), 'al menos una remisión');
  PERFORM public._t_falla(format('SELECT public.flujo_aplicar(%L, ''REMISION'', %L)', r.id,
    jsonb_build_array(jsonb_build_object('remision_id', r.rem, 'monto', r.pend + 1))), 'le quedan');
  v := public.flujo_aplicar(r.id, 'REMISION', jsonb_build_array(jsonb_build_object('remision_id', r.rem, 'monto', r.pend)));
  ASSERT (v->>'aplicadas')::int = 1, 'una aplicación';
  ASSERT (SELECT saldo_pendiente FROM public.v_cobranza_remisiones WHERE id = r.rem) = 0, 'la remisión queda liquidada';
  SELECT coalesce(sum(monto), 0) INTO v_saldo FROM public.cobranza_saldos_favor WHERE pago_origen_id = (SELECT cobranza_pago_id FROM public.flujo_dinero WHERE id = r.id);
  ASSERT v_saldo = 500, format('el sobrante (500) queda como saldo a favor, hay %s', v_saldo);
  ASSERT (SELECT estatus FROM public.cobranza_pagos WHERE id = (SELECT cobranza_pago_id FROM public.flujo_dinero WHERE id = r.id)) = 'validado';
  ASSERT (SELECT etapa FROM public.flujo_dinero WHERE id = r.id) = 'APLICADO';
  PERFORM public._t_falla(format('SELECT public.flujo_rechazar(%L, ''ya aplicado'')', r.id), 'ya no se puede rechazar');
END $$;
ROLLBACK;

\echo '3. Separación de funciones: quien recibió o metió a caja no aplica'
BEGIN;
SELECT public._t_como('prueba.super@dazon.demo');
SELECT public.flujo_asignar_perfil(public._t_uid('prueba.compras@dazon.demo'), 'cajera', true);
SELECT public.flujo_asignar_perfil(public._t_uid('prueba.compras@dazon.demo'), 'aplicacion_cobranza', true);
RESET ROLE;
SELECT public._t_como('prueba.compras@dazon.demo');
CREATE TEMP TABLE t_fd2 (id uuid);
GRANT ALL ON t_fd2 TO authenticated;
DO $$
DECLARE v jsonb; v_cta uuid;
BEGIN
  v := public.flujo_recibir('REEMBOLSO', 250, 'MXN', 'EFECTIVO', current_date, 'Proveedor X', NULL, 'Devolución de proveedor');
  INSERT INTO t_fd2 VALUES ((v->>'id')::uuid);
  v_cta := (SELECT id FROM public._t_cuenta_mxn());
  PERFORM public._t_falla(format('SELECT public.flujo_confirmar_caja(%L, %L)', (v->>'id'), v_cta), 'no puede registrarlo en caja');
END $$;
RESET ROLE;
SELECT public._t_como('prueba.almacen@dazon.demo');
DO $$ DECLARE v_cta uuid; BEGIN
  v_cta := (SELECT id FROM public._t_cuenta_mxn());
  PERFORM public.flujo_confirmar_caja((SELECT id FROM t_fd2), v_cta);
END $$;
RESET ROLE;
-- a2 (caja) recibe además la capacidad de aplicar: aun así no aplica lo que metió.
SELECT public._t_como('prueba.super@dazon.demo');
SELECT public.flujo_asignar_perfil(public._t_uid('prueba.almacen@dazon.demo'), 'aplicacion_cobranza', true);
RESET ROLE;
SELECT public._t_como('prueba.almacen@dazon.demo');
DO $$ BEGIN
  PERFORM public._t_falla(format('SELECT public.flujo_aplicar(%L, ''REEMBOLSO_PROVEEDOR'')', (SELECT id FROM t_fd2)), 'tercera persona');
END $$;
RESET ROLE;
SELECT public._t_como('prueba.compras@dazon.demo');
DO $$ BEGIN
  PERFORM public._t_falla(format('SELECT public.flujo_aplicar(%L, ''REEMBOLSO_PROVEEDOR'')', (SELECT id FROM t_fd2)), 'tercera persona');
END $$;
RESET ROLE;
SELECT public._t_como('prueba.finanzas@dazon.demo');
DO $$ BEGIN
  PERFORM public.flujo_aplicar((SELECT id FROM t_fd2), 'REEMBOLSO_PROVEEDOR', '[]', 'clasificado');
  ASSERT (SELECT etapa FROM public.flujo_dinero WHERE id = (SELECT id FROM t_fd2)) = 'APLICADO', 'el reembolso se clasifica sin remisión';
END $$;
ROLLBACK;

\echo '4. Salida de dinero (usuarios reales: la caja sí se mueve) y rechazo en caja'
BEGIN;
SELECT public._t_como('admin.real@ejemplo.mx');
SELECT public.flujo_asignar_perfil(public._t_uid('martin.real@ejemplo.mx'), 'recepcion_cobros', true);
SELECT public.flujo_asignar_perfil(public._t_uid('almacen.real@ejemplo.mx'), 'cajera', true);
RESET ROLE;
SELECT public._t_como('martin.real@ejemplo.mx');
CREATE TEMP TABLE t_fd3 (id uuid, cta uuid, saldo0 numeric);
GRANT ALL ON t_fd3 TO authenticated;
DO $$
DECLARE v jsonb; v_cta uuid;
BEGIN
  v_cta := (SELECT id FROM public._t_cuenta_mxn());
  PERFORM public._t_falla($q$SELECT public.flujo_recibir('SALIDA', 900, 'MXN', 'EFECTIVO', current_date, 'Chofer', NULL)$q$, 'concepto');
  v := public.flujo_recibir('SALIDA', 900, 'MXN', 'EFECTIVO', current_date, 'Chofer', NULL, 'Viáticos');
  INSERT INTO t_fd3 VALUES ((v->>'id')::uuid, v_cta, public._t_saldo(v_cta));
END $$;
RESET ROLE;
SELECT public._t_como('almacen.real@ejemplo.mx');
DO $$ DECLARE r t_fd3%ROWTYPE; BEGIN
  SELECT * INTO r FROM t_fd3;
  PERFORM public.flujo_confirmar_caja(r.id, r.cta);
  ASSERT public._t_saldo(r.cta) = r.saldo0 - 900, 'la salida descuenta la caja';
  -- Q: la Cajera no ve el libro general ni la cobranza; solo cuentas y su cola por las funciones flujo_*.
  ASSERT (SELECT count(*) FROM public.movimientos_financieros) = 0, 'Q: la cajera no ve el libro general de movimientos';
  ASSERT (SELECT count(*) FROM public.cuentas_financieras) = 0, 'Q: la cajera no lee la tabla de cuentas (solo flujo_cuentas)';
  ASSERT (SELECT count(*) FROM public.cobranza_pagos) = 0 AND (SELECT count(*) FROM public.cobranza_aplicaciones) = 0, 'Q: la cajera no ve cobranza';
  ASSERT (SELECT count(*) FROM public.flujo_cuentas()) >= 1, 'Q: la cajera sí ve las cuentas por flujo_cuentas()';
  ASSERT NOT EXISTS (SELECT 1 FROM public.flujo_dinero WHERE etapa = 'EN_CAJA' AND caja_por <> auth.uid()), 'Q: la cajera no ve lo que otra confirmó';
  PERFORM public._t_falla(format('SELECT public.flujo_rechazar(%L, ''x'')', r.id), 'motivo');
  PERFORM public.flujo_rechazar(r.id, 'La entrega no se realizó');
  ASSERT public._t_saldo(r.cta) = r.saldo0, 'el rechazo devuelve el saldo';
  ASSERT (SELECT etapa FROM public.flujo_dinero WHERE id = r.id) = 'RECHAZADO';
END $$;
RESET ROLE;
-- Nada se escribe directo ni se borra.
SELECT public._t_como('admin.real@ejemplo.mx');
DO $$ BEGIN
  PERFORM public._t_falla($q$UPDATE public.flujo_dinero SET etapa = 'APLICADO'$q$, 'permission denied');
  PERFORM public._t_falla($q$DELETE FROM public.flujo_dinero$q$, 'permission denied');
END $$;
ROLLBACK;


\echo '5. Perfiles: O sin perfil no hay etapa · P retiro inmediato · R bitácora · relevo · tres perfiles'
BEGIN;
-- O: a6 (logística, sin perfil) no puede ninguna etapa.
SELECT public._t_como('prueba.logistica@dazon.demo');
DO $$ BEGIN
  PERFORM public._t_falla($q$SELECT public.flujo_recibir('REEMBOLSO', 100, 'MXN', 'EFECTIVO', current_date, 'Prov', NULL, 'Devolución')$q$, 'etapa de recepción');
  PERFORM public._t_falla($q$SELECT public.flujo_confirmar_caja(gen_random_uuid(), gen_random_uuid())$q$, 'etapa de caja');
  PERFORM public._t_falla($q$SELECT public.flujo_aplicar(gen_random_uuid(), 'OTRO')$q$, 'etapa de aplicación');
  PERFORM public._t_falla($q$SELECT public.flujo_asignar_perfil(public._t_uid('prueba.logistica@dazon.demo'), 'cajera', true)$q$, 'Sólo un administrador o administrador financiero');
  ASSERT (SELECT count(*) FROM public.flujo_dinero) = 0, 'O: sin perfil no ve el flujo';
  ASSERT (public.flujo_mis_capacidades()->>'caja')::boolean = false, 'O: sin perfil no tiene etapa';
END $$;
RESET ROLE;
-- Perfil inválido y solo catálogo.
SELECT public._t_como('prueba.super@dazon.demo');
DO $$ BEGIN
  PERFORM public._t_falla($q$SELECT public.flujo_asignar_perfil(public._t_uid('prueba.logistica@dazon.demo'), 'tesorero', true)$q$, 'Perfil inválido');
  ASSERT (SELECT count(*) FROM public.flujo_catalogo_perfiles()) = 3, 'tres perfiles en el catálogo';
END $$;
RESET ROLE;
-- Movimiento X recibido por prueba.compras (recepción).
SELECT public._t_como('prueba.compras@dazon.demo');
CREATE TEMP TABLE t_x (id uuid);
GRANT ALL ON t_x TO authenticated;
DO $$ DECLARE v jsonb; BEGIN
  v := public.flujo_recibir('REEMBOLSO', 100, 'MXN', 'EFECTIVO', current_date, 'Proveedor Relevo', NULL, 'Devolución relevo');
  INSERT INTO t_x VALUES ((v->>'id')::uuid);
  ASSERT (SELECT count(*) FROM public.flujo_dinero) >= 1, 'recepción ve lo que registró';
END $$;
RESET ROLE;
-- P: se retira el perfil de Cajera a prueba.almacen: pierde la etapa al instante.
SELECT public._t_como('prueba.almacen@dazon.demo');
DO $$ BEGIN
  ASSERT (public.flujo_mis_capacidades()->>'caja')::boolean, 'P: antes del retiro tiene caja';
  ASSERT (SELECT count(*) FROM public.flujo_dinero WHERE id = (SELECT id FROM t_x)) = 1, 'la cajera ve lo pendiente de caja';
END $$;
RESET ROLE;
SELECT public._t_como('prueba.super@dazon.demo');
SELECT public.flujo_asignar_perfil(public._t_uid('prueba.almacen@dazon.demo'), 'cajera', false);
RESET ROLE;
SELECT public._t_como('prueba.almacen@dazon.demo');
DO $$ BEGIN
  ASSERT (public.flujo_mis_capacidades()->>'caja')::boolean = false, 'P: tras el retiro ya no tiene caja';
  PERFORM public._t_falla(format('SELECT public.flujo_confirmar_caja(%L, (SELECT id FROM public._t_cuenta_mxn()))', (SELECT id FROM t_x)), 'etapa de caja');
  PERFORM public._t_falla($q$SELECT * FROM public.flujo_cuentas()$q$, 'etapa de caja');
  ASSERT (SELECT count(*) FROM public.flujo_dinero WHERE id = (SELECT id FROM t_x)) = 0, 'P: ya no ve la cola de caja';
END $$;
RESET ROLE;
-- Relevo: otra persona con el perfil continúa lo que quedó a medias.
SELECT public._t_como('prueba.super@dazon.demo');
SELECT public.flujo_asignar_perfil(public._t_uid('prueba.logistica@dazon.demo'), 'cajera', true);
RESET ROLE;
SELECT public._t_como('prueba.logistica@dazon.demo');
DO $$ BEGIN
  PERFORM public.flujo_confirmar_caja((SELECT id FROM t_x), (SELECT id FROM public._t_cuenta_mxn()), 'Relevo de caja');
  ASSERT (SELECT etapa FROM public.flujo_dinero WHERE id = (SELECT id FROM t_x)) = 'EN_CAJA', 'el relevo continuó el movimiento';
END $$;
RESET ROLE;
-- Aplicación: prueba.finanzas pierde el perfil; prueba.ventas (aplica) lo continúa.
SELECT public._t_como('prueba.super@dazon.demo');
SELECT public.flujo_asignar_perfil(public._t_uid('prueba.finanzas@dazon.demo'), 'aplicacion_cobranza', false);
SELECT public.flujo_asignar_perfil(public._t_uid('prueba.ventas@dazon.demo'), 'aplicacion_cobranza', true);
RESET ROLE;
SELECT public._t_como('prueba.finanzas@dazon.demo');
DO $$ BEGIN
  PERFORM public._t_falla(format('SELECT public.flujo_aplicar(%L, ''OTRO'')', (SELECT id FROM t_x)), 'etapa de aplicación');
END $$;
RESET ROLE;
SELECT public._t_como('prueba.ventas@dazon.demo');
DO $$ BEGIN
  -- prueba.ventas tiene Recepción y Aplicación: aplica lo que no recibió ni confirmó.
  PERFORM public.flujo_aplicar((SELECT id FROM t_x), 'REEMBOLSO_EMPLEADO', '[]', 'relevo de aplicación');
  ASSERT (SELECT etapa FROM public.flujo_dinero WHERE id = (SELECT id FROM t_x)) = 'APLICADO', 'el relevo de aplicación cerró el movimiento';
END $$;
RESET ROLE;
-- Tres perfiles en una sola persona: la separación por movimiento sigue.
SELECT public._t_como('prueba.super@dazon.demo');
SELECT public.flujo_asignar_perfil(public._t_uid('prueba.ventas@dazon.demo'), 'cajera', true);
RESET ROLE;
SELECT public._t_como('prueba.ventas@dazon.demo');
CREATE TEMP TABLE t_y (id uuid);
GRANT ALL ON t_y TO authenticated;
DO $$ DECLARE v jsonb; BEGIN
  ASSERT (public.flujo_mis_capacidades()->>'recibe')::boolean AND (public.flujo_mis_capacidades()->>'caja')::boolean
     AND (public.flujo_mis_capacidades()->>'aplica')::boolean, 'tiene los tres perfiles';
  v := public.flujo_recibir('REEMBOLSO', 50, 'MXN', 'EFECTIVO', current_date, 'Proveedor Y', NULL, 'Y');
  INSERT INTO t_y VALUES ((v->>'id')::uuid);
  PERFORM public._t_falla(format('SELECT public.flujo_confirmar_caja(%L, (SELECT id FROM public._t_cuenta_mxn()))', (v->>'id')), 'Quien recibió el dinero no puede registrarlo en caja');
END $$;
RESET ROLE;
SELECT public._t_como('prueba.logistica@dazon.demo');
DO $$ BEGIN PERFORM public.flujo_confirmar_caja((SELECT id FROM t_y), (SELECT id FROM public._t_cuenta_mxn())); END $$;
RESET ROLE;
SELECT public._t_como('prueba.ventas@dazon.demo');
DO $$ BEGIN
  PERFORM public._t_falla(format('SELECT public.flujo_aplicar(%L, ''OTRO'')', (SELECT id FROM t_y)), 'tercera persona');
END $$;
RESET ROLE;
-- Un usuario real no opera movimientos de prueba.
SELECT public._t_como('admin.real@ejemplo.mx');
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.flujo_dinero) = 0, 'L: el administrador real no ve movimientos de prueba';
  ASSERT NOT EXISTS (SELECT 1 FROM public.flujo_listar_perfiles() WHERE nombre LIKE 'prueba.%'), 'L: la lista de perfiles real no incluye usuarios de prueba';
END $$;
RESET ROLE;
-- R: bitácora de cambios de perfil.
SELECT public._t_como('prueba.super@dazon.demo');
DO $$ DECLARE b record; BEGIN
  SELECT * INTO b FROM public.usuario_perfiles_flujo_bitacora
   WHERE usuario_id = public._t_uid('prueba.almacen@dazon.demo') AND perfiles_despues = '{}' ORDER BY created_at DESC LIMIT 1;
  ASSERT b.id IS NOT NULL, 'R: el retiro quedó en la bitácora';
  ASSERT b.perfiles_antes = ARRAY['cajera'], format('R: perfil anterior, llegó %s', b.perfiles_antes);
  ASSERT b.actor_id = public._t_uid('prueba.super@dazon.demo') AND b.origen = 'app' AND b.created_at IS NOT NULL, 'R: quién y cuándo';
  ASSERT b.es_prueba, 'R: marcado de prueba';
END $$;
RESET ROLE;
-- La bitácora no se edita ni se borra, ni siquiera el dueño de la tabla.
DO $$ BEGIN
  PERFORM public._t_falla($q$UPDATE public.usuario_perfiles_flujo_bitacora SET actor = 'x'$q$, 'no se edita ni se borra');
  PERFORM public._t_falla($q$DELETE FROM public.usuario_perfiles_flujo_bitacora$q$, 'no se edita ni se borra');
END $$;
-- Nada de escribir perfiles directo ni por la función núcleo.
SELECT public._t_como('prueba.super@dazon.demo');
DO $$ BEGIN
  PERFORM public._t_falla($q$INSERT INTO public.usuario_perfiles_flujo (user_id, perfil) VALUES (gen_random_uuid(), 'cajera')$q$, 'permission denied');
  PERFORM public._t_falla($q$SELECT public.perfiles_flujo_fijar(NULL, 'x', 'app', public._t_uid('prueba.almacen@dazon.demo'), ARRAY['cajera'])$q$, 'permission denied');
END $$;
RESET ROLE;
-- Una sola fuente: ya no existe la marca por persona.
DO $$ BEGIN
  ASSERT to_regclass('public.flujo_capacidades') IS NULL, 'no queda flujo_capacidades';
  ASSERT to_regprocedure('public.flujo_asignar_capacidad(uuid,text,boolean)') IS NULL, 'no queda flujo_asignar_capacidad';
END $$;
ROLLBACK;

\echo 'OK: flujo de dinero'

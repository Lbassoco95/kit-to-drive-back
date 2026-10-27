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
  SELECT c.id FROM public.cuentas_financieras c WHERE c.moneda = 'MXN' AND c.tipo = 'EFECTIVO' AND c.activo AND c.es_prueba = public.es_usuario_prueba(auth.uid()) ORDER BY c.orden LIMIT 1 $$;
CREATE OR REPLACE FUNCTION public._t_saldo(_cta uuid) RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$
  SELECT saldo_actual FROM public.v_saldos_cuentas WHERE id = _cta $$;
CREATE OR REPLACE FUNCTION public._t_emp() RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$
  SELECT id FROM public.empresas_grupo WHERE activo AND es_prueba = public.es_usuario_prueba(auth.uid()) ORDER BY nombre LIMIT 1 $$;
GRANT EXECUTE ON FUNCTION public._t_emp() TO authenticated;
-- Recibir con evidencia (desde la unificación es obligatoria): envoltura para las pruebas.
CREATE OR REPLACE FUNCTION public._t_rec(_tipo text, _monto numeric, _moneda text, _metodo text, _fecha date, _contra text,
  _cliente uuid DEFAULT NULL, _concepto text DEFAULT NULL, _ref text DEFAULT NULL, _tc numeric DEFAULT NULL, _datos jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.flujo_recibir(_tipo, _monto, _moneda, _metodo, _fecha, _contra, _cliente, _concepto, _ref, _tc,
                              'prueba/comprobantes/comprobante.pdf', _datos, public._t_emp()) $$;
GRANT EXECUTE ON FUNCTION public._t_rec(text, numeric, text, text, date, text, uuid, text, text, numeric, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public._t_cuenta_mxn(), public._t_saldo(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public._t_como(text), public._t_falla(text, text), public._t_uid(text), public._t_cli(text) TO authenticated;

-- Quién hace qué: a1 recibe, a2 caja, a3 aplica (admin: a5).
\echo '1. Sólo un administrador asigna etapas; sin capacidad no se puede nada'
BEGIN;
SELECT public._t_como('prueba.compras@dazon.demo');
DO $$ BEGIN
  PERFORM public._t_falla($q$SELECT public.flujo_asignar_capacidad(public._t_uid('prueba.compras@dazon.demo'), 'recibe', true)$q$, 'Sólo un administrador');
  PERFORM public._t_falla($q$SELECT public._t_rec('PAGO_CLIENTE', 100, 'MXN', 'EFECTIVO', current_date, 'Juan', public._t_cli('TST-C02'))$q$, 'etapa de recepción');
END $$;
RESET ROLE;
SELECT public._t_como('prueba.super@dazon.demo');
SELECT public.flujo_asignar_capacidad(public._t_uid('prueba.compras@dazon.demo'), 'recibe', true);
SELECT public.flujo_asignar_capacidad(public._t_uid('prueba.almacen@dazon.demo'), 'caja', true);
SELECT public.flujo_asignar_capacidad(public._t_uid('prueba.finanzas@dazon.demo'), 'aplica', true);
SELECT public.flujo_asignar_capacidad(public._t_uid('prueba.ventas@dazon.demo'), 'recibe', true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.flujo_listar_capacidades() WHERE recibe) = 2, 'listado de capacidades';
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
  PERFORM public._t_falla($q$SELECT public._t_rec('PAGO_CLIENTE', 100, 'USD', 'EFECTIVO', current_date, 'Juan', public._t_cli('TST-C02'), NULL, NULL, 17)$q$, 'MXN');
  PERFORM public._t_falla($q$SELECT public._t_rec('PAGO_CLIENTE', 100, 'MXN', 'TRANSFERENCIA', current_date, 'Juan', public._t_cli('TST-C02'))$q$, 'referencia');
  PERFORM public._t_falla($q$SELECT public._t_rec('PAGO_CLIENTE', 100, 'MXN', 'CHEQUE', current_date, 'Juan', public._t_cli('TST-C02'), NULL, 'CH1')$q$, 'efectivo, transferencia o depósito');
  PERFORM public._t_falla($q$SELECT public._t_rec('PAGO_CLIENTE', 100, 'MXN', 'EFECTIVO', current_date, 'Juan', NULL)$q$, 'Elige el cliente');
  ASSERT (SELECT count(*) FROM public.flujo_clientes() WHERE codigo = 'TST-C02') = 1, 'recibe ve los clientes por flujo_clientes()';
  PERFORM public._t_falla($q$SELECT * FROM public.flujo_cuentas()$q$, 'etapa de caja');
  v := public._t_rec('PAGO_CLIENTE', v_pend + 500, 'MXN', 'EFECTIVO', current_date, 'Juan Pérez', public._t_cli('TST-C02'));
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
SELECT public.flujo_asignar_capacidad(public._t_uid('prueba.compras@dazon.demo'), 'caja', true);
SELECT public.flujo_asignar_capacidad(public._t_uid('prueba.compras@dazon.demo'), 'aplica', true);
RESET ROLE;
SELECT public._t_como('prueba.compras@dazon.demo');
CREATE TEMP TABLE t_fd2 (id uuid);
GRANT ALL ON t_fd2 TO authenticated;
DO $$
DECLARE v jsonb; v_cta uuid;
BEGIN
  v := public._t_rec('REEMBOLSO', 250, 'MXN', 'EFECTIVO', current_date, 'Proveedor X', NULL, 'Devolución de proveedor');
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
SELECT public.flujo_asignar_capacidad(public._t_uid('prueba.almacen@dazon.demo'), 'aplica', true);
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
SELECT public.flujo_asignar_capacidad(public._t_uid('martin.real@ejemplo.mx'), 'recibe', true);
SELECT public.flujo_asignar_capacidad(public._t_uid('almacen.real@ejemplo.mx'), 'caja', true);
RESET ROLE;
SELECT public._t_como('martin.real@ejemplo.mx');
-- Los gastos y salidas ya no pasan por Recibe: tienen su propia captura (pestaña Gastos).
DO $$ BEGIN
  PERFORM public._t_falla($q$SELECT public._t_rec('SALIDA', 900, 'MXN', 'EFECTIVO', current_date, 'Chofer', NULL, 'Viáticos')$q$, 'pestaña Gastos');
END $$;
RESET ROLE;
-- Nada se escribe directo ni se borra.
SELECT public._t_como('admin.real@ejemplo.mx');
DO $$ BEGIN
  PERFORM public._t_falla($q$UPDATE public.flujo_dinero SET etapa = 'APLICADO'$q$, 'permission denied');
  PERFORM public._t_falla($q$DELETE FROM public.flujo_dinero$q$, 'permission denied');
END $$;
ROLLBACK;


\echo '5. Regla de cuenta por método de pago (efectivo→efectivo; transferencia y depósito→banco)'
BEGIN;
SELECT public._t_como('prueba.compras@dazon.demo');
CREATE TEMP TABLE t_m (id_ef uuid, id_tr uuid, id_dep uuid);
GRANT ALL ON t_m TO authenticated;
DO $$ DECLARE a jsonb; b jsonb; d jsonb; BEGIN
  a := public._t_rec('REEMBOLSO', 10, 'MXN', 'EFECTIVO', current_date, 'Prov', NULL, 'Efectivo');
  b := public._t_rec('REEMBOLSO', 20, 'MXN', 'TRANSFERENCIA', current_date, 'Prov', NULL, 'Transferencia', 'REF-1');
  d := public._t_rec('REEMBOLSO', 30, 'MXN', 'DEPOSITO', current_date, 'Prov', NULL, 'Depósito', 'REF-2');
  INSERT INTO t_m VALUES ((a->>'id')::uuid, (b->>'id')::uuid, (d->>'id')::uuid);
END $$;
RESET ROLE;
SELECT public._t_como('prueba.almacen@dazon.demo');
DO $$
DECLARE r t_m%ROWTYPE; v_ef uuid; v_bco uuid;
BEGIN
  SELECT * INTO r FROM t_m;
  SELECT c.id INTO v_ef  FROM public.flujo_cuentas() c WHERE c.moneda = 'MXN' AND c.tipo = 'EFECTIVO' ORDER BY c.orden LIMIT 1;
  SELECT c.id INTO v_bco FROM public.flujo_cuentas() c WHERE c.moneda = 'MXN' AND c.tipo = 'BANCO'    ORDER BY c.orden LIMIT 1;
  ASSERT v_ef IS NOT NULL AND v_bco IS NOT NULL, 'se necesita una caja de efectivo y una cuenta de banco en MXN';
  -- Efectivo en banco, transferencia y depósito en caja: rechazados, en español y chino.
  PERFORM public._t_falla(format('SELECT public.flujo_confirmar_caja(%L, %L)', r.id_ef, v_bco), 'solo se registra en una caja de efectivo.*现金只能登记在现金账户');
  PERFORM public._t_falla(format('SELECT public.flujo_confirmar_caja(%L, %L)', r.id_tr, v_ef), 'solo se registran en una cuenta de banco.*转账和存款只能登记在银行账户');
  PERFORM public._t_falla(format('SELECT public.flujo_confirmar_caja(%L, %L)', r.id_dep, v_ef), 'solo se registran en una cuenta de banco');
  ASSERT (SELECT etapa FROM public.flujo_dinero WHERE id = r.id_ef) = 'RECIBIDO', 'un rechazo no mueve el movimiento';
  -- Cada método en su cuenta: pasa.
  PERFORM public.flujo_confirmar_caja(r.id_ef,  v_ef);
  PERFORM public.flujo_confirmar_caja(r.id_tr,  v_bco, 'Contra estado de cuenta');
  PERFORM public.flujo_confirmar_caja(r.id_dep, v_bco);
  ASSERT (SELECT count(*) FROM public.flujo_dinero WHERE id IN (r.id_ef, r.id_tr, r.id_dep) AND etapa = 'EN_CAJA') = 3, 'los tres quedan en caja';
END $$;
ROLLBACK;

\echo 'OK: flujo de dinero'

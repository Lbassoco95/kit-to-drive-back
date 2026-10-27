-- ============================================================================
-- Pruebas (base de datos) de la unificación de Control financiero y flujo de dinero.
--   PGHOST=127.0.0.1 PGUSER=postgres scripts/db-local/probar_unificacion.sh
-- Cada prueba entra como un usuario; todo se revierte al final de cada bloque.
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
-- Recibir con evidencia (desde la unificación es obligatoria): envoltura para las pruebas.
CREATE OR REPLACE FUNCTION public._t_rec(_tipo text, _monto numeric, _moneda text, _metodo text, _fecha date, _contra text,
  _cliente uuid DEFAULT NULL, _concepto text DEFAULT NULL, _ref text DEFAULT NULL, _tc numeric DEFAULT NULL, _datos jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.flujo_recibir(_tipo, _monto, _moneda, _metodo, _fecha, _contra, _cliente, _concepto, _ref, _tc,
                              'prueba/comprobantes/comprobante.pdf', _datos) $$;
GRANT EXECUTE ON FUNCTION public._t_rec(text, numeric, text, text, date, text, uuid, text, text, numeric, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public._t_cuenta_mxn(), public._t_saldo(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public._t_como(text), public._t_falla(text, text), public._t_uid(text), public._t_cli(text) TO authenticated;

CREATE OR REPLACE FUNCTION public._t_banco() RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$
  SELECT id FROM public.cuentas_financieras WHERE moneda = 'MXN' AND tipo = 'BANCO' AND activo ORDER BY orden LIMIT 1 $$;
GRANT EXECUTE ON FUNCTION public._t_banco() TO authenticated;

-- Etapas: martin.real recibe · almacen.real caja · admin.real aplica (y administra) · prueba.* como en el flujo.
BEGIN;
SELECT public._t_como('admin.real@ejemplo.mx');
SELECT public.flujo_asignar_capacidad(public._t_uid('martin.real@ejemplo.mx'), 'recibe', true);
SELECT public.flujo_asignar_capacidad(public._t_uid('almacen.real@ejemplo.mx'), 'caja', true);
SELECT public.flujo_asignar_capacidad(public._t_uid('admin.real@ejemplo.mx'), 'aplica', true);
RESET ROLE;
SELECT public._t_como('prueba.super@dazon.demo');
SELECT public.flujo_asignar_capacidad(public._t_uid('prueba.compras@dazon.demo'), 'recibe', true);
SELECT public.flujo_asignar_capacidad(public._t_uid('prueba.almacen@dazon.demo'), 'caja', true);
SELECT public.flujo_asignar_capacidad(public._t_uid('prueba.finanzas@dazon.demo'), 'aplica', true);
RESET ROLE;
COMMIT;

\echo '1. Las otras puertas están cerradas: ni finanzas ni administrador insertan movimientos, pagos ni abonos directos'
BEGIN;
SELECT public._t_como('prueba.finanzas@dazon.demo');
DO $$ BEGIN
  PERFORM public._t_falla($q$INSERT INTO public.movimientos_financieros (tipo, estatus, concepto, monto, moneda, fecha_movimiento, metodo_pago, contraparte_tipo, contraparte_nombre, created_by, origen)
    VALUES ('INGRESO', 'PENDIENTE', 'x', 10, 'MXN', current_date, 'EFECTIVO', 'OTRO', 'x', auth.uid(), 'FLUJO')$q$, 'permission denied');
  PERFORM public._t_falla($q$UPDATE public.movimientos_financieros SET monto = 1$q$, 'permission denied');
  PERFORM public._t_falla($q$DELETE FROM public.movimientos_financieros$q$, 'permission denied');
  PERFORM public._t_falla($q$INSERT INTO public.cxc_abonos (cxc_id, monto, fecha_abono, created_by) VALUES (gen_random_uuid(), 1, current_date, auth.uid())$q$, 'permission denied');
  PERFORM public._t_falla($q$UPDATE public.cxc_abonos SET monto = 1$q$, 'permission denied');
  PERFORM public._t_falla($q$INSERT INTO public.cobranza_pagos (folio, cliente_id, fecha, monto, forma, estatus) VALUES ('X', gen_random_uuid(), current_date, 1, 'efectivo', 'validado')$q$, 'permission denied');
  PERFORM public._t_falla($q$SELECT public.registrar_pago_cobranza('{}'::jsonb)$q$, 'permission denied');
  PERFORM public._t_falla($q$SELECT public.validar_pago_cobranza(gen_random_uuid(), true, 'x')$q$, 'permission denied');
  PERFORM public._t_falla($q$SELECT public.aplicar_pago_cobranza(gen_random_uuid(), '[]'::jsonb, true, 'x')$q$, 'permission denied');
END $$;
RESET ROLE;
SELECT public._t_como('admin.real@ejemplo.mx');
DO $$ BEGIN
  PERFORM public._t_falla($q$INSERT INTO public.movimientos_financieros (tipo, estatus, concepto, monto, moneda, fecha_movimiento, metodo_pago, contraparte_tipo, contraparte_nombre, created_by, origen)
    VALUES ('INGRESO', 'CONFIRMADO', 'directo', 99999, 'MXN', current_date, 'EFECTIVO', 'OTRO', 'x', auth.uid(), 'FLUJO')$q$, 'permission denied');
  PERFORM public._t_falla($q$DELETE FROM public.movimientos_financieros$q$, 'permission denied');
  PERFORM public._t_falla($q$SELECT public.registrar_pago_cobranza('{}'::jsonb)$q$, 'permission denied');
  PERFORM public._t_falla($q$SELECT public.aplicar_pago_cobranza(gen_random_uuid(), '[]'::jsonb, true, 'x')$q$, 'permission denied');
  -- El saldo inicial de una cuenta pasa la política (administrador financiero) pero el candado lo frena.
  PERFORM public._t_falla($q$UPDATE public.cuentas_financieras SET saldo_inicial = 1000000$q$, 'no se edita directo|permission denied');
END $$;
RESET ROLE;
-- Ni el dueño de la base inserta en el libro sin pasar por Caja; nada se borra.
INSERT INTO public.clientes (nombre_comercial, razon_social, codigo_erp, es_prueba) VALUES ('Cliente Real CxC', 'CLIENTE REAL CXC SA', 'REAL-CXC', false);
INSERT INTO public.cuentas_por_cobrar (cliente_id, concepto, monto, saldo, moneda, fecha_emision, fecha_vencimiento, estatus)
  SELECT id, 'Crédito de prueba', 1000, 1000, 'MXN', current_date, current_date + 30, 'ABIERTA' FROM public.clientes WHERE codigo_erp = 'REAL-CXC';
DO $$ BEGIN
  PERFORM public._t_falla($q$INSERT INTO public.movimientos_financieros (tipo, estatus, concepto, monto, moneda, fecha_movimiento, metodo_pago, contraparte_tipo, contraparte_nombre, origen)
    VALUES ('INGRESO', 'CONFIRMADO', 'x', 10, 'MXN', current_date, 'EFECTIVO', 'OTRO', 'x', 'HISTORICO_DIRECTO')$q$, 'solo recibe dinero cuando Caja');
  PERFORM public._t_falla($q$INSERT INTO public.cxc_abonos (cxc_id, monto, fecha_abono) SELECT id, 1, current_date FROM public.cuentas_por_cobrar LIMIT 1$q$, 'nacen solo del flujo');
  PERFORM public._t_falla($q$UPDATE public.cuentas_por_cobrar SET saldo = 0$q$, 'no se editan');
END $$;
ROLLBACK;

\echo '2. La evidencia es obligatoria; no se aceptan datos fuera de la lista'
BEGIN;
SELECT public._t_como('martin.real@ejemplo.mx');
DO $$ BEGIN
  PERFORM public._t_falla($q$SELECT public.flujo_recibir('REEMBOLSO', 100, 'MXN', 'EFECTIVO', current_date, 'Prov', NULL, 'Devolución')$q$, 'Sin evidencia no se registra');
  PERFORM public._t_falla($q$SELECT public.flujo_recibir('REEMBOLSO', 100, 'MXN', 'EFECTIVO', current_date, 'Prov', NULL, 'Devolución', NULL, NULL, '  ')$q$, 'Sin evidencia no se registra');
  PERFORM public._t_falla($q$SELECT public._t_rec('REEMBOLSO', 100, 'MXN', 'EFECTIVO', current_date, 'Prov', NULL, 'Devolución', NULL, NULL, '{"monto": 5}'::jsonb)$q$, 'Datos no permitidos');
  PERFORM public.flujo_recibir('REEMBOLSO', 100, 'MXN', 'TRANSFERENCIA', current_date, 'Prov', NULL, 'Devolución', 'REF-9', NULL, 'comprobantes/transferencia.jpg');
  ASSERT (SELECT evidencia_tipo FROM public.flujo_dinero ORDER BY created_at DESC LIMIT 1) = 'transferencia', 'tipo de evidencia derivado del método';
END $$;
ROLLBACK;

\echo '3. Una salida real: Caja crea el libro con origen y evidencia; Aplica clasifica; se comprueba; historial completo'
BEGIN;
CREATE TEMP TABLE t_s (flujo uuid, mov uuid, saldo0 numeric, cta uuid);
GRANT ALL ON t_s TO authenticated;
SELECT public._t_como('martin.real@ejemplo.mx');
DO $$ DECLARE v jsonb; BEGIN
  v := public._t_rec('SALIDA', 900, 'MXN', 'EFECTIVO', current_date, 'Chofer', NULL, 'Viáticos', NULL, NULL,
        '{"categoria": "Viáticos", "requiere_comprobacion": true, "factura_folio": "A-1"}'::jsonb);
  INSERT INTO t_s (flujo, cta, saldo0) VALUES ((v->>'id')::uuid, (SELECT id FROM public._t_cuenta_mxn()), public._t_saldo((SELECT id FROM public._t_cuenta_mxn())));
  ASSERT (SELECT saldo0 FROM t_s) = public._t_saldo((SELECT cta FROM t_s)), 'lo recibido no mueve la caja';
END $$;
RESET ROLE;
SELECT public._t_como('almacen.real@ejemplo.mx');
DO $$ DECLARE t t_s%ROWTYPE; BEGIN
  SELECT * INTO t FROM t_s;
  PERFORM public.flujo_confirmar_caja(t.flujo, t.cta, 'Entregado');
  ASSERT (SELECT count(*) FROM public.movimientos_financieros) = 0, 'la cajera no ve el libro general';
END $$;
RESET ROLE;
SELECT public._t_como('admin.real@ejemplo.mx');
DO $$ DECLARE t t_s%ROWTYPE; m public.movimientos_financieros%ROWTYPE; BEGIN
  SELECT * INTO t FROM t_s;
  SELECT * INTO m FROM public.movimientos_financieros WHERE flujo_id = t.flujo;
  UPDATE t_s SET mov = m.id;
  t.mov := m.id;
  ASSERT m.origen = 'FLUJO' AND m.estatus = 'CONFIRMADO' AND m.tipo = 'EGRESO' AND m.monto = 900, 'el libro nace en Caja, confirmado';
  ASSERT m.categoria = 'Viáticos' AND m.requiere_comprobacion AND m.factura_folio = 'A-1', 'los datos de Recibe llegan al libro';
  ASSERT m.descripcion LIKE 'Flujo de dinero FD-%', 'el libro muestra su folio FD';
  ASSERT (SELECT tipo_documento::text FROM public.movimiento_adjuntos WHERE movimiento_id = m.id) = 'VALE_EFECTIVO', 'la evidencia queda en el expediente';
  ASSERT public._t_saldo(t.cta) = t.saldo0 - 900, 'la salida baja la caja';
  ASSERT (SELECT flujo_folio FROM public.v_movimientos_financieros WHERE id = t.mov) LIKE 'FD-%', 'Control financiero muestra el folio del flujo';
  ASSERT (SELECT flujo_etapa FROM public.v_movimientos_financieros WHERE id = t.mov) = 'EN_CAJA', 'y su etapa';
  ASSERT (SELECT origen FROM public.v_movimientos_financieros WHERE id = t.mov) = 'FLUJO', 'y su origen';
END $$;
DO $$ DECLARE t t_s%ROWTYPE; BEGIN
  SELECT * INTO t FROM t_s;
  PERFORM public.flujo_aplicar(t.flujo, 'GASTO', '[]'::jsonb, 'Viáticos del chofer', '{"categoria": "Gastos de viaje"}'::jsonb);
  ASSERT (SELECT categoria FROM public.movimientos_financieros WHERE id = t.mov) = 'Gastos de viaje', 'Aplica clasifica el libro';
  ASSERT (SELECT etapa FROM public.flujo_dinero WHERE id = t.flujo) = 'APLICADO', 'aplicado';
  -- Comprobación de efectivo por RPC.
  PERFORM public._t_falla(format($q$SELECT public.movimiento_comprobar(%L, 900, 100)$q$, t.mov), 'no puede superar');
  PERFORM public.movimiento_comprobar(t.mov, 800, 100);
  ASSERT (SELECT comprobado FROM public.movimientos_financieros WHERE id = t.mov), 'comprobado';
  PERFORM public._t_falla(format($q$SELECT public.movimiento_comprobar(%L, 1, 0)$q$, t.mov), 'ya está comprobado');
  -- Corrección: solo lo no monetario, con motivo, y queda en la bitácora.
  PERFORM public._t_falla(format($q$SELECT public.movimiento_ajustar(%L, '{"monto": 1}'::jsonb, 'cambio de monto')$q$, t.mov), 'No se ajusta');
  PERFORM public._t_falla(format($q$SELECT public.movimiento_ajustar(%L, '{"categoria": "x"}'::jsonb, 'x')$q$, t.mov), 'motivo');
  PERFORM public.movimiento_ajustar(t.mov, '{"descripcion": "Aclarado por Finanzas"}'::jsonb, 'Aclaración de la descripción');
  ASSERT (SELECT descripcion FROM public.movimientos_financieros WHERE id = t.mov) = 'Aclarado por Finanzas', 'ajuste no monetario';
  ASSERT EXISTS (SELECT 1 FROM public.movimiento_bitacora WHERE movimiento_id = t.mov AND accion = 'AJUSTADO'), 'el ajuste queda en la bitácora';
  -- Aplicado: no se cancela el libro sin revertir antes.
  PERFORM public._t_falla(format($q$SELECT public.movimiento_cancelar(%L, 'Cancelación de prueba')$q$, t.mov), 'revierte primero');
  -- Historial: quién y cuándo en cada etapa.
  ASSERT (SELECT array_agg(accion ORDER BY created_at, accion) FROM public.v_flujo_dinero_eventos WHERE flujo_id = t.flujo) @> ARRAY['RECIBIDO', 'CAJA_CONFIRMADA', 'APLICADO'], 'historial completo';
  ASSERT (SELECT count(DISTINCT usuario_id) FROM public.v_flujo_dinero_eventos WHERE flujo_id = t.flujo) = 3, 'tres personas distintas';
  ASSERT (SELECT recibido_por_nombre IS NOT NULL AND caja_por_nombre IS NOT NULL AND aplicado_por_nombre IS NOT NULL FROM public.v_flujo_dinero WHERE id = t.flujo), 'quién recibió, confirmó y aplicó';
END $$;
RESET ROLE;
SELECT public._t_como('martin.real@ejemplo.mx');
DO $$ DECLARE t t_s%ROWTYPE; BEGIN
  SELECT * INTO t FROM t_s;
  PERFORM public._t_falla(format($q$SELECT public.movimiento_cancelar(%L, 'Cancelación de prueba')$q$, t.mov), 'administrador financiero');
  PERFORM public._t_falla(format($q$SELECT public.movimiento_ajustar(%L, '{"categoria": "x"}'::jsonb, 'Intento de ajuste')$q$, t.mov), 'administrador financiero');
END $$;
RESET ROLE;
ROLLBACK;

\echo '4. Libro solo con lo confirmado; lo recibido va «en tránsito»; rechazado y revertido quedan visibles con motivo'
BEGIN;
CREATE TEMP TABLE t_z (flujo uuid, mov uuid, saldo0 numeric, cta uuid, flujo2 uuid);
GRANT ALL ON t_z TO authenticated;
SELECT public._t_como('martin.real@ejemplo.mx');
DO $$ DECLARE v jsonb; BEGIN
  INSERT INTO t_z (cta, saldo0) VALUES ((SELECT id FROM public._t_cuenta_mxn()), public._t_saldo((SELECT id FROM public._t_cuenta_mxn())));
  v := public._t_rec('REEMBOLSO', 500, 'MXN', 'EFECTIVO', current_date, 'Proveedor Z', NULL, 'Devolución Z');
  UPDATE t_z SET flujo = (v->>'id')::uuid;
  v := public._t_rec('REEMBOLSO', 70, 'MXN', 'EFECTIVO', current_date, 'Proveedor W', NULL, 'Devolución W');
  UPDATE t_z SET flujo2 = (v->>'id')::uuid;
END $$;
RESET ROLE;
SELECT public._t_como('admin.real@ejemplo.mx');
DO $$ DECLARE z t_z%ROWTYPE; BEGIN
  SELECT * INTO z FROM t_z;
  ASSERT (SELECT monto FROM public.v_flujo_en_transito WHERE moneda = 'MXN' AND tipo = 'INGRESO') = 570, 'lo recibido aparece en tránsito';
  ASSERT public._t_saldo(z.cta) = z.saldo0, 'y no está en el saldo de caja';
  ASSERT (SELECT count(*) FROM public.movimientos_financieros WHERE flujo_id IN (z.flujo, z.flujo2)) = 0, 'ni en el libro';
END $$;
RESET ROLE;
SELECT public._t_como('almacen.real@ejemplo.mx');
DO $$ DECLARE z t_z%ROWTYPE; BEGIN
  SELECT * INTO z FROM t_z;
  PERFORM public.flujo_confirmar_caja(z.flujo, z.cta);
  PERFORM public.flujo_confirmar_caja(z.flujo2, z.cta);
  ASSERT public._t_saldo(z.cta) = z.saldo0 + 570, 'confirmado por Caja: ya cuenta';
END $$;
RESET ROLE;
SELECT public._t_como('admin.real@ejemplo.mx');
DO $$ DECLARE z t_z%ROWTYPE; BEGIN
  SELECT * INTO z FROM t_z;
  UPDATE t_z SET mov = (SELECT id FROM public.movimientos_financieros WHERE flujo_id = z.flujo);
  z.mov := (SELECT mov FROM t_z);
  ASSERT NOT EXISTS (SELECT 1 FROM public.v_flujo_en_transito), 'ya nada en tránsito';
  -- Rechazo en caja: el libro cancela con motivo y el flujo lo muestra; nada se borra.
  PERFORM public.flujo_rechazar(z.flujo2, 'El proveedor no devolvió el dinero');
  ASSERT public._t_saldo(z.cta) = z.saldo0 + 500, 'el rechazo en caja devuelve el saldo';
  ASSERT (SELECT estatus::text FROM public.movimientos_financieros WHERE flujo_id = z.flujo2) = 'CANCELADO', 'el libro conserva el movimiento cancelado';
  ASSERT (SELECT motivo_cancelacion FROM public.movimientos_financieros WHERE flujo_id = z.flujo2) LIKE '%no devolvió%', 'con su motivo';
  ASSERT (SELECT etapa || '/' || motivo_rechazo FROM public.v_flujo_dinero WHERE id = z.flujo2) = 'RECHAZADO/El proveedor no devolvió el dinero', 'el flujo lo muestra rechazado';
  -- Cancelar por Control financiero (administrador financiero): el flujo queda REVERTIDO.
  PERFORM public._t_falla(format($q$SELECT public.movimiento_cancelar(%L, 'x')$q$, z.mov), 'motivo');
  PERFORM public.movimiento_cancelar(z.mov, 'Cancelado por Finanzas: depósito no localizado');
  ASSERT public._t_saldo(z.cta) = z.saldo0, 'cancelar restaura la caja';
  ASSERT (SELECT etapa || '/' || reversa_motivo FROM public.v_flujo_dinero WHERE id = z.flujo) = 'REVERTIDO/Cancelado por Finanzas: depósito no localizado', 'el flujo queda revertido con motivo';
  ASSERT (SELECT accion FROM public.v_flujo_dinero_eventos WHERE flujo_id = z.flujo ORDER BY created_at DESC LIMIT 1) = 'LIBRO_CANCELADO', 'queda en el historial';
  PERFORM public._t_falla(format($q$SELECT public.movimiento_cancelar(%L, 'Otra vez cancelado')$q$, z.mov), 'ya está cancelado');
  ASSERT (SELECT count(*) FROM public.movimientos_financieros WHERE flujo_id IN (z.flujo, z.flujo2)) = 2, 'nada se borró';
END $$;
RESET ROLE;
ROLLBACK;

\echo '5. Cuenta por cobrar: el abono nace del flujo, ligado al libro; reversa de la aplicación y del pago'
BEGIN;
INSERT INTO public.clientes (nombre_comercial, razon_social, codigo_erp, es_prueba) VALUES ('Cliente Real CxC', 'CLIENTE REAL CXC SA', 'REAL-CXC', false);
INSERT INTO public.clientes (nombre_comercial, razon_social, codigo_erp, es_prueba) VALUES ('Otro Cliente Real', 'OTRO SA', 'REAL-OTRO', false);
INSERT INTO public.cuentas_por_cobrar (cliente_id, concepto, monto, saldo, moneda, fecha_emision, fecha_vencimiento, estatus)
  SELECT id, 'Crédito de prueba', 1000, 1000, 'MXN', current_date, current_date + 30, 'ABIERTA' FROM public.clientes WHERE codigo_erp = 'REAL-CXC';
CREATE TEMP TABLE t_x (flujo uuid, mov uuid, cxc uuid, banco uuid, saldo0 numeric);
GRANT ALL ON t_x TO authenticated;
SELECT public._t_como('martin.real@ejemplo.mx');
DO $$ DECLARE v jsonb; BEGIN
  v := public._t_rec('PAGO_CLIENTE', 1200, 'MXN', 'TRANSFERENCIA', current_date, 'Cliente Real', public._t_cli('REAL-CXC'), NULL, 'SPEI-77');
  INSERT INTO t_x (flujo, cxc, banco, saldo0)
    VALUES ((v->>'id')::uuid, (SELECT id FROM public.cuentas_por_cobrar WHERE concepto = 'Crédito de prueba'), public._t_banco(), public._t_saldo(public._t_banco()));
END $$;
RESET ROLE;
SELECT public._t_como('almacen.real@ejemplo.mx');
DO $$ DECLARE x t_x%ROWTYPE; BEGIN
  SELECT * INTO x FROM t_x;
  PERFORM public.flujo_confirmar_caja(x.flujo, x.banco, 'Contra estado de cuenta');
  ASSERT public._t_saldo(x.banco) = x.saldo0 + 1200, 'Caja confirma en el banco';
END $$;
RESET ROLE;
SELECT public._t_como('admin.real@ejemplo.mx');
DO $$ DECLARE x t_x%ROWTYPE; v jsonb; BEGIN
  SELECT * INTO x FROM t_x;
  UPDATE t_x SET mov = (SELECT id FROM public.movimientos_financieros WHERE flujo_id = x.flujo);
  x.mov := (SELECT mov FROM t_x);
  PERFORM public._t_falla(format($q$SELECT public.flujo_aplicar(%L, 'CXC', '[]'::jsonb)$q$, x.flujo), 'al menos una cuenta por cobrar');
  PERFORM public._t_falla(format($q$SELECT public.flujo_aplicar(%L, 'CXC', %L)$q$, x.flujo, jsonb_build_array(jsonb_build_object('cxc_id', x.cxc, 'monto', 1100))), 'le quedan');
  PERFORM public._t_falla(format($q$SELECT public.flujo_aplicar(%L, 'GASTO', '[]'::jsonb)$q$, x.flujo), 'no corresponde');
  v := public.flujo_aplicar(x.flujo, 'CXC', jsonb_build_array(jsonb_build_object('cxc_id', x.cxc, 'monto', 1000)), 'Abono de octubre');
  ASSERT (v->>'aplicadas')::int = 1 AND v->>'saldo_favor' IS NOT NULL, 'un abono y el remanente a saldo a favor';
  ASSERT (SELECT saldo || '/' || estatus FROM public.cuentas_por_cobrar WHERE id = x.cxc) = '0.00/PAGADA', 'la cuenta por cobrar queda pagada';
  ASSERT (SELECT origen || '/' || (movimiento_id = x.mov)::text || '/' || (flujo_id = x.flujo)::text FROM public.cxc_abonos WHERE cxc_id = x.cxc) = 'FLUJO/true/true', 'el abono liga al libro y al flujo';
  ASSERT (SELECT monto FROM public.cobranza_saldos_favor WHERE flujo_id = x.flujo AND cancelado_at IS NULL) = 200, 'remanente a saldo a favor';
  ASSERT (SELECT destino FROM public.flujo_dinero WHERE id = x.flujo) = 'CXC', 'destino CXC';
END $$;
-- Reversa de la aplicación: «En caja, por aplicar»; el libro no cambia.
DO $$ DECLARE x t_x%ROWTYPE; BEGIN
  SELECT * INTO x FROM t_x;
  PERFORM public._t_falla(format($q$SELECT public.flujo_revertir(%L, 'x')$q$, x.flujo), 'motivo');
  PERFORM public.flujo_revertir(x.flujo, 'Se aplicó a la cuenta equivocada');
  ASSERT (SELECT etapa || '/' || coalesce(destino, '-') || '/' || coalesce(aplicado_por::text, '-') FROM public.flujo_dinero WHERE id = x.flujo) = 'EN_CAJA/-/-', 'vuelve a En caja, por aplicar';
  ASSERT (SELECT saldo || '/' || estatus FROM public.cuentas_por_cobrar WHERE id = x.cxc) = '1000.00/ABIERTA', 'la cuenta por cobrar recupera su saldo';
  ASSERT (SELECT revertido_at IS NOT NULL AND motivo_reversion LIKE '%equivocada%' FROM public.cxc_abonos WHERE flujo_id = x.flujo), 'el abono se marca revertido, no se borra';
  ASSERT NOT EXISTS (SELECT 1 FROM public.cobranza_saldos_favor WHERE flujo_id = x.flujo AND cancelado_at IS NULL), 'el remanente se cancela';
  ASSERT (SELECT estatus::text FROM public.movimientos_financieros WHERE id = x.mov) = 'CONFIRMADO', 'el libro no cambia: el dinero sigue en caja';
  ASSERT (SELECT accion FROM public.v_flujo_dinero_eventos WHERE flujo_id = x.flujo ORDER BY created_at DESC LIMIT 1) = 'APLICACION_REVERTIDA', 'historial';
  PERFORM public._t_falla(format($q$SELECT public.flujo_revertir(%L, 'Otra reversa sin nada aplicado')$q$, x.flujo), 'no está aplicado');
  -- Se puede aplicar de nuevo, bien.
  PERFORM public.flujo_aplicar(x.flujo, 'CXC', jsonb_build_array(jsonb_build_object('cxc_id', x.cxc, 'monto', 1200 - 200)), 'Reaplicado');
  ASSERT (SELECT count(*) FROM public.cxc_abonos WHERE flujo_id = x.flujo) = 2, 'dos abonos: el revertido y el vigente';
END $$;
-- Reversa del pago: dinero inválido → REVERTIDO y el libro cancela con motivo.
DO $$ DECLARE x t_x%ROWTYPE; BEGIN
  SELECT * INTO x FROM t_x;
  PERFORM public.flujo_revertir(x.flujo, 'La transferencia fue devuelta por el banco', true);
  ASSERT (SELECT etapa FROM public.flujo_dinero WHERE id = x.flujo) = 'REVERTIDO', 'flujo revertido';
  ASSERT (SELECT estatus::text || '/' || motivo_cancelacion FROM public.movimientos_financieros WHERE id = x.mov) LIKE 'CANCELADO/%devuelta por el banco%', 'el libro cancela con motivo';
  ASSERT public._t_saldo(x.banco) = x.saldo0, 'el banco vuelve a su saldo';
  ASSERT (SELECT saldo FROM public.cuentas_por_cobrar WHERE id = x.cxc) = 1000, 'la cuenta por cobrar recupera su saldo';
  ASSERT (SELECT array_agg(accion) FROM public.v_flujo_dinero_eventos WHERE flujo_id = x.flujo) @> ARRAY['PAGO_REVERTIDO', 'LIBRO_CANCELADO'], 'historial de la reversa';
  ASSERT (SELECT count(*) FROM public.cxc_abonos WHERE flujo_id = x.flujo AND revertido_at IS NULL) = 0, 'ningún abono vigente';
END $$;
RESET ROLE;
-- Quién revierte: Compras, Finanzas o administrador; no Almacén.
DO $$ BEGIN
  PERFORM public._t_como('almacen.real@ejemplo.mx');
  PERFORM public._t_falla($q$SELECT public.flujo_revertir(gen_random_uuid(), 'Intento de reversa de Almacén')$q$, 'Sólo Compras o Finanzas');
  RESET ROLE;
END $$;
ROLLBACK;

\echo '6. Reversa desde Cobranza (pago del flujo a remisión): aplicación → En caja; pago → Revertido'
BEGIN;
CREATE TEMP TABLE t_r (flujo uuid, rem uuid, pend numeric, apl uuid, pago uuid);
GRANT ALL ON t_r TO authenticated;
SELECT public._t_como('prueba.compras@dazon.demo');
DO $$ DECLARE v jsonb; v_rem uuid; v_pend numeric; BEGIN
  SELECT id, saldo_pendiente INTO v_rem, v_pend FROM public.v_cobranza_remisiones
   WHERE es_prueba AND documento = 'confirmada' AND saldo_pendiente > 100 AND cliente_id = public._t_cli('TST-C02') ORDER BY fecha_remision LIMIT 1;
  v := public._t_rec('PAGO_CLIENTE', v_pend, 'MXN', 'EFECTIVO', current_date, 'Juan', public._t_cli('TST-C02'));
  INSERT INTO t_r (flujo, rem, pend) VALUES ((v->>'id')::uuid, v_rem, v_pend);
END $$;
RESET ROLE;
SELECT public._t_como('prueba.almacen@dazon.demo');
DO $$ BEGIN PERFORM public.flujo_confirmar_caja((SELECT flujo FROM t_r), (SELECT id FROM public._t_cuenta_mxn())); END $$;
RESET ROLE;
SELECT public._t_como('prueba.finanzas@dazon.demo');
DO $$ DECLARE r t_r%ROWTYPE; BEGIN
  SELECT * INTO r FROM t_r;
  PERFORM public.flujo_aplicar(r.flujo, 'REMISION', jsonb_build_array(jsonb_build_object('remision_id', r.rem, 'monto', r.pend)));
  UPDATE t_r SET apl = (SELECT a.id FROM public.cobranza_aplicaciones a JOIN public.flujo_dinero f ON f.cobranza_pago_id = a.pago_id WHERE f.id = r.flujo),
                 pago = (SELECT cobranza_pago_id FROM public.flujo_dinero WHERE id = r.flujo);
  ASSERT (SELECT saldo_pendiente FROM public.v_cobranza_remisiones WHERE id = r.rem) = 0, 'liquidada';
  ASSERT (SELECT origen FROM public.cobranza_pagos WHERE id = (SELECT pago FROM t_r)) = 'FLUJO', 'el pago de cobranza viene del flujo';
END $$;
RESET ROLE;
SELECT public._t_como('prueba.super@dazon.demo');
DO $$ DECLARE r t_r%ROWTYPE; BEGIN
  SELECT * INTO r FROM t_r;
  PERFORM public.revertir_aplicacion_cobranza(r.apl, 'Aplicación a la remisión equivocada');
  ASSERT (SELECT etapa FROM public.flujo_dinero WHERE id = r.flujo) = 'EN_CAJA', 'el flujo regresa a En caja, por aplicar';
  ASSERT (SELECT saldo_pendiente FROM public.v_cobranza_remisiones WHERE id = r.rem) = r.pend, 'el saldo de la remisión se restaura';
  ASSERT (SELECT estatus FROM public.cobranza_pagos WHERE id = r.pago) = 'revertido', 'el pago anterior queda revertido, no borrado';
  ASSERT (SELECT reversa_motivo FROM public.flujo_dinero WHERE id = r.flujo) LIKE '%equivocada%', 'con su motivo';
END $$;
RESET ROLE;
SELECT public._t_como('prueba.finanzas@dazon.demo');
DO $$ DECLARE r t_r%ROWTYPE; BEGIN
  SELECT * INTO r FROM t_r;
  PERFORM public.flujo_aplicar(r.flujo, 'REMISION', jsonb_build_array(jsonb_build_object('remision_id', r.rem, 'monto', r.pend)), 'Reaplicado');
  UPDATE t_r SET pago = (SELECT cobranza_pago_id FROM public.flujo_dinero WHERE id = r.flujo);
  ASSERT (SELECT saldo_pendiente FROM public.v_cobranza_remisiones WHERE id = r.rem) = 0, 'reaplicado';
END $$;
RESET ROLE;
SELECT public._t_como('prueba.super@dazon.demo');
DO $$ DECLARE r t_r%ROWTYPE; BEGIN
  SELECT * INTO r FROM t_r;
  PERFORM public.revertir_pago_cobranza(r.pago, 'El comprobante resultó ser de otro cliente');
  ASSERT (SELECT etapa FROM public.flujo_dinero WHERE id = r.flujo) = 'REVERTIDO', 'revertir el pago deja el flujo REVERTIDO';
  ASSERT (SELECT saldo_pendiente FROM public.v_cobranza_remisiones WHERE id = r.rem) = r.pend, 'la remisión recupera su saldo';
  ASSERT (SELECT count(*) FROM public.v_flujo_dinero_eventos WHERE flujo_id = r.flujo AND accion IN ('APLICACION_REVERTIDA', 'PAGO_REVERTIDO')) = 2, 'las dos reversas en el historial';
  PERFORM public._t_falla(format($q$SELECT public.flujo_aplicar(%L, 'OTRO')$q$, r.flujo), 'no está pendiente de aplicar|etapa de aplicación');
END $$;
RESET ROLE;
ROLLBACK;

\echo '7. Separación de funciones con un administrador que tiene las tres etapas'
BEGIN;
SELECT public._t_como('admin.real@ejemplo.mx');
SELECT public.flujo_asignar_capacidad(public._t_uid('admin.real@ejemplo.mx'), 'recibe', true);
SELECT public.flujo_asignar_capacidad(public._t_uid('admin.real@ejemplo.mx'), 'caja', true);
RESET ROLE;
CREATE TEMP TABLE t_a (m1 uuid, m2 uuid, cta uuid);
GRANT ALL ON t_a TO authenticated;
SELECT public._t_como('admin.real@ejemplo.mx');
DO $$ DECLARE v jsonb; BEGIN
  INSERT INTO t_a (cta) VALUES ((SELECT id FROM public._t_cuenta_mxn()));
  v := public._t_rec('REEMBOLSO', 100, 'MXN', 'EFECTIVO', current_date, 'Prov A', NULL, 'Devolución A');
  UPDATE t_a SET m1 = (v->>'id')::uuid;
  PERFORM public._t_falla(format($q$SELECT public.flujo_confirmar_caja(%L, %L)$q$, (v->>'id')::uuid, (SELECT cta FROM t_a)), 'Quien recibió el dinero no puede registrarlo en caja');
END $$;
RESET ROLE;
SELECT public._t_como('martin.real@ejemplo.mx');
DO $$ DECLARE v jsonb; BEGIN
  v := public._t_rec('REEMBOLSO', 80, 'MXN', 'EFECTIVO', current_date, 'Prov B', NULL, 'Devolución B');
  UPDATE t_a SET m2 = (v->>'id')::uuid;
END $$;
RESET ROLE;
SELECT public._t_como('admin.real@ejemplo.mx');
DO $$ DECLARE a t_a%ROWTYPE; BEGIN
  SELECT * INTO a FROM t_a;
  -- Puede confirmar en caja un movimiento que recibió otra persona (distinto del suyo)…
  PERFORM public.flujo_confirmar_caja(a.m2, a.cta);
  -- …pero no aplicarlo (lo metió él a caja), ni cancelar en el libro lo que confirmó él.
  PERFORM public._t_falla(format($q$SELECT public.flujo_aplicar(%L, 'REEMBOLSO_PROVEEDOR')$q$, a.m2), 'tercera persona');
  PERFORM public._t_falla(format($q$SELECT public.movimiento_cancelar((SELECT movimiento_id FROM public.flujo_dinero WHERE id = %L), 'Cancelación propia')$q$, a.m2), 'no lo cancela');
END $$;
RESET ROLE;
SELECT public._t_como('almacen.real@ejemplo.mx');
DO $$ DECLARE a t_a%ROWTYPE; BEGIN
  SELECT * INTO a FROM t_a;
  PERFORM public.flujo_confirmar_caja(a.m1, a.cta);   -- el que recibió el administrador lo confirma otra persona
END $$;
RESET ROLE;
SELECT public._t_como('admin.real@ejemplo.mx');
DO $$ DECLARE a t_a%ROWTYPE; BEGIN
  SELECT * INTO a FROM t_a;
  PERFORM public._t_falla(format($q$SELECT public.flujo_aplicar(%L, 'REEMBOLSO_PROVEEDOR')$q$, a.m1), 'tercera persona');   -- lo recibió él
END $$;
RESET ROLE;
ROLLBACK;

\echo '8. Visibilidad: Finanzas consulta el flujo; prueba y real no se mezclan'
BEGIN;
SELECT public._t_como('martin.real@ejemplo.mx');
SELECT public._t_rec('REEMBOLSO', 10, 'MXN', 'EFECTIVO', current_date, 'Real', NULL, 'Real');
RESET ROLE;
SELECT public._t_como('prueba.compras@dazon.demo');
SELECT public._t_rec('REEMBOLSO', 11, 'MXN', 'EFECTIVO', current_date, 'Prueba', NULL, 'Prueba');
RESET ROLE;
SELECT public._t_como('prueba.finanzas@dazon.demo');
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.v_flujo_dinero) >= 1 AND NOT EXISTS (SELECT 1 FROM public.v_flujo_dinero WHERE NOT es_prueba), 'prueba ve solo prueba';
END $$;
RESET ROLE;
SELECT public._t_como('admin.real@ejemplo.mx');
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.v_flujo_dinero WHERE contraparte_nombre = 'Real') = 1, 'el administrador real ve lo real';
  ASSERT NOT EXISTS (SELECT 1 FROM public.v_flujo_dinero WHERE es_prueba), 'y no ve lo de prueba';
END $$;
RESET ROLE;
ROLLBACK;

\echo '9. El saldo inicial solo cambia con motivo y deja bitácora'
BEGIN;
SELECT public._t_como('martin.real@ejemplo.mx');
DO $$ BEGIN PERFORM public._t_falla($q$SELECT public.cuenta_ajustar_saldo_inicial((SELECT id FROM public.cuentas_financieras LIMIT 1), 500, 'Ajuste de apertura')$q$, 'administrador financiero'); END $$;
RESET ROLE;
SELECT public._t_como('admin.real@ejemplo.mx');
DO $$ DECLARE v_cta uuid := (SELECT id FROM public._t_cuenta_mxn()); v_antes numeric := public._t_saldo((SELECT id FROM public._t_cuenta_mxn())); BEGIN
  PERFORM public._t_falla(format($q$SELECT public.cuenta_ajustar_saldo_inicial(%L, 500, 'x')$q$, v_cta), 'motivo');
  PERFORM public.cuenta_ajustar_saldo_inicial(v_cta, 500, 'Saldo de apertura al 1 de octubre');
  ASSERT public._t_saldo(v_cta) = v_antes + 500, 'el saldo se mueve con el ajuste';
  ASSERT EXISTS (SELECT 1 FROM public.bitacora_compras_inventario WHERE accion = 'ajustar_saldo_inicial'), 'queda en la bitácora';
END $$;
RESET ROLE;
ROLLBACK;

\echo 'OK: unificación del flujo y Control financiero'

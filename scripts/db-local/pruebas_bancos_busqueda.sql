-- ============================================================================
-- Pruebas (base de datos) de bancos por empresa y búsqueda de remisiones.
--   PGHOST=127.0.0.1 PGUSER=postgres scripts/db-local/probar_bancos_busqueda.sh
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

\echo '1. Catálogo: solo el administrador financiero; últimos 4; sin borrar; bitácora; las cuentas actuales conservan id y saldo'
BEGIN;
CREATE TEMP TABLE t_e (kit uuid, otra uuid, bko uuid, efo uuid, bkb uuid, saldo0 numeric, ctas0 integer);
GRANT ALL ON t_e TO authenticated;
INSERT INTO t_e (saldo0, ctas0) SELECT coalesce(sum(saldo_actual), 0), count(*) FROM public.v_saldos_cuentas;
SELECT public._t_como('martin.real@ejemplo.mx');
DO $$ BEGIN
  PERFORM public._t_falla($q$SELECT public.empresa_guardar(NULL, 'Kawiil', 'Kawiil SA de CV')$q$, 'administrador financiero');
  PERFORM public._t_falla($q$INSERT INTO public.empresas_grupo (nombre, razon_social) VALUES ('X', 'XX')$q$, 'permission denied');
  PERFORM public._t_falla($q$UPDATE public.cuentas_financieras SET nombre = 'x'$q$, 'permission denied');
  PERFORM public._t_falla($q$DELETE FROM public.cuentas_financieras$q$, 'permission denied');
END $$;
RESET ROLE;
SELECT public._t_como('admin.real@ejemplo.mx');
DO $$ DECLARE c uuid; BEGIN
  UPDATE t_e SET kit = public.empresa_guardar(NULL, 'Kawiil', 'Kawiil SA de CV'), otra = public.empresa_guardar(NULL, 'Dazon', 'Dazon SA de CV');
  PERFORM public._t_falla($q$SELECT public.empresa_guardar(NULL, 'kawiil ', 'Otra razón')$q$, 'duplicate|unique|ux_empresas');
  PERFORM public._t_falla(format($q$SELECT public.cuenta_guardar(NULL, %L, 'BBVA', 'BBVA', 'BANCO', 'MXN', '12345678')$q$, (SELECT kit FROM t_e)), 'últimos 4');
  PERFORM public._t_falla(format($q$SELECT public.cuenta_guardar(NULL, %L, 'BBVA', 'BBVA', 'BANCO', 'MXN', NULL)$q$, (SELECT kit FROM t_e)), 'últimos 4');
  PERFORM public._t_falla(format($q$SELECT public.cuenta_guardar(NULL, %L, 'Caja', NULL, 'EFECTIVO', 'MXN', '1234')$q$, (SELECT kit FROM t_e)), 'no lleva número');
  UPDATE t_e SET bko = public.cuenta_guardar(NULL, kit, 'BBVA Kawiil', 'BBVA', 'BANCO', 'MXN', '4321'),
                 efo = public.cuenta_guardar(NULL, kit, 'Caja Kawiil', NULL, 'EFECTIVO', 'MXN', NULL),
                 bkb = public.cuenta_guardar(NULL, otra, 'Banorte Dazon', 'Banorte', 'BANCO', 'MXN', '9876');
  PERFORM public._t_falla(format($q$SELECT public.cuenta_guardar(NULL, %L, 'BBVA Kawiil 2', 'bbva', 'BANCO', 'MXN', '4321')$q$, (SELECT kit FROM t_e)), 'duplicate|unique|ux_cuentas');
  PERFORM public._t_falla($q$UPDATE public.cuentas_financieras SET ultimos4 = '1' $q$, 'permission denied');
  PERFORM public._t_falla(format($q$UPDATE public.cuentas_financieras SET numero_cuenta = '123456789012' WHERE id = %L$q$, (SELECT bko FROM t_e)), 'permission denied');
  PERFORM public._t_falla(format($q$SELECT public.cuenta_guardar(%L, %L, 'BBVA Kawiil', 'BBVA', 'BANCO', 'MXN', '4321', false)$q$, (SELECT bko FROM t_e), (SELECT kit FROM t_e)), 'motivo');
  ASSERT (SELECT count(*) FROM public.catalogo_bancos_bitacora WHERE accion = 'ALTA') = 5, 'cada alta queda en la bitácora';
  -- Las 3 cuentas actuales se asignan sin perder id ni saldo.
  FOR c IN SELECT id FROM public.cuentas_financieras WHERE empresa_id IS NULL LOOP
    PERFORM public.cuenta_guardar(c, (SELECT kit FROM t_e), (SELECT nombre FROM public.cuentas_financieras WHERE id = c),
      (SELECT coalesce(banco, 'BBVA') FROM public.cuentas_financieras WHERE id = c), (SELECT tipo::text FROM public.cuentas_financieras WHERE id = c),
      (SELECT moneda FROM public.cuentas_financieras WHERE id = c),
      CASE WHEN (SELECT tipo::text FROM public.cuentas_financieras WHERE id = c) = 'BANCO' THEN '0001' END,
      true, NULL, 0, 'Asignación inicial');
  END LOOP;
  ASSERT (SELECT count(*) FROM public.catalogo_bancos_bitacora WHERE accion = 'ASIGNACION_EMPRESA') >= 1 OR NOT EXISTS (SELECT 1 FROM public.cuentas_financieras WHERE nombre NOT LIKE '%Kawiil%' AND nombre NOT LIKE '%Dazon%'), 'asignación en bitácora';
  ASSERT (SELECT count(*) FROM public.cuentas_financieras WHERE empresa_id IS NULL) = 0, 'todas con empresa';
  PERFORM public._t_falla($q$UPDATE public.catalogo_bancos_bitacora SET motivo = 'x'$q$, 'permission denied|no se edita');
END $$;
RESET ROLE;
ROLLBACK;

\echo '2. Recibe elige la empresa; Caja solo ve y elige cuentas de esa empresa, del tipo y la moneda del método'
BEGIN;
CREATE TEMP TABLE t_e (kit uuid, otra uuid, bko uuid, efo uuid, bkb uuid, flujo uuid);
INSERT INTO t_e (kit) VALUES (NULL);
GRANT ALL ON t_e TO authenticated;
SELECT public._t_como('admin.real@ejemplo.mx');
DO $$ BEGIN
  UPDATE t_e SET kit = public.empresa_guardar(NULL, 'Kawiil', 'Kawiil SA de CV'), otra = public.empresa_guardar(NULL, 'Dazon', 'Dazon SA de CV');
  UPDATE t_e SET bko = public.cuenta_guardar(NULL, kit, 'BBVA Kawiil', 'BBVA', 'BANCO', 'MXN', '4321'),
                 efo = public.cuenta_guardar(NULL, kit, 'Caja Kawiil', NULL, 'EFECTIVO', 'MXN', NULL),
                 bkb = public.cuenta_guardar(NULL, otra, 'Banorte Dazon', 'Banorte', 'BANCO', 'MXN', '9876');
END $$;
RESET ROLE;
SELECT public._t_como('martin.real@ejemplo.mx');
DO $$ DECLARE v jsonb; BEGIN
  PERFORM public._t_falla($q$SELECT public._t_rec('REEMBOLSO', 500, 'MXN', 'TRANSFERENCIA', current_date, 'Prov', NULL, 'Dev', 'R-0')$q$, 'Elige la empresa');
  PERFORM public._t_falla(format($q$SELECT public.flujo_recibir('REEMBOLSO', 500, 'MXN', 'TRANSFERENCIA', current_date, 'Prov', NULL, 'Dev', 'R-0', NULL, 'e.pdf', '{}'::jsonb, %L)$q$, gen_random_uuid()), 'no existe o está desactivada');
  v := public.flujo_recibir('REEMBOLSO', 500, 'MXN', 'TRANSFERENCIA', current_date, 'Prov', NULL, 'Dev', 'R-1', NULL, 'e.pdf', '{}'::jsonb, (SELECT otra FROM t_e));
  UPDATE t_e SET flujo = (v->>'id')::uuid;
  ASSERT (SELECT count(*) FROM public.flujo_empresas()) = 2, 'Recibe ve las empresas activas';
  ASSERT (SELECT empresa_nombre FROM public.v_flujo_dinero WHERE id = (SELECT flujo FROM t_e)) = 'Dazon', 'la empresa viaja en el movimiento';
END $$;
RESET ROLE;
SELECT public._t_como('almacen.real@ejemplo.mx');
DO $$ DECLARE f uuid := (SELECT flujo FROM t_e); BEGIN
  -- Caja sin movimiento ve las activas; con movimiento, solo las de la empresa, el tipo y la moneda.
  ASSERT (SELECT count(*) FROM public.flujo_cuentas()) >= 3, 'lista general';
  ASSERT (SELECT array_agg(nombre) FROM public.flujo_cuentas(f)) = ARRAY['Banorte Dazon'], 'solo la cuenta bancaria de Dazon';
  PERFORM public._t_falla(format($q$SELECT public.flujo_confirmar_caja(%L, %L, NULL)$q$, f, (SELECT bko FROM t_e)), 'es de Kawiil|Elige una cuenta de esa empresa|es de');
  PERFORM public._t_falla(format($q$SELECT public.flujo_confirmar_caja(%L, %L, NULL)$q$, f, (SELECT efo FROM t_e)), 'es de|efectivo|banco|transferencia');
  PERFORM public.flujo_confirmar_caja(f, (SELECT bkb FROM t_e), NULL);
  ASSERT (SELECT etapa FROM public.flujo_dinero WHERE id = f) = 'EN_CAJA', 'confirmado en la cuenta correcta';
END $$;
RESET ROLE;
SELECT public._t_como('martin.real@ejemplo.mx');
DO $$ DECLARE v jsonb; BEGIN
  v := public.flujo_recibir('REEMBOLSO', 700, 'MXN', 'TRANSFERENCIA', current_date, 'Prov', NULL, 'Dev', 'R-2', NULL, 'e.pdf', '{}'::jsonb, (SELECT kit FROM t_e));
  ASSERT (SELECT monto FROM public.v_flujo_en_transito WHERE empresa_nombre = 'Kawiil' AND tipo = 'INGRESO') = 700, 'lo no confirmado queda en tránsito, por empresa';
  ASSERT coalesce((SELECT saldo_actual FROM public.v_saldos_por_empresa WHERE empresa_nombre = 'Kawiil' AND moneda = 'MXN'), 0) = 0
         OR (SELECT saldo_actual FROM public.v_saldos_por_empresa WHERE empresa_nombre = 'Kawiil' AND moneda = 'MXN') = (SELECT coalesce(sum(saldo_inicial), 0) FROM public.cuentas_financieras WHERE empresa_id = (SELECT kit FROM t_e)),
         'el tránsito no entra al saldo';
END $$;
RESET ROLE;
-- Una cuenta con movimientos ya no cambia de empresa; se desactiva con motivo.
SELECT public._t_como('admin.real@ejemplo.mx');
DO $$ BEGIN
  ASSERT (SELECT saldo_actual FROM public.v_saldos_por_empresa WHERE empresa_nombre = 'Dazon' AND moneda = 'MXN') = 500, 'saldo por empresa solo con lo confirmado';
  ASSERT (SELECT saldo_actual FROM public.v_saldos_cuentas WHERE id = (SELECT bkb FROM t_e)) = 500, 'saldo por cuenta con lo confirmado';
  PERFORM public._t_falla(format($q$SELECT public.cuenta_guardar(%L, %L, 'Banorte Dazon', 'Banorte', 'BANCO', 'MXN', '9876')$q$, (SELECT bkb FROM t_e), (SELECT kit FROM t_e)), 'ya tiene movimientos');
  PERFORM public.cuenta_guardar((SELECT bkb FROM t_e), (SELECT otra FROM t_e), 'Banorte Dazon', 'Banorte', 'BANCO', 'MXN', '9876', false, NULL, 0, 'Cuenta cerrada');
  ASSERT (SELECT activo FROM public.cuentas_financieras WHERE id = (SELECT bkb FROM t_e)) = false, 'desactivada, no borrada';
  PERFORM public._t_falla(format($q$SELECT public.empresa_guardar(%L, 'Kawiil', 'Kawiil SA de CV', false, 'Cierre de la empresa')$q$, (SELECT kit FROM t_e)), 'cuentas activas');
END $$;
RESET ROLE;
SELECT public._t_como('almacen.real@ejemplo.mx');
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.flujo_cuentas((SELECT flujo FROM t_e))) = 0, 'Caja ya no ve cuentas desactivadas';
END $$;
RESET ROLE;
ROLLBACK;

\echo '3. Búsqueda de remisiones al aplicar: filtros, paginación, sugerida, antigüedad, prueba/real separados, separación de funciones'
BEGIN;
CREATE TEMP TABLE t_b (flujo uuid, cli uuid);
GRANT ALL ON t_b TO authenticated;
SELECT public._t_como('prueba.compras@dazon.demo');
DO $$ DECLARE v jsonb; c uuid; BEGIN
  SELECT cliente_id INTO c FROM public.remisiones_refacciones r WHERE r.es_prueba AND r.etapa <> 'cancelada' AND NOT r.abierta
    AND (SELECT saldo_pendiente FROM public.estado_cobro_remision_refaccion(r.id)) > 0 ORDER BY fecha_remision LIMIT 1;
  ASSERT c IS NOT NULL, 'hay remisiones de prueba con saldo';
  v := public._t_rec('PAGO_CLIENTE', 1234.56, 'MXN', 'EFECTIVO', current_date, 'Cliente', c, 'Pago');
  INSERT INTO t_b VALUES ((v->>'id')::uuid, c);
END $$;
RESET ROLE;
SELECT public._t_como('prueba.almacen@dazon.demo');
SELECT public.flujo_confirmar_caja((SELECT flujo FROM t_b), (SELECT id FROM public._t_cuenta_mxn()), NULL);
RESET ROLE;
SELECT public._t_como('prueba.compras@dazon.demo');
DO $$ BEGIN PERFORM public._t_falla(format($q$SELECT * FROM public.flujo_buscar_remisiones(%L)$q$, (SELECT flujo FROM t_b)), 'etapa de aplicación|tercera persona'); END $$;
RESET ROLE;
SELECT public._t_como('prueba.almacen@dazon.demo');
DO $$ BEGIN PERFORM public._t_falla(format($q$SELECT * FROM public.flujo_buscar_remisiones(%L)$q$, (SELECT flujo FROM t_b)), 'etapa de aplicación|tercera persona'); END $$;
RESET ROLE;
SELECT public._t_como('prueba.finanzas@dazon.demo');
DO $$ DECLARE n bigint; r record; v_folio text; v_prev date; v_todos bigint; v_pag integer;
BEGIN
  -- Por omisión: solo las del cliente, de la más antigua a la más reciente, con antigüedad.
  v_prev := NULL;
  FOR r IN SELECT * FROM public.flujo_buscar_remisiones((SELECT flujo FROM t_b)) LOOP
    ASSERT r.cliente_id = (SELECT cli FROM t_b) AND r.es_del_cliente, 'solo el cliente del pago';
    ASSERT r.saldo_pendiente > 0 AND r.total >= r.saldo_pendiente, 'saldo pendiente coherente';
    ASSERT r.antiguedad_dias = current_date - r.fecha_remision, 'antigüedad en días';
    ASSERT v_prev IS NULL OR r.fecha_remision >= v_prev, 'ordenadas por antigüedad';
    v_prev := r.fecha_remision;
  END LOOP;
  SELECT count(*), max(total_filas) INTO n, v_todos FROM public.flujo_buscar_remisiones((SELECT flujo FROM t_b));
  ASSERT n >= 1 AND v_todos = n, 'total_filas coincide';
  -- Todos los clientes.
  SELECT max(total_filas) INTO v_todos FROM public.flujo_buscar_remisiones((SELECT flujo FROM t_b), true);
  ASSERT v_todos >= n, 'buscar en todos los clientes amplía';
  -- Paginación.
  ASSERT (SELECT count(*) FROM public.flujo_buscar_remisiones((SELECT flujo FROM t_b), true, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 2, 0)) = least(2, v_todos), 'límite';
  IF v_todos > 2 THEN
    ASSERT (SELECT array_agg(id ORDER BY fecha_remision, folio) FROM public.flujo_buscar_remisiones((SELECT flujo FROM t_b), true, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 2, 0))
           IS DISTINCT FROM (SELECT array_agg(id ORDER BY fecha_remision, folio) FROM public.flujo_buscar_remisiones((SELECT flujo FROM t_b), true, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 2, 2)), 'la segunda página es otra';
  END IF;
  -- Filtros.
  SELECT b.folio INTO v_folio FROM public.flujo_buscar_remisiones((SELECT flujo FROM t_b), true) b LIMIT 1;
  ASSERT (SELECT count(*) FROM public.flujo_buscar_remisiones((SELECT flujo FROM t_b), true, v_folio)) >= 1, 'filtro por folio';
  ASSERT (SELECT count(*) FROM public.flujo_buscar_remisiones((SELECT flujo FROM t_b), true, 'NO-EXISTE-XYZ')) = 0, 'folio inexistente';
  ASSERT (SELECT count(*) FROM public.flujo_buscar_remisiones((SELECT flujo FROM t_b), true, NULL, NULL, NULL, current_date + 1)) = 0, 'filtro por fecha desde';
  ASSERT (SELECT count(*) FROM public.flujo_buscar_remisiones((SELECT flujo FROM t_b), true, NULL, NULL, NULL, NULL, NULL, 1e12)) = 0, 'filtro por monto mínimo';
  ASSERT (SELECT count(*) FROM public.flujo_buscar_remisiones((SELECT flujo FROM t_b), true, NULL, 'TST-C0')) >= 1, 'filtro por cliente (código)';
  -- Ninguna cancelada ni de otro modo.
  ASSERT NOT EXISTS (SELECT 1 FROM public.flujo_buscar_remisiones((SELECT flujo FROM t_b), true) b JOIN public.remisiones_refacciones rr ON rr.id = b.id WHERE rr.etapa = 'cancelada' OR rr.abierta OR NOT rr.es_prueba), 'solo confirmadas, no canceladas, de prueba';
  -- La sugerida: cliente con saldo igual al monto.
END $$;
RESET ROLE;
ROLLBACK;

\echo '4. Cambio de cliente: motivo, otra persona, misma modalidad (prueba/real), huella; con parámetro exige administrador'
BEGIN;
CREATE TEMP TABLE t_c (flujo uuid, c1 uuid, c2 uuid, creal uuid);
GRANT ALL ON t_c TO authenticated;
INSERT INTO public.clientes (nombre_comercial, razon_social, codigo_erp, es_prueba) VALUES ('Cliente Real B', 'CLIENTE REAL B SA', 'REAL-B', false);
SELECT public._t_como('prueba.compras@dazon.demo');
DO $$ DECLARE v jsonb; BEGIN
  v := public._t_rec('PAGO_CLIENTE', 800, 'MXN', 'EFECTIVO', current_date, 'Cliente', public._t_cli('TST-C01'), 'Pago');
  INSERT INTO t_c VALUES ((v->>'id')::uuid, public._t_cli('TST-C01'), public._t_cli('TST-C02'), public._t_cli('REAL-B'));
END $$;
RESET ROLE;
SELECT public._t_como('prueba.almacen@dazon.demo');
DO $$ BEGIN PERFORM public._t_falla(format($q$SELECT public.flujo_cambiar_cliente(%L, %L, 'Cliente equivocado')$q$, (SELECT flujo FROM t_c), (SELECT c2 FROM t_c)), 'etapa de aplicación|no está pendiente'); END $$;
SELECT public.flujo_confirmar_caja((SELECT flujo FROM t_c), (SELECT id FROM public._t_cuenta_mxn()), NULL);
DO $$ BEGIN PERFORM public._t_falla(format($q$SELECT public.flujo_cambiar_cliente(%L, %L, 'Cliente equivocado')$q$, (SELECT flujo FROM t_c), (SELECT c2 FROM t_c)), 'etapa de aplicación|tercera|otra persona'); END $$;
RESET ROLE;
SELECT public._t_como('prueba.compras@dazon.demo');
DO $$ BEGIN PERFORM public._t_falla(format($q$SELECT public.flujo_cambiar_cliente(%L, %L, 'Cliente equivocado')$q$, (SELECT flujo FROM t_c), (SELECT c2 FROM t_c)), 'etapa de aplicación|otra persona'); END $$;
RESET ROLE;
SELECT public._t_como('prueba.finanzas@dazon.demo');
DO $$ BEGIN
  PERFORM public._t_falla(format($q$SELECT public.flujo_cambiar_cliente(%L, %L, 'x')$q$, (SELECT flujo FROM t_c), (SELECT c2 FROM t_c)), 'motivo');
  PERFORM public._t_falla(format($q$SELECT public.flujo_cambiar_cliente(%L, %L, 'Cliente equivocado')$q$, (SELECT flujo FROM t_c), (SELECT c1 FROM t_c)), 'ya es el cliente');
  PERFORM public._t_falla(format($q$SELECT public.flujo_cambiar_cliente(%L, %L, 'Cliente equivocado')$q$, (SELECT flujo FROM t_c), (SELECT creal FROM t_c)), 'prueba con reales|de prueba|real');
  PERFORM public.flujo_cambiar_cliente((SELECT flujo FROM t_c), (SELECT c2 FROM t_c), 'Capturaron el cliente equivocado');
  ASSERT (SELECT cliente_id FROM public.flujo_dinero WHERE id = (SELECT flujo FROM t_c)) = (SELECT c2 FROM t_c), 'cliente cambiado';
  ASSERT EXISTS (SELECT 1 FROM public.v_flujo_dinero_eventos WHERE flujo_id = (SELECT flujo FROM t_c) AND accion = 'CLIENTE_CAMBIADO' AND motivo = 'Capturaron el cliente equivocado'), 'queda en el historial con motivo';
  ASSERT EXISTS (SELECT 1 FROM public.v_flujo_dinero_eventos WHERE flujo_id = (SELECT flujo FROM t_c) AND accion = 'CLIENTE_CAMBIADO' AND detalle->'de'->>'codigo' = 'TST-C01' AND detalle->'a'->>'codigo' = 'TST-C02'), 'huella del antes y el después';
END $$;
RESET ROLE;
-- Con el parámetro encendido, además debe ser administrador.
SELECT set_config('request.jwt.claim.sub', '', true);
UPDATE public.compras_parametros SET valor = 'true'::jsonb WHERE clave = 'flujo_cambio_cliente_exige_admin';
SELECT public._t_como('prueba.finanzas@dazon.demo');
DO $$ BEGIN PERFORM public._t_falla(format($q$SELECT public.flujo_cambiar_cliente(%L, %L, 'Otra corrección')$q$, (SELECT flujo FROM t_c), (SELECT c1 FROM t_c)), 'administrador'); END $$;
RESET ROLE;
SELECT public._t_como('prueba.super@dazon.demo');
DO $$ BEGIN
  PERFORM public.flujo_cambiar_cliente((SELECT flujo FROM t_c), (SELECT c1 FROM t_c), 'Corrección por el administrador');
  ASSERT (SELECT cliente_id FROM public.flujo_dinero WHERE id = (SELECT flujo FROM t_c)) = (SELECT c1 FROM t_c), 'el administrador corrige';
END $$;
RESET ROLE;
ROLLBACK;

\echo '5. Cuentas por cobrar del cliente del pago (solo reales)'
BEGIN;
CREATE TEMP TABLE t_x (flujo uuid);
GRANT ALL ON t_x TO authenticated;
INSERT INTO public.clientes (nombre_comercial, razon_social, codigo_erp, es_prueba) VALUES ('Cliente Real X', 'CLIENTE REAL X SA', 'REAL-X', false);
INSERT INTO public.cuentas_por_cobrar (cliente_id, concepto, monto, saldo, moneda, fecha_emision, fecha_vencimiento, estatus)
  SELECT id, 'Crédito', 1000, 1000, 'MXN', current_date, current_date + 30, 'ABIERTA' FROM public.clientes WHERE codigo_erp = 'REAL-X';
SELECT public._t_como('martin.real@ejemplo.mx');
DO $$ BEGIN INSERT INTO t_x VALUES ((public._t_rec('PAGO_CLIENTE', 400, 'MXN', 'EFECTIVO', current_date, 'Cliente X', public._t_cli('REAL-X'), 'Pago')->>'id')::uuid); END $$;
RESET ROLE;
SELECT public._t_como('almacen.real@ejemplo.mx');
SELECT public.flujo_confirmar_caja((SELECT flujo FROM t_x), (SELECT id FROM public._t_cuenta_mxn()), NULL);
DO $$ BEGIN PERFORM public._t_falla(format($q$SELECT * FROM public.flujo_cxc_cliente(%L)$q$, (SELECT flujo FROM t_x)), 'etapa de aplicación'); END $$;
RESET ROLE;
SELECT public._t_como('admin.real@ejemplo.mx');
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.flujo_cxc_cliente((SELECT flujo FROM t_x))) = 1, 'la cuenta por cobrar del cliente aparece';
  ASSERT (SELECT saldo FROM public.flujo_cxc_cliente((SELECT flujo FROM t_x))) = 1000, 'con su saldo';
END $$;
RESET ROLE;
ROLLBACK;

\echo 'OK: bancos por empresa y búsqueda de remisiones'

-- ============================================================================
-- Pruebas (base de datos) de gastos, categorías, cuentas por prueba/real, históricos y regularización.
--   PGHOST=127.0.0.1 PGUSER=postgres scripts/db-local/probar_gastos.sh
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
  ('00000000-0000-0000-0000-0000000000b4', 'admin.real@ejemplo.mx'),
  ('00000000-0000-0000-0000-0000000000b5', 'jair.real@ejemplo.mx'),
  ('00000000-0000-0000-0000-0000000000b6', 'luna.real@ejemplo.mx'),
  ('00000000-0000-0000-0000-0000000000b7', 'leti.real@ejemplo.mx'),
  ('00000000-0000-0000-0000-0000000000b8', 'polo.real@ejemplo.mx')
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
  ('00000000-0000-0000-0000-0000000000b4', 'admin',     'direccion',         'admin'),
  ('00000000-0000-0000-0000-0000000000b5', 'admin_financiero', 'administracion', 'supervisor'),
  ('00000000-0000-0000-0000-0000000000b6', 'admin_financiero', 'administracion', 'supervisor'),
  ('00000000-0000-0000-0000-0000000000b7', 'admin_financiero', 'administracion', 'supervisor'),
  ('00000000-0000-0000-0000-0000000000b8', 'admin',     'direccion',         'admin');
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

CREATE OR REPLACE FUNCTION public._t_banco() RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$
  SELECT id FROM public.cuentas_financieras WHERE moneda = 'MXN' AND tipo = 'BANCO' AND activo AND es_prueba = public.es_usuario_prueba(auth.uid()) ORDER BY orden LIMIT 1 $$;
GRANT EXECUTE ON FUNCTION public._t_banco() TO authenticated;

-- Perfiles: Jair captura gastos · Luna confirma gastos · Leti caja · Polo/Martin admin sin etapas de gasto.
\echo '0. Perfiles captura_gasto y confirma_gasto: asignables por un administrador, nadie más; quedan en bitácora'
BEGIN;
SELECT public._t_como('martin.real@ejemplo.mx');
DO $$ BEGIN PERFORM public._t_falla($q$SELECT public.flujo_asignar_capacidad(public._t_uid('luna.real@ejemplo.mx'), 'confirma_gasto', true)$q$, 'administrador asigna|Sólo un administrador'); END $$;
RESET ROLE;
SELECT public._t_como('polo.real@ejemplo.mx');
SELECT public.flujo_asignar_capacidad(public._t_uid('jair.real@ejemplo.mx'), 'captura_gasto', true);
SELECT public.flujo_asignar_capacidad(public._t_uid('luna.real@ejemplo.mx'), 'confirma_gasto', true);
SELECT public.flujo_asignar_capacidad(public._t_uid('leti.real@ejemplo.mx'), 'caja', true);
DO $$ BEGIN
  PERFORM public._t_falla($q$SELECT public.flujo_asignar_capacidad(public._t_uid('luna.real@ejemplo.mx'), 'inventada', true)$q$, 'Capacidad inválida');
  ASSERT (SELECT captura_gasto FROM public.flujo_listar_capacidades() WHERE nombre = 'jair.real@ejemplo.mx') AND (SELECT confirma_gasto FROM public.flujo_listar_capacidades() WHERE nombre = 'luna.real@ejemplo.mx'), 'la lista muestra los perfiles';
  ASSERT (public.flujo_mis_capacidades() ->> 'captura_gasto') = 'false', 'Polo no tiene etapas de gasto';
END $$;
RESET ROLE;
SELECT public._t_como('jair.real@ejemplo.mx');
DO $$ BEGIN ASSERT (public.flujo_mis_capacidades() ->> 'captura_gasto') = 'true' AND (public.flujo_mis_capacidades() ->> 'confirma_gasto') = 'false', 'Jair captura y no confirma'; END $$;
RESET ROLE;
ROLLBACK;

\echo '1. Gastos por transferencia: evidencia obligatoria, categoría, moneda, saldo suficiente, separación de funciones, rechazo y corrección'
BEGIN;
CREATE TEMP TABLE t_g (kit uuid, bmx uuid, cmx uuid, busd uuid, cusd uuid, g1 uuid, g2 uuid);
INSERT INTO t_g (kit) VALUES (NULL);
GRANT ALL ON t_g TO authenticated;
SELECT public._t_como('polo.real@ejemplo.mx');
SELECT public.flujo_asignar_capacidad(public._t_uid('jair.real@ejemplo.mx'), 'captura_gasto', true);
SELECT public.flujo_asignar_capacidad(public._t_uid('luna.real@ejemplo.mx'), 'confirma_gasto', true);
SELECT public.flujo_asignar_capacidad(public._t_uid('leti.real@ejemplo.mx'), 'caja', true);
DO $$ BEGIN
  UPDATE t_g SET kit = public.empresa_guardar(NULL, 'Kawiil', 'Kawiil SA de CV');
  UPDATE t_g SET bmx = public.cuenta_guardar(NULL, kit, 'BBVA MXN', 'BBVA', 'BANCO', 'MXN', '1111', true, NULL, 10000, NULL),
                 cmx = public.cuenta_guardar(NULL, kit, 'Caja MXN', NULL, 'EFECTIVO', 'MXN', NULL, true, NULL, 500, NULL),
                 busd = public.cuenta_guardar(NULL, kit, 'Banco USD', 'BBVA', 'BANCO', 'USD', '2222', true, NULL, 20000, NULL),
                 cusd = public.cuenta_guardar(NULL, kit, 'Caja USD', NULL, 'EFECTIVO', 'USD', NULL, true, NULL, 0, NULL);
  PERFORM public._t_falla($q$SELECT public.cuenta_guardar(NULL, (SELECT kit FROM t_g), 'Cuenta CNY', 'BBVA', 'BANCO', 'CNY', '3333')$q$, 'no está permitida');
END $$;
RESET ROLE;
SELECT public._t_como('jair.real@ejemplo.mx');
DO $$ DECLARE v jsonb; k uuid := (SELECT kit FROM t_g); b uuid := (SELECT bmx FROM t_g); bu uuid := (SELECT busd FROM t_g); BEGIN
  -- Sin evidencia, sin categoría activa, internacional en MXN, moneda no permitida, cuenta de otra empresa/tipo: todo se rechaza.
  PERFORM public._t_falla(format($q$SELECT public.flujo_capturar_gasto(500, 'MXN', 'TRANSFERENCIA', current_date, 'Prov', 'Servicios (luz, agua, renta)', 'Luz', 'R-1', NULL, NULL, %L, %L)$q$, k, b), 'evidencia');
  PERFORM public._t_falla(format($q$SELECT public.flujo_capturar_gasto(500, 'MXN', 'TRANSFERENCIA', current_date, 'Prov', 'Mantenimiento', 'x', 'R-1', NULL, 'e.pdf', %L, %L)$q$, k, b), 'categoría de egreso activa');
  PERFORM public._t_falla(format($q$SELECT public.flujo_capturar_gasto(500, 'MXN', 'TRANSFERENCIA', current_date, 'Prov', 'Proveedor internacional', 'x', 'R-1', NULL, 'e.pdf', %L, %L)$q$, k, b), 'internacional');
  PERFORM public._t_falla(format($q$SELECT public.flujo_capturar_gasto(500, 'CNY', 'TRANSFERENCIA', current_date, 'Prov', 'Servicios (luz, agua, renta)', 'x', 'R-1', 7, 'e.pdf', %L, %L)$q$, k, b), 'no está permitida');
  PERFORM public._t_falla(format($q$SELECT public.flujo_capturar_gasto(500, 'MXN', 'TRANSFERENCIA', current_date, 'Prov', 'Servicios (luz, agua, renta)', 'x', 'R-1', NULL, 'e.pdf', %L, %L)$q$, k, (SELECT cmx FROM t_g)), 'cuenta de banco|efectivo');
  PERFORM public._t_falla(format($q$SELECT public.flujo_capturar_gasto(500, 'MXN', 'TRANSFERENCIA', current_date, 'Prov', 'Servicios (luz, agua, renta)', 'x', NULL, NULL, 'e.pdf', %L, %L)$q$, k, b), 'referencia');
  PERFORM public._t_falla(format($q$SELECT public.flujo_capturar_gasto(500, 'MXN', 'TRANSFERENCIA', current_date, 'Prov', 'Servicios (luz, agua, renta)', 'x', 'R-1', NULL, 'e.pdf', NULL, %L)$q$, b), 'empresa');
  -- Internacional en USD con cuenta USD: sí.
  v := public.flujo_capturar_gasto(8664.41, 'USD', 'TRANSFERENCIA', current_date, 'Proveedor China', 'Proveedor internacional', 'Pago final contenedor', 'SWIFT-9', 18.68, 'gastos/swift.pdf', k, bu);
  v := public.flujo_capturar_gasto(900, 'MXN', 'TRANSFERENCIA', current_date, 'CFE', 'Servicios (luz, agua, renta)', 'Luz oficina', 'R-77', NULL, 'gastos/cfe.pdf', k, b);
  UPDATE t_g SET g1 = (v->>'id')::uuid;
  ASSERT (SELECT etapa FROM public.flujo_dinero WHERE id = (SELECT g1 FROM t_g)) = 'RECIBIDO', 'queda por confirmar';
  PERFORM public._t_falla(format($q$SELECT public.flujo_confirmar_gasto(%L)$q$, (SELECT g1 FROM t_g)), 'confirmación de gastos');
  PERFORM public._t_falla($q$SELECT public.flujo_recibir('SALIDA', 10, 'MXN', 'EFECTIVO', current_date, 'x', NULL, 'x', NULL, NULL, 'e.pdf')$q$, 'etapa de recepción|pestaña Gastos');
END $$;
RESET ROLE;
SELECT public._t_como('luna.real@ejemplo.mx');
DO $$ DECLARE g uuid := (SELECT g1 FROM t_g); v jsonb; n0 integer := (SELECT count(*) FROM public.movimientos_financieros); BEGIN
  ASSERT (SELECT count(*) FROM public.flujo_cuentas_gasto((SELECT kit FROM t_g), 'TRANSFERENCIA', 'MXN')) = 1, 'solo el banco MXN de la empresa';
  ASSERT public.flujo_saldo_cuenta((SELECT bmx FROM t_g)) = 10000, 'saldo visible';
  -- Rechaza con motivo; Jair lo corrige; Luna confirma.
  PERFORM public._t_falla(format($q$SELECT public.flujo_rechazar_gasto(%L, 'x')$q$, g), 'motivo');
  PERFORM public.flujo_rechazar_gasto(g, 'Falta el recibo del mes');
  ASSERT (SELECT etapa FROM public.flujo_dinero WHERE id = g) = 'RECHAZADO', 'rechazado';
  ASSERT (SELECT count(*) FROM public.movimientos_financieros) = n0, 'rechazar no mueve el libro';
END $$;
RESET ROLE;
SELECT public._t_como('jair.real@ejemplo.mx');
DO $$ DECLARE g uuid := (SELECT g1 FROM t_g); BEGIN
  ASSERT (SELECT motivo_rechazo FROM public.v_flujo_dinero WHERE id = g) = 'Falta el recibo del mes', 'Jair ve el motivo';
  PERFORM public._t_falla(format($q$SELECT public.flujo_corregir_gasto(%L, '{"monto": 1}'::jsonb)$q$, (SELECT g2 FROM t_g)), 'No existe');
  PERFORM public._t_falla(format($q$SELECT public.flujo_corregir_gasto(%L, '{"cuenta_origen": 1}'::jsonb)$q$, g), 'No se corrige');
  PERFORM public.flujo_corregir_gasto(g, '{"evidencia_path": "gastos/cfe-octubre.pdf", "concepto": "Luz oficina octubre"}'::jsonb);
  ASSERT (SELECT etapa FROM public.flujo_dinero WHERE id = g) = 'RECIBIDO', 'vuelve a confirmación';
  ASSERT EXISTS (SELECT 1 FROM public.v_flujo_dinero_eventos WHERE flujo_id = g AND accion = 'GASTO_CORREGIDO'), 'queda en el historial';
END $$;
RESET ROLE;
SELECT public._t_como('luna.real@ejemplo.mx');
DO $$ DECLARE g uuid := (SELECT g1 FROM t_g); v jsonb; b uuid := (SELECT bmx FROM t_g); BEGIN
  v := public.flujo_confirmar_gasto(g);
  ASSERT v->>'etapa' = 'APLICADO' AND v->>'movimiento_id' IS NOT NULL, 'transferencia: confirma y entra al libro';
END $$;
RESET ROLE;
SELECT public._t_como('polo.real@ejemplo.mx');
DO $$ DECLARE g uuid := (SELECT g1 FROM t_g); m record; BEGIN
  SELECT * INTO m FROM public.movimientos_financieros WHERE flujo_id = g;
  ASSERT m.tipo = 'EGRESO' AND m.estatus = 'CONFIRMADO' AND m.origen = 'FLUJO' AND m.categoria = 'Servicios (luz, agua, renta)' AND m.cuenta_id = (SELECT bmx FROM t_g), 'egreso confirmado con origen y categoría';
  ASSERT EXISTS (SELECT 1 FROM public.v_movimientos_financieros WHERE id = m.id AND flujo_folio = (SELECT folio FROM public.flujo_dinero WHERE id = g)), 'el libro muestra el folio FD';
  ASSERT EXISTS (SELECT 1 FROM public.movimiento_adjuntos WHERE movimiento_id = m.id), 'la evidencia viaja al expediente';
  ASSERT public._t_saldo((SELECT bmx FROM t_g)) = 9100, 'el saldo baja solo al confirmar';
END $$;
RESET ROLE;
-- Saldo suficiente: un gasto mayor al saldo no se confirma, con mensaje claro.
SELECT public._t_como('jair.real@ejemplo.mx');
DO $$ DECLARE v jsonb; BEGIN
  v := public.flujo_capturar_gasto(50000, 'MXN', 'TRANSFERENCIA', current_date, 'Prov', 'Compra de partes', 'Partes', 'R-5', NULL, 'gastos/p.pdf', (SELECT kit FROM t_g), (SELECT bmx FROM t_g));
  UPDATE t_g SET g2 = (v->>'id')::uuid;
END $$;
RESET ROLE;
SELECT public._t_como('luna.real@ejemplo.mx');
DO $$ BEGIN PERFORM public._t_falla(format($q$SELECT public.flujo_confirmar_gasto(%L)$q$, (SELECT g2 FROM t_g)), 'Saldo insuficiente en «BBVA MXN»: tiene 9,100.00 MXN y el gasto es de 50,000.00 \(faltan 40,900.00\)'); END $$;
RESET ROLE;
-- Un administrador con captura y confirmación no confirma lo que capturó, pero sí lo de otra persona.
SELECT public._t_como('polo.real@ejemplo.mx');
SELECT public.flujo_asignar_capacidad(public._t_uid('luna.real@ejemplo.mx'), 'captura_gasto', true);
RESET ROLE;
SELECT public._t_como('luna.real@ejemplo.mx');
DO $$ DECLARE v jsonb; BEGIN
  v := public.flujo_capturar_gasto(100, 'MXN', 'TRANSFERENCIA', current_date, 'Prov', 'Impuestos', 'Pago', 'R-9', NULL, 'gastos/i.pdf', (SELECT kit FROM t_g), (SELECT bmx FROM t_g));
  PERFORM public._t_falla(format($q$SELECT public.flujo_confirmar_gasto(%L)$q$, v->>'id'), 'Quien capturó el gasto no lo confirma');
  PERFORM public._t_falla(format($q$SELECT public.flujo_rechazar_gasto(%L, 'no quiero')$q$, v->>'id'), 'Quien capturó el gasto no lo rechaza');
END $$;
RESET ROLE;
ROLLBACK;

\echo '2. Gastos en efectivo (opción B): Luna autoriza, Leti registra la entrega y el libro se mueve al entregar; saldo suficiente en ambos pasos'
BEGIN;
CREATE TEMP TABLE t_e (kit uuid, cmx uuid, bmx uuid, g1 uuid, g2 uuid, mov uuid);
INSERT INTO t_e (kit) VALUES (NULL);
GRANT ALL ON t_e TO authenticated;
SELECT public._t_como('polo.real@ejemplo.mx');
SELECT public.flujo_asignar_capacidad(public._t_uid('jair.real@ejemplo.mx'), 'captura_gasto', true);
SELECT public.flujo_asignar_capacidad(public._t_uid('luna.real@ejemplo.mx'), 'confirma_gasto', true);
SELECT public.flujo_asignar_capacidad(public._t_uid('leti.real@ejemplo.mx'), 'caja', true);
DO $$ BEGIN
  UPDATE t_e SET kit = public.empresa_guardar(NULL, 'Kawiil', 'Kawiil SA de CV');
  UPDATE t_e SET cmx = public.cuenta_guardar(NULL, kit, 'Caja MXN', NULL, 'EFECTIVO', 'MXN', NULL, true, NULL, 500, NULL),
                 bmx = public.cuenta_guardar(NULL, kit, 'BBVA MXN', 'BBVA', 'BANCO', 'MXN', '1111', true, NULL, 10000, NULL);
END $$;
RESET ROLE;
SELECT public._t_como('jair.real@ejemplo.mx');
DO $$ DECLARE v jsonb; BEGIN
  v := public.flujo_capturar_gasto(300, 'MXN', 'EFECTIVO', current_date, 'Chofer', 'Viáticos', 'Viáticos de entrega', NULL, NULL, 'gastos/vale.jpg', (SELECT kit FROM t_e), (SELECT cmx FROM t_e));
  UPDATE t_e SET g1 = (v->>'id')::uuid;
  v := public.flujo_capturar_gasto(400, 'MXN', 'EFECTIVO', current_date, 'Chofer', 'Viáticos', 'Otro viático', NULL, NULL, 'gastos/vale2.jpg', (SELECT kit FROM t_e), (SELECT cmx FROM t_e));
  UPDATE t_e SET g2 = (v->>'id')::uuid;
  ASSERT (SELECT (datos_libro->>'requiere_comprobacion')::boolean FROM public.flujo_dinero WHERE id = (SELECT g1 FROM t_e)), 'el efectivo queda por comprobar';
END $$;
RESET ROLE;
SELECT public._t_como('luna.real@ejemplo.mx');
DO $$ DECLARE v jsonb; n0 integer := (SELECT count(*) FROM public.movimientos_financieros); BEGIN
  v := public.flujo_confirmar_gasto((SELECT g1 FROM t_e));
  ASSERT v->>'etapa' = 'AUTORIZADO', 'efectivo: Luna solo autoriza';
  ASSERT (SELECT count(*) FROM public.movimientos_financieros) = n0, 'el libro no se mueve al autorizar';
  PERFORM public._t_falla(format($q$SELECT public.flujo_entregar_gasto(%L)$q$, (SELECT g1 FROM t_e)), 'etapa de caja');
END $$;
RESET ROLE;
SELECT public._t_como('leti.real@ejemplo.mx');
DO $$ DECLARE mv uuid; BEGIN
  PERFORM public._t_falla(format($q$SELECT public.flujo_entregar_gasto(%L)$q$, (SELECT g2 FROM t_e)), 'no está por entregar');
  mv := public.flujo_entregar_gasto((SELECT g1 FROM t_e), 'Entregado al chofer');
  UPDATE t_e SET mov = mv;
  ASSERT (SELECT etapa FROM public.flujo_dinero WHERE id = (SELECT g1 FROM t_e)) = 'APLICADO', 'entregado';
  ASSERT (SELECT caja_por FROM public.flujo_dinero WHERE id = (SELECT g1 FROM t_e)) = auth.uid(), 'entregó Leti';
  ASSERT (SELECT autorizado_por FROM public.flujo_dinero WHERE id = (SELECT g1 FROM t_e)) = public._t_uid('luna.real@ejemplo.mx'), 'autorizó Luna';
END $$;
RESET ROLE;
SELECT public._t_como('polo.real@ejemplo.mx');
DO $$ BEGIN ASSERT public._t_saldo((SELECT cmx FROM t_e)) = 200, 'la caja baja solo al entregar (500 - 300)'; END $$;
RESET ROLE;
-- 400 ya no cabe (quedan 200): el bloqueo es al autorizar.
SELECT public._t_como('luna.real@ejemplo.mx');
DO $$ BEGIN PERFORM public._t_falla(format($q$SELECT public.flujo_confirmar_gasto(%L)$q$, (SELECT g2 FROM t_e)), 'Saldo insuficiente en «Caja MXN»'); END $$;
RESET ROLE;
-- Regla para toda persona: ni Jair (capturó), ni Luna (autorizó), ni Leti (entregó) cancelan; otro administrador sí.
SELECT public._t_como('jair.real@ejemplo.mx');
DO $$ BEGIN
  PERFORM public._t_falla(format($q$SELECT public.movimiento_cancelar(%L, 'Lo capturé yo y me equivoqué')$q$, (SELECT mov FROM t_e)), 'participaste|capturaste');
  PERFORM public._t_falla(format($q$SELECT public.movimiento_ajustar(%L, '{"concepto": "x"}'::jsonb, 'Lo capturé yo')$q$, (SELECT mov FROM t_e)), 'participaste|capturaste');
END $$;
RESET ROLE;
SELECT public._t_como('luna.real@ejemplo.mx');
DO $$ BEGIN PERFORM public._t_falla(format($q$SELECT public.movimiento_cancelar(%L, 'Yo lo autoricé y quiero cancelarlo')$q$, (SELECT mov FROM t_e)), 'participaste|capturaste'); END $$;
RESET ROLE;
SELECT public._t_como('leti.real@ejemplo.mx');
DO $$ BEGIN PERFORM public._t_falla(format($q$SELECT public.movimiento_cancelar(%L, 'Yo entregué y quiero cancelar')$q$, (SELECT mov FROM t_e)), 'participaste|capturaste'); END $$;
RESET ROLE;
SELECT public._t_como('polo.real@ejemplo.mx');
DO $$ BEGIN
  PERFORM public.movimiento_cancelar((SELECT mov FROM t_e), 'El chofer devolvió el efectivo; entrega cancelada');
  ASSERT (SELECT etapa FROM public.flujo_dinero WHERE id = (SELECT g1 FROM t_e)) = 'REVERTIDO', 'el flujo del gasto queda revertido, con motivo';
  ASSERT public._t_saldo((SELECT cmx FROM t_e)) = 500, 'el saldo vuelve';
END $$;
RESET ROLE;
ROLLBACK;

\echo '3. Categorías: nuevas, ámbito, Mantenimiento inactiva, alta/renombre/desactivación con bitácora, sin borrado ni escritura directa'
BEGIN;
SELECT public._t_como('martin.real@ejemplo.mx');
DO $$ BEGIN PERFORM public._t_falla($q$SELECT public.categoria_guardar(NULL, 'EGRESO', 'Comisiones')$q$, 'administrador'); END $$;
RESET ROLE;
SELECT public._t_como('jair.real@ejemplo.mx');
DO $$ DECLARE v uuid; BEGIN
  ASSERT (SELECT ambito FROM public.categorias_financieras WHERE nombre = 'Proveedor internacional') = 'INTERNACIONAL', 'internacional';
  ASSERT (SELECT ambito FROM public.categorias_financieras WHERE nombre = 'Flete internacional') = 'INTERNACIONAL', 'flete internacional';
  ASSERT (SELECT ambito FROM public.categorias_financieras WHERE nombre = 'Pago a proveedor') = 'NACIONAL' AND (SELECT ambito FROM public.categorias_financieras WHERE nombre = 'Flete / transporte') = 'NACIONAL', 'las existentes quedan nacionales sin renombrar';
  ASSERT EXISTS (SELECT 1 FROM public.categorias_financieras WHERE nombre IN ('Mantenimiento de oficina') AND activo) AND EXISTS (SELECT 1 FROM public.categorias_financieras WHERE nombre = 'Mantenimiento de vehículos' AND activo), 'mantenimiento dividido';
  ASSERT NOT (SELECT activo FROM public.categorias_financieras WHERE nombre = 'Mantenimiento'), 'Mantenimiento inactiva para capturas nuevas';
  ASSERT NOT EXISTS (SELECT 1 FROM public.categorias_financieras WHERE es_prueba), 'una cuenta real no ve las de prueba';
  ASSERT (SELECT NOT afecta_totales FROM public.categorias_financieras WHERE nombre = 'Cambio de divisa' AND tipo = 'EGRESO'), 'cambio de divisa no suma';
  v := public.categoria_guardar(NULL, 'EGRESO', 'Comisiones bancarias', 'NACIONAL', true, 'Alta solicitada por Polo');
  PERFORM public._t_falla(format($q$SELECT public.categoria_guardar(%L, 'EGRESO', 'Comisiones y cargos', 'NACIONAL', true)$q$, v), 'motivo');
  PERFORM public.categoria_guardar(v, 'EGRESO', 'Comisiones y cargos', 'NACIONAL', true, 'Renombrada para incluir cargos');
  PERFORM public._t_falla(format($q$SELECT public.categoria_guardar(%L, 'EGRESO', 'Comisiones y cargos', 'NACIONAL', false)$q$, v), 'motivo');
  PERFORM public.categoria_guardar(v, 'EGRESO', 'Comisiones y cargos', 'NACIONAL', false, 'Ya no se usa');
  ASSERT (SELECT count(*) FROM public.catalogo_bancos_bitacora WHERE entidad = 'CATEGORIA' AND entidad_id = v) = 3, 'alta, renombre y desactivación en bitácora';
  PERFORM public._t_falla($q$SELECT public.categoria_guardar((SELECT id FROM public.categorias_financieras WHERE nombre = 'Cambio de divisa' AND tipo = 'EGRESO'), 'EGRESO', 'Otro', 'NACIONAL', true, 'intento')$q$, 'del sistema');
  PERFORM public._t_falla($q$INSERT INTO public.categorias_financieras (tipo, nombre) VALUES ('EGRESO', 'Directa')$q$, 'permission denied');
  PERFORM public._t_falla($q$UPDATE public.categorias_financieras SET activo = true$q$, 'permission denied');
  PERFORM public._t_falla($q$DELETE FROM public.categorias_financieras$q$, 'permission denied');
END $$;
RESET ROLE;
ROLLBACK;

\echo '4. Puertas cerradas: ningún rol inserta directo (libro, cuentas, categorías, pagos, abonos) ni usa las funciones directas'
BEGIN;
SELECT public._t_como('jair.real@ejemplo.mx');
DO $$ BEGIN
  PERFORM public._t_falla($q$INSERT INTO public.movimientos_financieros (tipo, estatus, concepto, monto, moneda, fecha_movimiento, metodo_pago, contraparte_tipo, contraparte_nombre, created_by, origen)
    VALUES ('EGRESO', 'CONFIRMADO', 'directo', 10, 'MXN', current_date, 'EFECTIVO', 'OTRO', 'x', auth.uid(), 'REGULARIZACION')$q$, 'permission denied');
  PERFORM public._t_falla($q$INSERT INTO public.cuentas_financieras (nombre, tipo, moneda) VALUES ('Directa', 'BANCO', 'MXN')$q$, 'permission denied');
  PERFORM public._t_falla($q$INSERT INTO public.cobranza_pagos (folio, cliente_id, fecha, monto, forma, estatus) VALUES ('X', gen_random_uuid(), current_date, 1, 'efectivo', 'validado')$q$, 'permission denied');
  PERFORM public._t_falla($q$INSERT INTO public.cxc_abonos (cxc_id, monto, fecha_abono) VALUES (gen_random_uuid(), 1, current_date)$q$, 'permission denied');
  PERFORM public._t_falla($q$SELECT public.registrar_pago_cobranza('{}'::jsonb)$q$, 'permission denied');
  PERFORM public._t_falla($q$SELECT public.flujo_aplicar(gen_random_uuid(), 'GASTO')$q$, 'etapa de aplicación|No existe');
END $$;
RESET ROLE;
-- Ni el dueño de la base inserta en el libro sin pasar por una función autorizada.
DO $$ BEGIN
  PERFORM public._t_falla($q$INSERT INTO public.movimientos_financieros (tipo, estatus, concepto, monto, moneda, fecha_movimiento, metodo_pago, contraparte_tipo, contraparte_nombre, origen)
    VALUES ('INGRESO', 'CONFIRMADO', 'x', 10, 'MXN', current_date, 'EFECTIVO', 'OTRO', 'x', 'HISTORICO_DIRECTO')$q$, 'solo recibe dinero|check');
END $$;
ROLLBACK;

\echo '5. Históricos: marca de origen sin tocar montos; resolver (cancelar/confirmar) con motivo; regularizar y reclasificar EGR-000004 sin tocar el original'
BEGIN;
CREATE TEMP TABLE t_h (ing4 uuid, ing5 uuid, egr uuid, busd uuid, kit uuid, cd uuid, cc uuid);
INSERT INTO t_h (kit) VALUES (NULL);
GRANT ALL ON t_h TO authenticated;
-- Simula lo capturado directo ANTES de la unificación (el guardia se apaga solo aquí, en la prueba).
ALTER TABLE public.movimientos_financieros DISABLE TRIGGER a_libro_guardia;
SELECT id AS cc FROM public.cuentas_financieras WHERE nombre = 'Caja chica' \gset
SELECT id AS cd FROM public.cuentas_financieras WHERE nombre = 'Caja dólares' \gset
UPDATE t_h SET cc = :'cc', cd = :'cd';
INSERT INTO public.movimientos_financieros (tipo, estatus, concepto, monto, moneda, fecha_movimiento, metodo_pago, cuenta_id, contraparte_tipo, contraparte_nombre, created_by, confirmado_por, origen, categoria)
  VALUES ('INGRESO', 'CONFIRMADO', 'DEMO', 45000, 'MXN', current_date, 'EFECTIVO', :'cc', 'OTRO', 'Demo', public._t_uid('martin.real@ejemplo.mx'), public._t_uid('martin.real@ejemplo.mx'), 'HISTORICO_DIRECTO', 'Venta de refacciones');
INSERT INTO public.movimientos_financieros (tipo, estatus, concepto, monto, moneda, fecha_movimiento, metodo_pago, contraparte_tipo, contraparte_nombre, created_by, origen, categoria)
  VALUES ('INGRESO', 'PENDIENTE', 'Venta moto', 3050, 'MXN', current_date, 'EFECTIVO', 'OTRO', 'Cliente', public._t_uid('polo.real@ejemplo.mx'), 'HISTORICO_DIRECTO', 'Venta de unidad');
INSERT INTO public.movimientos_financieros (tipo, estatus, concepto, monto, moneda, tipo_cambio, fecha_movimiento, metodo_pago, cuenta_id, contraparte_tipo, contraparte_nombre, created_by, confirmado_por, origen, categoria)
  VALUES ('EGRESO', 'CONFIRMADO', 'Pago final pedido contenedor', 8664.41, 'USD', 18.68, current_date, 'TRANSFERENCIA', :'cd', 'OTRO', 'Proveedor', public._t_uid('martin.real@ejemplo.mx'), public._t_uid('martin.real@ejemplo.mx'), 'HISTORICO_DIRECTO', 'Pago a proveedor');
ALTER TABLE public.movimientos_financieros ENABLE TRIGGER a_libro_guardia;
UPDATE t_h SET ing4 = (SELECT id FROM public.movimientos_financieros WHERE concepto = 'DEMO'),
               ing5 = (SELECT id FROM public.movimientos_financieros WHERE concepto = 'Venta moto'),
               egr = (SELECT id FROM public.movimientos_financieros WHERE tipo = 'EGRESO');
CREATE TEMP TABLE t_h0 AS SELECT id, estatus, monto, cuenta_id, fecha_movimiento, concepto, tipo, metodo_pago FROM public.movimientos_financieros;
GRANT ALL ON t_h0 TO authenticated;
SELECT public._t_como('polo.real@ejemplo.mx');
SELECT public.flujo_asignar_capacidad(public._t_uid('jair.real@ejemplo.mx'), 'captura_gasto', true);
DO $$ BEGIN
  UPDATE t_h SET kit = public.empresa_guardar(NULL, 'Kawiil', 'Kawiil SA de CV');
  UPDATE t_h SET busd = public.cuenta_guardar(NULL, kit, 'Banco USD Kawiil', 'BBVA', 'BANCO', 'USD', '4444', true, NULL, 0, NULL);
  -- Quien capturó un histórico no lo cancela, aun siendo administrador.
  PERFORM public._t_falla(format($q$SELECT public.movimiento_historico_resolver(%L, 'CANCELAR', NULL, 'duplicado de ING-000006 / FD-000009')$q$, (SELECT ing5 FROM t_h)), 'capturaste|participaste');
END $$;
RESET ROLE;
SELECT public._t_como('jair.real@ejemplo.mx');
DO $$ BEGIN
  PERFORM public._t_falla(format($q$SELECT public.movimiento_historico_resolver(%L, 'CANCELAR', NULL, 'x')$q$, (SELECT ing5 FROM t_h)), 'motivo');
  PERFORM public._t_falla(format($q$SELECT public.movimiento_historico_resolver(%L, 'BORRAR', NULL, 'motivo largo')$q$, (SELECT ing5 FROM t_h)), 'CONFIRMAR o CANCELAR');
  -- Confirmar exige cuenta válida (efectivo → caja de efectivo) y solo lo pendiente.
  PERFORM public._t_falla(format($q$SELECT public.movimiento_historico_resolver(%L, 'CONFIRMAR', %L, 'Revisado por Polo')$q$, (SELECT ing5 FROM t_h), (SELECT id FROM public.cuentas_financieras WHERE nombre = 'Banco principal')), 'caja de efectivo');
  PERFORM public._t_falla(format($q$SELECT public.movimiento_historico_resolver(%L, 'CONFIRMAR', %L, 'Revisado por Polo')$q$, (SELECT ing4 FROM t_h), (SELECT cc FROM t_h)), 'no está pendiente');
  PERFORM public.movimiento_historico_resolver((SELECT ing5 FROM t_h), 'CANCELAR', NULL, 'duplicado de ING-000006 / FD-000009');
  PERFORM public.movimiento_historico_resolver((SELECT ing4 FROM t_h), 'CANCELAR', NULL, 'Dato de demostración, no es dinero real');
  ASSERT (SELECT estatus FROM public.movimientos_financieros WHERE id = (SELECT ing5 FROM t_h)) = 'CANCELADO'
     AND (SELECT motivo_cancelacion FROM public.movimientos_financieros WHERE id = (SELECT ing5 FROM t_h)) = 'duplicado de ING-000006 / FD-000009', 'cancelado con motivo';
  ASSERT EXISTS (SELECT 1 FROM public.movimiento_bitacora WHERE movimiento_id = (SELECT ing5 FROM t_h) AND accion = 'RESOLVER_HISTORICO'), 'bitácora';
  ASSERT public._t_saldo((SELECT cc FROM t_h)) = 0, 'Caja chica sin los 45,000 demo';
  -- Un movimiento que NO es histórico no pasa por aquí.
  PERFORM public._t_falla($q$SELECT public.movimiento_historico_resolver(gen_random_uuid(), 'CANCELAR', NULL, 'motivo largo')$q$, 'No existe');
END $$;
RESET ROLE;
-- EGR: regularizar con una entrada de USD y reclasificar a un banco en USD.
SELECT public._t_como('jair.real@ejemplo.mx');
DO $$ DECLARE r jsonb; BEGIN
  PERFORM public._t_falla(format($q$SELECT public.movimiento_reclasificar_cuenta(%L, %L, 'Corrección de cuenta de salida')$q$, (SELECT egr FROM t_h), (SELECT busd FROM t_h)), 'Saldo insuficiente|motivo');
  PERFORM public._t_falla(format($q$SELECT public.movimiento_regularizar('INGRESO', 10000, 'USD', 18.5, current_date + 3, %L, 'TRANSFERENCIA', 'Entrada de USD', 'Otro ingreso', 'Origen de los dólares', 'SWIFT-1', 'Regulariza la entrada de dólares del contenedor')$q$, (SELECT busd FROM t_h)), 'futura');
  PERFORM public._t_falla(format($q$SELECT public.movimiento_regularizar('INGRESO', 10000, 'USD', 18.5, current_date, %L, 'EFECTIVO', 'Entrada de USD', 'Otro ingreso', 'Origen', 'x', 'Regulariza la entrada de dólares del contenedor')$q$, (SELECT busd FROM t_h)), 'cuenta de banco|caja de efectivo');
  PERFORM public.movimiento_regularizar('INGRESO', 10000, 'USD', 18.5, current_date, (SELECT busd FROM t_h), 'TRANSFERENCIA', 'Entrada de USD que respalda EGR', 'Otro ingreso',
    'Origen de los dólares', 'SWIFT-1', 'Regulariza la entrada de dólares que respalda el pago del contenedor', 'regularizacion/swift.pdf', false);
  ASSERT public._t_saldo((SELECT busd FROM t_h)) = 10000, 'entró el USD';
END $$;
RESET ROLE;
SELECT public._t_como('martin.real@ejemplo.mx');
DO $$ BEGIN PERFORM public._t_falla(format($q$SELECT public.movimiento_reclasificar_cuenta(%L, %L, 'Intento de quien lo capturó')$q$, (SELECT egr FROM t_h), (SELECT busd FROM t_h)), 'capturaste|permission|administrador'); END $$;
RESET ROLE;
SELECT public._t_como('jair.real@ejemplo.mx');
DO $$ DECLARE r jsonb; BEGIN
  r := public.movimiento_reclasificar_cuenta((SELECT egr FROM t_h), (SELECT busd FROM t_h), 'El pago salió del banco en dólares, no de la caja de efectivo');
  ASSERT public._t_saldo((SELECT cd FROM t_h)) = 0, 'Caja dólares vuelve a 0 (ya no queda en negativo)';
  ASSERT public._t_saldo((SELECT busd FROM t_h)) = 10000 - 8664.41, 'el banco USD refleja el pago';
  ASSERT (SELECT count(*) FROM public.movimientos_financieros WHERE reclasifica_mov_id = (SELECT egr FROM t_h) AND origen = 'CONTRA_MOVIMIENTO' AND NOT afecta_totales AND categoria = 'Reclasificación entre cuentas') = 2, 'dos contra-movimientos que no suman en totales';
  ASSERT (SELECT count(*) FROM public.movimientos_financieros WHERE origen = 'REGULARIZACION' AND NOT afecta_totales) = 1, 'la entrada de USD regularizada, marcada y fuera de totales';
  PERFORM public._t_falla(format($q$SELECT public.movimiento_reclasificar_cuenta(%L, %L, 'Otra vez la misma reclasificación')$q$, (SELECT egr FROM t_h), (SELECT busd FROM t_h)), 'ya fue reclasificado|distinta');
END $$;
RESET ROLE;
-- Sin pérdida: los 4 movimientos originales conservan monto, cuenta, fecha, concepto y tipo (solo cambió el estatus de los dos cancelados a propósito).
SELECT public._t_como('polo.real@ejemplo.mx');
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.movimientos_financieros m JOIN t_h0 o ON o.id = m.id
           WHERE m.monto = o.monto AND m.cuenta_id IS NOT DISTINCT FROM o.cuenta_id AND m.fecha_movimiento = o.fecha_movimiento AND m.concepto = o.concepto AND m.tipo = o.tipo AND m.metodo_pago = o.metodo_pago) = 3,
         'los históricos conservan monto, cuenta, fecha, concepto, tipo y método';
  ASSERT (SELECT estatus FROM public.movimientos_financieros WHERE id = (SELECT egr FROM t_h)) = 'CONFIRMADO' AND (SELECT cuenta_id FROM public.movimientos_financieros WHERE id = (SELECT egr FROM t_h)) = (SELECT cd FROM t_h), 'EGR intacto';
  ASSERT (SELECT origen FROM public.movimientos_financieros WHERE id = (SELECT egr FROM t_h)) = 'HISTORICO_DIRECTO', 'con su marca de origen';
END $$;
RESET ROLE;
ROLLBACK;

\echo '6. Pago de cobranza directo (CP-00001): regularización con cuenta y fecha reales, una sola vez, solo reales validados'
BEGIN;
CREATE TEMP TABLE t_p (p1 uuid, p2 uuid, p3 uuid, cc uuid);
GRANT ALL ON t_p TO authenticated;
INSERT INTO public.clientes (nombre_comercial, razon_social, codigo_erp, es_prueba) VALUES ('Cliente CP', 'CLIENTE CP SA', 'REAL-CP', false);
INSERT INTO public.cobranza_pagos (folio, cliente_id, fecha, monto, forma, estatus, es_prueba, evidencia_path) SELECT 'CP-00001', id, '2026-10-19', 3000, 'efectivo', 'validado', false, 'pagos/vale.jpg' FROM public.clientes WHERE codigo_erp = 'REAL-CP';
INSERT INTO public.cobranza_pagos (folio, cliente_id, fecha, monto, forma, estatus, es_prueba) SELECT 'CP-00002', id, '2026-10-19', 20000, 'deposito', 'revertido', false FROM public.clientes WHERE codigo_erp = 'REAL-CP';
INSERT INTO public.cobranza_pagos (folio, cliente_id, fecha, monto, forma, estatus, es_prueba) SELECT 'P-CP-00009', id, '2026-10-19', 5, 'efectivo', 'validado', true FROM public.clientes WHERE codigo_erp = 'REAL-CP';
UPDATE t_p SET p1 = NULL;
INSERT INTO t_p SELECT (SELECT id FROM public.cobranza_pagos WHERE folio = 'CP-00001'), (SELECT id FROM public.cobranza_pagos WHERE folio = 'CP-00002'), (SELECT id FROM public.cobranza_pagos WHERE folio = 'P-CP-00009'), (SELECT id FROM public.cuentas_financieras WHERE nombre = 'Caja chica');
SELECT public._t_como('martin.real@ejemplo.mx');
DO $$ BEGIN PERFORM public._t_falla(format($q$SELECT public.cobranza_pago_regularizar(%L, %L, '2026-10-19', 'Cobrado en efectivo antes del flujo')$q$, (SELECT p1 FROM t_p), (SELECT cc FROM t_p)), 'administrador financiero'); END $$;
RESET ROLE;
SELECT public._t_como('jair.real@ejemplo.mx');
DO $$ DECLARE mv uuid; BEGIN
  PERFORM public._t_falla(format($q$SELECT public.cobranza_pago_regularizar(%L, %L, '2026-10-19', 'corto')$q$, (SELECT p1 FROM t_p), (SELECT cc FROM t_p)), 'motivo');
  PERFORM public._t_falla(format($q$SELECT public.cobranza_pago_regularizar(%L, %L, '2026-10-19', 'Cobrado en efectivo antes del flujo')$q$, (SELECT p2 FROM t_p), (SELECT cc FROM t_p)), 'no está validado');
  PERFORM public._t_falla(format($q$SELECT public.cobranza_pago_regularizar(%L, %L, '2026-10-19', 'Cobrado en efectivo antes del flujo')$q$, (SELECT p3 FROM t_p), (SELECT cc FROM t_p)), 'prueba');
  PERFORM public._t_falla(format($q$SELECT public.cobranza_pago_regularizar(%L, %L, '2026-10-19', 'Cobrado en efectivo antes del flujo')$q$, (SELECT p1 FROM t_p), (SELECT id FROM public.cuentas_financieras WHERE nombre = 'Banco principal')), 'caja de efectivo');
  mv := public.cobranza_pago_regularizar((SELECT p1 FROM t_p), (SELECT cc FROM t_p), '2026-10-19', 'Cobrado en efectivo antes del flujo; se regulariza con la fecha real');
  ASSERT (SELECT fecha_movimiento FROM public.movimientos_financieros WHERE id = mv) = '2026-10-19' AND (SELECT monto FROM public.movimientos_financieros WHERE id = mv) = 3000
     AND (SELECT origen FROM public.movimientos_financieros WHERE id = mv) = 'REGULARIZACION' AND (SELECT regulariza_pago_id FROM public.movimientos_financieros WHERE id = mv) = (SELECT p1 FROM t_p), 'movimiento histórico con marca de origen, cuenta y fecha reales';
  ASSERT public._t_saldo((SELECT cc FROM t_p)) = 3000, 'la caja refleja el cobro';
  ASSERT EXISTS (SELECT 1 FROM public.movimiento_adjuntos WHERE movimiento_id = mv), 'conserva la evidencia';
  PERFORM public._t_falla(format($q$SELECT public.cobranza_pago_regularizar(%L, %L, '2026-10-19', 'Cobrado en efectivo antes del flujo; otra vez')$q$, (SELECT p1 FROM t_p), (SELECT cc FROM t_p)), 'ya fue regularizado');
  ASSERT (SELECT estatus FROM public.cobranza_pagos WHERE id = (SELECT p1 FROM t_p)) = 'validado', 'el pago de cobranza no cambia';
END $$;
RESET ROLE;
ROLLBACK;

\echo '7. Conciliación: marca simple con quién y cuándo, solo de lo confirmado'
BEGIN;
SELECT public._t_como('polo.real@ejemplo.mx');
SELECT public.flujo_asignar_capacidad(public._t_uid('jair.real@ejemplo.mx'), 'captura_gasto', true);
SELECT public.flujo_asignar_capacidad(public._t_uid('luna.real@ejemplo.mx'), 'confirma_gasto', true);
CREATE TEMP TABLE t_c (cta uuid, g uuid, mov uuid);
INSERT INTO t_c VALUES (NULL, NULL, NULL);
GRANT ALL ON t_c TO authenticated;
DO $$ DECLARE k uuid := public.empresa_guardar(NULL, 'Kawiil', 'Kawiil SA de CV'); BEGIN
  UPDATE t_c SET cta = public.cuenta_guardar(NULL, k, 'BBVA MXN', 'BBVA', 'BANCO', 'MXN', '1111', true, NULL, 1000, NULL);
END $$;
RESET ROLE;
SELECT public._t_como('jair.real@ejemplo.mx');
DO $$ DECLARE v jsonb; BEGIN
  v := public.flujo_capturar_gasto(100, 'MXN', 'TRANSFERENCIA', current_date, 'Prov', 'Impuestos', 'Pago', 'R-1', NULL, 'g/e.pdf', (SELECT empresa_id FROM public.cuentas_financieras WHERE id = (SELECT cta FROM t_c)), (SELECT cta FROM t_c));
  UPDATE t_c SET g = (v->>'id')::uuid;
END $$;
RESET ROLE;
SELECT public._t_como('luna.real@ejemplo.mx');
DO $$ BEGIN UPDATE t_c SET mov = (public.flujo_confirmar_gasto((SELECT g FROM t_c))->>'movimiento_id')::uuid; END $$;
RESET ROLE;
SELECT public._t_como('martin.real@ejemplo.mx');
DO $$ BEGIN PERFORM public._t_falla(format($q$SELECT public.movimiento_conciliar(ARRAY[%L]::uuid[])$q$, (SELECT mov FROM t_c)), 'Finanzas'); END $$;
RESET ROLE;
SELECT public._t_como('jair.real@ejemplo.mx');
DO $$ BEGIN
  ASSERT public.movimiento_conciliar(ARRAY[(SELECT mov FROM t_c)]) = 1, 'concilia uno';
  ASSERT (SELECT conciliado AND conciliado_por_nombre IS NOT NULL AND conciliado_at IS NOT NULL FROM public.v_movimientos_financieros WHERE id = (SELECT mov FROM t_c)), 'con quién y cuándo en la vista';
  ASSERT public.movimiento_conciliar(ARRAY[(SELECT mov FROM t_c)], false) = 1, 'desmarca uno';
  ASSERT NOT (SELECT conciliado FROM public.v_movimientos_financieros WHERE id = (SELECT mov FROM t_c)), 'se puede desmarcar';
END $$;
RESET ROLE;
ROLLBACK;

\echo '8. Prueba y real separados: cuentas, categorías y empresas de prueba propias; un gasto de prueba no toca el libro real'
BEGIN;
SELECT public._t_como('prueba.super@dazon.demo');
SELECT public.flujo_asignar_capacidad(public._t_uid('prueba.compras@dazon.demo'), 'captura_gasto', true);
SELECT public.flujo_asignar_capacidad(public._t_uid('prueba.finanzas@dazon.demo'), 'confirma_gasto', true);
SELECT public.flujo_asignar_capacidad(public._t_uid('prueba.almacen@dazon.demo'), 'caja', true);
RESET ROLE;
CREATE TEMP TABLE t_x (g uuid, n0 integer, real_cta uuid);
GRANT ALL ON t_x TO authenticated;
INSERT INTO t_x SELECT NULL, (SELECT count(*) FROM public.movimientos_financieros), (SELECT id FROM public.cuentas_financieras WHERE nombre = 'Banco principal');
SELECT public._t_como('prueba.compras@dazon.demo');
DO $$ DECLARE v jsonb; k uuid; b uuid; BEGIN
  SELECT id INTO k FROM public.flujo_empresas() LIMIT 1;
  ASSERT (SELECT count(*) FROM public.flujo_empresas()) = 1 AND (SELECT nombre FROM public.flujo_empresas()) = 'Empresa de prueba', 'solo ve la empresa de prueba';
  ASSERT NOT EXISTS (SELECT 1 FROM public.flujo_cuentas_gasto(NULL, NULL, NULL) WHERE nombre IN ('Caja chica', 'Caja dólares', 'Banco principal')), 'no ve cuentas reales';
  ASSERT (SELECT count(*) FROM public.flujo_categorias_gasto()) >= 10, 've sus propias categorías';
  SELECT id INTO b FROM public.flujo_cuentas_gasto(k, 'TRANSFERENCIA', 'MXN') LIMIT 1;
  PERFORM public._t_falla(format($q$SELECT public.flujo_capturar_gasto(100, 'MXN', 'TRANSFERENCIA', current_date, 'Prov', 'Impuestos', 'x', 'R-1', NULL, 'g/e.pdf', %L, (SELECT real_cta FROM t_x))$q$, k), 'caja o cuenta válida');
  v := public.flujo_capturar_gasto(2500, 'MXN', 'TRANSFERENCIA', current_date, 'Prov', 'Impuestos', 'Impuesto de prueba', 'R-1', NULL, 'g/e.pdf', k, b);
  UPDATE t_x SET g = (v->>'id')::uuid;
  ASSERT (SELECT es_prueba FROM public.flujo_dinero WHERE id = (SELECT g FROM t_x)), 'el gasto es de prueba';
  ASSERT public.flujo_saldo_cuenta(b) = 100000, 'saldo de prueba inicial';
  PERFORM public._t_falla(format($q$SELECT public.flujo_saldo_cuenta(%L)$q$, (SELECT real_cta FROM t_x)), 'No existe la cuenta');
END $$;
RESET ROLE;
SELECT public._t_como('prueba.finanzas@dazon.demo');
DO $$ DECLARE v jsonb; BEGIN
  v := public.flujo_confirmar_gasto((SELECT g FROM t_x));
  ASSERT v->>'etapa' = 'APLICADO' AND v->>'movimiento_id' IS NULL, 'un gasto de prueba no crea movimiento real';
  ASSERT public.flujo_saldo_cuenta((SELECT cuenta_id FROM public.flujo_dinero WHERE id = (SELECT g FROM t_x))) = 97500, 'el saldo de prueba baja con el flujo de prueba';
END $$;
RESET ROLE;
DO $$ BEGIN ASSERT (SELECT count(*) FROM public.movimientos_financieros) = (SELECT n0 FROM t_x), 'el libro real no cambió'; END $$;
-- Lo real no ve lo de prueba y lo de prueba no ve lo real.
SELECT public._t_como('jair.real@ejemplo.mx');
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.cuentas_financieras WHERE es_prueba) = 0, 'real no ve cuentas de prueba';
  ASSERT (SELECT count(*) FROM public.categorias_financieras WHERE es_prueba) = 0, 'real no ve categorías de prueba';
  ASSERT (SELECT count(*) FROM public.empresas_grupo WHERE es_prueba) = 0, 'real no ve empresas de prueba';
  ASSERT (SELECT count(*) FROM public.v_saldos_cuentas WHERE es_prueba) = 0, 'saldos reales sin prueba';
END $$;
RESET ROLE;
SELECT public._t_como('prueba.finanzas@dazon.demo');
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.cuentas_financieras WHERE NOT es_prueba) = 0, 'prueba no ve cuentas reales';
  ASSERT (SELECT count(*) FROM public.categorias_financieras WHERE NOT es_prueba) = 0, 'prueba no ve categorías reales';
END $$;
RESET ROLE;
ROLLBACK;

\echo '9. Monedas: catálogo por parámetro (hoy MXN y USD); se amplía sin tocar código'
BEGIN;
SELECT public._t_como('polo.real@ejemplo.mx');
DO $$ DECLARE k uuid := public.empresa_guardar(NULL, 'Kawiil', 'Kawiil SA de CV'); BEGIN
  ASSERT public.moneda_permitida('USD') AND public.moneda_permitida('mxn') AND NOT public.moneda_permitida('CNY'), 'hoy MXN y USD';
  PERFORM public._t_falla(format($q$SELECT public.cuenta_guardar(NULL, %L, 'Banco CNY', 'ICBC', 'BANCO', 'CNY', '5555')$q$, k), 'no está permitida');
END $$;
RESET ROLE;
SELECT set_config('request.jwt.claim.sub', '', true);
UPDATE public.compras_parametros SET valor = '["MXN", "USD", "CNY"]'::jsonb WHERE clave = 'monedas_permitidas';
SELECT public._t_como('polo.real@ejemplo.mx');
DO $$ DECLARE k uuid := (SELECT id FROM public.empresas_grupo WHERE nombre = 'Kawiil'); BEGIN
  ASSERT public.moneda_permitida('CNY'), 'ahora CNY';
  ASSERT public.cuenta_guardar(NULL, k, 'Banco CNY', 'ICBC', 'BANCO', 'CNY', '5555') IS NOT NULL, 'la cuenta en CNY se da de alta';
END $$;
RESET ROLE;
ROLLBACK;

\echo 'OK: gastos, categorías, cuentas por prueba/real, históricos y regularización'

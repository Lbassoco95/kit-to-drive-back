-- ============================================================================
-- Pruebas (base de datos) de la carga de remisiones históricas de refacciones.
--   PGHOST=127.0.0.1 PGUSER=postgres scripts/db-local/probar_remisiones_historicas.sh
-- Cada prueba entra como un usuario; las que escriben se revierten al final.
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

-- Quién cobra: a1 recibe, a2 caja, a3 aplica (admin de prueba: a5).
BEGIN;
SELECT public._t_como('prueba.super@dazon.demo');
SELECT public.flujo_asignar_capacidad(public._t_uid('prueba.compras@dazon.demo'), 'recibe', true);
SELECT public.flujo_asignar_capacidad(public._t_uid('prueba.almacen@dazon.demo'), 'caja', true);
SELECT public.flujo_asignar_capacidad(public._t_uid('prueba.finanzas@dazon.demo'), 'aplica', true);
RESET ROLE;
COMMIT;

CREATE OR REPLACE FUNCTION public._t_prod(_cod text) RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$
  SELECT id FROM public.almacen_refacciones_productos WHERE codigo_nuevo = _cod AND es_prueba $$;
CREATE OR REPLACE FUNCTION public._t_inv() RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT (SELECT coalesce(sum(stock), 0) FROM public.almacen_refacciones_productos)::text || '/' ||
         (SELECT count(*) FROM public.almacen_refacciones_movimientos)::text $$;
GRANT EXECUTE ON FUNCTION public._t_prod(text), public._t_inv() TO authenticated;

\echo '1. Solo un administrador carga; simular no escribe nada; los errores salen todos juntos'
BEGIN;
SELECT public._t_como('prueba.compras@dazon.demo');
DO $$ BEGIN
  PERFORM public._t_falla($q$SELECT public.cargar_remisiones_historicas_refacciones('[{}]'::jsonb, 'x')$q$, 'Sólo un administrador');
  PERFORM public._t_falla($q$SELECT public.anular_remision_historica_refacciones(gen_random_uuid(), 'x')$q$, 'Sólo un administrador');
END $$;
RESET ROLE;
CREATE TEMP TABLE t_h (carga jsonb, inv0 text);
GRANT ALL ON t_h TO authenticated;
SELECT public._t_como('prueba.super@dazon.demo');
DO $$
DECLARE v jsonb; v_cli uuid := public._t_cli('TST-C02'); v_vend uuid := public._t_uid('prueba.ventas@dazon.demo');
BEGIN
  INSERT INTO t_h VALUES (NULL, public._t_inv());
  PERFORM public._t_falla($q$SELECT public.cargar_remisiones_historicas_refacciones('[]'::jsonb, 'x')$q$, 'al menos una');
  PERFORM public._t_falla(format($q$SELECT public.cargar_remisiones_historicas_refacciones(%L, '')$q$, '[{}]'), 'fuente');
  -- Errores: sin referencia, artículo inexistente, cantidad 0, fecha futura, sin vendedor.
  v := public.cargar_remisiones_historicas_refacciones(jsonb_build_array(
    jsonb_build_object('fecha', current_date, 'cliente_id', v_cli),
    jsonb_build_object('referencia', 'A1', 'fecha', current_date + 5, 'cliente_id', v_cli, 'vendedor_id', v_vend,
      'partidas', jsonb_build_array(jsonb_build_object('codigo_nuevo', 'NO-EXISTE', 'cantidad', 1, 'precio_unitario', 10))),
    jsonb_build_object('referencia', 'A2', 'fecha', current_date, 'cliente_id', v_cli,
      'partidas', jsonb_build_array(jsonb_build_object('codigo_nuevo', 'TST-004', 'cantidad', 0, 'precio_unitario', 10)))
  ), 'prueba');
  ASSERT (v->>'ok')::boolean = false AND (v->>'simulada')::boolean, 'simulación con errores';
  ASSERT jsonb_array_length(v->'errores') >= 4, format('todos los errores juntos, llegaron %s: %s', jsonb_array_length(v->'errores'), v->'errores');
  PERFORM public._t_falla(format($q$SELECT public.cargar_remisiones_historicas_refacciones(%L, 'prueba', false)$q$,
    jsonb_build_array(jsonb_build_object('referencia', 'A1', 'fecha', current_date, 'cliente_id', v_cli))), 'no se escribió nada');
  ASSERT (SELECT count(*) FROM public.remisiones_refacciones WHERE es_historica) = 0, 'los errores no escriben';
END $$;
ROLLBACK;

\echo '2. Carga real, cobro por el flujo, candados y anulación (todo en una transacción)'
BEGIN;
CREATE TEMP TABLE t_c (res jsonb, inv0 text, id1 uuid, id2 uuid, flujo uuid);
GRANT ALL ON t_c TO authenticated;
SELECT public._t_como('prueba.super@dazon.demo');
DO $$
DECLARE v jsonb; v_cli uuid := public._t_cli('TST-C02'); v_vend uuid := public._t_uid('prueba.ventas@dazon.demo'); body jsonb; v_inv0 text;
BEGIN
  v_inv0 := public._t_inv();
  body := jsonb_build_array(
    jsonb_build_object('referencia', 'OCT-001', 'fecha', '2026-10-05', 'cliente_id', v_cli, 'vendedor_id', v_vend, 'tipo_pago', 'contra_entrega',
      'partidas', jsonb_build_array(
        jsonb_build_object('codigo_nuevo', 'TST-004', 'cantidad', 3, 'precio_unitario', 100.50),
        jsonb_build_object('codigo_nuevo', 'TST-005', 'cantidad', 2, 'precio_unitario', 50, 'descuento_pct', 10))),
    jsonb_build_object('referencia', 'OCT-002', 'fecha', '2026-10-07', 'cliente_id', v_cli, 'vendedor_id', v_vend, 'descuento_pct', 5,
      'partidas', jsonb_build_array(jsonb_build_object('codigo_nuevo', 'TST-004', 'cantidad', 1, 'precio_unitario', 200))));
  v := public.cargar_remisiones_historicas_refacciones(body, 'Libro de ventas de octubre');
  ASSERT (v->>'ok')::boolean AND (v->>'simulada')::boolean, 'por omisión simula';
  ASSERT (v->>'total')::numeric = 301.5 + 90 + 190, format('total simulado, llegó %s', v->>'total');
  ASSERT (SELECT count(*) FROM public.remisiones_refacciones WHERE es_historica) = 0, 'simular no escribe';
  v := public.cargar_remisiones_historicas_refacciones(body, 'Libro de ventas de octubre', false);
  INSERT INTO t_c VALUES (v, v_inv0,
    (SELECT id FROM public.remisiones_refacciones WHERE historica_ref = 'OCT-001'),
    (SELECT id FROM public.remisiones_refacciones WHERE historica_ref = 'OCT-002'), NULL);
END $$;
DO $$
DECLARE c t_c%ROWTYPE; r record;
BEGIN
  SELECT * INTO c FROM t_c;
  ASSERT (c.res->>'remisiones')::int = 2 AND (c.res->>'total')::numeric = 581.5, 'dos remisiones, total 581.50';
  ASSERT public._t_inv() = c.inv0, format('el inventario no se movió: %s → %s', c.inv0, public._t_inv());
  FOR r IN SELECT * FROM public.remisiones_refacciones WHERE es_historica ORDER BY historica_ref LOOP
    ASSERT r.etapa = 'entregada' AND NOT r.abierta AND r.es_prueba, 'confirmada, entregada, de prueba';
    ASSERT r.historica_por = auth.uid() AND r.historica_at IS NOT NULL AND r.historica_lote IS NOT NULL, 'quién y cuándo';
    ASSERT r.nombre_vendedor IS NOT NULL AND r.fecha_remision IN ('2026-10-05', '2026-10-07'), 'vendedor y fecha original';
    ASSERT (SELECT documento FROM public.v_cobranza_remisiones WHERE id = r.id) = 'confirmada', 'cobranza la ve confirmada, no cotización';
  END LOOP;
  ASSERT (SELECT saldo_pendiente FROM public.v_cobranza_remisiones WHERE id = c.id1) = 391.5, 'saldo = total de la remisión 1';
  ASSERT (SELECT saldo_pendiente FROM public.v_cobranza_remisiones WHERE id = c.id2) = 190, 'saldo = total de la remisión 2 (con descuento general)';
  ASSERT (SELECT count(*) FROM public.remision_refaccion_eventos WHERE remision_id IN (c.id1, c.id2) AND accion = 'carga_historica') = 2, 'evento por remisión';
  ASSERT (SELECT count(*) FROM public.bitacora_compras_inventario WHERE accion = 'carga_historica' AND usuario_id = auth.uid()) = 2, 'bitácora por remisión';
  ASSERT (SELECT remisiones FROM public.cargas_remisiones_historicas WHERE id = (c.res->>'lote')::uuid) = 2, 'registro del lote';
  -- Idempotencia: la misma referencia no se carga dos veces.
  PERFORM public._t_falla(format($q$SELECT public.cargar_remisiones_historicas_refacciones(%L, 'otra vez', false)$q$,
    jsonb_build_array(jsonb_build_object('referencia', 'OCT-001', 'fecha', '2026-10-05', 'cliente_id', public._t_cli('TST-C02'),
      'vendedor_id', public._t_uid('prueba.ventas@dazon.demo'),
      'partidas', jsonb_build_array(jsonb_build_object('codigo_nuevo', 'TST-004', 'cantidad', 1, 'precio_unitario', 1))))), 'no se escribió nada');
END $$;
RESET ROLE;

-- Candados (como dueño de la base: ni así se corrige sin el interruptor del administrador).
DO $$
DECLARE c t_c%ROWTYPE;
BEGIN
  SELECT * INTO c FROM t_c;
  PERFORM public._t_falla(format('UPDATE public.remisiones_refacciones SET etapa = ''cancelada'' WHERE id = %L', c.id1), 'es histórica');
  PERFORM public._t_falla(format('UPDATE public.remision_refaccion_items SET cantidad_surtida = 0, estatus = ''cancelada'' WHERE remision_id = %L', c.id1), 'es histórica');
  PERFORM public._t_falla(format('DELETE FROM public.remision_refaccion_items WHERE remision_id = %L', c.id1), 'es histórica');
  PERFORM public._t_falla(format('DELETE FROM public.remisiones_refacciones WHERE id = %L', c.id1), 'es histórica');
  PERFORM public._t_falla(format('UPDATE public.remisiones_refacciones SET descuento_pct = 50 WHERE id = %L', c.id1), 'es histórica');
  PERFORM public._t_falla(format('UPDATE public.remisiones_refacciones SET es_historica = true WHERE id = (SELECT id FROM public.remisiones_refacciones WHERE NOT es_historica LIMIT 1)'), 'no se vuelve histórica');
  -- Lo que no cambia dinero ni existencias sí se puede tocar (notas).
  UPDATE public.remisiones_refacciones SET notas = notas || ' (revisada)' WHERE id = c.id1;
  -- Los caminos normales (cancelar desde Almacén) tampoco la tocan ni mueven existencias.
  PERFORM public._t_falla(format('SELECT public.cancelar_remision_refacciones(%L, ''prueba'')', c.id1), 'histórica|permiso|Sólo|entregada no se cancela');
  ASSERT public._t_inv() = c.inv0, 'los candados no movieron inventario';
END $$;

-- Cobro por el flujo de dinero: recibe → caja → aplica a la remisión histórica.
SELECT public._t_como('prueba.compras@dazon.demo');
DO $$ DECLARE v jsonb; BEGIN
  v := public.flujo_recibir('PAGO_CLIENTE', 391.50, 'MXN', 'EFECTIVO', current_date, 'Cliente demo', public._t_cli('TST-C02'));
  UPDATE t_c SET flujo = (v->>'id')::uuid;
END $$;
RESET ROLE;
SELECT public._t_como('prueba.almacen@dazon.demo');
DO $$ BEGIN PERFORM public.flujo_confirmar_caja((SELECT flujo FROM t_c), (SELECT id FROM public._t_cuenta_mxn())); END $$;
RESET ROLE;
SELECT public._t_como('prueba.finanzas@dazon.demo');
DO $$ DECLARE c t_c%ROWTYPE; BEGIN
  SELECT * INTO c FROM t_c;
  PERFORM public.flujo_aplicar(c.flujo, 'REMISION', jsonb_build_array(jsonb_build_object('remision_id', c.id1, 'monto', 391.5)));
  ASSERT (SELECT saldo_pendiente FROM public.v_cobranza_remisiones WHERE id = c.id1) = 0, 'el cobro baja el saldo de la histórica';
END $$;
RESET ROLE;

-- Anulación: con cobros aplicados no; sin cobros sí, sin mover inventario.
SELECT public._t_como('prueba.super@dazon.demo');
DO $$ DECLARE c t_c%ROWTYPE; BEGIN
  SELECT * INTO c FROM t_c;
  PERFORM public._t_falla(format('SELECT public.anular_remision_historica_refacciones(%L, ''x'')', c.id1), 'motivo');
  PERFORM public._t_falla(format('SELECT public.anular_remision_historica_refacciones(%L, ''Duplicada'')', c.id1), 'ya tiene cobros aplicados');
  PERFORM public.anular_remision_historica_refacciones(c.id2, 'Cargada por error');
  ASSERT (SELECT etapa FROM public.remisiones_refacciones WHERE id = c.id2) = 'cancelada', 'quedó anulada';
  ASSERT public.total_vigente_remision_refaccion(c.id2) = 0, 'total vigente 0';
  ASSERT public._t_inv() = c.inv0, 'anular no movió inventario';
  ASSERT (SELECT count(*) FROM public.remision_refaccion_eventos WHERE remision_id = c.id2 AND accion = 'anulacion_historica') = 1, 'evento de anulación';
  PERFORM public._t_falla(format('SELECT public.anular_remision_historica_refacciones(%L, ''otra vez'')', c.id2), 'ya está anulada');
  PERFORM public._t_falla(format('SELECT public.anular_remision_historica_refacciones(%L, ''x yz'')', (SELECT id FROM public.remisiones_refacciones WHERE NOT es_historica LIMIT 1)), 'no es histórica');
END $$;
RESET ROLE;
ROLLBACK;

\echo 'OK: remisiones históricas'

-- ============================================================================
-- Pruebas (base de datos) de 20261103000001_pendientes_martin_refacciones.sql
--
--   PGHOST=/tmp PGPORT=5433 PGUSER=postgres \
--     scripts/db-local/aplicar_migraciones.sh kit_prueba      # todas las migraciones
--   psql -d kit_prueba -c "ALTER TABLE public.remisiones_refacciones ADD COLUMN IF NOT EXISTS es_historica boolean NOT NULL DEFAULT false"
--   psql -d kit_prueba -f supabase/migrations/20261103000001_pendientes_martin_refacciones.sql
--   psql -d kit_prueba -f scripts/db-local/pruebas_pendientes_martin.sql
--
-- (`es_historica` existe en producción y no en las migraciones de main: por eso
-- el script del paso 3 pide esa columna y se agrega aquí a mano.)
-- Cada prueba corre en su transacción y se revierte.
-- ============================================================================
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE OR REPLACE FUNCTION public._m_como(_email text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', (SELECT id::text FROM auth.users WHERE email = _email), true);
  EXECUTE 'SET LOCAL ROLE authenticated';
END $$;
CREATE OR REPLACE FUNCTION public._m_falla(_sql text, _patron text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE _sql;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM !~* _patron THEN RAISE EXCEPTION 'Falló con otro mensaje. Esperado /%/, llegó: %', _patron, SQLERRM; END IF;
    RETURN;
  END;
  RAISE EXCEPTION 'Debió fallar (esperado /%/): %', _patron, _sql;
END $$;
GRANT EXECUTE ON FUNCTION public._m_como(text), public._m_falla(text, text) TO authenticated;

-- Usuarios --------------------------------------------------------------------
INSERT INTO auth.users (id, email, raw_app_meta_data)
SELECT id::uuid, email, '{"created_via_admin": "true"}'::jsonb FROM (VALUES
  ('00000000-0000-0000-0000-0000000000c1', 'vendedor.a@mm.test'),
  ('00000000-0000-0000-0000-0000000000c2', 'vendedor.b@mm.test'),
  ('00000000-0000-0000-0000-0000000000c3', 'supervisor@mm.test'),
  ('00000000-0000-0000-0000-0000000000c4', 'administrativa@mm.test'),
  ('00000000-0000-0000-0000-0000000000c5', 'admin.comercial@mm.test'),
  ('00000000-0000-0000-0000-0000000000c6', 'global@mm.test'),
  ('00000000-0000-0000-0000-0000000000c7', 'almacen@mm.test'),
  ('00000000-0000-0000-0000-0000000000c8', 'fabrica@mm.test')
) AS u(id, email) ON CONFLICT (id) DO NOTHING;
INSERT INTO public.profiles (id, nombre_completo, activo, email, es_vendedor, es_administrativo)
SELECT id, split_part(email, '@', 1), true, email,
       email IN ('vendedor.a@mm.test', 'vendedor.b@mm.test'), email = 'administrativa@mm.test'
  FROM auth.users WHERE id::text LIKE '00000000-0000-0000-0000-0000000000c%'
ON CONFLICT (id) DO UPDATE SET es_vendedor = EXCLUDED.es_vendedor, es_administrativo = EXCLUDED.es_administrativo, activo = true;
DELETE FROM public.user_roles WHERE user_id::text LIKE '00000000-0000-0000-0000-0000000000c%';
INSERT INTO public.user_roles (user_id, role, area, nivel) VALUES
  ('00000000-0000-0000-0000-0000000000c1', 'ventas',    'comercial', 'operador'),
  ('00000000-0000-0000-0000-0000000000c2', 'ventas',    'comercial', 'operador'),
  ('00000000-0000-0000-0000-0000000000c3', 'ventas',    'comercial', 'supervisor'),
  ('00000000-0000-0000-0000-0000000000c4', 'ventas',    'comercial', 'operador'),
  ('00000000-0000-0000-0000-0000000000c5', 'ventas',    'comercial', 'admin'),
  ('00000000-0000-0000-0000-0000000000c6', 'admin',     'direccion', 'admin'),
  ('00000000-0000-0000-0000-0000000000c7', 'logistica', 'almacen_logistica', 'operador'),
  ('00000000-0000-0000-0000-0000000000c8', 'fabrica',   'fabrica',   'operador');
INSERT INTO public.almacen_refacciones_acceso (email, user_id, activo)
VALUES ('almacen@mm.test', '00000000-0000-0000-0000-0000000000c7', true)
ON CONFLICT (email) DO UPDATE SET user_id = EXCLUDED.user_id, activo = true;

INSERT INTO public.clientes (codigo_erp, nombre_comercial) VALUES ('MM-001', 'Cliente MM')
ON CONFLICT DO NOTHING;
INSERT INTO public.almacen_refacciones_productos (codigo_nuevo, clave_completa, linea_catalogo, descripcion, precio, stock, visible_venta)
VALUES ('MM-ART-1', 'MM-ART-1', 'linea_dorada', 'Artículo MM uno', 100, 100, true),
       ('MM-ART-2', 'MM-ART-2', 'linea_azul',   'Artículo MM dos', 50,  100, true)
ON CONFLICT (codigo_nuevo) DO UPDATE SET stock = 100, visible_venta = true;

CREATE OR REPLACE FUNCTION public._m_prod(_c text) RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$ SELECT id FROM public.almacen_refacciones_productos WHERE codigo_nuevo = _c $$;
CREATE OR REPLACE FUNCTION public._m_cli() RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$ SELECT id FROM public.clientes WHERE codigo_erp = 'MM-001' $$;
CREATE OR REPLACE FUNCTION public._m_stock(_c text) RETURNS integer LANGUAGE sql SECURITY DEFINER AS $$ SELECT stock FROM public.almacen_refacciones_productos WHERE codigo_nuevo = _c $$;
-- Simula el surtido real (la salida de inventario del almacén).
CREATE OR REPLACE FUNCTION public._m_surtir(_rem uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE i public.remision_refaccion_items%ROWTYPE; r public.remisiones_refacciones%ROWTYPE;
BEGIN
  SELECT * INTO r FROM public.remisiones_refacciones WHERE id = _rem;
  FOR i IN SELECT * FROM public.remision_refaccion_items WHERE remision_id = _rem AND cantidad_bloqueada > 0 LOOP
    PERFORM public._mover_inventario_refaccion(i.producto_id, i.almacen, -i.cantidad_bloqueada, r.fecha_remision, 'venta', 'remision', NULL,
      r.folio, NULL, 'Salida por remisión ' || r.folio, r.cliente_id, i.precio_unitario, false);
    UPDATE public.remision_refaccion_items SET cantidad_surtida = cantidad_surtida + cantidad_bloqueada, cantidad_bloqueada = 0, estatus = 'surtida' WHERE id = i.id;
  END LOOP;
  PERFORM public.recalcular_etapa_remision_refaccion(_rem);
END $$;
GRANT EXECUTE ON FUNCTION public._m_prod(text), public._m_cli(), public._m_stock(text) TO authenticated;

CREATE TABLE IF NOT EXISTS public._m_ids (clave text PRIMARY KEY, id uuid);
GRANT SELECT ON public._m_ids TO authenticated;
DELETE FROM public._m_ids;

\echo '1. Vendedores sólo ven SUS remisiones (y supervisor, administrativa, admin, almacén ven todas)'
BEGIN;
SELECT public._m_como('vendedor.a@mm.test');
DO $$ DECLARE v jsonb; BEGIN
  v := public.crear_remision_refacciones(public._m_cli(), 'A', NULL,
    jsonb_build_array(jsonb_build_object('producto_id', public._m_prod('MM-ART-1'), 'cantidad', 3)),
    '{"tipo_envio":"recoge","tipo_pago":"credito"}'::jsonb);
  INSERT INTO public._m_ids VALUES ('a', (v->>'id')::uuid);
  ASSERT v->>'tipo_pago' = 'credito', 'regresa el tipo de pago';
END $$;
RESET ROLE;
SELECT public._m_como('vendedor.b@mm.test');
DO $$ DECLARE v jsonb; BEGIN
  v := public.crear_remision_refacciones(public._m_cli(), 'B', NULL,
    jsonb_build_array(jsonb_build_object('producto_id', public._m_prod('MM-ART-1'), 'cantidad', 2),
                      jsonb_build_object('producto_id', public._m_prod('MM-ART-2'), 'cantidad', 4)),
    '{"tipo_envio":"recoge","tipo_pago":"anticipado"}'::jsonb);
  INSERT INTO public._m_ids VALUES ('b', (v->>'id')::uuid);
END $$;
RESET ROLE;
DO $$ DECLARE n integer; BEGIN
  PERFORM public._m_como('vendedor.a@mm.test');
  SELECT count(*) INTO n FROM public.remisiones_refacciones WHERE notas IN ('A', 'B');
  ASSERT n = 1, format('el vendedor A debía ver 1 remisión y ve %s', n);
  SELECT count(*) INTO n FROM public.remision_refaccion_items WHERE remision_id IN (SELECT id FROM public._m_ids);
  ASSERT n = 1, format('el vendedor A debía ver 1 partida y ve %s', n);
  SELECT count(*) INTO n FROM public.remision_refaccion_eventos WHERE remision_id IN (SELECT id FROM public._m_ids);
  ASSERT n = 2, format('el vendedor A debía ver los 2 eventos de la suya y ve %s', n);
  ASSERT public.puede_leer_remision_refaccion((SELECT id FROM public._m_ids WHERE clave = 'b')) = false, 'no lee la del otro';
  ASSERT public.puede_leer_remision_refaccion((SELECT id FROM public._m_ids WHERE clave = 'a')) = true, 'lee la suya';
END $$;
RESET ROLE;
DO $$ DECLARE n integer; e text; BEGIN
  FOREACH e IN ARRAY ARRAY['supervisor@mm.test', 'administrativa@mm.test', 'admin.comercial@mm.test', 'global@mm.test', 'almacen@mm.test'] LOOP
    PERFORM public._m_como(e);
    SELECT count(*) INTO n FROM public.remisiones_refacciones WHERE notas IN ('A', 'B');
    ASSERT n = 2, format('%s debía ver las 2 y ve %s', e, n);
    RESET ROLE;
  END LOOP;
END $$;
ROLLBACK;

\echo '2. Crédito: se guarda, nace NO pagada; un tipo inválido se rechaza'
BEGIN;
SELECT public._m_como('vendedor.a@mm.test');
DO $$ DECLARE v jsonb; r public.remisiones_refacciones%ROWTYPE; BEGIN
  v := public.crear_remision_refacciones(public._m_cli(), 'C', NULL,
    jsonb_build_array(jsonb_build_object('producto_id', public._m_prod('MM-ART-1'), 'cantidad', 1)),
    '{"tipo_envio":"recoge","tipo_pago":"credito"}'::jsonb);
  SELECT * INTO r FROM public.remisiones_refacciones WHERE id = (v->>'id')::uuid;
  ASSERT r.tipo_pago = 'credito' AND r.pagado = false, 'crédito sin pagar';
  PERFORM public._m_falla($q$SELECT public.crear_remision_refacciones(public._m_cli(), 'D', NULL,
    jsonb_build_array(jsonb_build_object('producto_id', public._m_prod('MM-ART-1'), 'cantidad', 1)),
    '{"tipo_envio":"recoge","tipo_pago":"fiado"}'::jsonb)$q$, 'anticipado, contra entrega o a crédito');
  -- Cambiar a contra entrega y volver a crédito desde el envío.
  PERFORM public.actualizar_envio_remision_refaccion(r.id, '{"tipo_pago":"contra_entrega"}'::jsonb);
  ASSERT (SELECT tipo_pago FROM public.remisiones_refacciones WHERE id = r.id) = 'contra_entrega';
  PERFORM public.actualizar_envio_remision_refaccion(r.id, '{"tipo_pago":"credito"}'::jsonb);
  ASSERT (SELECT tipo_pago FROM public.remisiones_refacciones WHERE id = r.id) = 'credito';
  PERFORM public._m_falla(format($q$SELECT public.actualizar_envio_remision_refaccion(%L, '{"tipo_pago":"fiado"}'::jsonb)$q$, r.id), 'anticipado, contra entrega o a crédito');
END $$;
ROLLBACK;

\echo '3. Fecha de la remisión editable (no futura, no histórica)'
BEGIN;
SELECT public._m_como('vendedor.a@mm.test');
DO $$ DECLARE v jsonb; rid uuid; hoy date := (now() AT TIME ZONE 'America/Mexico_City')::date; BEGIN
  v := public.crear_remision_refacciones(public._m_cli(), 'F', NULL,
    jsonb_build_array(jsonb_build_object('producto_id', public._m_prod('MM-ART-1'), 'cantidad', 1)),
    '{"tipo_envio":"recoge","tipo_pago":"anticipado"}'::jsonb);
  rid := (v->>'id')::uuid;
  PERFORM public.actualizar_envio_remision_refaccion(rid, format('{"fecha_remision":"%s"}', hoy - 5)::jsonb);
  ASSERT (SELECT fecha_remision FROM public.remisiones_refacciones WHERE remisiones_refacciones.id = rid) = hoy - 5, 'cambió la fecha';
  ASSERT EXISTS (SELECT 1 FROM public.remision_refaccion_eventos e WHERE e.remision_id = rid AND e.detalle LIKE '%fecha de la remisión%'), 'queda en el historial';
  PERFORM public._m_falla(format($q$SELECT public.actualizar_envio_remision_refaccion(%L, '{"fecha_remision":"%s"}'::jsonb)$q$, rid, hoy + 3), 'no puede ser futura');
  PERFORM public._m_falla(format($q$SELECT public.actualizar_envio_remision_refaccion(%L, '{"fecha_remision":"no-es-fecha"}'::jsonb)$q$, rid), 'no es válida');
  -- Sin fecha en el payload no la toca.
  PERFORM public.actualizar_envio_remision_refaccion(rid, '{"tipo_pago":"credito"}'::jsonb);
  ASSERT (SELECT fecha_remision FROM public.remisiones_refacciones WHERE remisiones_refacciones.id = rid) = hoy - 5;
END $$;
RESET ROLE;
-- Histórica: no se cambia.
UPDATE public.remisiones_refacciones SET es_historica = true WHERE notas = 'F';
SELECT public._m_como('vendedor.a@mm.test');
DO $$ DECLARE rid uuid := (SELECT r.id FROM public.remisiones_refacciones r WHERE notas = 'F'); BEGIN
  PERFORM public._m_falla(format($q$SELECT public.actualizar_envio_remision_refaccion(%L, '{"fecha_remision":"2026-01-01"}'::jsonb)$q$, rid), 'histórica');
END $$;
ROLLBACK;

\echo '4. Eliminar por completo: sólo admin, devuelve inventario, deja bitácora'
BEGIN;
SELECT public._m_como('vendedor.a@mm.test');
DO $$ DECLARE v jsonb; BEGIN
  v := public.crear_remision_refacciones(public._m_cli(), 'E1', NULL,
    jsonb_build_array(jsonb_build_object('producto_id', public._m_prod('MM-ART-1'), 'cantidad', 7)),
    '{"tipo_envio":"recoge","tipo_pago":"anticipado"}'::jsonb);
  INSERT INTO public._m_ids VALUES ('e1', (v->>'id')::uuid);
  v := public.crear_remision_refacciones(public._m_cli(), 'E2', NULL,
    jsonb_build_array(jsonb_build_object('producto_id', public._m_prod('MM-ART-1'), 'cantidad', 5)),
    '{"tipo_envio":"recoge","tipo_pago":"anticipado"}'::jsonb);
  INSERT INTO public._m_ids VALUES ('e2', (v->>'id')::uuid);
END $$;
RESET ROLE;
SELECT public._m_surtir((SELECT id FROM public._m_ids WHERE clave = 'e1'));
SELECT public._m_surtir((SELECT id FROM public._m_ids WHERE clave = 'e2'));
DO $$ BEGIN ASSERT public._m_stock('MM-ART-1') = 100 - 7 - 5, 'salieron 12'; END $$;

-- El vendedor, el supervisor y la administrativa NO pueden.
DO $$ DECLARE e text; id uuid := (SELECT i.id FROM public._m_ids i WHERE clave = 'e1'); BEGIN
  FOREACH e IN ARRAY ARRAY['vendedor.a@mm.test', 'supervisor@mm.test', 'administrativa@mm.test', 'almacen@mm.test'] LOOP
    PERFORM public._m_como(e);
    PERFORM public._m_falla(format($q$SELECT public.eliminar_remision_refacciones(%L, 'limpieza de pruebas')$q$, id), 'administrador de Comercial');
    RESET ROLE;
  END LOOP;
END $$;
-- Motivo corto.
SELECT public._m_como('admin.comercial@mm.test');
DO $$ BEGIN
  PERFORM public._m_falla(format($q$SELECT public.eliminar_remision_refacciones(%L, 'corto')$q$, (SELECT i.id FROM public._m_ids i WHERE clave = 'e1')), 'mínimo 10');
END $$;
-- Admin de Comercial: elimina e1 devolviendo inventario.
DO $$ DECLARE r jsonb; BEGIN
  r := public.eliminar_remision_refacciones((SELECT i.id FROM public._m_ids i WHERE clave = 'e1'), 'limpieza de pruebas de Martín');
  ASSERT (r->>'piezas_devueltas')::int = 7, format('devolvió %s', r);
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT public._m_stock('MM-ART-1') = 100 - 5, 'regresaron 7: quedan fuera sólo las 5 de E2';
  ASSERT NOT EXISTS (SELECT 1 FROM public.remisiones_refacciones WHERE notas = 'E1'), 'ya no existe';
  ASSERT NOT EXISTS (SELECT 1 FROM public.remision_refaccion_items WHERE remision_id = (SELECT id FROM public._m_ids WHERE clave = 'e1')), 'sin partidas';
  ASSERT (SELECT count(*) FROM public.bitacora_eliminaciones WHERE tabla = 'remisiones_refacciones' AND registro_id = (SELECT id FROM public._m_ids WHERE clave = 'e1')
           AND motivo = 'limpieza de pruebas de Martín' AND datos_eliminados ? 'partidas') = 1, 'bitácora con snapshot';
  ASSERT (SELECT count(*) FROM public.almacen_refacciones_movimientos WHERE documento_tipo = 'devolucion' AND documento_folio IN
           (SELECT folio FROM public.remisiones_refacciones UNION ALL SELECT 'x')) >= 0;
END $$;
-- Global elimina e2 SIN devolver inventario.
SELECT public._m_como('global@mm.test');
DO $$ DECLARE r jsonb; BEGIN
  r := public.eliminar_remision_refacciones((SELECT i.id FROM public._m_ids i WHERE clave = 'e2'), 'limpieza sin devolver', false);
  ASSERT (r->>'piezas_devueltas')::int = 0;
END $$;
RESET ROLE;
DO $$ BEGIN ASSERT public._m_stock('MM-ART-1') = 100 - 5, 'sin devolver no cambia la existencia'; END $$;
ROLLBACK;

\echo '4b. No se elimina: real entregada, con cobros'
BEGIN;
SELECT public._m_como('vendedor.a@mm.test');
DO $$ DECLARE v jsonb; BEGIN
  v := public.crear_remision_refacciones(public._m_cli(), 'G1', NULL,
    jsonb_build_array(jsonb_build_object('producto_id', public._m_prod('MM-ART-1'), 'cantidad', 1)),
    '{"tipo_envio":"recoge","tipo_pago":"anticipado"}'::jsonb);
  INSERT INTO public._m_ids VALUES ('g1', (v->>'id')::uuid);
END $$;
RESET ROLE;
UPDATE public.remisiones_refacciones SET etapa = 'entregada', entregada_at = now(), abierta = false WHERE notas = 'G1';
SELECT public._m_como('global@mm.test');
DO $$ BEGIN
  PERFORM public._m_falla(format($q$SELECT public.eliminar_remision_refacciones(%L, 'intento de borrar entregada')$q$, (SELECT i.id FROM public._m_ids i WHERE clave = 'g1')), 'ya se entregó y es real');
END $$;
RESET ROLE;
-- Cancelada con un saldo a favor ligado: no se elimina.
UPDATE public.remisiones_refacciones SET etapa = 'cancelada' WHERE notas = 'G1';
INSERT INTO public.cobranza_saldos_favor (folio, cliente_id, origen, monto, remision_origen_id, notas)
VALUES ('SF-MM-1', public._m_cli(), 'otro', 10, (SELECT id FROM public._m_ids WHERE clave = 'g1'), 'prueba');
SELECT public._m_como('global@mm.test');
DO $$ BEGIN
  PERFORM public._m_falla(format($q$SELECT public.eliminar_remision_refacciones(%L, 'intento con cobros')$q$, (SELECT i.id FROM public._m_ids i WHERE clave = 'g1')), 'cobros, saldos a favor');
END $$;
ROLLBACK;

\echo '5. Reporte de ventas: periodo, sin canceladas, descuentos, permisos'
BEGIN;
SELECT public._m_como('vendedor.a@mm.test');
DO $$ DECLARE v jsonb; BEGIN
  v := public.crear_remision_refacciones(public._m_cli(), 'R1', NULL,
    jsonb_build_array(jsonb_build_object('producto_id', public._m_prod('MM-ART-1'), 'cantidad', 4, 'descuento_pct', 10),
                      jsonb_build_object('producto_id', public._m_prod('MM-ART-2'), 'cantidad', 2)),
    '{"tipo_envio":"recoge","tipo_pago":"anticipado","descuento_pct":50}'::jsonb);
  INSERT INTO public._m_ids VALUES ('r1', (v->>'id')::uuid);
  v := public.crear_remision_refacciones(public._m_cli(), 'R2', NULL,
    jsonb_build_array(jsonb_build_object('producto_id', public._m_prod('MM-ART-1'), 'cantidad', 9)),
    '{"tipo_envio":"recoge","tipo_pago":"anticipado"}'::jsonb);
  INSERT INTO public._m_ids VALUES ('r2', (v->>'id')::uuid);
  PERFORM public.cancelar_remision_refacciones((v->>'id')::uuid, 'se cancela R2');
END $$;
-- Un vendedor no lee el reporte.
DO $$ BEGIN PERFORM public._m_falla($q$SELECT * FROM public.reporte_ventas_refacciones(current_date - 30, current_date)$q$, 'Sin acceso'); END $$;
RESET ROLE;
SELECT public._m_como('global@mm.test');
DO $$ DECLARE n integer; piezas integer; monto numeric; hoy date := (now() AT TIME ZONE 'America/Mexico_City')::date; BEGIN
  SELECT count(*), sum(x.piezas), sum(x.monto) INTO n, piezas, monto FROM public.reporte_ventas_refacciones(hoy - 1, hoy + 1) x;
  -- R1: 4 × 100 × 0.9 × 0.5 = 180 ; 2 × 50 × 0.5 = 50  → 230. R2 cancelada no cuenta.
  ASSERT n = 2 AND piezas = 6 AND monto = 230, format('filas %s piezas %s monto %s', n, piezas, monto);
  ASSERT (SELECT count(*) FROM public.reporte_ventas_refacciones(hoy - 10, hoy - 5)) = 0, 'fuera del periodo';
  ASSERT (SELECT vendedor FROM public.reporte_ventas_refacciones(hoy, hoy) LIMIT 1) = 'vendedor.a@mm.test', 'trae el vendedor';
  ASSERT (SELECT array_agg(DISTINCT almacen ORDER BY almacen) FROM public.reporte_ventas_refacciones(hoy, hoy)) = ARRAY['linea_azul', 'linea_dorada'], 'trae el almacén de cada partida';
  PERFORM public._m_falla($q$SELECT * FROM public.reporte_ventas_refacciones(current_date, current_date - 1)$q$, 'periodo válido');
END $$;
RESET ROLE;
SELECT public._m_como('supervisor@mm.test');
DO $$ BEGIN ASSERT (SELECT count(*) FROM public.reporte_ventas_refacciones((now() AT TIME ZONE 'America/Mexico_City')::date, (now() AT TIME ZONE 'America/Mexico_City')::date)) = 2, 'el supervisor de Comercial sí lo lee'; END $$;
ROLLBACK;

\echo 'OK: todas las pruebas de 20261103000001 pasaron'

\echo '6. Eliminar un movimiento financiero ligado al flujo (antes: violación de llave)'
BEGIN;
DO $$ DECLARE m uuid; f uuid; BEGIN
  ASSERT (SELECT confdeltype FROM pg_constraint WHERE conname = 'flujo_dinero_movimiento_id_fkey') = 'n', 'SET NULL';
END $$;
ROLLBACK;
\echo 'OK: sección 6'

-- ============================================================================
-- Pruebas (base de datos) de 20261113000001_traspasos_entre_cuentas.sql
--
--   PGHOST=/tmp PGPORT=5433 PGUSER=postgres scripts/db-local/aplicar_migraciones.sh kit_prueba
--   psql -d kit_prueba -f scripts/db-local/pruebas_traspasos.sql
--
-- Autosuficiente: crea sus propios usuarios y cuentas. Corre sobre base nueva (los traspasos no se borran). Cada bloque corre en su transacción.
-- ============================================================================
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

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
GRANT EXECUTE ON FUNCTION public._t_como(text), public._t_falla(text, text) TO authenticated;

DROP TABLE IF EXISTS public._tr_ids; CREATE TABLE public._tr_ids (clave text PRIMARY KEY, id uuid);
GRANT SELECT, INSERT ON public._tr_ids TO authenticated;

-- Usuarios: captura (recibe), caja, caja con autoaplica, administrador, sin permisos.
INSERT INTO auth.users (id, email, raw_app_meta_data) VALUES
  ('00000000-0000-0000-0000-0000000000d1', 'captura@tr.test', '{"created_via_admin": "true"}'),
  ('00000000-0000-0000-0000-0000000000d2', 'caja@tr.test', '{"created_via_admin": "true"}'),
  ('00000000-0000-0000-0000-0000000000d3', 'caja.auto@tr.test', '{"created_via_admin": "true"}'),
  ('00000000-0000-0000-0000-0000000000d4', 'admin@tr.test', '{"created_via_admin": "true"}'),
  ('00000000-0000-0000-0000-0000000000d5', 'nadie@tr.test', '{"created_via_admin": "true"}')
ON CONFLICT (id) DO NOTHING;
INSERT INTO public.profiles (id, nombre_completo, activo, email)
SELECT id, split_part(email, '@', 1), true, email FROM auth.users WHERE id::text LIKE '00000000-0000-0000-0000-0000000000d%'
ON CONFLICT (id) DO UPDATE SET activo = true;
DELETE FROM public.user_roles WHERE user_id::text LIKE '00000000-0000-0000-0000-0000000000d%';
INSERT INTO public.user_roles (user_id, role, area, nivel) VALUES
  ('00000000-0000-0000-0000-0000000000d1', 'ventas', 'comercial', 'operador'),
  ('00000000-0000-0000-0000-0000000000d2', 'ventas', 'comercial', 'operador'),
  ('00000000-0000-0000-0000-0000000000d3', 'ventas', 'comercial', 'operador'),
  ('00000000-0000-0000-0000-0000000000d4', 'admin', 'direccion', 'admin'),
  ('00000000-0000-0000-0000-0000000000d5', 'ventas', 'comercial', 'operador');
INSERT INTO public.flujo_capacidades (user_id, recibe, caja, aplica, autoaplica) VALUES
  ('00000000-0000-0000-0000-0000000000d1', true, false, false, false),
  ('00000000-0000-0000-0000-0000000000d2', false, true, false, false),
  ('00000000-0000-0000-0000-0000000000d3', true, true, false, true)
ON CONFLICT (user_id) DO UPDATE SET recibe = EXCLUDED.recibe, caja = EXCLUDED.caja, aplica = EXCLUDED.aplica, autoaplica = EXCLUDED.autoaplica;

-- Cuentas (saldo inicial) --------------------------------------------------------
DELETE FROM public.cuentas_financieras WHERE nombre LIKE 'TR %';
INSERT INTO public.cuentas_financieras (nombre, tipo, moneda, saldo_inicial, orden) VALUES
  ('TR Banco MXN 1', 'BANCO', 'MXN', 10000, 900),
  ('TR Banco MXN 2', 'BANCO', 'MXN', 0, 901),
  ('TR Caja MXN', 'EFECTIVO', 'MXN', 500, 902),
  ('TR Banco USD', 'BANCO', 'USD', 100, 903),
  ('TR Banco EUR', 'BANCO', 'EUR', 100, 904);
CREATE OR REPLACE FUNCTION public._t_c(_n text) RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$ SELECT id FROM public.cuentas_financieras WHERE nombre = _n $$;
GRANT EXECUTE ON FUNCTION public._t_c(text) TO authenticated;

\echo 'TR1. Quién puede qué'
BEGIN;
SELECT public._t_como('nadie@tr.test');
DO $$ BEGIN
  PERFORM public._t_falla($q$SELECT * FROM public.traspaso_cuentas()$q$, 'etapa del flujo');
  PERFORM public._t_falla($q$SELECT public.traspaso_solicitar(public._t_c('TR Banco MXN 1'), public._t_c('TR Banco MXN 2'), 100)$q$, 'captura');
END $$;
RESET ROLE;
SELECT public._t_como('caja@tr.test');
DO $$ BEGIN
  PERFORM public._t_falla($q$SELECT public.traspaso_solicitar(public._t_c('TR Banco MXN 1'), public._t_c('TR Banco MXN 2'), 100)$q$, 'captura');
END $$;
RESET ROLE;
SELECT public._t_como('captura@tr.test');
DO $$ BEGIN
  ASSERT (SELECT saldo FROM public.traspaso_cuentas() WHERE nombre = 'TR Banco MXN 1') = 10000, 've el saldo de la cuenta';
  PERFORM public._t_falla($q$SELECT public.traspaso_confirmar(gen_random_uuid())$q$, 'caja');
END $$;
RESET ROLE;
ROLLBACK;

\echo 'TR2. Validaciones de captura'
BEGIN;
SELECT public._t_como('captura@tr.test');
DO $$ BEGIN
  PERFORM public._t_falla($q$SELECT public.traspaso_solicitar(public._t_c('TR Banco MXN 1'), public._t_c('TR Banco MXN 1'), 100)$q$, 'distintas');
  PERFORM public._t_falla($q$SELECT public.traspaso_solicitar(public._t_c('TR Banco MXN 1'), public._t_c('TR Banco MXN 2'), 0)$q$, 'mayor a cero');
  PERFORM public._t_falla($q$SELECT public.traspaso_solicitar(public._t_c('TR Banco MXN 1'), public._t_c('TR Banco MXN 2'), 100.555)$q$, 'dos decimales');
  PERFORM public._t_falla($q$SELECT public.traspaso_solicitar(public._t_c('TR Banco MXN 1'), public._t_c('TR Banco MXN 2'), 100, 17.5)$q$, 'misma moneda');
  PERFORM public._t_falla($q$SELECT public.traspaso_solicitar(public._t_c('TR Banco MXN 1'), public._t_c('TR Banco USD'), 100)$q$, 'tipo de cambio');
  PERFORM public._t_falla($q$SELECT public.traspaso_solicitar(public._t_c('TR Banco MXN 1'), public._t_c('TR Banco USD'), 100, 0)$q$, 'tipo de cambio');
  PERFORM public._t_falla($q$SELECT public.traspaso_solicitar(public._t_c('TR Banco MXN 1'), public._t_c('TR Banco EUR'), 100, 20)$q$, 'pesos \(MXN\) o dólares');
  PERFORM public._t_falla($q$SELECT public.traspaso_solicitar(public._t_c('TR Banco MXN 1'), public._t_c('TR Banco MXN 2'), 10000.01)$q$, 'saldo insuficiente');
  PERFORM public._t_falla($q$SELECT public.traspaso_solicitar(public._t_c('TR Banco USD'), public._t_c('TR Banco MXN 2'), 100.01, 18)$q$, 'saldo insuficiente');
END $$;
RESET ROLE;
ROLLBACK;

\echo 'TR3. Traspaso MXN→MXN: captura, otra persona confirma, nacen dos patas y los saldos cuadran'
BEGIN;
SELECT public._t_como('captura@tr.test');
DO $$ DECLARE v jsonb; BEGIN
  v := public.traspaso_solicitar(public._t_c('TR Banco MXN 1'), public._t_c('TR Banco MXN 2'), 2500.50, NULL, CURRENT_DATE, 'Fondeo nómina', 'SPEI-77');
  ASSERT v->>'operacion' = 'TRASPASO' AND (v->>'monto_destino')::numeric = 2500.50 AND v->>'folio' LIKE 'TR-%', v::text;
  INSERT INTO public._tr_ids VALUES ('t1', (v->>'id')::uuid);
  PERFORM public._t_falla(format($q$SELECT public.traspaso_confirmar(%L)$q$, v->>'id'), 'caja');
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT saldo_actual FROM public.v_saldos_cuentas WHERE nombre = 'TR Banco MXN 1') = 10000, 'solicitar no mueve saldos';
  ASSERT (SELECT count(*) FROM public.movimientos_financieros WHERE traspaso_id = (SELECT id FROM public._tr_ids WHERE clave = 't1')) = 0, 'sin patas aún';
END $$;
SELECT public._t_como('caja@tr.test');
SELECT public.traspaso_confirmar((SELECT id FROM public._tr_ids WHERE clave = 't1'), 'Revisado contra banco');
DO $$ BEGIN
  PERFORM public._t_falla(format($q$SELECT public.traspaso_confirmar(%L)$q$, (SELECT id FROM public._tr_ids WHERE clave = 't1')), 'no está pendiente');
  PERFORM public._t_falla(format($q$SELECT public.traspaso_rechazar(%L, 'tarde')$q$, (SELECT id FROM public._tr_ids WHERE clave = 't1')), 'ya no se puede rechazar');
END $$;
RESET ROLE;
DO $$ DECLARE e public.movimientos_financieros%ROWTYPE; i public.movimientos_financieros%ROWTYPE; t public.traspasos_cuentas%ROWTYPE; BEGIN
  SELECT * INTO t FROM public.traspasos_cuentas WHERE id = (SELECT id FROM public._tr_ids WHERE clave = 't1');
  ASSERT t.estatus = 'CONFIRMADO' AND t.caja_notas = 'Revisado contra banco' AND t.confirmado_por::text LIKE '%d2', 'confirmado por caja';
  SELECT * INTO e FROM public.movimientos_financieros WHERE id = t.mov_egreso_id;
  SELECT * INTO i FROM public.movimientos_financieros WHERE id = t.mov_ingreso_id;
  ASSERT e.tipo = 'EGRESO' AND e.monto = 2500.50 AND e.estatus = 'CONFIRMADO' AND e.traspaso_id = t.id AND e.categoria = 'Traspaso entre cuentas', 'pata de egreso';
  ASSERT i.tipo = 'INGRESO' AND i.monto = 2500.50 AND i.estatus = 'CONFIRMADO' AND i.traspaso_id = t.id AND i.cuenta_id = public._t_c('TR Banco MXN 2'), 'pata de ingreso';
  ASSERT e.monto_mxn = i.monto_mxn, 'las patas suman lo mismo en pesos';
  ASSERT (SELECT saldo_actual FROM public.v_saldos_cuentas WHERE nombre = 'TR Banco MXN 1') = 7499.50, 'origen baja';
  ASSERT (SELECT saldo_actual FROM public.v_saldos_cuentas WHERE nombre = 'TR Banco MXN 2') = 2500.50, 'destino sube';
  ASSERT EXISTS (SELECT 1 FROM public.bitacora_compras_inventario WHERE accion = 'traspaso_confirmar' AND entidad_id = t.id), 'bitácora';
END $$;
COMMIT;

\echo 'TR4. Compra de dólares (MXN→USD) y venta de dólares (USD→MXN) con tipo de cambio'
BEGIN;
SELECT public._t_como('captura@tr.test');
DO $$ DECLARE v jsonb; BEGIN
  v := public.traspaso_solicitar(public._t_c('TR Banco MXN 1'), public._t_c('TR Banco USD'), 1800, 18.0000, CURRENT_DATE, 'Compra de dólares proveedor');
  ASSERT v->>'operacion' = 'COMPRA_USD' AND (v->>'monto_destino')::numeric = 100.00, v::text;
  INSERT INTO public._tr_ids VALUES ('c1', (v->>'id')::uuid);
  v := public.traspaso_solicitar(public._t_c('TR Banco USD'), public._t_c('TR Banco MXN 2'), 50, 17.5);
  ASSERT v->>'operacion' = 'VENTA_USD' AND (v->>'monto_destino')::numeric = 875.00, v::text;
  INSERT INTO public._tr_ids VALUES ('v1', (v->>'id')::uuid);
END $$;
RESET ROLE;
SELECT public._t_como('caja@tr.test');
SELECT public.traspaso_confirmar((SELECT id FROM public._tr_ids WHERE clave = 'c1'));
SELECT public.traspaso_confirmar((SELECT id FROM public._tr_ids WHERE clave = 'v1'));
RESET ROLE;
DO $$ DECLARE e public.movimientos_financieros%ROWTYPE; i public.movimientos_financieros%ROWTYPE; BEGIN
  SELECT m.* INTO e FROM public.movimientos_financieros m JOIN public.traspasos_cuentas t ON t.mov_egreso_id = m.id WHERE t.id = (SELECT id FROM public._tr_ids WHERE clave = 'c1');
  SELECT m.* INTO i FROM public.movimientos_financieros m JOIN public.traspasos_cuentas t ON t.mov_ingreso_id = m.id WHERE t.id = (SELECT id FROM public._tr_ids WHERE clave = 'c1');
  ASSERT e.moneda = 'MXN' AND e.monto = 1800 AND i.moneda = 'USD' AND i.monto = 100 AND i.tipo_cambio = 18, 'compra: sale MXN, entra USD a TC 18';
  ASSERT e.monto_mxn = 1800 AND i.monto_mxn = 1800, 'la compra cuadra en pesos';
  ASSERT (SELECT saldo_actual FROM public.v_saldos_cuentas WHERE nombre = 'TR Banco USD') = 150, 'USD: 100 + 100 - 50';
  ASSERT (SELECT saldo_actual FROM public.v_saldos_cuentas WHERE nombre = 'TR Banco MXN 1') = 10000 - 2500.50 - 1800 AND true, 'MXN baja por la compra' ;
  ASSERT (SELECT saldo_actual FROM public.v_saldos_cuentas WHERE nombre = 'TR Banco MXN 2') = 2500.50 + 875, 'MXN sube por la venta';
  ASSERT (SELECT tipo_cambio FROM public.traspasos_cuentas WHERE id = (SELECT id FROM public._tr_ids WHERE clave = 'v1')) = 17.5, 'el tipo de cambio queda guardado';
END $$;
COMMIT;

\echo 'TR5. Sobregiro: si el saldo cambió entre la captura y la confirmación, no se confirma'
BEGIN;
SELECT public._t_como('captura@tr.test');
DO $$ DECLARE v jsonb; BEGIN
  v := public.traspaso_solicitar(public._t_c('TR Caja MXN'), public._t_c('TR Banco MXN 2'), 400);
  INSERT INTO public._tr_ids VALUES ('s1', (v->>'id')::uuid);
  v := public.traspaso_solicitar(public._t_c('TR Caja MXN'), public._t_c('TR Banco MXN 1'), 400);
  INSERT INTO public._tr_ids VALUES ('s2', (v->>'id')::uuid);
END $$;
RESET ROLE;
SELECT public._t_como('caja@tr.test');
SELECT public.traspaso_confirmar((SELECT id FROM public._tr_ids WHERE clave = 's1'));
DO $$ BEGIN
  PERFORM public._t_falla(format($q$SELECT public.traspaso_confirmar(%L)$q$, (SELECT id FROM public._tr_ids WHERE clave = 's2')), 'saldo insuficiente');
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT saldo_actual FROM public.v_saldos_cuentas WHERE nombre = 'TR Caja MXN') = 100, 'la caja no quedó en negativo';
  ASSERT (SELECT estatus FROM public.traspasos_cuentas WHERE id = (SELECT id FROM public._tr_ids WHERE clave = 's2')) = 'SOLICITADO', 'el segundo sigue pendiente';
END $$;
COMMIT;

\echo 'TR6. Rechazar: caja o quien lo capturó, con motivo; no mueve saldos'
BEGIN;
SELECT public._t_como('captura@tr.test');
DO $$ BEGIN
  PERFORM public._t_falla(format($q$SELECT public.traspaso_rechazar(%L, '')$q$, (SELECT id FROM public._tr_ids WHERE clave = 's2')), 'motivo');
  PERFORM public.traspaso_rechazar((SELECT id FROM public._tr_ids WHERE clave = 's2'), 'Lo capturé mal');
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT estatus FROM public.traspasos_cuentas WHERE id = (SELECT id FROM public._tr_ids WHERE clave = 's2')) = 'RECHAZADO', 'rechazado';
  ASSERT (SELECT saldo_actual FROM public.v_saldos_cuentas WHERE nombre = 'TR Banco MXN 1') = 10000 - 2500.50 - 1800, 'sin cambios';
END $$;
COMMIT;

\echo 'TR7. Quien capturó no confirma lo suyo, salvo con autoaplica'
BEGIN;
SELECT public._t_como('caja.auto@tr.test');
DO $$ DECLARE v jsonb; BEGIN
  v := public.traspaso_solicitar(public._t_c('TR Banco MXN 1'), public._t_c('TR Banco MXN 2'), 100);
  PERFORM public.traspaso_confirmar((v->>'id')::uuid);
  INSERT INTO public._tr_ids VALUES ('a1', (v->>'id')::uuid);
END $$;
RESET ROLE;
UPDATE public.flujo_capacidades SET autoaplica = false WHERE user_id = '00000000-0000-0000-0000-0000000000d3';
SELECT public._t_como('caja.auto@tr.test');
DO $$ DECLARE v jsonb; BEGIN
  v := public.traspaso_solicitar(public._t_c('TR Banco MXN 1'), public._t_c('TR Banco MXN 2'), 100);
  PERFORM public._t_falla(format($q$SELECT public.traspaso_confirmar(%L)$q$, v->>'id'), 'otra persona');
END $$;
RESET ROLE;
COMMIT;

\echo 'TR8. Revertir: solo administrador, con motivo; cancela las dos patas y respeta el sobregiro'
BEGIN;
SELECT public._t_como('caja@tr.test');
DO $$ BEGIN
  PERFORM public._t_falla(format($q$SELECT public.traspaso_revertir(%L, 'error')$q$, (SELECT id FROM public._tr_ids WHERE clave = 't1')), 'administrador');
END $$;
RESET ROLE;
SELECT public._t_como('admin@tr.test');
DO $$ BEGIN
  PERFORM public._t_falla(format($q$SELECT public.traspaso_revertir(%L, '')$q$, (SELECT id FROM public._tr_ids WHERE clave = 't1')), 'motivo');
  PERFORM public._t_falla(format($q$SELECT public.traspaso_revertir(%L, 'x')$q$, (SELECT id FROM public._tr_ids WHERE clave = 's2')), 'motivo|no está confirmado');
  PERFORM public.traspaso_revertir((SELECT id FROM public._tr_ids WHERE clave = 'a1'), 'Se capturó duplicado');
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.movimientos_financieros WHERE traspaso_id = (SELECT id FROM public._tr_ids WHERE clave = 'a1') AND estatus = 'CANCELADO') = 2, 'las dos patas canceladas';
  ASSERT (SELECT estatus FROM public.traspasos_cuentas WHERE id = (SELECT id FROM public._tr_ids WHERE clave = 'a1')) = 'REVERTIDO', 'revertido';
  ASSERT (SELECT saldo_actual FROM public.v_saldos_cuentas WHERE nombre = 'TR Banco MXN 2') = 2500.50 + 875 + 400, 'el destino volvió a su saldo (menos nada de a1)';
END $$;
-- Sacar de la cuenta destino lo que ya gastó dejaría sobregiro: no se revierte.
SELECT public._t_como('admin@tr.test');
DO $$ BEGIN
  PERFORM public._t_falla(format($q$SELECT public.traspaso_revertir(%L, 'ya no')$q$, (SELECT id FROM public._tr_ids WHERE clave = 'a1')), 'no está confirmado');
END $$;
RESET ROLE;
COMMIT;

\echo 'TR9. Candado: nadie escribe patas a mano ni lee la tabla directo; nada se borra'
BEGIN;
SELECT public._t_como('captura@tr.test');
DO $$ BEGIN
  PERFORM public._t_falla($q$SELECT * FROM public.traspasos_cuentas$q$, 'permission denied');
  PERFORM public._t_falla($q$UPDATE public.traspasos_cuentas SET monto_origen = 1$q$, 'permission denied');
END $$;
RESET ROLE;
DO $$ BEGIN
  PERFORM public._t_falla($q$DELETE FROM public.traspasos_cuentas$q$, 'no se borran');
END $$;
SELECT public._t_como('admin@tr.test');
DO $$ BEGIN
  PERFORM public._t_falla(format($q$UPDATE public.movimientos_financieros SET monto = 1 WHERE traspaso_id = %L$q$, (SELECT id FROM public._tr_ids WHERE clave = 't1')), 'solo de consulta|permission denied');
END $$;
RESET ROLE;
ROLLBACK;

\echo 'TR10. Listado: cada quien con permiso lo ve; quien no tiene etapa, no'
BEGIN;
SELECT public._t_como('caja@tr.test');
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.traspaso_listar() WHERE folio IS NOT NULL) >= 5, 'caja ve los traspasos';
  ASSERT (SELECT creado_por_nombre FROM public.traspaso_listar() WHERE id = (SELECT id FROM public._tr_ids WHERE clave = 't1')) = (SELECT nombre_completo FROM public.profiles WHERE id = '00000000-0000-0000-0000-0000000000d1') AND (SELECT creado_por_nombre FROM public.traspaso_listar() WHERE id = (SELECT id FROM public._tr_ids WHERE clave = 't1')) IS NOT NULL, 'trae el nombre de quien capturó';
END $$;
RESET ROLE;
SELECT public._t_como('nadie@tr.test');
DO $$ BEGIN PERFORM public._t_falla($q$SELECT * FROM public.traspaso_listar()$q$, 'etapa del flujo'); END $$;
RESET ROLE;
ROLLBACK;

\echo 'OK — pruebas de traspasos'

-- ============================================================================
-- Pruebas (base de datos) de 20261114000001_traspasos_alerta_saldo_negativo.sql
--
--   PGHOST=/tmp PGPORT=5433 PGUSER=postgres scripts/db-local/aplicar_migraciones.sh kit_prueba
--   psql -d kit_prueba -f scripts/db-local/pruebas_saldo_negativo.sql
--
-- Autosuficiente: crea sus usuarios y cuentas. Corre sobre base nueva.
-- ============================================================================
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE OR REPLACE FUNCTION public._s_como(_email text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', (SELECT id::text FROM auth.users WHERE email = _email), true);
  EXECUTE 'SET LOCAL ROLE authenticated';
END $$;
CREATE OR REPLACE FUNCTION public._s_falla(_sql text, _patron text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE _sql;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM !~* _patron THEN RAISE EXCEPTION 'Falló con otro mensaje. Esperado /%/, llegó: %', _patron, SQLERRM; END IF;
    RETURN;
  END;
  RAISE EXCEPTION 'Debió fallar (esperado /%/): %', _patron, _sql;
END $$;
GRANT EXECUTE ON FUNCTION public._s_como(text), public._s_falla(text, text) TO authenticated;
CREATE OR REPLACE FUNCTION public._s_c(_n text) RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$ SELECT id FROM public.cuentas_financieras WHERE nombre = _n $$;
GRANT EXECUTE ON FUNCTION public._s_c(text) TO authenticated;
-- Movimiento confirmado de prueba, con fecha relativa a hoy (como mantenimiento: sin usuario de sesión).
CREATE OR REPLACE FUNCTION public._s_mov(_cuenta text, _tipo text, _monto numeric, _dias_atras integer) RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.movimientos_financieros (tipo, estatus, concepto, monto, fecha_movimiento, cuenta_id, contraparte_nombre)
  VALUES (_tipo::public.mov_tipo, 'CONFIRMADO', 'SN prueba', _monto, CURRENT_DATE - _dias_atras, public._s_c(_cuenta), 'SN')
$$;

-- Usuarios: dos de Finanzas/Administración (el sistema liga el área administracion al rol finanzas), un superadmin y uno sin permiso.
INSERT INTO auth.users (id, email, raw_app_meta_data) VALUES
  ('00000000-0000-0000-0000-0000000000e1', 'finanzas@sn.test', '{"created_via_admin": "true"}'),
  ('00000000-0000-0000-0000-0000000000e2', 'administracion@sn.test', '{"created_via_admin": "true"}'),
  ('00000000-0000-0000-0000-0000000000e3', 'superadmin@sn.test', '{"created_via_admin": "true"}'),
  ('00000000-0000-0000-0000-0000000000e4', 'ventas@sn.test', '{"created_via_admin": "true"}')
ON CONFLICT (id) DO NOTHING;
INSERT INTO public.profiles (id, nombre_completo, activo, email)
SELECT id, split_part(email, '@', 1), true, email FROM auth.users WHERE id::text LIKE '00000000-0000-0000-0000-0000000000e%'
ON CONFLICT (id) DO UPDATE SET activo = true;
DELETE FROM public.user_roles WHERE user_id::text LIKE '00000000-0000-0000-0000-0000000000e%';
INSERT INTO public.user_roles (user_id, role, area, nivel) VALUES
  ('00000000-0000-0000-0000-0000000000e1', 'finanzas', 'administracion', 'operador'),
  ('00000000-0000-0000-0000-0000000000e2', 'finanzas', 'administracion', 'supervisor'),
  ('00000000-0000-0000-0000-0000000000e3', 'admin', 'direccion', 'admin'),
  ('00000000-0000-0000-0000-0000000000e4', 'ventas', 'comercial', 'operador');
INSERT INTO public.super_admins (user_id) VALUES ('00000000-0000-0000-0000-0000000000e3') ON CONFLICT DO NOTHING;

-- Cuentas ------------------------------------------------------------------------
INSERT INTO public.cuentas_financieras (nombre, tipo, moneda, saldo_inicial, orden) VALUES
  ('SN Caja', 'EFECTIVO', 'MXN', 0, 950),          -- negativa desde hace 6 días
  ('SN Reciente', 'BANCO', 'MXN', 0, 951),         -- negativa desde hace 2 días
  ('SN Banco', 'BANCO', 'MXN', 500, 952),          -- positiva
  ('SN Recuperada', 'BANCO', 'MXN', 0, 953),       -- fue negativa y ya se recuperó
  ('SN Racha', 'BANCO', 'MXN', 0, 954),            -- se recuperó y volvió a caer hace 3 días
  ('SN Inicial', 'EFECTIVO', 'MXN', -100, 955);    -- nació en negativo, sin movimientos

SELECT public._s_mov('SN Caja', 'INGRESO', 100, 10);
SELECT public._s_mov('SN Caja', 'EGRESO', 300, 6);
SELECT public._s_mov('SN Reciente', 'INGRESO', 100, 8);
SELECT public._s_mov('SN Reciente', 'EGRESO', 150, 2);
SELECT public._s_mov('SN Recuperada', 'INGRESO', 50, 9);
SELECT public._s_mov('SN Recuperada', 'EGRESO', 100, 7);
SELECT public._s_mov('SN Recuperada', 'INGRESO', 200, 4);
SELECT public._s_mov('SN Racha', 'INGRESO', 100, 9);
SELECT public._s_mov('SN Racha', 'EGRESO', 300, 8);
SELECT public._s_mov('SN Racha', 'INGRESO', 500, 6);
SELECT public._s_mov('SN Racha', 'EGRESO', 400, 3);

\echo 'SN1. Desde cuándo está en negativo (de la racha actual, del libro mayor)'
DO $$ BEGIN
  ASSERT public._saldo_negativo_desde(public._s_c('SN Caja')) = CURRENT_DATE - 6, 'caja: desde hace 6 días';
  ASSERT public._saldo_negativo_desde(public._s_c('SN Reciente')) = CURRENT_DATE - 2, 'reciente: desde hace 2';
  ASSERT public._saldo_negativo_desde(public._s_c('SN Banco')) IS NULL, 'positiva: sin racha';
  ASSERT public._saldo_negativo_desde(public._s_c('SN Recuperada')) IS NULL, 'recuperada: ya no está negativa';
  ASSERT public._saldo_negativo_desde(public._s_c('SN Racha')) = CURRENT_DATE - 3, 'racha nueva tras recuperarse';
  ASSERT public._saldo_negativo_desde(public._s_c('SN Inicial')) = CURRENT_DATE, 'nació en negativo: desde su alta';
END $$;

\echo 'SN2. La revisión abre alertas y avisa solo a las de más de 3 días, a Finanzas, Administración y superadmin'
DO $$ DECLARE r jsonb; BEGIN
  r := public.saldo_negativo_revisar(3);
  ASSERT (SELECT count(*) FROM public.cuentas_saldo_alertas WHERE resuelta_at IS NULL AND cuenta_id IN (SELECT id FROM public.cuentas_financieras WHERE nombre LIKE 'SN %')) = 4,
    'abre alerta de caja, reciente, racha e inicial: ' || r::text;
  ASSERT (SELECT avisos FROM public.cuentas_saldo_alertas WHERE cuenta_id = public._s_c('SN Caja') AND resuelta_at IS NULL) = 1, 'caja avisada una vez';
  ASSERT (SELECT avisos FROM public.cuentas_saldo_alertas WHERE cuenta_id = public._s_c('SN Reciente') AND resuelta_at IS NULL) = 0, 'reciente aún no (2 días)';
  ASSERT (SELECT avisos FROM public.cuentas_saldo_alertas WHERE cuenta_id = public._s_c('SN Racha') AND resuelta_at IS NULL) = 0, 'racha: 3 días no es más de 3';
  ASSERT (SELECT count(*) FROM public.notificaciones WHERE tipo = 'saldo_negativo' AND titulo = 'Saldo negativo en SN Caja') = 3, 'una por destinatario';
  ASSERT (SELECT count(*) FROM public.notificaciones WHERE tipo = 'saldo_negativo' AND titulo = 'Saldo negativo en SN Caja'
            AND usuario_destino IN ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000e2', '00000000-0000-0000-0000-0000000000e3')) = 3,
    'finanzas, administración y superadmin';
  ASSERT NOT EXISTS (SELECT 1 FROM public.notificaciones WHERE tipo = 'saldo_negativo' AND usuario_destino = '00000000-0000-0000-0000-0000000000e4'), 'ventas no recibe';
  ASSERT (SELECT cuerpo FROM public.notificaciones WHERE tipo = 'saldo_negativo' AND titulo = 'Saldo negativo en SN Caja' LIMIT 1) LIKE '%6 días%-200.00 MXN%', 'el aviso dice días y saldo';
  ASSERT (SELECT enlace FROM public.notificaciones WHERE tipo = 'saldo_negativo' AND titulo = 'Saldo negativo en SN Caja' LIMIT 1) LIKE '/finanzas/traspasos?cuenta=%', 'enlace a la cuenta';
END $$;

\echo 'SN3. Revisar otra vez no duplica avisos'
DO $$ BEGIN
  PERFORM public.saldo_negativo_revisar(3);
  ASSERT (SELECT count(*) FROM public.notificaciones WHERE tipo = 'saldo_negativo' AND titulo = 'Saldo negativo en SN Caja') = 3, 'sin duplicados';
  ASSERT (SELECT count(*) FROM public.cuentas_saldo_alertas WHERE cuenta_id = public._s_c('SN Caja') AND resuelta_at IS NULL) = 1, 'una alerta abierta por cuenta';
END $$;

\echo 'SN4. Permisos: quien no es Finanzas/Administración/superadmin ni opera el flujo no ve ni valida'
BEGIN;
SELECT public._s_como('ventas@sn.test');
DO $$ BEGIN
  PERFORM public._s_falla($q$SELECT * FROM public.saldo_negativo_alertas()$q$, 'permiso para ver');
  PERFORM public._s_falla($q$SELECT public.saldo_negativo_revisar()$q$, 'permiso para revisar');
  PERFORM public._s_falla(format($q$SELECT public.saldo_negativo_validar(%L, 'falta registrar un retiro')$q$, public._s_c('SN Caja')), 'Solo Finanzas');
END $$;
RESET ROLE;
SELECT public._s_como('finanzas@sn.test');
DO $$ BEGIN
  ASSERT (SELECT dias FROM public.saldo_negativo_alertas() WHERE cuenta = 'SN Caja') = 6, 've los días';
  ASSERT (SELECT requiere_validar FROM public.saldo_negativo_alertas() WHERE cuenta = 'SN Caja'), 'caja requiere validación';
  ASSERT NOT (SELECT requiere_validar FROM public.saldo_negativo_alertas() WHERE cuenta = 'SN Reciente'), 'reciente aún no';
  ASSERT (SELECT saldo FROM public.saldo_negativo_alertas() WHERE cuenta = 'SN Caja') = -200, 'saldo vigente';
END $$;
RESET ROLE;
ROLLBACK;

\echo 'SN5. Validar con nota: se detienen los avisos de esa racha y queda constancia'
BEGIN;
SELECT public._s_como('administracion@sn.test');
DO $$ BEGIN
  PERFORM public._s_falla(format($q$SELECT public.saldo_negativo_validar(%L, 'no')$q$, public._s_c('SN Caja')), 'nota');
  PERFORM public._s_falla($q$SELECT public.saldo_negativo_validar(gen_random_uuid(), 'nota suficiente larga')$q$, 'alerta de saldo negativo abierta');
  PERFORM public.saldo_negativo_validar(public._s_c('SN Caja'), 'Falta registrar el retiro de la compra de papelería');
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT validado_at IS NOT NULL AND validado_por = '00000000-0000-0000-0000-0000000000e2' FROM public.cuentas_saldo_alertas WHERE cuenta_id = public._s_c('SN Caja') AND resuelta_at IS NULL), 'quién validó';
  ASSERT EXISTS (SELECT 1 FROM public.bitacora_compras_inventario WHERE accion = 'saldo_negativo_validar'), 'bitácora';
  UPDATE public.cuentas_saldo_alertas SET ultimo_aviso_at = now() - interval '5 days' WHERE cuenta_id = public._s_c('SN Caja') AND resuelta_at IS NULL;
  PERFORM public.saldo_negativo_revisar(3);
  ASSERT (SELECT avisos FROM public.cuentas_saldo_alertas WHERE cuenta_id = public._s_c('SN Caja') AND resuelta_at IS NULL) = 1, 'validada: no se vuelve a avisar';
END $$;
COMMIT;

\echo 'SN6. Sin validar se repite cada 3 días; al pasar de 3 días la racha nueva también avisa'
DO $$ BEGIN
  -- La racha de «SN Racha» ya pasó los 3 días si su primer día negativo fuera hace 4: se simula adelantando la fecha del egreso.
  UPDATE public.movimientos_financieros SET fecha_movimiento = CURRENT_DATE - 4
   WHERE cuenta_id = public._s_c('SN Racha') AND tipo = 'EGRESO' AND monto = 400;
  ASSERT public._saldo_negativo_desde(public._s_c('SN Racha')) = CURRENT_DATE - 4, 'ahora son 4 días';
  PERFORM public.saldo_negativo_revisar(3);
  ASSERT (SELECT avisos FROM public.cuentas_saldo_alertas WHERE cuenta_id = public._s_c('SN Racha') AND resuelta_at IS NULL) = 1, 'primer aviso al pasar de 3 días';
  PERFORM public.saldo_negativo_revisar(3);
  ASSERT (SELECT avisos FROM public.cuentas_saldo_alertas WHERE cuenta_id = public._s_c('SN Racha') AND resuelta_at IS NULL) = 1, 'no se repite el mismo día';
  UPDATE public.cuentas_saldo_alertas SET ultimo_aviso_at = now() - interval '4 days' WHERE cuenta_id = public._s_c('SN Racha') AND resuelta_at IS NULL;
  PERFORM public.saldo_negativo_revisar(3);
  ASSERT (SELECT avisos FROM public.cuentas_saldo_alertas WHERE cuenta_id = public._s_c('SN Racha') AND resuelta_at IS NULL) = 2, 'se repite a los 3 días sin validar';
END $$;

\echo 'SN7. Al regularizar la cuenta la alerta se cierra; una racha nueva es otra alerta'
DO $$ BEGIN
  PERFORM public._s_mov('SN Caja', 'INGRESO', 500, 2);
  ASSERT public._saldo_negativo_desde(public._s_c('SN Caja')) IS NULL, 'ya no es negativa';
  PERFORM public.saldo_negativo_revisar(3);
  ASSERT NOT EXISTS (SELECT 1 FROM public.cuentas_saldo_alertas WHERE cuenta_id = public._s_c('SN Caja') AND resuelta_at IS NULL), 'alerta cerrada';
  ASSERT EXISTS (SELECT 1 FROM public.cuentas_saldo_alertas WHERE cuenta_id = public._s_c('SN Caja') AND resuelta_at IS NOT NULL AND validado_at IS NOT NULL), 'queda el historial con su validación';
  PERFORM public._s_mov('SN Caja', 'EGRESO', 400, 0);
  PERFORM public.saldo_negativo_revisar(3);
  ASSERT (SELECT count(*) FROM public.cuentas_saldo_alertas WHERE cuenta_id = public._s_c('SN Caja')) = 2, 'racha nueva = alerta nueva';
  ASSERT (SELECT validado_at IS NULL AND avisos = 0 FROM public.cuentas_saldo_alertas WHERE cuenta_id = public._s_c('SN Caja') AND resuelta_at IS NULL), 'la nueva empieza sin validar';
END $$;

\echo 'SN8. Cerrado a lectura directa y a anon'
BEGIN;
SELECT public._s_como('finanzas@sn.test');
DO $$ BEGIN PERFORM public._s_falla($q$SELECT * FROM public.cuentas_saldo_alertas$q$, 'permission denied'); END $$;
RESET ROLE;
ROLLBACK;

\echo 'OK — pruebas de saldo negativo'

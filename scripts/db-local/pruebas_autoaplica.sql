-- Pruebas de 20261106000002_flujo_permiso_autoaplica.sql
-- Requiere pruebas_pendientes_martin.sql y pruebas_abono_flujo.sql (usuarios reales y admin global@mm.test).
\set ON_ERROR_STOP 1
SET client_min_messages = warning;
DROP TABLE IF EXISTS public._aa_ids; CREATE TABLE public._aa_ids (clave text PRIMARY KEY, id uuid);
GRANT SELECT, INSERT ON public._aa_ids TO authenticated;

\echo 'AA1. Sin el permiso, quien registra no confirma ni aplica lo suyo'
BEGIN;
SELECT set_config('kit.t_martin', (SELECT id::text FROM auth.users WHERE email = 'martin.real@ejemplo.mx'), true), set_config('kit.t_vend', (SELECT id::text FROM auth.users WHERE email = 'vendedor.a@mm.test'), true);
SELECT public._m_como('global@mm.test');
SELECT public.flujo_asignar_capacidad(current_setting('kit.t_martin')::uuid, 'recibe', true);
SELECT public.flujo_asignar_capacidad(current_setting('kit.t_martin')::uuid, 'caja', true);
SELECT public.flujo_asignar_capacidad(current_setting('kit.t_martin')::uuid, 'aplica', true);
SELECT public.flujo_asignar_capacidad(current_setting('kit.t_martin')::uuid, 'autoaplica', false);
RESET ROLE;
SELECT set_config('kit.t_caja', (SELECT id::text FROM public.cuentas_financieras WHERE tipo::text = 'EFECTIVO' AND moneda = 'MXN' AND activo ORDER BY nombre LIMIT 1), true);
SELECT public._m_como('martin.real@ejemplo.mx');
DO $$ DECLARE v jsonb; BEGIN
  v := public.flujo_registrar_movimiento(jsonb_build_object('tipo', 'INGRESO', 'concepto', 'Propio', 'monto', 100, 'metodo_pago', 'EFECTIVO', 'contraparte_nombre', 'Alguien'));
  INSERT INTO public._aa_ids VALUES ('f1', (v->>'id')::uuid);
  PERFORM public._m_falla(format($q$SELECT public.flujo_confirmar_caja(%L, %L)$q$, v->>'id', current_setting('kit.t_caja')), 'lo hace otra persona');
END $$;
RESET ROLE;
COMMIT;

\echo 'AA2. Con el permiso, lo confirma en caja y lo aplica él mismo; queda marcado'
BEGIN;
SELECT set_config('kit.t_martin', (SELECT id::text FROM auth.users WHERE email = 'martin.real@ejemplo.mx'), true), set_config('kit.t_vend', (SELECT id::text FROM auth.users WHERE email = 'vendedor.a@mm.test'), true);
SELECT set_config('kit.t_caja', (SELECT id::text FROM public.cuentas_financieras WHERE tipo::text = 'EFECTIVO' AND moneda = 'MXN' AND activo ORDER BY nombre LIMIT 1), true);
SELECT public._m_como('global@mm.test');
SELECT public.flujo_asignar_capacidad(current_setting('kit.t_martin')::uuid, 'autoaplica', true);
DO $$ BEGIN ASSERT (SELECT autoaplica FROM public.flujo_listar_capacidades() WHERE user_id = current_setting('kit.t_martin')::uuid), 'la lista trae el permiso'; END $$;
RESET ROLE;
SELECT public._m_como('martin.real@ejemplo.mx');
DO $$ BEGIN ASSERT (public.flujo_mis_capacidades()->>'autoaplica')::boolean, 'él ve su permiso'; END $$;
SELECT public.flujo_confirmar_caja((SELECT id FROM public._aa_ids WHERE clave = 'f1'), current_setting('kit.t_caja')::uuid);
SELECT public.flujo_aplicar((SELECT id FROM public._aa_ids WHERE clave = 'f1'), 'OTRO', '[]', 'Autorizado por mí');
RESET ROLE;
DO $$ DECLARE f public.flujo_dinero%ROWTYPE; BEGIN
  SELECT * INTO f FROM public.flujo_dinero WHERE id = (SELECT id FROM public._aa_ids WHERE clave = 'f1');
  ASSERT f.etapa = 'APLICADO' AND f.autoautorizado AND f.recibido_por = f.caja_por AND f.caja_por = f.aplicado_por, format('%s', to_jsonb(f));
  ASSERT (SELECT estatus::text FROM public.movimientos_financieros WHERE id = f.movimiento_id) = 'CONFIRMADO', 'el movimiento se confirmó';
END $$;
COMMIT;

\echo 'AA3. El permiso no da etapas: sin caja/aplica sigue sin poder; y solo un administrador lo asigna'
BEGIN;
SELECT set_config('kit.t_martin', (SELECT id::text FROM auth.users WHERE email = 'martin.real@ejemplo.mx'), true), set_config('kit.t_vend', (SELECT id::text FROM auth.users WHERE email = 'vendedor.a@mm.test'), true);
SELECT public._m_como('vendedor.a@mm.test');
SELECT public._m_falla($q$SELECT public.flujo_asignar_capacidad(gen_random_uuid(), 'autoaplica', true)$q$, 'administrador');
RESET ROLE;
SELECT public._m_como('global@mm.test');
SELECT public.flujo_asignar_capacidad(current_setting('kit.t_vend')::uuid, 'autoaplica', true);
RESET ROLE;
SELECT public._m_como('vendedor.a@mm.test');
DO $$ BEGIN
  PERFORM public._m_falla($q$SELECT public.flujo_confirmar_caja(gen_random_uuid(), gen_random_uuid())$q$, 'etapa de caja');
  PERFORM public._m_falla($q$SELECT public.flujo_aplicar(gen_random_uuid(), 'OTRO')$q$, 'etapa de aplicación');
END $$;
RESET ROLE;
COMMIT;
\echo 'OK: autoaplica'

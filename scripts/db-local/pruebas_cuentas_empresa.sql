-- Pruebas de 20261106000001_flujo_empresas_bancos_cuentas.sql
-- Requiere pruebas_pendientes_martin.sql y pruebas_abono_flujo.sql (usuarios reales y admin global@mm.test).
\set ON_ERROR_STOP 1
SET client_min_messages = warning;
DROP TABLE IF EXISTS public._ce_ids; CREATE TABLE public._ce_ids (clave text PRIMARY KEY, id uuid);
GRANT SELECT, INSERT ON public._ce_ids TO authenticated;

\echo 'CE1. El catálogo trae bancos y fintech y lo ve quien registra'
BEGIN;
SELECT public._m_como('martin.real@ejemplo.mx');
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.flujo_instituciones()) >= 50, 'catálogo';
  ASSERT EXISTS (SELECT 1 FROM public.flujo_instituciones() WHERE nombre = 'Banorte' AND tipo = 'BANCO'), 'Banorte';
  ASSERT EXISTS (SELECT 1 FROM public.flujo_instituciones() WHERE nombre = 'Mercado Pago' AND tipo = 'FINTECH'), 'fintech';
  PERFORM public._m_falla($q$SELECT public.flujo_crear_cuenta_empresa('Kawiil', 'BANCO', NULL, '1234')$q$, 'administrador');
  PERFORM public._m_falla($q$SELECT public.flujo_agregar_institucion('Nueva')$q$, 'administrador');
END $$;
RESET ROLE;
COMMIT;

\echo 'CE2. Un administrador da de alta cuentas por empresa, banco y últimos 4 dígitos'
BEGIN;
SELECT set_config('kit.t_bnt', (SELECT id::text FROM public.instituciones_financieras WHERE nombre = 'Banorte'), true);
SELECT public._m_como('global@mm.test');
DO $$ DECLARE v jsonb; BEGIN
  v := public.flujo_crear_cuenta_empresa('Kawiil MX', 'BANCO', current_setting('kit.t_bnt')::uuid, '1234', 'MXN', NULL);
  ASSERT v->>'nombre' = 'Kawiil MX · Banorte ••1234', v::text;
  INSERT INTO public._ce_ids VALUES ('c1', (v->>'id')::uuid);
  PERFORM public.flujo_crear_cuenta_empresa('Kawiil MX', 'BANCO', current_setting('kit.t_bnt')::uuid, '9999', 'MXN', 'Banorte nómina');
  PERFORM public.flujo_crear_cuenta_empresa('Kawiil MX', 'EFECTIVO');
  PERFORM public._m_falla(format($q$SELECT public.flujo_crear_cuenta_empresa('Kawiil MX', 'BANCO', %L, '1234')$q$, current_setting('kit.t_bnt')), 'ya está dada de alta');
  PERFORM public._m_falla(format($q$SELECT public.flujo_crear_cuenta_empresa('Kawiil MX', 'BANCO', %L, '12a4')$q$, current_setting('kit.t_bnt')), 'últimos 4');
  PERFORM public._m_falla($q$SELECT public.flujo_crear_cuenta_empresa('Kawiil MX', 'BANCO', NULL, '1234')$q$, 'Elige el banco');
  PERFORM public._m_falla($q$SELECT public.flujo_crear_cuenta_empresa('', 'EFECTIVO')$q$, 'empresa');
  PERFORM public.flujo_agregar_institucion('Banco de Prueba', 'OTRO');
  PERFORM public._m_falla($q$SELECT public.flujo_agregar_institucion('banco de prueba')$q$, 'ya está en la lista');
END $$;
RESET ROLE;
COMMIT;

\echo 'CE3. Quien registra ve las cuentas con empresa y banco; las inactivas solo las ve un administrador'
BEGIN;
SELECT set_config('kit.t_bnt', (SELECT id::text FROM public.instituciones_financieras WHERE nombre = 'Banorte'), true);
SELECT public._m_como('martin.real@ejemplo.mx');
DO $$ BEGIN
  ASSERT EXISTS (SELECT 1 FROM public.flujo_cuentas() WHERE empresa = 'Kawiil MX' AND institucion = 'Banorte' AND ultimos4 = '1234'), 'empresa, banco y 4 dígitos';
END $$;
RESET ROLE;
SELECT public._m_como('global@mm.test');
SELECT public.flujo_desactivar_cuenta((SELECT id FROM public._ce_ids WHERE clave = 'c1'));
DO $$ BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.flujo_cuentas() WHERE id = (SELECT id FROM public._ce_ids WHERE clave = 'c1')), 'inactiva no sale';
  ASSERT EXISTS (SELECT 1 FROM public.flujo_cuentas(true) WHERE id = (SELECT id FROM public._ce_ids WHERE clave = 'c1') AND NOT activo), 'el admin la ve con todas';
END $$;
SELECT public.flujo_desactivar_cuenta((SELECT id FROM public._ce_ids WHERE clave = 'c1'), true);
SELECT public.flujo_editar_cuenta((SELECT id FROM public.cuentas_financieras WHERE nombre = 'Banco principal'), 'Kawiil MX', current_setting('kit.t_bnt')::uuid, '5555', NULL);
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT empresa || ultimos4 FROM public.cuentas_financieras WHERE nombre = 'Banco principal') = 'Kawiil MX5555', 'se asignó empresa a una cuenta existente';
END $$;
COMMIT;
\echo 'OK: cuentas por empresa'

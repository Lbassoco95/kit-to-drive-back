-- ============================================================================
-- Quitar el acceso a las funciones de trigger a anon, authenticated y PUBLIC
--
-- Fase 1 de seguridad de la base de producción (docs/seguridad/). Punto 2 de 6.
-- ============================================================================
--
-- Por qué: una función de trigger no se llama desde la aplicación, pero hoy
-- cualquier usuario con sesión (y `anon`, en dos casos) puede invocarla por
-- /rest/v1/rpc/<nombre>. PostgreSQL no comprueba EXECUTE cuando dispara un
-- trigger (probado en el ensayo; además 6 de estas funciones ya están cerradas a
-- `authenticated` en producción y funcionan), así que cerrarlas no cambia lo que
-- hacen los triggers.
--
-- Las dos de `anon`: `vigilar_super_admin()` (permiso explícito) y
-- `limpiar_entrega_programada_refaccion()` (nació con permiso PUBLIC porque se
-- creó sin REVOKE; por eso se revoca a PUBLIC y no solo a anon).
--
-- Se conservan los permisos de `service_role` y de `supabase_auth_admin`. Este
-- último se vuelve a conceder de forma explícita en las funciones de los
-- triggers de auth.users (handle_new_user, reject_public_signups): en un
-- incidente anterior (20261009000002 → 20261010000001) el alta de usuarios
-- falló al quitar permisos y el rol de Auth no tenía concesión explícita. El
-- ensayo no logró reproducirlo (el motor no revisa EXECUTE al disparar), pero se
-- deja explícito por prudencia.
--
-- Lee las funciones de la base (no una lista fija) para no depender de que no
-- haya cambiado nada desde el respaldo. No toca funciones de extensiones.
-- Idempotente. Reversa: supabase/reversas/20261031000002_fase1_cerrar_funciones_de_trigger_reversa.sql
-- ============================================================================
GRANT EXECUTE ON FUNCTION public.handle_new_user()        TO supabase_auth_admin;
GRANT EXECUTE ON FUNCTION public.reject_public_signups()  TO supabase_auth_admin;

DO $$
DECLARE f record; n integer := 0;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS firma
      FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
     WHERE ns.nspname = 'public' AND p.prokind = 'f'
       AND p.prorettype IN ('trigger'::regtype, 'event_trigger'::regtype)
       AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
     ORDER BY p.proname
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', f.firma);
    n := n + 1;
  END LOOP;
  RAISE NOTICE 'Funciones de trigger cerradas: %', n;
END $$;

-- Verificación: las dos primeras cifras deben salir en 0; las dos últimas en true.
SELECT
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.prorettype = 'trigger'::regtype
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
      AND has_function_privilege('anon', p.oid, 'EXECUTE'))           AS triggers_ejecutables_por_anon,
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.prorettype = 'trigger'::regtype
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
      AND has_function_privilege('authenticated', p.oid, 'EXECUTE'))  AS triggers_ejecutables_por_authenticated,
  has_function_privilege('supabase_auth_admin', 'public.handle_new_user()', 'EXECUTE')       AS auth_conserva_handle_new_user,
  has_function_privilege('supabase_auth_admin', 'public.reject_public_signups()', 'EXECUTE') AS auth_conserva_candado;

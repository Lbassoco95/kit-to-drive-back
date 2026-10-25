-- ============================================================================
-- Quitar TRUNCATE, TRIGGER y REFERENCES a anon y authenticated en tablas y vistas de public
--
-- Fase 1 de seguridad de la base de producción (docs/seguridad/). Punto 1 de 6.
-- ============================================================================
--
-- Por qué: la seguridad por filas (RLS) frena INSERT, UPDATE, DELETE y SELECT,
-- pero NO frena TRUNCATE: quien lo tenga puede vaciar una tabla entera. Los
-- permisos TRIGGER y REFERENCES tampoco los usa la aplicación (los usuarios
-- no crean triggers ni llaves foráneas). Salieron de los permisos por defecto
-- de Supabase, no de una decisión del proyecto.
--
-- Forma de revocar: REVOKE simple, SIN CASCADE. Inventario previo (25 oct 2026):
-- todos los permisos los otorgó `postgres`, dueño de las 93 tablas y 18 vistas,
-- y ninguno lleva WITH GRANT OPTION; no hay permisos de otros roles que dependan
-- de estos. Si apareciera uno, el REVOKE fallaría en vez de arrastrarlo.
--
-- No toca: SELECT, INSERT, UPDATE, DELETE (ni siquiera de anon: eso es el
-- punto 5), service_role, postgres ni MAINTAIN (ver docs/seguridad/).
-- Idempotente: volver a correrlo no cambia nada.
-- Reversa: supabase/reversas/20261031000001_fase1_quitar_truncate_trigger_references_reversa.sql
-- ============================================================================
REVOKE TRUNCATE, TRIGGER, REFERENCES ON ALL TABLES IN SCHEMA public FROM anon, authenticated;

-- Verificación: las cuatro cifras deben salir en 0.
SELECT
  count(*) FILTER (WHERE has_table_privilege('anon', c.oid, 'TRUNCATE'))            AS anon_truncate,
  count(*) FILTER (WHERE has_table_privilege('authenticated', c.oid, 'TRUNCATE'))   AS authenticated_truncate,
  count(*) FILTER (WHERE has_table_privilege('anon', c.oid, 'TRIGGER')
                      OR has_table_privilege('authenticated', c.oid, 'TRIGGER'))    AS con_trigger,
  count(*) FILTER (WHERE has_table_privilege('anon', c.oid, 'REFERENCES')
                      OR has_table_privilege('authenticated', c.oid, 'REFERENCES')) AS con_references
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v');

-- ============================================================================
-- Que las tablas, vistas, secuencias y funciones NUEVAS no nazcan con permisos amplios
--
-- Fase 1 de seguridad de la base de producción (docs/seguridad/). Punto 6 de 6.
-- ============================================================================
--
-- Solo cambia los permisos por defecto de lo que cree `postgres` (el rol con el
-- que se pegan las migraciones). No toca ningún objeto existente.
--
-- Tablas y vistas: `anon` ya no recibe nada; `authenticated` conserva SELECT,
--   INSERT, UPDATE y DELETE (la seguridad por filas decide) pero ya no TRUNCATE,
--   TRIGGER ni REFERENCES.
-- Secuencias: `anon` ya no recibe nada. (Hoy `anon` puede llamar nextval/setval en
--   las 9 secuencias existentes; arreglar las existentes queda para otra fase.)
-- Funciones: nacen sin permiso para PUBLIC, anon ni authenticated. Toda función
--   que el front llame o que usen las políticas necesita un
--   `GRANT EXECUTE ... TO authenticated` explícito en su migración, como ya hacen
--   17 de las 19 migraciones recientes con funciones.
--
-- POR QUÉ LA REVOCACIÓN DE PUBLIC ES GLOBAL (sin IN SCHEMA): el repo ya intentó
-- esto en 20261009000002 con `ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE
-- EXECUTE ON FUNCTIONS FROM PUBLIC, anon`, y no funcionó: PostgreSQL concede
-- EXECUTE a PUBLIC por defecto a toda función nueva, y esa concesión solo se
-- quita con la forma global. Prueba: `limpiar_entrega_programada_refaccion()`
-- (20261020000001) se creó después y nació con permiso PUBLIC, o sea ejecutable
-- por `anon`. Consecuencia de la forma global: afecta también las funciones que
-- `postgres` cree en otros esquemas (p. ej. si algún día instala una extensión);
-- esas necesitarán su GRANT explícito.
--
-- IMPORTANTE para el equipo: el proyecto de QA (kit-to-drive-db-qa) NO recibe
-- este cambio, así que allí una función sin GRANT explícito sí funcionaría y en
-- producción no. Por eso `tests/fase1-permisos.test.ts` exige el GRANT explícito
-- en las migraciones nuevas.
--
-- Idempotente. Reversa: supabase/reversas/20261031000006_fase1_lo_nuevo_nace_cerrado_reversa.sql
-- ============================================================================
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON TABLES FROM anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE TRUNCATE, TRIGGER, REFERENCES ON TABLES FROM authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- Verificación: las tres primeras deben salir en true.
SELECT
  NOT EXISTS (SELECT 1 FROM pg_default_acl d, aclexplode(d.defaclacl) x
               WHERE d.defaclrole = 'postgres'::regrole AND d.defaclnamespace = 'public'::regnamespace
                 AND d.defaclobjtype = 'r' AND x.grantee = 'anon'::regrole)                    AS tablas_nuevas_cerradas_a_anon,
  NOT EXISTS (SELECT 1 FROM pg_default_acl d, aclexplode(d.defaclacl) x
               WHERE d.defaclrole = 'postgres'::regrole AND d.defaclnamespace = 'public'::regnamespace
                 AND d.defaclobjtype = 'r' AND x.grantee = 'authenticated'::regrole
                 AND x.privilege_type IN ('TRUNCATE', 'TRIGGER', 'REFERENCES'))                AS tablas_nuevas_sin_truncate,
  EXISTS (SELECT 1 FROM pg_default_acl d
           WHERE d.defaclrole = 'postgres'::regrole AND d.defaclnamespace = 0 AND d.defaclobjtype = 'f'
             AND NOT EXISTS (SELECT 1 FROM aclexplode(d.defaclacl) x WHERE x.grantee = 0))      AS funciones_nuevas_sin_public;

-- ============================================================================
-- REVERSA: devuelve los permisos por defecto de lo nuevo a como estaban el 25 oct 2026
--
-- Fase 1 de seguridad de la base de producción (docs/seguridad/). Reversa del punto 6.
-- ============================================================================
-- Solo afecta objetos que se creen DESPUÉS de correrla.
-- ============================================================================
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT TRUNCATE, TRIGGER, REFERENCES ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres GRANT EXECUTE ON FUNCTIONS TO PUBLIC;

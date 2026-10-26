-- ============================================================================
-- REVERSA: quita la protección de perfiles de la Fase 2 (cambio 1)
--
-- Deja profiles como estaba el 25 oct 2026: sin trigger trg_proteger_perfil_fase2.
-- Los triggers anteriores (proteger_profile_activo, proteger_campos_privilegiados_profiles)
-- no se tocan. Idempotente.
-- ============================================================================
DROP TRIGGER IF EXISTS trg_proteger_perfil_fase2 ON public.profiles;
DROP FUNCTION IF EXISTS public.proteger_perfil_fase2();

-- Verificación: debe salir 0 y false.
SELECT (SELECT count(*) FROM pg_trigger WHERE tgname = 'trg_proteger_perfil_fase2') AS triggers_restantes,
       to_regprocedure('public.proteger_perfil_fase2()') IS NOT NULL AS funcion_existe;

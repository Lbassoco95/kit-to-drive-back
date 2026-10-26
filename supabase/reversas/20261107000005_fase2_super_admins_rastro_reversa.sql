-- ============================================================================
-- REVERSA: quita el rastro automático de la lista de super admins (Fase 2, cambio 5)
--
-- Los renglones que ya se hayan escrito en bitacora_super_admin se conservan (no se borra
-- información). Idempotente.
-- ============================================================================
DROP TRIGGER IF EXISTS trg_rastro_lista_super_admins ON public.super_admins;
DROP FUNCTION IF EXISTS public.rastro_lista_super_admins();

-- Verificación: debe salir 0 y false.
SELECT (SELECT count(*) FROM pg_trigger WHERE tgname = 'trg_rastro_lista_super_admins') AS triggers_restantes,
       to_regprocedure('public.rastro_lista_super_admins()') IS NOT NULL AS funcion_existe;

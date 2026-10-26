-- ============================================================================
-- Perfiles: nadie se asciende a sí mismo, un admin de área no sube de rango a
-- nadie y los super admins solo los toca un super admin.
--
-- Fase 2 de seguridad de la base de producción (docs/seguridad/). Cambio 1 de 4.
-- Depende de la Fase 1 (20261031000001–06): primero se aplica la Fase 1.
-- ============================================================================
--
-- Hoy (probado en la réplica, Fase 0 hallazgo S1):
--   · cualquier usuario puede ponerse es_vendedor / es_administrativo en su perfil
--     (profiles_update_propio no limita columnas y ningún trigger las protege);
--   · un admin de CUALQUIER área puede editar el perfil de otra área y el del
--     super admin (profiles_update_admin no mira el área del destino).
--
-- Reglas nuevas (solo cuando hay sesión de usuario; service_role / SQL interno,
-- donde auth.uid() es NULL, no cambian: las Edge Functions las aplican en código):
--   1. Sobre el PROPIO perfil solo se puede cambiar nombre_completo. Ni es_vendedor,
--      es_administrativo, activo, debe_cambiar_password, email ni codigo_vendedor.
--   2. Sobre OTRO perfil:
--        · si es super admin, solo otro super admin (no basta ser administrador global);
--        · un administrador global (Dirección/admin) puede todo lo demás;
--        · un admin de área solo toca usuarios de SU área, de nivel menor al suyo
--          (nunca a otro admin), y solo los campos de perfil: activo, es_vendedor,
--          es_administrativo, nombre_completo, codigo_vendedor, email, debe_cambiar_password;
--        · cualquier otro usuario no toca perfiles ajenos.
--   3. INSERT con sesión: es_vendedor / es_administrativo / codigo_vendedor quedan
--      reservados a un administrador (un perfil propio nace sin ellos).
--   4. id y created_at no cambian.
--
-- No quita nada de lo que ya protegen proteger_profile_activo y
-- proteger_campos_privilegiados_profiles: se suma a ellos.
-- Idempotente. Reversa: supabase/reversas/20261107000001_fase2_perfiles_campos_protegidos_reversa.sql
-- ============================================================================
CREATE OR REPLACE FUNCTION public.proteger_perfil_fase2()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _actor        uuid := auth.uid();
  _a_area       public.user_area;
  _a_nivel      public.user_nivel;
  _t_area       public.user_area;
  _t_nivel      public.user_nivel;
  _es_global    boolean;
  _destino_super boolean;
BEGIN
  -- service_role y SQL interno (sin sesión de usuario): sin cambio.
  IF _actor IS NULL THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  _es_global := public.es_admin_global(_actor);

  -- ── INSERT ────────────────────────────────────────────────────────────────
  IF TG_OP = 'INSERT' THEN
    IF NOT _es_global AND (NEW.es_vendedor OR NEW.es_administrativo OR NEW.codigo_vendedor IS NOT NULL) THEN
      RAISE EXCEPTION 'Solo un administrador global puede crear un perfil con función comercial o código de vendedor'
        USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;

  -- ── UPDATE ────────────────────────────────────────────────────────────────
  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'No se puede cambiar el id ni la fecha de alta del perfil' USING ERRCODE = '42501';
  END IF;

  -- Si no cambió ningún campo de perfil (p. ej. solo updated_at), no hay nada que revisar.
  IF NEW.nombre_completo IS NOT DISTINCT FROM OLD.nombre_completo
     AND NEW.codigo_vendedor IS NOT DISTINCT FROM OLD.codigo_vendedor
     AND NEW.activo IS NOT DISTINCT FROM OLD.activo
     AND NEW.email IS NOT DISTINCT FROM OLD.email
     AND NEW.debe_cambiar_password IS NOT DISTINCT FROM OLD.debe_cambiar_password
     AND NEW.es_vendedor IS NOT DISTINCT FROM OLD.es_vendedor
     AND NEW.es_administrativo IS NOT DISTINCT FROM OLD.es_administrativo THEN
    RETURN NEW;
  END IF;

  IF NOT public.usuario_activo(_actor) THEN
    RAISE EXCEPTION 'Un usuario inactivo no puede editar perfiles' USING ERRCODE = '42501';
  END IF;

  -- 1. Perfil propio: solo el nombre.
  IF NEW.id = _actor THEN
    IF NEW.codigo_vendedor IS DISTINCT FROM OLD.codigo_vendedor
       OR NEW.activo IS DISTINCT FROM OLD.activo
       OR NEW.email IS DISTINCT FROM OLD.email
       OR NEW.debe_cambiar_password IS DISTINCT FROM OLD.debe_cambiar_password
       OR NEW.es_vendedor IS DISTINCT FROM OLD.es_vendedor
       OR NEW.es_administrativo IS DISTINCT FROM OLD.es_administrativo THEN
      RAISE EXCEPTION 'No puedes cambiar tu propio perfil, salvo el nombre' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;

  -- 2. Perfil ajeno.
  _destino_super := EXISTS (SELECT 1 FROM public.super_admins WHERE user_id = OLD.id);
  IF _destino_super AND NOT public.es_super_admin(_actor) THEN
    RAISE EXCEPTION 'Solo un super admin puede modificar a otro super admin' USING ERRCODE = '42501';
  END IF;

  IF _es_global THEN
    RETURN NEW;
  END IF;

  SELECT area, nivel INTO _a_area, _a_nivel FROM public.user_roles WHERE user_id = _actor LIMIT 1;
  IF _a_nivel IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Solo un administrador puede editar perfiles ajenos' USING ERRCODE = '42501';
  END IF;

  SELECT area, nivel INTO _t_area, _t_nivel FROM public.user_roles WHERE user_id = OLD.id LIMIT 1;
  IF _t_area IS DISTINCT FROM _a_area THEN
    RAISE EXCEPTION 'Solo puedes editar usuarios de tu propia área' USING ERRCODE = '42501';
  END IF;
  IF public.nivel_rank(_t_nivel) >= public.nivel_rank(_a_nivel) THEN
    RAISE EXCEPTION 'No puedes editar a un usuario de tu mismo nivel o superior' USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$function$;

-- Sin GRANT EXECUTE a propósito: es función de trigger (Fase 1: nacen cerradas).
DROP TRIGGER IF EXISTS trg_proteger_perfil_fase2 ON public.profiles;
CREATE TRIGGER trg_proteger_perfil_fase2
  BEFORE INSERT OR UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.proteger_perfil_fase2();

-- Verificación: debe salir 1 trigger y la función sin EXECUTE para authenticated.
SELECT (SELECT count(*) FROM pg_trigger WHERE tgname = 'trg_proteger_perfil_fase2' AND NOT tgisinternal) AS trigger_creado,
       NOT has_function_privilege('authenticated', 'public.proteger_perfil_fase2()', 'EXECUTE') AS funcion_cerrada;

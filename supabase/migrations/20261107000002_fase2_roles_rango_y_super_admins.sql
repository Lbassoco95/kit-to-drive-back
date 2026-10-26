-- ============================================================================
-- Roles: un admin de área no crea ni toca administradores, y los roles de un
-- super admin solo los cambia otro super admin.
--
-- Fase 2 de seguridad de la base de producción (docs/seguridad/). Cambio 2 de 4.
-- Depende de la Fase 1 y del cambio 1 de la Fase 2.
-- ============================================================================
--
-- Reemplaza impedir_escalada_rol() (que producción tiene y el repo no traía:
-- hallazgo D1, ahora queda en el repo). Conserva TODAS sus reglas y mensajes y suma:
--   · C3: si el usuario destino es super admin (está en public.super_admins), solo un
--         super admin puede cambiarle o quitarle el rol. Antes bastaba ser administrador global.
--   · C2: un admin de área no puede crear ni modificar a otro administrador (nivel
--         igual o superior al suyo), ni siquiera dentro de su área. Antes podía crear
--         administradores de su área. Solo un administrador global lo hace.
-- No cambia lo que hace un administrador global con usuarios que no son super admin.
-- asignar_super_admin() sigue funcionando: el destino aún no es super admin cuando
-- se le asigna Dirección/admin.
-- Para service_role (auth.uid() NULL) no cambia nada: las Edge Functions aplican las
-- mismas reglas en código (supabase/functions/_shared/permisos.ts).
--
-- También crea el trigger si no existe (en producción ya existe igual; así un
-- repo armado solo con migraciones queda igual que producción).
-- Idempotente. Reversa: supabase/reversas/20261107000002_fase2_roles_rango_y_super_admins_reversa.sql
-- ============================================================================
CREATE OR REPLACE FUNCTION public.impedir_escalada_rol()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _caller uuid := auth.uid();
  _area_caller public.user_area;
  _nivel_caller public.user_nivel;
  _destino uuid;
BEGIN
  IF _caller IS NULL THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  -- Antes que el atajo de Dirección: ni el administrador global se reescribe
  -- el rol en la misma sesión. Si la comprobación de «soy global» viera la
  -- fila nueva, cambiarse el área a Dirección se aprobaría solo.
  IF TG_OP = 'DELETE' AND OLD.user_id = _caller THEN
    RAISE EXCEPTION 'No puedes quitarte tu propio rol';
  END IF;
  IF TG_OP <> 'DELETE' AND NEW.user_id = _caller THEN
    IF TG_OP = 'INSERT' THEN
      RAISE EXCEPTION 'No puedes asignarte un rol';
    END IF;
    IF NEW.area IS DISTINCT FROM OLD.area OR NEW.nivel IS DISTINCT FROM OLD.nivel THEN
      RAISE EXCEPTION 'No puedes cambiar tu propio rol';
    END IF;
  END IF;

  IF NOT public.usuario_activo(_caller) THEN
    RAISE EXCEPTION 'Un usuario inactivo no puede cambiar roles';
  END IF;

  -- Fase 2 (C3): los roles de un super admin solo los cambia otro super admin.
  _destino := CASE WHEN TG_OP = 'INSERT' THEN NEW.user_id ELSE OLD.user_id END;
  IF TG_OP <> 'INSERT'
     AND EXISTS (SELECT 1 FROM public.super_admins WHERE user_id = _destino)
     AND NOT public.es_super_admin(_caller) THEN
    RAISE EXCEPTION 'Solo un super admin puede cambiar el rol de otro super admin';
  END IF;

  IF public.es_admin_global(_caller) THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  SELECT area, nivel INTO _area_caller, _nivel_caller
    FROM public.user_roles
   WHERE user_id = _caller
   LIMIT 1;

  IF _nivel_caller IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Solo un administrador puede cambiar roles';
  END IF;

  IF TG_OP = 'DELETE' THEN
    IF OLD.area IS DISTINCT FROM _area_caller THEN
      RAISE EXCEPTION 'Solo puedes administrar usuarios de tu área';
    END IF;
    IF OLD.area = 'direccion' AND OLD.nivel = 'admin' THEN
      RAISE EXCEPTION 'No puedes modificar al administrador global';
    END IF;
    -- Fase 2 (C2): tampoco a otro administrador de su área.
    IF OLD.nivel = 'admin' THEN
      RAISE EXCEPTION 'Solo un administrador global puede modificar a otro administrador';
    END IF;
    RETURN OLD;
  END IF;

  IF NEW.area IS DISTINCT FROM _area_caller THEN
    RAISE EXCEPTION 'Solo puedes asignar usuarios de tu área';
  END IF;

  IF TG_OP = 'UPDATE' AND OLD.area IS DISTINCT FROM _area_caller THEN
    RAISE EXCEPTION 'Solo puedes administrar usuarios de tu área';
  END IF;

  IF (TG_OP = 'UPDATE' AND OLD.area = 'direccion' AND OLD.nivel = 'admin')
     OR (NEW.area = 'direccion' AND NEW.nivel = 'admin') THEN
    RAISE EXCEPTION 'No puedes modificar al administrador global';
  END IF;

  -- Fase 2 (C2): un admin de área no crea administradores ni toca a los que ya hay.
  IF NEW.nivel = 'admin' OR (TG_OP = 'UPDATE' AND OLD.nivel = 'admin') THEN
    RAISE EXCEPTION 'Solo un administrador global puede crear o modificar administradores';
  END IF;

  RETURN NEW;
END;
$function$;

-- Sin GRANT EXECUTE a propósito: es función de trigger.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_impedir_escalada_rol'
                    AND tgrelid = 'public.user_roles'::regclass AND NOT tgisinternal) THEN
    CREATE TRIGGER trg_impedir_escalada_rol
      BEFORE INSERT OR DELETE OR UPDATE ON public.user_roles
      FOR EACH ROW EXECUTE FUNCTION public.impedir_escalada_rol();
  END IF;
END $$;

-- Verificación: debe salir 1 trigger, la función cerrada y con la regla nueva.
SELECT (SELECT count(*) FROM pg_trigger WHERE tgname = 'trg_impedir_escalada_rol' AND NOT tgisinternal) AS trigger_existe,
       NOT has_function_privilege('authenticated', 'public.impedir_escalada_rol()', 'EXECUTE') AS funcion_cerrada,
       position('Solo un super admin puede cambiar el rol de otro super admin' IN pg_get_functiondef('public.impedir_escalada_rol()'::regprocedure)) > 0 AS regla_super_admin;

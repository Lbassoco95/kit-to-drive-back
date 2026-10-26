-- ============================================================================
-- REVERSA: devuelve impedir_escalada_rol() a la definición de producción del 25 oct 2026
--
-- Fase 2 de seguridad (docs/seguridad/). Reversa del cambio 2. La definición de abajo
-- es la que tenía producción (respaldo del esquema del 25 oct 2026), sin cambios.
-- No toca el trigger ni los permisos. Idempotente.
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

  RETURN NEW;
END;
$function$
;

-- Verificación: la regla de la Fase 2 ya no debe estar (false) y el trigger sigue (1).
SELECT position('Solo un super admin puede cambiar el rol de otro super admin' IN pg_get_functiondef('public.impedir_escalada_rol()'::regprocedure)) > 0 AS regla_fase2_presente,
       (SELECT count(*) FROM pg_trigger WHERE tgname = 'trg_impedir_escalada_rol' AND NOT tgisinternal) AS trigger_existe;

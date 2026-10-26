-- ============================================================================
-- Lista de super admins: todo cambio deja rastro, también el que no pasa por la función
--
-- Fase 2 de seguridad de la base de producción (docs/seguridad/). Cambio 5 (opcional).
-- ============================================================================
--
-- La lista es public.super_admins (hoy 2 personas). Ya es explícita y cerrada: REVOKE ALL
-- a anon y authenticated, sin políticas; solo la escribe asignar_super_admin() (que deja
-- su renglón en bitacora_super_admin) o service_role / el SQL Editor.
-- El hueco: una escritura directa de service_role o del SQL Editor (auth.uid() NULL) no
-- dejaba rastro. Este trigger lo deja. No registra lo que ya registra la función (con
-- sesión), para no duplicar. No bloquea nada: solo agrega el renglón.
--
-- La auditoría completa es la Fase 4; esto solo cierra el rastro de esta lista.
-- Idempotente. Reversa: supabase/reversas/20261107000005_fase2_super_admins_rastro_reversa.sql
-- ============================================================================
CREATE OR REPLACE FUNCTION public.rastro_lista_super_admins()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF auth.uid() IS NOT NULL THEN
    RETURN NULL;  -- con sesión, asignar_super_admin() ya dejó su renglón
  END IF;
  INSERT INTO public.bitacora_super_admin (usuario_id, tabla, operacion, registro_id, datos_antes, datos_despues, ruta)
  VALUES (NULL, 'super_admins', 'LISTA_' || TG_OP,
          COALESCE(NEW.user_id, OLD.user_id)::text,
          CASE WHEN TG_OP <> 'INSERT' THEN jsonb_build_object('user_id', OLD.user_id) END,
          CASE WHEN TG_OP <> 'DELETE' THEN jsonb_build_object('user_id', NEW.user_id) END,
          'service_role/SQL directo');
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_rastro_lista_super_admins ON public.super_admins;
CREATE TRIGGER trg_rastro_lista_super_admins
  AFTER INSERT OR UPDATE OR DELETE ON public.super_admins
  FOR EACH ROW EXECUTE FUNCTION public.rastro_lista_super_admins();

-- Verificación: debe salir 1 y la función cerrada.
SELECT (SELECT count(*) FROM pg_trigger WHERE tgname = 'trg_rastro_lista_super_admins' AND NOT tgisinternal) AS trigger_creado,
       NOT has_function_privilege('authenticated', 'public.rastro_lista_super_admins()', 'EXECUTE') AS funcion_cerrada;

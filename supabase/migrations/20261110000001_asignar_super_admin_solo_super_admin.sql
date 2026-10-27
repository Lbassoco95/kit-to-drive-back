-- ============================================================================
-- asignar_super_admin — OPCIÓN B (decidida por Polo el 26 oct 2026): solo un SUPER ADMIN agrega o quita super admins
--
-- Hoy (migración 20261016000001) `asignar_super_admin()` la ejecuta SOLO un administrador global que NO es super admin: los dos super admins no
-- pueden agregar ni quitar super admins. Eso va al revés del criterio de la Fase 2 («solo un super admin modifica a otro super admin») y deja ese
-- poder en cuentas sin ese rango (hoy cuatro administradores globales, dos de ellas sin haber entrado nunca). La Fase 2 lo dejó como estaba para
-- no romper la pantalla de Aprobaciones; esta migración lo corrige DESPUÉS de la Fase 2.
--
-- Qué cambia (solo la función; ninguna tabla, política ni trigger):
--   · la puerta pasa de «administrador global que no es super admin» a «super admin»;
--   · lo demás se conserva: no se puede cambiar el propio tipo (por eso la lista nunca queda vacía por esta vía: quien quita siempre es OTRO super admin), la asignación sube al destino a Dirección/admin y deja renglón en
--     `bitacora_super_admin`, y la quitada solo borra de `super_admins` (el destino sigue siendo administrador de Dirección).
-- Efecto para las personas: Polo (administrador global, no super admin) y los demás administradores globales dejan de poder asignar o quitar
-- super admins; pueden Martin y Peter (los dos super admins de hoy). La pantalla de Aprobaciones y la de Usuarios deben mostrar ese control solo a un
-- super admin (cambio de front aparte; con la base nueva y el front viejo, el botón fallaría con el mensaje de la función).
--
-- Mismo nombre y firma (CREATE OR REPLACE): permisos sin cambio (REVOKE a PUBLIC y anon, GRANT a authenticated). Idempotente.
-- Reversa: supabase/reversas/20261110000001_asignar_super_admin_solo_super_admin_reversa.sql (restituye la función de la migración 20261016000001).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.asignar_super_admin(_user_id uuid, _activo boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.es_super_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Sólo un super admin puede asignar o quitar el Super admin.' USING ERRCODE = '42501';
  END IF;
  IF _user_id = auth.uid() THEN
    RAISE EXCEPTION 'No puedes cambiar tu propio tipo de usuario.' USING ERRCODE = '42501';
  END IF;
  IF _activo THEN
    UPDATE public.user_roles SET area = 'direccion', nivel = 'admin' WHERE user_id = _user_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Ese usuario no tiene tipo de usuario asignado.';
    END IF;
    INSERT INTO public.super_admins (user_id, asignado_por) VALUES (_user_id, auth.uid())
    ON CONFLICT (user_id) DO NOTHING;
  ELSE
    DELETE FROM public.super_admins WHERE user_id = _user_id;
  END IF;
  INSERT INTO public.bitacora_super_admin (usuario_id, tabla, operacion, registro_id, datos_despues)
  VALUES (auth.uid(), 'super_admins', CASE WHEN _activo THEN 'ASIGNAR' ELSE 'QUITAR' END, _user_id::text,
          jsonb_build_object('user_id', _user_id, 'activo', _activo));
END
$$;

REVOKE ALL ON FUNCTION public.asignar_super_admin(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.asignar_super_admin(uuid, boolean) TO authenticated;

-- Verificación: la función existe con un solo juego de argumentos, es DEFINER con search_path fijo y exige super admin;
-- anon no la ejecuta y authenticated sí.
SELECT
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'asignar_super_admin') AS sobrecargas,
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'asignar_super_admin' AND p.prosecdef
      AND EXISTS (SELECT 1 FROM unnest(p.proconfig) x WHERE x LIKE 'search_path=%')
      AND p.prosrc LIKE '%NOT public.es_super_admin(auth.uid())%') AS funcion_con_la_regla_nueva,
  has_function_privilege('anon', 'public.asignar_super_admin(uuid, boolean)', 'EXECUTE') AS anon_ejecuta,
  has_function_privilege('authenticated', 'public.asignar_super_admin(uuid, boolean)', 'EXECUTE') AS authenticated_ejecuta;

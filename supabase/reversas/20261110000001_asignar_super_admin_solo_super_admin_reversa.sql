-- REVERSA de 20261110000001: restituye `asignar_super_admin` tal como la dejó la migración 20261016000001 (opción A: solo un administrador
-- global que NO es super admin la ejecuta). Los super admins ya asignados o quitados no cambian: son datos.
CREATE OR REPLACE FUNCTION public.asignar_super_admin(_user_id uuid, _activo boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.es_admin_global(auth.uid()) OR public.es_super_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Sólo un administrador de Dirección puede asignar el Super admin.' USING ERRCODE = '42501';
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
SELECT (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'asignar_super_admin') AS sobrecargas,
       (SELECT count(*) FROM pg_proc p WHERE p.proname = 'asignar_super_admin' AND p.prosrc LIKE '%NOT public.es_super_admin(auth.uid())%') AS con_la_regla_nueva;

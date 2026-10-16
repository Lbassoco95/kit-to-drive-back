-- Super admin entra también a Almacén de refacciones --------------------------
-- El almacén de refacciones se abre solo a quien está en
-- `almacen_refacciones_acceso`. El Super admin ve y modifica todo, así que
-- entra sin estar en esa lista. Eliminar sigue pidiendo aprobación del admin
-- del área (trigger `vigilar_super_admin`) y todo queda en la bitácora.
--
-- Requiere 20261016000001_super_admin_aprobaciones.sql. Se puede correr dos veces.

CREATE OR REPLACE FUNCTION public.puede_ver_almacen_refacciones(_user_id UUID DEFAULT auth.uid())
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.almacen_refacciones_acceso a
    WHERE a.activo
      AND (
        a.user_id = _user_id
        OR lower(a.email) = lower(coalesce(
          (SELECT email FROM auth.users WHERE id = _user_id),
          ''
        ))
      )
  )
  OR public.es_super_admin(_user_id);
$$;

REVOKE ALL ON FUNCTION public.puede_ver_almacen_refacciones(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.puede_ver_almacen_refacciones(UUID) TO authenticated;

SELECT u.email, public.es_super_admin(u.id) AS es_super_admin,
       public.puede_ver_almacen_refacciones(u.id) AS entra_almacen_refacciones
FROM public.super_admins s
JOIN auth.users u ON u.id = s.user_id;

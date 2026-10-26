-- REVERSA de 20261103000003: puede_leer_remision_refaccion() vuelve a la versión de 20260925000001
-- (toda el área comercial lee todas las remisiones de refacciones).
CREATE OR REPLACE FUNCTION public.puede_leer_remision_refaccion(
  _remision_id UUID,
  _user_id UUID DEFAULT auth.uid()
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _rol text;
  _area text;
  _vendedor uuid;
  _creador uuid;
BEGIN
  IF _user_id IS NULL OR _remision_id IS NULL THEN RETURN false; END IF;
  IF EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = _user_id AND p.activo = false) THEN
    RETURN false;
  END IF;

  SELECT r.vendedor_id, r.created_by INTO _vendedor, _creador
  FROM public.remisiones_refacciones r
  WHERE r.id = _remision_id;
  IF NOT FOUND THEN RETURN false; END IF;

  IF public.puede_ver_almacen_refacciones(_user_id) THEN RETURN true; END IF;
  IF _vendedor = _user_id OR _creador = _user_id THEN RETURN true; END IF;

  _rol := public.rol_comercial(_user_id);
  IF _rol IN ('global', 'supervisor') THEN RETURN true; END IF;

  SELECT ur.area::text INTO _area
  FROM public.user_roles ur
  WHERE ur.user_id = _user_id
  LIMIT 1;
  RETURN _area IN ('direccion', 'administracion', 'almacen_logistica', 'comercial');
END;
$$;
SELECT pg_get_functiondef('public.puede_leer_remision_refaccion(uuid,uuid)'::regprocedure) ILIKE '%''comercial'')%' AS lista_original_restaurada;

-- ============================================================================
-- PAQUETE 1 (permisos del vendedor) · 3 de 3: remisiones de refacciones, el vendedor solo ve las suyas
--
-- Criterio 4 (Polo, 26 oct 2026): un vendedor ve únicamente las remisiones donde él es el vendedor,
-- de motocarros y de refacciones.
--
-- Las remisiones de motocarros ya cumplen (20261007000001: vendedor_id = él). Las de refacciones
-- NO: puede_leer_remision_refaccion() termina en «area IN (direccion, administracion,
-- almacen_logistica, comercial)», es decir, TODO usuario del área comercial las lee todas. Esa
-- función la usan las políticas de remisiones_refacciones, sus partidas, órdenes, eventos y
-- correcciones, y solicitar_saldo_favor().
--
-- Cambio: se quita «comercial» de esa lista. Quien siga viendo todo lo ve por su propia vía:
--   · administrador global y supervisores de Comercial: rol_comercial = global | supervisor (ya estaba),
--   · administrativos de Comercial (profiles.es_administrativo): se agrega explícito,
--   · Dirección, Administración y Almacén/Logística: siguen en la lista,
--   · el vendedor dueño o quien capturó la remisión: ya estaba arriba (vendedor_id / created_by),
--   · Compras y Finanzas leen por sus propias políticas, que no cambian.
-- El resto de la función queda idéntico (20260925000001). CREATE OR REPLACE conserva permisos.
-- Idempotente. Reversa: supabase/reversas/20261103000003_paquete1_remisiones_refacciones_solo_del_vendedor_reversa.sql
-- ============================================================================
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
  IF public.es_administrativo_comercial(_user_id) THEN RETURN true; END IF;

  SELECT ur.area::text INTO _area
  FROM public.user_roles ur
  WHERE ur.user_id = _user_id
  LIMIT 1;
  RETURN _area IN ('direccion', 'administracion', 'almacen_logistica');
END;
$$;

-- Verificación: la definición ya no menciona 'comercial' en la lista final y sí al administrativo.
SELECT
  position('''comercial''' IN substring(pg_get_functiondef('public.puede_leer_remision_refaccion(uuid,uuid)'::regprocedure)
           FROM 'RETURN _area IN \([^)]*\)')) = 0 AS sin_comercial_en_la_lista,
  pg_get_functiondef('public.puede_leer_remision_refaccion(uuid,uuid)'::regprocedure) ILIKE '%es_administrativo_comercial%' AS con_administrativo;

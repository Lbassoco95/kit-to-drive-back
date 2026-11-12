-- ============================================================================
-- Cliente con vendedor asignado: nadie se lo puede quitar a otro
-- Fecha: 2026-11-12
--
-- `clientes.vendedor_id` ya existía (y las políticas lo usan para que cada
-- vendedor vea lo suyo), pero no había forma ordenada de asignarlo ni cuidarlo.
-- Esto sirve para reportes por vendedor y para evitar que se "roben" clientes.
--
-- Reglas (las hace cumplir la base, no solo la pantalla):
--  · Asignar o reasignar el vendedor de un cliente: administración de ventas,
--    supervisores/administradores de Comercial y Dirección (admin global).
--  · Un vendedor da de alta clientes solo a su nombre y NO puede cambiar el
--    vendedor de un cliente (ni tomar uno ajeno ni soltar el suyo).
--  · El vendedor asignado tiene que ser alguien del equipo de ventas activo.
-- Sin sesión (migraciones, scripts de servicio) no se restringe. Idempotente.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.puede_asignar_vendedor_cliente(_user_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.es_admin_global(_user_id)
    OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = _user_id AND p.es_administrativo AND coalesce(p.activo, true))
    OR EXISTS (SELECT 1 FROM public.user_roles r
                WHERE r.user_id = _user_id AND r.area = 'comercial' AND r.nivel IN ('supervisor', 'admin'));
$$;
REVOKE ALL ON FUNCTION public.puede_asignar_vendedor_cliente(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.puede_asignar_vendedor_cliente(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.clientes_vendedor_protegido()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL OR public.puede_asignar_vendedor_cliente(v_uid) THEN
    -- Quien asigna: el vendedor tiene que ser del equipo de ventas (solo si cambia o es alta).
    IF NEW.vendedor_id IS NOT NULL
       AND (TG_OP = 'INSERT' OR NEW.vendedor_id IS DISTINCT FROM OLD.vendedor_id)
       AND v_uid IS NOT NULL
       AND NOT public.es_vendedor_activo(NEW.vendedor_id) THEN
      RAISE EXCEPTION 'El vendedor tiene que ser alguien del equipo de ventas';
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.vendedor_id IS NOT NULL AND NEW.vendedor_id <> v_uid THEN
      RAISE EXCEPTION 'Solo puedes dar de alta clientes a tu nombre';
    END IF;
    IF NEW.vendedor_id IS NULL AND public.es_vendedor_activo(v_uid) THEN
      NEW.vendedor_id := v_uid;
    END IF;
  ELSIF NEW.vendedor_id IS DISTINCT FROM OLD.vendedor_id THEN
    RAISE EXCEPTION 'Solo administración de ventas, supervisores de Comercial y Dirección cambian el vendedor de un cliente';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.clientes_vendedor_protegido() FROM PUBLIC, anon;

DROP TRIGGER IF EXISTS trg_clientes_vendedor_protegido ON public.clientes;
CREATE TRIGGER trg_clientes_vendedor_protegido
  BEFORE INSERT OR UPDATE OF vendedor_id ON public.clientes
  FOR EACH ROW EXECUTE FUNCTION public.clientes_vendedor_protegido();

CREATE INDEX IF NOT EXISTS idx_clientes_vendedor ON public.clientes (vendedor_id);

DO $postflight$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_clientes_vendedor_protegido' AND NOT tgisinternal) THEN
    RAISE EXCEPTION 'trg_clientes_vendedor_protegido no se creó.';
  END IF;
  IF has_function_privilege('anon', 'public.puede_asignar_vendedor_cliente(uuid)', 'execute') THEN
    RAISE EXCEPTION 'puede_asignar_vendedor_cliente no debe estar abierta a anon.';
  END IF;
END $postflight$;

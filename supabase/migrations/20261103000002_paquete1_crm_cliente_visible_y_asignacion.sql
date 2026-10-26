-- ============================================================================
-- PAQUETE 1 (permisos del vendedor) · 2 de 3: CRM y alta de clientes del vendedor
--
-- Criterios (Polo, 26 oct 2026):
--  2) Un vendedor puede crear un cliente nuevo y queda asignado a él.
--  3) Un vendedor puede crear oportunidad, ruta y actividad con cualquier cliente que pueda ver.
--     Si usa un cliente sin asignar, queda asignado a él al crearla.
--
-- Hoy las políticas de alta de CRM («*_insert_area») dejan a cualquier usuario de Comercial
-- insertar con cualquier cliente_id, sin comprobar que lo vea, y la de clientes («comercial crea
-- clientes») no comprueba a nombre de quién queda. Se agregan TRIGGERS, no políticas, porque
-- las políticas permisivas se suman (OR) y no pueden restringir lo que otra ya permite.
--
-- «Vendedor» = operador de Comercial activo que NO es administrativo (es_administrativo_comercial).
-- Supervisores, Dirección y administrativos no se auto-asignan nada: conservan lo que hacen hoy.
--
-- Objetos nuevos (todos nacen cerrados desde la Fase 1; ninguno es RPC, ninguno necesita EXECUTE
-- para `authenticated`: PostgreSQL no revisa EXECUTE al disparar un trigger):
--   función  es_vendedor_comercial(uuid)               auxiliar, solo la usan las funciones de abajo
--   función  clientes_asignar_vendedor_al_crear()      trigger BEFORE INSERT en clientes
--   función  crm_validar_cliente_visible()             trigger BEFORE INSERT/UPDATE en 3 tablas de CRM (INVOKER: aplica RLS)
--   función  crm_asignar_cliente_al_usar()             trigger BEFORE INSERT en 3 tablas de CRM (DEFINER)
--   triggers trg_clientes_asignar_vendedor, trg_crm_a_validar_cliente, trg_crm_b_asignar_cliente
-- Idempotente. Reversa: supabase/reversas/20261103000002_paquete1_crm_cliente_visible_y_asignacion_reversa.sql
-- ============================================================================

-- 1) Auxiliar ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.es_vendedor_comercial(_user_id uuid DEFAULT auth.uid())
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT _user_id IS NOT NULL
     AND public.usuario_activo(_user_id)
     AND public.rol_comercial(_user_id) = 'operador'
     AND NOT public.es_administrativo_comercial(_user_id)
$$;
REVOKE ALL ON FUNCTION public.es_vendedor_comercial(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.es_vendedor_comercial(uuid) TO service_role;
COMMENT ON FUNCTION public.es_vendedor_comercial(uuid) IS
  'Operador de Comercial activo que no es administrativo. Solo lo usan los triggers del Paquete 1.';

-- 2) Un cliente nuevo del vendedor queda a su nombre --------------------------
CREATE OR REPLACE FUNCTION public.clientes_asignar_vendedor_al_crear()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NOT NULL AND public.es_vendedor_comercial(auth.uid()) THEN
    NEW.vendedor_id := auth.uid();
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.clientes_asignar_vendedor_al_crear() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_clientes_asignar_vendedor ON public.clientes;
CREATE TRIGGER trg_clientes_asignar_vendedor BEFORE INSERT ON public.clientes
  FOR EACH ROW EXECUTE FUNCTION public.clientes_asignar_vendedor_al_crear();

-- 3) CRM: el cliente debe ser uno que quien captura puede ver ----------------
-- SECURITY INVOKER a propósito: el SELECT corre con los permisos de quien captura, así que
-- responde exactamente a la política «leer clientes» (una sola regla que mantener).
CREATE OR REPLACE FUNCTION public.crm_validar_cliente_visible()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL OR NEW.cliente_id IS NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND NEW.cliente_id IS NOT DISTINCT FROM OLD.cliente_id THEN RETURN NEW; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.clientes c WHERE c.id = NEW.cliente_id) THEN
    RAISE EXCEPTION 'No puedes usar ese cliente: no está entre los que ves'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.crm_validar_cliente_visible() FROM PUBLIC, anon, authenticated;

-- 4) CRM: un cliente sin asignar que el vendedor usa, queda a su nombre -------
CREATE OR REPLACE FUNCTION public.crm_asignar_cliente_al_usar()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _vendedor uuid;
BEGIN
  IF auth.uid() IS NULL OR NEW.cliente_id IS NULL THEN RETURN NEW; END IF;
  IF NOT public.es_vendedor_comercial(auth.uid()) THEN RETURN NEW; END IF;
  IF TG_TABLE_NAME = 'crm_ruta_paradas' THEN
    SELECT r.vendedor_id INTO _vendedor FROM public.crm_rutas r WHERE r.id = NEW.ruta_id;
  ELSE
    _vendedor := NEW.vendedor_id;
  END IF;
  IF _vendedor IS DISTINCT FROM auth.uid() THEN RETURN NEW; END IF;
  UPDATE public.clientes SET vendedor_id = auth.uid()
   WHERE id = NEW.cliente_id AND vendedor_id IS NULL;
  IF FOUND THEN
    INSERT INTO public.clientes_bitacora (cliente_id, usuario_id, tipo_cambio, motivo, datos_nuevos)
    VALUES (NEW.cliente_id, auth.uid(), 'asignacion_automatica',
            'El vendedor usó un cliente sin asignar en ' || TG_TABLE_NAME,
            jsonb_build_object('vendedor_id', auth.uid()));
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.crm_asignar_cliente_al_usar() FROM PUBLIC, anon, authenticated;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['crm_oportunidades', 'crm_actividades', 'crm_ruta_paradas'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_crm_a_validar_cliente ON public.%I', t);
    EXECUTE format('CREATE TRIGGER trg_crm_a_validar_cliente BEFORE INSERT OR UPDATE OF cliente_id ON public.%I
                    FOR EACH ROW EXECUTE FUNCTION public.crm_validar_cliente_visible()', t);
    EXECUTE format('DROP TRIGGER IF EXISTS trg_crm_b_asignar_cliente ON public.%I', t);
    EXECUTE format('CREATE TRIGGER trg_crm_b_asignar_cliente BEFORE INSERT ON public.%I
                    FOR EACH ROW EXECUTE FUNCTION public.crm_asignar_cliente_al_usar()', t);
  END LOOP;
END $$;

-- Verificación: 4 funciones nuevas, 7 triggers nuevos, ninguna ejecutable por anon ni authenticated.
SELECT
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname IN ('es_vendedor_comercial', 'clientes_asignar_vendedor_al_crear',
          'crm_validar_cliente_visible', 'crm_asignar_cliente_al_usar')) AS funciones_nuevas,
  (SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal AND tgname IN
          ('trg_clientes_asignar_vendedor', 'trg_crm_a_validar_cliente', 'trg_crm_b_asignar_cliente')) AS triggers_nuevos,
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname IN ('es_vendedor_comercial', 'clientes_asignar_vendedor_al_crear',
          'crm_validar_cliente_visible', 'crm_asignar_cliente_al_usar')
      AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR has_function_privilege('authenticated', p.oid, 'EXECUTE'))) AS ejecutables_por_anon_o_authenticated;

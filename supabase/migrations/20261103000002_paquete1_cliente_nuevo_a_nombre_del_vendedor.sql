-- ============================================================================
-- PAQUETE 1 (permisos del vendedor) · 2 de 3: el cliente NUEVO de un vendedor queda a su nombre,
-- y una remisión solo se captura a un cliente que el vendedor ya ve
--
-- Decisión de Polo (26 oct 2026): solo un cliente NUEVO creado por un vendedor queda asignado a él.
-- NO se asigna automáticamente un cliente sin asignar cuando se usa en oportunidad, ruta o actividad.
--
-- Hoy la política de alta («comercial crea clientes») deja a cualquier usuario de Comercial insertar
-- sin comprobar a nombre de quién queda: un cliente sin vendedor, o a nombre de otro, que el propio
-- vendedor ya no vería. Se agrega un TRIGGER (no una política: las permisivas se suman y no pueden
-- restringir lo que otra ya permite).
--
-- Segundo punto, consecuencia del catálogo básico (migración 1): el catálogo le da al vendedor el id de
-- TODOS los clientes, y la política de alta de remisiones no comprueba que el cliente sea uno que ve.
-- Como «leer clientes» deja ver la ficha completa de los clientes de las propias remisiones, un vendedor
-- podía abrir la ficha (crédito, saldo, documentos) de cualquier cliente creando una remisión por la API.
-- La pantalla nunca lo permitió (el selector solo lista los visibles); este trigger lo cierra en la base:
-- el vendedor solo puede capturar una remisión a un cliente que YA ve (con la política de clientes, sin
-- cambios). No cambia ninguna pantalla. Supervisores, Dirección y administrativos no se ven afectados.
--
-- «Vendedor» = operador de Comercial activo que NO es administrativo (es_administrativo_comercial).
-- Supervisores, Dirección y administrativos no se auto-asignan nada: conservan lo que hacen hoy.
--
-- Objetos nuevos (nacen cerrados desde la Fase 1; ninguno es RPC ni necesita EXECUTE para
-- `authenticated`: PostgreSQL no revisa EXECUTE al disparar un trigger):
--   función es_vendedor_comercial(uuid)             auxiliar, solo la usa la función de abajo
--   función clientes_asignar_vendedor_al_crear()    trigger BEFORE INSERT en clientes
--   trigger trg_clientes_asignar_vendedor
--   función remisiones_validar_cliente_visible()    trigger BEFORE INSERT/UPDATE OF cliente_id en remisiones (INVOKER: aplica RLS)
--   trigger trg_remisiones_validar_cliente
-- Idempotente. Reversa: supabase/reversas/20261103000002_paquete1_cliente_nuevo_a_nombre_del_vendedor_reversa.sql
-- ============================================================================
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
  'Operador de Comercial activo que no es administrativo. Solo lo usa el trigger de alta de clientes del Paquete 1.';

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

-- INVOKER a propósito: el SELECT corre con los permisos de quien captura, así que responde exactamente a la
-- política «leer clientes» (una sola regla que mantener). Solo usa funciones que `authenticated` ya ejecuta.
CREATE OR REPLACE FUNCTION public.remisiones_validar_cliente_visible()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL OR NEW.cliente_id IS NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND NEW.cliente_id IS NOT DISTINCT FROM OLD.cliente_id THEN RETURN NEW; END IF;
  -- Solo al vendedor (operador de Comercial activo, no administrativo); a los demás no les cambia nada.
  IF public.rol_comercial(auth.uid()) <> 'operador' OR public.es_administrativo_comercial(auth.uid()) THEN RETURN NEW; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.clientes c WHERE c.id = NEW.cliente_id) THEN
    RAISE EXCEPTION 'No puedes capturar una remisión a un cliente que no ves: pide que te lo asignen' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.remisiones_validar_cliente_visible() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_remisiones_validar_cliente ON public.remisiones;
CREATE TRIGGER trg_remisiones_validar_cliente BEFORE INSERT OR UPDATE OF cliente_id ON public.remisiones
  FOR EACH ROW EXECUTE FUNCTION public.remisiones_validar_cliente_visible();

-- Verificación: 3 funciones y 2 triggers nuevos; ninguna ejecutable por anon ni authenticated.
SELECT
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname IN ('es_vendedor_comercial', 'clientes_asignar_vendedor_al_crear', 'remisiones_validar_cliente_visible')) AS funciones_nuevas,
  (SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal AND tgname IN ('trg_clientes_asignar_vendedor', 'trg_remisiones_validar_cliente')) AS triggers_nuevos,
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname IN ('es_vendedor_comercial', 'clientes_asignar_vendedor_al_crear', 'remisiones_validar_cliente_visible')
      AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR has_function_privilege('authenticated', p.oid, 'EXECUTE'))) AS ejecutables_por_anon_o_authenticated;

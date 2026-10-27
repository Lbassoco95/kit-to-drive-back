-- ============================================================================
-- PAQUETE 3 (eliminar remisión, fecha de remisión) · 1 de 3: interruptor GLOBAL de «modo prueba»
--
-- Decisión de Polo (26 oct 2026, D-A1 = A): hoy «modo prueba» es por USUARIO (tabla `inventario_usuarios_prueba`) y
-- marca datos de prueba. Para poder eliminar remisiones mientras el sistema está en pruebas, y dejar de poder
-- hacerlo cuando entre en operación definitiva, se crea un interruptor GLOBAL que apaga Dirección.
--
-- Dónde vive: una fila en `compras_parametros` (clave `modo_prueba_global`, valor true/false). Nace APAGADO
-- (decisión de Polo tras la revisión independiente: hay datos reales en producción; Dirección lo enciende solo cuando lo necesite). Quién lo cambia: solo Dirección o un super admin, SOLO por `fijar_modo_prueba_global`
-- (queda en `bitacora_eventos`). Un trigger impide tocar esa fila de otra forma (la política actual de
-- `compras_parametros` deja escribir a quien puede compras/inventario, y no debe poder apagarlo ni encenderlo).
-- Si la fila no existe se interpreta como APAGADO (lo seguro).
--
-- Objetos nuevos: 3 funciones (`modo_prueba_global_activo`, `fijar_modo_prueba_global`, `proteger_modo_prueba_global`),
-- 1 trigger y 1 fila de datos. Idempotente.
-- Reversa: supabase/reversas/20261109000001_paquete3_modo_prueba_global_reversa.sql
-- ============================================================================
INSERT INTO public.compras_parametros (clave, valor, descripcion)
VALUES ('modo_prueba_global', 'false'::jsonb,
        'Interruptor global de modo prueba (Paquete 3). Encendido: un super admin puede eliminar remisiones sin pagos ni entregas (con folio y motivo). Se cambia solo con fijar_modo_prueba_global.')
ON CONFLICT (clave) DO NOTHING;

CREATE OR REPLACE FUNCTION public.proteger_modo_prueba_global()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF ((TG_OP <> 'INSERT' AND OLD.clave = 'modo_prueba_global') OR (TG_OP <> 'DELETE' AND NEW.clave = 'modo_prueba_global'))
     AND coalesce(current_setting('kit.permite_modo_prueba_global', true), '') <> '1' THEN
    RAISE EXCEPTION 'El modo prueba global solo se cambia con «fijar_modo_prueba_global» (Dirección o super admin)' USING ERRCODE = '42501';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_proteger_modo_prueba_global ON public.compras_parametros;
CREATE TRIGGER trg_proteger_modo_prueba_global
  BEFORE INSERT OR UPDATE OR DELETE ON public.compras_parametros
  FOR EACH ROW EXECUTE FUNCTION public.proteger_modo_prueba_global();

CREATE OR REPLACE FUNCTION public.modo_prueba_global_activo()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce((SELECT valor = 'true'::jsonb FROM public.compras_parametros WHERE clave = 'modo_prueba_global'), false)
$$;

CREATE OR REPLACE FUNCTION public.fijar_modo_prueba_global(_activo boolean, _motivo text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_antes boolean := public.modo_prueba_global_activo();
BEGIN
  IF auth.uid() IS NULL OR NOT (
       (public.es_area(auth.uid(), 'direccion'::public.user_area) AND public.usuario_activo(auth.uid()))
       OR public.es_super_admin(auth.uid())
     ) THEN
    RAISE EXCEPTION 'Solo Dirección o un super admin cambia el modo prueba global' USING ERRCODE = '42501';
  END IF;
  IF _activo IS NULL THEN RAISE EXCEPTION 'Indica si el modo prueba queda encendido o apagado'; END IF;
  IF nullif(trim(_motivo), '') IS NULL OR char_length(trim(_motivo)) < 5 THEN
    RAISE EXCEPTION 'Escribe el motivo (mínimo 5 caracteres)';
  END IF;
  PERFORM set_config('kit.permite_modo_prueba_global', '1', true);
  INSERT INTO public.compras_parametros (clave, valor, descripcion, updated_by, updated_at)
  VALUES ('modo_prueba_global', to_jsonb(_activo), 'Interruptor global de modo prueba (Paquete 3).', auth.uid(), now())
  ON CONFLICT (clave) DO UPDATE SET valor = EXCLUDED.valor, updated_by = EXCLUDED.updated_by, updated_at = EXCLUDED.updated_at;
  PERFORM set_config('kit.permite_modo_prueba_global', '', true);
  INSERT INTO public.bitacora_eventos (usuario_id, modulo, accion, entidad_tipo, entidad_id, datos_antes, datos_despues)
  VALUES (auth.uid(), 'configuracion', 'modo_prueba_global', 'compras_parametros', NULL,
          jsonb_build_object('activo', v_antes), jsonb_build_object('activo', _activo, 'motivo', trim(_motivo)));
  RETURN _activo;
END;
$$;

REVOKE ALL ON FUNCTION public.proteger_modo_prueba_global() FROM PUBLIC, anon, authenticated;  -- función de trigger: nadie la llama
REVOKE ALL ON FUNCTION public.modo_prueba_global_activo() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fijar_modo_prueba_global(boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.modo_prueba_global_activo() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.fijar_modo_prueba_global(boolean, text) TO authenticated, service_role;

-- Verificación: fila apagada, trigger de protección, 2 funciones DEFINER con search_path fijo, anon sin EXECUTE.
SELECT
  (SELECT valor FROM public.compras_parametros WHERE clave = 'modo_prueba_global') AS valor_inicial,
  (SELECT count(*) FROM pg_trigger WHERE tgname = 'trg_proteger_modo_prueba_global' AND NOT tgisinternal) AS trigger_proteccion,
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname IN ('modo_prueba_global_activo', 'fijar_modo_prueba_global') AND p.prosecdef
      AND EXISTS (SELECT 1 FROM unnest(p.proconfig) x WHERE x LIKE 'search_path=%')) AS funciones_definer_con_search_path,
  has_function_privilege('anon', 'public.fijar_modo_prueba_global(boolean, text)', 'EXECUTE') AS anon_ejecuta;

-- ============================================================================
-- Super admin: acción directa con aviso al admin del área (2026-10-20).
--
-- Antes el Super admin no podía eliminar, cancelar remisiones ni revertir
-- pagos: se generaba una solicitud que aprobaba el admin del área. Ahora:
--   * El Super admin elimina, cancela y revierte en el momento.
--   * Al admin del área dueña (o, si no hay, a los admins de Dirección) le
--     llega un aviso en la campana (`notificaciones`). El aviso es informativo:
--     no puede frenar la acción.
--   * Todo sigue quedando en `bitacora_super_admin` con el antes y el después.
--   * En Aprobaciones el Super admin puede aprobar, rechazar o eliminar
--     cualquier solicitud, incluidas las que él generó.
--
-- Requiere 20261016000001_super_admin_aprobaciones.sql. Idempotente.
-- ============================================================================

-- 1. Aviso al admin del área ---------------------------------------------------
CREATE OR REPLACE FUNCTION public.avisar_admins_area(
  _area public.user_area, _titulo text, _cuerpo text, _enlace text DEFAULT '/aprobaciones')
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_nombre text;
  v_n      integer;
BEGIN
  SELECT coalesce(nullif(p.nombre_completo, ''), p.email) INTO v_nombre FROM public.profiles p WHERE p.id = v_uid;

  INSERT INTO public.notificaciones (usuario_destino, tipo, titulo, cuerpo, enlace, creado_por, nombre_creador)
  SELECT DISTINCT ur.user_id, 'super_admin', _titulo, _cuerpo, _enlace, v_uid, v_nombre
    FROM public.user_roles ur
    LEFT JOIN public.profiles p ON p.id = ur.user_id
   WHERE ur.area = _area AND ur.nivel = 'admin' AND coalesce(p.activo, true)
     AND ur.user_id IS DISTINCT FROM v_uid
     AND NOT EXISTS (SELECT 1 FROM public.super_admins s WHERE s.user_id = ur.user_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;

  -- Área sin admin: avisa a los admins de Dirección.
  IF v_n = 0 AND _area <> 'direccion' THEN
    INSERT INTO public.notificaciones (usuario_destino, tipo, titulo, cuerpo, enlace, creado_por, nombre_creador)
    SELECT DISTINCT ur.user_id, 'super_admin', _titulo, _cuerpo, _enlace, v_uid, v_nombre
      FROM public.user_roles ur
      LEFT JOIN public.profiles p ON p.id = ur.user_id
     WHERE ur.area = 'direccion' AND ur.nivel = 'admin' AND coalesce(p.activo, true)
       AND ur.user_id IS DISTINCT FROM v_uid
       AND NOT EXISTS (SELECT 1 FROM public.super_admins s WHERE s.user_id = ur.user_id);
    GET DIAGNOSTICS v_n = ROW_COUNT;
  END IF;
  RETURN v_n;
END
$$;
REVOKE ALL ON FUNCTION public.avisar_admins_area(public.user_area, text, text, text) FROM PUBLIC, anon, authenticated;

-- 2. El trigger ya no frena: registra y avisa --------------------------------
CREATE OR REPLACE FUNCTION public.vigilar_super_admin()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_ruta   text := current_setting('request.path', true);
  v_metodo text := current_setting('request.method', true);
  v_rpc    text;
  v_nuevo  jsonb;
  v_viejo  jsonb;
  v_objeto text;
  v_titulo text;
  v_clave  text;
  v_hechos text;
BEGIN
  IF v_uid IS NULL OR NOT EXISTS (SELECT 1 FROM public.super_admins WHERE user_id = v_uid) THEN
    RETURN NULL;
  END IF;
  IF NOT public.es_admin_global(v_uid) THEN
    RETURN NULL;
  END IF;

  IF TG_OP <> 'DELETE' THEN v_nuevo := to_jsonb(NEW); END IF;
  IF TG_OP <> 'INSERT' THEN v_viejo := to_jsonb(OLD); END IF;

  IF pg_trigger_depth() = 1 THEN
    v_rpc := CASE WHEN v_ruta LIKE '%/rpc/%' THEN regexp_replace(v_ruta, '^.*/rpc/', '') END;
    -- Borrar directo (los renglones de una remisión se reemplazan al editarla: eso es modificar).
    IF TG_OP = 'DELETE' AND v_metodo = 'DELETE' AND TG_TABLE_NAME <> 'remision_items' THEN
      v_objeto := TG_TABLE_NAME;
      v_titulo := 'El Super admin eliminó un registro de ' || TG_TABLE_NAME;
    -- Eliminar, cancelar o revertir por función.
    ELSIF v_rpc IS NOT NULL AND public.es_rpc_con_aprobacion(v_rpc) THEN
      v_objeto := v_rpc;
      v_titulo := 'El Super admin ejecutó ' || v_rpc;
    -- Cancelar una remisión de motos.
    ELSIF TG_TABLE_NAME = 'remisiones' AND TG_OP = 'UPDATE'
       AND v_nuevo->>'estatus' = 'CANCELADA' AND v_viejo->>'estatus' IS DISTINCT FROM 'CANCELADA' THEN
      v_objeto := 'remisiones';
      v_titulo := 'El Super admin canceló la remisión ' || coalesce(v_nuevo->>'folio_remision', v_nuevo->>'id');
    END IF;

    -- Un solo aviso por acción aunque toque muchos renglones.
    IF v_objeto IS NOT NULL THEN
      v_clave  := TG_TABLE_NAME || ':' || v_objeto;
      v_hechos := coalesce(current_setting('kawiil.avisos_super_admin', true), '');
      IF position('|' || v_clave || '|' IN v_hechos) = 0 THEN
        PERFORM set_config('kawiil.avisos_super_admin', v_hechos || '|' || v_clave || '|', true);
        PERFORM public.avisar_admins_area(public.area_que_aprueba(v_objeto), v_titulo,
          left(TG_TABLE_NAME || ' ' || coalesce(v_viejo->>'id', v_nuevo->>'id', ''), 500), '/aprobaciones');
      END IF;
    END IF;
  END IF;

  INSERT INTO public.bitacora_super_admin (usuario_id, tabla, operacion, registro_id, datos_antes, datos_despues, ruta)
  VALUES (v_uid, TG_TABLE_NAME, TG_OP, coalesce(v_nuevo->>'id', v_viejo->>'id'), v_viejo, v_nuevo, v_ruta);
  RETURN NULL;
END
$$;
REVOKE ALL ON FUNCTION public.vigilar_super_admin() FROM PUBLIC;
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated', 'service_role', 'supabase_auth_admin'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION public.vigilar_super_admin() TO %I', r);
    END IF;
  END LOOP;
END
$$;

-- Tablas creadas después del 2026-10-16 también quedan en la bitácora.
DO $$
DECLARE t text;
BEGIN
  FOR t IN
    SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind = 'r' AND NOT c.relispartition
       AND c.relname NOT IN ('super_admins', 'bitacora_super_admin', 'solicitudes_aprobacion',
                             'notificaciones', 'historial_conexiones')
       AND c.relname NOT LIKE 'bitacora%'
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_vigilar_super_admin ON public.%I', t);
    EXECUTE format(
      'CREATE TRIGGER trg_vigilar_super_admin AFTER INSERT OR UPDATE OR DELETE ON public.%I
         FOR EACH ROW EXECUTE FUNCTION public.vigilar_super_admin()', t);
  END LOOP;
END
$$;

-- 3. Resolver: el Super admin resuelve cualquiera, también las suyas ------------
CREATE OR REPLACE FUNCTION public.resolver_solicitud_aprobacion(_id uuid, _aprobar boolean, _comentario text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  s       public.solicitudes_aprobacion%ROWTYPE;
  v_super boolean := public.es_super_admin(auth.uid());
  v_where text;
  v_args  text;
  v_n     integer;
BEGIN
  SELECT * INTO s FROM public.solicitudes_aprobacion WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'La solicitud no existe.'; END IF;
  IF s.estado <> 'pendiente' THEN RAISE EXCEPTION 'La solicitud ya fue resuelta.'; END IF;
  IF NOT (v_super OR (public.es_admin_de_area(s.area, auth.uid()) AND s.solicitado_por <> auth.uid())) THEN
    RAISE EXCEPTION 'Sólo el Super admin o el administrador del área pueden resolver esta solicitud.' USING ERRCODE = '42501';
  END IF;

  IF NOT _aprobar THEN
    UPDATE public.solicitudes_aprobacion
       SET estado = 'rechazada', resuelto_por = auth.uid(), resuelto_en = now(), comentario = _comentario
     WHERE id = _id;
    INSERT INTO public.bitacora_super_admin (usuario_id, tabla, operacion, registro_id, datos_despues)
    VALUES (auth.uid(), 'solicitudes_aprobacion', 'RECHAZAR', _id::text,
            jsonb_build_object('tipo', s.tipo, 'objeto', s.objeto, 'parametros', s.parametros, 'comentario', _comentario));
    IF v_super THEN
      PERFORM public.avisar_admins_area(s.area, 'El Super admin rechazó una solicitud',
        left(coalesce(s.descripcion, s.objeto), 500), '/aprobaciones');
    END IF;
    RETURN 'rechazada';
  END IF;

  BEGIN
    IF s.tipo = 'borrar' THEN
      SELECT string_agg(format('%I::text = %L', key, value), ' AND ')
        INTO v_where FROM jsonb_each_text(s.parametros);
      EXECUTE format('DELETE FROM public.%I WHERE %s', s.objeto, v_where);
      GET DIAGNOSTICS v_n = ROW_COUNT;
      IF v_n = 0 THEN RAISE EXCEPTION 'El registro ya no existe.'; END IF;
    ELSIF s.tipo = 'cancelar_remision' THEN
      UPDATE public.motocarros SET remision_id = NULL WHERE remision_id::text = s.parametros->>'id';
      UPDATE public.remisiones SET estatus = 'CANCELADA' WHERE id::text = s.parametros->>'id';
    ELSE
      SELECT string_agg(
               format('%I => %s', a.nombre,
                 CASE
                   WHEN s.parametros->a.nombre IS NULL OR jsonb_typeof(s.parametros->a.nombre) = 'null'
                     THEN format('NULL::%s', a.tipo::regtype)
                   WHEN a.tipo IN ('jsonb'::regtype, 'json'::regtype)
                     THEN format('%L::%s', (s.parametros->a.nombre)::text, a.tipo::regtype)
                   WHEN jsonb_typeof(s.parametros->a.nombre) = 'array'
                     THEN format('ARRAY(SELECT jsonb_array_elements_text(%L::jsonb))::%s',
                                 (s.parametros->a.nombre)::text, a.tipo::regtype)
                   ELSE format('%L::%s', s.parametros->>a.nombre, a.tipo::regtype)
                 END), ', ')
        INTO v_args
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        CROSS JOIN LATERAL unnest(p.proargnames[1:p.pronargs], p.proargtypes::oid[]) AS a(nombre, tipo)
       WHERE n.nspname = 'public' AND p.proname = s.objeto
         AND s.parametros ? a.nombre;
      EXECUTE format('SELECT public.%I(%s)', s.objeto, coalesce(v_args, ''));
    END IF;
  EXCEPTION WHEN OTHERS THEN
    UPDATE public.solicitudes_aprobacion
       SET estado = 'fallida', resuelto_por = auth.uid(), resuelto_en = now(),
           comentario = _comentario, error = SQLERRM
     WHERE id = _id;
    RETURN 'fallida: ' || SQLERRM;
  END;

  UPDATE public.solicitudes_aprobacion
     SET estado = 'aprobada', resuelto_por = auth.uid(), resuelto_en = now(), comentario = _comentario
   WHERE id = _id;
  INSERT INTO public.bitacora_super_admin (usuario_id, tabla, operacion, registro_id, datos_despues)
  VALUES (auth.uid(), 'solicitudes_aprobacion', 'APROBAR', _id::text,
          jsonb_build_object('tipo', s.tipo, 'objeto', s.objeto, 'parametros', s.parametros));
  IF v_super THEN
    PERFORM public.avisar_admins_area(s.area, 'El Super admin aprobó y aplicó una solicitud',
      left(coalesce(s.descripcion, s.objeto), 500), '/aprobaciones');
  END IF;
  RETURN 'aprobada';
END
$$;
REVOKE ALL ON FUNCTION public.resolver_solicitud_aprobacion(uuid, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resolver_solicitud_aprobacion(uuid, boolean, text) TO authenticated;

-- 4. Eliminar una solicitud ---------------------------------------------------
CREATE OR REPLACE FUNCTION public.eliminar_solicitud_aprobacion(_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  s public.solicitudes_aprobacion%ROWTYPE;
BEGIN
  IF NOT public.es_admin_global(auth.uid()) THEN
    RAISE EXCEPTION 'Sólo el Super admin o un administrador de Dirección eliminan solicitudes.' USING ERRCODE = '42501';
  END IF;
  DELETE FROM public.solicitudes_aprobacion WHERE id = _id RETURNING * INTO s;
  IF NOT FOUND THEN RAISE EXCEPTION 'La solicitud no existe.'; END IF;
  INSERT INTO public.bitacora_super_admin (usuario_id, tabla, operacion, registro_id, datos_antes)
  VALUES (auth.uid(), 'solicitudes_aprobacion', 'ELIMINAR', _id::text, to_jsonb(s));
  PERFORM public.avisar_admins_area(s.area, 'Se eliminó una solicitud de aprobación',
    left(coalesce(s.descripcion, s.objeto), 500), '/aprobaciones');
END
$$;
REVOKE ALL ON FUNCTION public.eliminar_solicitud_aprobacion(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.eliminar_solicitud_aprobacion(uuid) TO authenticated;

-- Verificación: debe dar tablas_vigiladas > 0 y las dos funciones en true.
SELECT (SELECT count(*) FROM pg_trigger WHERE tgname = 'trg_vigilar_super_admin') AS tablas_vigiladas,
       to_regprocedure('public.eliminar_solicitud_aprobacion(uuid)') IS NOT NULL AS eliminar_solicitud,
       to_regprocedure('public.avisar_admins_area(public.user_area,text,text,text)') IS NOT NULL AS aviso_admin;

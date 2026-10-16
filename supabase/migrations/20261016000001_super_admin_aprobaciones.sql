-- ============================================================================
-- Super admin con aprobaciones y bitácora (2026-10-16).
--
-- El Super admin es un admin de Dirección que puede entrar y modificar todo,
-- pero que NO borra directo: eliminar registros, cancelar remisiones y
-- revertir pagos generan una solicitud que aprueba el admin del área dueña
-- (Comercial para remisiones y clientes, Administración para finanzas y
-- cobranza, Compras para compras y almacén, Fábrica para producción). El admin
-- de Dirección puede aprobar cualquiera. Todo lo que escribe el Super admin
-- queda en `bitacora_super_admin` con el antes y el después.
--
-- Quién es Super admin vive en `super_admins` y no en `user_roles`, porque
-- admin-update-user borra y vuelve a crear la fila de `user_roles` cada vez
-- que se edita un usuario. Sólo un admin de Dirección (que no sea Super admin)
-- lo asigna, con `asignar_super_admin`.
--
-- El freno es un trigger en las tablas de `public`; para cualquier otro
-- usuario sólo revisa si es Super admin y sale. Las tablas que se creen después
-- de este script no lo traen: vuelve a correr este archivo. Idempotente.
-- ============================================================================

-- 1. Quién es Super admin -----------------------------------------------------
CREATE TABLE IF NOT EXISTS public.super_admins (
  user_id      uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  asignado_por uuid REFERENCES auth.users(id),
  creado_en    timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.super_admins ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.super_admins FROM PUBLIC, anon, authenticated;

-- Sólo cuenta mientras siga siendo admin de Dirección.
CREATE OR REPLACE FUNCTION public.es_super_admin(_user_id uuid DEFAULT auth.uid())
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT _user_id IS NOT NULL
     AND (_user_id = auth.uid() OR auth.uid() IS NULL OR public.es_admin_global(auth.uid()))
     AND EXISTS (SELECT 1 FROM public.super_admins WHERE user_id = _user_id)
     AND public.es_admin_global(_user_id)
$$;
REVOKE ALL ON FUNCTION public.es_super_admin(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.es_super_admin(uuid) TO authenticated;

-- 2. Bitácora ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.bitacora_super_admin (
  id            bigserial PRIMARY KEY,
  usuario_id    uuid,
  tabla         text NOT NULL,
  operacion     text NOT NULL,
  registro_id   text,
  datos_antes   jsonb,
  datos_despues jsonb,
  ruta          text,
  creado_en     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS bitacora_super_admin_creado_idx ON public.bitacora_super_admin (creado_en DESC);
ALTER TABLE public.bitacora_super_admin ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.bitacora_super_admin FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.bitacora_super_admin TO authenticated;
DROP POLICY IF EXISTS "admins leen bitacora super admin" ON public.bitacora_super_admin;
CREATE POLICY "admins leen bitacora super admin" ON public.bitacora_super_admin
  FOR SELECT TO authenticated USING (public.nivel_al_menos(auth.uid(), 'admin'::public.user_nivel));

-- 3. Solicitudes de aprobación ------------------------------------------------
CREATE TABLE IF NOT EXISTS public.solicitudes_aprobacion (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tipo           text NOT NULL CHECK (tipo IN ('borrar', 'rpc', 'cancelar_remision')),
  objeto         text NOT NULL,
  parametros     jsonb NOT NULL DEFAULT '{}'::jsonb,
  area           public.user_area NOT NULL,
  descripcion    text,
  motivo         text NOT NULL,
  estado         text NOT NULL DEFAULT 'pendiente' CHECK (estado IN ('pendiente', 'aprobada', 'rechazada', 'fallida')),
  solicitado_por uuid NOT NULL REFERENCES auth.users(id),
  solicitado_en  timestamptz NOT NULL DEFAULT now(),
  resuelto_por   uuid REFERENCES auth.users(id),
  resuelto_en    timestamptz,
  comentario     text,
  error          text
);
CREATE INDEX IF NOT EXISTS solicitudes_aprobacion_estado_idx ON public.solicitudes_aprobacion (estado, solicitado_en DESC);
ALTER TABLE public.solicitudes_aprobacion ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.solicitudes_aprobacion FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.solicitudes_aprobacion TO authenticated;
DROP POLICY IF EXISTS "ver solicitudes propias o de mi area" ON public.solicitudes_aprobacion;
CREATE POLICY "ver solicitudes propias o de mi area" ON public.solicitudes_aprobacion
  FOR SELECT TO authenticated
  USING (solicitado_por = auth.uid() OR public.es_admin_de_area(area, auth.uid()));

-- Funciones que se consideran eliminar / cancelar / revertir.
CREATE OR REPLACE FUNCTION public.es_rpc_con_aprobacion(_nombre text)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT _nombre ~ '^(eliminar|borrar|cancelar|revertir)_'
$$;
REVOKE ALL ON FUNCTION public.es_rpc_con_aprobacion(text) FROM PUBLIC, anon;

-- Área cuyo admin aprueba, según la tabla o la función.
CREATE OR REPLACE FUNCTION public.area_que_aprueba(_objeto text)
RETURNS public.user_area LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT (CASE
    WHEN _objeto ~ '(movimiento|cuentas_financieras|categorias_financieras|flujo_|^pagos$|cxc|cuentas_por_cobrar|cobranza|revertir_pago)' THEN 'administracion'
    WHEN _objeto ~ '(remision|clientes|crm_)' THEN 'comercial'
    WHEN _objeto ~ '(compra|articulo|almacen_refacciones|proveedores|recepciones|ajustes_inventario|contenedores)' THEN 'compras'
    WHEN _objeto ~ '(motocarro|inventario_|incidencias|modelos_producto|reportes_turno|orden_armado)' THEN 'fabrica'
    ELSE 'direccion'
  END)::public.user_area
$$;
REVOKE ALL ON FUNCTION public.area_que_aprueba(text) FROM PUBLIC, anon;

-- 4. El freno y el registro ---------------------------------------------------
CREATE OR REPLACE FUNCTION public.vigilar_super_admin()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_ruta   text := current_setting('request.path', true);
  v_metodo text := current_setting('request.method', true);
  v_nuevo  jsonb;
  v_viejo  jsonb;
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
    -- Borrar directo (los renglones de una remisión se reemplazan al editarla: eso es modificar).
    IF TG_OP = 'DELETE' AND v_metodo = 'DELETE' AND TG_TABLE_NAME <> 'remision_items' THEN
      RAISE EXCEPTION 'Eliminar requiere aprobación del administrador del área.'
        USING ERRCODE = '42501', HINT = 'aprobacion_requerida';
    END IF;
    -- Eliminar, cancelar o revertir por función.
    IF public.es_rpc_con_aprobacion(regexp_replace(coalesce(v_ruta, ''), '^.*/rpc/', '')) AND v_ruta LIKE '%/rpc/%' THEN
      RAISE EXCEPTION 'Esta acción requiere aprobación del administrador del área.'
        USING ERRCODE = '42501', HINT = 'aprobacion_requerida';
    END IF;
    -- Cancelar una remisión de motos.
    IF TG_TABLE_NAME = 'remisiones' AND TG_OP = 'UPDATE'
       AND v_nuevo->>'estatus' = 'CANCELADA' AND v_viejo->>'estatus' IS DISTINCT FROM 'CANCELADA' THEN
      RAISE EXCEPTION 'Cancelar una remisión requiere aprobación del administrador de Comercial.'
        USING ERRCODE = '42501', HINT = 'aprobacion_requerida';
    END IF;
  END IF;

  INSERT INTO public.bitacora_super_admin (usuario_id, tabla, operacion, registro_id, datos_antes, datos_despues, ruta)
  VALUES (v_uid, TG_TABLE_NAME, TG_OP, coalesce(v_nuevo->>'id', v_viejo->>'id'), v_viejo, v_nuevo, v_ruta);
  RETURN NULL;
END
$$;
REVOKE ALL ON FUNCTION public.vigilar_super_admin() FROM PUBLIC;
-- Lo dispara quien escribe en la tabla (la app, las Edge Functions y el alta de cuentas).
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

-- 5. Asignar / quitar Super admin ---------------------------------------------
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

CREATE OR REPLACE FUNCTION public.super_admins_ids()
RETURNS SETOF uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT user_id FROM public.super_admins WHERE public.es_admin_global(auth.uid())
$$;
REVOKE ALL ON FUNCTION public.super_admins_ids() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.super_admins_ids() TO authenticated;

-- 6. Pedir y resolver ---------------------------------------------------------
CREATE OR REPLACE FUNCTION public.solicitar_aprobacion(
  _tipo text, _objeto text, _parametros jsonb, _descripcion text, _motivo text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_id   uuid;
  v_area public.user_area;
  k      text;
BEGIN
  IF NOT public.es_super_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Sólo el Super admin pide aprobaciones.' USING ERRCODE = '42501';
  END IF;
  IF length(trim(coalesce(_motivo, ''))) < 3 THEN
    RAISE EXCEPTION 'Escribe el motivo.';
  END IF;
  IF jsonb_typeof(_parametros) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Parámetros inválidos.';
  END IF;

  IF _tipo = 'borrar' THEN
    IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                    WHERE n.nspname = 'public' AND c.relname = _objeto AND c.relkind = 'r') THEN
      RAISE EXCEPTION 'Tabla desconocida: %', _objeto;
    END IF;
    IF _parametros = '{}'::jsonb THEN
      RAISE EXCEPTION 'Falta indicar qué registro se elimina.';
    END IF;
    FOR k IN SELECT jsonb_object_keys(_parametros) LOOP
      IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                      WHERE table_schema = 'public' AND table_name = _objeto AND column_name = k) THEN
        RAISE EXCEPTION 'Columna desconocida: %.%', _objeto, k;
      END IF;
    END LOOP;
  ELSIF _tipo = 'rpc' THEN
    IF NOT public.es_rpc_con_aprobacion(_objeto)
       OR NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                       WHERE n.nspname = 'public' AND p.proname = _objeto) THEN
      RAISE EXCEPTION 'Acción no permitida: %', _objeto;
    END IF;
  ELSIF _tipo = 'cancelar_remision' THEN
    _objeto := 'remisiones';
    IF NOT EXISTS (SELECT 1 FROM public.remisiones WHERE id::text = _parametros->>'id') THEN
      RAISE EXCEPTION 'La remisión no existe.';
    END IF;
  ELSE
    RAISE EXCEPTION 'Tipo de solicitud desconocido: %', _tipo;
  END IF;

  v_area := public.area_que_aprueba(_objeto);
  INSERT INTO public.solicitudes_aprobacion (tipo, objeto, parametros, area, descripcion, motivo, solicitado_por)
  VALUES (_tipo, _objeto, _parametros, v_area, _descripcion, trim(_motivo), auth.uid())
  RETURNING id INTO v_id;

  INSERT INTO public.bitacora_super_admin (usuario_id, tabla, operacion, registro_id, datos_despues)
  VALUES (auth.uid(), 'solicitudes_aprobacion', 'SOLICITAR', v_id::text,
          jsonb_build_object('tipo', _tipo, 'objeto', _objeto, 'parametros', _parametros, 'motivo', _motivo));
  RETURN v_id;
END
$$;
REVOKE ALL ON FUNCTION public.solicitar_aprobacion(text, text, jsonb, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.solicitar_aprobacion(text, text, jsonb, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.resolver_solicitud_aprobacion(_id uuid, _aprobar boolean, _comentario text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  s       public.solicitudes_aprobacion%ROWTYPE;
  v_where text;
  v_args  text;
  v_n     integer;
BEGIN
  SELECT * INTO s FROM public.solicitudes_aprobacion WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'La solicitud no existe.'; END IF;
  IF s.estado <> 'pendiente' THEN RAISE EXCEPTION 'La solicitud ya fue resuelta.'; END IF;
  IF NOT public.es_admin_de_area(s.area, auth.uid()) OR public.es_super_admin(auth.uid())
     OR s.solicitado_por = auth.uid() THEN
    RAISE EXCEPTION 'Sólo el administrador del área puede resolver esta solicitud.' USING ERRCODE = '42501';
  END IF;

  IF NOT _aprobar THEN
    UPDATE public.solicitudes_aprobacion
       SET estado = 'rechazada', resuelto_por = auth.uid(), resuelto_en = now(), comentario = _comentario
     WHERE id = _id;
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
  RETURN 'aprobada';
END
$$;
REVOKE ALL ON FUNCTION public.resolver_solicitud_aprobacion(uuid, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resolver_solicitud_aprobacion(uuid, boolean, text) TO authenticated;

-- Verificación: cuántas tablas quedaron vigiladas (debe ser > 0).
SELECT count(*) AS tablas_vigiladas FROM pg_trigger WHERE tgname = 'trg_vigilar_super_admin';

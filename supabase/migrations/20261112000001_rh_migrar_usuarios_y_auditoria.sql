-- ============================================================================
-- RH — Migrar usuarios a trabajadores y registro de cambios
-- Fecha: 2026-11-12 (continúa 20261111000002)
--
-- 1. Desde Usuarios se marca quién es TAMBIÉN trabajador y entra al módulo RH
--    (se crea su ficha). RH puede migrar varios a la vez. Ya no se migra a
--    todos por omisión.
-- 2. RH puede agregar documentos y corregir información. Todo cambio queda
--    registrado: quién, qué, cuándo, antes/después y motivo.
--      · `rh_bitacora_cambios`: historial detallado, solo lo lee RH.
--      · `bitacora_eventos` (la bitácora de Sistema): un renglón por cambio, como
--        los demás módulos. Los datos personales (RFC, CURP, NSS, CLABE…) se
--        registran SOLO como nombres de campos cambiados, nunca sus valores.
-- Idempotente.
-- ============================================================================

-- ── 1. Quién puede gestionar a un usuario como trabajador ───────────────────
-- RH, o el admin del área del usuario (el mismo que lo administra en Usuarios).
CREATE OR REPLACE FUNCTION public.rh_puede_gestionar_trabajador(_user UUID)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.usuario_activo(auth.uid()) AND (
    public.rh_es_rh()
    OR public.es_admin_area(auth.uid(), (SELECT ur.area FROM public.user_roles ur WHERE ur.user_id = _user LIMIT 1))
  )
$$;

-- Usuarios que ya son trabajadores (solo los que el llamador puede gestionar).
CREATE OR REPLACE FUNCTION public.rh_usuarios_trabajadores()
RETURNS TABLE (user_id UUID, empleado_id UUID, estatus TEXT)
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT e.user_id, e.id, e.estatus
    FROM public.rh_empleados e
   WHERE e.user_id IS NOT NULL AND public.rh_puede_gestionar_trabajador(e.user_id)
$$;

-- Usuarios que todavía no tienen ficha (para migrarlos). Solo RH.
CREATE OR REPLACE FUNCTION public.rh_usuarios_sin_ficha()
RETURNS TABLE (user_id UUID, nombre TEXT, correo TEXT, area TEXT, nivel TEXT, activo BOOLEAN)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.rh_es_rh() THEN RAISE EXCEPTION 'Solo RH puede ver los usuarios sin ficha.'; END IF;
  RETURN QUERY
  SELECT p.id,
         coalesce(nullif(btrim(p.nombre_completo), ''), split_part(coalesce(u.email, ''), '@', 1)),
         u.email::text, r.area::text, r.nivel::text, (p.activo IS NOT FALSE)
    FROM public.profiles p
    JOIN auth.users u ON u.id = p.id
    LEFT JOIN LATERAL (SELECT ur.area, ur.nivel FROM public.user_roles ur WHERE ur.user_id = p.id LIMIT 1) r ON true
   WHERE NOT EXISTS (SELECT 1 FROM public.rh_empleados e WHERE e.user_id = p.id)
   ORDER BY 2;
END $$;

-- Marca a un usuario como trabajador: crea su ficha (o devuelve la que ya tiene).
CREATE OR REPLACE FUNCTION public.rh_alta_trabajador(_user UUID)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE emp UUID;
BEGIN
  IF NOT public.rh_puede_gestionar_trabajador(_user) THEN RAISE EXCEPTION 'Sin permiso para marcar a este usuario como trabajador.'; END IF;
  SELECT id INTO emp FROM public.rh_empleados WHERE user_id = _user;
  IF emp IS NOT NULL THEN RETURN emp; END IF;
  INSERT INTO public.rh_empleados (user_id, nombre, correo, area_id, estatus)
  SELECT p.id,
         coalesce(nullif(btrim(p.nombre_completo), ''), split_part(coalesce(u.email, ''), '@', 1), 'Sin nombre'),
         u.email,
         (SELECT a.id FROM public.rh_areas a WHERE a.user_area = r.area LIMIT 1),
         CASE WHEN p.activo IS FALSE THEN 'baja' ELSE 'activo' END
    FROM public.profiles p
    JOIN auth.users u ON u.id = p.id
    LEFT JOIN LATERAL (SELECT ur.area FROM public.user_roles ur WHERE ur.user_id = p.id LIMIT 1) r ON true
   WHERE p.id = _user
  RETURNING id INTO emp;
  IF emp IS NULL THEN RAISE EXCEPTION 'Usuario no encontrado.'; END IF;
  RETURN emp;
END $$;

-- Migra varios usuarios a la vez. Solo RH.
CREATE OR REPLACE FUNCTION public.rh_alta_trabajadores(_users UUID[])
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u UUID; n INTEGER := 0;
BEGIN
  IF NOT public.rh_es_rh() THEN RAISE EXCEPTION 'Solo RH migra usuarios en bloque.'; END IF;
  FOREACH u IN ARRAY coalesce(_users, '{}'::uuid[]) LOOP
    IF NOT EXISTS (SELECT 1 FROM public.rh_empleados WHERE user_id = u) THEN
      PERFORM public.rh_alta_trabajador(u);
      n := n + 1;
    END IF;
  END LOOP;
  RETURN n;
END $$;

-- Quita la marca. Solo si la ficha está vacía; si ya tiene información se da de BAJA en RH.
CREATE OR REPLACE FUNCTION public.rh_quitar_trabajador(_user UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE emp UUID;
BEGIN
  IF NOT public.rh_puede_gestionar_trabajador(_user) THEN RAISE EXCEPTION 'Sin permiso.'; END IF;
  SELECT id INTO emp FROM public.rh_empleados WHERE user_id = _user;
  IF emp IS NULL THEN RETURN; END IF;
  IF EXISTS (SELECT 1 FROM public.rh_empleado_datos WHERE empleado_id = emp)
     OR EXISTS (SELECT 1 FROM public.rh_documentos WHERE empleado_id = emp)
     OR EXISTS (SELECT 1 FROM public.rh_asistencia WHERE empleado_id = emp)
     OR EXISTS (SELECT 1 FROM public.rh_solicitudes WHERE empleado_id = emp)
     OR EXISTS (SELECT 1 FROM public.rh_contratos WHERE empleado_id = emp)
     OR EXISTS (SELECT 1 FROM public.rh_horarios WHERE empleado_id = emp)
     OR EXISTS (SELECT 1 FROM public.rh_biblioteca_lecturas WHERE empleado_id = emp)
     OR EXISTS (SELECT 1 FROM public.rh_avisos_aceptaciones WHERE empleado_id = emp)
     OR EXISTS (SELECT 1 FROM public.rh_empleados WHERE reporta_a = emp) THEN
    RAISE EXCEPTION 'Este trabajador ya tiene información registrada (documentos, asistencia, horario…). Para dejarlo de contar, dalo de baja desde Recursos Humanos.';
  END IF;
  DELETE FROM public.rh_empleados WHERE id = emp;
END $$;

-- ── 2. Registro de cambios ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.rh_bitacora_cambios (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id  UUID REFERENCES auth.users(id),
  empleado_id UUID,                       -- sin FK: el historial sobrevive aunque se quite la ficha
  tabla       TEXT NOT NULL,
  registro_id TEXT,
  accion      TEXT NOT NULL CHECK (accion IN ('alta', 'cambio', 'baja')),
  campos      TEXT[],
  antes       JSONB,
  despues     JSONB,
  motivo      TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_rh_bitacora_cambios_emp ON public.rh_bitacora_cambios (empleado_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_rh_bitacora_cambios_fecha ON public.rh_bitacora_cambios (created_at DESC);
ALTER TABLE public.rh_bitacora_cambios ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "rh_bitacora_cambios_select" ON public.rh_bitacora_cambios;
CREATE POLICY "rh_bitacora_cambios_select" ON public.rh_bitacora_cambios FOR SELECT TO authenticated
  USING (public.rh_es_rh());
GRANT SELECT ON public.rh_bitacora_cambios TO authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.rh_bitacora_cambios FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.rh_bitacora_cambios FROM anon;

-- Trigger genérico: registra el alta, el cambio (solo columnas que cambiaron) y la baja.
CREATE OR REPLACE FUNCTION public.rh_auditar() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  viejo JSONB; nuevo JSONB; fila JSONB; k TEXT;
  cambiadas TEXT[] := '{}'; antes JSONB := '{}'; despues JSONB := '{}';
  accion TEXT; emp UUID; reg TEXT;
  sensible BOOLEAN := (TG_TABLE_NAME = 'rh_empleado_datos');
  motivo TEXT := nullif(btrim(coalesce(current_setting('rh.motivo', true), '')), '');
  ruido TEXT[] := ARRAY['updated_at', 'created_at'];
BEGIN
  IF TG_OP = 'INSERT' THEN accion := 'alta'; fila := to_jsonb(NEW);
  ELSIF TG_OP = 'DELETE' THEN accion := 'baja'; fila := to_jsonb(OLD);
  ELSE accion := 'cambio'; fila := to_jsonb(NEW); viejo := to_jsonb(OLD); nuevo := to_jsonb(NEW); END IF;

  emp := CASE WHEN TG_TABLE_NAME = 'rh_empleados' THEN (fila->>'id')::uuid ELSE (fila->>'empleado_id')::uuid END;
  reg := coalesce(fila->>'id', fila->>'empleado_id', fila->>'periodo');

  IF TG_OP = 'UPDATE' THEN
    FOR k IN SELECT jsonb_object_keys(nuevo) LOOP
      IF k = ANY (ruido) THEN CONTINUE; END IF;
      IF nuevo->k IS DISTINCT FROM viejo->k THEN
        cambiadas := cambiadas || k; antes := antes || jsonb_build_object(k, viejo->k); despues := despues || jsonb_build_object(k, nuevo->k);
      END IF;
    END LOOP;
    IF cardinality(cambiadas) = 0 THEN RETURN NEW; END IF;   -- sin cambio real, no se registra
  ELSE
    SELECT coalesce(array_agg(x), '{}') INTO cambiadas FROM jsonb_object_keys(fila) x WHERE x <> ALL (ruido);
    IF TG_OP = 'INSERT' THEN despues := fila - ruido; ELSE antes := fila - ruido; END IF;
  END IF;

  IF sensible THEN antes := NULL; despues := NULL; END IF;   -- RFC, CURP, NSS, CLABE: nunca los valores

  INSERT INTO public.rh_bitacora_cambios (usuario_id, empleado_id, tabla, registro_id, accion, campos, antes, despues, motivo)
  VALUES (auth.uid(), emp, TG_TABLE_NAME, reg, accion, cambiadas, antes, despues, motivo);

  -- La bitácora general de Sistema, como los demás módulos.
  INSERT INTO public.bitacora_eventos (usuario_id, modulo, accion, entidad_tipo, entidad_id, datos_antes, datos_despues)
  VALUES (auth.uid(), 'rh', TG_TABLE_NAME || '.' || accion, TG_TABLE_NAME,
          CASE WHEN reg ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN reg::uuid ELSE emp END,
          CASE WHEN sensible THEN jsonb_build_object('campos', to_jsonb(cambiadas)) ELSE antes END,
          CASE WHEN sensible THEN jsonb_build_object('campos', to_jsonb(cambiadas), 'motivo', motivo)
               ELSE CASE WHEN motivo IS NULL THEN despues ELSE coalesce(despues, '{}'::jsonb) || jsonb_build_object('_motivo', motivo) END END);

  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;

DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['rh_empleados', 'rh_empleado_datos', 'rh_documentos', 'rh_horarios', 'rh_contratos', 'rh_vacaciones_saldos'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_rh_auditar ON public.%I', t);
    EXECUTE format('CREATE TRIGGER trg_rh_auditar AFTER INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.rh_auditar()', t);
  END LOOP;
END $$;

-- ── 3. Correcciones de RH con motivo (y registro) ───────────────────────────
-- Datos personales de otra persona: solo RH, con motivo de 10+ caracteres.
CREATE OR REPLACE FUNCTION public.rh_guardar_datos(_empleado UUID, _datos JSONB, _motivo TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE actual JSONB; mezcla JSONB; r public.rh_empleado_datos;
  permitidas TEXT[] := ARRAY['rfc','curp','nss','clabe','banco','fecha_nacimiento','domicilio','codigo_postal','contacto_emergencia','telefono_emergencia'];
BEGIN
  IF NOT public.rh_es_rh() THEN RAISE EXCEPTION 'Solo RH corrige datos personales de otra persona.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rh_empleados WHERE id = _empleado) THEN RAISE EXCEPTION 'Colaborador no encontrado.'; END IF;
  IF length(btrim(coalesce(_motivo, ''))) < 10 THEN RAISE EXCEPTION 'Explica el motivo de la corrección (mínimo 10 caracteres).'; END IF;
  PERFORM set_config('rh.motivo', btrim(_motivo), true);
  SELECT coalesce(to_jsonb(d), jsonb_build_object('empleado_id', _empleado)) INTO actual
    FROM (SELECT 1) x LEFT JOIN public.rh_empleado_datos d ON d.empleado_id = _empleado;
  SELECT coalesce(jsonb_object_agg(key, value), '{}') INTO mezcla FROM jsonb_each(_datos) WHERE key = ANY (permitidas);
  r := jsonb_populate_record(NULL::public.rh_empleado_datos, actual || mezcla || jsonb_build_object('empleado_id', _empleado));
  INSERT INTO public.rh_empleado_datos (empleado_id, rfc, curp, nss, clabe, banco, fecha_nacimiento, domicilio, codigo_postal, contacto_emergencia, telefono_emergencia)
  VALUES (r.empleado_id, r.rfc, r.curp, r.nss, r.clabe, r.banco, r.fecha_nacimiento, r.domicilio, r.codigo_postal, r.contacto_emergencia, r.telefono_emergencia)
  ON CONFLICT (empleado_id) DO UPDATE SET
    rfc = EXCLUDED.rfc, curp = EXCLUDED.curp, nss = EXCLUDED.nss, clabe = EXCLUDED.clabe, banco = EXCLUDED.banco,
    fecha_nacimiento = EXCLUDED.fecha_nacimiento, domicilio = EXCLUDED.domicilio, codigo_postal = EXCLUDED.codigo_postal,
    contacto_emergencia = EXCLUDED.contacto_emergencia, telefono_emergencia = EXCLUDED.telefono_emergencia;
END $$;

-- Ficha del trabajador. El motivo es opcional (todo se registra igual), pero
-- obligatorio para dar de baja.
CREATE OR REPLACE FUNCTION public.rh_actualizar_empleado(_id UUID, _cambios JSONB, _motivo TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE e public.rh_empleados; mezcla JSONB; r public.rh_empleados;
  permitidas TEXT[] := ARRAY['numero_empleado','nombre','correo','telefono','area_id','puesto_id','reporta_a','fecha_ingreso','fecha_baja','motivo_baja','estatus','nivel_acceso'];
BEGIN
  IF NOT public.rh_es_rh() THEN RAISE EXCEPTION 'Solo RH corrige la ficha.'; END IF;
  SELECT * INTO e FROM public.rh_empleados WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Colaborador no encontrado.'; END IF;
  SELECT coalesce(jsonb_object_agg(key, value), '{}') INTO mezcla FROM jsonb_each(_cambios) WHERE key = ANY (permitidas);
  IF mezcla ->> 'estatus' = 'baja' AND e.estatus <> 'baja' AND length(btrim(coalesce(_motivo, mezcla ->> 'motivo_baja', ''))) < 10 THEN
    RAISE EXCEPTION 'Para dar de baja explica el motivo (mínimo 10 caracteres).';
  END IF;
  IF _motivo IS NOT NULL AND btrim(_motivo) <> '' THEN PERFORM set_config('rh.motivo', btrim(_motivo), true); END IF;
  r := jsonb_populate_record(NULL::public.rh_empleados, to_jsonb(e) || mezcla);
  UPDATE public.rh_empleados SET
    numero_empleado = r.numero_empleado, nombre = r.nombre, correo = r.correo, telefono = r.telefono,
    area_id = r.area_id, puesto_id = r.puesto_id, reporta_a = r.reporta_a, fecha_ingreso = r.fecha_ingreso,
    fecha_baja = r.fecha_baja, motivo_baja = r.motivo_baja, estatus = r.estatus, nivel_acceso = r.nivel_acceso
  WHERE id = _id;
END $$;

-- RH quita un documento del expediente: motivo obligatorio. Devuelve la ruta para borrar el archivo.
CREATE OR REPLACE FUNCTION public.rh_eliminar_documento(_id UUID, _motivo TEXT)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE d public.rh_documentos;
BEGIN
  IF NOT public.rh_es_rh() THEN RAISE EXCEPTION 'Solo RH quita documentos de otra persona.'; END IF;
  IF length(btrim(coalesce(_motivo, ''))) < 10 THEN RAISE EXCEPTION 'Explica el motivo (mínimo 10 caracteres).'; END IF;
  SELECT * INTO d FROM public.rh_documentos WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Documento no encontrado.'; END IF;
  PERFORM set_config('rh.motivo', btrim(_motivo), true);
  DELETE FROM public.rh_documentos WHERE id = _id;
  RETURN d.ruta;
END $$;

-- Privilegios.
DO $$
DECLARE f TEXT;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'rh_puede_gestionar_trabajador(uuid)', 'rh_usuarios_trabajadores()', 'rh_usuarios_sin_ficha()',
    'rh_alta_trabajador(uuid)', 'rh_alta_trabajadores(uuid[])', 'rh_quitar_trabajador(uuid)', 'rh_auditar()',
    'rh_guardar_datos(uuid,jsonb,text)', 'rh_actualizar_empleado(uuid,jsonb,text)', 'rh_eliminar_documento(uuid,text)'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon', f);
    IF f <> 'rh_auditar()' THEN EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', f); END IF;
  END LOOP;
END $$;

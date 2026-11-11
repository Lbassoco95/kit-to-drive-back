-- ============================================================================
-- RH — Aviso de privacidad, jornadas sin salida y contratos
-- Fecha: 2026-11-11 (continúa 20261111000001_rh_modulo_base)
--
-- 1. Aviso de privacidad versionado. El TEXTO lo carga RH cuando jurídico lo
--    entregue (queda como pendiente visible). Una vez publicado, el colaborador
--    debe aceptarlo ANTES de capturar datos personales o subir documentos.
-- 2. Jornada sin salida: pasado el máximo de horas se cierra sola como
--    «sin salida» y cuenta como FALTA (configurable). RH o el jefe la corrigen
--    con motivo (justificación) y deja de contar.
-- 3. Contratos: el contrato se firma en WeTrust (fuera del sistema); aquí se
--    registra el envío y se sube el firmado. Hasta que está firmado y subido
--    NO se mandan accesos: la persona nace «por ingresar», sin usuario.
-- Idempotente.
-- ============================================================================

-- ── 1. Aviso de privacidad ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.rh_avisos_privacidad (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  version             INTEGER NOT NULL UNIQUE,
  titulo              TEXT NOT NULL,
  texto               TEXT NOT NULL,
  plazo_conservacion  TEXT,
  vigente             BOOLEAN NOT NULL DEFAULT false,
  publicado_por       UUID REFERENCES auth.users(id),
  publicado_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_rh_aviso_vigente ON public.rh_avisos_privacidad ((true)) WHERE vigente;

CREATE TABLE IF NOT EXISTS public.rh_avisos_aceptaciones (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  empleado_id UUID NOT NULL REFERENCES public.rh_empleados(id) ON DELETE CASCADE,
  aviso_id    UUID NOT NULL REFERENCES public.rh_avisos_privacidad(id),
  aceptado_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (empleado_id, aviso_id)
);
ALTER TABLE public.rh_avisos_privacidad ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rh_avisos_aceptaciones ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "rh_avisos_privacidad_select" ON public.rh_avisos_privacidad;
CREATE POLICY "rh_avisos_privacidad_select" ON public.rh_avisos_privacidad FOR SELECT TO authenticated
  USING (public.usuario_activo(auth.uid()));
DROP POLICY IF EXISTS "rh_avisos_aceptaciones_select" ON public.rh_avisos_aceptaciones;
CREATE POLICY "rh_avisos_aceptaciones_select" ON public.rh_avisos_aceptaciones FOR SELECT TO authenticated
  USING (public.rh_es_rh() OR public.rh_es_yo(empleado_id));
GRANT SELECT ON public.rh_avisos_privacidad, public.rh_avisos_aceptaciones TO authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.rh_avisos_privacidad, public.rh_avisos_aceptaciones FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.rh_avisos_privacidad, public.rh_avisos_aceptaciones FROM anon;

-- Sin aviso vigente no se bloquea a nadie (queda como pendiente para RH); con
-- aviso vigente, hay que haberlo aceptado.
CREATE OR REPLACE FUNCTION public.rh_aviso_ok(_empleado UUID)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT NOT EXISTS (SELECT 1 FROM public.rh_avisos_privacidad WHERE vigente)
      OR EXISTS (SELECT 1 FROM public.rh_avisos_privacidad a
                  JOIN public.rh_avisos_aceptaciones x ON x.aviso_id = a.id
                 WHERE a.vigente AND x.empleado_id = _empleado)
$$;

CREATE OR REPLACE FUNCTION public.rh_publicar_aviso(_titulo TEXT, _texto TEXT, _plazo TEXT DEFAULT NULL)
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v INTEGER;
BEGIN
  IF NOT public.rh_es_rh() THEN RAISE EXCEPTION 'Solo RH publica el aviso de privacidad.'; END IF;
  IF length(btrim(coalesce(_texto, ''))) < 100 THEN RAISE EXCEPTION 'El texto del aviso es demasiado corto (mínimo 100 caracteres).'; END IF;
  IF length(btrim(coalesce(_titulo, ''))) = 0 THEN RAISE EXCEPTION 'Falta el título del aviso.'; END IF;
  SELECT coalesce(max(version), 0) + 1 INTO v FROM public.rh_avisos_privacidad;
  UPDATE public.rh_avisos_privacidad SET vigente = false WHERE vigente;
  INSERT INTO public.rh_avisos_privacidad (version, titulo, texto, plazo_conservacion, vigente, publicado_por)
  VALUES (v, btrim(_titulo), btrim(_texto), nullif(btrim(coalesce(_plazo, '')), ''), true, auth.uid());
  RETURN v;
END $$;

CREATE OR REPLACE FUNCTION public.rh_aceptar_aviso()
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE emp UUID := public.rh_mi_empleado_id(); aviso UUID;
BEGIN
  IF emp IS NULL OR NOT public.usuario_activo(auth.uid()) THEN RAISE EXCEPTION 'No tienes ficha de colaborador activa.'; END IF;
  SELECT id INTO aviso FROM public.rh_avisos_privacidad WHERE vigente;
  IF aviso IS NULL THEN RAISE EXCEPTION 'Todavía no hay un aviso de privacidad publicado.'; END IF;
  INSERT INTO public.rh_avisos_aceptaciones (empleado_id, aviso_id) VALUES (emp, aviso) ON CONFLICT DO NOTHING;
END $$;

-- Quien captura datos personales o sube documentos ya aceptó el aviso vigente.
DROP POLICY IF EXISTS "rh_empleado_datos_dueno" ON public.rh_empleado_datos;
CREATE POLICY "rh_empleado_datos_dueno" ON public.rh_empleado_datos FOR ALL TO authenticated
  USING (public.rh_es_yo(empleado_id))
  WITH CHECK (public.rh_es_yo(empleado_id) AND public.rh_aviso_ok(empleado_id));
DROP POLICY IF EXISTS "rh_documentos_dueno_insert" ON public.rh_documentos;
CREATE POLICY "rh_documentos_dueno_insert" ON public.rh_documentos FOR INSERT TO authenticated
  WITH CHECK (public.rh_es_yo(empleado_id) AND estatus = 'subido' AND public.rh_aviso_ok(empleado_id));

-- ── 2. Jornada sin salida ───────────────────────────────────────────────────
ALTER TABLE public.rh_asistencia ADD COLUMN IF NOT EXISTS sin_salida BOOLEAN NOT NULL DEFAULT false;
DROP INDEX IF EXISTS public.uq_rh_asistencia_abierta;
CREATE UNIQUE INDEX uq_rh_asistencia_abierta ON public.rh_asistencia (empleado_id) WHERE salida_at IS NULL AND NOT sin_salida;

INSERT INTO public.rh_parametros (clave, valor, descripcion) VALUES
  ('jornada_max_horas',   '14',   'Horas después de la entrada en que una jornada sin salida se cierra sola como «sin salida»'),
  ('sin_salida_es_falta', 'true', 'Una jornada sin salida cuenta como falta hasta que RH o el jefe la corrijan (true/false)')
ON CONFLICT (clave) DO NOTHING;

-- Cierra las jornadas que pasaron el máximo. Idempotente; sin argumentos: solo
-- depende de la hora, así que puede llamarla cualquier usuario con sesión.
CREATE OR REPLACE FUNCTION public.rh_cerrar_jornadas_vencidas()
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n INTEGER; horas NUMERIC := coalesce(nullif(public.rh_parametro('jornada_max_horas', '14'), '')::numeric, 14);
BEGIN
  WITH c AS (
    UPDATE public.rh_asistencia SET sin_salida = true
     WHERE salida_at IS NULL AND NOT sin_salida AND now() - entrada_at > make_interval(hours => horas::int)
    RETURNING 1)
  SELECT count(*) INTO n FROM c;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION public.rh_marcar_entrada(_modo TEXT DEFAULT 'oficina', _lat DOUBLE PRECISION DEFAULT NULL, _lng DOUBLE PRECISION DEFAULT NULL, _precision DOUBLE PRECISION DEFAULT NULL)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  emp UUID := public.rh_mi_empleado_id();
  tz TEXT := public.rh_parametro('zona_horaria', 'America/Mexico_City');
  ahora TIMESTAMPTZ := now();
  local_ts TIMESTAMP := now() AT TIME ZONE tz;
  h RECORD; ret INTEGER := 0; tol INTEGER; res RECORD; nuevo UUID;
BEGIN
  IF emp IS NULL OR NOT public.usuario_activo(auth.uid()) THEN RAISE EXCEPTION 'No tienes ficha de colaborador activa.'; END IF;
  IF _modo NOT IN ('oficina', 'remoto', 'comision') THEN RAISE EXCEPTION 'Modo no válido.'; END IF;
  PERFORM public.rh_cerrar_jornadas_vencidas();
  IF EXISTS (SELECT 1 FROM public.rh_asistencia WHERE empleado_id = emp AND salida_at IS NULL AND NOT sin_salida) THEN
    RAISE EXCEPTION 'Ya tienes una jornada abierta. Registra tu salida primero.';
  END IF;

  SELECT * INTO h FROM public.rh_horarios
   WHERE empleado_id = emp AND vigente_desde <= local_ts::date AND (vigente_hasta IS NULL OR vigente_hasta >= local_ts::date)
     AND extract(isodow FROM local_ts)::int = ANY (dias)
   ORDER BY vigente_desde DESC LIMIT 1;
  IF FOUND THEN
    tol := coalesce(h.tolerancia_min, public.rh_parametro('tolerancia_min', '10')::int);
    ret := greatest(0, floor(extract(epoch FROM (local_ts::time - h.hora_entrada)) / 60)::int - tol);
    IF local_ts::time < h.hora_entrada THEN ret := 0; END IF;
  END IF;

  SELECT * INTO res FROM public.rh_resultado_ubicacion(_modo, _lat, _lng, _precision);
  INSERT INTO public.rh_asistencia (empleado_id, fecha, modo, entrada_at, entrada_resultado, entrada_oficina_id, retardo_min)
  VALUES (emp, local_ts::date, _modo, ahora, res.resultado, res.oficina, ret) RETURNING id INTO nuevo;
  IF _lat IS NOT NULL AND _lng IS NOT NULL AND _modo = 'oficina' THEN
    INSERT INTO public.rh_asistencia_ubicacion (asistencia_id, empleado_id, momento, lat, lng, precision_m)
    VALUES (nuevo, emp, 'entrada', round(_lat::numeric, 3), round(_lng::numeric, 3), round(_precision)::int);
  END IF;
  RETURN nuevo;
END $$;

CREATE OR REPLACE FUNCTION public.rh_marcar_salida(_lat DOUBLE PRECISION DEFAULT NULL, _lng DOUBLE PRECISION DEFAULT NULL, _precision DOUBLE PRECISION DEFAULT NULL)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE emp UUID := public.rh_mi_empleado_id(); a RECORD; res RECORD;
BEGIN
  IF emp IS NULL OR NOT public.usuario_activo(auth.uid()) THEN RAISE EXCEPTION 'No tienes ficha de colaborador activa.'; END IF;
  PERFORM public.rh_cerrar_jornadas_vencidas();
  SELECT * INTO a FROM public.rh_asistencia WHERE empleado_id = emp AND salida_at IS NULL AND NOT sin_salida FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No tienes una jornada abierta. Si tu jornada anterior quedó sin salida, pide a tu jefe o a RH que la corrijan.'; END IF;
  SELECT * INTO res FROM public.rh_resultado_ubicacion(a.modo, _lat, _lng, _precision);
  UPDATE public.rh_asistencia SET salida_at = now(), salida_resultado = res.resultado WHERE id = a.id;
  IF _lat IS NOT NULL AND _lng IS NOT NULL AND a.modo = 'oficina' THEN
    INSERT INTO public.rh_asistencia_ubicacion (asistencia_id, empleado_id, momento, lat, lng, precision_m)
    VALUES (a.id, emp, 'salida', round(_lat::numeric, 3), round(_lng::numeric, 3), round(_precision)::int);
  END IF;
  RETURN a.id;
END $$;

-- Corregir deja de contar la jornada como «sin salida» si se le pone salida.
CREATE OR REPLACE FUNCTION public.rh_corregir_asistencia(_id UUID, _entrada TIMESTAMPTZ, _salida TIMESTAMPTZ, _motivo TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a RECORD;
BEGIN
  SELECT * INTO a FROM public.rh_asistencia WHERE id = _id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Registro no encontrado.'; END IF;
  IF NOT (public.rh_es_rh() OR public.rh_es_jefe_de(a.empleado_id)) THEN RAISE EXCEPTION 'Sin permiso.'; END IF;
  IF public.rh_es_yo(a.empleado_id) AND NOT public.rh_es_rh() THEN RAISE EXCEPTION 'No puedes corregir tu propio registro.'; END IF;
  IF length(btrim(coalesce(_motivo, ''))) < 10 THEN RAISE EXCEPTION 'El motivo debe tener al menos 10 caracteres.'; END IF;
  INSERT INTO public.rh_asistencia_correcciones (asistencia_id, corregido_por, entrada_antes, salida_antes, entrada_nueva, salida_nueva, motivo)
  VALUES (_id, auth.uid(), a.entrada_at, a.salida_at, coalesce(_entrada, a.entrada_at), coalesce(_salida, a.salida_at), btrim(_motivo));
  UPDATE public.rh_asistencia
     SET entrada_at = coalesce(_entrada, entrada_at), salida_at = coalesce(_salida, salida_at), corregida = true,
         sin_salida = CASE WHEN _salida IS NOT NULL THEN false ELSE sin_salida END
   WHERE id = _id;
END $$;

-- Faltas: día de horario sin asistencia válida, sin solicitud aprobada y no inhábil.
-- Una jornada «sin salida» no es asistencia válida mientras `sin_salida_es_falta` sea true.
CREATE OR REPLACE FUNCTION public.rh_faltas(_empleado UUID, _desde DATE, _hasta DATE)
RETURNS TABLE (fecha DATE) LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  tz TEXT := public.rh_parametro('zona_horaria', 'America/Mexico_City');
  hoy DATE := (now() AT TIME ZONE tz)::date;
  sin_salida_falta BOOLEAN := lower(public.rh_parametro('sin_salida_es_falta', 'true')) IN ('true', 't', '1', 'si', 'sí');
BEGIN
  IF NOT (public.rh_es_rh() OR public.rh_es_yo(_empleado) OR public.rh_es_jefe_de(_empleado)) THEN
    RAISE EXCEPTION 'Sin permiso.';
  END IF;
  RETURN QUERY
  SELECT d::date
    FROM generate_series(_desde, least(_hasta, hoy - 1), interval '1 day') d
    JOIN LATERAL (SELECT h.dias FROM public.rh_horarios h
                   WHERE h.empleado_id = _empleado AND h.vigente_desde <= d::date
                     AND (h.vigente_hasta IS NULL OR h.vigente_hasta >= d::date)
                   ORDER BY h.vigente_desde DESC LIMIT 1) hh ON extract(isodow FROM d)::int = ANY (hh.dias)
   WHERE NOT EXISTS (SELECT 1 FROM public.rh_asistencia a
                      WHERE a.empleado_id = _empleado AND a.fecha = d::date AND (NOT a.sin_salida OR NOT sin_salida_falta))
     AND NOT EXISTS (SELECT 1 FROM public.rh_solicitudes s WHERE s.empleado_id = _empleado AND s.estatus = 'aprobada'
                      AND s.fecha_inicio <= d::date AND s.fecha_fin >= d::date)
     AND NOT EXISTS (SELECT 1 FROM public.rh_dias_inhabiles i WHERE i.fecha = d::date)
     AND d::date >= coalesce((SELECT e.fecha_ingreso FROM public.rh_empleados e WHERE e.id = _empleado), d::date)
   ORDER BY 1;
END $$;

-- Cierre automático cada hora si la base tiene pg_cron; si no, se cierra al
-- marcar y cuando la app lo pide (no depende del cron).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'rh_cerrar_jornadas_vencidas') THEN
      PERFORM cron.schedule('rh_cerrar_jornadas_vencidas', '7 * * * *', 'SELECT public.rh_cerrar_jornadas_vencidas()');
    END IF;
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron no disponible (%); las jornadas se cierran al marcar y al abrir RH.', SQLERRM;
END $$;

-- ── 3. Contratos (WeTrust) y alta por ingresar ──────────────────────────────
ALTER TABLE public.rh_empleados ALTER COLUMN user_id DROP NOT NULL;
ALTER TABLE public.rh_empleados DROP CONSTRAINT IF EXISTS rh_empleados_estatus_check;
ALTER TABLE public.rh_empleados ADD CONSTRAINT rh_empleados_estatus_check
  CHECK (estatus IN ('por_ingresar', 'activo', 'licencia', 'baja'));
ALTER TABLE public.rh_empleados ADD COLUMN IF NOT EXISTS nivel_acceso public.user_nivel NOT NULL DEFAULT 'operador';
ALTER TABLE public.rh_empleados DROP CONSTRAINT IF EXISTS rh_empleados_nivel_acceso_check;
ALTER TABLE public.rh_empleados ADD CONSTRAINT rh_empleados_nivel_acceso_check CHECK (nivel_acceso IN ('operador', 'supervisor'));
ALTER TABLE public.rh_empleados DROP CONSTRAINT IF EXISTS rh_empleados_usuario_o_por_ingresar;
ALTER TABLE public.rh_empleados ADD CONSTRAINT rh_empleados_usuario_o_por_ingresar CHECK (user_id IS NOT NULL OR estatus = 'por_ingresar');

CREATE TABLE IF NOT EXISTS public.rh_contratos (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  empleado_id        UUID NOT NULL REFERENCES public.rh_empleados(id) ON DELETE CASCADE,
  proveedor          TEXT NOT NULL DEFAULT 'weetrust',
  referencia_externa TEXT,                       -- folio / id del documento en WeTrust
  estatus            TEXT NOT NULL DEFAULT 'enviado' CHECK (estatus IN ('enviado', 'firmado', 'cancelado')),
  enviado_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  firmado_at         TIMESTAMPTZ,
  ruta               TEXT,
  nombre_archivo     TEXT,
  accesos_enviados_at TIMESTAMPTZ,
  creado_por         UUID REFERENCES auth.users(id),
  CHECK (estatus <> 'firmado' OR ruta IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS idx_rh_contratos_empleado ON public.rh_contratos (empleado_id, enviado_at DESC);
ALTER TABLE public.rh_contratos ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "rh_contratos_select" ON public.rh_contratos;
CREATE POLICY "rh_contratos_select" ON public.rh_contratos FOR SELECT TO authenticated
  USING (public.rh_es_rh() OR public.rh_es_yo(empleado_id));
GRANT SELECT ON public.rh_contratos TO authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.rh_contratos FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.rh_contratos FROM anon;

INSERT INTO public.rh_tipos_documento (clave, nombre, ayuda, orden)
VALUES ('contrato', 'Contrato firmado', 'Contrato individual de trabajo firmado en WeTrust', 0)
ON CONFLICT (clave) DO NOTHING;

-- Marca que el contrato se mandó a firma en WeTrust.
CREATE OR REPLACE FUNCTION public.rh_contrato_enviado(_empleado UUID, _referencia TEXT DEFAULT NULL)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE nuevo UUID;
BEGIN
  IF NOT public.rh_es_rh() THEN RAISE EXCEPTION 'Solo RH registra contratos.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rh_empleados WHERE id = _empleado) THEN RAISE EXCEPTION 'Colaborador no encontrado.'; END IF;
  UPDATE public.rh_contratos SET estatus = 'cancelado' WHERE empleado_id = _empleado AND estatus = 'enviado';
  INSERT INTO public.rh_contratos (empleado_id, referencia_externa, creado_por)
  VALUES (_empleado, nullif(btrim(coalesce(_referencia, '')), ''), auth.uid()) RETURNING id INTO nuevo;
  RETURN nuevo;
END $$;

-- Sube el contrato firmado: queda en el contrato, en el expediente (verificado) y
-- habilita mandar accesos.
CREATE OR REPLACE FUNCTION public.rh_contrato_firmado(_empleado UUID, _ruta TEXT, _nombre TEXT, _referencia TEXT DEFAULT NULL, _firmado_at TIMESTAMPTZ DEFAULT now())
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE c UUID; tipo UUID;
BEGIN
  IF NOT public.rh_es_rh() THEN RAISE EXCEPTION 'Solo RH sube contratos firmados.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rh_empleados WHERE id = _empleado) THEN RAISE EXCEPTION 'Colaborador no encontrado.'; END IF;
  IF _ruta IS NULL OR _ruta NOT LIKE _empleado::text || '/%' THEN RAISE EXCEPTION 'La ruta del archivo no corresponde al colaborador.'; END IF;
  SELECT id INTO c FROM public.rh_contratos WHERE empleado_id = _empleado AND estatus = 'enviado' ORDER BY enviado_at DESC LIMIT 1;
  IF c IS NULL THEN
    INSERT INTO public.rh_contratos (empleado_id, referencia_externa, creado_por)
    VALUES (_empleado, nullif(btrim(coalesce(_referencia, '')), ''), auth.uid()) RETURNING id INTO c;
  END IF;
  UPDATE public.rh_contratos
     SET estatus = 'firmado', firmado_at = coalesce(_firmado_at, now()), ruta = _ruta, nombre_archivo = _nombre,
         referencia_externa = coalesce(nullif(btrim(coalesce(_referencia, '')), ''), referencia_externa)
   WHERE id = c;
  SELECT id INTO tipo FROM public.rh_tipos_documento WHERE clave = 'contrato';
  IF tipo IS NOT NULL THEN
    INSERT INTO public.rh_documentos (empleado_id, tipo_id, ruta, nombre_archivo, estatus, verificado_por, verificado_at)
    VALUES (_empleado, tipo, _ruta, _nombre, 'verificado', auth.uid(), now());
  END IF;
  RETURN c;
END $$;

-- Liga al colaborador con el usuario recién creado (lo llama RH tras crear los
-- accesos). Exige contrato firmado.
CREATE OR REPLACE FUNCTION public.rh_vincular_usuario(_empleado UUID, _user UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE e RECORD;
BEGIN
  IF NOT public.rh_es_rh() THEN RAISE EXCEPTION 'Solo RH manda accesos.'; END IF;
  SELECT * INTO e FROM public.rh_empleados WHERE id = _empleado FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Colaborador no encontrado.'; END IF;
  IF e.user_id IS NOT NULL THEN RAISE EXCEPTION 'Este colaborador ya tiene usuario.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rh_contratos WHERE empleado_id = _empleado AND estatus = 'firmado') THEN
    RAISE EXCEPTION 'Primero sube el contrato firmado: sin él no se mandan accesos.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.rh_empleados WHERE user_id = _user) THEN RAISE EXCEPTION 'Ese usuario ya está ligado a otro colaborador.'; END IF;
  UPDATE public.rh_empleados
     SET user_id = _user, estatus = 'activo', fecha_ingreso = coalesce(fecha_ingreso, current_date)
   WHERE id = _empleado;
  UPDATE public.rh_contratos SET accesos_enviados_at = now()
   WHERE empleado_id = _empleado AND estatus = 'firmado';
END $$;

-- El directorio no muestra a quien aún no ingresa.
CREATE OR REPLACE VIEW public.v_rh_directorio AS
SELECT e.id, e.nombre, e.correo, a.nombre AS area, p.nombre AS puesto, e.reporta_a
  FROM public.rh_empleados e
  LEFT JOIN public.rh_areas a ON a.id = e.area_id
  LEFT JOIN public.rh_puestos p ON p.id = e.puesto_id
 WHERE e.estatus NOT IN ('baja', 'por_ingresar') AND public.usuario_activo(auth.uid());

-- Privilegios de las funciones nuevas.
DO $$
DECLARE f TEXT;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'rh_aviso_ok(uuid)', 'rh_publicar_aviso(text,text,text)', 'rh_aceptar_aviso()',
    'rh_cerrar_jornadas_vencidas()', 'rh_contrato_enviado(uuid,text)',
    'rh_contrato_firmado(uuid,text,text,text,timestamptz)', 'rh_vincular_usuario(uuid,uuid)',
    'rh_marcar_entrada(text,double precision,double precision,double precision)',
    'rh_marcar_salida(double precision,double precision,double precision)',
    'rh_corregir_asistencia(uuid,timestamptz,timestamptz,text)', 'rh_faltas(uuid,date,date)'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', f);
  END LOOP;
END $$;

-- ============================================================================
-- Recursos Humanos (RH) — base del módulo
-- Fecha: 2026-11-11
--
-- Plantilla por área y puesto, expediente digital, biblioteca (manuales y
-- políticas), tablero de publicaciones, checador con geolocalización,
-- solicitudes (permisos / vacaciones / incapacidades) y bitácora de accesos.
--
-- · Todo es catálogo en base de datos (áreas, puestos, tipos de documento,
--   tipos de solicitud, parámetros, categorías): nada fijo en el código.
-- · RH = un usuario de nivel admin al que se le da el rol adicional en
--   `rh_acceso` (o el admin global de Dirección).
-- · Toda la plantilla tiene usuario: `rh_empleados.user_id` es obligatorio.
-- · Un colaborador ve solo lo suyo. El jefe directo ve asistencia y
--   solicitudes de su equipo, NUNCA expedientes. El directorio general
--   (`v_rh_directorio`) solo expone nombre, puesto, área y correo.
-- · El checador fija la hora y valida la geocerca EN EL SERVIDOR; la
--   ubicación exacta solo la lee la propia persona.
-- Idempotente.
-- ============================================================================

-- ── 1. Rol adicional de RH ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.rh_acceso (
  user_id     UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  otorgado_por UUID REFERENCES auth.users(id),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.rh_acceso ENABLE ROW LEVEL SECURITY;

-- ¿Es RH? Admin global, o admin de cualquier área con el rol adicional.
CREATE OR REPLACE FUNCTION public.rh_es_rh(_user_id UUID DEFAULT auth.uid())
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.usuario_activo(_user_id) AND (
    public.es_admin_global(_user_id)
    OR (EXISTS (SELECT 1 FROM public.rh_acceso a WHERE a.user_id = _user_id)
        AND public.nivel_al_menos(_user_id, 'admin'))
  )
$$;

DROP POLICY IF EXISTS "rh_acceso_select" ON public.rh_acceso;
CREATE POLICY "rh_acceso_select" ON public.rh_acceso
  FOR SELECT TO authenticated USING (user_id = auth.uid() OR public.rh_es_rh());
-- Solo el admin global designa a RH.
DROP POLICY IF EXISTS "rh_acceso_admin" ON public.rh_acceso;
CREATE POLICY "rh_acceso_admin" ON public.rh_acceso
  FOR ALL TO authenticated
  USING (public.es_admin_global(auth.uid()))
  WITH CHECK (public.es_admin_global(auth.uid()));

-- ── 2. Catálogos ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.rh_areas (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  clave      TEXT NOT NULL UNIQUE,
  nombre     TEXT NOT NULL,
  user_area  public.user_area,           -- área de acceso equivalente, si la hay
  activo     BOOLEAN NOT NULL DEFAULT true,
  orden      INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS public.rh_puestos (
  id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre   TEXT NOT NULL,
  area_id  UUID REFERENCES public.rh_areas(id),
  activo   BOOLEAN NOT NULL DEFAULT true,
  UNIQUE (nombre, area_id)
);
CREATE TABLE IF NOT EXISTS public.rh_tipos_documento (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  clave          TEXT NOT NULL UNIQUE,
  nombre         TEXT NOT NULL,
  ayuda          TEXT,
  requerido      BOOLEAN NOT NULL DEFAULT true,   -- cuenta para el % de avance
  vigencia_meses INTEGER,                         -- NULL = no vence
  activo         BOOLEAN NOT NULL DEFAULT true,
  orden          INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS public.rh_tipos_solicitud (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  clave                 TEXT NOT NULL UNIQUE,
  nombre                TEXT NOT NULL,
  descuenta_vacaciones  BOOLEAN NOT NULL DEFAULT false,
  activo                BOOLEAN NOT NULL DEFAULT true,
  orden                 INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS public.rh_parametros (
  clave       TEXT PRIMARY KEY,
  valor       TEXT NOT NULL,
  descripcion TEXT,
  updated_by  UUID REFERENCES auth.users(id),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.rh_biblioteca_categorias (
  id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre TEXT NOT NULL UNIQUE,
  orden  INTEGER NOT NULL DEFAULT 0,
  activo BOOLEAN NOT NULL DEFAULT true
);

-- ── 3. Plantilla ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.rh_empleados (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id            UUID NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
  numero_empleado    TEXT UNIQUE,
  nombre             TEXT NOT NULL,
  correo             TEXT,
  telefono           TEXT,
  area_id            UUID REFERENCES public.rh_areas(id),
  puesto_id          UUID REFERENCES public.rh_puestos(id),
  reporta_a          UUID REFERENCES public.rh_empleados(id) ON DELETE SET NULL,
  fecha_ingreso      DATE,
  fecha_baja         DATE,
  motivo_baja        TEXT,
  estatus            TEXT NOT NULL DEFAULT 'activo' CHECK (estatus IN ('activo', 'licencia', 'baja')),
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (reporta_a IS NULL OR reporta_a <> id)
);
CREATE INDEX IF NOT EXISTS idx_rh_empleados_area ON public.rh_empleados (area_id);
CREATE INDEX IF NOT EXISTS idx_rh_empleados_reporta ON public.rh_empleados (reporta_a);

-- Datos personales y fiscales: tabla aparte, política más estricta.
CREATE TABLE IF NOT EXISTS public.rh_empleado_datos (
  empleado_id             UUID PRIMARY KEY REFERENCES public.rh_empleados(id) ON DELETE CASCADE,
  rfc                     TEXT,
  curp                    TEXT,
  nss                     TEXT,
  clabe                   TEXT,
  banco                   TEXT,
  fecha_nacimiento        DATE,
  domicilio               TEXT,
  codigo_postal           TEXT,
  contacto_emergencia     TEXT,
  telefono_emergencia     TEXT,
  updated_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ── 4. Ayudantes de pertenencia (SECURITY DEFINER: evitan recursión en RLS) ──
CREATE OR REPLACE FUNCTION public.rh_mi_empleado_id()
RETURNS UUID LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT e.id FROM public.rh_empleados e WHERE e.user_id = auth.uid() LIMIT 1
$$;

CREATE OR REPLACE FUNCTION public.rh_es_yo(_empleado UUID)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.usuario_activo(auth.uid())
     AND EXISTS (SELECT 1 FROM public.rh_empleados e WHERE e.id = _empleado AND e.user_id = auth.uid())
$$;

CREATE OR REPLACE FUNCTION public.rh_es_jefe_de(_empleado UUID)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.usuario_activo(auth.uid())
     AND EXISTS (
       SELECT 1 FROM public.rh_empleados e
        WHERE e.id = _empleado AND e.reporta_a IS NOT NULL AND e.reporta_a = public.rh_mi_empleado_id())
$$;

CREATE OR REPLACE FUNCTION public.rh_mi_area_id()
RETURNS UUID LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT e.area_id FROM public.rh_empleados e WHERE e.user_id = auth.uid() LIMIT 1
$$;

-- Parámetro numérico/texto con valor por omisión.
CREATE OR REPLACE FUNCTION public.rh_parametro(_clave TEXT, _defecto TEXT DEFAULT NULL)
RETURNS TEXT LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce((SELECT valor FROM public.rh_parametros WHERE clave = _clave), _defecto)
$$;

-- ── 5. Expediente ───────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.rh_documentos (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  empleado_id   UUID NOT NULL REFERENCES public.rh_empleados(id) ON DELETE CASCADE,
  tipo_id       UUID NOT NULL REFERENCES public.rh_tipos_documento(id),
  ruta          TEXT NOT NULL,
  nombre_archivo TEXT,
  estatus       TEXT NOT NULL DEFAULT 'subido' CHECK (estatus IN ('subido', 'verificado', 'rechazado')),
  nota          TEXT,
  vence_el      DATE,
  verificado_por UUID REFERENCES auth.users(id),
  verificado_at TIMESTAMPTZ,
  subido_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_rh_documentos_empleado ON public.rh_documentos (empleado_id, tipo_id);

-- ── 6. Biblioteca (manuales, políticas) y tablero de publicaciones ───────────
CREATE TABLE IF NOT EXISTS public.rh_biblioteca_documentos (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  categoria_id  UUID REFERENCES public.rh_biblioteca_categorias(id),
  titulo        TEXT NOT NULL,
  descripcion   TEXT,
  tipo          TEXT NOT NULL DEFAULT 'manual' CHECK (tipo IN ('manual', 'politica', 'reglamento', 'formato', 'otro')),
  version       INTEGER NOT NULL DEFAULT 1,
  ruta          TEXT NOT NULL,
  nombre_archivo TEXT,
  mime          TEXT,
  publicado     BOOLEAN NOT NULL DEFAULT false,
  requiere_acuse BOOLEAN NOT NULL DEFAULT false,
  creado_por    UUID REFERENCES auth.users(id),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- Público: áreas a las que va dirigido. Sin renglones = toda la empresa.
CREATE TABLE IF NOT EXISTS public.rh_biblioteca_publico (
  documento_id UUID NOT NULL REFERENCES public.rh_biblioteca_documentos(id) ON DELETE CASCADE,
  area_id      UUID NOT NULL REFERENCES public.rh_areas(id) ON DELETE CASCADE,
  PRIMARY KEY (documento_id, area_id)
);
CREATE TABLE IF NOT EXISTS public.rh_biblioteca_versiones (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  documento_id  UUID NOT NULL REFERENCES public.rh_biblioteca_documentos(id) ON DELETE CASCADE,
  version       INTEGER NOT NULL,
  ruta          TEXT NOT NULL,
  nombre_archivo TEXT,
  nota          TEXT,
  subido_por    UUID REFERENCES auth.users(id),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (documento_id, version)
);
CREATE TABLE IF NOT EXISTS public.rh_biblioteca_lecturas (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  documento_id UUID NOT NULL REFERENCES public.rh_biblioteca_documentos(id) ON DELETE CASCADE,
  empleado_id  UUID NOT NULL REFERENCES public.rh_empleados(id) ON DELETE CASCADE,
  version      INTEGER NOT NULL,
  leido_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (documento_id, empleado_id, version)
);

CREATE TABLE IF NOT EXISTS public.rh_publicaciones (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  titulo       TEXT NOT NULL,
  cuerpo       TEXT NOT NULL DEFAULT '',
  area_id      UUID REFERENCES public.rh_areas(id),   -- NULL = para todos
  fijada       BOOLEAN NOT NULL DEFAULT false,
  publicado_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  vence_at     TIMESTAMPTZ,
  creado_por   UUID REFERENCES auth.users(id),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_rh_publicaciones_fecha ON public.rh_publicaciones (publicado_at DESC);

-- ¿Puede el usuario actual ver este documento de la biblioteca?
CREATE OR REPLACE FUNCTION public.rh_puede_ver_biblioteca(_documento UUID)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.usuario_activo(auth.uid()) AND (
    public.rh_es_rh()
    OR EXISTS (
      SELECT 1 FROM public.rh_biblioteca_documentos d
       WHERE d.id = _documento AND d.publicado
         AND (NOT EXISTS (SELECT 1 FROM public.rh_biblioteca_publico p WHERE p.documento_id = d.id)
              OR EXISTS (SELECT 1 FROM public.rh_biblioteca_publico p
                          WHERE p.documento_id = d.id AND p.area_id = public.rh_mi_area_id()))
    )
  )
$$;

-- ── 7. Checador ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.rh_oficinas (
  id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre    TEXT NOT NULL,
  direccion TEXT,
  lat       DOUBLE PRECISION NOT NULL CHECK (lat BETWEEN -90 AND 90),
  lng       DOUBLE PRECISION NOT NULL CHECK (lng BETWEEN -180 AND 180),
  radio_m   INTEGER NOT NULL DEFAULT 150 CHECK (radio_m BETWEEN 30 AND 2000),
  activo    BOOLEAN NOT NULL DEFAULT true
);

CREATE TABLE IF NOT EXISTS public.rh_horarios (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  empleado_id    UUID NOT NULL REFERENCES public.rh_empleados(id) ON DELETE CASCADE,
  dias           INTEGER[] NOT NULL DEFAULT '{1,2,3,4,5}',   -- 1 = lunes … 7 = domingo
  hora_entrada   TIME NOT NULL,
  hora_salida    TIME NOT NULL,
  tolerancia_min INTEGER,                                    -- NULL = parámetro general
  vigente_desde  DATE NOT NULL DEFAULT current_date,
  vigente_hasta  DATE,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (hora_salida <> hora_entrada)
);
CREATE INDEX IF NOT EXISTS idx_rh_horarios_empleado ON public.rh_horarios (empleado_id, vigente_desde DESC);

CREATE TABLE IF NOT EXISTS public.rh_dias_inhabiles (
  fecha  DATE PRIMARY KEY,
  motivo TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS public.rh_asistencia (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  empleado_id      UUID NOT NULL REFERENCES public.rh_empleados(id) ON DELETE CASCADE,
  fecha            DATE NOT NULL,                    -- día local de la entrada
  modo             TEXT NOT NULL DEFAULT 'oficina' CHECK (modo IN ('oficina', 'remoto', 'comision')),
  entrada_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  entrada_resultado TEXT NOT NULL,
  entrada_oficina_id UUID REFERENCES public.rh_oficinas(id),
  retardo_min      INTEGER NOT NULL DEFAULT 0,
  salida_at        TIMESTAMPTZ,
  salida_resultado TEXT,
  corregida        BOOLEAN NOT NULL DEFAULT false,
  nota             TEXT,
  CHECK (salida_at IS NULL OR salida_at >= entrada_at)
);
CREATE INDEX IF NOT EXISTS idx_rh_asistencia_emp_fecha ON public.rh_asistencia (empleado_id, fecha DESC);
-- Una sola jornada abierta por persona.
CREATE UNIQUE INDEX IF NOT EXISTS uq_rh_asistencia_abierta ON public.rh_asistencia (empleado_id) WHERE salida_at IS NULL;

-- Ubicación aproximada (~100 m). La lee SOLO la propia persona.
CREATE TABLE IF NOT EXISTS public.rh_asistencia_ubicacion (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  asistencia_id UUID NOT NULL REFERENCES public.rh_asistencia(id) ON DELETE CASCADE,
  empleado_id   UUID NOT NULL REFERENCES public.rh_empleados(id) ON DELETE CASCADE,
  momento       TEXT NOT NULL CHECK (momento IN ('entrada', 'salida')),
  lat           NUMERIC(8,3),
  lng           NUMERIC(8,3),
  precision_m   INTEGER,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.rh_asistencia_correcciones (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  asistencia_id UUID NOT NULL REFERENCES public.rh_asistencia(id) ON DELETE CASCADE,
  corregido_por UUID NOT NULL REFERENCES auth.users(id),
  entrada_antes TIMESTAMPTZ,
  salida_antes  TIMESTAMPTZ,
  entrada_nueva TIMESTAMPTZ,
  salida_nueva  TIMESTAMPTZ,
  motivo        TEXT NOT NULL CHECK (length(btrim(motivo)) >= 10),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ── 8. Solicitudes y vacaciones ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.rh_solicitudes (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  empleado_id    UUID NOT NULL REFERENCES public.rh_empleados(id) ON DELETE CASCADE,
  tipo_id        UUID NOT NULL REFERENCES public.rh_tipos_solicitud(id),
  fecha_inicio   DATE NOT NULL,
  fecha_fin      DATE NOT NULL,
  dias           NUMERIC(5,1) NOT NULL DEFAULT 0,
  motivo         TEXT,
  estatus        TEXT NOT NULL DEFAULT 'pendiente' CHECK (estatus IN ('pendiente', 'aprobada', 'rechazada', 'cancelada')),
  resuelto_por   UUID REFERENCES auth.users(id),
  resuelto_at    TIMESTAMPTZ,
  comentario     TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (fecha_fin >= fecha_inicio)
);
CREATE INDEX IF NOT EXISTS idx_rh_solicitudes_empleado ON public.rh_solicitudes (empleado_id, fecha_inicio DESC);

CREATE TABLE IF NOT EXISTS public.rh_vacaciones_saldos (
  empleado_id    UUID NOT NULL REFERENCES public.rh_empleados(id) ON DELETE CASCADE,
  periodo        INTEGER NOT NULL,
  dias_asignados NUMERIC(5,1) NOT NULL DEFAULT 0,
  nota           TEXT,
  PRIMARY KEY (empleado_id, periodo)
);

-- ── 9. Bitácora de accesos (solo se inserta) ────────────────────────────────
CREATE TABLE IF NOT EXISTS public.rh_bitacora_accesos (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id  UUID NOT NULL REFERENCES auth.users(id),
  empleado_id UUID REFERENCES public.rh_empleados(id) ON DELETE SET NULL,
  accion      TEXT NOT NULL,
  detalle     JSONB,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_rh_bitacora_fecha ON public.rh_bitacora_accesos (created_at DESC);

-- ── 10. RLS ─────────────────────────────────────────────────────────────────
DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'rh_areas','rh_puestos','rh_tipos_documento','rh_tipos_solicitud','rh_parametros','rh_biblioteca_categorias',
    'rh_empleados','rh_empleado_datos','rh_documentos','rh_biblioteca_documentos','rh_biblioteca_publico',
    'rh_biblioteca_versiones','rh_biblioteca_lecturas','rh_publicaciones','rh_oficinas','rh_horarios',
    'rh_dias_inhabiles','rh_asistencia','rh_asistencia_ubicacion','rh_asistencia_correcciones',
    'rh_solicitudes','rh_vacaciones_saldos','rh_bitacora_accesos'
  ] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
  END LOOP;
END $$;

-- Catálogos: leen todos los usuarios activos; escribe RH.
DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'rh_areas','rh_puestos','rh_tipos_documento','rh_tipos_solicitud','rh_parametros',
    'rh_biblioteca_categorias','rh_oficinas','rh_dias_inhabiles'
  ] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_select', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (public.usuario_activo(auth.uid()))', t || '_select', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_rh', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR ALL TO authenticated USING (public.rh_es_rh()) WITH CHECK (public.rh_es_rh())', t || '_rh', t);
  END LOOP;
END $$;

-- Plantilla: RH, la propia persona y su jefe directo. El directorio va por vista.
DROP POLICY IF EXISTS "rh_empleados_select" ON public.rh_empleados;
CREATE POLICY "rh_empleados_select" ON public.rh_empleados FOR SELECT TO authenticated
  USING (public.rh_es_rh() OR public.rh_es_yo(id) OR public.rh_es_jefe_de(id));
DROP POLICY IF EXISTS "rh_empleados_rh" ON public.rh_empleados;
CREATE POLICY "rh_empleados_rh" ON public.rh_empleados FOR ALL TO authenticated
  USING (public.rh_es_rh()) WITH CHECK (public.rh_es_rh());

-- Datos sensibles: dueño y RH. El jefe NO.
DROP POLICY IF EXISTS "rh_empleado_datos_select" ON public.rh_empleado_datos;
CREATE POLICY "rh_empleado_datos_select" ON public.rh_empleado_datos FOR SELECT TO authenticated
  USING (public.rh_es_rh() OR public.rh_es_yo(empleado_id));
DROP POLICY IF EXISTS "rh_empleado_datos_dueno" ON public.rh_empleado_datos;
CREATE POLICY "rh_empleado_datos_dueno" ON public.rh_empleado_datos FOR ALL TO authenticated
  USING (public.rh_es_yo(empleado_id)) WITH CHECK (public.rh_es_yo(empleado_id));
DROP POLICY IF EXISTS "rh_empleado_datos_rh" ON public.rh_empleado_datos;
CREATE POLICY "rh_empleado_datos_rh" ON public.rh_empleado_datos FOR ALL TO authenticated
  USING (public.rh_es_rh()) WITH CHECK (public.rh_es_rh());

-- Expediente: dueño y RH. El jefe NO.
DROP POLICY IF EXISTS "rh_documentos_select" ON public.rh_documentos;
CREATE POLICY "rh_documentos_select" ON public.rh_documentos FOR SELECT TO authenticated
  USING (public.rh_es_rh() OR public.rh_es_yo(empleado_id));
DROP POLICY IF EXISTS "rh_documentos_dueno_insert" ON public.rh_documentos;
CREATE POLICY "rh_documentos_dueno_insert" ON public.rh_documentos FOR INSERT TO authenticated
  WITH CHECK (public.rh_es_yo(empleado_id) AND estatus = 'subido');
DROP POLICY IF EXISTS "rh_documentos_dueno_delete" ON public.rh_documentos;
CREATE POLICY "rh_documentos_dueno_delete" ON public.rh_documentos FOR DELETE TO authenticated
  USING (public.rh_es_yo(empleado_id) AND estatus <> 'verificado');
DROP POLICY IF EXISTS "rh_documentos_rh" ON public.rh_documentos;
CREATE POLICY "rh_documentos_rh" ON public.rh_documentos FOR ALL TO authenticated
  USING (public.rh_es_rh()) WITH CHECK (public.rh_es_rh());

-- Biblioteca.
DROP POLICY IF EXISTS "rh_biblioteca_documentos_select" ON public.rh_biblioteca_documentos;
CREATE POLICY "rh_biblioteca_documentos_select" ON public.rh_biblioteca_documentos FOR SELECT TO authenticated
  USING (public.rh_puede_ver_biblioteca(id));
DROP POLICY IF EXISTS "rh_biblioteca_documentos_rh" ON public.rh_biblioteca_documentos;
CREATE POLICY "rh_biblioteca_documentos_rh" ON public.rh_biblioteca_documentos FOR ALL TO authenticated
  USING (public.rh_es_rh()) WITH CHECK (public.rh_es_rh());

DROP POLICY IF EXISTS "rh_biblioteca_publico_select" ON public.rh_biblioteca_publico;
CREATE POLICY "rh_biblioteca_publico_select" ON public.rh_biblioteca_publico FOR SELECT TO authenticated
  USING (public.rh_puede_ver_biblioteca(documento_id));
DROP POLICY IF EXISTS "rh_biblioteca_publico_rh" ON public.rh_biblioteca_publico;
CREATE POLICY "rh_biblioteca_publico_rh" ON public.rh_biblioteca_publico FOR ALL TO authenticated
  USING (public.rh_es_rh()) WITH CHECK (public.rh_es_rh());

DROP POLICY IF EXISTS "rh_biblioteca_versiones_select" ON public.rh_biblioteca_versiones;
CREATE POLICY "rh_biblioteca_versiones_select" ON public.rh_biblioteca_versiones FOR SELECT TO authenticated
  USING (public.rh_es_rh());
DROP POLICY IF EXISTS "rh_biblioteca_versiones_rh" ON public.rh_biblioteca_versiones;
CREATE POLICY "rh_biblioteca_versiones_rh" ON public.rh_biblioteca_versiones FOR ALL TO authenticated
  USING (public.rh_es_rh()) WITH CHECK (public.rh_es_rh());

DROP POLICY IF EXISTS "rh_biblioteca_lecturas_select" ON public.rh_biblioteca_lecturas;
CREATE POLICY "rh_biblioteca_lecturas_select" ON public.rh_biblioteca_lecturas FOR SELECT TO authenticated
  USING (public.rh_es_rh() OR public.rh_es_yo(empleado_id));

-- Tablero de publicaciones.
DROP POLICY IF EXISTS "rh_publicaciones_select" ON public.rh_publicaciones;
CREATE POLICY "rh_publicaciones_select" ON public.rh_publicaciones FOR SELECT TO authenticated
  USING (public.usuario_activo(auth.uid()) AND (
    public.rh_es_rh()
    OR (publicado_at <= now() AND (vence_at IS NULL OR vence_at > now())
        AND (area_id IS NULL OR area_id = public.rh_mi_area_id()))));
DROP POLICY IF EXISTS "rh_publicaciones_rh" ON public.rh_publicaciones;
CREATE POLICY "rh_publicaciones_rh" ON public.rh_publicaciones FOR ALL TO authenticated
  USING (public.rh_es_rh()) WITH CHECK (public.rh_es_rh());

-- Horarios: la persona, su jefe y RH leen; escribe RH.
DROP POLICY IF EXISTS "rh_horarios_select" ON public.rh_horarios;
CREATE POLICY "rh_horarios_select" ON public.rh_horarios FOR SELECT TO authenticated
  USING (public.rh_es_rh() OR public.rh_es_yo(empleado_id) OR public.rh_es_jefe_de(empleado_id));
DROP POLICY IF EXISTS "rh_horarios_rh" ON public.rh_horarios;
CREATE POLICY "rh_horarios_rh" ON public.rh_horarios FOR ALL TO authenticated
  USING (public.rh_es_rh()) WITH CHECK (public.rh_es_rh());

-- Asistencia: solo lectura desde la app; se escribe por RPC.
DROP POLICY IF EXISTS "rh_asistencia_select" ON public.rh_asistencia;
CREATE POLICY "rh_asistencia_select" ON public.rh_asistencia FOR SELECT TO authenticated
  USING (public.rh_es_rh() OR public.rh_es_yo(empleado_id) OR public.rh_es_jefe_de(empleado_id));
DROP POLICY IF EXISTS "rh_asistencia_ubicacion_select" ON public.rh_asistencia_ubicacion;
CREATE POLICY "rh_asistencia_ubicacion_select" ON public.rh_asistencia_ubicacion FOR SELECT TO authenticated
  USING (public.rh_es_yo(empleado_id));   -- ni RH ni el jefe ven el punto
DROP POLICY IF EXISTS "rh_asistencia_correcciones_select" ON public.rh_asistencia_correcciones;
CREATE POLICY "rh_asistencia_correcciones_select" ON public.rh_asistencia_correcciones FOR SELECT TO authenticated
  USING (public.rh_es_rh() OR EXISTS (
    SELECT 1 FROM public.rh_asistencia a
     WHERE a.id = asistencia_id AND (public.rh_es_yo(a.empleado_id) OR public.rh_es_jefe_de(a.empleado_id))));

-- Solicitudes y saldos: la persona, su jefe y RH leen; escribe solo por RPC (saldos: RH).
DROP POLICY IF EXISTS "rh_solicitudes_select" ON public.rh_solicitudes;
CREATE POLICY "rh_solicitudes_select" ON public.rh_solicitudes FOR SELECT TO authenticated
  USING (public.rh_es_rh() OR public.rh_es_yo(empleado_id) OR public.rh_es_jefe_de(empleado_id));
DROP POLICY IF EXISTS "rh_vacaciones_saldos_select" ON public.rh_vacaciones_saldos;
CREATE POLICY "rh_vacaciones_saldos_select" ON public.rh_vacaciones_saldos FOR SELECT TO authenticated
  USING (public.rh_es_rh() OR public.rh_es_yo(empleado_id) OR public.rh_es_jefe_de(empleado_id));
DROP POLICY IF EXISTS "rh_vacaciones_saldos_rh" ON public.rh_vacaciones_saldos;
CREATE POLICY "rh_vacaciones_saldos_rh" ON public.rh_vacaciones_saldos FOR ALL TO authenticated
  USING (public.rh_es_rh()) WITH CHECK (public.rh_es_rh());

-- Bitácora: solo RH lee; se inserta por RPC.
DROP POLICY IF EXISTS "rh_bitacora_accesos_select" ON public.rh_bitacora_accesos;
CREATE POLICY "rh_bitacora_accesos_select" ON public.rh_bitacora_accesos FOR SELECT TO authenticated
  USING (public.rh_es_rh());

-- Privilegios de tabla (RLS decide qué filas).
GRANT SELECT ON public.rh_acceso, public.rh_areas, public.rh_puestos, public.rh_tipos_documento,
  public.rh_tipos_solicitud, public.rh_parametros, public.rh_biblioteca_categorias, public.rh_oficinas,
  public.rh_dias_inhabiles, public.rh_empleados, public.rh_empleado_datos, public.rh_documentos,
  public.rh_biblioteca_documentos, public.rh_biblioteca_publico, public.rh_biblioteca_versiones,
  public.rh_biblioteca_lecturas, public.rh_publicaciones, public.rh_horarios, public.rh_asistencia,
  public.rh_asistencia_ubicacion, public.rh_asistencia_correcciones, public.rh_solicitudes,
  public.rh_vacaciones_saldos, public.rh_bitacora_accesos TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.rh_acceso, public.rh_areas, public.rh_puestos,
  public.rh_tipos_documento, public.rh_tipos_solicitud, public.rh_parametros,
  public.rh_biblioteca_categorias, public.rh_oficinas, public.rh_dias_inhabiles, public.rh_empleados,
  public.rh_empleado_datos, public.rh_documentos, public.rh_biblioteca_documentos,
  public.rh_biblioteca_publico, public.rh_biblioteca_versiones, public.rh_publicaciones,
  public.rh_horarios, public.rh_vacaciones_saldos TO authenticated;

-- Tablas que SOLO se escriben por RPC: sin escritura directa aunque Supabase
-- otorgue privilegios por omisión; y ninguna tabla de RH es visible para anon.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.rh_asistencia, public.rh_asistencia_ubicacion,
  public.rh_asistencia_correcciones, public.rh_solicitudes, public.rh_bitacora_accesos,
  public.rh_biblioteca_lecturas FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.rh_acceso, public.rh_areas, public.rh_puestos, public.rh_tipos_documento,
  public.rh_tipos_solicitud, public.rh_parametros, public.rh_biblioteca_categorias, public.rh_oficinas,
  public.rh_dias_inhabiles, public.rh_empleados, public.rh_empleado_datos, public.rh_documentos,
  public.rh_biblioteca_documentos, public.rh_biblioteca_publico, public.rh_biblioteca_versiones,
  public.rh_biblioteca_lecturas, public.rh_publicaciones, public.rh_horarios, public.rh_asistencia,
  public.rh_asistencia_ubicacion, public.rh_asistencia_correcciones, public.rh_solicitudes,
  public.rh_vacaciones_saldos, public.rh_bitacora_accesos FROM anon;

-- ── 11. Directorio general: solo nombre, puesto, área y correo ──────────────
-- Vista con los privilegios de su dueño A PROPÓSITO: expone únicamente estas
-- columnas, de empleados activos, a cualquier usuario activo.
CREATE OR REPLACE VIEW public.v_rh_directorio AS
SELECT e.id, e.nombre, e.correo, a.nombre AS area, p.nombre AS puesto, e.reporta_a
  FROM public.rh_empleados e
  LEFT JOIN public.rh_areas a ON a.id = e.area_id
  LEFT JOIN public.rh_puestos p ON p.id = e.puesto_id
 WHERE e.estatus <> 'baja' AND public.usuario_activo(auth.uid());
GRANT SELECT ON public.v_rh_directorio TO authenticated;
REVOKE ALL ON public.v_rh_directorio FROM anon;

-- Vacaciones por empleado y año (respeta RLS de quien consulta).
CREATE OR REPLACE VIEW public.v_rh_vacaciones WITH (security_invoker = true) AS
SELECT s.empleado_id, s.periodo, s.dias_asignados,
       coalesce((SELECT sum(x.dias) FROM public.rh_solicitudes x
                   JOIN public.rh_tipos_solicitud t ON t.id = x.tipo_id
                  WHERE x.empleado_id = s.empleado_id AND t.descuenta_vacaciones
                    AND x.estatus = 'aprobada' AND extract(year FROM x.fecha_inicio) = s.periodo), 0) AS dias_tomados,
       coalesce((SELECT sum(x.dias) FROM public.rh_solicitudes x
                   JOIN public.rh_tipos_solicitud t ON t.id = x.tipo_id
                  WHERE x.empleado_id = s.empleado_id AND t.descuenta_vacaciones
                    AND x.estatus = 'pendiente' AND extract(year FROM x.fecha_inicio) = s.periodo), 0) AS dias_pendientes
  FROM public.rh_vacaciones_saldos s;
GRANT SELECT ON public.v_rh_vacaciones TO authenticated;
REVOKE ALL ON public.v_rh_vacaciones FROM anon;

-- ── 12. Triggers de guarda ──────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rh_touch_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$ BEGIN NEW.updated_at := now(); RETURN NEW; END $$;

DROP TRIGGER IF EXISTS trg_rh_empleados_updated ON public.rh_empleados;
CREATE TRIGGER trg_rh_empleados_updated BEFORE UPDATE ON public.rh_empleados
  FOR EACH ROW EXECUTE FUNCTION public.rh_touch_updated_at();
DROP TRIGGER IF EXISTS trg_rh_empleado_datos_updated ON public.rh_empleado_datos;
CREATE TRIGGER trg_rh_empleado_datos_updated BEFORE UPDATE ON public.rh_empleado_datos
  FOR EACH ROW EXECUTE FUNCTION public.rh_touch_updated_at();
DROP TRIGGER IF EXISTS trg_rh_biblioteca_updated ON public.rh_biblioteca_documentos;
CREATE TRIGGER trg_rh_biblioteca_updated BEFORE UPDATE ON public.rh_biblioteca_documentos
  FOR EACH ROW EXECUTE FUNCTION public.rh_touch_updated_at();

-- Quien no es RH no puede marcar un documento como verificado/rechazado, y la
-- verificación deja autor y fecha.
CREATE OR REPLACE FUNCTION public.rh_documentos_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NOT public.rh_es_rh() THEN NEW.estatus := 'subido'; NEW.verificado_por := NULL; NEW.verificado_at := NULL; END IF;
    RETURN NEW;
  END IF;
  IF NOT public.rh_es_rh() THEN RAISE EXCEPTION 'Solo RH verifica documentos.'; END IF;
  IF NEW.estatus IS DISTINCT FROM OLD.estatus AND NEW.estatus IN ('verificado', 'rechazado') THEN
    NEW.verificado_por := auth.uid();
    NEW.verificado_at := now();
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_rh_documentos_guard ON public.rh_documentos;
CREATE TRIGGER trg_rh_documentos_guard BEFORE INSERT OR UPDATE ON public.rh_documentos
  FOR EACH ROW EXECUTE FUNCTION public.rh_documentos_guard();

-- ── 13. RPC ─────────────────────────────────────────────────────────────────
-- Crea la ficha de quien aún no la tiene, a partir de los usuarios existentes.
CREATE OR REPLACE FUNCTION public.rh_sincronizar_plantilla()
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n INTEGER;
BEGIN
  IF NOT public.rh_es_rh() THEN RAISE EXCEPTION 'Solo RH puede sincronizar la plantilla.'; END IF;
  WITH nuevos AS (
    INSERT INTO public.rh_empleados (user_id, nombre, correo, area_id, estatus)
    SELECT p.id,
           coalesce(nullif(btrim(p.nombre_completo), ''), split_part(coalesce(u.email, ''), '@', 1), 'Sin nombre'),
           u.email,
           (SELECT a.id FROM public.rh_areas a WHERE a.user_area = r.area LIMIT 1),
           CASE WHEN p.activo IS FALSE THEN 'baja' ELSE 'activo' END
      FROM public.profiles p
      JOIN auth.users u ON u.id = p.id
      LEFT JOIN LATERAL (SELECT ur.area FROM public.user_roles ur WHERE ur.user_id = p.id LIMIT 1) r ON true
     WHERE NOT EXISTS (SELECT 1 FROM public.rh_empleados e WHERE e.user_id = p.id)
    RETURNING 1)
  SELECT count(*) INTO n FROM nuevos;
  RETURN n;
END $$;

-- Registra que RH (o quien sea) abrió algo sensible de otra persona.
CREATE OR REPLACE FUNCTION public.rh_registrar_acceso(_empleado UUID, _accion TEXT, _detalle JSONB DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.usuario_activo(auth.uid()) THEN RAISE EXCEPTION 'Sin sesión.'; END IF;
  -- Ver lo propio no se registra.
  IF _empleado IS NOT NULL AND public.rh_es_yo(_empleado) THEN RETURN; END IF;
  IF NOT public.rh_es_rh() THEN RAISE EXCEPTION 'Sin permiso.'; END IF;
  INSERT INTO public.rh_bitacora_accesos (usuario_id, empleado_id, accion, detalle)
  VALUES (auth.uid(), _empleado, left(_accion, 80), _detalle);
END $$;

-- Lectura / acuse de un documento de la biblioteca.
CREATE OR REPLACE FUNCTION public.rh_registrar_lectura(_documento UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE emp UUID := public.rh_mi_empleado_id(); ver INTEGER;
BEGIN
  IF emp IS NULL THEN RAISE EXCEPTION 'No tienes ficha de colaborador.'; END IF;
  IF NOT public.rh_puede_ver_biblioteca(_documento) THEN RAISE EXCEPTION 'Documento no disponible.'; END IF;
  SELECT version INTO ver FROM public.rh_biblioteca_documentos WHERE id = _documento;
  INSERT INTO public.rh_biblioteca_lecturas (documento_id, empleado_id, version)
  VALUES (_documento, emp, ver) ON CONFLICT DO NOTHING;
END $$;

-- Sube una versión nueva: la anterior queda en el historial.
CREATE OR REPLACE FUNCTION public.rh_biblioteca_nueva_version(_documento UUID, _ruta TEXT, _nombre TEXT, _nota TEXT DEFAULT NULL)
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE nueva INTEGER;
BEGIN
  IF NOT public.rh_es_rh() THEN RAISE EXCEPTION 'Solo RH publica versiones.'; END IF;
  UPDATE public.rh_biblioteca_documentos
     SET version = version + 1, ruta = _ruta, nombre_archivo = _nombre
   WHERE id = _documento RETURNING version INTO nueva;
  IF nueva IS NULL THEN RAISE EXCEPTION 'Documento no encontrado.'; END IF;
  INSERT INTO public.rh_biblioteca_versiones (documento_id, version, ruta, nombre_archivo, nota, subido_por)
  VALUES (_documento, nueva, _ruta, _nombre, _nota, auth.uid());
  RETURN nueva;
END $$;

-- Distancia en metros (Haversine).
CREATE OR REPLACE FUNCTION public.rh_distancia_m(lat1 DOUBLE PRECISION, lng1 DOUBLE PRECISION, lat2 DOUBLE PRECISION, lng2 DOUBLE PRECISION)
RETURNS DOUBLE PRECISION LANGUAGE SQL IMMUTABLE AS $$
  SELECT 2 * 6371000 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)))
$$;

-- Resultado de ubicación calculado en el servidor.
CREATE OR REPLACE FUNCTION public.rh_resultado_ubicacion(_modo TEXT, _lat DOUBLE PRECISION, _lng DOUBLE PRECISION, _precision DOUBLE PRECISION, OUT resultado TEXT, OUT oficina UUID)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE o RECORD; hay BOOLEAN := false; maxp DOUBLE PRECISION := public.rh_parametro('precision_max_m', '150')::double precision;
BEGIN
  oficina := NULL;
  IF _modo = 'remoto' THEN resultado := 'remoto'; RETURN; END IF;
  IF _modo = 'comision' THEN resultado := 'comision'; RETURN; END IF;
  IF _lat IS NULL OR _lng IS NULL THEN resultado := 'sin_ubicacion'; RETURN; END IF;
  SELECT true INTO hay FROM public.rh_oficinas WHERE activo LIMIT 1;
  IF NOT coalesce(hay, false) THEN resultado := 'sin_oficinas'; RETURN; END IF;
  IF _precision IS NOT NULL AND _precision > maxp THEN resultado := 'imprecisa'; RETURN; END IF;
  FOR o IN SELECT id, lat, lng, radio_m FROM public.rh_oficinas WHERE activo ORDER BY public.rh_distancia_m(_lat, _lng, lat, lng) LOOP
    IF public.rh_distancia_m(_lat, _lng, o.lat, o.lng) <= o.radio_m THEN
      resultado := 'en_oficina'; oficina := o.id; RETURN;
    END IF;
    EXIT; -- solo la más cercana
  END LOOP;
  resultado := 'fuera_geocerca';
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
  IF EXISTS (SELECT 1 FROM public.rh_asistencia WHERE empleado_id = emp AND salida_at IS NULL) THEN
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
  SELECT * INTO a FROM public.rh_asistencia WHERE empleado_id = emp AND salida_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No tienes una jornada abierta.'; END IF;
  SELECT * INTO res FROM public.rh_resultado_ubicacion(a.modo, _lat, _lng, _precision);
  UPDATE public.rh_asistencia SET salida_at = now(), salida_resultado = res.resultado WHERE id = a.id;
  IF _lat IS NOT NULL AND _lng IS NOT NULL AND a.modo = 'oficina' THEN
    INSERT INTO public.rh_asistencia_ubicacion (asistencia_id, empleado_id, momento, lat, lng, precision_m)
    VALUES (a.id, emp, 'salida', round(_lat::numeric, 3), round(_lng::numeric, 3), round(_precision)::int);
  END IF;
  RETURN a.id;
END $$;

-- Corrección de una jornada (RH o jefe directo), con motivo y rastro.
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
     SET entrada_at = coalesce(_entrada, entrada_at), salida_at = coalesce(_salida, salida_at), corregida = true
   WHERE id = _id;
END $$;

-- Días hábiles de una solicitud (horario del empleado, o lunes a viernes) menos inhábiles.
CREATE OR REPLACE FUNCTION public.rh_dias_habiles(_empleado UUID, _desde DATE, _hasta DATE)
RETURNS NUMERIC LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT count(*)::numeric FROM generate_series(_desde, _hasta, interval '1 day') d
   WHERE extract(isodow FROM d)::int = ANY (coalesce(
           (SELECT h.dias FROM public.rh_horarios h
             WHERE h.empleado_id = _empleado AND h.vigente_desde <= d::date AND (h.vigente_hasta IS NULL OR h.vigente_hasta >= d::date)
             ORDER BY h.vigente_desde DESC LIMIT 1), '{1,2,3,4,5}'::int[]))
     AND NOT EXISTS (SELECT 1 FROM public.rh_dias_inhabiles i WHERE i.fecha = d::date)
$$;

CREATE OR REPLACE FUNCTION public.rh_crear_solicitud(_tipo UUID, _inicio DATE, _fin DATE, _motivo TEXT DEFAULT NULL)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE emp UUID := public.rh_mi_empleado_id(); d NUMERIC; nuevo UUID;
BEGIN
  IF emp IS NULL OR NOT public.usuario_activo(auth.uid()) THEN RAISE EXCEPTION 'No tienes ficha de colaborador activa.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rh_tipos_solicitud WHERE id = _tipo AND activo) THEN RAISE EXCEPTION 'Tipo de solicitud no válido.'; END IF;
  IF _fin < _inicio THEN RAISE EXCEPTION 'La fecha final es anterior a la inicial.'; END IF;
  IF EXISTS (SELECT 1 FROM public.rh_solicitudes WHERE empleado_id = emp AND estatus IN ('pendiente', 'aprobada')
              AND fecha_inicio <= _fin AND fecha_fin >= _inicio) THEN
    RAISE EXCEPTION 'Ya tienes una solicitud que se empalma con esas fechas.';
  END IF;
  d := public.rh_dias_habiles(emp, _inicio, _fin);
  INSERT INTO public.rh_solicitudes (empleado_id, tipo_id, fecha_inicio, fecha_fin, dias, motivo)
  VALUES (emp, _tipo, _inicio, _fin, d, nullif(btrim(coalesce(_motivo, '')), '')) RETURNING id INTO nuevo;
  RETURN nuevo;
END $$;

-- La resuelve el jefe directo o RH; nunca la propia persona.
CREATE OR REPLACE FUNCTION public.rh_resolver_solicitud(_id UUID, _aprobar BOOLEAN, _comentario TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE s RECORD;
BEGIN
  SELECT * INTO s FROM public.rh_solicitudes WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Solicitud no encontrada.'; END IF;
  IF s.estatus <> 'pendiente' THEN RAISE EXCEPTION 'La solicitud ya fue resuelta.'; END IF;
  IF public.rh_es_yo(s.empleado_id) THEN RAISE EXCEPTION 'No puedes resolver tu propia solicitud.'; END IF;
  IF NOT (public.rh_es_rh() OR public.rh_es_jefe_de(s.empleado_id)) THEN RAISE EXCEPTION 'Sin permiso.'; END IF;
  IF NOT _aprobar AND length(btrim(coalesce(_comentario, ''))) < 5 THEN RAISE EXCEPTION 'Explica el motivo del rechazo.'; END IF;
  UPDATE public.rh_solicitudes
     SET estatus = CASE WHEN _aprobar THEN 'aprobada' ELSE 'rechazada' END,
         resuelto_por = auth.uid(), resuelto_at = now(), comentario = nullif(btrim(coalesce(_comentario, '')), '')
   WHERE id = _id;
END $$;

CREATE OR REPLACE FUNCTION public.rh_cancelar_solicitud(_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE public.rh_solicitudes SET estatus = 'cancelada', resuelto_at = now(), resuelto_por = auth.uid()
   WHERE id = _id AND estatus = 'pendiente' AND public.rh_es_yo(empleado_id);
  IF NOT FOUND THEN RAISE EXCEPTION 'Solo puedes cancelar tus solicitudes pendientes.'; END IF;
END $$;

-- Faltas calculadas: día de horario sin asistencia, sin solicitud aprobada y no inhábil.
CREATE OR REPLACE FUNCTION public.rh_faltas(_empleado UUID, _desde DATE, _hasta DATE)
RETURNS TABLE (fecha DATE) LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE tz TEXT := public.rh_parametro('zona_horaria', 'America/Mexico_City'); hoy DATE := (now() AT TIME ZONE tz)::date;
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
   WHERE NOT EXISTS (SELECT 1 FROM public.rh_asistencia a WHERE a.empleado_id = _empleado AND a.fecha = d::date)
     AND NOT EXISTS (SELECT 1 FROM public.rh_solicitudes s WHERE s.empleado_id = _empleado AND s.estatus = 'aprobada'
                      AND s.fecha_inicio <= d::date AND s.fecha_fin >= d::date)
     AND NOT EXISTS (SELECT 1 FROM public.rh_dias_inhabiles i WHERE i.fecha = d::date)
     AND d::date >= coalesce((SELECT e.fecha_ingreso FROM public.rh_empleados e WHERE e.id = _empleado), d::date)
   ORDER BY 1;
END $$;

-- Cierra a anon todas las funciones nuevas y abre a usuarios con sesión las que se llaman desde la app.
DO $$
DECLARE f TEXT;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'rh_es_rh(uuid)', 'rh_mi_empleado_id()', 'rh_es_yo(uuid)', 'rh_es_jefe_de(uuid)', 'rh_mi_area_id()',
    'rh_parametro(text,text)', 'rh_puede_ver_biblioteca(uuid)', 'rh_sincronizar_plantilla()',
    'rh_registrar_acceso(uuid,text,jsonb)', 'rh_registrar_lectura(uuid)',
    'rh_biblioteca_nueva_version(uuid,text,text,text)', 'rh_distancia_m(double precision,double precision,double precision,double precision)',
    'rh_resultado_ubicacion(text,double precision,double precision,double precision)',
    'rh_marcar_entrada(text,double precision,double precision,double precision)',
    'rh_marcar_salida(double precision,double precision,double precision)',
    'rh_corregir_asistencia(uuid,timestamptz,timestamptz,text)', 'rh_dias_habiles(uuid,date,date)',
    'rh_crear_solicitud(uuid,date,date,text)', 'rh_resolver_solicitud(uuid,boolean,text)',
    'rh_cancelar_solicitud(uuid)', 'rh_faltas(uuid,date,date)', 'rh_documentos_guard()', 'rh_touch_updated_at()'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon', f);
    IF f NOT IN ('rh_documentos_guard()', 'rh_touch_updated_at()', 'rh_resultado_ubicacion(text,double precision,double precision,double precision)') THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', f);
    END IF;
  END LOOP;
END $$;

-- ── 14. Almacenamiento (buckets privados) ───────────────────────────────────
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('rh-expedientes', 'rh-expedientes', false, 10485760,
        ARRAY['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
ON CONFLICT (id) DO UPDATE
  SET public = false, file_size_limit = 10485760,
      allowed_mime_types = ARRAY['application/pdf', 'image/jpeg', 'image/png', 'image/webp'];

INSERT INTO storage.buckets (id, name, public, file_size_limit)
VALUES ('rh-biblioteca', 'rh-biblioteca', false, 26214400)
ON CONFLICT (id) DO UPDATE SET public = false, file_size_limit = 26214400;

-- Expediente: ruta `<empleado_id>/<tipo>/<archivo>`. Dueño o RH; el jefe no.
DROP POLICY IF EXISTS "rh_expedientes_storage_select" ON storage.objects;
CREATE POLICY "rh_expedientes_storage_select" ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'rh-expedientes'
         AND (storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
         AND (public.rh_es_rh() OR public.rh_es_yo(((storage.foldername(name))[1])::uuid)));
DROP POLICY IF EXISTS "rh_expedientes_storage_insert" ON storage.objects;
CREATE POLICY "rh_expedientes_storage_insert" ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'rh-expedientes'
         AND (storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
         AND (public.rh_es_rh() OR public.rh_es_yo(((storage.foldername(name))[1])::uuid)));
DROP POLICY IF EXISTS "rh_expedientes_storage_delete" ON storage.objects;
CREATE POLICY "rh_expedientes_storage_delete" ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = 'rh-expedientes'
         AND (storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
         AND (public.rh_es_rh() OR public.rh_es_yo(((storage.foldername(name))[1])::uuid)));

-- Biblioteca: ruta `<documento_id>/v<n>/<archivo>`. Lee quien ve el documento; escribe RH.
DROP POLICY IF EXISTS "rh_biblioteca_storage_select" ON storage.objects;
CREATE POLICY "rh_biblioteca_storage_select" ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'rh-biblioteca'
         AND (storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
         AND public.rh_puede_ver_biblioteca(((storage.foldername(name))[1])::uuid));
DROP POLICY IF EXISTS "rh_biblioteca_storage_insert" ON storage.objects;
CREATE POLICY "rh_biblioteca_storage_insert" ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'rh-biblioteca' AND public.rh_es_rh());
DROP POLICY IF EXISTS "rh_biblioteca_storage_delete" ON storage.objects;
CREATE POLICY "rh_biblioteca_storage_delete" ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = 'rh-biblioteca' AND public.rh_es_rh());

-- ── 15. Datos iniciales (se editan desde la pantalla) ───────────────────────
INSERT INTO public.rh_areas (clave, nombre, user_area, orden) VALUES
  ('comercial',         'Comercial',           'comercial',         1),
  ('fabrica',           'Fábrica',             'fabrica',           2),
  ('almacen_logistica', 'Almacén y Logística', 'almacen_logistica', 3),
  ('administracion',    'Administración',      'administracion',    4),
  ('compras',           'Compras',             'compras',           5),
  ('direccion',         'Dirección',           'direccion',         6)
ON CONFLICT (clave) DO NOTHING;

INSERT INTO public.rh_tipos_documento (clave, nombre, ayuda, vigencia_meses, orden) VALUES
  ('ine',       'Identificación oficial',                 'INE o pasaporte vigente',            NULL, 1),
  ('curp',      'CURP',                                   NULL,                                 NULL, 2),
  ('rfc',       'RFC / Constancia de Situación Fiscal',   'CSF reciente del SAT',               NULL, 3),
  ('nss',       'Número de Seguridad Social (NSS)',       'Constancia del IMSS',                NULL, 4),
  ('domicilio', 'Comprobante de domicilio',               'No mayor a 3 meses',                 3,    5),
  ('clabe',     'Estado de cuenta / CLABE',               'Para depósito de nómina',            NULL, 6),
  ('acta',      'Acta de nacimiento',                     NULL,                                 NULL, 7),
  ('estudios',  'Comprobante de estudios',                'Certificado, título o cédula',       NULL, 8)
ON CONFLICT (clave) DO NOTHING;

INSERT INTO public.rh_tipos_solicitud (clave, nombre, descuenta_vacaciones, orden) VALUES
  ('vacaciones',  'Vacaciones',               true,  1),
  ('permiso',     'Permiso con goce',         false, 2),
  ('permiso_sg',  'Permiso sin goce',         false, 3),
  ('incapacidad', 'Incapacidad',              false, 4),
  ('home_office', 'Home office',              false, 5),
  ('otro',        'Otro',                     false, 6)
ON CONFLICT (clave) DO NOTHING;

INSERT INTO public.rh_parametros (clave, valor, descripcion) VALUES
  ('zona_horaria',    'America/Mexico_City', 'Zona horaria en que se miden horarios y retardos'),
  ('tolerancia_min',  '10',                  'Minutos de tolerancia en la entrada'),
  ('precision_max_m', '150',                 'Precisión máxima del GPS (metros) para validar la geocerca')
ON CONFLICT (clave) DO NOTHING;

INSERT INTO public.rh_biblioteca_categorias (nombre, orden) VALUES
  ('Manuales', 1), ('Políticas', 2), ('Reglamentos', 3), ('Formatos', 4)
ON CONFLICT (nombre) DO NOTHING;

-- Módulo encendible desde MATI Admin.
INSERT INTO public.app_modulos (clave, nombre, protegido)
VALUES ('rh', 'Recursos humanos', false)
ON CONFLICT (clave) DO NOTHING;

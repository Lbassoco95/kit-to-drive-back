-- ============================================================================
-- Firma electrónica SIMPLE interna (documentos de la empresa, firmantes del
-- equipo). Primer origen: PDF de remisiones de motocarro (`remisiones.documento_url`).
-- Fecha: 2026-10-16
--
-- · Solo firmantes INTERNOS (usuarios con cuenta). Clientes y proveedores no.
-- · Todo el flujo (crear, firmar, rechazar, cancelar, recordar) lo hace la Edge
--   Function `firmas` con service_role: las tablas son de solo lectura para el
--   front. El PDF firmado y la evidencia nacen en el servidor.
-- · Bucket privado `firmas`: <solicitud_id>/original.pdf, firmado.pdf, sig-<firmante>.png
-- · No es firma electrónica avanzada ni constancia NOM-151.
-- Idempotente.
-- ============================================================================

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('firmas', 'firmas', false, 15728640, ARRAY['application/pdf', 'image/png'])
ON CONFLICT (id) DO UPDATE
  SET public = false, file_size_limit = 15728640, allowed_mime_types = ARRAY['application/pdf', 'image/png'];

CREATE TABLE IF NOT EXISTS public.firmas_solicitudes (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  creado_por      UUID NOT NULL REFERENCES auth.users(id),
  titulo          TEXT NOT NULL,
  mensaje         TEXT,
  entidad_tipo    TEXT NOT NULL DEFAULT 'remision' CHECK (entidad_tipo IN ('remision')),
  entidad_id      UUID,
  nombre_archivo  TEXT NOT NULL,
  estatus         TEXT NOT NULL DEFAULT 'pendiente'
                  CHECK (estatus IN ('pendiente', 'completada', 'cancelada', 'rechazada')),
  secuencial      BOOLEAN NOT NULL DEFAULT false,
  ruta_original   TEXT NOT NULL,
  sha256_original TEXT NOT NULL,
  ruta_firmado    TEXT,
  sha256_firmado  TEXT,
  vence_at        TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '30 days'),
  completado_at   TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.firmas_solicitudes ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_firmas_solicitudes_creador ON public.firmas_solicitudes (creado_por, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_firmas_solicitudes_entidad ON public.firmas_solicitudes (entidad_tipo, entidad_id);

CREATE TABLE IF NOT EXISTS public.firmas_firmantes (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  solicitud_id      UUID NOT NULL REFERENCES public.firmas_solicitudes(id) ON DELETE CASCADE,
  orden             INTEGER NOT NULL DEFAULT 0,
  usuario_id        UUID NOT NULL REFERENCES auth.users(id),
  nombre            TEXT NOT NULL,
  email             TEXT,
  estatus           TEXT NOT NULL DEFAULT 'pendiente' CHECK (estatus IN ('pendiente', 'firmado', 'rechazado')),
  notificado_at     TIMESTAMPTZ,
  firmado_at        TIMESTAMPTZ,
  firmado_ip        TEXT,
  firmado_user_agent TEXT,
  ruta_firma        TEXT,
  motivo_rechazo    TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (solicitud_id, usuario_id)
);
ALTER TABLE public.firmas_firmantes ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_firmas_firmantes_solicitud ON public.firmas_firmantes (solicitud_id);
CREATE INDEX IF NOT EXISTS idx_firmas_firmantes_usuario ON public.firmas_firmantes (usuario_id, estatus);

-- Ayudantes SECURITY DEFINER: las dos políticas se consultan entre sí y sin
-- ellos Postgres detecta recursión infinita en RLS.
CREATE OR REPLACE FUNCTION public.firmas_es_firmante(_solicitud uuid, _user uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$ SELECT EXISTS (SELECT 1 FROM public.firmas_firmantes f WHERE f.solicitud_id = _solicitud AND f.usuario_id = _user) $$;

CREATE OR REPLACE FUNCTION public.firmas_puede_ver_solicitud(_solicitud uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT public.usuario_activo(auth.uid()) AND (
    public.es_admin_global(auth.uid())
    OR EXISTS (SELECT 1 FROM public.firmas_solicitudes s WHERE s.id = _solicitud AND s.creado_por = auth.uid())
    OR public.firmas_es_firmante(_solicitud, auth.uid())
  )
$$;

REVOKE ALL ON FUNCTION public.firmas_es_firmante(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.firmas_puede_ver_solicitud(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.firmas_puede_ver_solicitud(uuid) TO authenticated;

GRANT SELECT ON public.firmas_solicitudes, public.firmas_firmantes TO authenticated;

DROP POLICY IF EXISTS "firmas_solicitudes_select" ON public.firmas_solicitudes;
CREATE POLICY "firmas_solicitudes_select" ON public.firmas_solicitudes
  FOR SELECT TO authenticated USING (public.firmas_puede_ver_solicitud(id));

DROP POLICY IF EXISTS "firmas_firmantes_select" ON public.firmas_firmantes;
CREATE POLICY "firmas_firmantes_select" ON public.firmas_firmantes
  FOR SELECT TO authenticated USING (public.firmas_puede_ver_solicitud(solicitud_id));

-- Archivos: quien puede ver la solicitud puede pedir URL firmada del PDF.
-- Escribir/borrar en el bucket solo lo hace la función (service_role).
DROP POLICY IF EXISTS "firmas_storage_select" ON storage.objects;
CREATE POLICY "firmas_storage_select" ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'firmas'
    AND (storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    AND (storage.foldername(name))[2] IS NULL
    AND name !~ '/sig-'
    AND public.firmas_puede_ver_solicitud(((storage.foldername(name))[1])::uuid)
  );

-- Módulo encendible desde MATI Admin.
INSERT INTO public.app_modulos (clave, nombre, protegido)
VALUES ('firmas', 'Firmas electrónicas', false)
ON CONFLICT (clave) DO NOTHING;

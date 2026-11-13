-- ============================================================================
-- Adjuntar imagen o PDF a un ingreso / egreso del flujo de dinero
-- Fecha: 2026-11-13
--
-- Finanzas pidió poder adjuntar el comprobante (foto, imagen o PDF) al
-- registrar un ingreso o egreso en el flujo. El expediente de
-- `movimiento_adjuntos` solo lo ve y sube gente de Finanzas; quien registra en
-- el flujo (recepción, caja, aplicación) no necesariamente lo es. Por eso:
--   * tabla propia `flujo_adjuntos` ligada a `flujo_dinero`,
--   * permisos por capacidades del flujo (las mismas que ya leen `flujo_dinero`),
--   * archivos en el bucket privado existente `finanzas-docs`, bajo `flujo/`.
-- Idempotente. No toca tablas ni funciones existentes.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.flujo_adjuntos (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  flujo_id       uuid NOT NULL REFERENCES public.flujo_dinero(id) ON DELETE CASCADE,
  nombre_archivo text NOT NULL,
  storage_path   text NOT NULL UNIQUE,
  mime_type      text,
  tamano_bytes   bigint,
  subido_por     uuid REFERENCES auth.users(id) ON DELETE SET NULL DEFAULT auth.uid(),
  created_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT flujo_adjuntos_ruta CHECK (storage_path LIKE 'flujo/%')
);
CREATE INDEX IF NOT EXISTS idx_flujo_adjuntos_flujo ON public.flujo_adjuntos (flujo_id);

ALTER TABLE public.flujo_adjuntos ENABLE ROW LEVEL SECURITY;

-- Mismo criterio que la lectura de flujo_dinero.
DROP POLICY IF EXISTS flujo_adjuntos_select ON public.flujo_adjuntos;
CREATE POLICY flujo_adjuntos_select ON public.flujo_adjuntos FOR SELECT TO authenticated
  USING (public.flujo_es_admin() OR public.flujo_cap('recibe') OR public.flujo_cap('caja') OR public.flujo_cap('aplica'));

DROP POLICY IF EXISTS flujo_adjuntos_insert ON public.flujo_adjuntos;
CREATE POLICY flujo_adjuntos_insert ON public.flujo_adjuntos FOR INSERT TO authenticated
  WITH CHECK (subido_por = auth.uid()
    AND (public.flujo_es_admin() OR public.flujo_cap('recibe') OR public.flujo_cap('caja') OR public.flujo_cap('aplica')));

DROP POLICY IF EXISTS flujo_adjuntos_delete ON public.flujo_adjuntos;
CREATE POLICY flujo_adjuntos_delete ON public.flujo_adjuntos FOR DELETE TO authenticated
  USING (public.flujo_es_admin() OR subido_por = auth.uid());

REVOKE ALL ON public.flujo_adjuntos FROM PUBLIC, anon;
GRANT SELECT, INSERT, DELETE ON public.flujo_adjuntos TO authenticated;

-- Storage: las políticas de Finanzas ya existentes siguen igual; estas se suman
-- (se combinan con OR) y solo abarcan la carpeta `flujo/` del mismo bucket.
-- Aisladas: si no hay permiso sobre storage.objects, avisa y sigue.
DO $$
BEGIN
  DROP POLICY IF EXISTS flujo_docs_select ON storage.objects;
  CREATE POLICY flujo_docs_select ON storage.objects FOR SELECT TO authenticated
    USING (bucket_id = 'finanzas-docs' AND name LIKE 'flujo/%'
      AND (public.flujo_es_admin() OR public.flujo_cap('recibe') OR public.flujo_cap('caja') OR public.flujo_cap('aplica')));

  DROP POLICY IF EXISTS flujo_docs_insert ON storage.objects;
  CREATE POLICY flujo_docs_insert ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'finanzas-docs' AND name LIKE 'flujo/%'
      AND (public.flujo_es_admin() OR public.flujo_cap('recibe') OR public.flujo_cap('caja') OR public.flujo_cap('aplica')));

  DROP POLICY IF EXISTS flujo_docs_delete ON storage.objects;
  CREATE POLICY flujo_docs_delete ON storage.objects FOR DELETE TO authenticated
    USING (bucket_id = 'finanzas-docs' AND name LIKE 'flujo/%'
      AND (public.flujo_es_admin() OR owner = auth.uid()));
EXCEPTION
  WHEN insufficient_privilege OR undefined_table THEN
    RAISE NOTICE 'PENDIENTE MANUAL: crea en Storage → Policies, para «finanzas-docs» y la carpeta flujo/, lectura, subida y borrado para quien tenga capacidad del flujo.';
END $$;

DO $postflight$
BEGIN
  IF to_regclass('public.flujo_adjuntos') IS NULL THEN
    RAISE EXCEPTION 'flujo_adjuntos no se creó.';
  END IF;
  IF has_table_privilege('anon', 'public.flujo_adjuntos', 'select') THEN
    RAISE EXCEPTION 'flujo_adjuntos no debe estar abierta a anon.';
  END IF;
END $postflight$;

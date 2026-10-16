-- ============================================================================
-- Firmas electrónicas: documentos subidos directamente + lugar de la firma
-- Fecha: 2026-10-16
--
-- 1. `firmas_solicitudes.entidad_tipo` acepta 'documento' (PDF o Word convertido
--    a PDF que alguien sube desde la pantalla Firmas, sin remisión de por medio).
-- 2. `firmas_firmantes.recuadros`: dónde firma cada persona. Lista de
--    {page, x, y, w, h} con coordenadas normalizadas 0..1 (origen arriba-izquierda,
--    page desde 1). Vacía = la firma va solo en la hoja de firmas del final.
-- Idempotente.
-- ============================================================================

ALTER TABLE public.firmas_solicitudes DROP CONSTRAINT IF EXISTS firmas_solicitudes_entidad_tipo_check;
ALTER TABLE public.firmas_solicitudes
  ADD CONSTRAINT firmas_solicitudes_entidad_tipo_check CHECK (entidad_tipo IN ('remision', 'documento'));

ALTER TABLE public.firmas_firmantes
  ADD COLUMN IF NOT EXISTS recuadros JSONB NOT NULL DEFAULT '[]'::jsonb;

-- ============================================================================
-- Firmas: quien puede ver la solicitud también puede ver la imagen de cada firma
-- Fecha: 2026-10-26
--
-- De qué se trata
-- ---------------
-- La política `firmas_storage_select` (20261016000001) deja leer solo los PDF
-- del bucket `firmas`: excluye `<solicitud>/sig-<firmante>.png`. Dirección pidió
-- ver la firma de cada persona en la solicitud, así que se agrega una política
-- ADITIVA solo para esas imágenes. No se toca la política de los PDF.
--
-- Quién las ve: las mismas personas que ven la solicitud
-- (`firmas_puede_ver_solicitud`): quien la creó, los firmantes y Dirección admin.
-- Escribir o borrar en el bucket sigue siendo solo de la Edge Function.
--
-- REVERSA:
--   DROP POLICY IF EXISTS "firmas_storage_select_firmas" ON storage.objects;
--
-- ADVERTENCIA: idempotente, para el SQL editor de Supabase. NO usar
-- `supabase db push`.
-- ============================================================================

DROP POLICY IF EXISTS "firmas_storage_select_firmas" ON storage.objects;
CREATE POLICY "firmas_storage_select_firmas" ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'firmas'
    AND (storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    AND (storage.foldername(name))[2] IS NULL
    AND name ~ '/sig-[0-9a-f-]+\.png$'
    AND public.firmas_puede_ver_solicitud(((storage.foldername(name))[1])::uuid)
  );

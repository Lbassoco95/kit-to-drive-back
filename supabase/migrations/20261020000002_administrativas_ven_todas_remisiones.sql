-- ============================================================================
-- Administrativas de Comercial ven las remisiones completas de todo el equipo
-- Fecha: 2026-10-20
--
-- Atenea y Ana Karen (administrativas de ventas, `profiles.es_administrativo`)
-- son operadoras de Comercial, así que desde 20261007000001 sólo veían las
-- remisiones donde ellas eran el vendedor. Necesitan revisar y dar seguimiento
-- a todas: remisión, partidas, unidades (motocarros), bitácora, cliente y sus
-- documentos (PDF de la remisión, comprobante de pago, factura).
--
-- Se resuelve con la bandera que ya existe (Usuarios → «Administrativo»), no
-- con correos: quien tenga esa casilla en el área comercial ve todo lo de
-- remisiones; al quitarla vuelve a ver sólo lo suyo.
--
-- Sólo LECTURA y ADITIVO: no toca las políticas existentes ni quién puede
-- editar (eso sigue en puede_editar_remision / remisiones_asignacion_acceso).
-- Partidas, bitácora, documentos del cliente y cartera ya siguen a la
-- visibilidad de `remisiones` / `clientes`, así que se abren solos.
-- Las remisiones de refacciones ya las ve toda el área comercial
-- (puede_leer_remision_refaccion).
--
-- Para retirarlo: DROP de las 4 políticas «administrativo comercial …» y de la
-- función es_administrativo_comercial(uuid).
--
-- ADVERTENCIA: idempotente, para el SQL editor de Supabase. NO usar
-- `supabase db push`.
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := '{}';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public' AND table_name = 'profiles'
                    AND column_name = 'es_administrativo') THEN
    _faltan := _faltan || 'columna profiles.es_administrativo (20261014000002)'::text;
  END IF;
  IF to_regprocedure('public.usuario_activo(uuid)') IS NULL THEN _faltan := _faltan || 'función usuario_activo (20260824000003)'::text; END IF;
  IF to_regprocedure('public.es_area(uuid,public.user_area)') IS NULL THEN _faltan := _faltan || 'función es_area (20260823000005)'::text; END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ', ');
  END IF;
END;
$preflight$;

-- ── 1. Helper ───────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.es_administrativo_comercial(_user_id uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT _user_id IS NOT NULL
     AND public.usuario_activo(_user_id)
     AND public.es_area(_user_id, 'comercial'::public.user_area)
     AND EXISTS (SELECT 1 FROM public.profiles p
                  WHERE p.id = _user_id AND p.es_administrativo);
$$;

COMMENT ON FUNCTION public.es_administrativo_comercial(uuid) IS
  'Administrativo(a) activo(a) del área comercial (profiles.es_administrativo): lee todas las remisiones de motocarro, sus unidades, clientes y documentos.';

REVOKE ALL ON FUNCTION public.es_administrativo_comercial(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.es_administrativo_comercial(uuid) TO authenticated, service_role;

-- ── 2. Remisiones (partidas y bitácora la siguen por EXISTS) ────────────────
DROP POLICY IF EXISTS "administrativo comercial lee remisiones" ON public.remisiones;
CREATE POLICY "administrativo comercial lee remisiones" ON public.remisiones
  FOR SELECT TO authenticated
  USING (public.es_administrativo_comercial(auth.uid()));

-- ── 3. Unidades (motocarros) de las remisiones ──────────────────────────────
DROP POLICY IF EXISTS "administrativo comercial lee motocarros" ON public.motocarros;
CREATE POLICY "administrativo comercial lee motocarros" ON public.motocarros
  FOR SELECT TO authenticated
  USING (remision_id IS NOT NULL AND public.es_administrativo_comercial(auth.uid()));

-- ── 4. Clientes (documentos del cliente y cartera la siguen por EXISTS) ─────
DROP POLICY IF EXISTS "administrativo comercial lee clientes" ON public.clientes;
CREATE POLICY "administrativo comercial lee clientes" ON public.clientes
  FOR SELECT TO authenticated
  USING (public.es_administrativo_comercial(auth.uid()));

-- ── 5. Documentos de remisiones (PDF, comprobante, factura) ─────────────────
DROP POLICY IF EXISTS "administrativo comercial lee docs remisiones" ON storage.objects;
CREATE POLICY "administrativo comercial lee docs remisiones" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'remisiones-docs' AND public.es_administrativo_comercial(auth.uid()));

-- ── Verificación (solo lectura) ─────────────────────────────────────────────
-- Debe listar a Atenea y Ana Karen con ve_todas_remisiones = true:
--
-- SELECT p.email, p.nombre_completo, ur.area, ur.nivel, p.es_administrativo,
--        public.es_administrativo_comercial(p.id) AS ve_todas_remisiones
--   FROM public.profiles p
--   LEFT JOIN public.user_roles ur ON ur.user_id = p.id
--  WHERE p.es_administrativo OR lower(p.email) IN ('athenea.portilla@dazon.mx', 'ana.rivas@dazon.mx');

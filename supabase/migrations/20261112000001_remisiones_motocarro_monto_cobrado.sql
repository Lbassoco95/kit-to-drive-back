-- ============================================================================
-- Remisiones de motocarro: monto cobrado y fecha de cobro
-- ============================================================================
-- Motivo: el reporte de ventas que pide Peter mide las ventas POR COBRO y suma
-- los pesos de motocarros. Hasta hoy `remisiones` sólo guarda `pagado`
-- (sí/no), sin importe. Estas dos columnas lo resuelven:
--   · monto_cobrado  importe en MXN cobrado por la remisión.
--   · fecha_cobro    día en que se cobró (anticipado: la fecha de la remisión;
--                    contra entrega o crédito: el día en que se confirma el pago).
--
-- Sólo AGREGA: no modifica ni borra datos. Las remisiones anteriores quedan con
-- monto NULL («sin monto») hasta capturarlo; el reporte las señala.
-- Idempotente, para el SQL editor de Supabase. NO usar `supabase db push`.
--
-- Para revertir:
--   DROP TRIGGER IF EXISTS trg_remisiones_fecha_cobro ON public.remisiones;
--   DROP FUNCTION IF EXISTS public.trg_remisiones_fecha_cobro();
--   ALTER TABLE public.remisiones DROP COLUMN IF EXISTS monto_cobrado, DROP COLUMN IF EXISTS fecha_cobro;
-- ============================================================================

DO $preflight$
BEGIN
  IF to_regclass('public.remisiones') IS NULL THEN
    RAISE EXCEPTION 'No se modificó nada. Falta la tabla remisiones.';
  END IF;
END $preflight$;

ALTER TABLE public.remisiones
  ADD COLUMN IF NOT EXISTS monto_cobrado numeric(14, 2),
  ADD COLUMN IF NOT EXISTS fecha_cobro date;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'remisiones_monto_cobrado_check') THEN
    ALTER TABLE public.remisiones
      ADD CONSTRAINT remisiones_monto_cobrado_check CHECK (monto_cobrado IS NULL OR monto_cobrado >= 0);
  END IF;
END $$;

-- La fecha de cobro se completa sola cuando la remisión pasa a pagada.
CREATE OR REPLACE FUNCTION public.trg_remisiones_fecha_cobro()
RETURNS trigger
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.pagado AND NEW.fecha_cobro IS NULL
     AND (TG_OP = 'INSERT' OR OLD.pagado IS DISTINCT FROM true) THEN
    NEW.fecha_cobro := CASE WHEN NEW.tipo_pago = 'anticipado'
                            THEN coalesce(NEW.fecha_remision, CURRENT_DATE)
                            ELSE CURRENT_DATE END;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.trg_remisiones_fecha_cobro() FROM PUBLIC, anon;

DROP TRIGGER IF EXISTS trg_remisiones_fecha_cobro ON public.remisiones;
CREATE TRIGGER trg_remisiones_fecha_cobro
  BEFORE INSERT OR UPDATE OF pagado ON public.remisiones
  FOR EACH ROW EXECUTE FUNCTION public.trg_remisiones_fecha_cobro();

CREATE INDEX IF NOT EXISTS idx_remisiones_fecha_cobro ON public.remisiones (fecha_cobro) WHERE pagado;

DO $postflight$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public' AND table_name = 'remisiones' AND column_name IN ('monto_cobrado')) THEN
    RAISE EXCEPTION 'remisiones.monto_cobrado no se creó.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public' AND table_name = 'remisiones' AND column_name = 'fecha_cobro') THEN
    RAISE EXCEPTION 'remisiones.fecha_cobro no se creó.';
  END IF;
END $postflight$;

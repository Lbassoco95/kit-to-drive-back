-- ============================================================================
-- Remisiones: quién la cargó (y cuándo)
--
-- Para darle seguimiento a una remisión mal capturada hay que saber quién la
-- cargó. La fecha y hora ya existen (created_at); falta la persona:
--   · public.remisiones             → created_by + nombre_creador (no existían)
--   · public.remisiones_refacciones → nombre_creador (created_by ya existía)
--
-- Se llenan en la base con un disparador, no desde la pantalla, para que no
-- dependa de qué vista la creó ni se pueda falsear. Una vez escritos no se
-- pueden cambiar (queda como evidencia). Las remisiones anteriores a este
-- cambio no tienen creador registrado y quedan en NULL; las de refacciones se
-- completan con created_by.
-- Idempotente. No toca otras columnas, políticas ni funciones.
-- ============================================================================

ALTER TABLE public.remisiones
  ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES public.profiles(id),
  ADD COLUMN IF NOT EXISTS nombre_creador TEXT;

ALTER TABLE public.remisiones_refacciones
  ADD COLUMN IF NOT EXISTS nombre_creador TEXT;

-- Completar las de refacciones que ya tienen created_by (antes de blindar).
UPDATE public.remisiones_refacciones r
   SET nombre_creador = p.nombre_completo
  FROM public.profiles p
 WHERE p.id = r.created_by AND r.nombre_creador IS NULL;

CREATE OR REPLACE FUNCTION public.remision_sellar_creador()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.created_by := coalesce(NEW.created_by, auth.uid());
    IF NEW.created_by IS NOT NULL THEN
      SELECT p.nombre_completo INTO NEW.nombre_creador
        FROM public.profiles p WHERE p.id = NEW.created_by;
    ELSE
      NEW.nombre_creador := NULL;
    END IF;
  ELSE
    -- Evidencia: quién cargó la remisión no se reescribe.
    NEW.created_by := OLD.created_by;
    NEW.nombre_creador := OLD.nombre_creador;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_remisiones_sellar_creador ON public.remisiones;
CREATE TRIGGER trg_remisiones_sellar_creador
  BEFORE INSERT OR UPDATE ON public.remisiones
  FOR EACH ROW EXECUTE FUNCTION public.remision_sellar_creador();

DROP TRIGGER IF EXISTS trg_remisiones_refacciones_sellar_creador ON public.remisiones_refacciones;
CREATE TRIGGER trg_remisiones_refacciones_sellar_creador
  BEFORE INSERT OR UPDATE ON public.remisiones_refacciones
  FOR EACH ROW EXECUTE FUNCTION public.remision_sellar_creador();

NOTIFY pgrst, 'reload schema';

-- Entregas: remisiones de refacciones con fecha programada ---------------------
-- La pantalla Entregas solo mostraba motocarros. Logística ahora programa ahí
-- también la entrega de las remisiones de refacciones surtidas o en logística.
-- La marca de entregada sigue siendo `entregar_remision_refaccion`.
--
-- Requiere 20260925000001_remision_refacciones_seguimiento.sql. Se puede correr dos veces.

ALTER TABLE public.remisiones_refacciones
  ADD COLUMN IF NOT EXISTS fecha_entrega_programada DATE;

CREATE OR REPLACE FUNCTION public.programar_entrega_remision_refaccion(
  _remision_id UUID,
  _fecha DATE
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.remisiones_refacciones%ROWTYPE;
BEGIN
  IF NOT public.puede_operar_logistica_refacciones() THEN
    RAISE EXCEPTION 'Sólo logística puede programar la entrega';
  END IF;
  IF _fecha IS NULL THEN
    RAISE EXCEPTION 'Indica la fecha de entrega';
  END IF;
  SELECT * INTO v_row FROM public.remisiones_refacciones WHERE id = _remision_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró la remisión';
  END IF;
  IF v_row.etapa NOT IN ('surtida', 'logistica') THEN
    RAISE EXCEPTION 'Sólo se programa una remisión surtida o en logística';
  END IF;

  UPDATE public.remisiones_refacciones
  SET fecha_entrega_programada = _fecha
  WHERE id = _remision_id;

  INSERT INTO public.remision_refaccion_eventos (remision_id, etapa, area, accion, detalle, usuario_id)
  VALUES (
    _remision_id, v_row.etapa, 'logistica', 'programar_entrega',
    'Logística programó la entrega para el ' || to_char(_fecha, 'DD/MM/YYYY') || '.',
    auth.uid()
  );
END;
$$;

REVOKE ALL ON FUNCTION public.programar_entrega_remision_refaccion(UUID, DATE) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.programar_entrega_remision_refaccion(UUID, DATE) FROM anon;
GRANT EXECUTE ON FUNCTION public.programar_entrega_remision_refaccion(UUID, DATE) TO authenticated;

-- Verificación:
-- SELECT column_name FROM information_schema.columns
--  WHERE table_schema = 'public' AND table_name = 'remisiones_refacciones' AND column_name = 'fecha_entrega_programada';
-- SELECT to_regprocedure('public.programar_entrega_remision_refaccion(uuid,date)');

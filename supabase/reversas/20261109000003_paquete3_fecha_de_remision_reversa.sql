-- REVERSA de 20261109000003: quita el control de la fecha de remisión. Vuelve a poder cambiarse la fecha como antes
-- (con la edición normal de la remisión). Se BORRA la tabla `remision_fecha_cambios` (el historial de cambios hechos con
-- la función se pierde: exportarlo antes si ya se usó) y los avisos ya creados en `avisos` se quedan.
DROP TRIGGER IF EXISTS trg_remisiones_fecha_solo_funcion ON public.remisiones;
DROP TRIGGER IF EXISTS trg_remisiones_refacciones_fecha_solo_funcion ON public.remisiones_refacciones;
DROP FUNCTION IF EXISTS public.cambiar_fecha_remision(text, uuid, date, text);
DROP FUNCTION IF EXISTS public.remision_fecha_solo_por_funcion();
DROP TABLE IF EXISTS public.remision_fecha_cambios;
SELECT (SELECT count(*) FROM pg_trigger WHERE tgname IN ('trg_remisiones_fecha_solo_funcion', 'trg_remisiones_refacciones_fecha_solo_funcion')) AS triggers_que_quedan,
       (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname IN ('cambiar_fecha_remision', 'remision_fecha_solo_por_funcion')) AS funciones_que_quedan,
       to_regclass('public.remision_fecha_cambios') IS NOT NULL AS tabla_que_queda;

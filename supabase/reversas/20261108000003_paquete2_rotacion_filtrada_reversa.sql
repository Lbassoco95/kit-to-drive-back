-- REVERSA de 20261108000003: quita la rotación filtrada. `resumen_rotacion_refacciones` (original) no se toca.
DROP FUNCTION IF EXISTS public.resumen_rotacion_refacciones_filtrado(date, date, boolean, uuid[], text);
SELECT count(*) AS funcion_que_queda FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'resumen_rotacion_refacciones_filtrado';

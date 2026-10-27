-- REVERSA de 20261108000002: quita el kárdex de varios artículos. `kardex_refaccion` (un artículo) no se toca.
DROP FUNCTION IF EXISTS public.kardex_refacciones_multi(uuid[], date, date, text);
SELECT count(*) AS funcion_que_queda FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'kardex_refacciones_multi';

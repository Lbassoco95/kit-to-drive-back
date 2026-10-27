-- REVERSA de 20261108000001: quita el reporte de ventas de refacciones. La pantalla que lo use debe volver
-- a la versión anterior antes de revertir.
DROP FUNCTION IF EXISTS public.reporte_ventas_refacciones(date, date, text[], uuid[], uuid[], boolean);
SELECT count(*) AS funcion_que_queda FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'reporte_ventas_refacciones';

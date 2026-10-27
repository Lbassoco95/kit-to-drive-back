-- REVERSA de 20261108000004: quita los totales del reporte de ventas. `reporte_ventas_refacciones` (filas) no se toca.
-- El front que use los totales debe volver a la versión anterior antes de revertir (o la tarjeta de remisiones quedaría sin dato).
DROP FUNCTION IF EXISTS public.reporte_ventas_refacciones_totales(date, date, text[], uuid[], uuid[], boolean);
SELECT count(*) AS funcion_que_queda FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'reporte_ventas_refacciones_totales';

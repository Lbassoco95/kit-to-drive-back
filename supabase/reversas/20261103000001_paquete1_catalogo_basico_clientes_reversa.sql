-- REVERSA de 20261103000001: quita el catálogo básico de clientes. El front que lo use (selectores de CRM)
-- debe volver a la versión anterior antes de revertir, o los selectores quedarán vacíos.
DROP FUNCTION IF EXISTS public.catalogo_clientes_basico();
SELECT count(*) AS funcion_que_queda FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'catalogo_clientes_basico';

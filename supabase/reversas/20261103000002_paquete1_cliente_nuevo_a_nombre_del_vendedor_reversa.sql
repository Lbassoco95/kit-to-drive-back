-- REVERSA de 20261103000002: quita los 2 triggers y las 3 funciones. No deshace los clientes que ya quedaron a nombre
-- de un vendedor al crearse (son datos); un supervisor puede reasignarlos en Clientes.
DROP TRIGGER IF EXISTS trg_remisiones_validar_cliente ON public.remisiones;
DROP TRIGGER IF EXISTS trg_clientes_asignar_vendedor ON public.clientes;
DROP FUNCTION IF EXISTS public.remisiones_validar_cliente_visible();
DROP FUNCTION IF EXISTS public.clientes_asignar_vendedor_al_crear();
DROP FUNCTION IF EXISTS public.es_vendedor_comercial(uuid);
SELECT
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname IN ('es_vendedor_comercial', 'clientes_asignar_vendedor_al_crear', 'remisiones_validar_cliente_visible')) AS funciones_que_quedan,
  (SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal AND tgname IN ('trg_clientes_asignar_vendedor', 'trg_remisiones_validar_cliente')) AS triggers_que_quedan;

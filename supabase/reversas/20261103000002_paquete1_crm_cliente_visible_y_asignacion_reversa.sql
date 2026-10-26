-- REVERSA de 20261103000002: quita los triggers y las 4 funciones del Paquete 1 (parte 2).
-- No deshace las asignaciones de cliente que los triggers ya hicieron (son datos): quedan anotadas en
-- clientes_bitacora con tipo_cambio = 'asignacion_automatica' por si hubiera que revisarlas.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['crm_oportunidades', 'crm_actividades', 'crm_ruta_paradas'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_crm_a_validar_cliente ON public.%I', t);
    EXECUTE format('DROP TRIGGER IF EXISTS trg_crm_b_asignar_cliente ON public.%I', t);
  END LOOP;
END $$;
DROP TRIGGER IF EXISTS trg_clientes_asignar_vendedor ON public.clientes;
DROP FUNCTION IF EXISTS public.crm_asignar_cliente_al_usar();
DROP FUNCTION IF EXISTS public.crm_validar_cliente_visible();
DROP FUNCTION IF EXISTS public.clientes_asignar_vendedor_al_crear();
DROP FUNCTION IF EXISTS public.es_vendedor_comercial(uuid);
SELECT
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname IN ('es_vendedor_comercial', 'clientes_asignar_vendedor_al_crear',
          'crm_validar_cliente_visible', 'crm_asignar_cliente_al_usar')) AS funciones_que_quedan,
  (SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal AND tgname IN
          ('trg_clientes_asignar_vendedor', 'trg_crm_a_validar_cliente', 'trg_crm_b_asignar_cliente')) AS triggers_que_quedan;

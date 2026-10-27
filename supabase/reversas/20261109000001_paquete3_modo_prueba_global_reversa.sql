-- REVERSA de 20261109000001: quita el interruptor global de modo prueba. Revertir ANTES la eliminación de remisiones
-- (20261109000002), que lo exige. Se borra la fila de `compras_parametros` (el trigger se quita primero).
DROP TRIGGER IF EXISTS trg_proteger_modo_prueba_global ON public.compras_parametros;
DELETE FROM public.compras_parametros WHERE clave = 'modo_prueba_global';
DROP FUNCTION IF EXISTS public.fijar_modo_prueba_global(boolean, text);
DROP FUNCTION IF EXISTS public.modo_prueba_global_activo();
DROP FUNCTION IF EXISTS public.proteger_modo_prueba_global();
SELECT (SELECT count(*) FROM public.compras_parametros WHERE clave = 'modo_prueba_global') AS fila_que_queda,
       (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public' AND p.proname IN ('modo_prueba_global_activo', 'fijar_modo_prueba_global', 'proteger_modo_prueba_global')) AS funciones_que_quedan;

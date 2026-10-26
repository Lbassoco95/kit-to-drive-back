-- ============================================================================
-- REVERSA: devuelve las dos funciones de cartera vencida a SECURITY DEFINER (25 oct 2026)
--
-- Fase 2 de seguridad (docs/seguridad/). Reversa del cambio 4. Idempotente.
-- ============================================================================
ALTER FUNCTION public.cliente_tiene_cxc_vencidas(uuid) SECURITY DEFINER;
ALTER FUNCTION public.cxc_vencidas_resumen(uuid) SECURITY DEFINER;

-- Verificación: debe salir true, true.
SELECT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.cliente_tiene_cxc_vencidas(uuid)'::regprocedure) AS definer_1,
       (SELECT prosecdef FROM pg_proc WHERE oid = 'public.cxc_vencidas_resumen(uuid)'::regprocedure) AS definer_2;

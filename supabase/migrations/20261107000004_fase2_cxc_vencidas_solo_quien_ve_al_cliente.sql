-- ============================================================================
-- Cuentas por cobrar vencidas: solo quien puede ver al cliente
--
-- Fase 2 de seguridad de la base de producción (docs/seguridad/). Cambio 4 de 4.
-- ============================================================================
--
-- cliente_tiene_cxc_vencidas(uuid) y cxc_vencidas_resumen(uuid) son SECURITY DEFINER sin
-- ninguna verificación: cualquier usuario con sesión consulta las vencidas de cualquier
-- cliente (hallazgo S2). La tabla cuentas_por_cobrar sí está protegida: su política
-- cxc_select deja leer una cuenta solo si el usuario puede ver al cliente (RLS de clientes).
--
-- Se pasan a SECURITY INVOKER: las dos funciones leen cuentas_por_cobrar con los permisos
-- de quien llama, así que responden exactamente a lo que esa persona ya puede leer
-- (mismo criterio que la tabla, sin una segunda regla que mantener).
--
-- Quién las usa (código del front): solo evaluarBloqueoPorCartera() en
-- src/lib/creditoDb.ts, desde Remisiones (alta y edición de una remisión): comercial,
-- administración y quien ve al cliente. NO son solo finanzas: restringirlas a finanzas
-- haría que un vendedor reciba error y el front (que falla abierto) deje de bloquear
-- remisiones a clientes con cartera vencida. Con INVOKER, el vendedor ve la cartera de
-- SUS clientes (los que ya ve) y nada más.
--
-- No cambia el resultado para nadie que hoy las use legítimamente (todos ven al cliente).
-- Idempotente. Reversa: supabase/reversas/20261107000004_fase2_cxc_vencidas_solo_quien_ve_al_cliente_reversa.sql
-- ============================================================================
ALTER FUNCTION public.cliente_tiene_cxc_vencidas(uuid) SECURITY INVOKER;
ALTER FUNCTION public.cxc_vencidas_resumen(uuid) SECURITY INVOKER;

-- Verificación: debe salir false, false (ya no son SECURITY DEFINER).
SELECT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.cliente_tiene_cxc_vencidas(uuid)'::regprocedure) AS definer_1,
       (SELECT prosecdef FROM pg_proc WHERE oid = 'public.cxc_vencidas_resumen(uuid)'::regprocedure) AS definer_2;

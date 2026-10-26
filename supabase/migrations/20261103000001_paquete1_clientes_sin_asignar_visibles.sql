-- ============================================================================
-- PAQUETE 1 (permisos del vendedor) · 1 de 3: el vendedor ve los clientes sin vendedor asignado
--
-- Síntoma (Martin, Dazon): un vendedor de Comercial/Operador ve «0 de 0 clientes» y al crear
-- una oportunidad «No hay clientes en el catálogo». Causa: la política «leer clientes»
-- (20261007000002) deja al vendedor ver solo los clientes con vendedor_id = él, o los de sus
-- propias remisiones. Si no tiene ninguno asignado no ve ninguno, y la base tiene 1,786.
--
-- Cambio: el vendedor ve también los clientes SIN vendedor asignado (vendedor_id IS NULL).
-- Nunca ve los asignados a otro vendedor, salvo la cláusula que ya existía (los clientes de
-- sus propias remisiones): ver docs/mejoras/PAQUETE-1-PERMISOS-VENDEDOR.md, decisión D1.
-- Todo lo demás de la política queda idéntico. Los comentarios, la bitácora, los documentos y
-- la cartera del cliente siguen a esta política por EXISTS, así que se alinean solos.
--
-- Una sola política cambiada (301 políticas antes y después). Idempotente.
-- Reversa: supabase/reversas/20261103000001_paquete1_clientes_sin_asignar_visibles_reversa.sql
-- ============================================================================
DROP POLICY IF EXISTS "leer clientes" ON public.clientes;
CREATE POLICY "leer clientes" ON public.clientes
FOR SELECT TO authenticated
USING (
  public.es_admin_global(auth.uid())
  OR public.ve_todo_comercial(auth.uid())
  OR public.es_area(auth.uid(), 'fabrica'::public.user_area)
  OR public.es_area(auth.uid(), 'almacen_logistica'::public.user_area)
  OR public.es_area(auth.uid(), 'administracion'::public.user_area)
  OR public.es_area(auth.uid(), 'compras'::public.user_area)
  OR public.es_area(auth.uid(), 'direccion'::public.user_area)
  OR public.has_role(auth.uid(), 'admin'::app_role)
  OR public.has_role(auth.uid(), 'fabrica'::app_role)
  OR public.has_role(auth.uid(), 'logistica'::app_role)
  OR public.has_role(auth.uid(), 'coordinador'::app_role)
  OR public.has_role(auth.uid(), 'finanzas'::app_role)
  OR public.has_role(auth.uid(), 'admin_financiero'::app_role)
  OR public.has_role(auth.uid(), 'compras'::app_role)
  OR (
    (public.es_area(auth.uid(), 'comercial'::public.user_area)
      OR public.has_role(auth.uid(), 'ventas'::app_role))
    AND public.usuario_activo(auth.uid())
    AND (
      vendedor_id = auth.uid()
      OR vendedor_id IS NULL
      OR EXISTS (SELECT 1 FROM public.remisiones r
                  WHERE r.cliente_id = clientes.id AND r.vendedor_id = auth.uid())
    )
  )
);

-- Verificación: la política existe, es SELECT y menciona «vendedor_id IS NULL»; el total sigue en 301.
SELECT
  (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND tablename = 'clientes'
     AND policyname = 'leer clientes' AND cmd = 'SELECT' AND qual ILIKE '%vendedor_id IS NULL%') AS politica_con_sin_asignar,
  (SELECT count(*) FROM pg_policies WHERE schemaname = 'public') AS politicas_public;

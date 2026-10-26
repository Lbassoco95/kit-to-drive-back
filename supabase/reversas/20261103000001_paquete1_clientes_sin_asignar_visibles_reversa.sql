-- REVERSA de 20261103000001: la política «leer clientes» vuelve a como estaba el 26 oct 2026 (20261007000002):
-- el vendedor ve solo los clientes asignados a él y los de sus propias remisiones.
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
      OR EXISTS (SELECT 1 FROM public.remisiones r
                  WHERE r.cliente_id = clientes.id AND r.vendedor_id = auth.uid())
    )
  )
);
SELECT count(*) AS politica_sin_asignar_ya_no_esta
  FROM pg_policies WHERE schemaname = 'public' AND tablename = 'clientes' AND policyname = 'leer clientes' AND qual ILIKE '%vendedor_id IS NULL%';

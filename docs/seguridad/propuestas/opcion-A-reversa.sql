-- Reversa de la propuesta Opción A: deja las políticas con el texto de producción del 26 oct 2026.
BEGIN;
DROP POLICY IF EXISTS "Usuarios autenticados pueden insertar en bitácora" ON public.clientes_bitacora;
CREATE POLICY "Usuarios autenticados pueden insertar en bitácora" ON public.clientes_bitacora FOR INSERT TO public WITH CHECK (auth.uid() = usuario_id);
DROP POLICY IF EXISTS "Usuarios autenticados pueden insertar comentarios" ON public.clientes_comentarios;
CREATE POLICY "Usuarios autenticados pueden insertar comentarios" ON public.clientes_comentarios FOR INSERT TO public WITH CHECK (auth.uid() = usuario_id);
DROP POLICY IF EXISTS "registrar cambio de remision" ON public.remisiones_bitacora;
CREATE POLICY "registrar cambio de remision" ON public.remisiones_bitacora FOR INSERT TO authenticated WITH CHECK (usuario_id = auth.uid());
DROP POLICY IF EXISTS "mandar aviso" ON public.avisos;
CREATE POLICY "mandar aviso" ON public.avisos FOR INSERT TO authenticated WITH CHECK (creado_por = auth.uid());
DROP POLICY IF EXISTS "mencionar usuario" ON public.notificaciones;
CREATE POLICY "mencionar usuario" ON public.notificaciones FOR INSERT TO authenticated WITH CHECK (creado_por = auth.uid());
DROP POLICY IF EXISTS "motivos_ajuste_leer" ON public.inventario_motivos_ajuste;
CREATE POLICY "motivos_ajuste_leer" ON public.inventario_motivos_ajuste FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS "reglas_modo_prueba_leer" ON public.inventario_reglas_modo_prueba;
CREATE POLICY "reglas_modo_prueba_leer" ON public.inventario_reglas_modo_prueba FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS "unidades_venta_leer" ON public.inventario_unidades_venta;
CREATE POLICY "unidades_venta_leer" ON public.inventario_unidades_venta FOR SELECT TO authenticated USING (true);
COMMIT;

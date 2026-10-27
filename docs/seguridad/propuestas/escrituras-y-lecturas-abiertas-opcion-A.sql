-- ============================================================================
-- PROPUESTA (NO APLICADA, NO ES UNA MIGRACIÓN): cerrar las políticas de escritura sin rol y las tres de lectura abiertas
-- Opción A. Revisada en la réplica local (docs/seguridad/MATRIZ-ACCION-POR-ROL.md). Reversa: opcion-A-reversa.sql
-- ============================================================================
-- Escritura: «ser yo» deja de bastar. Hace falta además una cuenta activa con rol (usuario_operativo) y, donde hay
-- un registro padre, que el padre sea visible para quien escribe (el EXISTS se evalúa con la seguridad por filas de quien llama).
BEGIN;

DROP POLICY IF EXISTS "Usuarios autenticados pueden insertar en bitácora" ON public.clientes_bitacora;
CREATE POLICY "Usuarios autenticados pueden insertar en bitácora" ON public.clientes_bitacora FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = usuario_id AND public.usuario_operativo(auth.uid())
              AND EXISTS (SELECT 1 FROM public.clientes c WHERE c.id = clientes_bitacora.cliente_id));

DROP POLICY IF EXISTS "Usuarios autenticados pueden insertar comentarios" ON public.clientes_comentarios;
CREATE POLICY "Usuarios autenticados pueden insertar comentarios" ON public.clientes_comentarios FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = usuario_id AND public.usuario_operativo(auth.uid())
              AND EXISTS (SELECT 1 FROM public.clientes c WHERE c.id = clientes_comentarios.cliente_id));

DROP POLICY IF EXISTS "registrar cambio de remision" ON public.remisiones_bitacora;
CREATE POLICY "registrar cambio de remision" ON public.remisiones_bitacora FOR INSERT TO authenticated
  WITH CHECK (usuario_id = auth.uid() AND public.usuario_operativo(auth.uid())
              AND EXISTS (SELECT 1 FROM public.remisiones r WHERE r.id = remisiones_bitacora.remision_id));

-- El front nunca inserta en avisos (solo los marca como vistos) y las 8 funciones que los crean son SECURITY DEFINER.
DROP POLICY IF EXISTS "mandar aviso" ON public.avisos;

DROP POLICY IF EXISTS "mencionar usuario" ON public.notificaciones;
CREATE POLICY "mencionar usuario" ON public.notificaciones FOR INSERT TO authenticated
  WITH CHECK (creado_por = auth.uid() AND public.usuario_operativo(auth.uid()));

-- Lectura: las tres tablas con USING (true) pasan a pedir una cuenta activa con rol, como las demás del mismo grupo.
DROP POLICY IF EXISTS "motivos_ajuste_leer" ON public.inventario_motivos_ajuste;
CREATE POLICY "motivos_ajuste_leer" ON public.inventario_motivos_ajuste FOR SELECT TO authenticated USING (public.usuario_operativo(auth.uid()));
DROP POLICY IF EXISTS "reglas_modo_prueba_leer" ON public.inventario_reglas_modo_prueba;
CREATE POLICY "reglas_modo_prueba_leer" ON public.inventario_reglas_modo_prueba FOR SELECT TO authenticated USING (public.usuario_operativo(auth.uid()));
DROP POLICY IF EXISTS "unidades_venta_leer" ON public.inventario_unidades_venta;
CREATE POLICY "unidades_venta_leer" ON public.inventario_unidades_venta FOR SELECT TO authenticated USING (public.usuario_operativo(auth.uid()));
COMMIT;

-- Políticas de seguridad por filas de public y storage (la Fase 1 no las cambia)
-- Proyecto Supabase: kit-to-drive (dmhzhyeivvuliumcgsmm), producción.
-- Capturado: 2026-10-25 19:14 UTC, solo lectura. No contiene datos de negocio.
-- Generado con docs/seguridad/consultas/00-respaldo-catalogo.sql

CREATE POLICY abc_leyenda_escribir ON public.abc_leyenda_combinaciones AS PERMISSIVE FOR UPDATE TO authenticated USING (puede_compras_inventario(auth.uid())) WITH CHECK (puede_compras_inventario(auth.uid()));
CREATE POLICY abc_leyenda_leer ON public.abc_leyenda_combinaciones AS PERMISSIVE FOR SELECT TO authenticated USING (puede_leer_compras_inventario(auth.uid()));
CREATE POLICY ajuste_inv_lineas_leer ON public.ajuste_inventario_lineas AS PERMISSIVE FOR SELECT TO authenticated USING (puede_leer_compras_inventario(auth.uid()));
CREATE POLICY modo_prueba_lectura ON public.ajuste_inventario_lineas AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR (EXISTS ( SELECT 1
   FROM ajustes_inventario p
  WHERE ((p.id = ajuste_inventario_lineas.ajuste_id) AND p.es_prueba)))));
CREATE POLICY ajustes_inv_leer ON public.ajustes_inventario AS PERMISSIVE FOR SELECT TO authenticated USING (puede_leer_compras_inventario(auth.uid()));
CREATE POLICY modo_prueba_lectura ON public.ajustes_inventario AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR es_prueba));
CREATE POLICY modo_prueba_lectura ON public.almacen_refacciones_acceso AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR (user_id = auth.uid())));
CREATE POLICY ref_acceso_escribir ON public.almacen_refacciones_acceso AS PERMISSIVE FOR ALL TO authenticated USING (es_admin_global(auth.uid())) WITH CHECK (es_admin_global(auth.uid()));
CREATE POLICY ref_acceso_leer ON public.almacen_refacciones_acceso AS PERMISSIVE FOR SELECT TO authenticated USING ((es_admin_global(auth.uid()) OR (user_id = auth.uid()) OR (lower(email) = lower((COALESCE(( SELECT users.email
   FROM auth.users
  WHERE (users.id = auth.uid())), ''::character varying))::text))));
CREATE POLICY modo_prueba_lectura ON public.almacen_refacciones_codigos AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR (EXISTS ( SELECT 1
   FROM almacen_refacciones_productos p
  WHERE ((p.id = almacen_refacciones_codigos.producto_id) AND p.es_prueba)))));
CREATE POLICY ref_codigos_escribir ON public.almacen_refacciones_codigos AS PERMISSIVE FOR ALL TO authenticated USING (puede_ver_almacen_refacciones()) WITH CHECK (puede_ver_almacen_refacciones());
CREATE POLICY ref_codigos_leer ON public.almacen_refacciones_codigos AS PERMISSIVE FOR SELECT TO authenticated USING (puede_ver_almacen_refacciones());
CREATE POLICY ref_codigos_leer_compras ON public.almacen_refacciones_codigos AS PERMISSIVE FOR SELECT TO authenticated USING (puede_leer_compras_inventario(auth.uid()));
CREATE POLICY modo_prueba_lectura ON public.almacen_refacciones_movimientos AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR es_prueba));
CREATE POLICY ref_mov_escribir ON public.almacen_refacciones_movimientos AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (puede_ver_almacen_refacciones());
CREATE POLICY ref_mov_leer ON public.almacen_refacciones_movimientos AS PERMISSIVE FOR SELECT TO authenticated USING (puede_ver_almacen_refacciones());
CREATE POLICY ref_mov_leer_compras ON public.almacen_refacciones_movimientos AS PERMISSIVE FOR SELECT TO authenticated USING (puede_leer_compras_inventario(auth.uid()));
CREATE POLICY modo_prueba_lectura ON public.almacen_refacciones_producto_compat AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR (EXISTS ( SELECT 1
   FROM almacen_refacciones_productos p
  WHERE ((p.id = almacen_refacciones_producto_compat.producto_id) AND p.es_prueba)))));
CREATE POLICY ref_compat_escribir ON public.almacen_refacciones_producto_compat AS PERMISSIVE FOR ALL TO authenticated USING (puede_ver_almacen_refacciones()) WITH CHECK (puede_ver_almacen_refacciones());
CREATE POLICY ref_compat_leer ON public.almacen_refacciones_producto_compat AS PERMISSIVE FOR SELECT TO authenticated USING (puede_ver_almacen_refacciones());
CREATE POLICY ref_compat_leer_compras ON public.almacen_refacciones_producto_compat AS PERMISSIVE FOR SELECT TO authenticated USING (puede_leer_compras_inventario(auth.uid()));
CREATE POLICY modo_prueba_lectura ON public.almacen_refacciones_productos AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR es_prueba));
CREATE POLICY ref_prod_escribir ON public.almacen_refacciones_productos AS PERMISSIVE FOR ALL TO authenticated USING (puede_ver_almacen_refacciones()) WITH CHECK (puede_ver_almacen_refacciones());
CREATE POLICY ref_prod_leer ON public.almacen_refacciones_productos AS PERMISSIVE FOR SELECT TO authenticated USING (puede_ver_almacen_refacciones());
CREATE POLICY ref_prod_leer_compras ON public.almacen_refacciones_productos AS PERMISSIVE FOR SELECT TO authenticated USING (puede_leer_compras_inventario(auth.uid()));
CREATE POLICY ref_prod_leer_ventas ON public.almacen_refacciones_productos AS PERMISSIVE FOR SELECT TO authenticated USING (((rol_comercial() <> 'ninguno'::text) AND visible_venta));
CREATE POLICY unidad_alias_leer ON public.almacen_refacciones_unidad_alias AS PERMISSIVE FOR SELECT TO authenticated USING ((puede_ver_almacen_refacciones() OR puede_leer_compras_inventario(auth.uid())));
CREATE POLICY ref_unidades_escribir ON public.almacen_refacciones_unidades AS PERMISSIVE FOR ALL TO authenticated USING (puede_ver_almacen_refacciones()) WITH CHECK (puede_ver_almacen_refacciones());
CREATE POLICY ref_unidades_leer ON public.almacen_refacciones_unidades AS PERMISSIVE FOR SELECT TO authenticated USING (puede_ver_almacen_refacciones());
CREATE POLICY ref_unidades_leer_compras ON public.almacen_refacciones_unidades AS PERMISSIVE FOR SELECT TO authenticated USING (puede_leer_compras_inventario(auth.uid()));
CREATE POLICY "leer modulos activos" ON public.app_modulos AS PERMISSIVE FOR SELECT TO authenticated USING (usuario_activo(auth.uid()));
CREATE POLICY avisos_modo_prueba ON public.avisos AS RESTRICTIVE FOR SELECT TO authenticated USING (
CASE
    WHEN ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba) THEN (es_prueba OR (destinatario_id = auth.uid()))
    ELSE (NOT es_prueba)
END);
CREATE POLICY "dar por visto" ON public.avisos AS PERMISSIVE FOR UPDATE TO authenticated USING ((recibe_avisos_de(area_destino) OR (usuario_destino = auth.uid()))) WITH CHECK ((recibe_avisos_de(area_destino) OR (usuario_destino = auth.uid())));
CREATE POLICY "leer avisos de mi area" ON public.avisos AS PERMISSIVE FOR SELECT TO authenticated USING ((recibe_avisos_de(area_destino) OR (creado_por = auth.uid()) OR (destinatario_id = auth.uid())));
CREATE POLICY "mandar aviso" ON public.avisos AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK ((creado_por = auth.uid()));
CREATE POLICY "autenticados leen bitacora_color" ON public.bitacora_color AS PERMISSIVE FOR SELECT TO authenticated USING (usuario_operativo(auth.uid()));
CREATE POLICY modo_prueba_lectura ON public.bitacora_color AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY bitacora_compras_leer ON public.bitacora_compras_inventario AS PERMISSIVE FOR SELECT TO authenticated USING ((es_admin_global(auth.uid()) OR has_role(auth.uid(), 'admin'::app_role) OR ((modulo = 'cobranza'::text) AND puede_finanzas_cobranza(auth.uid())) OR ((modulo = ANY (ARRAY['inventario'::text, 'prueba'::text])) AND puede_compras_inventario(auth.uid()))));
CREATE POLICY modo_prueba_lectura ON public.bitacora_compras_inventario AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR es_prueba));
CREATE POLICY bitacora_elim_select_admin ON public.bitacora_eliminaciones AS PERMISSIVE FOR SELECT TO authenticated USING ((es_admin_global(auth.uid()) OR has_role(auth.uid(), 'admin'::app_role)));
CREATE POLICY modo_prueba_lectura ON public.bitacora_eliminaciones AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR (eliminado_por = auth.uid())));
CREATE POLICY "admin de area lee bitacora" ON public.bitacora_eventos AS PERMISSIVE FOR SELECT TO authenticated USING ((nivel_al_menos(auth.uid(), 'admin'::user_nivel) OR es_area(auth.uid(), 'direccion'::user_area)));
CREATE POLICY "leer bitacora admin" ON public.bitacora_eventos AS PERMISSIVE FOR SELECT TO authenticated USING (has_role(auth.uid(), 'admin'::app_role));
CREATE POLICY modo_prueba_lectura ON public.bitacora_eventos AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR (usuario_id = auth.uid())));
CREATE POLICY "autenticados leen bitacora_orden_armado" ON public.bitacora_orden_armado AS PERMISSIVE FOR SELECT TO authenticated USING (usuario_operativo(auth.uid()));
CREATE POLICY modo_prueba_lectura ON public.bitacora_orden_armado AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY "admins leen bitacora super admin" ON public.bitacora_super_admin AS PERMISSIVE FOR SELECT TO authenticated USING (nivel_al_menos(auth.uid(), 'admin'::user_nivel));
CREATE POLICY categorias_select ON public.categorias_financieras AS PERMISSIVE FOR SELECT TO authenticated USING (es_finanzas(auth.uid()));
CREATE POLICY categorias_write ON public.categorias_financieras AS PERMISSIVE FOR ALL TO authenticated USING (es_finanzas_admin(auth.uid())) WITH CHECK (es_finanzas_admin(auth.uid()));
CREATE POLICY modo_prueba_lectura ON public.categorias_financieras AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY "actualizar clientes" ON public.clientes AS PERMISSIVE FOR UPDATE TO authenticated USING ((has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'director_ventas'::app_role) OR has_role(auth.uid(), 'coordinador_ventas'::app_role) OR ((vendedor_id = auth.uid()) AND (has_role(auth.uid(), 'ventas'::app_role) OR has_role(auth.uid(), 'auxiliar_ventas'::app_role)))));
CREATE POLICY "admin de area borra clientes" ON public.clientes AS PERMISSIVE FOR DELETE TO authenticated USING ((es_admin_area(auth.uid(), 'comercial'::user_area) OR es_admin_area(auth.uid(), 'administracion'::user_area)));
CREATE POLICY "administrativo comercial lee clientes" ON public.clientes AS PERMISSIVE FOR SELECT TO authenticated USING (es_administrativo_comercial(auth.uid()));
CREATE POLICY "borrar clientes admin" ON public.clientes AS PERMISSIVE FOR DELETE TO authenticated USING (has_role(auth.uid(), 'admin'::app_role));
CREATE POLICY "comercial crea clientes" ON public.clientes AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK ((es_area(auth.uid(), 'comercial'::user_area) OR es_area(auth.uid(), 'administracion'::user_area) OR es_admin_global(auth.uid())));
CREATE POLICY "comercial supervisa clientes" ON public.clientes AS PERMISSIVE FOR UPDATE TO authenticated USING ((supervisa_area(auth.uid(), 'comercial'::user_area) OR supervisa_area(auth.uid(), 'administracion'::user_area)));
CREATE POLICY "crear clientes" ON public.clientes AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK ((has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'director_ventas'::app_role) OR has_role(auth.uid(), 'coordinador_ventas'::app_role) OR has_role(auth.uid(), 'ventas'::app_role) OR has_role(auth.uid(), 'auxiliar_ventas'::app_role)));
CREATE POLICY "escribir clientes" ON public.clientes AS PERMISSIVE FOR INSERT TO public WITH CHECK ((has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'fabrica'::app_role) OR has_role(auth.uid(), 'coordinador'::app_role) OR has_role(auth.uid(), 'ventas'::app_role)));
CREATE POLICY "leer clientes" ON public.clientes AS PERMISSIVE FOR SELECT TO authenticated USING ((es_admin_global(auth.uid()) OR ve_todo_comercial(auth.uid()) OR es_area(auth.uid(), 'fabrica'::user_area) OR es_area(auth.uid(), 'almacen_logistica'::user_area) OR es_area(auth.uid(), 'administracion'::user_area) OR es_area(auth.uid(), 'compras'::user_area) OR es_area(auth.uid(), 'direccion'::user_area) OR has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'fabrica'::app_role) OR has_role(auth.uid(), 'logistica'::app_role) OR has_role(auth.uid(), 'coordinador'::app_role) OR has_role(auth.uid(), 'finanzas'::app_role) OR has_role(auth.uid(), 'admin_financiero'::app_role) OR has_role(auth.uid(), 'compras'::app_role) OR ((es_area(auth.uid(), 'comercial'::user_area) OR has_role(auth.uid(), 'ventas'::app_role)) AND usuario_activo(auth.uid()) AND ((vendedor_id = auth.uid()) OR (EXISTS ( SELECT 1
   FROM remisiones r
  WHERE ((r.cliente_id = clientes.id) AND (r.vendedor_id = auth.uid()))))))));
CREATE POLICY modo_prueba_lectura ON public.clientes AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR es_prueba));
CREATE POLICY "Usuarios autenticados pueden insertar en bitácora" ON public.clientes_bitacora AS PERMISSIVE FOR INSERT TO public WITH CHECK ((auth.uid() = usuario_id));
CREATE POLICY clientes_bitacora_select ON public.clientes_bitacora AS PERMISSIVE FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM clientes c
  WHERE (c.id = clientes_bitacora.cliente_id))));
CREATE POLICY modo_prueba_lectura ON public.clientes_bitacora AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR (EXISTS ( SELECT 1
   FROM clientes p
  WHERE ((p.id = clientes_bitacora.cliente_id) AND p.es_prueba)))));
CREATE POLICY "Usuarios autenticados pueden insertar comentarios" ON public.clientes_comentarios AS PERMISSIVE FOR INSERT TO public WITH CHECK ((auth.uid() = usuario_id));
CREATE POLICY clientes_comentarios_select ON public.clientes_comentarios AS PERMISSIVE FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM clientes c
  WHERE (c.id = clientes_comentarios.cliente_id))));
CREATE POLICY modo_prueba_lectura ON public.clientes_comentarios AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR (EXISTS ( SELECT 1
   FROM clientes p
  WHERE ((p.id = clientes_comentarios.cliente_id) AND p.es_prueba)))));
CREATE POLICY cobranza_aplicaciones_leer ON public.cobranza_aplicaciones AS PERMISSIVE FOR SELECT TO authenticated USING ((puede_compras_inventario(auth.uid()) OR puede_finanzas_cobranza(auth.uid())));
CREATE POLICY modo_prueba_lectura ON public.cobranza_aplicaciones AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR es_prueba));
CREATE POLICY cobranza_pagos_leer ON public.cobranza_pagos AS PERMISSIVE FOR SELECT TO authenticated USING ((puede_compras_inventario(auth.uid()) OR puede_finanzas_cobranza(auth.uid())));
CREATE POLICY modo_prueba_lectura ON public.cobranza_pagos AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR es_prueba));
CREATE POLICY cobranza_saldos_favor_leer ON public.cobranza_saldos_favor AS PERMISSIVE FOR SELECT TO authenticated USING ((puede_compras_inventario(auth.uid()) OR puede_finanzas_cobranza(auth.uid())));
CREATE POLICY modo_prueba_lectura ON public.cobranza_saldos_favor AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR es_prueba));
CREATE POLICY cobranza_solicitudes_leer ON public.cobranza_solicitudes_saldo AS PERMISSIVE FOR SELECT TO authenticated USING (((solicitado_por = auth.uid()) OR puede_compras_inventario(auth.uid()) OR puede_finanzas_cobranza(auth.uid())));
CREATE POLICY modo_prueba_lectura ON public.cobranza_solicitudes_saldo AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR es_prueba));
CREATE POLICY "borrar comentario motocarro" ON public.comentarios_motocarros AS PERMISSIVE FOR DELETE TO authenticated USING (has_role(auth.uid(), 'admin'::app_role));
CREATE POLICY "insertar comentario motocarro" ON public.comentarios_motocarros AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (((usuario_id = auth.uid()) AND (es_area(auth.uid(), 'direccion'::user_area) OR es_area(auth.uid(), 'comercial'::user_area) OR es_area(auth.uid(), 'fabrica'::user_area) OR es_area(auth.uid(), 'almacen_logistica'::user_area))));
CREATE POLICY "leer comentarios motocarros" ON public.comentarios_motocarros AS PERMISSIVE FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM motocarros m
  WHERE ((m.id = comentarios_motocarros.motocarro_id) AND (has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'fabrica'::app_role) OR has_role(auth.uid(), 'logistica'::app_role) OR has_role(auth.uid(), 'coordinador'::app_role) OR ((m.remision_id IS NOT NULL) AND (EXISTS ( SELECT 1
           FROM remisiones r
          WHERE ((r.id = m.remision_id) AND (r.vendedor_id = auth.uid()))))))))));
CREATE POLICY modo_prueba_lectura ON public.comentarios_motocarros AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY "leer compra lineas" ON public.compra_lineas AS PERMISSIVE FOR SELECT TO authenticated USING ((es_compras(auth.uid()) OR es_finanzas(auth.uid()) OR es_admin_global(auth.uid())));
CREATE POLICY modo_prueba_lectura ON public.compra_lineas AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY compra_ref_lineas_leer ON public.compra_refaccion_lineas AS PERMISSIVE FOR SELECT TO authenticated USING (puede_leer_compras_inventario(auth.uid()));
CREATE POLICY modo_prueba_lectura ON public.compra_refaccion_lineas AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR (EXISTS ( SELECT 1
   FROM compras_refacciones p
  WHERE ((p.id = compra_refaccion_lineas.compra_id) AND p.es_prueba)))));
CREATE POLICY compra_ref_pend_leer ON public.compra_refaccion_pendientes AS PERMISSIVE FOR SELECT TO authenticated USING (puede_leer_compras_inventario(auth.uid()));
CREATE POLICY modo_prueba_lectura ON public.compra_refaccion_pendientes AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR (EXISTS ( SELECT 1
   FROM compras_refacciones p
  WHERE ((p.id = compra_refaccion_pendientes.compra_id) AND p.es_prueba)))));
CREATE POLICY "leer compras" ON public.compras AS PERMISSIVE FOR SELECT TO authenticated USING ((es_compras(auth.uid()) OR es_finanzas(auth.uid()) OR es_admin_global(auth.uid())));
CREATE POLICY modo_prueba_lectura ON public.compras AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY modo_prueba_lectura ON public.compras_folios AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR es_prueba));
CREATE POLICY compras_parametros_escribir ON public.compras_parametros AS PERMISSIVE FOR UPDATE TO authenticated USING (puede_compras_inventario(auth.uid())) WITH CHECK (puede_compras_inventario(auth.uid()));
CREATE POLICY compras_parametros_leer ON public.compras_parametros AS PERMISSIVE FOR SELECT TO authenticated USING (puede_leer_compras_inventario(auth.uid()));
CREATE POLICY compras_ref_leer ON public.compras_refacciones AS PERMISSIVE FOR SELECT TO authenticated USING (puede_leer_compras_inventario(auth.uid()));
CREATE POLICY modo_prueba_lectura ON public.compras_refacciones AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR es_prueba));
CREATE POLICY "actualizar config admin" ON public.config_general AS PERMISSIVE FOR UPDATE TO authenticated USING (has_role(auth.uid(), 'admin'::app_role));
CREATE POLICY "admin global actualiza config" ON public.config_general AS PERMISSIVE FOR UPDATE TO authenticated USING (es_admin_global(auth.uid()));
CREATE POLICY "leer config" ON public.config_general AS PERMISSIVE FOR SELECT TO authenticated USING (usuario_operativo(auth.uid()));
CREATE POLICY "actualizar partes contenedor admin/fabrica" ON public.contenedor_partes AS PERMISSIVE FOR UPDATE TO authenticated USING ((has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'fabrica'::app_role)));
CREATE POLICY "borrar partes contenedor admin" ON public.contenedor_partes AS PERMISSIVE FOR DELETE TO authenticated USING (has_role(auth.uid(), 'admin'::app_role));
CREATE POLICY "escribir partes contenedor admin/fabrica" ON public.contenedor_partes AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK ((has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'fabrica'::app_role)));
CREATE POLICY "leer partes contenedor" ON public.contenedor_partes AS PERMISSIVE FOR SELECT TO authenticated USING (usuario_operativo(auth.uid()));
CREATE POLICY modo_prueba_lectura ON public.contenedor_partes AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY "actualizar contenedores admin/fabrica" ON public.contenedores AS PERMISSIVE FOR UPDATE TO authenticated USING ((has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'fabrica'::app_role)));
CREATE POLICY "admin de area borra contenedores" ON public.contenedores AS PERMISSIVE FOR DELETE TO authenticated USING ((es_admin_area(auth.uid(), 'fabrica'::user_area) OR es_admin_area(auth.uid(), 'almacen_logistica'::user_area)));
CREATE POLICY "borrar contenedores admin" ON public.contenedores AS PERMISSIVE FOR DELETE TO authenticated USING (has_role(auth.uid(), 'admin'::app_role));
CREATE POLICY "escribir contenedores admin/fabrica" ON public.contenedores AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK ((has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'fabrica'::app_role)));
CREATE POLICY "leer contenedores" ON public.contenedores AS PERMISSIVE FOR SELECT TO authenticated USING (usuario_operativo(auth.uid()));
CREATE POLICY modo_prueba_lectura ON public.contenedores AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY crm_act_insert ON public.crm_actividades AS PERMISSIVE FOR INSERT TO public WITH CHECK ((has_role(auth.uid(), 'admin'::app_role) OR ve_todo_comercial(auth.uid()) OR (es_area(auth.uid(), 'comercial'::user_area) AND (vendedor_id = auth.uid()))));
CREATE POLICY crm_act_select ON public.crm_actividades AS PERMISSIVE FOR SELECT TO public USING ((has_role(auth.uid(), 'admin'::app_role) OR ve_todo_comercial(auth.uid()) OR (vendedor_id = auth.uid())));
CREATE POLICY crm_act_update ON public.crm_actividades AS PERMISSIVE FOR UPDATE TO public USING ((has_role(auth.uid(), 'admin'::app_role) OR ve_todo_comercial(auth.uid()) OR (vendedor_id = auth.uid())));
CREATE POLICY crm_actividades_delete ON public.crm_actividades AS PERMISSIVE FOR DELETE TO public USING ((has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'director_ventas'::app_role)));
CREATE POLICY crm_actividades_delete_area ON public.crm_actividades AS PERMISSIVE FOR DELETE TO authenticated USING ((es_area(auth.uid(), 'direccion'::user_area) OR supervisa_area(auth.uid(), 'comercial'::user_area)));
CREATE POLICY crm_actividades_insert ON public.crm_actividades AS PERMISSIVE FOR INSERT TO public WITH CHECK ((has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'director_ventas'::app_role) OR has_role(auth.uid(), 'coordinador_ventas'::app_role) OR has_role(auth.uid(), 'ventas'::app_role) OR has_role(auth.uid(), 'auxiliar_ventas'::app_role)));
CREATE POLICY crm_actividades_insert_area ON public.crm_actividades AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK ((es_area(auth.uid(), 'direccion'::user_area) OR es_area(auth.uid(), 'comercial'::user_area)));
CREATE POLICY crm_actividades_select ON public.crm_actividades AS PERMISSIVE FOR SELECT TO public USING ((has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'director_ventas'::app_role) OR has_role(auth.uid(), 'coordinador_ventas'::app_role) OR (vendedor_id = auth.uid())));
CREATE POLICY crm_actividades_update ON public.crm_actividades AS PERMISSIVE FOR UPDATE TO public USING ((has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'director_ventas'::app_role) OR (vendedor_id = auth.uid())));
CREATE POLICY crm_actividades_update_area ON public.crm_actividades AS PERMISSIVE FOR UPDATE TO authenticated USING ((es_area(auth.uid(), 'direccion'::user_area) OR supervisa_area(auth.uid(), 'comercial'::user_area) OR (es_area(auth.uid(), 'comercial'::user_area) AND (vendedor_id = auth.uid()))));
CREATE POLICY modo_prueba_lectura ON public.crm_actividades AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY crm_oport_insert ON public.crm_oportunidades AS PERMISSIVE FOR INSERT TO public WITH CHECK ((has_role(auth.uid(), 'admin'::app_role) OR ve_todo_comercial(auth.uid()) OR (es_area(auth.uid(), 'comercial'::user_area) AND (vendedor_id = auth.uid()))));
CREATE POLICY crm_oport_select ON public.crm_oportunidades AS PERMISSIVE FOR SELECT TO public USING ((has_role(auth.uid(), 'admin'::app_role) OR ve_todo_comercial(auth.uid()) OR (vendedor_id = auth.uid())));
CREATE POLICY crm_oport_update ON public.crm_oportunidades AS PERMISSIVE FOR UPDATE TO public USING ((has_role(auth.uid(), 'admin'::app_role) OR ve_todo_comercial(auth.uid()) OR (vendedor_id = auth.uid())));
CREATE POLICY crm_oportunidades_delete ON public.crm_oportunidades AS PERMISSIVE FOR DELETE TO public USING ((has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'director_ventas'::app_role)));
CREATE POLICY crm_oportunidades_delete_area ON public.crm_oportunidades AS PERMISSIVE FOR DELETE TO authenticated USING ((es_area(auth.uid(), 'direccion'::user_area) OR supervisa_area(auth.uid(), 'comercial'::user_area)));
CREATE POLICY crm_oportunidades_insert ON public.crm_oportunidades AS PERMISSIVE FOR INSERT TO public WITH CHECK ((has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'director_ventas'::app_role) OR has_role(auth.uid(), 'coordinador_ventas'::app_role) OR has_role(auth.uid(), 'ventas'::app_role) OR has_role(auth.uid(), 'auxiliar_ventas'::app_role)));
CREATE POLICY crm_oportunidades_insert_area ON public.crm_oportunidades AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK ((es_area(auth.uid(), 'direccion'::user_area) OR es_area(auth.uid(), 'comercial'::user_area)));
CREATE POLICY crm_oportunidades_select ON public.crm_oportunidades AS PERMISSIVE FOR SELECT TO public USING ((has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'director_ventas'::app_role) OR has_role(auth.uid(), 'coordinador_ventas'::app_role) OR ((has_role(auth.uid(), 'ventas'::app_role) OR has_role(auth.uid(), 'auxiliar_ventas'::app_role)) AND (vendedor_id = auth.uid()))));
CREATE POLICY crm_oportunidades_update ON public.crm_oportunidades AS PERMISSIVE FOR UPDATE TO public USING ((has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'director_ventas'::app_role) OR has_role(auth.uid(), 'coordinador_ventas'::app_role) OR (vendedor_id = auth.uid())));
CREATE POLICY crm_oportunidades_update_area ON public.crm_oportunidades AS PERMISSIVE FOR UPDATE TO authenticated USING ((es_area(auth.uid(), 'direccion'::user_area) OR supervisa_area(auth.uid(), 'comercial'::user_area) OR (es_area(auth.uid(), 'comercial'::user_area) AND (vendedor_id = auth.uid()))));
CREATE POLICY modo_prueba_lectura ON public.crm_oportunidades AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY crm_paradas_all ON public.crm_ruta_paradas AS PERMISSIVE FOR ALL TO public USING ((EXISTS ( SELECT 1
   FROM crm_rutas r
  WHERE (r.id = crm_ruta_paradas.ruta_id)))) WITH CHECK ((EXISTS ( SELECT 1
   FROM crm_rutas r
  WHERE (r.id = crm_ruta_paradas.ruta_id))));
CREATE POLICY crm_ruta_paradas_insert ON public.crm_ruta_paradas AS PERMISSIVE FOR INSERT TO public WITH CHECK ((EXISTS ( SELECT 1
   FROM crm_rutas r
  WHERE ((r.id = crm_ruta_paradas.ruta_id) AND (has_role(auth.uid(), 'admin'::app_role) OR (r.vendedor_id = auth.uid()))))));
CREATE POLICY crm_ruta_paradas_select ON public.crm_ruta_paradas AS PERMISSIVE FOR SELECT TO public USING ((EXISTS ( SELECT 1
   FROM crm_rutas r
  WHERE ((r.id = crm_ruta_paradas.ruta_id) AND (has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'director_ventas'::app_role) OR has_role(auth.uid(), 'coordinador_ventas'::app_role) OR (r.vendedor_id = auth.uid()))))));
CREATE POLICY crm_ruta_paradas_update ON public.crm_ruta_paradas AS PERMISSIVE FOR UPDATE TO public USING ((EXISTS ( SELECT 1
   FROM crm_rutas r
  WHERE ((r.id = crm_ruta_paradas.ruta_id) AND (has_role(auth.uid(), 'admin'::app_role) OR (r.vendedor_id = auth.uid()))))));
CREATE POLICY modo_prueba_lectura ON public.crm_ruta_paradas AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY crm_rutas_delete_area ON public.crm_rutas AS PERMISSIVE FOR DELETE TO authenticated USING ((es_area(auth.uid(), 'direccion'::user_area) OR supervisa_area(auth.uid(), 'comercial'::user_area)));
CREATE POLICY crm_rutas_insert ON public.crm_rutas AS PERMISSIVE FOR INSERT TO public WITH CHECK ((has_role(auth.uid(), 'admin'::app_role) OR ve_todo_comercial(auth.uid()) OR (es_area(auth.uid(), 'comercial'::user_area) AND (vendedor_id = auth.uid()))));
CREATE POLICY crm_rutas_insert_area ON public.crm_rutas AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK ((es_area(auth.uid(), 'direccion'::user_area) OR es_area(auth.uid(), 'comercial'::user_area)));
CREATE POLICY crm_rutas_select ON public.crm_rutas AS PERMISSIVE FOR SELECT TO public USING ((has_role(auth.uid(), 'admin'::app_role) OR ve_todo_comercial(auth.uid()) OR (vendedor_id = auth.uid())));
CREATE POLICY crm_rutas_update ON public.crm_rutas AS PERMISSIVE FOR UPDATE TO public USING ((has_role(auth.uid(), 'admin'::app_role) OR ve_todo_comercial(auth.uid()) OR (vendedor_id = auth.uid())));
CREATE POLICY crm_rutas_update_area ON public.crm_rutas AS PERMISSIVE FOR UPDATE TO authenticated USING ((es_area(auth.uid(), 'direccion'::user_area) OR supervisa_area(auth.uid(), 'comercial'::user_area) OR (es_area(auth.uid(), 'comercial'::user_area) AND (vendedor_id = auth.uid()))));
CREATE POLICY modo_prueba_lectura ON public.crm_rutas AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY cuentas_select ON public.cuentas_financieras AS PERMISSIVE FOR SELECT TO authenticated USING (es_finanzas(auth.uid()));
CREATE POLICY cuentas_write ON public.cuentas_financieras AS PERMISSIVE FOR ALL TO authenticated USING (es_finanzas_admin(auth.uid())) WITH CHECK (es_finanzas_admin(auth.uid()));
CREATE POLICY modo_prueba_lectura ON public.cuentas_financieras AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY cxc_delete ON public.cuentas_por_cobrar AS PERMISSIVE FOR DELETE TO authenticated USING (es_finanzas_admin(auth.uid()));
CREATE POLICY cxc_insert ON public.cuentas_por_cobrar AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (es_finanzas(auth.uid()));
CREATE POLICY cxc_select ON public.cuentas_por_cobrar AS PERMISSIVE FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM clientes c
  WHERE (c.id = cuentas_por_cobrar.cliente_id))));
CREATE POLICY cxc_update ON public.cuentas_por_cobrar AS PERMISSIVE FOR UPDATE TO authenticated USING (es_finanzas(auth.uid())) WITH CHECK (es_finanzas(auth.uid()));
CREATE POLICY modo_prueba_lectura ON public.cuentas_por_cobrar AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY cxc_abonos_delete ON public.cxc_abonos AS PERMISSIVE FOR DELETE TO authenticated USING (es_finanzas_admin(auth.uid()));
CREATE POLICY cxc_abonos_insert ON public.cxc_abonos AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK ((es_finanzas(auth.uid()) AND (created_by = auth.uid())));
CREATE POLICY cxc_abonos_select ON public.cxc_abonos AS PERMISSIVE FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM cuentas_por_cobrar x
  WHERE (x.id = cxc_abonos.cxc_id))));
CREATE POLICY modo_prueba_lectura ON public.cxc_abonos AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY "leer documento inventario lineas" ON public.documento_inventario_lineas AS PERMISSIVE FOR SELECT TO authenticated USING (puede_leer_inventario(auth.uid()));
CREATE POLICY modo_prueba_lectura ON public.documento_inventario_lineas AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY "leer documentos inventario" ON public.documentos_inventario AS PERMISSIVE FOR SELECT TO authenticated USING (puede_leer_inventario(auth.uid()));
CREATE POLICY modo_prueba_lectura ON public.documentos_inventario AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY firmas_firmantes_select ON public.firmas_firmantes AS PERMISSIVE FOR SELECT TO authenticated USING (firmas_puede_ver_solicitud(solicitud_id));
CREATE POLICY firmas_solicitudes_select ON public.firmas_solicitudes AS PERMISSIVE FOR SELECT TO authenticated USING (firmas_puede_ver_solicitud(id));
CREATE POLICY flujo_capacidades_leer ON public.flujo_capacidades AS PERMISSIVE FOR SELECT TO authenticated USING (((user_id = auth.uid()) OR flujo_es_admin()));
CREATE POLICY flujo_dinero_leer ON public.flujo_dinero AS PERMISSIVE FOR SELECT TO authenticated USING ((flujo_es_admin() OR flujo_cap('recibe'::text) OR flujo_cap('caja'::text) OR flujo_cap('aplica'::text)));
CREATE POLICY "direccion lee historial conexiones" ON public.historial_conexiones AS PERMISSIVE FOR SELECT TO authenticated USING ((es_area(auth.uid(), 'direccion'::user_area) OR es_admin_global(auth.uid()) OR has_role(auth.uid(), 'admin'::app_role)));
CREATE POLICY modo_prueba_lectura ON public.historial_conexiones AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR (usuario_id = auth.uid())));
CREATE POLICY "autenticados leen incidencias_chasis" ON public.incidencias_chasis AS PERMISSIVE FOR SELECT TO authenticated USING (usuario_operativo(auth.uid()));
CREATE POLICY modo_prueba_lectura ON public.incidencias_chasis AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY "autenticados leen incidencias_eventos" ON public.incidencias_chasis_eventos AS PERMISSIVE FOR SELECT TO authenticated USING (usuario_operativo(auth.uid()));
CREATE POLICY modo_prueba_lectura ON public.incidencias_chasis_eventos AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY inventario_almacenes_leer ON public.inventario_almacenes AS PERMISSIVE FOR SELECT TO authenticated USING (puede_leer_compras_inventario(auth.uid()));
CREATE POLICY inv_delete_admin ON public.inventario_chasis AS PERMISSIVE FOR DELETE TO authenticated USING ((es_admin_global(auth.uid()) OR has_role(auth.uid(), 'admin'::app_role)));
CREATE POLICY inv_insert_ops ON public.inventario_chasis AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (puede_escribir_inventario(auth.uid()));
CREATE POLICY inv_select_operativo ON public.inventario_chasis AS PERMISSIVE FOR SELECT TO authenticated USING (puede_leer_inventario(auth.uid()));
CREATE POLICY inv_update_ops ON public.inventario_chasis AS PERMISSIVE FOR UPDATE TO authenticated USING (puede_escribir_inventario(auth.uid())) WITH CHECK (puede_escribir_inventario(auth.uid()));
CREATE POLICY modo_prueba_lectura ON public.inventario_chasis AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY inv_delete_admin ON public.inventario_colores AS PERMISSIVE FOR DELETE TO authenticated USING ((es_admin_global(auth.uid()) OR has_role(auth.uid(), 'admin'::app_role)));
CREATE POLICY inv_insert_ops ON public.inventario_colores AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (puede_escribir_inventario(auth.uid()));
CREATE POLICY inv_select_operativo ON public.inventario_colores AS PERMISSIVE FOR SELECT TO authenticated USING (puede_leer_inventario(auth.uid()));
CREATE POLICY inv_update_ops ON public.inventario_colores AS PERMISSIVE FOR UPDATE TO authenticated USING (puede_escribir_inventario(auth.uid())) WITH CHECK (puede_escribir_inventario(auth.uid()));
CREATE POLICY modo_prueba_lectura ON public.inventario_colores AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY motivos_ajuste_escribir ON public.inventario_motivos_ajuste AS PERMISSIVE FOR ALL TO authenticated USING (puede_compras_inventario(auth.uid())) WITH CHECK (puede_compras_inventario(auth.uid()));
CREATE POLICY motivos_ajuste_leer ON public.inventario_motivos_ajuste AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY inv_delete_admin ON public.inventario_motor AS PERMISSIVE FOR DELETE TO authenticated USING ((es_admin_global(auth.uid()) OR has_role(auth.uid(), 'admin'::app_role)));
CREATE POLICY inv_insert_ops ON public.inventario_motor AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (puede_escribir_inventario(auth.uid()));
CREATE POLICY inv_select_operativo ON public.inventario_motor AS PERMISSIVE FOR SELECT TO authenticated USING (puede_leer_inventario(auth.uid()));
CREATE POLICY inv_update_ops ON public.inventario_motor AS PERMISSIVE FOR UPDATE TO authenticated USING (puede_escribir_inventario(auth.uid())) WITH CHECK (puede_escribir_inventario(auth.uid()));
CREATE POLICY modo_prueba_lectura ON public.inventario_motor AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY inv_delete_admin ON public.inventario_partes AS PERMISSIVE FOR DELETE TO authenticated USING ((es_admin_global(auth.uid()) OR has_role(auth.uid(), 'admin'::app_role)));
CREATE POLICY inv_insert_ops ON public.inventario_partes AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (puede_escribir_inventario(auth.uid()));
CREATE POLICY inv_select_operativo ON public.inventario_partes AS PERMISSIVE FOR SELECT TO authenticated USING (puede_leer_inventario(auth.uid()));
CREATE POLICY inv_update_ops ON public.inventario_partes AS PERMISSIVE FOR UPDATE TO authenticated USING (puede_escribir_inventario(auth.uid())) WITH CHECK (puede_escribir_inventario(auth.uid()));
CREATE POLICY modo_prueba_lectura ON public.inventario_partes AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY reglas_modo_prueba_leer ON public.inventario_reglas_modo_prueba AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY unidades_venta_escribir ON public.inventario_unidades_venta AS PERMISSIVE FOR ALL TO authenticated USING (puede_compras_inventario(auth.uid())) WITH CHECK (puede_compras_inventario(auth.uid()));
CREATE POLICY unidades_venta_leer ON public.inventario_unidades_venta AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY usuarios_prueba_leer ON public.inventario_usuarios_prueba AS PERMISSIVE FOR SELECT TO authenticated USING (puede_compras_inventario(auth.uid()));
CREATE POLICY "admin escribe modelos_producto" ON public.modelos_producto AS PERMISSIVE FOR ALL TO authenticated USING (has_role(auth.uid(), 'admin'::app_role)) WITH CHECK (has_role(auth.uid(), 'admin'::app_role));
CREATE POLICY "autenticados leen modelos_producto" ON public.modelos_producto AS PERMISSIVE FOR SELECT TO authenticated USING (usuario_operativo(auth.uid()));
CREATE POLICY modo_prueba_lectura ON public.modelos_producto AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY "actualizar motocarros operativos" ON public.motocarros AS PERMISSIVE FOR UPDATE TO public USING ((has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'fabrica'::app_role) OR has_role(auth.uid(), 'logistica'::app_role) OR has_role(auth.uid(), 'coordinador'::app_role) OR ((remision_id IS NOT NULL) AND (EXISTS ( SELECT 1
   FROM remisiones r
  WHERE ((r.id = motocarros.remision_id) AND (r.vendedor_id = auth.uid())))))));
CREATE POLICY "admin de area borra motocarros" ON public.motocarros AS PERMISSIVE FOR DELETE TO authenticated USING ((es_admin_area(auth.uid(), 'fabrica'::user_area) OR es_admin_area(auth.uid(), 'almacen_logistica'::user_area)));
CREATE POLICY "administrativo comercial lee motocarros" ON public.motocarros AS PERMISSIVE FOR SELECT TO authenticated USING (((remision_id IS NOT NULL) AND es_administrativo_comercial(auth.uid())));
CREATE POLICY "borrar motocarros admin" ON public.motocarros AS PERMISSIVE FOR DELETE TO authenticated USING (has_role(auth.uid(), 'admin'::app_role));
CREATE POLICY "comercial lee motocarros" ON public.motocarros AS PERMISSIVE FOR SELECT TO authenticated USING ((ve_todo_comercial(auth.uid()) OR (es_area(auth.uid(), 'comercial'::user_area) AND (remision_id IS NOT NULL) AND (EXISTS ( SELECT 1
   FROM remisiones r
  WHERE ((r.id = motocarros.remision_id) AND (r.vendedor_id = auth.uid())))))));
CREATE POLICY "compras lee motocarros" ON public.motocarros AS PERMISSIVE FOR SELECT TO authenticated USING (es_compras(auth.uid()));
CREATE POLICY "compras supervisa motocarros de remisiones" ON public.motocarros AS PERMISSIVE FOR SELECT TO authenticated USING (((remision_id IS NOT NULL) AND compras_supervisa_remisiones(auth.uid())));
CREATE POLICY "crear motocarros admin/fabrica" ON public.motocarros AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK ((has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'fabrica'::app_role)));
CREATE POLICY "direccion lee motocarros" ON public.motocarros AS PERMISSIVE FOR SELECT TO authenticated USING ((es_area(auth.uid(), 'direccion'::user_area) OR es_area(auth.uid(), 'administracion'::user_area)));
CREATE POLICY "leer motocarros por rol" ON public.motocarros AS PERMISSIVE FOR SELECT TO public USING ((has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'fabrica'::app_role) OR has_role(auth.uid(), 'logistica'::app_role) OR has_role(auth.uid(), 'coordinador'::app_role) OR has_role(auth.uid(), 'finanzas'::app_role) OR has_role(auth.uid(), 'admin_financiero'::app_role) OR ((remision_id IS NOT NULL) AND (EXISTS ( SELECT 1
   FROM remisiones r
  WHERE ((r.id = motocarros.remision_id) AND (r.vendedor_id = auth.uid())))))));
CREATE POLICY modo_prueba_lectura ON public.motocarros AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY adjuntos_delete ON public.movimiento_adjuntos AS PERMISSIVE FOR DELETE TO authenticated USING ((es_finanzas_admin(auth.uid()) OR (subido_por = auth.uid())));
CREATE POLICY adjuntos_insert ON public.movimiento_adjuntos AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK ((es_finanzas(auth.uid()) AND (subido_por = auth.uid())));
CREATE POLICY adjuntos_select ON public.movimiento_adjuntos AS PERMISSIVE FOR SELECT TO authenticated USING (es_finanzas(auth.uid()));
CREATE POLICY modo_prueba_lectura ON public.movimiento_adjuntos AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY modo_prueba_lectura ON public.movimiento_bitacora AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY mov_bitacora_select ON public.movimiento_bitacora AS PERMISSIVE FOR SELECT TO authenticated USING (es_finanzas(auth.uid()));
CREATE POLICY modo_prueba_lectura ON public.movimientos_financieros AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY movimientos_delete ON public.movimientos_financieros AS PERMISSIVE FOR DELETE TO authenticated USING (es_finanzas_admin(auth.uid()));
CREATE POLICY movimientos_insert ON public.movimientos_financieros AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK ((es_finanzas(auth.uid()) AND (created_by = auth.uid())));
CREATE POLICY movimientos_select ON public.movimientos_financieros AS PERMISSIVE FOR SELECT TO authenticated USING (es_finanzas(auth.uid()));
CREATE POLICY movimientos_update_admin ON public.movimientos_financieros AS PERMISSIVE FOR UPDATE TO authenticated USING (es_finanzas_admin(auth.uid())) WITH CHECK (es_finanzas_admin(auth.uid()));
CREATE POLICY movimientos_update_propio ON public.movimientos_financieros AS PERMISSIVE FOR UPDATE TO authenticated USING ((has_role(auth.uid(), 'finanzas'::app_role) AND (created_by = auth.uid()) AND (estatus = ANY (ARRAY['BORRADOR'::mov_estatus, 'PENDIENTE'::mov_estatus])))) WITH CHECK ((has_role(auth.uid(), 'finanzas'::app_role) AND (created_by = auth.uid()) AND (estatus = ANY (ARRAY['BORRADOR'::mov_estatus, 'PENDIENTE'::mov_estatus]))));
CREATE POLICY "leer mis notificaciones" ON public.notificaciones AS PERMISSIVE FOR SELECT TO authenticated USING ((usuario_destino = auth.uid()));
CREATE POLICY "marcar mi notificacion leida" ON public.notificaciones AS PERMISSIVE FOR UPDATE TO authenticated USING ((usuario_destino = auth.uid())) WITH CHECK ((usuario_destino = auth.uid()));
CREATE POLICY "mencionar usuario" ON public.notificaciones AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK ((creado_por = auth.uid()));
CREATE POLICY modo_prueba_lectura ON public.notificaciones AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY modo_prueba_lectura ON public.pagos AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY pagos_admin_all ON public.pagos AS PERMISSIVE FOR ALL TO public USING (has_role(auth.uid(), 'admin'::app_role));
CREATE POLICY pagos_admin_financiero_all ON public.pagos AS PERMISSIVE FOR ALL TO public USING (has_role(auth.uid(), 'admin_financiero'::app_role));
CREATE POLICY pagos_finanzas_insert ON public.pagos AS PERMISSIVE FOR INSERT TO public WITH CHECK ((has_role(auth.uid(), 'finanzas'::app_role) AND (created_by = auth.uid())));
CREATE POLICY pagos_finanzas_select ON public.pagos AS PERMISSIVE FOR SELECT TO public USING (has_role(auth.uid(), 'finanzas'::app_role));
CREATE POLICY pagos_finanzas_update ON public.pagos AS PERMISSIVE FOR UPDATE TO public USING ((has_role(auth.uid(), 'finanzas'::app_role) AND (created_by = auth.uid())));
CREATE POLICY "admin de area actualiza profiles" ON public.profiles AS PERMISSIVE FOR UPDATE TO authenticated USING ((es_admin_global(auth.uid()) OR (EXISTS ( SELECT 1
   FROM user_roles ur
  WHERE ((ur.user_id = profiles.id) AND (mi_nivel() = 'admin'::user_nivel) AND (ur.area = mi_area()))))));
CREATE POLICY "admin de area inserta profiles" ON public.profiles AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK ((nivel_al_menos(auth.uid(), 'admin'::user_nivel) OR (id = auth.uid())));
CREATE POLICY "admin inserta profiles" ON public.profiles AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK ((has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'director_ventas'::app_role) OR has_role(auth.uid(), 'coordinador_ventas'::app_role) OR has_role(auth.uid(), 'admin_financiero'::app_role) OR (id = auth.uid())));
CREATE POLICY modo_prueba_lectura ON public.profiles AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR ((id = auth.uid()) OR es_usuario_prueba(id))));
CREATE POLICY profiles_select_activos ON public.profiles AS PERMISSIVE FOR SELECT TO authenticated USING (((id = auth.uid()) OR usuario_activo(auth.uid())));
CREATE POLICY profiles_update_admin ON public.profiles AS PERMISSIVE FOR UPDATE TO authenticated USING ((es_admin_global(auth.uid()) OR es_admin_area(auth.uid(), 'direccion'::user_area) OR (EXISTS ( SELECT 1
   FROM user_roles ur
  WHERE ((ur.user_id = auth.uid()) AND (ur.nivel = 'admin'::user_nivel) AND usuario_activo(auth.uid())))))) WITH CHECK ((es_admin_global(auth.uid()) OR es_admin_area(auth.uid(), 'direccion'::user_area) OR (EXISTS ( SELECT 1
   FROM user_roles ur
  WHERE ((ur.user_id = auth.uid()) AND (ur.nivel = 'admin'::user_nivel) AND usuario_activo(auth.uid()))))));
CREATE POLICY profiles_update_propio ON public.profiles AS PERMISSIVE FOR UPDATE TO authenticated USING (((id = auth.uid()) AND usuario_activo(auth.uid()))) WITH CHECK ((id = auth.uid()));
CREATE POLICY modo_prueba_lectura ON public.proveedores AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY proveedores_delete ON public.proveedores AS PERMISSIVE FOR DELETE TO authenticated USING ((es_finanzas_admin(auth.uid()) OR es_compras_admin(auth.uid())));
CREATE POLICY proveedores_insert ON public.proveedores AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK ((es_finanzas(auth.uid()) OR es_compras(auth.uid())));
CREATE POLICY proveedores_select ON public.proveedores AS PERMISSIVE FOR SELECT TO authenticated USING ((es_finanzas(auth.uid()) OR es_compras(auth.uid()) OR es_admin_global(auth.uid())));
CREATE POLICY proveedores_update ON public.proveedores AS PERMISSIVE FOR UPDATE TO authenticated USING ((es_finanzas(auth.uid()) OR es_compras(auth.uid())));
CREATE POLICY modo_prueba_lectura ON public.recepcion_refaccion_lineas AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR (EXISTS ( SELECT 1
   FROM recepciones_refacciones p
  WHERE ((p.id = recepcion_refaccion_lineas.recepcion_id) AND p.es_prueba)))));
CREATE POLICY recepcion_ref_lineas_leer ON public.recepcion_refaccion_lineas AS PERMISSIVE FOR SELECT TO authenticated USING (puede_leer_compras_inventario(auth.uid()));
CREATE POLICY modo_prueba_lectura ON public.recepciones_refacciones AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR es_prueba));
CREATE POLICY recepciones_ref_leer ON public.recepciones_refacciones AS PERMISSIVE FOR SELECT TO authenticated USING (puede_leer_compras_inventario(auth.uid()));
CREATE POLICY modo_prueba_lectura ON public.remision_items AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY remision_items_delete ON public.remision_items AS PERMISSIVE FOR DELETE TO public USING (has_role(auth.uid(), 'admin'::app_role));
CREATE POLICY remision_items_delete_area ON public.remision_items AS PERMISSIVE FOR DELETE TO authenticated USING (puede_editar_remision(remision_id));
CREATE POLICY remision_items_insert_area ON public.remision_items AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (puede_editar_remision(remision_id));
CREATE POLICY remision_items_select ON public.remision_items AS PERMISSIVE FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM remisiones r
  WHERE (r.id = remision_items.remision_id))));
CREATE POLICY remision_items_update_area ON public.remision_items AS PERMISSIVE FOR UPDATE TO authenticated USING (puede_editar_remision(remision_id)) WITH CHECK (puede_editar_remision(remision_id));
CREATE POLICY modo_prueba_lectura ON public.remision_refaccion_correcciones AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR es_prueba));
CREATE POLICY rem_ref_correcciones_leer ON public.remision_refaccion_correcciones AS PERMISSIVE FOR SELECT TO authenticated USING ((puede_leer_remision_refaccion(remision_id) OR puede_compras_inventario(auth.uid()) OR puede_finanzas_cobranza(auth.uid())));
CREATE POLICY "compras lee eventos refacciones" ON public.remision_refaccion_eventos AS PERMISSIVE FOR SELECT TO authenticated USING ((puede_compras_inventario(auth.uid()) OR puede_finanzas_cobranza(auth.uid())));
CREATE POLICY "leer eventos refacciones" ON public.remision_refaccion_eventos AS PERMISSIVE FOR SELECT TO authenticated USING (puede_leer_remision_refaccion(remision_id));
CREATE POLICY modo_prueba_lectura ON public.remision_refaccion_eventos AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR (EXISTS ( SELECT 1
   FROM remisiones_refacciones p
  WHERE ((p.id = remision_refaccion_eventos.remision_id) AND p.es_prueba)))));
CREATE POLICY "compras lee partidas refacciones" ON public.remision_refaccion_items AS PERMISSIVE FOR SELECT TO authenticated USING ((puede_compras_inventario(auth.uid()) OR puede_finanzas_cobranza(auth.uid())));
CREATE POLICY "leer partidas refacciones" ON public.remision_refaccion_items AS PERMISSIVE FOR SELECT TO authenticated USING (puede_leer_remision_refaccion(remision_id));
CREATE POLICY modo_prueba_lectura ON public.remision_refaccion_items AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR (EXISTS ( SELECT 1
   FROM remisiones_refacciones p
  WHERE ((p.id = remision_refaccion_items.remision_id) AND p.es_prueba)))));
CREATE POLICY modo_prueba_lectura ON public.remision_refaccion_ordenes AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR (EXISTS ( SELECT 1
   FROM remisiones_refacciones p
  WHERE ((p.id = remision_refaccion_ordenes.remision_id) AND p.es_prueba)))));
CREATE POLICY rem_ref_ordenes_leer ON public.remision_refaccion_ordenes AS PERMISSIVE FOR SELECT TO authenticated USING ((puede_leer_remision_refaccion(remision_id) OR puede_compras_inventario(auth.uid()) OR puede_finanzas_cobranza(auth.uid())));
CREATE POLICY "actualizar remisiones" ON public.remisiones AS PERMISSIVE FOR UPDATE TO public USING ((has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'coordinador'::app_role) OR ((vendedor_id = auth.uid()) AND usuario_activo(auth.uid()))));
CREATE POLICY "admin de area borra remisiones" ON public.remisiones AS PERMISSIVE FOR DELETE TO authenticated USING (es_admin_area(auth.uid(), 'comercial'::user_area));
CREATE POLICY "administrativo comercial lee remisiones" ON public.remisiones AS PERMISSIVE FOR SELECT TO authenticated USING (es_administrativo_comercial(auth.uid()));
CREATE POLICY "borrar remisiones admin" ON public.remisiones AS PERMISSIVE FOR DELETE TO authenticated USING (has_role(auth.uid(), 'admin'::app_role));
CREATE POLICY "comercial captura remisiones" ON public.remisiones AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (puede_capturar_remision(vendedor_id));
CREATE POLICY "comercial edita sus remisiones" ON public.remisiones AS PERMISSIVE FOR UPDATE TO authenticated USING (puede_editar_remision(id)) WITH CHECK (puede_editar_remision(id));
CREATE POLICY "comercial lee remisiones" ON public.remisiones AS PERMISSIVE FOR SELECT TO authenticated USING ((ve_todo_comercial(auth.uid()) OR (es_area(auth.uid(), 'comercial'::user_area) AND (vendedor_id = auth.uid()) AND usuario_activo(auth.uid())) OR es_area(auth.uid(), 'direccion'::user_area) OR es_area(auth.uid(), 'administracion'::user_area)));
CREATE POLICY "comercial supervisa remisiones" ON public.remisiones AS PERMISSIVE FOR UPDATE TO authenticated USING (supervisa_area(auth.uid(), 'comercial'::user_area));
CREATE POLICY "compras supervisa remisiones captura" ON public.remisiones AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (compras_supervisa_remisiones(auth.uid()));
CREATE POLICY "compras supervisa remisiones lectura" ON public.remisiones AS PERMISSIVE FOR SELECT TO authenticated USING (compras_supervisa_remisiones(auth.uid()));
CREATE POLICY "crear remisiones" ON public.remisiones AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK ((es_area(auth.uid(), 'direccion'::user_area) OR supervisa_area(auth.uid(), 'comercial'::user_area) OR (es_area(auth.uid(), 'comercial'::user_area) AND (vendedor_id = auth.uid()))));
CREATE POLICY "leer remisiones por rol" ON public.remisiones AS PERMISSIVE FOR SELECT TO public USING ((has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'fabrica'::app_role) OR has_role(auth.uid(), 'logistica'::app_role) OR has_role(auth.uid(), 'coordinador'::app_role) OR has_role(auth.uid(), 'finanzas'::app_role) OR has_role(auth.uid(), 'admin_financiero'::app_role) OR ((vendedor_id = auth.uid()) AND usuario_activo(auth.uid()))));
CREATE POLICY modo_prueba_lectura ON public.remisiones AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY modo_prueba_lectura ON public.remisiones_asignacion_acceso AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR (user_id = auth.uid())));
CREATE POLICY remisiones_asignacion_acceso_escritura ON public.remisiones_asignacion_acceso AS PERMISSIVE FOR ALL TO authenticated USING (es_admin_global(auth.uid())) WITH CHECK (es_admin_global(auth.uid()));
CREATE POLICY remisiones_asignacion_acceso_lectura ON public.remisiones_asignacion_acceso AS PERMISSIVE FOR SELECT TO authenticated USING (((user_id = auth.uid()) OR es_admin_global(auth.uid())));
CREATE POLICY "leer bitacora de remisiones" ON public.remisiones_bitacora AS PERMISSIVE FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM remisiones r
  WHERE (r.id = remisiones_bitacora.remision_id))));
CREATE POLICY modo_prueba_lectura ON public.remisiones_bitacora AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY "registrar cambio de remision" ON public.remisiones_bitacora AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK ((usuario_id = auth.uid()));
CREATE POLICY "compras lee remisiones refacciones" ON public.remisiones_refacciones AS PERMISSIVE FOR SELECT TO authenticated USING ((puede_compras_inventario(auth.uid()) OR puede_finanzas_cobranza(auth.uid())));
CREATE POLICY "leer remisiones refacciones" ON public.remisiones_refacciones AS PERMISSIVE FOR SELECT TO authenticated USING (puede_leer_remision_refaccion(id));
CREATE POLICY modo_prueba_lectura ON public.remisiones_refacciones AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR es_prueba));
CREATE POLICY "actualizar reporte turno" ON public.reportes_turno AS PERMISSIVE FOR UPDATE TO authenticated USING ((has_role(auth.uid(), 'admin'::app_role) OR ((usuario_id = auth.uid()) AND (fecha = CURRENT_DATE))));
CREATE POLICY "borrar reporte turno" ON public.reportes_turno AS PERMISSIVE FOR DELETE TO authenticated USING (has_role(auth.uid(), 'admin'::app_role));
CREATE POLICY "insertar reporte turno" ON public.reportes_turno AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK ((has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'fabrica'::app_role)));
CREATE POLICY "leer reportes turno" ON public.reportes_turno AS PERMISSIVE FOR SELECT TO authenticated USING ((has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'fabrica'::app_role) OR has_role(auth.uid(), 'logistica'::app_role) OR has_role(auth.uid(), 'ventas'::app_role) OR has_role(auth.uid(), 'coordinador'::app_role)));
CREATE POLICY modo_prueba_lectura ON public.reportes_turno AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY "ver solicitudes propias o de mi area" ON public.solicitudes_aprobacion AS PERMISSIVE FOR SELECT TO authenticated USING (((solicitado_por = auth.uid()) OR es_admin_de_area(area, auth.uid())));
CREATE POLICY "responder en mi ticket" ON public.soporte_mensajes AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (((autor_tipo = 'usuario'::text) AND (autor_id = auth.uid()) AND (EXISTS ( SELECT 1
   FROM soporte_tickets t
  WHERE ((t.id = soporte_mensajes.ticket_id) AND (t.creado_por = auth.uid()))))));
CREATE POLICY "ver mensajes de mis tickets" ON public.soporte_mensajes AS PERMISSIVE FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM soporte_tickets t
  WHERE ((t.id = soporte_mensajes.ticket_id) AND ((t.creado_por = auth.uid()) OR es_admin_global(auth.uid()))))));
CREATE POLICY "crear ticket propio" ON public.soporte_tickets AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (((creado_por = auth.uid()) AND usuario_activo(auth.uid()) AND (estado = 'abierto'::text)));
CREATE POLICY "ver tickets propios" ON public.soporte_tickets AS PERMISSIVE FOR SELECT TO authenticated USING (((creado_por = auth.uid()) OR es_admin_global(auth.uid())));
CREATE POLICY "actualizar tareas" ON public.tareas AS PERMISSIVE FOR UPDATE TO authenticated USING (((asignado_a = auth.uid()) OR (creado_por = auth.uid()) OR es_admin_de_area(area))) WITH CHECK (((asignado_a = auth.uid()) OR (creado_por = auth.uid()) OR es_admin_de_area(area)));
CREATE POLICY "borrar tareas" ON public.tareas AS PERMISSIVE FOR DELETE TO authenticated USING (((creado_por = auth.uid()) OR es_admin_de_area(area)));
CREATE POLICY "crear tareas" ON public.tareas AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (((creado_por = auth.uid()) AND ((asignado_a = auth.uid()) OR (EXISTS ( SELECT 1
   FROM area_nivel_de(auth.uid()) y(area, nivel)
  WHERE ((y.nivel = ANY (ARRAY['supervisor'::user_nivel, 'admin'::user_nivel])) AND ((y.area = 'direccion'::user_area) OR (y.area = tareas.area))))))));
CREATE POLICY modo_prueba_lectura ON public.tareas AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR false));
CREATE POLICY "ver tareas" ON public.tareas AS PERMISSIVE FOR SELECT TO authenticated USING (((asignado_a = auth.uid()) OR (creado_por = auth.uid()) OR es_admin_de_area(area)));
CREATE POLICY "admin de area gestiona usuarios" ON public.user_roles AS PERMISSIVE FOR ALL TO authenticated USING ((es_admin_global(auth.uid()) OR ((mi_nivel() = 'admin'::user_nivel) AND (area = mi_area())))) WITH CHECK ((es_admin_global(auth.uid()) OR ((mi_nivel() = 'admin'::user_nivel) AND (area = mi_area()))));
CREATE POLICY gestionar_roles ON public.user_roles AS PERMISSIVE FOR ALL TO authenticated USING ((has_role(auth.uid(), 'admin'::app_role) OR (has_role(auth.uid(), 'director_ventas'::app_role) AND (role = ANY (ARRAY['ventas'::app_role, 'auxiliar_ventas'::app_role, 'coordinador_ventas'::app_role]))) OR (has_role(auth.uid(), 'coordinador_ventas'::app_role) AND (role = ANY (ARRAY['ventas'::app_role, 'auxiliar_ventas'::app_role]))) OR (has_role(auth.uid(), 'admin_financiero'::app_role) AND (role = 'finanzas'::app_role)))) WITH CHECK ((has_role(auth.uid(), 'admin'::app_role) OR (has_role(auth.uid(), 'director_ventas'::app_role) AND (role = ANY (ARRAY['ventas'::app_role, 'auxiliar_ventas'::app_role, 'coordinador_ventas'::app_role]))) OR (has_role(auth.uid(), 'coordinador_ventas'::app_role) AND (role = ANY (ARRAY['ventas'::app_role, 'auxiliar_ventas'::app_role]))) OR (has_role(auth.uid(), 'admin_financiero'::app_role) AND (role = 'finanzas'::app_role))));
CREATE POLICY "leer roles propios" ON public.user_roles AS PERMISSIVE FOR SELECT TO authenticated USING (((user_id = auth.uid()) OR has_role(auth.uid(), 'admin'::app_role)));
CREATE POLICY modo_prueba_lectura ON public.user_roles AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR ((user_id = auth.uid()) OR es_usuario_prueba(user_id))));
CREATE POLICY actividades_evidencia_delete ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated USING (((bucket_id = 'actividades-evidencia'::text) AND (es_admin_global(auth.uid()) OR has_role(auth.uid(), 'admin'::app_role) OR ((storage.foldername(name))[1] = (auth.uid())::text))));
CREATE POLICY actividades_evidencia_insert ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (((bucket_id = 'actividades-evidencia'::text) AND usuario_activo(auth.uid()) AND (es_admin_global(auth.uid()) OR es_area(auth.uid(), 'comercial'::user_area) OR has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'ventas'::app_role) OR has_role(auth.uid(), 'coordinador'::app_role)) AND ((storage.foldername(name))[1] = (auth.uid())::text)));
CREATE POLICY actividades_evidencia_select ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated USING (((bucket_id = 'actividades-evidencia'::text) AND usuario_activo(auth.uid()) AND (es_admin_global(auth.uid()) OR es_area(auth.uid(), 'comercial'::user_area) OR es_area(auth.uid(), 'administracion'::user_area) OR has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'ventas'::app_role) OR has_role(auth.uid(), 'coordinador'::app_role) OR has_role(auth.uid(), 'director_ventas'::app_role) OR ((storage.foldername(name))[1] = (auth.uid())::text))));
CREATE POLICY "actualizar docs remisiones admin" ON storage.objects AS PERMISSIVE FOR UPDATE TO authenticated USING (((bucket_id = 'remisiones-docs'::text) AND has_role(auth.uid(), 'admin'::app_role)));
CREATE POLICY "administrativo comercial lee docs remisiones" ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated USING (((bucket_id = 'remisiones-docs'::text) AND es_administrativo_comercial(auth.uid())));
CREATE POLICY "borrar docs remisiones admin" ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated USING (((bucket_id = 'remisiones-docs'::text) AND has_role(auth.uid(), 'admin'::app_role)));
CREATE POLICY clientes_docs_delete ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated USING (((bucket_id = 'clientes-docs'::text) AND (es_admin_global(auth.uid()) OR has_role(auth.uid(), 'admin'::app_role))));
CREATE POLICY clientes_docs_insert ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (((bucket_id = 'clientes-docs'::text) AND usuario_activo(auth.uid()) AND (es_admin_global(auth.uid()) OR es_area(auth.uid(), 'comercial'::user_area) OR es_area(auth.uid(), 'administracion'::user_area) OR has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'ventas'::app_role) OR has_role(auth.uid(), 'coordinador'::app_role))));
CREATE POLICY clientes_docs_select ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated USING (((bucket_id = 'clientes-docs'::text) AND usuario_activo(auth.uid()) AND (es_admin_global(auth.uid()) OR ve_todo_comercial(auth.uid()) OR es_area(auth.uid(), 'administracion'::user_area) OR es_area(auth.uid(), 'fabrica'::user_area) OR has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'coordinador'::app_role) OR has_role(auth.uid(), 'finanzas'::app_role) OR has_role(auth.uid(), 'admin_financiero'::app_role) OR ((es_area(auth.uid(), 'comercial'::user_area) OR has_role(auth.uid(), 'ventas'::app_role)) AND (EXISTS ( SELECT 1
   FROM clientes c
  WHERE ((c.id)::text = (storage.foldername(objects.name))[1])))))));
CREATE POLICY clientes_docs_update ON storage.objects AS PERMISSIVE FOR UPDATE TO authenticated USING (((bucket_id = 'clientes-docs'::text) AND (es_admin_global(auth.uid()) OR es_area(auth.uid(), 'comercial'::user_area) OR has_role(auth.uid(), 'admin'::app_role))));
CREATE POLICY comentarios_fotos_delete ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated USING (((bucket_id = 'comentarios-fotos'::text) AND (es_admin_global(auth.uid()) OR has_role(auth.uid(), 'admin'::app_role))));
CREATE POLICY comentarios_fotos_insert ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (((bucket_id = 'comentarios-fotos'::text) AND usuario_activo(auth.uid()) AND (es_admin_global(auth.uid()) OR es_area(auth.uid(), 'fabrica'::user_area) OR es_area(auth.uid(), 'almacen_logistica'::user_area) OR es_area(auth.uid(), 'comercial'::user_area) OR has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'fabrica'::app_role) OR has_role(auth.uid(), 'logistica'::app_role) OR has_role(auth.uid(), 'ventas'::app_role) OR has_role(auth.uid(), 'coordinador'::app_role))));
CREATE POLICY comentarios_fotos_select ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated USING (((bucket_id = 'comentarios-fotos'::text) AND usuario_activo(auth.uid()) AND (es_admin_global(auth.uid()) OR es_area(auth.uid(), 'fabrica'::user_area) OR es_area(auth.uid(), 'almacen_logistica'::user_area) OR es_area(auth.uid(), 'comercial'::user_area) OR es_area(auth.uid(), 'administracion'::user_area) OR has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'fabrica'::app_role) OR has_role(auth.uid(), 'logistica'::app_role) OR has_role(auth.uid(), 'ventas'::app_role) OR has_role(auth.uid(), 'coordinador'::app_role) OR has_role(auth.uid(), 'finanzas'::app_role) OR has_role(auth.uid(), 'admin_financiero'::app_role))));
CREATE POLICY "compras supervisa docs remisiones leer" ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated USING (((bucket_id = 'remisiones-docs'::text) AND compras_supervisa_remisiones(auth.uid())));
CREATE POLICY "compras supervisa docs remisiones subir" ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (((bucket_id = 'remisiones-docs'::text) AND compras_supervisa_remisiones(auth.uid())));
CREATE POLICY evidencias_compras_insert ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (((bucket_id = 'evidencias-compras'::text) AND puede_leer_compras_inventario(auth.uid())));
CREATE POLICY evidencias_compras_select ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated USING (((bucket_id = 'evidencias-compras'::text) AND puede_leer_compras_inventario(auth.uid())));
CREATE POLICY facturas_delete_finanzas ON storage.objects AS PERMISSIVE FOR DELETE TO public USING (((bucket_id = 'facturas'::text) AND (has_role(auth.uid(), 'admin_financiero'::app_role) OR has_role(auth.uid(), 'admin'::app_role))));
CREATE POLICY facturas_select_finanzas ON storage.objects AS PERMISSIVE FOR SELECT TO public USING (((bucket_id = 'facturas'::text) AND (has_role(auth.uid(), 'finanzas'::app_role) OR has_role(auth.uid(), 'admin_financiero'::app_role) OR has_role(auth.uid(), 'admin'::app_role))));
CREATE POLICY facturas_update_finanzas ON storage.objects AS PERMISSIVE FOR UPDATE TO public USING (((bucket_id = 'facturas'::text) AND (has_role(auth.uid(), 'admin_financiero'::app_role) OR has_role(auth.uid(), 'admin'::app_role))));
CREATE POLICY facturas_upload_finanzas ON storage.objects AS PERMISSIVE FOR INSERT TO public WITH CHECK (((bucket_id = 'facturas'::text) AND (has_role(auth.uid(), 'finanzas'::app_role) OR has_role(auth.uid(), 'admin_financiero'::app_role) OR has_role(auth.uid(), 'admin'::app_role))));
CREATE POLICY finanzas_docs_delete ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated USING (((bucket_id = 'finanzas-docs'::text) AND es_finanzas(auth.uid())));
CREATE POLICY finanzas_docs_insert ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (((bucket_id = 'finanzas-docs'::text) AND es_finanzas(auth.uid())));
CREATE POLICY finanzas_docs_select ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated USING (((bucket_id = 'finanzas-docs'::text) AND es_finanzas(auth.uid())));
CREATE POLICY firmas_storage_select ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated USING (((bucket_id = 'firmas'::text) AND ((storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'::text) AND ((storage.foldername(name))[2] IS NULL) AND (name !~ '/sig-'::text) AND firmas_puede_ver_solicitud(((storage.foldername(name))[1])::uuid)));
CREATE POLICY "leer docs remisiones operativos" ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated USING (((bucket_id = 'remisiones-docs'::text) AND usuario_activo(auth.uid()) AND (es_admin_global(auth.uid()) OR es_area(auth.uid(), 'fabrica'::user_area) OR es_area(auth.uid(), 'almacen_logistica'::user_area) OR es_area(auth.uid(), 'administracion'::user_area) OR es_area(auth.uid(), 'direccion'::user_area) OR has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'fabrica'::app_role) OR has_role(auth.uid(), 'logistica'::app_role) OR has_role(auth.uid(), 'coordinador'::app_role) OR has_role(auth.uid(), 'finanzas'::app_role) OR has_role(auth.uid(), 'admin_financiero'::app_role) OR has_role(auth.uid(), 'director_ventas'::app_role) OR has_role(auth.uid(), 'coordinador_ventas'::app_role) OR ((es_area(auth.uid(), 'comercial'::user_area) OR has_role(auth.uid(), 'ventas'::app_role) OR has_role(auth.uid(), 'auxiliar_ventas'::app_role)) AND (EXISTS ( SELECT 1
   FROM remisiones r
  WHERE (((r.id)::text = (storage.foldername(objects.name))[1]) AND (r.vendedor_id = auth.uid()))))))));
CREATE POLICY modo_prueba_archivos_borrar ON storage.objects AS RESTRICTIVE FOR DELETE TO authenticated USING ((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)));
CREATE POLICY modo_prueba_archivos_cambiar ON storage.objects AS RESTRICTIVE FOR UPDATE TO authenticated USING ((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)));
CREATE POLICY modo_prueba_archivos_leer ON storage.objects AS RESTRICTIVE FOR SELECT TO authenticated USING (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR ((bucket_id = 'evidencias-compras'::text) AND (name ~~ 'prueba/%'::text))));
CREATE POLICY modo_prueba_archivos_subir ON storage.objects AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (((NOT ( SELECT es_usuario_prueba(auth.uid()) AS es_usuario_prueba)) OR ((bucket_id = 'evidencias-compras'::text) AND (name ~~ 'prueba/%'::text))));
CREATE POLICY ref_fotos_actualizar ON storage.objects AS PERMISSIVE FOR UPDATE TO authenticated USING (((bucket_id = 'refacciones-fotos'::text) AND puede_ver_almacen_refacciones())) WITH CHECK (((bucket_id = 'refacciones-fotos'::text) AND puede_ver_almacen_refacciones()));
CREATE POLICY ref_fotos_borrar ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated USING (((bucket_id = 'refacciones-fotos'::text) AND puede_ver_almacen_refacciones()));
CREATE POLICY ref_fotos_leer ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated USING ((bucket_id = 'refacciones-fotos'::text));
CREATE POLICY ref_fotos_leer_anon ON storage.objects AS PERMISSIVE FOR SELECT TO anon USING ((bucket_id = 'refacciones-fotos'::text));
CREATE POLICY ref_fotos_subir ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (((bucket_id = 'refacciones-fotos'::text) AND puede_ver_almacen_refacciones()));
CREATE POLICY "subir docs remisiones admin/ventas" ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (((bucket_id = 'remisiones-docs'::text) AND (has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'ventas'::app_role))));
CREATE POLICY "subir docs remisiones comercial" ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (((bucket_id = 'remisiones-docs'::text) AND usuario_activo(auth.uid()) AND (has_role(auth.uid(), 'coordinador_ventas'::app_role) OR has_role(auth.uid(), 'director_ventas'::app_role) OR ((has_role(auth.uid(), 'auxiliar_ventas'::app_role) OR es_area(auth.uid(), 'comercial'::user_area)) AND (EXISTS ( SELECT 1
   FROM remisiones r
  WHERE (((r.id)::text = (storage.foldername(objects.name))[1]) AND (r.vendedor_id = auth.uid()))))))));

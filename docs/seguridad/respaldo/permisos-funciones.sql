-- Permisos de ejecución de funciones de public (anon, authenticated, PUBLIC)
-- Proyecto Supabase: kit-to-drive (dmhzhyeivvuliumcgsmm), producción.
-- Capturado: 2026-10-25 19:14 UTC, solo lectura. No contiene datos de negocio.
-- Generado con docs/seguridad/consultas/00-respaldo-catalogo.sql
-- Para restaurar un permiso quitado: ejecutar la línea GRANT correspondiente.

GRANT EXECUTE ON FUNCTION public._fijar_color_original() TO authenticated;  -- SECURITY INVOKER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public._folio_incidencia() TO authenticated;  -- SECURITY INVOKER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public._trg_recalcular_colores() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public._verificar_capacidad_color() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.abc_leyenda_sello() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.actualizar_articulo_refaccion(_id uuid, _datos jsonb) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.actualizar_compra_refacciones(_id uuid, _cabecera jsonb, _lineas jsonb) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.actualizar_envio_remision_refaccion(_remision_id uuid, _envio jsonb) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.ajustar_capacidad_color(_modelo text, _color text, _piezas_recibidas integer, _motivo text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.ajustar_compra_faltante(_compra_linea_id uuid, _accion text, _notas text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.ajustar_unidades_remision(_remision_id uuid, _total_objetivo integer, _motivo text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.ajuste_motivo_de_prueba() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.alta_articulo_refaccion(_datos jsonb) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.aplicar_abono_cxc() TO authenticated;  -- SECURITY INVOKER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.aplicar_ajuste_rapido(_almacen text, _fecha date, _motivo text, _motivo_texto text, _lineas jsonb, _evidencia text, _notas text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.aplicar_datos_maestros_refacciones(_items jsonb) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.aplicar_pago_cobranza(_pago_id uuid, _aplicaciones jsonb, _remanente_a_saldo boolean, _notas text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.aplicar_saldo_favor(_saldo_id uuid, _remision_id uuid, _monto numeric, _solicitud_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.area_nivel_de(_user_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.area_que_aprueba(_objeto text) TO authenticated;  -- SECURITY INVOKER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.asignar_chasis_remision(_remision_id uuid, _cantidad integer, _color text, _modelo text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.asignar_motocarro_a_remision(_motocarro_id uuid, _remision_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.asignar_remision_items(_remision_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.asignar_super_admin(_user_id uuid, _activo boolean) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.asignar_vendedor_remision(_tipo text, _remision_id uuid, _vendedor_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.auto_asignar_motocarros_remision() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.avisar_faltante_refaccion(_remision_id uuid, _item_id uuid, _detalle text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.aviso_marca_prueba() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.bitacora_solo_agregar() TO authenticated;  -- SECURITY INVOKER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.buscar_modelos_refacciones(_q text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.cambiar_color_chasis(_chasis_id uuid, _color_nuevo text, _motivo text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.cambiar_orden_armado(_motocarro_id uuid, _orden_nuevo integer, _motivo text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.cancelar_compra_refacciones(_id uuid, _motivo text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.cancelar_linea_refaccion(_item_id uuid, _motivo text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.cancelar_remision_refacciones(_remision_id uuid, _motivo text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.candado_descuento_con_pago() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.candado_entrega_con_pago() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.candado_linea_refaccion() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.candado_modo_prueba() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.capacidad_color_libre(_modelo text, _color text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.capturar_seriales_unidad(_motocarro_id uuid, _ns_chasis text, _ns_motor text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.cargar_existencia_inicial_refacciones(_almacen text, _fecha date, _items jsonb) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.cargar_saldos_iniciales_cobranza(_items jsonb, _confirmacion text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.catalogo_inventario_guardia() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.chasis_bloqueado(_chasis_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.clave_catalogo_usada(_tabla text, _clave text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.cliente_marca_prueba() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.cliente_tiene_credito(_cliente_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.cliente_tiene_cxc_vencidas(_cliente_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.cobranza_inmutable() TO authenticated;  -- SECURITY INVOKER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.completar_movimiento_refaccion() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.compras_parametro(_clave text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.compras_parametros_guardia() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.compras_supervisa_remisiones(_user_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.configurar_pedido_remision(_remision_id uuid, _items jsonb) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.configurar_unidad(_chasis_id uuid, _motor_id uuid, _orden integer, _color text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.confirmar_compra_refacciones(_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.confirmar_compras_refacciones(_ids uuid[]) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.confirmar_entrega_credito(_motocarro_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.confirmar_fecha_entrega(_motocarro_id uuid, _area text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.confirmar_sin_existencia_refaccion(_item_id uuid, _nota text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.corregir_remision_refaccion(_remision_id uuid, _cambios jsonb, _motivo text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.crear_compra(_folio text, _proveedor_id uuid, _contenedor_id uuid, _fecha date, _notas text, _lineas jsonb) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.crear_compra_refacciones(_cabecera jsonb, _lineas jsonb, _pendientes jsonb) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.crear_motocarro_ya_armado(_ns_chasis text, _ns_motor text, _modelo text, _color text, _remision_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.crear_remision_refacciones(_cliente_id uuid, _notas text, _nombre_vendedor text, _items jsonb) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.crear_remision_refacciones(_cliente_id uuid, _notas text, _nombre_vendedor text, _items jsonb, _envio jsonb) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.cxc_vencidas_resumen(_cliente_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.decrementar_inventario_color(_modelo text, _color text, _cantidad integer) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.desasignar_motocarro_de_remision(_motocarro_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.desconfigurar_unidad(_motocarro_id uuid, _motivo text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.disponible_pago_cobranza(_pago_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.disponible_saldo_favor(_saldo_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.dividir_compra_refacciones(_id uuid, _linea_ids uuid[], _almacen text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.eliminar_compra_refacciones(_id uuid, _motivo text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.eliminar_solicitud_aprobacion(_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.entregar_remision_refaccion(_remision_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.es_admin_area(_user_id uuid, _area user_area) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.es_admin_compras(_uid uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.es_admin_de_area(_area user_area, _user_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.es_admin_global(_user_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.es_administrativo_comercial(_user_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.es_area(_user_id uuid, _area user_area) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.es_compras(_uid uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.es_compras_admin(_uid uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.es_finanzas(_uid uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.es_finanzas_admin(_uid uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.es_rpc_con_aprobacion(_nombre text) TO authenticated;  -- SECURITY INVOKER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.es_super_admin(_user_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.es_usuario_prueba(_uid uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.es_usuario_prueba_actual() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.es_vendedor_activo(_user_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.estado_cobro_remision_refaccion(_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.exigir_serial_para_cerrar() TO authenticated;  -- SECURITY INVOKER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.firmas_puede_ver_solicitud(_solicitud uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.flujo_aplicar(_id uuid, _destino text, _aplicaciones jsonb, _notas text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.flujo_asignar_capacidad(_user_id uuid, _capacidad text, _valor boolean) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.flujo_cap(_cap text, _uid uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.flujo_clientes() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.flujo_confirmar_caja(_id uuid, _cuenta_id uuid, _notas text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.flujo_cuentas() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.flujo_es_admin(_uid uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.flujo_listar_capacidades() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.flujo_mis_capacidades() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.flujo_nombre(_uid uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.flujo_rechazar(_id uuid, _motivo text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.flujo_recibir(_tipo text, _monto numeric, _moneda text, _metodo_pago text, _fecha date, _contraparte_nombre text, _cliente_id uuid, _concepto text, _referencia text, _tipo_cambio numeric) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.flujo_remisiones_para_aplicar(_flujo_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.generar_folio_interno_cliente() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.get_my_role() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.guardar_almacen_inventario(_clave text, _nombre text, _descripcion text, _recibe_compras boolean, _activo boolean) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.guardar_equivalente_ecount(_clave text, _equivalente text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.guardar_motivo_ajuste(_clave text, _nombre text, _requiere_texto boolean, _activo boolean, _orden integer) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.has_role(_user_id uuid, _role app_role) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.impedir_inventario_negativo() TO authenticated;  -- SECURITY INVOKER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.importar_almacen_refacciones(_items jsonb) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.importar_motores_inventario(_contenedor_id uuid, _modelo text, _motores jsonb) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.importar_packing_list(_contenedor_id uuid, _partes jsonb) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.importar_vins_inventario(_contenedor_id uuid, _folio_contenedor text, _modelo text, _vins jsonb) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.importe_partida_refaccion(_precio numeric, _piezas integer, _desc_partida numeric, _desc_general numeric) TO authenticated;  -- SECURITY INVOKER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.incrementar_inventario_color(_modelo text, _color text, _cantidad integer) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.intercambiar_color_chasis(_chasis_a uuid, _chasis_b uuid, _motivo text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.kardex_refaccion(_producto uuid, _desde date, _hasta date) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.liberar_refaccion_remision(_item_id uuid, _cantidad integer) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.limpiar_entrega_programada_refaccion() TO PUBLIC;  -- SECURITY INVOKER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.limpiar_entrega_programada_refaccion() TO authenticated;  -- SECURITY INVOKER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.log_borrado_movimiento() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.log_motocarros_changes() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.log_movimiento() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.log_remisiones_changes() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.log_reporte_turno() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.logistica_puede_entregar(_user_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.marcar_comprobacion_movimiento() TO authenticated;  -- SECURITY INVOKER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.marcar_pago_remision_con_evidencia(_remision_id uuid, _pagado boolean, _nota text, _evidencia_path text, _conciliado boolean) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.marcar_pago_remision_refaccion(_remision_id uuid, _pagado boolean, _nota text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.marcar_remision_entregada(_remision_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.marcar_unidad_entregada(_motocarro_id uuid, _fecha date) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.mi_area() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.mi_nivel() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.movimiento_refaccion_inmutable() TO authenticated;  -- SECURITY INVOKER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.nivel_al_menos(_user_id uuid, _nivel user_nivel) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.nivel_rank(_nivel user_nivel) TO authenticated;  -- SECURITY INVOKER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.norm_color(_color text) TO authenticated;  -- SECURITY INVOKER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.normalizar_modelo_refaccion(_t text) TO authenticated;  -- SECURITY INVOKER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.parear_unidades_contenedor(_contenedor_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.partida_refaccion_a_orden() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.partida_refaccion_candado_prueba() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.patch_corregir_surtido_indebido_faltante() TO authenticated;  -- SECURITY INVOKER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.programar_entrega_remision_refaccion(_remision_id uuid, _fecha date) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.proponer_conteo_fisico(_almacen text, _fecha date, _lineas jsonb, _notas text, _evidencia text, _motivo text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.proponer_fecha_entrega(_motocarro_id uuid, _fecha date, _notas text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.proteger_campos_privilegiados_profiles() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.puede_almacen_fisico(_uid uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.puede_aplicar_saldo_favor(_uid uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.puede_asignar_remisiones(_user_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.puede_capturar_refacciones(_user_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.puede_capturar_remision(_vendedor_id uuid, _user_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.puede_cargar_remisiones_anteriores(_user_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.puede_compras_inventario(_uid uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.puede_configurar_pedido(_remision_id uuid, _user_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.puede_editar_remision(_remision_id uuid, _user_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.puede_editar_todas_remisiones(_user_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.puede_escribir_inventario(_uid uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.puede_finanzas_cobranza(_uid uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.puede_leer_compras_inventario(_uid uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.puede_leer_inventario(_uid uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.puede_leer_remision_refaccion(_remision_id uuid, _user_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.puede_marcar_pago_refacciones(_user_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.puede_operar_almacen_refacciones(_user_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.puede_operar_logistica_refacciones(_user_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.puede_ver_almacen_refacciones(_user_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.reabrir_incidencia_chasis(_incidencia_id uuid, _motivo text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.recalcular_etapa_remision_refaccion(_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.recalcular_inventario_colores() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.recibe_avisos_de(_area user_area, _user_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.recibir_contenedor(_folio_contenedor text, _fecha_arribo date, _modelo text, _color text, _unidades jsonb) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.recibo_pago_cobranza(_pago_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.redirigir_compat_unificada() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.registrar_conexion() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.registrar_correccion_partida() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.registrar_correccion_remision() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.registrar_documento_inventario(_contenedor_id uuid, _compra_id uuid, _origen text, _notas text, _lineas jsonb) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.registrar_guia_remision_refaccion(_remision_id uuid, _paqueteria text, _guia text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.registrar_pago_cobranza(_datos jsonb) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.registrar_paqueteria(_motocarro_id uuid, _paqueteria text, _numero_guia text, _fecha_estimada date) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.registrar_recepcion_refacciones(_compra_id uuid, _fecha date, _lineas jsonb, _notas text, _visto_bueno boolean) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.reiniciar_datos_prueba_compras(_confirmacion text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.reintentar_asignar_remision(_remision_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.remision_refaccion_marca_prueba() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.reportar_faltante_refaccion(_item_id uuid, _cantidad integer, _nota text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.reportar_incidencia_chasis(_chasis_id uuid, _tipo_falla text, _descripcion text, _parte_afectada text, _severidad text, _retiene boolean, _evidencia_url text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.resolver_incidencia_chasis(_incidencia_id uuid, _resultado text, _resolucion text, _folio_garantia text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.resolver_pendiente_compra_refacciones(_pendiente_id uuid, _producto_id uuid, _cantidad integer, _nota text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.resolver_solicitud_aprobacion(_id uuid, _aprobar boolean, _comentario text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.responder_solicitud(_aviso_id uuid, _aceptar boolean, _respuesta text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.resumen_rotacion_refacciones(_desde date, _hasta date, _incluir_prueba boolean) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.revertir_aplicacion_cobranza(_aplicacion_id uuid, _motivo text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.revertir_pago_cobranza(_pago_id uuid, _motivo text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.revisar_incidencia_chasis(_incidencia_id uuid, _nota text, _retiene boolean) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.revisar_propuesta_ajuste(_id uuid, _aprobar boolean, _comentario text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.rol_comercial(_user_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.rol_legacy(_area user_area, _nivel user_nivel) TO authenticated;  -- SECURITY INVOKER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.saldo_favor_disponible_cliente(_cliente_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.saldo_inicial_sin_documento(_producto uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.saldo_minimo_desde(_producto uuid, _fecha date) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.saldo_refaccion_a_fecha(_producto uuid, _fecha date) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.saldos_atipicos_refacciones(_incluir_prueba boolean) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.salidas_por_cliente_mes(_producto uuid, _desde date, _hasta date) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.sembrar_datos_prueba_compras() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.set_folio_cxc() TO authenticated;  -- SECURITY INVOKER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.set_folio_movimiento() TO authenticated;  -- SECURITY INVOKER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.sincronizar_compat_refacciones(_items jsonb) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.solicitar_aprobacion(_tipo text, _objeto text, _parametros jsonb, _descripcion text, _motivo text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.solicitar_saldo_favor(_remision_id uuid, _monto numeric, _nota text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.stock_bloqueado_producto(_producto_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.sufijo_orden_almacen(_almacen text) TO authenticated;  -- SECURITY INVOKER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.super_admins_ids() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.supervisa_area(_user_id uuid, _area user_area) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.sync_rol_legacy() TO authenticated;  -- SECURITY INVOKER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.sync_tiene_factura() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.total_vigente_remision_refaccion(_id uuid, _desc_general numeric) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.trg_avisos_solo_acuse() TO authenticated;  -- SECURITY INVOKER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.trg_clientes_folio_interno() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.trg_crm_actividades_aviso_correo() TO authenticated;  -- SECURITY INVOKER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.trg_notificaciones_solo_leida() TO authenticated;  -- SECURITY INVOKER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.trg_tareas_guardia() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.unificar_unidades_refacciones(_destino uuid, _origenes uuid[], _nombre_final text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.usuario_activo(_user_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.usuario_operativo(_user_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.usuarios_asignables() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.validar_moneda_cuenta() TO authenticated;  -- SECURITY INVOKER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.validar_pago_cobranza(_pago_id uuid, _conciliado boolean, _evidencia_path text) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.ve_todo_comercial(_user_id uuid) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.ventas_mensuales_refacciones(_desde date, _hasta date, _incluir_prueba boolean) TO authenticated;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.vigilar_super_admin() TO anon;  -- SECURITY DEFINER, otorgado por postgres
GRANT EXECUTE ON FUNCTION public.vigilar_super_admin() TO authenticated;  -- SECURITY DEFINER, otorgado por postgres

-- ============================================================================
-- REVERSA: devuelve EXECUTE a PUBLIC, anon y authenticated en las funciones de trigger, como estaban el 25 oct 2026
--
-- Fase 1 de seguridad de la base de producción (docs/seguridad/). Reversa del punto 2.
-- ============================================================================
-- Generada del respaldo docs/seguridad/respaldo/permisos-funciones.sql. Solo repone lo que existía.
-- ============================================================================
GRANT EXECUTE ON FUNCTION public._fijar_color_original() TO authenticated;
GRANT EXECUTE ON FUNCTION public._folio_incidencia() TO authenticated;
GRANT EXECUTE ON FUNCTION public._trg_recalcular_colores() TO authenticated;
GRANT EXECUTE ON FUNCTION public._verificar_capacidad_color() TO authenticated;
GRANT EXECUTE ON FUNCTION public.abc_leyenda_sello() TO authenticated;
GRANT EXECUTE ON FUNCTION public.ajuste_motivo_de_prueba() TO authenticated;
GRANT EXECUTE ON FUNCTION public.aplicar_abono_cxc() TO authenticated;
GRANT EXECUTE ON FUNCTION public.auto_asignar_motocarros_remision() TO authenticated;
GRANT EXECUTE ON FUNCTION public.aviso_marca_prueba() TO authenticated;
GRANT EXECUTE ON FUNCTION public.bitacora_solo_agregar() TO authenticated;
GRANT EXECUTE ON FUNCTION public.candado_descuento_con_pago() TO authenticated;
GRANT EXECUTE ON FUNCTION public.candado_entrega_con_pago() TO authenticated;
GRANT EXECUTE ON FUNCTION public.candado_linea_refaccion() TO authenticated;
GRANT EXECUTE ON FUNCTION public.candado_modo_prueba() TO authenticated;
GRANT EXECUTE ON FUNCTION public.catalogo_inventario_guardia() TO authenticated;
GRANT EXECUTE ON FUNCTION public.cliente_marca_prueba() TO authenticated;
GRANT EXECUTE ON FUNCTION public.cobranza_inmutable() TO authenticated;
GRANT EXECUTE ON FUNCTION public.completar_movimiento_refaccion() TO authenticated;
GRANT EXECUTE ON FUNCTION public.compras_parametros_guardia() TO authenticated;
GRANT EXECUTE ON FUNCTION public.exigir_serial_para_cerrar() TO authenticated;
GRANT EXECUTE ON FUNCTION public.impedir_inventario_negativo() TO authenticated;
GRANT EXECUTE ON FUNCTION public.limpiar_entrega_programada_refaccion() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.limpiar_entrega_programada_refaccion() TO authenticated;
GRANT EXECUTE ON FUNCTION public.log_borrado_movimiento() TO authenticated;
GRANT EXECUTE ON FUNCTION public.log_motocarros_changes() TO authenticated;
GRANT EXECUTE ON FUNCTION public.log_movimiento() TO authenticated;
GRANT EXECUTE ON FUNCTION public.log_remisiones_changes() TO authenticated;
GRANT EXECUTE ON FUNCTION public.log_reporte_turno() TO authenticated;
GRANT EXECUTE ON FUNCTION public.marcar_comprobacion_movimiento() TO authenticated;
GRANT EXECUTE ON FUNCTION public.movimiento_refaccion_inmutable() TO authenticated;
GRANT EXECUTE ON FUNCTION public.partida_refaccion_a_orden() TO authenticated;
GRANT EXECUTE ON FUNCTION public.partida_refaccion_candado_prueba() TO authenticated;
GRANT EXECUTE ON FUNCTION public.proteger_campos_privilegiados_profiles() TO authenticated;
GRANT EXECUTE ON FUNCTION public.redirigir_compat_unificada() TO authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_correccion_partida() TO authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_correccion_remision() TO authenticated;
GRANT EXECUTE ON FUNCTION public.remision_refaccion_marca_prueba() TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_folio_cxc() TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_folio_movimiento() TO authenticated;
GRANT EXECUTE ON FUNCTION public.sync_rol_legacy() TO authenticated;
GRANT EXECUTE ON FUNCTION public.sync_tiene_factura() TO authenticated;
GRANT EXECUTE ON FUNCTION public.trg_avisos_solo_acuse() TO authenticated;
GRANT EXECUTE ON FUNCTION public.trg_clientes_folio_interno() TO authenticated;
GRANT EXECUTE ON FUNCTION public.trg_crm_actividades_aviso_correo() TO authenticated;
GRANT EXECUTE ON FUNCTION public.trg_notificaciones_solo_leida() TO authenticated;
GRANT EXECUTE ON FUNCTION public.trg_tareas_guardia() TO authenticated;
GRANT EXECUTE ON FUNCTION public.validar_moneda_cuenta() TO authenticated;
GRANT EXECUTE ON FUNCTION public.vigilar_super_admin() TO anon;
GRANT EXECUTE ON FUNCTION public.vigilar_super_admin() TO authenticated;

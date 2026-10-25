# Clasificación de las funciones de `public` (Fase 0, sección 3.3)

Proyecto Supabase `kit-to-drive` (producción). Capturado 2026-10-25 19:14 UTC, solo lectura. No se cambió ninguna función.

## Resumen

| Grupo | Qué es | Funciones | Qué haría la Fase 1 |
|---|---|---|---|
| 1 | Funciones de trigger | 53 | Quitar el acceso a `anon`, `authenticated` y PUBLIC. Ver «Condición» abajo. |
| 2 | Las usan políticas, vistas, defaults o restricciones | 40 | No se tocan. Se quedan ejecutables por usuarios con sesión. |
| 3A | RPC que llama el front o la compuerta, más una que llama una Edge Function | 101 | No se tocan; se auditan una por una (abajo). |
| 3B | Ejecutables por usuarios con sesión y sin llamador conocido en el código | 46 | No se tocan. Candidatas a cerrar en una fase posterior, tras confirmar con el equipo. |
| 3C | Internas: los usuarios con sesión no las pueden ejecutar | 28 | Nada que hacer. |

Total: 268 funciones (240 son SECURITY DEFINER). Se excluyen las de extensiones.

### Cómo se clasificó

- **Trigger:** el tipo de retorno es `trigger`.
- **Grupo 2:** `pg_depend` dice que una política, vista, default o restricción depende de la función. Es más fiable que buscar el nombre en el texto.
- **Grupo 3A:** el nombre aparece en una llamada `.rpc(...)` del front (`kit-to-drive`, código de producción, sin pruebas), en la lista blanca vigente de la compuerta (`kit-to-drive-front`, `origin/main` = despliegue de producción `843cc92`) o en una Edge Function.
- **Orden de prioridad:** trigger, luego grupo 2, luego grupo 3. Una función usada por una política y también por el front va en el grupo 2.
- **Auditoría del grupo 3A:** revisión automática del cuerpo (¿usa `auth.uid()`, una función de permiso, un `RAISE EXCEPTION`?) y lectura a mano de las que la revisión automática no pudo dar por buenas (se leyó el cuerpo de 22 de las 24; `super_admins_ids` y `es_super_admin` quedan marcadas «revisar» y sin leer a mano).

### Limitaciones (lo que no se verificó)

- La revisión automática del grupo 3A **no valida la lógica de negocio** de cada función: confirma que existe una verificación de identidad y permiso, no que sea la correcta. Las marcadas «OK (automática)» son un supuesto razonable, no una auditoría línea por línea.
- Los llamadores salen de buscar `.rpc('nombre')` en el código. Una llamada armada con una variable no aparece; por eso el grupo 3B se trata como «sin llamador conocido» y no como «sin uso».
- No se revisaron las funciones del grupo 3B.

## Hallazgos de la auditoría

| Función | Gravedad | Qué pasa |
|---|---|---|
| `cliente_tiene_cxc_vencidas` | MEDIA | SECURITY DEFINER sin identidad ni permiso: cualquier usuario con sesión consulta si un cliente tiene cuentas por cobrar vencidas, saltándose las políticas de cuentas_por_cobrar. |
| `cxc_vencidas_resumen` | MEDIA | SECURITY DEFINER sin identidad ni permiso: devuelve folio, saldo y vencimiento de las cuentas vencidas de cualquier cliente a cualquier usuario con sesión. |
| `saldo_refaccion_a_fecha` | BAJA | SECURITY DEFINER sin permiso: devuelve el saldo histórico de una refacción a cualquier usuario con sesión. |
| `compras_parametro` | BAJA | SECURITY DEFINER sin permiso: lee cualquier parámetro de compras por clave. Las políticas lo usan; hay que revisar qué claves existen antes de restringirlo. |
| `puede_*(uid)`, `es_*(uid)`, `has_role(uid, …)` y similares | BAJA | Aceptan el uid de otra persona y cualquier usuario con sesión puede preguntar por los roles de otros. Las políticas las necesitan. |

Ninguno de estos hallazgos se corrige en la Fase 1. Se proponen para una fase posterior, con prueba por rol.

## Grupo 1: funciones de trigger

**Condición.** Un incidente anterior (`20261009000002` → `20261010000001`) dejó claro que quitar EXECUTE a PUBLIC rompió el alta de usuarios, porque el rol de Auth (`supabase_auth_admin`) disparaba `handle_new_user()` con el permiso heredado de PUBLIC. Los dos triggers de `auth.users` ya tienen permiso explícito para ese rol. Para los 240 triggers sobre tablas de `public` el ensayo debe demostrar que quitar EXECUTE a `authenticated` no rompe las escrituras.

| Función | Triggers que la usan | `authenticated` | `anon` | Nota |
|---|---|---|---|---|
| `_fijar_color_original` | 1 | sí | no |  |
| `_folio_incidencia` | 1 | sí | no |  |
| `_trg_recalcular_colores` | 2 | sí | no |  |
| `_verificar_capacidad_color` | 1 | sí | no |  |
| `abc_leyenda_sello` | 1 | sí | no |  |
| `ajuste_motivo_de_prueba` | 1 | sí | no |  |
| `aplicar_abono_cxc` | 1 | sí | no |  |
| `auto_asignar_motocarros_remision` | 0 | sí | no | sin trigger asociado (huérfana) |
| `aviso_marca_prueba` | 1 | sí | no |  |
| `bitacora_solo_agregar` | 1 | sí | no |  |
| `candado_descuento_con_pago` | 2 | sí | no |  |
| `candado_entrega_con_pago` | 1 | sí | no |  |
| `candado_linea_refaccion` | 1 | sí | no |  |
| `candado_modo_prueba` | 79 | sí | no |  |
| `catalogo_inventario_guardia` | 2 | sí | no |  |
| `cliente_marca_prueba` | 1 | sí | no |  |
| `cobranza_inmutable` | 4 | sí | no |  |
| `completar_movimiento_refaccion` | 1 | sí | no |  |
| `compras_parametros_guardia` | 1 | sí | no |  |
| `exigir_serial_para_cerrar` | 1 | sí | no |  |
| `flujo_dinero_sin_borrar` | 1 | no | no |  |
| `handle_new_user` | 1 | no | no | trigger sobre `auth.users`; permiso explícito para `supabase_auth_admin` |
| `impedir_escalada_rol` | 1 | no | no |  |
| `impedir_inventario_negativo` | 2 | sí | no |  |
| `limpiar_entrega_programada_refaccion` | 1 | sí | sí | la ejecuta `anon` hoy, por PUBLIC (se creó sin REVOKE) |
| `log_borrado_movimiento` | 1 | sí | no |  |
| `log_motocarros_changes` | 1 | sí | no |  |
| `log_movimiento` | 1 | sí | no |  |
| `log_remisiones_changes` | 1 | sí | no |  |
| `log_reporte_turno` | 1 | sí | no |  |
| `marcar_comprobacion_movimiento` | 1 | sí | no |  |
| `movimiento_refaccion_inmutable` | 1 | sí | no |  |
| `partida_refaccion_a_orden` | 1 | sí | no |  |
| `partida_refaccion_candado_prueba` | 1 | sí | no |  |
| `proteger_campos_privilegiados_profiles` | 1 | sí | no |  |
| `proteger_profile_activo` | 1 | no | no |  |
| `redirigir_compat_unificada` | 1 | sí | no |  |
| `registrar_correccion_partida` | 1 | sí | no |  |
| `registrar_correccion_remision` | 1 | sí | no |  |
| `reject_public_signups` | 1 | no | no | trigger sobre `auth.users`; permiso explícito para `supabase_auth_admin` |
| `remision_refaccion_marca_prueba` | 1 | sí | no |  |
| `set_folio_cxc` | 1 | sí | no |  |
| `set_folio_movimiento` | 1 | sí | no |  |
| `set_updated_at` | 24 | no | no |  |
| `sync_rol_legacy` | 1 | sí | no |  |
| `sync_tiene_factura` | 1 | sí | no |  |
| `trg_avisos_solo_acuse` | 1 | sí | no |  |
| `trg_clientes_folio_interno` | 1 | sí | no |  |
| `trg_crm_actividades_aviso_correo` | 1 | sí | no |  |
| `trg_notificaciones_solo_leida` | 1 | sí | no |  |
| `trg_tareas_guardia` | 1 | sí | no |  |
| `validar_moneda_cuenta` | 1 | sí | no |  |
| `vigilar_super_admin` | 83 | sí | sí | la ejecuta `anon` hoy; permiso explícito sobrante para `supabase_auth_admin` |

## Grupo 2: funciones que usan políticas, vistas, defaults o restricciones

Se quedan accesibles para usuarios con sesión: las políticas se evalúan con el rol de quien consulta y necesitan poder ejecutarlas.

| Función | Políticas | Vistas | También la llama el front | Ejemplo de uso |
|---|---|---|---|---|
| `area_nivel_de(_user_id uuid)` | 1 | 0 | no | public.tareas:crear tareas |
| `cliente_tiene_credito(_cliente_id uuid)` | 0 | 1 | no | vista |
| `compras_supervisa_remisiones(_user_id uuid)` | 5 | 0 | no | public.motocarros:compras supervisa motocarros de remisiones |
| `disponible_pago_cobranza(_pago_id uuid)` | 0 | 1 | no | vista |
| `disponible_saldo_favor(_saldo_id uuid)` | 0 | 1 | no | vista |
| `es_admin_area(_user_id uuid, _area user_area)` | 6 | 0 | no | public.clientes:admin de area borra clientes |
| `es_admin_de_area(_area user_area, _user_id uuid)` | 5 | 0 | no | public.solicitudes_aprobacion:ver solicitudes propias o de mi area |
| `es_admin_global(_user_id uuid)` | 37 | 0 | no | public.almacen_refacciones_acceso:ref_acceso_escribir |
| `es_administrativo_comercial(_user_id uuid)` | 4 | 0 | no | public.clientes:administrativo comercial lee clientes |
| `es_area(_user_id uuid, _area user_area)` | 30 | 0 | no | public.bitacora_eventos:admin de area lee bitacora |
| `es_compras(_uid uuid)` | 6 | 0 | no | public.compra_lineas:leer compra lineas |
| `es_compras_admin(_uid uuid)` | 1 | 0 | no | public.proveedores:proveedores_delete |
| `es_finanzas(_uid uuid)` | 19 | 0 | no | public.categorias_financieras:categorias_select |
| `es_finanzas_admin(_uid uuid)` | 11 | 0 | no | public.categorias_financieras:categorias_write |
| `es_usuario_prueba(_uid uuid)` | 73 | 0 | sí | public.ajuste_inventario_lineas:modo_prueba_lectura |
| `estado_cobro_remision_refaccion(_id uuid)` | 0 | 1 | sí | vista |
| `firmas_puede_ver_solicitud(_solicitud uuid)` | 3 | 0 | no | public.firmas_firmantes:firmas_firmantes_select |
| `flujo_cap(_cap text, _uid uuid)` | 1 | 0 | no | public.flujo_dinero:flujo_dinero_leer |
| `flujo_es_admin(_uid uuid)` | 2 | 0 | no | public.flujo_capacidades:flujo_capacidades_leer |
| `flujo_nombre(_uid uuid)` | 0 | 1 | no | vista |
| `has_role(_user_id uuid, _role app_role)` | 86 | 0 | no | public.bitacora_compras_inventario:bitacora_compras_leer |
| `mi_area()` | 3 | 0 | no | public.profiles:admin de area actualiza profiles |
| `mi_nivel()` | 3 | 0 | no | public.profiles:admin de area actualiza profiles |
| `nivel_al_menos(_user_id uuid, _nivel user_nivel)` | 3 | 0 | no | public.bitacora_eventos:admin de area lee bitacora |
| `puede_capturar_remision(_vendedor_id uuid, _user_id uuid)` | 1 | 0 | no | public.remisiones:comercial captura remisiones |
| `puede_compras_inventario(_uid uuid)` | 19 | 0 | sí | public.abc_leyenda_combinaciones:abc_leyenda_escribir |
| `puede_editar_remision(_remision_id uuid, _user_id uuid)` | 6 | 0 | no | public.remision_items:remision_items_delete_area |
| `puede_escribir_inventario(_uid uuid)` | 12 | 0 | no | public.inventario_chasis:inv_insert_ops |
| `puede_finanzas_cobranza(_uid uuid)` | 10 | 0 | no | public.bitacora_compras_inventario:bitacora_compras_leer |
| `puede_leer_compras_inventario(_uid uuid)` | 18 | 0 | no | public.abc_leyenda_combinaciones:abc_leyenda_leer |
| `puede_leer_inventario(_uid uuid)` | 6 | 0 | no | public.documento_inventario_lineas:leer documento inventario lineas |
| `puede_leer_remision_refaccion(_remision_id uuid, _user_id uuid)` | 5 | 0 | no | public.remision_refaccion_correcciones:rem_ref_correcciones_leer |
| `puede_ver_almacen_refacciones(_user_id uuid)` | 19 | 0 | sí | public.almacen_refacciones_codigos:ref_codigos_escribir |
| `recibe_avisos_de(_area user_area, _user_id uuid)` | 3 | 0 | no | public.avisos:dar por visto |
| `rol_comercial(_user_id uuid)` | 1 | 0 | no | public.almacen_refacciones_productos:ref_prod_leer_ventas |
| `stock_bloqueado_producto(_producto_id uuid)` | 0 | 1 | no | vista |
| `supervisa_area(_user_id uuid, _area user_area)` | 9 | 0 | no | public.clientes:comercial supervisa clientes |
| `usuario_activo(_user_id uuid)` | 18 | 0 | no | public.app_modulos:leer modulos activos |
| `usuario_operativo(_user_id uuid)` | 8 | 0 | no | public.bitacora_color:autenticados leen bitacora_color |
| `ve_todo_comercial(_user_id uuid)` | 13 | 0 | no | public.clientes:leer clientes |

### Propuesta para una fase posterior (solo en este documento)

Mover las funciones del grupo 2 a un esquema que la API no exponga (por ejemplo `privado`), de forma que dejen de ser RPC sin dejar de servir a las políticas:

1. Crear el esquema `privado` y darle `USAGE` a `authenticated`; no se agrega a los esquemas expuestos de la API.
2. Crear en `privado` una **versión nueva** de cada función (mismo cuerpo, con `SET search_path` fijo). La versión de `public` sigue funcionando.
3. Cambiar las políticas y vistas, de una en una, para que usen la versión nueva, con la prueba por rol después de cada cambio.
4. Cuando nada dependa de la versión de `public` y los registros de la API muestren cero llamadas, retirarla (o convertirla en un envoltorio que llame a la nueva si el front aún la pide, como `puede_*`).
5. Cada paso lleva su reversa y se aplica en una ventana, como la Fase 1.

## Grupo 3A: RPC que llama el front o la compuerta

| Función | Quién la llama | Valoración | Qué verifica / nota |
|---|---|---|---|
| `cliente_tiene_cxc_vencidas(_cliente_id uuid)` | front: creditoDb.ts; compuerta | ⚠ MEDIA | SECURITY DEFINER sin identidad ni permiso: cualquier usuario con sesión consulta si un cliente tiene cuentas por cobrar vencidas, saltándose las políticas de cuentas_por_cobrar. |
| `compras_parametro(_clave text)` | front: Kardex.tsx; compuerta | ⚠ BAJA | SECURITY DEFINER sin permiso: lee cualquier parámetro de compras por clave. Las políticas lo usan; hay que revisar qué claves existen antes de restringirlo. |
| `cxc_vencidas_resumen(_cliente_id uuid)` | front: creditoDb.ts; compuerta | ⚠ MEDIA | SECURITY DEFINER sin identidad ni permiso: devuelve folio, saldo y vencimiento de las cuentas vencidas de cualquier cliente a cualquier usuario con sesión. |
| `saldo_refaccion_a_fecha(_producto uuid, _fecha date)` | front: AjustesInventario.tsx; compuerta | ⚠ BAJA | SECURITY DEFINER sin permiso: devuelve el saldo histórico de una refacción a cualquier usuario con sesión. |
| `es_super_admin(_user_id uuid)` | front: AuthContext.tsx; compuerta | BAJA | Predicado de permiso que acepta el uid de otra persona: sirve para averiguar los roles de otros usuarios. Es necesario para las políticas; se resuelve al moverlo a un esquema no expuesto. |
| `puede_aplicar_saldo_favor(_uid uuid)` | front: comun.tsx; compuerta | BAJA | Predicado de permiso que acepta el uid de otra persona: sirve para averiguar los roles de otros usuarios. Es necesario para las políticas; se resuelve al moverlo a un esquema no expuesto. |
| `puede_asignar_remisiones(_user_id uuid)` | front: AuthContext.tsx; compuerta | BAJA | Predicado de permiso que acepta el uid de otra persona: sirve para averiguar los roles de otros usuarios. Es necesario para las políticas; se resuelve al moverlo a un esquema no expuesto. |
| `puede_cargar_remisiones_anteriores(_user_id uuid)` | front: AuthContext.tsx; compuerta | BAJA | Predicado de permiso que acepta el uid de otra persona: sirve para averiguar los roles de otros usuarios. Es necesario para las políticas; se resuelve al moverlo a un esquema no expuesto. |
| `puede_editar_todas_remisiones(_user_id uuid)` | front: AuthContext.tsx; compuerta | BAJA | Predicado de permiso que acepta el uid de otra persona: sirve para averiguar los roles de otros usuarios. Es necesario para las políticas; se resuelve al moverlo a un esquema no expuesto. |
| `super_admins_ids()` | front: Aprobaciones.tsx, Usuarios.tsx; compuerta | OK parcial (revisar) | auth.uid() + es_admin_global |
| `actualizar_articulo_refaccion(_id uuid, _datos jsonb)` | compuerta | OK (automática) | auth.uid() + puede_compras_inventario + rechazo con RAISE |
| `actualizar_envio_remision_refaccion(_remision_id uuid, _envio jsonb)` | front: RemisionesRefacciones.tsx; compuerta | OK (automática) | auth.uid() + compras_supervisa_remisiones, puede_capturar_refacciones + rechazo con RAISE |
| `ajustar_capacidad_color(_modelo text, _color text, _piezas_recibidas integer, _motiv…)` | front: ColorChasis.tsx; compuerta | OK (automática) | auth.uid() + has_role + rechazo con RAISE |
| `ajustar_unidades_remision(_remision_id uuid, _total_objetivo integer, _motivo text)` | front: Remisiones.tsx; compuerta | OK (automática) | auth.uid() + puede_editar_remision + rechazo con RAISE |
| `alta_articulo_refaccion(_datos jsonb)` | compuerta | OK (automática) | auth.uid() + es_usuario_prueba, puede_compras_inventario + rechazo con RAISE |
| `aplicar_ajuste_rapido(_almacen text, _fecha date, _motivo text, _motivo_texto text…)` | compuerta | OK (automática) | auth.uid() + puede_compras_inventario + rechazo con RAISE |
| `aplicar_datos_maestros_refacciones(_items jsonb)` | compuerta | OK (automática) | auth.uid() + puede_compras_inventario + rechazo con RAISE |
| `aplicar_pago_cobranza(_pago_id uuid, _aplicaciones jsonb, _remanente_a_saldo boole…)` | compuerta | OK (automática) | auth.uid() + puede_compras_inventario + rechazo con RAISE |
| `aplicar_saldo_favor(_saldo_id uuid, _remision_id uuid, _monto numeric, _solicitu…)` | compuerta | OK (automática) | auth.uid() + puede_aplicar_saldo_favor + rechazo con RAISE |
| `asignar_motocarro_a_remision(_motocarro_id uuid, _remision_id uuid)` | front: BandejaRemisiones.tsx; compuerta | OK (automática) | auth.uid() + puede_asignar_remisiones + rechazo con RAISE |
| `asignar_remision_items(_remision_id uuid)` | front: BandejaRemisiones.tsx, Remisiones.tsx; compuerta | OK (automática) | auth.uid() + has_role + rechazo con RAISE |
| `asignar_super_admin(_user_id uuid, _activo boolean)` | front: Aprobaciones.tsx, Usuarios.tsx; compuerta | OK (automática) | auth.uid() + es_admin_global, es_super_admin + rechazo con RAISE |
| `asignar_vendedor_remision(_tipo text, _remision_id uuid, _vendedor_id uuid)` | front: AsignarVendedor.tsx; compuerta | OK (automática) | auth.uid() + es_admin_global + rechazo con RAISE |
| `cambiar_color_chasis(_chasis_id uuid, _color_nuevo text, _motivo text)` | front: ColorChasis.tsx; compuerta | OK (automática) | auth.uid() + has_role + rechazo con RAISE |
| `cambiar_orden_armado(_motocarro_id uuid, _orden_nuevo integer, _motivo text)` | front: Produccion.tsx; compuerta | OK (automática) | auth.uid() + has_role + rechazo con RAISE |
| `cancelar_compra_refacciones(_id uuid, _motivo text)` | compuerta | OK (automática) | auth.uid() + compras_refacciones + rechazo con RAISE |
| `cancelar_linea_refaccion(_item_id uuid, _motivo text)` | front: RemisionesRefacciones.tsx; compuerta | OK (automática) | auth.uid() + compras_supervisa_remisiones + rechazo con RAISE |
| `cancelar_remision_refacciones(_remision_id uuid, _motivo text)` | front: RemisionesRefacciones.tsx; compuerta | OK (automática) | auth.uid() + compras_supervisa_remisiones + rechazo con RAISE |
| `capturar_seriales_unidad(_motocarro_id uuid, _ns_chasis text, _ns_motor text)` | front: BandejaRemisiones.tsx, Produccion.tsx; compuerta | OK (automática) | auth.uid() + puede_asignar_remisiones + rechazo con RAISE |
| `configurar_pedido_remision(_remision_id uuid, _items jsonb)` | front: BandejaRemisiones.tsx; compuerta | OK (automática) | auth.uid() + puede_configurar_pedido + rechazo con RAISE |
| `configurar_unidad(_chasis_id uuid, _motor_id uuid, _orden integer, _color text)` | front: ConfigurarUnidad.tsx; compuerta | OK (automática) | auth.uid() + has_role + rechazo con RAISE |
| `confirmar_compra_refacciones(_id uuid)` | compuerta | OK (automática) | auth.uid() + compras_refacciones + rechazo con RAISE |
| `confirmar_compras_refacciones(_ids uuid[])` | compuerta | OK (revisada a mano) | delega en confirmar_compra_refacciones → _compra_editable, que exige puede_compras_inventario(auth.uid()) |
| `confirmar_fecha_entrega(_motocarro_id uuid, _area text)` | front: Remisiones.tsx; compuerta | OK (automática) | auth.uid() + has_role + rechazo con RAISE |
| `confirmar_sin_existencia_refaccion(_item_id uuid, _nota text)` | front: RemisionesRefacciones.tsx; compuerta | OK (automática) | auth.uid() + puede_operar_almacen_refacciones + rechazo con RAISE |
| `corregir_remision_refaccion(_remision_id uuid, _cambios jsonb, _motivo text)` | compuerta | OK (automática) | auth.uid() + puede_compras_inventario, puede_finanzas_cobranza + rechazo con RAISE |
| `crear_compra_refacciones(_cabecera jsonb, _lineas jsonb, _pendientes jsonb)` | compuerta | OK (automática) | auth.uid() + compras_refacciones, es_usuario_prueba, puede_compras_inventario + rechazo con RAISE |
| `crear_motocarro_ya_armado(_ns_chasis text, _ns_motor text, _modelo text, _color text, …)` | front: BandejaRemisiones.tsx; compuerta | OK (automática) | auth.uid() + puede_asignar_remisiones + rechazo con RAISE |
| `crear_remision_refacciones(_cliente_id uuid, _notas text, _nombre_vendedor text, _items…)` | front: RemisionesRefacciones.tsx; compuerta | OK (revisada a mano) | puede_capturar_refacciones() |
| `crear_remision_refacciones(_cliente_id uuid, _notas text, _nombre_vendedor text, _items…)` | front: RemisionesRefacciones.tsx; compuerta | OK (revisada a mano) | puede_capturar_refacciones() |
| `desasignar_motocarro_de_remision(_motocarro_id uuid)` | front: BandejaRemisiones.tsx; compuerta | OK (automática) | auth.uid() + puede_asignar_remisiones + rechazo con RAISE |
| `desconfigurar_unidad(_motocarro_id uuid, _motivo text)` | front: Produccion.tsx; compuerta | OK (automática) | auth.uid() + has_role + rechazo con RAISE |
| `dividir_compra_refacciones(_id uuid, _linea_ids uuid[], _almacen text)` | compuerta | OK (automática) | auth.uid() + compras_refacciones + rechazo con RAISE |
| `eliminar_compra_refacciones(_id uuid, _motivo text)` | compuerta | OK (automática) | auth.uid() + compras_refacciones, puede_compras_inventario + rechazo con RAISE |
| `eliminar_solicitud_aprobacion(_id uuid)` | front: Aprobaciones.tsx; compuerta | OK (automática) | auth.uid() + es_admin_global + rechazo con RAISE |
| `entregar_remision_refaccion(_remision_id uuid)` | front: RemisionesRefacciones.tsx; compuerta | OK (automática) | auth.uid() + puede_operar_logistica_refacciones + rechazo con RAISE |
| `flujo_aplicar(_id uuid, _destino text, _aplicaciones jsonb, _notas text)` | compuerta | OK (revisada a mano) | flujo_cap(aplica) |
| `flujo_asignar_capacidad(_user_id uuid, _capacidad text, _valor boolean)` | front: FinanzasFlujo.tsx; compuerta | OK (automática) | auth.uid() + es_usuario_prueba + rechazo con RAISE |
| `flujo_clientes()` | front: FinanzasFlujo.tsx; compuerta | OK (automática) | auth.uid() + es_usuario_prueba + rechazo con RAISE |
| `flujo_confirmar_caja(_id uuid, _cuenta_id uuid, _notas text)` | compuerta | OK (revisada a mano) | flujo_cap(caja) y separación de funciones |
| `flujo_cuentas()` | front: FinanzasFlujo.tsx; compuerta | OK (revisada a mano) | flujo_cap(caja) o flujo_es_admin() |
| `flujo_listar_capacidades()` | front: FinanzasFlujo.tsx; compuerta | OK (revisada a mano) | flujo_es_admin() |
| `flujo_mis_capacidades()` | front: FinanzasFlujo.tsx; compuerta | OK (revisada a mano) | solo devuelve las capacidades de quien llama |
| `flujo_rechazar(_id uuid, _motivo text)` | compuerta | OK (revisada a mano) | flujo_cap según la etapa |
| `flujo_recibir(_tipo text, _monto numeric, _moneda text, _metodo_pago text,…)` | compuerta | OK (automática) | auth.uid() + es_usuario_prueba + rechazo con RAISE |
| `flujo_remisiones_para_aplicar(_flujo_id uuid)` | front: FinanzasFlujo.tsx; compuerta | OK (revisada a mano) | flujo_cap(aplica) |
| `guardar_almacen_inventario(_clave text, _nombre text, _descripcion text, _recibe_compra…)` | compuerta | OK (automática) | auth.uid() + es_usuario_prueba, puede_compras_inventario + rechazo con RAISE |
| `guardar_equivalente_ecount(_clave text, _equivalente text)` | compuerta | OK (automática) | auth.uid() + puede_compras_inventario + rechazo con RAISE |
| `guardar_motivo_ajuste(_clave text, _nombre text, _requiere_texto boolean, _activo …)` | compuerta | OK (automática) | auth.uid() + puede_compras_inventario + rechazo con RAISE |
| `importar_almacen_refacciones(_items jsonb)` | front: AlmacenRefacciones.tsx; compuerta | OK (automática) | auth.uid() + puede_ver_almacen_refacciones + rechazo con RAISE |
| `importar_motores_inventario(_contenedor_id uuid, _modelo text, _motores jsonb)` | front: RecibirContenedor.tsx; compuerta | OK (automática) | auth.uid() + has_role + rechazo con RAISE |
| `importar_packing_list(_contenedor_id uuid, _partes jsonb)` | front: ContenedorPartes.tsx; compuerta | OK (automática) | auth.uid() + has_role + rechazo con RAISE |
| `importar_vins_inventario(_contenedor_id uuid, _folio_contenedor text, _modelo text, _…)` | front: RecibirContenedor.tsx; compuerta | OK (automática) | auth.uid() + has_role + rechazo con RAISE |
| `intercambiar_color_chasis(_chasis_a uuid, _chasis_b uuid, _motivo text)` | front: ColorChasis.tsx; compuerta | OK (automática) | auth.uid() + has_role + rechazo con RAISE |
| `kardex_refaccion(_producto uuid, _desde date, _hasta date)` | front: Kardex.tsx; compuerta | OK (automática) | auth.uid() + puede_leer_compras_inventario, puede_ver_almacen_refacciones + rechazo con RAISE |
| `liberar_refaccion_remision(_item_id uuid, _cantidad integer)` | front: RemisionesRefacciones.tsx; compuerta | OK (automática) | auth.uid() + puede_operar_almacen_refacciones + rechazo con RAISE |
| `marcar_pago_remision_con_evidencia(_remision_id uuid, _pagado boolean, _nota text, _evidencia_p…)` | front: RemisionesRefacciones.tsx; compuerta | OK (revisada a mano) | delega en marcar_pago_remision_refaccion, que exige puede_marcar_pago_refacciones() |
| `marcar_remision_entregada(_remision_id uuid)` | front: Remisiones.tsx; compuerta | OK (automática) | auth.uid() + puede_asignar_remisiones + rechazo con RAISE |
| `marcar_unidad_entregada(_motocarro_id uuid, _fecha date)` | front: BandejaRemisiones.tsx, Remisiones.tsx; compuerta | OK (automática) | auth.uid() + puede_asignar_remisiones + rechazo con RAISE |
| `programar_entrega_remision_refaccion(_remision_id uuid, _fecha date)` | compuerta | OK (automática) | auth.uid() + puede_operar_logistica_refacciones + rechazo con RAISE |
| `proponer_conteo_fisico(_almacen text, _fecha date, _lineas jsonb, _notas text, _evi…)` | compuerta | OK (automática) | auth.uid() + puede_almacen_fisico + rechazo con RAISE |
| `proponer_fecha_entrega(_motocarro_id uuid, _fecha date, _notas text)` | front: Remisiones.tsx; compuerta | OK (automática) | auth.uid() + has_role + rechazo con RAISE |
| `reabrir_incidencia_chasis(_incidencia_id uuid, _motivo text)` | front: Incidencias.tsx; compuerta | OK (automática) | auth.uid() + has_role + rechazo con RAISE |
| `recibir_contenedor(_folio_contenedor text, _fecha_arribo date, _modelo text, _c…)` | front: RecibirContenedor.tsx; compuerta | OK (automática) | auth.uid() + has_role + rechazo con RAISE |
| `recibo_pago_cobranza(_pago_id uuid)` | front: Cobranza.tsx; compuerta | OK (automática) | auth.uid() + puede_compras_inventario, puede_finanzas_cobranza + rechazo con RAISE |
| `registrar_conexion()` | front: AuthContext.tsx; compuerta | OK (revisada a mano) | exige auth.uid() |
| `registrar_guia_remision_refaccion(_remision_id uuid, _paqueteria text, _guia text)` | front: RemisionesRefacciones.tsx; compuerta | OK (automática) | auth.uid() + puede_operar_logistica_refacciones + rechazo con RAISE |
| `registrar_pago_cobranza(_datos jsonb)` | compuerta | OK (automática) | auth.uid() + puede_compras_inventario, puede_finanzas_cobranza + rechazo con RAISE |
| `registrar_recepcion_refacciones(_compra_id uuid, _fecha date, _lineas jsonb, _notas text, _v…)` | compuerta | OK (automática) | auth.uid() + compras_refacciones, puede_almacen_fisico, puede_compras_inventario + rechazo con RAISE |
| `reiniciar_datos_prueba_compras(_confirmacion text)` | compuerta | OK (automática) | auth.uid() + compras_folios, compras_refacciones, es_admin_global, has_role + rechazo con RAISE |
| `reportar_faltante_refaccion(_item_id uuid, _cantidad integer, _nota text)` | front: RemisionesRefacciones.tsx; compuerta | OK (automática) | auth.uid() + puede_operar_almacen_refacciones + rechazo con RAISE |
| `reportar_incidencia_chasis(_chasis_id uuid, _tipo_falla text, _descripcion text, _parte…)` | front: ReportarIncidencia.tsx; compuerta | OK (automática) | auth.uid() + has_role + rechazo con RAISE |
| `resolver_incidencia_chasis(_incidencia_id uuid, _resultado text, _resolucion text, _fol…)` | front: Incidencias.tsx; compuerta | OK (automática) | auth.uid() + has_role + rechazo con RAISE |
| `resolver_pendiente_compra_refacciones(_pendiente_id uuid, _producto_id uuid, _cantidad integer, _n…)` | compuerta | OK (automática) | auth.uid() + compras_refacciones + rechazo con RAISE |
| `resolver_solicitud_aprobacion(_id uuid, _aprobar boolean, _comentario text)` | front: Aprobaciones.tsx; compuerta | OK (automática) | auth.uid() + es_admin_de_area, es_super_admin + rechazo con RAISE |
| `responder_solicitud(_aviso_id uuid, _aceptar boolean, _respuesta text)` | front: BandejaAvisos.tsx; compuerta | OK (revisada a mano) | recibe_avisos_de(área destino) |
| `resumen_rotacion_refacciones(_desde date, _hasta date, _incluir_prueba boolean)` | front: RotacionABC.tsx; compuerta | OK (automática) | auth.uid() + compras_refacciones, es_usuario_prueba, puede_leer_compras_inventario + rechazo con RAISE |
| `revertir_pago_cobranza(_pago_id uuid, _motivo text)` | compuerta | OK (automática) | auth.uid() + puede_compras_inventario, puede_finanzas_cobranza + rechazo con RAISE |
| `revisar_incidencia_chasis(_incidencia_id uuid, _nota text, _retiene boolean)` | front: Incidencias.tsx; compuerta | OK (automática) | auth.uid() + has_role + rechazo con RAISE |
| `revisar_propuesta_ajuste(_id uuid, _aprobar boolean, _comentario text)` | compuerta | OK (automática) | auth.uid() + puede_compras_inventario + rechazo con RAISE |
| `saldo_favor_disponible_cliente(_cliente_id uuid)` | front: RemisionCobro.tsx; compuerta | OK (revisada a mano) | rol comercial, compras o finanzas |
| `saldos_atipicos_refacciones(_incluir_prueba boolean)` | front: CatalogoArticulos.tsx, ReportesCompras.tsx; compuerta | OK (automática) | auth.uid() + es_usuario_prueba, puede_leer_compras_inventario + rechazo con RAISE |
| `salidas_por_cliente_mes(_producto uuid, _desde date, _hasta date)` | front: Kardex.tsx; compuerta | OK (automática) | auth.uid() + puede_leer_compras_inventario, puede_ver_almacen_refacciones + rechazo con RAISE |
| `sembrar_datos_prueba_compras()` | compuerta | OK (automática) | auth.uid() + compras_refacciones, es_admin_global, has_role + rechazo con RAISE |
| `sincronizar_compat_refacciones(_items jsonb)` | front: AlmacenRefacciones.tsx; compuerta | OK (automática) | auth.uid() + puede_ver_almacen_refacciones + rechazo con RAISE |
| `solicitar_aprobacion(_tipo text, _objeto text, _parametros jsonb, _descripcion te…)` | front: aprobaciones.ts; compuerta | OK (automática) | auth.uid() + es_super_admin + rechazo con RAISE |
| `solicitar_saldo_favor(_remision_id uuid, _monto numeric, _nota text)` | compuerta | OK (automática) | auth.uid() + puede_leer_remision_refaccion + rechazo con RAISE |
| `unificar_unidades_refacciones(_destino uuid, _origenes uuid[], _nombre_final text)` | compuerta | OK (automática) | auth.uid() + es_usuario_prueba, puede_compras_inventario + rechazo con RAISE |
| `usuarios_asignables()` | front: Tareas.tsx; compuerta | OK (revisada a mano) | area_nivel_de(auth.uid()): limita por nivel y área |
| `validar_pago_cobranza(_pago_id uuid, _conciliado boolean, _evidencia_path text)` | compuerta | OK (automática) | auth.uid() + puede_finanzas_cobranza + rechazo con RAISE |
| `ventas_mensuales_refacciones(_desde date, _hasta date, _incluir_prueba boolean)` | front: RotacionABC.tsx; compuerta | OK (automática) | auth.uid() + es_usuario_prueba, puede_leer_compras_inventario + rechazo con RAISE |

## Grupo 3B: ejecutables por usuarios con sesión y sin llamador conocido

| Función | La llaman otras funciones de la base |
|---|---|
| `actualizar_compra_refacciones(_id uuid, _cabecera jsonb, _lineas jsonb)` | — |
| `ajustar_compra_faltante(_compra_linea_id uuid, _accion text, _notas text)` | — |
| `area_que_aprueba(_objeto text)` | solicitar_aprobacion, vigilar_super_admin |
| `asignar_chasis_remision(_remision_id uuid, _cantidad integer, _color text, _modelo t…)` | auto_asignar_motocarros_remision |
| `avisar_faltante_refaccion(_remision_id uuid, _item_id uuid, _detalle text)` | confirmar_sin_existencia_refaccion, reportar_faltante_refaccion |
| `buscar_modelos_refacciones(_q text)` | — |
| `capacidad_color_libre(_modelo text, _color text)` | ajustar_capacidad_color, cambiar_color_chasis, crear_motocarro_ya_armado |
| `cargar_existencia_inicial_refacciones(_almacen text, _fecha date, _items jsonb)` | — |
| `cargar_saldos_iniciales_cobranza(_items jsonb, _confirmacion text)` | — |
| `chasis_bloqueado(_chasis_id uuid)` | asignar_chasis_remision, asignar_remision_items, capturar_seriales_unidad, configurar_unidad, crear_motocarro_ya_armado |
| `clave_catalogo_usada(_tabla text, _clave text)` | catalogo_inventario_guardia |
| `confirmar_entrega_credito(_motocarro_id uuid)` | — |
| `crear_compra(_folio text, _proveedor_id uuid, _contenedor_id uuid, _fecha…)` | crear_compra_refacciones |
| `decrementar_inventario_color(_modelo text, _color text, _cantidad integer)` | — |
| `es_admin_compras(_uid uuid)` | compras_parametros_guardia |
| `es_rpc_con_aprobacion(_nombre text)` | solicitar_aprobacion, vigilar_super_admin |
| `es_usuario_prueba_actual()` | aviso_marca_prueba, candado_modo_prueba, catalogo_inventario_guardia, compras_parametros_guardia, guardar_motivo_ajuste |
| `es_vendedor_activo(_user_id uuid)` | asignar_vendedor_remision, crear_remision_refacciones |
| `generar_folio_interno_cliente()` | trg_clientes_folio_interno |
| `get_my_role()` | — |
| `importe_partida_refaccion(_precio numeric, _piezas integer, _desc_partida numeric, _de…)` | registrar_correccion_partida, total_vigente_remision_refaccion |
| `incrementar_inventario_color(_modelo text, _color text, _cantidad integer)` | importar_vins_inventario |
| `logistica_puede_entregar(_user_id uuid)` | confirmar_entrega_credito, registrar_paqueteria |
| `marcar_pago_remision_refaccion(_remision_id uuid, _pagado boolean, _nota text)` | marcar_pago_remision_con_evidencia |
| `nivel_rank(_nivel user_nivel)` | area_nivel_de, nivel_al_menos, supervisa_area, trg_tareas_guardia |
| `norm_color(_color text)` | _fijar_color_original, ajustar_capacidad_color, cambiar_color_chasis, capacidad_color_libre, configurar_unidad, crear_motocarro_ya_armado |
| `normalizar_modelo_refaccion(_t text)` | buscar_modelos_refacciones, unificar_unidades_refacciones |
| `parear_unidades_contenedor(_contenedor_id uuid)` | — |
| `patch_corregir_surtido_indebido_faltante()` | — |
| `puede_almacen_fisico(_uid uuid)` | proponer_conteo_fisico, puede_leer_compras_inventario, registrar_recepcion_refacciones |
| `puede_capturar_refacciones(_user_id uuid)` | actualizar_envio_remision_refaccion, crear_remision_refacciones |
| `puede_configurar_pedido(_remision_id uuid, _user_id uuid)` | configurar_pedido_remision |
| `puede_marcar_pago_refacciones(_user_id uuid)` | marcar_pago_remision_refaccion |
| `puede_operar_almacen_refacciones(_user_id uuid)` | confirmar_sin_existencia_refaccion, liberar_refaccion_remision, reportar_faltante_refaccion |
| `puede_operar_logistica_refacciones(_user_id uuid)` | entregar_remision_refaccion, programar_entrega_remision_refaccion, registrar_guia_remision_refaccion |
| `recalcular_etapa_remision_refaccion(_id uuid)` | _prueba_surtir, cancelar_linea_refaccion, confirmar_sin_existencia_refaccion, corregir_remision_refaccion, liberar_refaccion_remision, reportar_faltante_refaccion, sembrar_datos_prueba_compras |
| `recalcular_inventario_colores()` | _trg_recalcular_colores, ajustar_capacidad_color, cambiar_color_chasis, capturar_seriales_unidad, configurar_unidad, crear_motocarro_ya_armado, decrementar_inventario_color, desconfigurar_unidad, incrementar_inventario_color, intercambiar_color_chasis, reabrir_incidencia_chasis, reportar_incidencia_ |
| `registrar_documento_inventario(_contenedor_id uuid, _compra_id uuid, _origen text, _notas t…)` | — |
| `registrar_paqueteria(_motocarro_id uuid, _paqueteria text, _numero_guia text, _fe…)` | — |
| `reintentar_asignar_remision(_remision_id uuid)` | — |
| `revertir_aplicacion_cobranza(_aplicacion_id uuid, _motivo text)` | — |
| `rol_legacy(_area user_area, _nivel user_nivel)` | sync_rol_legacy |
| `saldo_inicial_sin_documento(_producto uuid)` | saldo_minimo_desde, saldo_refaccion_a_fecha, saldos_atipicos_refacciones |
| `saldo_minimo_desde(_producto uuid, _fecha date)` | _mover_inventario_refaccion, sembrar_datos_prueba_compras |
| `sufijo_orden_almacen(_almacen text)` | _orden_de_remision |
| `total_vigente_remision_refaccion(_id uuid, _desc_general numeric)` | corregir_remision_refaccion, estado_cobro_remision_refaccion, recibo_pago_cobranza, registrar_correccion_partida, registrar_correccion_remision, sembrar_datos_prueba_compras |

## Grupo 3C: internas

Los usuarios con sesión no las pueden ejecutar (28): `_aplicar_ajuste_inventario`, `_compra_editable`, `_crear_ajuste_inventario`, `_escribir_lineas_compra_refacciones`, `_mover_inventario_refaccion`, `_orden_de_remision`, `_parear_unidades_contenedor_internal`, `_prueba_aplicar`, `_prueba_cliente`, `_prueba_pago`, `_prueba_producto`, `_prueba_remision`, `_prueba_surtir`, `_puede_ajustar_compra`, `_puede_capturar_compra`, `_puede_cargar_inventario`, `_recalcular_compra`, `_siguiente_folio_compras`, `_sincronizar_estatus_chasis`, `_validar_destino_cobro`, `admin_clear_debe_cambiar_password`, `aplicar_reglas_modo_prueba`, `avisar_admins_area`, `cobranza_sincronizar_remision`, `exigir_dato_prueba`, `exigir_lectura_prueba`, `firmas_es_firmante`, `registrar_bitacora_compras`.

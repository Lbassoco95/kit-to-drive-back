# Hallazgo: el historial de migraciones de producción (H3 y H4)

**Solo lectura, y sin tocar producción.** Polo pidió usar solo el MCP de solo lectura, que **todavía no está configurado**. Por eso este documento se hizo **sin consultar producción**: con lo que ya se había leído el 26 oct (lista de 34 migraciones: versión y nombre), los archivos del repo y los respaldos de la Fase 0. Lo que exige leer el contenido de las migraciones (**quién las aplicó** y **qué sentencias traen**) queda como **consulta lista para correr** (`consultas/07-historial-migraciones.sql`) cuando el canal de solo lectura esté disponible. Cada afirmación dice si es **hecho** o **hipótesis**.

## 1. Qué es el historial de producción

`supabase_migrations.schema_migrations` tiene **34 renglones**, de `20260922043407` a `20261014200905`. **La versión es la fecha y hora (UTC) en que se aplicó**, no el nombre del archivo del repo. **Antes del 21 sep 22:34 (CDMX) no hay nada**: de junio a septiembre los cambios se pegaron en el SQL Editor sin dejar historial. Después, solo hay **7 semanas con 34 marcas**, y desde el 14 oct **ninguna** aunque se aplicaron más migraciones (se usó otra vía).

## 2. Las 34 migraciones

| # | Versión (UTC) | Fecha CDMX | Nombre en producción | Equivalente en el repo | Qué hizo / objetos que hoy existen |
|---|---|---|---|---|---|
| 1 | `20260922043407` | 21 Sep 22:34 | `patio_bridge_admin_rpcs` | **ninguno con ese nombre** | Creó el puente `patio_kit_*` (listar usuarios, activar/desactivar, **cambiar rol**, cambiar configuración) y `patio_bridge_secret` con el token en texto plano. **Hoy no existe**: lo retiró `20261009000002` (repo). |
| 2 | `20260922043429` | 21 Sep 22:34 | `fix_patio_kit_set_user_role_conflict` | **ninguno con ese nombre** | Arreglo de `patio_kit_set_user_role`. Mismo caso: retirada por `20261009000002`. |
| 3 | `20260922045537` | 21 Sep 22:55 | `almacen_refacciones` | `20260922000001_almacen_refacciones` |  |
| 4 | `20260922052700` | 21 Sep 23:27 | `restore_importar_almacen_refacciones_fn` | **ninguno con ese nombre** | Restauró `importar_almacen_refacciones`. El repo la define en `20260922000001`. |
| 5 | `20260922193333` | 22 Sep 13:33 | `area_compras_enum` | `20260922000003_area_compras_enum` |  |
| 6 | `20260922193350` | 22 Sep 13:33 | `area_compras` | `20260922000004_area_compras` |  |
| 7 | `20260922193513` | 22 Sep 13:35 | `sincronizar_compat_refacciones` | `20260922000002_sincronizar_compat_refacciones` |  |
| 8 | `20260922194306` | 22 Sep 13:43 | `descripcion_limpia_refacciones` | **ninguno con ese nombre** |  |
| 9 | `20260922194451` | 22 Sep 13:44 | `v_almacen_refacciones_con_descripcion_original` | **ninguno con ese nombre** |  |
| 10 | `20260922194510` | 22 Sep 13:45 | `sincronizar_compat_limpia_descripcion` | **ninguno con ese nombre** |  |
| 11 | `20260922194531` | 22 Sep 13:45 | `importar_almacen_refacciones_desc_limpia` | **ninguno con ese nombre** |  |
| 12 | `20260923011914` | 22 Sep 19:19 | `compat_no_borrar_si_vacio` | **ninguno con ese nombre** |  |
| 13 | `20260923014733` | 22 Sep 19:47 | `refacciones_foto_caracteristicas` | **ninguno con ese nombre** | **Hipótesis:** crea el bucket `refacciones-fotos` y sus 5 políticas de storage `ref_fotos_*` (las 5 políticas «solo producción» de storage). |
| 14 | `20260923014916` | 22 Sep 19:49 | `vista_refacciones_stock_disponible` | **ninguno con ese nombre** |  |
| 15 | `20260923015943` | 22 Sep 19:59 | `compat_universal_refacciones` | **ninguno con ese nombre** |  |
| 16 | `20260925171409` | 25 Sep 11:14 | `security_hardening_criticos` | `20260925170000_security_hardening_criticos` | **Hipótesis:** puede ser el origen de `impedir_escalada_rol` / `proteger_profile_activo` (funciones «solo producción») y de políticas distintas en `user_roles`. |
| 17 | `20260925172530` | 25 Sep 11:25 | `remision_refacciones_seguimiento_columnas` | **ninguno con ese nombre** |  |
| 18 | `20260925180830` | 25 Sep 12:08 | `remision_refacciones_pago_descuento_columnas` | **ninguno con ese nombre** |  |
| 19 | `20260925180953` | 25 Sep 12:09 | `remision_refacciones_actualizar_envio_pago` | **ninguno con ese nombre** |  |
| 20 | `20260925181135` | 25 Sep 12:11 | `remision_refacciones_crear_pago_descuento` | **ninguno con ese nombre** |  |
| 21 | `20260925181448` | 25 Sep 12:14 | `remision_refacciones_canceladas` | `20260925000004_remision_refacciones_canceladas` |  |
| 22 | `20260925182744` | 25 Sep 12:27 | `inventario_trigger_sin_campo_ajeno` | `20260925000005_inventario_trigger_sin_campo_ajeno` |  |
| 23 | `20260925184004` | 25 Sep 12:40 | `vista_movimientos_stock_refacciones` | **ninguno con ese nombre** | **Hipótesis:** crea la vista `v_almacen_refacciones_movimientos` (una de las 4 vistas «solo producción»). |
| 24 | `20260925184132` | 25 Sep 12:41 | `realtime_movimientos_stock_refacciones` | **ninguno con ese nombre** | Publica `almacen_refacciones_movimientos` en realtime (una de las 2 tablas publicadas). |
| 25 | `20260925193349` | 25 Sep 13:33 | `security_hardening_fase2` | `20260925193000_security_hardening_fase2` | Misma familia (el repo trae `20260925193000_security_hardening_fase2`). |
| 26 | `20260925193513` | 25 Sep 13:35 | `security_hardening_fase2_rls` | **ninguno con ese nombre** | Sin archivo propio en el repo: puede ser parte de lo que cambió las políticas. |
| 27 | `20260925212613` | 25 Sep 15:26 | `disable_public_signups_trigger` | **ninguno con ese nombre** | Cierra el registro público (el repo trae `20260925210000_disable_public_signups`; el de producción tiene otro nombre y no es idéntico por versión). |
| 28 | `20260925212624` | 25 Sep 15:26 | `force_password_change_all_users` | **ninguno con ese nombre** | **Operación de datos de una sola vez** (marcó a todos los usuarios «debe cambiar contraseña»). Sin archivo en el repo. Explica los `must_change_password` de hoy. |
| 29 | `20260930174015` | 30 Sep 11:40 | `marcar_entrega_asignacion` | `20260930000001_marcar_entrega_asignacion` |  |
| 30 | `20260930192713` | 30 Sep 13:27 | `bloquear_surtido_faltante` | **ninguno** | Probablemente crea un trigger/función de bloqueo de surtido (el repo trae `20260930…`? no: ver tabla); aplicada dos veces (192713 y 192951). |
| 31 | `20260930192951` | 30 Sep 13:29 | `bloquear_surtido_faltante` | **ninguno** | Probablemente crea un trigger/función de bloqueo de surtido (el repo trae `20260930…`? no: ver tabla); aplicada dos veces (192713 y 192951). |
| 32 | `20260930194236` | 30 Sep 13:42 | `corregir_surtido_indebido_faltante` | **ninguno con ese nombre** | Crea `patch_corregir_surtido_indebido_faltante()` (función «solo producción»). |
| 33 | `20261014184026` | 14 Oct 12:40 | `profiles_funcion_comercial` | `20261014000002_profiles_funcion_comercial` |  |
| 34 | `20261014200905` | 14 Oct 14:09 | `vendedor_obligatorio_remisiones` | `20261014000003_vendedor_obligatorio_remisiones` |  |

### Resumen

| Grupo | Cuántas | Hecho / hipótesis |
|---|---|---|
| **De otro proyecto (Patio)** | **2** (nº 1 y 2) | **Hecho** por el nombre (`patio_*`). **Hecho** que hoy no hay objetos `patio_*` en producción (ninguna función con ese nombre en el respaldo de permisos del 25 oct; la tabla `patio_bridge_secret` no está entre las 93) y que el repo trae `20261009000002_cerrar_puente_heredado…`, que los **retira** (`DROP FUNCTION patio_kit_*`, `DROP TABLE patio_bridge_secret`). |
| **Con equivalente por nombre en el repo** | 11 | **Hecho** por nombre. **No verificado** que el contenido sea el mismo. |
| **Sin equivalente en el repo** (incluidas las 2 de Patio) | **23** | **Hecho** por nombre. Una de ellas, `force_password_change_all_users`, es una operación de **datos** de una sola vez. |
| **Aplicadas más de una vez** | 1 (`bloquear_surtido_faltante`, 30 sep 13:27 y 13:29 CDMX) | **Hecho** |

### Lo que mueve el hallazgo de Patio

El puente `patio_kit_*` (22 sep → retirado el 9 oct o después) permitía **listar usuarios, activarlos o desactivarlos, cambiar el rol y cambiar la configuración de Kit-to-Drive**, con un token guardado en **texto plano** en una tabla. **Hecho:** estuvo en producción unos 17 días y hoy ya no existe. **No se sabe** si se usó (no hay bitácora de esas llamadas; los registros de la API solo duran 7 días). `20261009000002` no está registrada en `migraciones_aplicadas`, pero el catálogo de hoy no tiene esos objetos, así que **se aplicó** sin registrarla.

## 3. ¿Crean objetos que hoy existen y el repo no conoce? Cruce con las 17 políticas «solo producción»

**Hecho (reproducido hoy en una base armada solo con las migraciones del repo):** 17 políticas existen solo en producción y 5 solo en el repo. Las 17:

| Grupo | Políticas | Migración del historial que probablemente las creó | Confianza |
|---|---|---|---|
| Storage de `refacciones-fotos` | `ref_fotos_actualizar`, `ref_fotos_borrar`, `ref_fotos_leer`, `ref_fotos_leer_anon`, `ref_fotos_subir` (5) | nº 13 `refacciones_foto_caracteristicas` (22 sep, 19:47 CDMX) | **Media** (por nombre y fecha) |
| CRM | `crm_actividades_{select,insert,update,delete}`, `crm_oportunidades_{select,insert,update,delete}`, `crm_ruta_paradas_{select,insert,update}` (11) | **Ninguna** del historial: son anteriores a él (jun–sep) o se aplicaron por otra vía | Media: el repo las llama `crm_act_*`, `crm_oport_*` |
| Roles | `user_roles.gestionar_roles` (1) | nº 16 `security_hardening_criticos` o nº 25 `…fase2` (25 sep) | **Baja** |

Las 5 solo en el repo (`bitacora_eventos.insertar bitacora autenticados`, `crm_actividades.crm_act_delete`, `crm_oportunidades.crm_oport_delete`, `crm_rutas.crm_rutas_delete`, `user_roles.admin gestiona roles`) son **lo que el repo cree que existe y producción no tiene**: en producción **no hay política de borrado para `crm_rutas`** y no está `admin gestiona roles` (hay otra con otro nombre, `gestionar_roles`).

**Otros objetos «solo producción»** (hallazgo D1): 8 funciones, 8 triggers, 4 vistas, la tabla `zz_lista_oct`, 5 columnas de `pagos`.

| Objeto | Migración del historial que probablemente lo creó | Confianza |
|---|---|---|
| `patch_corregir_surtido_indebido_faltante()` | nº 32 `corregir_surtido_indebido_faltante` (30 sep) | **Alta** (mismo nombre) |
| `v_almacen_refacciones_movimientos` | nº 23 `vista_movimientos_stock_refacciones` (25 sep) | Media |
| `impedir_escalada_rol()`, `proteger_profile_activo()` y sus triggers | nº 16 `security_hardening_criticos` / nº 25 `…fase2` (25 sep) | Media |
| `confirmar_entrega_credito`, `logistica_puede_entregar`, `registrar_paqueteria`, `usuario_operativo` | Ninguna con nombre parecido | **Sin origen conocido** |
| `trg_crm_actividades_aviso_correo` y los 3 triggers `*_updated` del CRM | Ninguna | **Sin origen conocido** |
| `zz_lista_oct` (2,219 filas), `v_reporte_*` (3 vistas), columnas de `pagos` | Ninguna | **Sin origen conocido** |

**Conclusión (hecho):** producción se ha modificado **por al menos tres vías**: (1) el SQL Editor, sin historial (junio–septiembre y desde el 14 oct); (2) herramientas conectadas por MCP o CLI (las 34 marcas, 23 sin archivo en el repo, incluida la de Patio); (3) scripts de datos de una sola vez. **No se sabe quién aplicó cada una** hasta correr la consulta 07 (`created_by`).

## 4. Qué falta por saber (consulta lista, solo lectura)

`consultas/07-historial-migraciones.sql` devuelve, sin mostrar sentencias:
1. Versión, **fecha UTC**, nombre, **quién** (`created_by`, si el historial lo guarda), número de sentencias y huella de las 34.
2. Para cada uno de los objetos «solo producción» (36 nombres), **qué migración del historial lo menciona** (sin coincidencia = otra vía).
3. Para las 5 políticas «solo repo», si alguna migración las quita.
**Pendiente:** correrla con el MCP de solo lectura en cuanto Polo lo avise, y completar las columnas «quién» y «confianza».

## 5. Propuesta para alinear el historial (NO se aplica; es tarea aparte, con su propia ventana)

**Orden: primero Fase 1 y Fase 2; el historial después.** Mientras tanto, la regla es: **nada se aplica a producción si no es un archivo del repo, con `psql` y registrado en `migraciones_aplicadas`.**

1. **Congelar.** Quien tenga conectores con escritura los desactiva (Polo ya lo decidió). Una sola vía de cambio.
2. **Conocer.** Correr la consulta 07 y **guardar una copia** de las 34 migraciones (con sentencias) en el repo, en `docs/seguridad/historial-remoto/` (solo definiciones; sin datos). Así no se pierde nada al tocar el historial.
3. **Converger los objetos.** Escribir una migración idempotente `…_convergencia_con_produccion.sql` con **las definiciones que producción ya tiene** (17 políticas, 8 funciones, 8 triggers, 4 vistas, columnas de `pagos`; `zz_lista_oct` **no se borra**, se documenta), generada con `pg_get_*` y verificada en una réplica: al aplicarla en producción **no cambia nada** (todo existe); en una base nueva **crea lo que falta**. Para las 5 políticas «solo repo», **decidir por escrito** si el repo las quita o producción las recibe (es una decisión de permisos, no de orden).
4. **Alinear la CLI.** En una ventana propia, con respaldo: `supabase migration repair --status reverted <las 34 versiones remotas>` (después de guardar su copia) y `--status applied` para los archivos del repo que el diagnóstico (`diagnostico_esquema.sql`) da por aplicados, **dejando fuera `20261014000001`** hasta decidirla. Criterio de salida: **`supabase db push --dry-run` lista solo lo que Polo decidió** (ninguna migración vieja).
5. **Versionar bien.** Adoptar versiones de 14 dígitos **únicas** por archivo (hoy se repiten tres versiones: ver el último párrafo) y ponerle versión al archivo que no la tiene (`fix_remisiones_columns.sql`).
6. **Que no vuelva a pasar.** Prueba automática: el diagnóstico contra producción de solo lectura corre antes de cada ventana y **se detiene** si hay `FALTA`/`PARCIAL` nuevo; el historial de la CLI se revisa con `db push --dry-run` antes de aplicar.

**Riesgos de alinear:** ~140 marcas a mano (error humano) → por eso `--dry-run` obligatorio y una copia previa; las marcas son solo metadatos y se pueden revertir con el mismo comando.

**Dos hechos que conviene saber (comprobados en el repo):** hay **versiones repetidas** (varios archivos con la misma versión: `20261007000001` ×4, `20261016000001` ×2, `20261016000002` ×2), así que la CLI **no podría** registrarlos tal cual, y hay **un archivo sin versión**. Eso confirma que el repo se pensó para el SQL Editor, no para la CLI.

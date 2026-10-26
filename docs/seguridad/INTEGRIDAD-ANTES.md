# Integridad de la información — foto ANTES (Parte A)

**Solo lectura.** Producción = proyecto `kit-to-drive`, referencia **`dmhzhyeivvuliumcgsmm`** (confirmada con `get_project_url`: `https://dmhzhyeivvuliumcgsmm.supabase.co`). **No se tocó QA** (`qszllskpizvpnzcytqpj`).
Este documento contiene **conteos y huellas (hashes), nunca filas**.

**Corte:** 2026-10-26 **04:34 UTC** = **22:34 CDMX del 25 oct 2026** (la foto de tablas; Auth y Storage, 04:36 UTC). Se repitió la comparación de las 93 tablas unos minutos después y salió **idéntica** (ninguna actividad entre una y otra).

## 1. Resultado frente a la referencia de Polo (22:26 CDMX / 04:26 UTC)

| Cifra | Referencia de Polo | Esta foto | |
|---|---:|---:|---|
| Tablas en `public` | 93 | **93** | igual |
| Filas en total | 20,610 | **20,610** | igual |
| Tablas vacías | 23 | **23** | igual |
| Tablas sin llave primaria | — | **0** | las 93 tienen llave primaria |

Las diez más grandes:

| Tabla | Referencia | Esta foto | |
|---|---:|---:|---|
| `almacen_refacciones_producto_compat` | 5,065 | 5,065 | igual |
| `almacen_refacciones_codigos` | 2,925 | 2,925 | igual |
| `almacen_refacciones_productos` | 2,237 | 2,237 | igual |
| `zz_lista_oct` | 2,219 | 2,219 | igual |
| `almacen_refacciones_unidades` | 1,858 | 1,858 | igual |
| `clientes` | 1,786 | 1,786 | igual |
| `almacen_refacciones_movimientos` | 1,079 | 1,079 | igual |
| `ajuste_inventario_lineas` | 1,053 | 1,053 | igual |
| `bitacora_eventos` | 460 | 460 | igual |
| `bitacora_super_admin` | 258 | 258 | igual |

**No hay ninguna diferencia que explicar:** en los ocho minutos entre ambos cortes no hubo actividad de usuarios que cambiara una sola fila (es domingo por la noche; los registros de la API de las últimas 24 h muestran 1,227 solicitudes, todas 2xx).

## 2. Cómo se calculó la huella (repetible)

Consulta `consultas/05-integridad-tablas.sql`: para cada tabla, `md5` del contenido completo (cada fila como texto, unidas con `|`) **ordenado por la llave primaria**. Una tabla vacía se marca `vacia`. La **huella global** resume las 93 líneas `tabla|filas|huella`:

> **Huella global antes:** `f14b7f9d221eb9465000913f8aaf5f36`  ·  93 tablas  ·  20,610 filas

El archivo completo, con las huellas enteras, es **`integridad/antes-tablas.txt`** (verificado: su `md5` es la huella global). Para repetirlo después de un cambio:
```bash
python3 docs/seguridad/integridad/generar-comparacion.py docs/seguridad/integridad/antes-tablas.txt   # imprime una consulta de solo lectura
```
Se pega esa consulta en el SQL Editor (Polo la corre y pega el resultado; ver `SQL-PARA-POLO.md`, bloque A1). **Devuelve solo las tablas que cambiaron.** Resultado vacío = la información se mantuvo igual. Se probó hoy contra producción: devolvió vacío.

**Qué detecta y qué no:** cualquier cambio en cualquier columna de cualquier fila, o filas nuevas o borradas. **No detecta** cambios de estructura (eso lo cubren las consultas de catálogo de la sección 5).

## 3. Auth

Consulta `consultas/06-integridad-auth-storage.sql`. Archivo con los valores: `integridad/antes-auth-storage.txt`.

| Objeto | Valor |
|---|---|
| `auth.users` | **26** usuarios; **26** sin bloqueo; **0** bloqueados; 26 con correo confirmado |
| Huella de `auth.users` sin contraseñas (id, correo, alta, bloqueo, metadatos) | `1ac193c5a1b9…` |
| Huella de los hashes de contraseña | `b5ce83d10864…` (cambia si alguien cambia su contraseña: actividad normal) |
| `auth.identities` | 28 |
| `auth.sessions` | 21 (21 vigentes) |
| `auth.refresh_tokens` | 116 (21 no revocados) |
| `auth.mfa_factors` | **0** (nadie tiene segundo factor) |

Las sesiones y los tokens cambian solos con el uso normal (inicios de sesión, renovaciones); los usuarios y sus huellas no deberían moverse sin una operación.

## 4. Storage

| Bucket | Objetos | Bytes | Huella |
|---|---:|---:|---|
| `evidencias-compras` | 7 | 872,280 | `eed343bc90be…` |
| `remisiones-docs` | 65 | 106,180,335 | `36d593c67e57…` |
| Los otros 7 buckets (`actividades-evidencia`, `clientes-docs`, `comentarios-fotos`, `facturas`, `finanzas-docs`, `firmas`, `refacciones-fotos`) | 0 | 0 | — |
| **Total** | **72** | **107,052,615** | `e47ebdcc66e1…` |
| Configuración de los 9 buckets (público, límite, tipos) | | | `002c2d12ded3…` |

Huella de objetos = `md5` de `bucket|nombre|tamaño|eTag` ordenado. No lee los archivos.

## 5. Catálogo (permisos, políticas, funciones, triggers)

Consulta `consultas/02-conteos-linea-base.sql` más conteos adicionales, 26 oct 2026 04:3x UTC:

| Qué se cuenta | Hoy | Comparación con la línea base del 25 oct (Fase 0) |
|---|---:|---|
| Tablas en `public` / con RLS | 93 / 93 | igual |
| Vistas / con `security_invoker` | 18 / 18 | igual |
| Tablas en `bkp` | 8 | igual |
| Funciones de `public` / SECURITY DEFINER | 268 / 240 | igual |
| SECURITY DEFINER ejecutables por `authenticated` | 208 | igual |
| Funciones ejecutables por `anon` | 2 (`limpiar_entrega_programada_refaccion`, `vigilar_super_admin`) | igual |
| Funciones sin `search_path` fijo | 14 | igual |
| Tablas con INSERT+UPDATE+DELETE para `anon` | 81 | igual |
| Tablas con TRUNCATE para `authenticated` / `anon` | 82 / 82 | igual |
| Relaciones con TRIGGER / REFERENCES para `anon` o `authenticated` | 103 / 103 | igual |
| Vistas con lectura para `anon` | 16 | igual |
| Tablas publicadas en realtime | 2 (`almacen_refacciones_movimientos`, `notificaciones`) | igual |
| Políticas de tablas con rol `public` / de storage con rol `public` | 34 / 4 | igual |
| **Políticas de `public` (total)** / **de storage (total)** | **301** / **37** | 301 igual |
| **Triggers en `public`** | **240** | |
| **Funciones de trigger** / ejecutables por `authenticated` / por `anon` | **53** / 47 / 2 | 53 igual |
| Funciones ejecutables por `authenticated` (todas) | 234 | |
| Permisos por defecto de `postgres` en `public` | tablas `arwdDxtm` para `anon`, `authenticated`, `service_role`; funciones `X` para `authenticated` y `service_role`; secuencias `rwU` para los tres | igual (**la Fase 1 los cambia**) |
| Objetos de la Fase 2 presentes | **0** | — |
| Política `profiles_update_admin` | **sigue existiendo** (1) | — |
| Motor / extensiones | PostgreSQL 17.6; `pg_stat_statements`, `pgcrypto`, `supabase_vault` (no hay `pg_cron` ni `pg_net`) | |

## 6. Las 93 tablas

| Tabla | Filas | Huella (md5, primeros 12) |
|---|---:|---|
| `abc_leyenda_combinaciones` | 9 | 542c4d75c18c |
| `ajuste_inventario_lineas` | 1,053 | 53501aaaebf4 |
| `ajustes_inventario` | 11 | 2360bb03d19f |
| `almacen_refacciones_acceso` | 3 | 99e76cce875c |
| `almacen_refacciones_codigos` | 2,925 | c792d0226ed6 |
| `almacen_refacciones_movimientos` | 1,079 | 207ca9473777 |
| `almacen_refacciones_producto_compat` | 5,065 | fbd6989e2723 |
| `almacen_refacciones_productos` | 2,237 | d400652a1693 |
| `almacen_refacciones_unidad_alias` | 0 | (vacía) |
| `almacen_refacciones_unidades` | 1,858 | 03ad1c8f2a28 |
| `altas_autorizadas` | 0 | (vacía) |
| `app_modulos` | 26 | 84bfe09de093 |
| `avisos` | 15 | 2ab97636abd3 |
| `bitacora_color` | 67 | 9015d8228497 |
| `bitacora_compras_inventario` | 42 | 352ce0943292 |
| `bitacora_eliminaciones` | 6 | 7d4b5689a2df |
| `bitacora_eventos` | 460 | 01afcbf92d59 |
| `bitacora_orden_armado` | 0 | (vacía) |
| `bitacora_super_admin` | 258 | f5e33ee7d589 |
| `bridge_bitacora` | 3 | a9e1e8660c70 |
| `categorias_financieras` | 18 | 263d3bd9054e |
| `clientes` | 1,786 | d45426afd619 |
| `clientes_bitacora` | 13 | f0c44f45a0a1 |
| `clientes_comentarios` | 0 | (vacía) |
| `cobranza_aplicaciones` | 6 | bb2af8d58938 |
| `cobranza_pagos` | 3 | 866cab1b9dd6 |
| `cobranza_saldos_favor` | 6 | 8f81087c865b |
| `cobranza_solicitudes_saldo` | 0 | (vacía) |
| `comentarios_motocarros` | 2 | fbb506617159 |
| `compra_lineas` | 0 | (vacía) |
| `compra_refaccion_lineas` | 1 | 336389242380 |
| `compra_refaccion_pendientes` | 0 | (vacía) |
| `compras` | 0 | (vacía) |
| `compras_folios` | 5 | 7aaaad3858e2 |
| `compras_parametros` | 10 | 1d843ed19429 |
| `compras_refacciones` | 1 | 38ae6f3fea1a |
| `config_general` | 1 | d2a42cc84816 |
| `contenedor_partes` | 0 | (vacía) |
| `contenedores` | 5 | 1f4ee00ba412 |
| `crm_actividades` | 4 | 50f8d6642a99 |
| `crm_oportunidades` | 2 | 63032ae96734 |
| `crm_ruta_paradas` | 11 | f86b8f48d6ff |
| `crm_rutas` | 7 | c09e0b90e155 |
| `cuentas_financieras` | 3 | 68389d3cfbea |
| `cuentas_por_cobrar` | 2 | 41c7d998fc36 |
| `cxc_abonos` | 1 | 77841ebb26c1 |
| `documento_inventario_lineas` | 0 | (vacía) |
| `documentos_inventario` | 0 | (vacía) |
| `firmas_firmantes` | 0 | (vacía) |
| `firmas_solicitudes` | 0 | (vacía) |
| `flujo_capacidades` | 3 | fac380f925c2 |
| `flujo_dinero` | 0 | (vacía) |
| `historial_conexiones` | 109 | 83f32dd51ec3 |
| `incidencias_chasis` | 0 | (vacía) |
| `incidencias_chasis_eventos` | 0 | (vacía) |
| `inventario_almacenes` | 3 | 36d19af1e4b7 |
| `inventario_chasis` | 155 | 7a243c52ebba |
| `inventario_colores` | 11 | 0f0d57351040 |
| `inventario_motivos_ajuste` | 6 | 805f45e9994a |
| `inventario_motor` | 155 | 302dfb987d8b |
| `inventario_partes` | 0 | (vacía) |
| `inventario_reglas_modo_prueba` | 43 | 24559ec85536 |
| `inventario_unidades_venta` | 5 | c57e19f772a7 |
| `inventario_usuarios_prueba` | 7 | 4f192ca099b3 |
| `migraciones_aplicadas` | 90 | 0478424ffd54 |
| `modelos_producto` | 5 | 673f4c1d8f47 |
| `motocarros` | 183 | 5567a6b5ffa6 |
| `movimiento_adjuntos` | 0 | (vacía) |
| `movimiento_bitacora` | 0 | (vacía) |
| `movimientos_financieros` | 0 | (vacía) |
| `notificaciones` | 37 | a108aafd3ccd |
| `pagos` | 0 | (vacía) |
| `profiles` | 26 | a3149603bead |
| `proveedores` | 1 | dc976c81a4a7 |
| `recepcion_refaccion_lineas` | 0 | (vacía) |
| `recepciones_refacciones` | 0 | (vacía) |
| `remision_items` | 104 | fc560da92da5 |
| `remision_refaccion_correcciones` | 26 | 2e3ed9b311c8 |
| `remision_refaccion_eventos` | 92 | 265227272d41 |
| `remision_refaccion_items` | 32 | c3c4cc7e9894 |
| `remision_refaccion_ordenes` | 16 | 1caf5f405f8e |
| `remisiones` | 93 | 7b7ceace6bab |
| `remisiones_asignacion_acceso` | 1 | cea74ab5549a |
| `remisiones_bitacora` | 125 | cc3f4a64ef0b |
| `remisiones_refacciones` | 15 | e0bcb1b482f7 |
| `reportes_turno` | 7 | 9aacf148154a |
| `solicitudes_aprobacion` | 7 | 4f74c4c2d79e |
| `soporte_mensajes` | 1 | 2641f7536d08 |
| `soporte_tickets` | 1 | c7f83beb7b16 |
| `super_admins` | 2 | 5354475effe5 |
| `tareas` | 1 | 8e1fcd02bcf4 |
| `user_roles` | 25 | 8a8c0b7e252a |
| `zz_lista_oct` | 2,219 | 6f402bf731f3 |

## 7. Lo que NO incluye esta foto

- **Datos de Auth que cambian solos** (sesiones, tokens, `last_sign_in_at`): se cuentan, no se comparan por huella.
- **Los archivos de Storage por dentro**: se comparan por nombre, tamaño y `eTag`.
- **Tablas de otros esquemas** (`bkp`, 8 tablas, no se tocan en ninguna fase).

# Línea base — 25 de octubre de 2026 (Fase 0, sección 3.2)

Todo se midió el **25 de octubre de 2026** (entre las 19:00 y las 21:00 UTC), en solo lectura, sobre el proyecto Supabase `kit-to-drive`. Está escrito para repetirse idéntico después de cada fase: cada cifra dice con qué consulta u origen se obtuvo.

## 1. Conteos de permisos (sección 2 del encargo)

Consulta: `consultas/02-conteos-linea-base.sql` (la misma antes y después de cada migración).

| Qué se cuenta | Encargo | **Producción 25 oct** | Después de la Fase 1 (ensayo) |
|---|---|---|---|
| Tablas en `public` con seguridad por filas activa | 93 / 93 | **93 / 93** ✓ | 93 / 93 |
| Vistas / con `security_invoker` | 18 / 18 | **18 / 18** ✓ | 18 / 18 |
| Tablas en el esquema `bkp` | 8 | **8** ✓ | 8 (no se toca) |
| Funciones de `public` / SECURITY DEFINER | 240 SD | **268 / 240** ✓ | 268 / 240 |
| SECURITY DEFINER ejecutables por `authenticated` | 208 | **208** ✓ | 178 (−30 de trigger) |
| Funciones ejecutables por `anon` | 2 | **2** ✓ (`limpiar_entrega_programada_refaccion`, `vigilar_super_admin`) | 0 |
| Funciones sin `search_path` fijo | 14 | **14** ✓ | 0 |
| Tablas con INSERT+UPDATE+DELETE para `anon` | 81 | **81** ✓ | 0 |
| Tablas con TRUNCATE para `authenticated` | 82 | **82** ✓ | 0 |
| Tablas con TRUNCATE para **`anon`** | *(no estaba)* | **82** | 0 |
| Relaciones con TRIGGER o REFERENCES para `anon`/`authenticated` | *(no estaba)* | **103 y 103** | 0 y 0 |
| Vistas con lectura para `anon` | 16 de 18 | **16** ✓ (sin: `v_carga_ya_armados`, `v_stock_modelo_color`) | 0 |
| Tablas publicadas en realtime | 2 | **2** ✓ (`almacen_refacciones_movimientos`, `notificaciones`) | 2 (no se toca) |
| Políticas de tablas con rol `public` | 34 | **34** ✓ | 34 |
| Políticas de storage para `public` | 5 | **4** (+1 para `anon`: `ref_fotos_leer_anon`) | 4 + 1 |

**Diferencias contra la sección 2, todas explicadas:**
1. **Storage:** hay 4 políticas para el rol `public` (todas `facturas_*`) y una quinta para el rol `anon` (`ref_fotos_leer_anon`, lectura del bucket `refacciones-fotos`). El «5» del encargo cuenta las dos formas.
2. **TRUNCATE:** `anon` también lo tiene en 82 tablas, igual que `authenticated` (el encargo solo mencionaba a los usuarios con sesión).
3. **MAINTAIN:** PostgreSQL 17 agrega este permiso (VACUUM, ANALYZE, REINDEX, LOCK…) y `anon` y `authenticated` lo tienen en todas las relaciones. **No estaba en el plan y no se incluyó en la Fase 1**; queda como decisión de Polo (ver `HALLAZGOS-PENDIENTES.md`).

## 2. Asesores de Supabase (25 oct 2026)

**Seguridad:** `authenticated_security_definer_function_executable` **208** · `function_search_path_mutable` **14** · `anon_security_definer_function_executable` **1** · `rls_enabled_no_policy` **9** (INFO, tablas del esquema `bkp`) · `auth_leaked_password_protection` **1**.

**Rendimiento:** `auth_rls_initplan` **269** · `multiple_permissive_policies` **118** · `unindexed_foreign_keys` **113** (INFO) · `unused_index` **58** (INFO) · `no_primary_key` **8** (INFO, `bkp`) · `duplicate_index` **1** (`motocarros`) · `auth_db_connections_absolute` **1** (INFO).

La Fase 1 debe bajar de seguridad: `function_search_path_mutable` 14 → 0 y `anon_security_definer_function_executable` 1 → 0. No debe mover ninguno de rendimiento.

## 3. Las diez consultas más costosas (`pg_stat_statements`)

Tiempo acumulado desde el último reinicio de las estadísticas (no se conoce la fecha). Todas son de PostgREST salvo la tercera.

| # | Consulta | Llamadas | Total | Promedio |
|---|---|---|---|---|
| 1 | `v_almacen_refacciones` ordenada | 317 | 931,948 ms | **2,940 ms** |
| 2 | `clientes` ordenada por folio | 741 | 833,791 ms | **1,125 ms** |
| 3 | Sondeo interno de realtime (`list_changes`) | 120,062 | 652,938 ms | 5.4 ms |
| 4 | `v_stock_modelo_color` (columnas) | 897 | 639,369 ms | 713 ms |
| 5 | `v_clientes_credito` ordenada | 618 | 588,515 ms | 952 ms |
| 6 | `clientes` (otra forma) | 478 | 452,118 ms | 946 ms |
| 7 | `v_stock_modelo_color` | 483 | 295,283 ms | 611 ms |
| 8 | `clientes` (otra forma) | 821 | 249,653 ms | 304 ms |
| 9 | `almacen_refacciones_unidades` | 117 | 205,794 ms | **1,759 ms** |
| 10 | `v_almacen_refacciones` | 61 | 192,047 ms | **3,148 ms** |

> **Corrección a un análisis anterior.** En una revisión previa de esta conversación se dijo que «con las tablas actuales no hay un problema grave de velocidad». Esa conclusión salió de una consulta que excluía las filas con `pg_` en el texto, lo que **descartaba todas las consultas de PostgREST** (`pgrst_source`). Sin ese filtro se ve lo contrario: consultas de **1 a 3 segundos** en promedio sobre tablas chicas (`clientes` tiene 1,786 filas). Eso apunta al costo de las políticas (269 sin optimizar) y no a falta de índices. Es el trabajo de la fase de rendimiento, no de esta.

## 4. Errores 4xx y 5xx de los últimos siete días

**API de Supabase** (registros `edge_logs`, 7 ventanas de 24 h terminando el 25 oct 19:30 UTC; ese último día tuvo 6,238 solicitudes). **Cero errores 5xx.** Total de 4xx: **96**.

| Ruta | Estado | Solicitudes en 7 días |
|---|---|---|
| `auth/v1/token` | 400 (credenciales incorrectas) | 35 |
| `rest/v1/notificaciones` | 401 | 14 |
| `rest/v1/crm_actividades` | 400 | 12 |
| `rest/v1/rpc/revertir_pago_cobranza` | 400 | 5 |
| `auth/v1/logout` | 403 | 5 |
| `rest/v1/remisiones` | 403 | 4 |
| `rest/v1/rpc/cancelar_remision_refacciones` | 403 | 4 |
| `rest/v1/movimientos_financieros` | 403 | 4 |
| `rest/v1/crm_oportunidades` | 400 | 3 |
| `auth/v1/user` | 403 | 2 |
| `storage/v1/object/sign/remisiones` | 400 | 2 |
| `rpc/responder_solicitud`, `rpc/eliminar_compra_refacciones` | 400 | 2 + 2 |
| `rpc/asignar_remision_items`, `rest/v1/clientes` (409) | 400 / 409 | 1 + 1 |

**Compuerta (`kit-to-drive-api`, Vercel):** sin errores de ejecución en 7 días. Solicitudes bloqueadas por la lista blanca en 7 días: `rpc/programar_entrega_remision_refaccion` ×4 (después se agregó a la lista) y objetos del bucket **`finanzas-docs`** ×3 (ese bucket **no está en la lista blanca**; ver `HALLAZGOS-PENDIENTES.md`).

**`mati-api` (Vercel):** sin errores de ejecución en 7 días. **Puente de MATI Admin** (`mati-admin-bridge`, Edge Function): no se obtuvieron sus registros propios en esta sesión *(pendiente)*; las llamadas del puente aparecen en la API de Supabase como escrituras con llave de servicio desde el agente `SupabaseEdgeRuntime`.

## 5. Estado de despliegues y de pruebas

| Pieza | Estado el 25 oct |
|---|---|
| Front `kit-to-drive` (Vercel) | Producción en `7575984` (= `origin/main`), `READY` |
| Compuerta `kit-to-drive-api` (Vercel, repo `kit-to-drive-front`) | Producción en `843cc92` (= `origin/main`), `READY`. El clon local usado para el análisis iba atrasado (`c1d521d`); se analizó `origin/main` |
| `mati-api` (Vercel) | Producción en `9e62020` (= `main` de `mati-app`), `READY` |
| `mati-admin` (Vercel) | Producción desplegada de la **rama** `cursor/ficha-alta-usuarios-ktd-4b6a` (`46d58fb`), no de `main`. *(Anotado; no se tocó.)* |
| Edge Functions (Supabase) | 7 activas: `admin-create-user` v20, `admin-update-user` v8, `admin-reset-user-password` v9, `complete-password-change` v9, `mati-admin-bridge` v14 (sin JWT a propósito, usa secreto), `firmas` v1, `seed-demo-users` v7 |

| Pruebas | Resultado |
|---|---|
| Back `kit-to-drive-back` (`npm test`) | **85 pasan**, 3 omitidas (necesitan Postgres local) |
| Back, pruebas de base contra Postgres local (`KIT_PG_PRUEBAS=1`) | 3 **fallan, y ya fallaban** en `origin/main` limpio (mismo commit `2a2d6de`): error `cobranza_pagos no existe` en `20261012000001` al armar una base «anterior», y un dato de la remisión de prueba en `pruebas_compras.sql:195`. Con la Fase 1 la salida es **idéntica** a `main` |
| Front (`typecheck`, `npm run test`, `npm run build`) | typecheck ✓ · **492 pasan**, 1 omitida (53 archivos) · build ✓ |
| Compuerta (`typecheck`, `npm test`) | typecheck ✓ · **13 pasan** |
| `mati-api` (`npm test`) | **22 pasan** |

## 6. Deriva entre el repositorio y producción (hallazgos de la medición)

La réplica local construida solo con las migraciones del repo **no** coincide con producción; las diferencias son la medida de la deriva:

- **Producción tiene y el repo no crea:** 8 funciones (`impedir_escalada_rol`, `proteger_profile_activo`, `confirmar_entrega_credito`, `logistica_puede_entregar`, `registrar_paqueteria`, `usuario_operativo`, `trg_crm_actividades_aviso_correo`, `patch_corregir_surtido_indebido_faltante`), 4 vistas (`v_almacen_refacciones_movimientos`, `v_reporte_pagos`, `v_reporte_produccion`, `v_reporte_remisiones`), la tabla `zz_lista_oct`, 8 triggers, columnas de `pagos` (`tipo_cambio`, `categoria`, `fecha_pago`, `estatus`, `referencia_externa`) y 17 políticas (otras 5 políticas del repo no existen en producción con ese nombre). **Las protecciones de roles (`impedir_escalada_rol`, `proteger_profile_activo`) no están en el repo.**
- **El repo tiene y producción no:** `asignar_chasis_remision(uuid,integer,text)`, `definir_compatibilidades_articulo` y `eliminar_articulo_refaccion` (la migración `20261014000001` no está aplicada en producción).
- **El registro `migraciones_aplicadas` de producción está atrasado:** llega hasta `20261022000001` pero le faltan varias que sí están aplicadas (por ejemplo `20261009000002`, `20261010000001`, `20261010000002`, `20261020000001`).

Nada de esto se corrigió en la Fase 0.

## 7. Cómo repetir la línea base idéntica

1. Conteos: correr `consultas/02-conteos-linea-base.sql` (solo lectura) en producción.
2. Asesores: *Supabase → Advisors* (seguridad y rendimiento) o la herramienta `get_advisors`.
3. Consultas costosas: `select … from pg_stat_statements order by total_exec_time desc limit 10` **sin filtrar por texto**.
4. Errores: registros `edge_logs` de la API (ventanas de 24 h) y los registros de ejecución de Vercel de la compuerta.
5. Pruebas: los comandos de la tabla de la sección 5 en cada repo.
6. Réplica y ensayo: `ensayo/construir-replica-fiel.py` y `ensayo/ensayar-fase-1.py`.

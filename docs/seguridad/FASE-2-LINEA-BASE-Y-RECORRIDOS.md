# Fase 2 — línea base y recorridos por rol (26 oct 2026)

Esta es la **Fase 0 de la Fase 2**: qué hay hoy en producción de lo que la Fase 2 toca, y qué puede y no puede hacer cada rol sobre perfiles y roles. Se repite idéntico antes y después de cada migración.
Medido en solo lectura el 26 oct 2026 (producción) y en la réplica local con datos inventados (recorridos). **Nada se aplicó en producción.**

> **Orden:** primero la Fase 1 (PR #12, pendiente de autorización), después la Fase 2. La Fase 2 se ensayó **sobre la réplica con la Fase 1 ya aplicada**.

## 1. Lo que hay en producción hoy (solo lectura)

**Tamaño:** 26 perfiles, 25 filas en `user_roles`, 2 super admins.

**Triggers de `profiles`:** `trg_profiles_updated`, `trg_proteger_profile_activo`, `trg_proteger_profiles_privilegiados`, `trg_vigilar_super_admin`, `zzz_candado_modo_prueba`.
**Triggers de `user_roles`:** `trg_impedir_escalada_rol`, `trg_user_roles_sync_legacy`, `trg_vigilar_super_admin`, `zzz_candado_modo_prueba`.
**`super_admins`:** sin triggers, sin políticas, permisos cerrados.
**Políticas de UPDATE de `profiles`:** `admin de area actualiza profiles`, `profiles_update_admin` (**la que la Fase 2 quita**), `profiles_update_propio`.
**Políticas de `user_roles`:** `admin de area gestiona usuarios`, `gestionar_roles`, `leer roles propios`, `modo_prueba_lectura`.

**Funciones (todas `SECURITY DEFINER` con `search_path = public`, salvo `nivel_rank`).** Huella = `md5(prosrc)` en producción el 26 oct; sirve para comprobar el día de la ventana que nada cambió:

| Función | Huella (md5 del cuerpo) |
|---|---|
| `impedir_escalada_rol()` | `9f15e754fdc2c723c97b56c185b33be4` |
| `proteger_profile_activo()` | `b3fd4269e813fde33dd7f7e284588b5a` |
| `proteger_campos_privilegiados_profiles()` | `48ee99732bb212ac02c6f6f0b97f738c` |
| `asignar_super_admin(uuid,boolean)` | `8d3eb529c8b66bb2a7863a1fce250435` |
| `es_super_admin(uuid)` | `f6ee05bd13a56d62ce43f8dd56f76079` |
| `es_admin_global(uuid)` | `e98cc059565681d9842fbae2d7c14d2c` |
| `usuario_activo(uuid)` | `14e4f42f6bf09cd73632e0cb01315e28` |
| `vigilar_super_admin()` | `db4b2afd572b55e5417324113c20a4d5` |
| `handle_new_user()` | `d9133e6ed8105d122c96bd12b467c642` |
| `cliente_tiene_cxc_vencidas(uuid)` (**definer**, la Fase 2 la pasa a invoker) | `883987f113018c5230259eb736bb6a99` |
| `cxc_vencidas_resumen(uuid)` (**definer**) | `9ff424ca715c394af47d857593f0b1fa` |

La definición de `impedir_escalada_rol()` **no estaba en el repo** (hallazgo D1): el cambio 2 la trae al repo, y su reversa la restituye tal como estaba (respaldo del esquema del 25 oct).

**Conteos de la sección 2 (consulta `consultas/02-conteos-linea-base.sql`), sobre la réplica con Fase 1:**

| Qué se cuenta | Antes de la Fase 2 | Después | Por qué |
|---|---|---|---|
| Funciones de `public` | 268 | **270** | +2 funciones de trigger (cambios 1 y 5) |
| SECURITY DEFINER | 240 | **240** | +2 nuevas (triggers) −2 (cartera pasa a invoker) |
| SECURITY DEFINER ejecutables por `authenticated` | 178 | **176** | Las dos de cartera dejan de ser definer |
| Políticas de `public` | 301 | **300** | Se quita `profiles_update_admin` |
| Todo lo demás (RLS, vistas, permisos de tablas, `anon`, `search_path`, realtime) | — | **sin cambio** | La Fase 2 no toca permisos |

En producción esos números son los de `LINEA-BASE-2026-10-25.md` menos lo que mueva la Fase 1: 268 funciones → **270**; SECURITY DEFINER ejecutables por `authenticated` 208 → 178 (Fase 1) → **176** (Fase 2).

## 2. Los 12 roles de los recorridos

Usuarios inventados (`@ejemplo.test`) en la réplica. Cada acción corre en una subtransacción que se revierte.

| Rol | Área / nivel | Para qué está |
|---|---|---|
| sin área | sin fila en `user_roles` | Quien entró y aún no tiene tipo de usuario |
| vendedor, vendedor 2 | Comercial / operador, `es_vendedor` | Dueño del cliente y otro vendedor que **no** lo ve |
| administrativo | Comercial / operador, `es_administrativo` | La bandera que se podía autopromover |
| admin Comercial, admin Comercial 2 | Comercial / admin | Un admin de área y su par |
| admin Administración | Administración / admin | Admin de **otra** área |
| admin global | Dirección / admin, **no** super admin | Los 4 de producción que no son super admin (D3–D6) |
| super admin, super admin 2 | Dirección / admin, en `super_admins` | S1 y S2 |
| operador Fábrica, operador Finanzas | operador | Roles sin poder de administrar |

**Destinos de las ediciones:** un operador de Comercial (el «usuario de su área» de la tabla), el operador de Finanzas («otra área»), el par administrador y el otro super admin.

## 3. Qué debe poder y no poder cada rol (criterio de aceptación)

| Rol | Debe poder | No debe poder |
|---|---|---|
| Cualquiera | Cambiar su **nombre** | Ponerse `es_vendedor` / `es_administrativo`; cambiar su activo, correo, código de vendedor, área o nivel (**C1**) |
| Admin de área (Comercial) | En usuarios de **su área y de nivel menor**: activar/desactivar, `es_vendedor`, `es_administrativo`, datos del perfil; subir a supervisor | Tocar otra área; tocar a otro admin; crear admins; hacer global a nadie; tocar a un super admin (**C2, C3**) |
| Admin de otra área (Administración) | Lo mismo, **en su área** | Editar al operador de Comercial (otra área) |
| Admin global (no super) | Todo con usuarios que no son super admin; asignar el Super admin con la función | Modificar el perfil o el rol de un super admin (**C3**) |
| Super admin | Modificar al **otro** super admin | Cambiarse a sí mismo algo que no sea el nombre |
| Operador, vendedor, sin área | Nada sobre otros perfiles | — |
| Todos los de arriba | Leer la cartera vencida **solo de clientes que ya ven** | Leer la de un cliente que no ven (**C5**) |

## 4. Resultado esperado y real, por acción (réplica; antes y después de la Fase 2)

Se probaron **27 acciones × 12 roles = 324 comprobaciones**. Antes de la Fase 2: **62 no coinciden con lo esperado** (los huecos). Después: **0**.

| Acción (sobre el destino indicado) | ANTES: quién puede | DESPUÉS: quién puede |
|---|---|---|
| C1 propio: cambiar su correo | admin Comercial, admin global, admin Administración, admin Comercial 2, super admin, super admin 2 | **nadie** |
| C1 propio: cambiar su código de vendedor | admin Comercial, admin global, admin Administración, admin Comercial 2, super admin, super admin 2 | **nadie** |
| C1 propio: cambiar su nombre | todos (12) | todos (12) |
| C1 propio: cambiarse el rol | **nadie** | **nadie** |
| C1 propio: desactivarse | admin global, super admin, super admin 2 | **nadie** |
| C1 propio: ponerse es_administrativo | admin Comercial, admin global, admin Administración, admin Comercial 2, operador Finanzas, operador Fábrica, sin área, super admin, super admin 2, vendedor, vendedor 2 | **nadie** |
| C1 propio: ponerse es_vendedor | admin Comercial, admin global, admin Administración, admin Comercial 2, administrativo, operador Finanzas, operador Fábrica, sin área, super admin, super admin 2 | **nadie** |
| C2 hacer administrador global a un usuario | admin global, super admin, super admin 2 | admin global, super admin, super admin 2 |
| C2 otro administrador de su área: cambiar nombre | admin Comercial, admin global, admin Administración, super admin, super admin 2 | admin global, super admin, super admin 2 |
| C2 otro usuario de su área: cambiar nombre | admin Comercial, admin global, admin Administración, admin Comercial 2, super admin, super admin 2 | admin Comercial, admin global, admin Comercial 2, super admin, super admin 2 |
| C2 otro usuario de su área: desactivar | admin Comercial, admin global, admin Comercial 2, super admin, super admin 2 | admin Comercial, admin global, admin Comercial 2, super admin, super admin 2 |
| C2 otro usuario de su área: es_administrativo | admin Comercial, admin global, admin Administración, admin Comercial 2, super admin, super admin 2 | admin Comercial, admin global, admin Comercial 2, super admin, super admin 2 |
| C2 otro usuario de su área: es_vendedor | admin Comercial, admin global, admin Administración, admin Comercial 2, super admin, super admin 2 | admin Comercial, admin global, admin Comercial 2, super admin, super admin 2 |
| C2 pasar a un usuario a otra área | admin global, super admin, super admin 2 | admin global, super admin, super admin 2 |
| C2 subir de nivel a un operador de su área | admin Comercial, admin global, admin Comercial 2, super admin, super admin 2 | admin global, super admin, super admin 2 |
| C2 usuario de OTRA área: cambiar nombre | admin Comercial, admin global, admin Administración, admin Comercial 2, super admin, super admin 2 | admin global, admin Administración, super admin, super admin 2 |
| C2 usuario de OTRA área: es_administrativo | admin Comercial, admin global, admin Administración, admin Comercial 2, super admin, super admin 2 | admin global, admin Administración, super admin, super admin 2 |
| C3 asignar_super_admin (RPC) a un usuario normal | admin global | admin global |
| C3 lista: borrar de super_admins | **nadie** | **nadie** |
| C3 lista: escribir en super_admins | **nadie** | **nadie** |
| C3 super admin: bajarle el nivel | admin global, super admin, super admin 2 | super admin, super admin 2 |
| C3 super admin: cambiar su correo | admin Comercial, admin global, admin Administración, admin Comercial 2, super admin, super admin 2 | super admin, super admin 2 |
| C3 super admin: cambiar su nombre | admin Comercial, admin global, admin Administración, admin Comercial 2, super admin, super admin 2 | super admin, super admin 2 |
| C3 super admin: desactivarlo | admin global, super admin, super admin 2 | super admin, super admin 2 |
| C3 super admin: quitarle el rol | admin global, super admin, super admin 2 | super admin, super admin 2 |
| C5 cartera vencida: resumen (cliente de vendedor) | todos (12) | admin Comercial, admin global, admin Administración, admin Comercial 2, administrativo, operador Finanzas, operador Fábrica, super admin, super admin 2, vendedor |
| C5 cartera vencida: ¿tiene? (cliente de vendedor) | todos (12) | admin Comercial, admin global, admin Administración, admin Comercial 2, administrativo, operador Finanzas, operador Fábrica, super admin, super admin 2, vendedor |

Las acciones «sobre otro administrador de su área» y «super admin» no tienen a nadie en la columna de después salvo quien debe poder. «C1 propio: cambiarse el rol» ya estaba cerrado por `impedir_escalada_rol` y sigue así.

## 5. Recorridos de pantalla en la ventana (no cubiertos por la réplica)

Con cuentas de prueba, antes y después de cada cambio (los de la Fase 1 siguen vigentes: `RECORRIDOS-Y-PRUEBAS-POR-ROL.md` 1–12), más:

| # | Recorrido | Resultado esperado |
|---|---|---|
| U1 | Admin global abre **Usuarios** y edita nombre, área y nivel de un usuario | Se guarda («actualizado») |
| U2 | Admin global activa/desactiva un usuario | Se guarda |
| U3 | Admin de Comercial edita a un vendedor de su área (nombre y `es_administrativo`) | Se guarda |
| U4 | Admin de Comercial intenta pasar a ese vendedor a **Dirección / admin** o a **otra área** | Mensaje de rechazo; el usuario no cambia |
| U5 | Admin de Comercial intenta editar a un usuario de **otra área** | Rechazo |
| U6 | Admin de Comercial intenta crear un usuario de nivel **admin** | Rechazo («solo un administrador global») |
| U7 | Admin global (no super) intenta editar, desactivar o restablecer a un **super admin** | Rechazo |
| U8 | Super admin edita al **otro** super admin | Se guarda |
| U9 | Usuario normal abre su perfil y cambia su nombre | Se guarda |
| U10 | Alta de usuario desde Usuarios (admin global) | Correo enviado y perfil creado |
| U11 | Restablecer contraseña (admin de su área) | Correo enviado |
| U12 | Crear una **remisión** a un cliente con cartera vencida (vendedor dueño del cliente) | Se **bloquea** por cartera, como hoy |
| U13 | Crear una remisión (vendedor) a un cliente **sin** cartera vencida | Se crea |
| U14 | Ver la fila nueva en el rastro tras cada U1–U11 | Un renglón en `bridge_bitacora` con actor y correlación |

## 6. Cómo repetirlo

```bash
# Réplica local (PostgreSQL 16, datos inventados) y ensayo completo:
PGOPTIONS='-c role=postgres' python3 docs/seguridad/ensayo/construir-replica-fiel.py <base> <definiciones.json>
PGOPTIONS='-c role=postgres' python3 docs/seguridad/ensayo/ensayar-fase-2.py <base> <salida.json>
# Solo los recorridos de la Fase 2:
python3 docs/seguridad/ensayo/recorridos-fase-2.py <base> [salida.json]
```
El resultado de esta corrida está en `ensayo/resultado-ensayo-fase-2-2026-10-26.json` y los recorridos en `ensayo/resultado-recorridos-fase-2-antes.json` y `…-despues.json`.

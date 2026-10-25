# Hallazgos pendientes para las siguientes fases

Surgieron durante la Fase 0 (25 oct 2026). **Ninguno se corrigió**: están fuera de la Fase 1. Ordenados por importancia.

## Seguridad

| # | Hallazgo | Evidencia | Fase propuesta |
|---|---|---|---|
| S1 (**prioritario**) | **Un administrador de cualquier área puede cambiar el nombre, el correo y el código de vendedor del perfil de otra área y del super admin.** El trigger `proteger_campos_privilegiados_profiles` y la política `profiles_update_admin` tratan como «admin» a cualquier usuario con nivel admin de cualquier área. **Además, cualquier usuario puede ponerse a sí mismo `es_vendedor` y `es_administrativo` en verdadero** (probado en la réplica: el usuario de Compras lo logra; el trigger no protege esos dos campos). Eso es una **autopromoción**: `asignar_vendedor_remision` autoriza a cualquiera con `es_administrativo` (de cualquier área) a reasignar el vendedor de una remisión, y `es_administrativo_comercial` da a ese indicador, dentro de Comercial, la visibilidad de todas las remisiones (migración `20261020000002`). Responde la preocupación de Juan Carlos sobre «modificar a un usuario desde el front». | Probado en la réplica con las políticas y triggers de producción: el «admin de área (Comercial)» obtiene `✓ 1` al editar nombre y correo del super admin y de otra área (`RECORRIDOS-Y-PRUEBAS-POR-ROL.md`). **Lo que sí está protegido:** rol y área (`impedir_escalada_rol`), `activo` (`proteger_profile_activo`), rol propio y baja del administrador global. | **Fase 2** (perfiles, roles y super admin) |
| S2 | `cliente_tiene_cxc_vencidas(uuid)` y `cxc_vencidas_resumen(uuid)`: SECURITY DEFINER **sin verificar identidad ni permiso**; cualquier usuario con sesión consulta las cuentas por cobrar vencidas de cualquier cliente. `saldo_refaccion_a_fecha` y `compras_parametro`: igual, de menor sensibilidad. | `CLASIFICACION-FUNCIONES.md`, hallazgos. Leído el cuerpo de las cuatro. | Fase de funciones (grupo 3) |
| S3 | Los predicados de permiso con `uid` como argumento (`puede_*(uid)`, `es_super_admin(uid)`, `has_role(uid, …)`) permiten a cualquier usuario averiguar los roles de otros. | `CLASIFICACION-FUNCIONES.md` | Mover el grupo 2 a un esquema no expuesto (propuesta en ese documento) |
| S4 | **208 funciones SECURITY DEFINER ejecutables por usuarios con sesión** (178 tras la Fase 1): 46 sin llamador conocido en el código (grupo 3B) son candidatas a cerrarse. | `CLASIFICACION-FUNCIONES.md` | Fase de funciones |
| S5 | `crm_paradas_all` (FOR ALL, rol `public`) depende solo de que exista la ruta; la barrera real es la seguridad por filas de `crm_rutas`. | `USO-DE-ANON-Y-REALTIME.md` §3 | Fase de políticas |
| S6 | `anon` conserva SELECT en las 93 tablas (hoy falla porque las políticas llaman funciones que `anon` no ejecuta, pero es una segunda barrera, no la primera) y USAGE/UPDATE en las 9 secuencias existentes (`nextval`/`setval`). | Respaldo de permisos; defaults de secuencias | Fase 1b (decisión de Polo) |
| S7 | Permiso `MAINTAIN` (PostgreSQL 17) concedido a `anon` y `authenticated` en todas las relaciones. No estaba en el plan. | `LINEA-BASE-2026-10-25.md` §1 | Fase 1b: una migración corta; no se ensayó localmente porque el motor local es 16 |
| S8 | **Cuenta de super admin con correo `…@qq.com`.** Hay dos super admins activos; uno es la cuenta del administrador de Dazon (dominio dazon.mx) y el otro tiene un correo de `qq.com`. | `super_admins` (solo lectura) | **Polo debe confirmar que es legítima** antes de la ventana |
| S9 | La llave `anon` anterior sigue pendiente de rotación (según la guía del equipo). Con la Fase 1, quien la tenga ya no puede escribir; sí puede intentar leer. | `docs/guia-del-equipo.md` | Fase aparte (afecta a MATI Admin y funciones) |
| S10 | Protección contra contraseñas filtradas apagada; el front no maneja bien su error. | `CONTRASENAS-FILTRADAS.md` | Polo en el panel, después de arreglar el front |

## Deriva y orden en el repositorio

| # | Hallazgo | Fase propuesta |
|---|---|---|
| D1 | Producción tiene objetos que el repo no crea: 8 funciones (incluidas las protecciones de roles), 4 vistas, `zz_lista_oct`, 8 triggers, 5 columnas de `pagos`, 17 políticas. **Las protecciones `impedir_escalada_rol` y `proteger_profile_activo` no están en el repo**: una base armada solo con las migraciones no las tiene. Hay que llevarlas al repo. | Antes de la Fase 2 |
| D2 | La migración `20261014000001` (compatibilidades, baja de artículo, borrar compra) no está aplicada en producción. | Equipo de desarrollo |
| D3 | `migraciones_aplicadas` de producción está atrasado (faltan, por ejemplo, `20261009000002`, `20261010000001/2`, `20261020000001`). | Equipo; no se tocó |
| D4 | Tres pruebas opcionales de base del repo ya fallan en `origin/main` (`cobranza_pagos` en la base «anterior»; vendedor de la remisión de prueba en `pruebas_compras.sql:195`). | Equipo |
| D5 | El proyecto QA no recibirá los permisos por defecto de la migración 6: **conviene que el equipo de QA los aplique** para que QA se comporte como producción. | Equipo de QA (no se tocó) |
| D6 | `AGENTS.md` (front) y la guía del back no describían la regla de GRANT explícito. Se actualizó `docs/guia-del-equipo.md` del back; **falta el texto en `AGENTS.md` del front** (no se abre PR en ese repo): ver el bloque al final. | Equipo (PR en `kit-to-drive`) |
| D7 | `mati-admin` en producción corre desde una rama (`cursor/ficha-alta-usuarios-ktd-4b6a`), no desde `main`. | Equipo |

## Rendimiento y datos (fases 3 y 4 del plan anterior)

- Las consultas de PostgREST tardan **1–3 s** en promedio sobre tablas chicas (`LINEA-BASE-2026-10-25.md` §3): costo de 269 políticas sin optimizar y 118 políticas permisivas duplicadas.
- El sondeo interno de realtime acumula 653 s con **cero** clientes conectados en 7 días; la campana de notificaciones consulta cada 20 s por la compuerta.
- 113 llaves foráneas sin índice, 58 índices sin uso, 1 índice duplicado (`motocarros`).
- Auditoría: solo 19 de 93 tablas tienen `created_by` y 5 `updated_by`.

## Compuerta y front

- El bucket **`finanzas-docs`** lo usa el front y **no está en la lista blanca** de la compuerta: 3 solicitudes bloqueadas en 7 días. `clientes-docs` está en el mismo caso en el código del front.
- Un clon local de la compuerta iba atrasado; siempre analizar `origin/main`.

---

## Texto propuesto para `AGENTS.md` del front (no se abre PR en ese repo)

```
## Permisos de la base (producción)

- Las tablas, vistas, secuencias y funciones NUEVAS nacen cerradas: `anon` no recibe nada y
  `authenticated` no recibe EXECUTE en funciones (ni TRUNCATE/TRIGGER/REFERENCES en tablas).
- Toda función que el front llame (RPC) o que usen las políticas necesita en su migración
  `GRANT EXECUTE ON FUNCTION … TO authenticated;`. Las de trigger no lo necesitan. Una función solo
  interna se marca con el comentario `-- interna`.
- El proyecto de QA NO tiene este cambio: allí una función sin GRANT funciona y en producción no.
  `kit-to-drive-web/tests/fase1-permisos.test.ts` lo revisa en las migraciones nuevas.
```

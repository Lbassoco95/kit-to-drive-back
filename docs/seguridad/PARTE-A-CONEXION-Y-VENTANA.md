# Parte A — conexión a producción, estado actual y plan de ventana (25–26 oct 2026)

**Solo lectura. No se aplicó nada, no se tocó QA, no se inició sesión en ninguna cuenta.** Cada consulta de esta corrida corrió dentro de `begin read only; … commit;` (comprobado: `transaction_read_only = on`).

## 1. Qué conexión tengo hoy (A1)

| Pregunta | Respuesta (comprobada con consultas de solo lectura) |
|---|---|
| ¿Qué canal? | **El conector de Supabase de claude.ai** (servidor MCP de la cuenta), **no** el MCP de solo lectura de la sección 2 del encargo. |
| ¿Proyecto? | **`kit-to-drive` = `dmhzhyeivvuliumcgsmm`** (`get_project_url` → `https://dmhzhyeivvuliumcgsmm.supabase.co`; región us-west-2). **No es QA** (`qszllskpizvpnzcytqpj`, `kit-to-drive-db-qa`). |
| ¿Solo lectura o escritura? | **ESCRITURA.** Usuario de Postgres `postgres`, `transaction_read_only = off`, `BYPASSRLS = sí`, puede `UPDATE`/`INSERT` en `profiles` y crear objetos en `public`. |
| ¿Qué alcance? | **Toda la organización:** `list_projects` devuelve **10 proyectos**, entre ellos QA (`kit-to-drive-db-qa`), `Patio-yoltik`, `mati-app`, `ixim-pay`, `yoltik-regtech-hub`. |
| ¿Qué herramientas de escritura trae? | `apply_migration`, `deploy_edge_function`, `create_edge_function_secret`, `create_project`, `create_branch`, `merge_branch`, `pause_project`, `restore_project` y otras. |

### Hallazgos nuevos de esta corrida

| # | Hallazgo | Gravedad | Qué se hizo / qué se propone |
|---|---|---|---|
| **H1** | Esta sesión tiene **acceso de escritura a producción y a QA** que nadie pidió para este trabajo. | **Alta** | **No se usó para escribir.** Evidencia: todas las consultas fueron `SELECT` (en `read only` desde la Fase 0); los registros de Postgres del último día muestran **4 errores, que por fecha y mensaje corresponden a consultas mías** (un `CREATE TABLE` que la transacción de solo lectura **rechazó** el 25 oct 19:36 UTC, una función sin permiso para `anon`, una unión de tipos mal escrita y una columna mal escrita), y la foto de hoy coincide cifra por cifra con la que Polo tomó. **Propuesta:** conectar el MCP de solo lectura (§2) y **quitar o desactivar el conector de claude.ai** para este proyecto, o dejarlo solo con aprobación manual de cada llamada. |
| **H2** | En el entorno de esta sesión existe una variable **`SUPABASE_ACCESS_TOKEN`** (token de cuenta). | **Alta** | **No se leyó su valor, no se imprimió, no se usó.** Solo se comprobó que existe (nombre). **Propuesta:** Polo revisa de dónde sale (configuración del entorno de Claude), y **la revoca y la reemplaza** por una de alcance limitado o la quita. Un token de cuenta permite gestionar todos los proyectos. |
| **H3** | El historial de migraciones de producción **no coincide con el del repo**: la CLI (`supabase db push`) **no se puede usar tal cual** (§4). | **Alta (bloqueante del canal 2)** | Ver §4 y la decisión que necesita Polo. |
| **H4** | El historial de producción trae migraciones de **otro proyecto** (`patio_bridge_admin_rpcs`, `fix_patio_kit_set_user_role_conflict`) y 21 más sin equivalente en el repo: producción se ha modificado **con otra herramienta**. | Media | Explica parte de la deriva (D1–D3). No se corrige aquí. |

## 2. Canales (comandos exactos, sin secretos)

### Canal 1 — lectura y verificación (lo hace Polo, una sola vez)
```bash
claude mcp add --transport http supabase-prod "https://mcp.supabase.com/mcp?project_ref=dmhzhyeivvuliumcgsmm&read_only=true&features=database,debugging,docs"
# en Claude Code: /mcp  → completar el inicio de sesión en el navegador, eligiendo la organización que contiene kit-to-drive
```
**Comprobación** (la primera consulta de cada sesión): `get_project_url` debe devolver `dmhzhyeivvuliumcgsmm` y `show transaction_read_only;` debe dar **`on`**. Si da `off`, **no continuar**.

### Canal 2 — aplicar (solo en la ventana autorizada)
```bash
supabase login                                    # navegador
supabase link --project-ref dmhzhyeivvuliumcgsmm  # si pide la contraseña de la base, la escribe Polo en su terminal
```
**Pero el canal 2 como está descrito (`supabase db push`) no es seguro hoy: ver §4.** Hasta que Polo decida el mecanismo, **la Parte B no empieza.**
Al terminar cada ventana: `supabase unlink` y cerrar sesión.

## 3. Estado de permisos hoy (A3): producción sigue en el estado previo a la Fase 1

Se repitieron las consultas de catálogo de la línea base (`consultas/02-conteos-linea-base.sql` y adicionales, resultados en `INTEGRIDAD-ANTES.md` §5). **Todas las cifras coinciden con las del 25 oct:** 268 funciones, 240 SECURITY DEFINER, 208 ejecutables por `authenticated`, 2 por `anon`, 14 sin `search_path`, 81 tablas con escritura de `anon`, 82 con TRUNCATE, 103 con TRIGGER/REFERENCES, 16 vistas con `anon`, 301 políticas.
**Nada de la Fase 1 ni de la Fase 2 está aplicado** (0 objetos de la Fase 2; `profiles_update_admin` sigue existiendo). **Nada cambió desde la Fase 0.**

## 4. Historial de migraciones (A4)

### 4.1 Tres registros que no se parecen

| Registro | Qué es | Cuántas |
|---|---|---|
| Repo `supabase/migrations/` | Archivos | **113** (107 con versión numérica de 14 dígitos, 5 de la Fase 2 incluidos; más `fix_remisiones_columns`, sin versión) |
| Producción `supabase_migrations.schema_migrations` | Lo que la **CLI** consulta | **34** (la última, `20261014200905`) |
| Producción `public.migraciones_aplicadas` | El registro **propio del repo** (se llena a mano en cada ventana) | **90** (88 `aplicado`, 2 `superado`) |

### 4.2 Lo que encontré

- **Ninguna de las 34 versiones remotas existe como versión en el repo (0 de 34).** Cada migración se pegó en el SQL Editor o se aplicó con otra herramienta, y el historial de la CLI se llenó con marcas de tiempo distintas a los nombres de archivo. Solo 11 de las 34 coinciden por **nombre**.
- **23 de las 34 no tienen equivalente en el repo** (p. ej. `patio_bridge_admin_rpcs`, `fix_patio_kit_set_user_role_conflict`, `disable_public_signups_trigger`, `force_password_change_all_users`, `security_hardening_fase2_rls`, `bloquear_surtido_faltante` ×2, `corregir_surtido_indebido_faltante` y varias de refacciones).
- **`public.migraciones_aplicadas` no tiene sobrantes** (todo lo registrado está en el repo) y **le faltan 23 archivos del repo:** 12 anteriores (del 9 al 20 oct), las **6 de la Fase 1** y las **5 de la Fase 2**. De los 12 anteriores, el diagnóstico (`supabase/diagnostico_esquema.sql`, Fase 0) los da por **aplicados salvo** `20261014000001_catalogo_compat_baja_articulo_y_borrar_compra` (**no aplicada**, hallazgo D2) y `20261016000001_super_admin_aprobaciones` (parcial).

### 4.3 Qué haría `supabase db push` hoy (ensayo en seco por análisis; no hay CLI ni credenciales en este entorno)

1. **Se detendría con error**: «Remote migration versions not found in local migrations directory» (las 34 versiones remotas).
2. Si se «arregla» con `supabase migration repair --status reverted` para esas 34 y se vuelve a intentar, **vería 107 migraciones pendientes**, incluidas decenas que ya están aplicadas y que **no son todas idempotentes**: intentaría correr **todo el repo contra producción**.
3. Si se marcan como `applied` las ya aplicadas, `db push` correría además **`20261014000001`** (la que **no** está aplicada) y otras no registradas: **cambios fuera del plan**.

**Conclusión: no usar `db push` mientras el historial no esté alineado, y alinearlo es en sí un cambio en producción (metadatos) que hay que decidir.**

### 4.4 Decisión que necesita Polo (el canal 2 cambia)

| Opción | Cómo | Pros | Contras |
|---|---|---|---|
| **A (recomendada)** Aplicar **cada archivo exactamente como está en el repo**, en una transacción, con `psql` desde la terminal de Polo (o el SQL Editor), y **registrar** en `migraciones_aplicadas` | `psql "<cadena de conexión del panel>" -v ON_ERROR_STOP=1 --single-transaction -f supabase/migrations/<archivo>.sql` (la contraseña la escribe Polo; yo no la veo). Luego el `INSERT` de registro del runbook. | Es el mecanismo que ya usa el equipo (88 migraciones); cada paso con su verificación propia; no toca `schema_migrations`. | El historial de la CLI sigue desalineado (como hoy). |
| B Alinear la CLI primero (`migration repair`) y luego `db push` | Marcar 34 remotas como `reverted` y las ya aplicadas como `applied`, **decidiendo a mano** `20261014000001` y las parciales; `db push --dry-run` debe mostrar **solo** las 11 de las fases | Historial de la CLI limpio para siempre | **Es un cambio previo en producción**, requiere una ventana propia y un `dry-run` revisado; riesgo de error humano en ~140 marcas |
| C `apply_migration` del conector | — | — | **Prohibido** por el encargo (deja marcas de tiempo propias y más desviación) |

**Recomendación: A para las dos ventanas; B como tarea aparte, con su propia ventana y su propio `dry-run`.** Con A, **yo no ejecuto la aplicación**: la corre Polo (o quien él designe) en su terminal, y yo mido antes y después con el canal 1 (solo lectura).

### 4.5 Ensayo en seco de la Fase 1 y la Fase 2 (sin aplicar)

**Guardas de cada migración contra producción hoy** (todas pasan):

| Migración | Lo que espera | Lo que hay hoy |
|---|---|---|
| F1-1 TRUNCATE/TRIGGER/REFERENCES | 82 tablas con TRUNCATE; 103 relaciones con TRIGGER/REFERENCES | 82; 103 |
| F1-2 funciones de trigger | 53 funciones de trigger | 53 |
| F1-3 `search_path` | 14 funciones existen | **14 de 14** |
| F1-4 vistas | 16 vistas con lectura para `anon` | 16 |
| F1-5 escritura de `anon` | 81 tablas | 81 |
| F1-6 permisos por defecto | `default_acl` actual (tablas `arwdDxtm` para `anon`…) | el esperado |
| F2-1…5 | `es_super_admin`, `nivel_rank`, `usuario_activo`, `asignar_super_admin`, `impedir_escalada_rol` y su trigger, y las tablas `super_admins`, `bitacora_super_admin`, `bridge_bitacora`, `cuentas_por_cobrar`, `profiles`, `user_roles` | **5 de 5; 1; 6 de 6** |

**Orden (corregido):** el encargo pide **la de `search_path` al final y sola**. La Fase 1 en el repo está numerada 1 a 6 con `search_path` en el lugar 3; **se aplica en este orden: 1, 2, 4, 5, 6 y por último la 3, sola.** Se ensayó en ese orden en la réplica local: las seis se aplican, se revierten **exactas**, se pueden repetir y las reversas en orden inverso recuperan la línea base (son independientes entre sí).

**Qué cambiaría en el catálogo** (réplica; producción debe dar lo mismo):

| Después de… | Funciones ejecutables por `anon` | SECDEF ejecutables por `authenticated` | Sin `search_path` | Tablas con escritura de `anon` | TRUNCATE (`authenticated`) | TRIGGER/REFERENCES | Vistas con `anon` | Políticas `public` | Funciones totales / SECDEF |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| Hoy | 2 | 208 | 14 | 81 | 82 | 103 | 16 | 301 | 268 / 240 |
| Fase 1 completa | **0** | **178** | **0** | **0** | **0** | **0** | **0** | 301 | 268 / 240 |
| Fase 2 completa | 0 | **176** | 0 | 0 | 0 | 0 | 0 | **300** | **270** / 240 |

**En todos los pasos, filas y huellas de las 93 tablas: cero diferencias.** Las migraciones no escriben datos (comprobado por pruebas automáticas).
Los scripts de cuentas demo sí cambian datos, solo estos: `auth.users.banned_until` de 5 cuentas (bloque 1) y, con otra frase, `profiles.debe_cambiar_password` y `auth.users.raw_app_meta_data` de 3 cuentas. Ver `RUNBOOK-CONSOLIDADO-VENTANAS.md` §6.

## 5. Respaldo (A5)

**No puedo ver la fecha del último respaldo** con este conector. **Sin un respaldo reciente confirmado, la Parte B no empieza.**
Instrucción exacta para Polo, el día de la ventana (antes de empezar):
1. Supabase → proyecto **kit-to-drive** → **Database → Backups**.
2. En **Scheduled backups**, anotar la fecha y hora del último respaldo (Pro: diarios, 7 días). Debe ser **del mismo día o del anterior**.
3. Si hay **Point in Time Recovery**, anotar el rango disponible.
4. Escribirle la fecha a Claude en la sesión («Respaldo del <fecha hora>»).
5. Además, **opcional y recomendado:** una copia lógica **en la terminal de Polo** (la información real nunca pasa por Claude): `supabase db dump --linked -f respaldo-<fecha>.sql` (esquema) y `supabase db dump --linked --data-only -f datos-<fecha>.sql` (datos). Guardarla fuera del repo.
Ya existe el **respaldo lógico del esquema** de la Fase 0 (`respaldo/`, sin datos) para las reversas de permisos.

## 6. Qué sigue

`RUNBOOK-CONSOLIDADO-VENTANAS.md` (A6) y, **cuando Polo escriba la frase de autorización con fecha**, la Parte B. **No aplico nada hasta entonces.**

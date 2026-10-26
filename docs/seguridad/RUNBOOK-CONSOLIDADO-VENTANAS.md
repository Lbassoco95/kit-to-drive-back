# Runbook consolidado de las ventanas (Fase 1 y Fase 2) — A6

**Estado: NADA APLICADO.** Reemplaza el orden de `VENTANA-FASE-1.md` y de `RUNBOOK-VENTANA-FASE-2.md` donde se contradigan (cambios: orden de la Fase 1, mecanismo de aplicación, integridad de la información en cada paso, scripts de correo y de contraseña). Los otros dos documentos siguen valiendo para el detalle de cada migración y de cada recorrido.

## 0. Frases de autorización (las escribe Polo, en la sesión, con fecha)

| Frase | Autoriza **solo** |
|---|---|
| «Autorizo Fase 1 en producción, ventana del `<fecha>`» | Las 6 migraciones de la Fase 1 |
| «Autorizo Fase 2 en producción, ventana del `<fecha>`» | Las 5 migraciones de la Fase 2 y el despliegue de las Edge Functions |
| «Autorizo bloquear cuentas inactivas, ventana del `<fecha>`» | El bloque 1 del script de bloqueo (5 cuentas). `edgar`, solo con confirmación expresa |
| «Autorizo migrar a correo real a lee y marco, correos: `<correos>`, ventana del `<fecha>`» | El script de correo, con **esos** correos |
| «Autorizo cambio de contraseña obligatorio a lee, ventana del `<fecha>`» | El script de cambio obligatorio, solo `lee` |

**Orden:** Fase 1 → verificación completa → **una semana de observación** → Fase 2 (otra ventana). Los scripts de cuentas demo van **al final de la ventana de la Fase 2 o en otra**, cada uno con su frase. Cada frase vale **solo** lo que nombra. Si falta algo, no se hace.

## 1. Quién y con qué

| Quién | Qué hace | Disponibilidad |
|---|---|---|
| **Polo** | Autoriza; **corre** los comandos de aplicación en su terminal (mecanismo A, §2); escribe la fecha del respaldo | Toda la ventana |
| **Una persona de pruebas por rol** (la designa Polo) | Hace los recorridos de pantalla antes y después de cada paso, con **una cuenta por cada rol**: sin área, vendedor (dueño de un cliente), otro vendedor, administrativo, admin de área, admin de otra área, administrador global, super admin | **Toda la ventana, sin interrupciones.** Si no hay quien pruebe, **no se empieza** |
| **Claude** | Mide con el MCP de **solo lectura** (conteos, huellas, catálogo, registros), compara con lo previsto y dice «sigue» o «detente». **No aplica.** | Toda la ventana |
| Administradores (incluido el de China) | Se les avisa al empezar y al terminar | — |

## 2. Cómo se aplica (mecanismo A, decisión de Polo en `PARTE-A-CONEXION-Y-VENTANA.md` §4.4)

Cada archivo **tal como está en el repo**, en **una sola transacción**, desde la terminal de Polo (la contraseña de la base la escribe él; nadie más la ve):

```bash
psql "<cadena de conexión del panel (Connect)>" -v ON_ERROR_STOP=1 --single-transaction \
     -f supabase/migrations/<archivo>.sql
```
Después, el registro (una sola línea por archivo, como en las 88 anteriores):
```sql
INSERT INTO public.migraciones_aplicadas (script, estado, notas) VALUES ('<archivo sin .sql>', 'aplicado', 'Fase <n>, ventana del <fecha>');
```
**No** se usa `supabase db push` (historial desalineado, H3) ni `apply_migration` del conector (prohibido). La reversa de cada paso es el archivo de `supabase/reversas/`, con el mismo comando.
Al terminar la ventana, Polo cierra la sesión (`unlink`/`exit`).

## 3. Antes de empezar (cada ventana) — todo en verde

1. ☐ **Frase de autorización con fecha** y la hora real **dentro de la ventana permitida** (sáb/dom, o entre semana después de las 19:00 CDMX).
2. ☐ **Respaldo confirmado** del día o del anterior, con fecha y hora escritas por Polo (`PARTE-A` §5). **Sin esto, no empieza.**
3. ☐ **Conexión de solo lectura** verificada: `get_project_url` = `dmhzhyeivvuliumcgsmm` y `show transaction_read_only;` = `on` (el conector con escritura de claude.ai, desactivado).
4. ☐ **Foto fresca de integridad** (`consultas/05` y `06`) y **comparada con `INTEGRIDAD-ANTES.md`**. Si algo cambió desde el 25 oct, **se explica antes de seguir** (actividad normal con fechas, o se detiene).
5. ☐ **Catálogo** igual que la línea base (`consultas/02-conteos-linea-base.sql`); para la ventana 2, igual que el resultado de la Fase 1.
6. ☐ **Recorridos de pantalla hechos una vez antes** y anotados (los de la Fase 0; en la ventana 2, además U1–U14).
7. ☐ **Los dos super admins activos**, uno con sesión durante la ventana. **No se modifican.**
8. ☐ **Línea base de errores:** `401/403/5xx` de las últimas 24 h en los registros de la API y de Postgres (hoy: **0** en la API; **0** de aplicación en Postgres).
9. ☐ Administradores avisados.

## 4. Ventana 1 — Fase 1 (solo permisos; ninguna fila debe cambiar)

**Orden: 1, 2, 4, 5, 6 y la de `search_path` (la 3) al final y sola.** Cada paso con la misma rutina (§4.1).

| Paso | Archivo | Qué cambia (previsto) | Verificación propia | Duración estimada\* |
|---|---|---|---|---|
| 1 | `20261031000001_fase1_quitar_truncate_trigger_references` | TRUNCATE (82 tablas), TRIGGER y REFERENCES (103 relaciones) | `0, 0, 0, 0` | 30–40 min |
| 2 | `20261031000002_fase1_cerrar_funciones_de_trigger` | EXECUTE de 53 funciones de trigger (SECDEF ejecutables 208 → 178; `anon` 2 → 0) | `0, 0, true, true`; «Funciones de trigger cerradas: 53» | 30–40 min (incluye **alta de usuario**) |
| 3 | `20261031000004_fase1_quitar_lectura_anon_de_vistas` | `anon` sin lectura de 16 vistas | «Vistas cerradas a anon: 16»; `0, 18` | 25–30 min |
| 4 | `20261031000005_fase1_quitar_escritura_anon_de_tablas` | `anon` sin INSERT/UPDATE/DELETE (81 tablas) | `0` | 25–30 min |
| 5 | `20261031000006_fase1_lo_nuevo_nace_cerrado` | Permisos por defecto de lo nuevo | `true, true, true` | 25–30 min |
| 6 | `20261031000003_fase1_fijar_search_path` **(al final y sola)** | `search_path` de 14 funciones | «Funciones con search_path fijado: 14»; `0` | 30–40 min (recorrido **completo**) |

\* Estimaciones, no medidas: la aplicación tarda segundos; el tiempo lo ponen la persona de pruebas (15–25 min por vuelta) y la comparación de integridad (1–2 min).
**Total previsto:** ~45 min de preparación + ~3 h de pasos + ~45 min de cierre = **≈ 4,5 h**, dentro de 10:00–18:00.

### 4.1 Rutina de cada paso (B1–B4)

1. **Aplicar** el archivo (§2) y leer su verificación: debe coincidir con la tabla.
2. **B1, permisos:** repetir `consultas/02-conteos-linea-base.sql`: debe cambiar **solo** lo previsto (tabla de `PARTE-A` §4.5).
3. **B2, recorridos por rol:** la persona de pruebas repite los recorridos (**1, 2, 3, 5 y 6 obligatorios** tras los pasos 1 y 2). Resultado igual que antes.
4. **B3, integridad:** Claude corre la consulta de comparación (`generar-comparacion.py` + `06`) y compara con `INTEGRIDAD-ANTES.md`.
   - **Una migración de solo permisos debe dejar CERO diferencias** en filas y huellas de las 93 tablas, en `auth.users` y en Storage.
   - Si aparece una diferencia: **se detiene**. Solo se acepta si se **demuestra**, con la fecha y hora de creación de cada fila nueva, que la causó una operación normal de un usuario (y no el cambio). La explicación va por escrito en `INTEGRIDAD-RESULTADO-FASE-1.md`; **la diferencia no se da por buena sin esa evidencia.**
5. **B4, errores:** `401/403/5xx` y errores de Postgres comparados con la línea base (API y Postgres).
6. **Registrar** (§2) y recién entonces, el siguiente paso.

## 5. Una semana de observación

Sin cambios. Revisar cada día los registros; si alguien reporta algo, se revisa **antes** de la ventana 2. Al cabo de la semana, repetir la foto de integridad: las diferencias contra el cierre de la ventana 1 deben ser solo actividad normal, explicada.

## 6. Ventana 2 — Fase 2 (+ scripts de datos)

Prerrequisito: **Fase 1 aplicada, observada una semana y `INTEGRIDAD-RESULTADO-FASE-1.md` con veredicto «sí se mantuvo».**

### 6.1 Migraciones y funciones (frase «Autorizo Fase 2…»)

| Paso | Qué | Previsto | Pruebas obligatorias |
|---|---|---|---|
| 1 | `20261107000001…` (perfiles) | `1, true`; funciones 268 → 269 | U1, U2, U9, U10 |
| 2 | `20261107000002…` (roles) | `1, true, true` | U3–U8 |
| 3 | `20261107000003…` (política `profiles_update_admin`) | `0`; políticas 301 → 300 | U1–U5 |
| 4 | `20261107000004…` (cartera) | `false, false`; SECDEF ejecutables 178 → 176 | **U12, U13** |
| 5 | `20261107000005…` (rastro super admins) | `1, true`; funciones 269 → 270 | — |
| 6 | Edge Functions, **una a una** (`admin-update-user`, `admin-create-user`, `admin-reset-user-password`) con el flujo manual `deploy-edge-functions.yml` | Un renglón nuevo en `bridge_bitacora` tras la primera edición | U1, U3–U8, U10, U11, U14 |

**Integridad en la ventana 2:** las cinco migraciones son de permisos/estructura: **cero diferencias** en filas y huellas. **Las Edge Functions sí escriben**: cada prueba de pantalla que edite un usuario cambia `profiles` y deja un renglón en `bridge_bitacora` (**esos son los únicos cambios aceptados**, se listan con fecha y hora). Para no mezclar, las pruebas que editan datos se hacen **con cuentas de prueba o con ediciones que se revierten por la misma pantalla**, y se anotan.

### 6.2 Scripts de datos (cada uno con su frase; el resto de las tablas debe quedar idéntico)

Antes de correr cada uno, Claude **lista las filas y campos que deben cambiar**; cualquier diferencia fuera de la lista **detiene**.

| Script | Frase | Cambios previstos (**y solo estos**) | Cifras previstas |
|---|---|---|---|
| `fase2-desactivar-cuentas-demo-inactivas.sql`, bloque 1 | «Autorizo bloquear cuentas inactivas…» | `auth.users.banned_until`: `NULL` → `infinity` en **5 filas**: `admin@`, `coordinador@`, `fabrica@`, `logistica@`, `ventas@dazon.demo` | `auth.users` bloqueados **0 → 5**, no bloqueados **26 → 21**; `huella_sin_contrasena` de `auth.users` **cambia**; `huella_contrasenas`, `auth.identities`, `profiles` y las 93 tablas: **sin diferencias**; sesiones y tokens: mismo conteo (Auth ya no los renueva) |
| `fase2-migrar-correo-real-lee-marco.sql` | «Autorizo migrar a correo real a lee y marco, correos: …» | **2 usuarios:** `auth.users.email` (+ `raw_user_meta_data.email` si existe) y `updated_at`; **2 identidades:** `identity_data.email`; **2 perfiles:** `profiles.email` | `auth.users` total y bloqueados iguales; `profiles` huella cambia (2 filas, campo `email` y `updated_at`); **ninguna otra tabla** |
| `fase2-forzar-cambio-password-demo-activas.sql` (solo `lee`) | «Autorizo cambio de contraseña obligatorio a lee…» | `lee` ya tiene `debe_cambiar_password = true` y `must_change_password = true`: **ningún valor cambia**; solo `profiles.updated_at` de **1 fila** | `profiles` huella cambia por esa fila |

Cada script devuelve su verificación y se comprueba; **y** se repite la comparación de integridad: solo las filas listadas pueden diferir.
**El bloqueo de cuentas se prueba después con `finanzas`, `lee` y `marco`:** siguen iniciando sesión (el script no los toca).

## 7. Cuándo detenerse y revertir (todas las ventanas)

Se **detiene** y se aplica la **reversa de esa pieza** (y de las anteriores, en orden inverso, si hace falta) si, tras cualquier paso:
- falla un recorrido por rol que antes pasaba;
- un usuario legítimo pierde una acción que tenía;
- aumentan los `401/403/5xx` contra la línea base;
- **algún conteo o huella cambia sin explicación demostrada**;
- la medición posterior no coincide con la prevista (§4 y §6);
- el alta de usuarios falla, una remisión a cliente moroso deja de bloquearse (U12) o un vendedor no puede crear una remisión normal (U13);
- el rastro de `bridge_bitacora` no aparece tras desplegar las funciones.
`REVOKE`/`DROP` que falle por dependencia: **no** `CASCADE`; se detiene y se reporta.
Se reporta qué pasó, qué se revirtió y el estado final.

## 8. Al terminar cada fase

1. `INTEGRIDAD-RESULTADO-FASE-<n>.md`: tabla por tabla antes y después, veredicto **«la información se mantuvo: sí/no (y en qué tablas no)»**, diferencias explicadas, estado final de permisos frente al objetivo.
2. Repetir la línea base completa y guardarla (`REPORTE-FASE-<n>.md`).
3. `RESUMEN-PARA-CUADERNO.md` (una página, lenguaje simple, cifras de antes y después).
4. Avisar a los administradores; una semana de observación.

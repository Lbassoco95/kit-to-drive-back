# Runbook consolidado de las ventanas (Fase 1 y Fase 2) — mecanismo A

**Estado: NADA APLICADO.** Este guion reemplaza el orden y el mecanismo de `VENTANA-FASE-1.md` y de `RUNBOOK-VENTANA-FASE-2.md`. Esos dos siguen valiendo para el detalle de cada migración y de cada recorrido.

**Decisiones de Polo (26 oct):** cada archivo se aplica **tal cual** con `psql`, **en una transacción**, **desde la terminal de Polo**, y se registra en `migraciones_aplicadas`. No se usa `supabase db push` ni `apply_migration`. **Polo escribe la contraseña de la base; Claude no la ve.**

> **Para la ventana 1 (Fase 1) el guion vigente es `RUNBOOK-FINAL-FASE-1.md`.** Este documento sigue valiendo para la ventana 2 y los scripts de cuentas.

**Modo de medición (cambio del 26 oct, tarde):** **no hay canal de solo lectura para Claude.** Claude **no usa el conector de Supabase de claude.ai para nada, ni para leer** (se repite en cada reporte). Todo dato de producción lo obtiene **Polo** corriendo SQL de solo lectura (`begin read only; … rollback;`) en el SQL Editor o con los scripts de `scripts/ventana/`, y **pegándolo en la sesión**: solo conteos, huellas y catálogo, nunca filas con datos personales. Todo el SQL está en **`SQL-PARA-POLO.md`**. Claude compara lo pegado con lo previsto y dice «sigue» o «detente». **Puente de Patio:** confirmado por Polo que no existe; `20261009000002` **no entra a ninguna ventana** (solo se registra en `migraciones_aplicadas` como aplicada, aparte).

## 0. Frases de autorización (las escribe Polo, en la sesión, con fecha)

| Frase | Autoriza **solo** |
|---|---|
| «Autorizo Fase 1 en producción, ventana del `<fecha>`» | Las 6 migraciones de la Fase 1 |
| «Autorizo Fase 2 en producción, ventana del `<fecha>`» | Las 5 migraciones de la Fase 2 y el despliegue de las Edge Functions |
| «Autorizo bloquear cuentas inactivas, ventana del `<fecha>`» | El bloque 1 del script de bloqueo (5 cuentas). `edgar`, solo con confirmación expresa |
| «Autorizo migrar a correo real a lee y marco, correos: `<correos>`, ventana del `<fecha>`» | El script de correo, con **esos** correos |
| «Autorizo cambio de contraseña obligatorio a lee, ventana del `<fecha>`» | El script de cambio obligatorio, solo `lee` |
| (sin frase aún) cerrar las sesiones de `lee` | Ver `PROPUESTA-LEE-CIERRE-DE-SESIONES.md`: necesita su propia frase |

Orden: Fase 1 → verificación completa → **un día de observación** → Fase 2 (otra ventana) → **bloqueo de cuentas, al final y separado** (su propia frase, su propia ventana o el cierre de la de la Fase 2). Cada frase vale solo lo que nombra.
**Ventana permitida:** sábados y domingos, o entre semana **después de las 19:00 (CDMX)**. Nunca durante el uso normal de Dazon.

### Resumen de las dos ventanas

| Ventana | Cuándo | Frase de autorización (la escribe Polo, en la sesión, con fecha) | Qué cubre |
|---|---|---|---|
| **1 — Fase 1** | Sábado o domingo, o entre semana **después de las 19:00 CDMX** | «Autorizo Fase 1 en producción, ventana del `<fecha>`» | Solo las 6 migraciones de la Fase 1 (§4) |
| **2 — Fase 2** | **El día siguiente** a la ventana 1, **solo si la Fase 1 salió limpia** (§5) y dentro de la ventana permitida | «Autorizo Fase 2 en producción, ventana del `<fecha>`» | Solo las 5 migraciones de la Fase 2 y las 3 Edge Functions (§6) |

La frase de la ventana 2 **no se escribe de antemano**: Polo la escribe después de ver el veredicto de §5. Cada frase vale solo lo que nombra; los scripts de cuentas tienen las suyas (§0).

## 1. Quién y con qué

| Quién | Qué hace |
|---|---|
| **Polo** | Autoriza. **Corre** los scripts de `scripts/ventana/` en su terminal. Escribe la contraseña de la base (una vez, sin eco). Escribe la fecha del respaldo. **Corre los bloques de `SQL-PARA-POLO.md`** y pasa a Claude los resultados |
| **Persona de pruebas** (la designa Polo) | Ejecuta `HOJA-DE-PRUEBAS-POR-ROL.md` antes y después de cada paso. **No necesita saber de programación**; necesita una cuenta por cada rol y estar **toda la ventana**. Si no hay quién pruebe, no se empieza |
| **Claude** | **No tiene canal a producción** y no usa el conector de Supabase de claude.ai (ni para leer). Compara **lo que Polo pega** (catálogo, huellas, registros) con lo previsto y dice «sigue» o «detente». **No aplica nada** |
| Administradores (incluido el de China) | Se les avisa al empezar y al terminar |

## 2. Preparar la terminal de Polo (una vez por ventana)

```bash
cd kit-to-drive-back                       # el repo, en la rama ya mezclada y revisada por una persona
# Copia los valores del botón Connect del proyecto kit-to-drive (Session pooler). NO escribas la contraseña aquí:
export PGHOST=<host del pooler>  PGPORT=5432  PGUSER=postgres.dmhzhyeivvuliumcgsmm  PGDATABASE=postgres  PGSSLMODE=require
source scripts/ventana/conectar.sh         # pide la contraseña SIN eco, comprueba que es producción y no QA
```
`conectar.sh` se **detiene** si ni `PGUSER` ni `PGHOST` contienen `dmhzhyeivvuliumcgsmm`, o si aparece la referencia de QA, y muestra `zz_lista_oct` y `super_admins`: en producción debe ser **`zz_lista_oct=2219` y `super_admins=2`** (a la fecha del 26 oct; si cambió por actividad, explicarlo).
Al terminar la ventana: `unset PGPASSWORD PGHOST PGUSER` y cerrar la terminal. **La contraseña no queda en archivos ni en el historial** (se lee con `read -s`).

## 3. Antes de empezar (cada ventana) — todo en verde

1. ☐ **Frase de autorización con fecha** y hora **dentro de la ventana permitida**.
2. ☐ **Respaldo:** Polo le escribe a Claude «Respaldo del `<fecha y hora>`» (Database → Backups): **del mismo día o del anterior**. Opcional recomendado: copia lógica en su terminal (`PARTE-A-CONEXION-Y-VENTANA.md` §5). **Sin esto, no empieza.**
3. ☐ **Bloques de `SQL-PARA-POLO.md` corridos por Polo y pegados** el mismo día: **0** (es producción, no QA; sin bloqueos), **A2** (foto fresca; se guarda como `integridad/antes-ventana-fase-1.txt`), **A3**, **D1** y **D2**. Claude los lee y dice «verde» o «detente».
4. ☐ **Integridad contra la referencia del 25 oct:** bloque **A1** de `SQL-PARA-POLO.md` (o `scripts/ventana/comparar-integridad.sh docs/seguridad/integridad/antes-tablas.txt` en la terminal). Cero diferencias, o diferencias **explicadas** con fecha y hora de cada fila nueva. Si no se pueden explicar: **no se empieza.**
5. ☐ **Catálogo igual que la línea base:** bloque **D1** (o `scripts/ventana/catalogo.sh`); la ventana 2, igual que el cierre de la ventana 1.
6. ☐ **Recorridos de pantalla hechos una vez antes** (hoja de pruebas, columna «Antes»).
7. ☐ **Dos super admins activos** y uno con sesión durante la ventana. No se modifican.
8. ☐ **Línea base de errores** 401/403/5xx de las últimas 24 h (API y Postgres), anotada.
9. ☐ Administradores avisados.

## 4. Ventana 1 — Fase 1 (solo permisos: **ninguna fila debe cambiar**)

**Orden: 1, 2, 4, 5, 6 y por último la 3 (`search_path`), sola.** Cada paso con la misma rutina (§4.1). Estimaciones, **no medidas**: la aplicación tarda segundos; el tiempo lo ponen la persona de pruebas (15–25 min por vuelta) y la verificación.

| Paso | Archivo (`<N>` = nombre sin `.sql`) | Qué cambia (previsto) | Verificación que imprime el script | Estimado |
|---|---|---|---|---|
| 1 | `20261031000001_fase1_quitar_truncate_trigger_references` | TRUNCATE (82 tablas), TRIGGER y REFERENCES (103 relaciones) → 0 | `0, 0, 0, 0` | 35 min |
| 2 | `20261031000002_fase1_cerrar_funciones_de_trigger` | 53 funciones de trigger cerradas (SECDEF ejecutables 208 → 178; `anon` 2 → 0) | `0, 0, true, true`; «Funciones de trigger cerradas: 53» | 35 min (incluye **alta de usuario**) |
| 3 | `20261031000004_fase1_quitar_lectura_anon_de_vistas` | `anon` sin lectura de 16 vistas | «Vistas cerradas a anon: 16»; `0, 18` | 30 min |
| 4 | `20261031000005_fase1_quitar_escritura_anon_de_tablas` | `anon` sin INSERT/UPDATE/DELETE (81 tablas) | `0` | 30 min |
| 5 | `20261031000006_fase1_lo_nuevo_nace_cerrado` | Permisos por defecto de lo nuevo | `true, true, true` | 30 min |
| 6 | `20261031000003_fase1_fijar_search_path` **(al final y sola)** | `search_path` de 14 funciones | «Funciones con search_path fijado: 14»; `0` | 40 min (recorrido **completo**) |

**Total previsto:** 45 min de preparación + 3 h 20 min de pasos + 45 min de cierre ≈ **4 h 50 min**, dentro de 10:00–18:00.

### 4.1 Rutina de cada paso

1. **Aplicar** (Polo):
   ```bash
   scripts/ventana/aplicar.sh <N> 1 <AAAA-MM-DD>
   ```
   Pide que escribas la referencia del proyecto (`dmhzhyeivvuliumcgsmm`). Por dentro, **exactamente esto**, una sola transacción (si algo falla, no queda ni el registro):
   ```bash
   psql -X -v ON_ERROR_STOP=1 --single-transaction -f supabase/migrations/<N>.sql \
     -c "INSERT INTO public.migraciones_aplicadas (script, estado, notas) VALUES ('<N>', 'aplicado', 'Fase 1, ventana del <fecha>') ON CONFLICT (script) DO UPDATE SET estado='aplicado', aplicada_at=now(), notas=EXCLUDED.notas"
   ```
   Leer la verificación que imprime y compararla con la tabla. Queda copia en `ventana-logs/`.
2. **B1, permisos:** bloque **D1** de `SQL-PARA-POLO.md` (o `scripts/ventana/catalogo.sh`), que Polo pega a Claude: debe cambiar **solo** lo previsto (`PARTE-A-CONEXION-Y-VENTANA.md` §4.5).
3. **B2, recorridos:** la persona de pruebas ejecuta la hoja (**1, 2, 3, 5 y 6 obligatorios tras los pasos 1 y 2**) y anota en «Después».
4. **B3, integridad:** `scripts/ventana/comparar-integridad.sh docs/seguridad/integridad/antes-tablas.txt` (Polo) **o** `generar-comparacion.py` sobre `antes-ventana-fase-1.txt` pegado en el SQL Editor; Polo pega el resultado a Claude.
   - Una migración de solo permisos debe dar **«CERO diferencias»**. Cualquier otra salida **detiene**.
   - Una diferencia solo se acepta si se **demuestra**, con fecha y hora de creación de cada fila nueva, que la causó una operación normal de un usuario. La explicación va por escrito en `INTEGRIDAD-RESULTADO-FASE-1.md`. **No se da por buena sin esa evidencia.**
5. **B4, errores:** 401/403/5xx y errores de Postgres contra la línea base (Polo corre los dos conteos de **D2** en Logs Explorer y pega el resultado; Claude compara con la línea base).
6. **Registrar** ya lo hizo el paso 1. **Decisión «sigue / detente»** la dice Claude por escrito; la ejecuta Polo.

### 4.2 Reversa de cada paso (misma forma, una transacción)

**Si un paso falla o los criterios de §7 se cumplen, se revierte ESE paso y los anteriores, en orden inverso al aplicado.**
Orden inverso de la Fase 1: **3 → 6 → 5 → 4 → 2 → 1** (es decir, `search_path`, defaults, escritura de `anon`, vistas, funciones de trigger y TRUNCATE).

```bash
scripts/ventana/revertir.sh <N> 1 <AAAA-MM-DD>
```
Por dentro:
```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction -f supabase/reversas/<N>_reversa.sql \
  -c "UPDATE public.migraciones_aplicadas SET estado='superado', notas='REVERTIDA en la ventana del <fecha> (Fase 1)' WHERE script='<N>'"
```
(No se borra el renglón del registro: queda como `superado` con la nota. Si se vuelve a aplicar, `aplicar.sh` lo vuelve a poner en `aplicado`.)
Después de cada reversa: `catalogo.sh` debe volver a la línea base **y** `comparar-integridad.sh` debe dar cero diferencias. Cada reversa se **ensayó** en la réplica (catálogo idéntico al de antes).

| Reversa | Archivo `supabase/reversas/<N>_reversa.sql` |
|---|---|
| 1.º en revertir | `20261031000003_fase1_fijar_search_path` |
| 2.º | `20261031000006_fase1_lo_nuevo_nace_cerrado` |
| 3.º | `20261031000005_fase1_quitar_escritura_anon_de_tablas` |
| 4.º | `20261031000004_fase1_quitar_lectura_anon_de_vistas` |
| 5.º | `20261031000002_fase1_cerrar_funciones_de_trigger` |
| 6.º | `20261031000001_fase1_quitar_truncate_trigger_references` |

### 4.3 Tiempos: qué se hace si un paso se pasa

| Situación | Qué se hace |
|---|---|
| Un paso lleva **más de 1,5×** su estimado sin conclusión (p. ej. 55 min en uno de 35) | **Pausa.** Claude resume qué falta (qué recorrido, qué cifra). Polo decide: terminar la prueba, o revertir el paso |
| La aplicación de un archivo **no termina** (más de 2 min) o la conexión se corta | psql revierte la transacción sola. **Antes de repetir:** `catalogo.sh` y consultar el registro (`select script, estado from migraciones_aplicadas where script like '202610310%'`) para ver **en qué estado quedó**; repetir solo si no quedó aplicado |
| Es **más de las 16:00** | **No se empieza ningún paso nuevo.** Cada paso aplicado es un estado estable: se cierra con la verificación completa de lo ya aplicado y **lo que falta pasa a otra ventana** (la 3 de `search_path` siempre es la última) |
| Es **más de las 17:30** con un paso a medias | Se **revierte** ese paso y se cierra con integridad y catálogo. **Nunca se deja un paso sin verificar** |
| Falta la persona de pruebas | **Se detiene.** No se avanza sin recorridos |

## 5. Cierre de la ventana 1 y criterio «la Fase 1 salió limpia» (para abrir la ventana 2 al día siguiente)

Al terminar el paso 6, Polo corre **A1** (contra `antes-ventana-fase-1.txt`), **A3**, **D1** y **D2**, y Claude escribe `INTEGRIDAD-RESULTADO-FASE-1.md`. **La Fase 1 salió limpia** solo si se cumple **todo**:

1. Los 6 pasos aplicados y registrados como `aplicado` en `migraciones_aplicadas` (bloque **B2**).
2. **Cero diferencias** de integridad en las 93 tablas, Auth y Storage (A1 y A3), o solo actividad normal **demostrada** con fecha y hora.
3. **D1** igual a lo previsto (tabla de §4); `anon` sin escritura ni TRUNCATE; funciones de trigger cerradas.
4. Recorridos por rol sin falla (hoja de pruebas), incluida el **alta de usuario**.
5. Errores de **D2** sin aumento contra la línea base de la mañana.

**Mañana siguiente (antes de la ventana 2):** Polo vuelve a correr **A1**, **A3**, **D1** y **D2** (las últimas 24 h ya cubren el uso normal de Dazon con la Fase 1 puesta). Claude compara: si algo subió (401/403/5xx) o cambió sin explicación, **la ventana 2 no se abre** y se revisa. Si todo está igual, Claude lo dice por escrito y Polo decide si escribe la frase de la Fase 2. **Una semana de observación ya no es requisito**; sí lo es este día de observación. Quien prefiera esperar más, puede.

## 6. Ventana 2 — Fase 2 (y, al final y aparte, los scripts de cuentas)

Prerrequisito: **Fase 1 aplicada, con el veredicto «salió limpia» de §5 por escrito y la comprobación de la mañana siguiente en verde**, y `INTEGRIDAD-RESULTADO-FASE-1.md` con «la información se mantuvo: sí». Además se repite el **§3** completo (respaldo del mismo día o del anterior, foto fresca nueva guardada como `antes-ventana-fase-2.txt`, persona de pruebas, ventana horaria permitida).

### 6.1 Migraciones (frase «Autorizo Fase 2…») — orden 1, 2, 3, 4, 5

Misma rutina (§4.1) con `scripts/ventana/aplicar.sh <N> 2 <fecha>`. **Reversa en orden inverso: 5 → 4 → 3 → 2 → 1** con `revertir.sh <N> 2 <fecha>`.

| Paso | Archivo | Previsto | Pruebas obligatorias | Estimado |
|---|---|---|---|---|
| 1 | `20261107000001_fase2_perfiles_campos_protegidos` | `1, true`; funciones 268 → 269 | U1, U2, U9, U10 | 35 min |
| 2 | `20261107000002_fase2_roles_rango_y_super_admins` | `1, true, true` | U3–U8 | 35 min |
| 3 | `20261107000003_fase2_profiles_politica_por_area` | `0`; políticas 301 → 300 | U1–U5 | 25 min |
| 4 | `20261107000004_fase2_cxc_vencidas_solo_quien_ve_al_cliente` | `false, false`; SECDEF ejecutables 178 → 176 | **U12, U13** | 25 min |
| 5 | `20261107000005_fase2_super_admins_rastro` | `1, true`; funciones 269 → 270 | — | 15 min |

**Integridad:** las cinco son de permisos/estructura: **cero diferencias** en filas y huellas. Mismo criterio de detención.

### 6.2 Edge Functions (después de las migraciones)

Flujo manual `deploy-edge-functions.yml` (GitHub → Actions → *Run workflow*), **una función a la vez**: `admin-update-user` → `admin-create-user` → `admin-reset-user-password`. (El flujo usa un secreto del repo, `SUPABASE_ACCESS_TOKEN`: **es distinto del token del entorno que Polo revoca**; revisar con qué alcance está.) Tras la primera edición exitosa debe haber **un renglón nuevo en `bridge_bitacora`** (`usuario.editar`). Sin renglón o con 503: se detiene y se vuelve a desplegar la versión anterior.
**Las Edge Functions sí escriben:** cada prueba de pantalla que edite un usuario cambia `profiles` y agrega un renglón en `bridge_bitacora`: esos son **los únicos cambios aceptados** en la integridad, con fecha y hora; las pruebas que editan datos se hacen con **cuentas de prueba o con ediciones que se revierten por la misma pantalla**, y se anotan. Estimado: 20 min por función.

### 6.3 Scripts de datos (cada uno, con su frase; al final y aparte)

Se corren con `psql -X -v ON_ERROR_STOP=1 -f supabase/operaciones/<script>.sql` (traen su propio `BEGIN/COMMIT` y sus guardas). Antes de correr cada uno, Claude **lista las filas y campos que deben cambiar**; cualquier diferencia fuera de la lista **detiene**. Después: `comparar-integridad.sh` y la comparación de Auth (`consultas/06`).

| Script | Frase | Cambios previstos (**y solo estos**) | Cifras previstas |
|---|---|---|---|
| `fase2-desactivar-cuentas-demo-inactivas.sql` (bloque 1) | «Autorizo bloquear cuentas inactivas…» | `auth.users.banned_until`: `NULL` → `infinity` en **5 filas**: `admin@`, `coordinador@`, `fabrica@`, `logistica@`, `ventas@dazon.demo` (**`edgar@`: solo con confirmación; sería la fila 6**) | `auth.users`: bloqueados **0 → 5** (6 con edgar), no bloqueados **26 → 21** (20); la huella de `auth.users` sin contraseñas **cambia**; contraseñas, identidades, **profiles y las 93 tablas: sin diferencias**; sesiones y tokens: mismo conteo |
| `fase2-migrar-correo-real-lee-marco.sql` | «Autorizo migrar a correo real a lee y marco, correos: …» (**pendiente: Polo da los correos**) | **2** `auth.users` (`email`, `updated_at`, y `raw_user_meta_data.email` si existe); **2** `auth.identities` (`identity_data.email`); **2** `profiles` (`email`, `updated_at`) | `auth.users`: totales iguales; `profiles` cambia en 2 filas; ninguna otra tabla |
| `fase2-forzar-cambio-password-demo-activas.sql` (solo `lee`) | «Autorizo cambio de contraseña obligatorio a lee…» | **Ningún valor cambia** (ya está activado); solo `profiles.updated_at` de 1 fila. **No se corre** según la decisión de Polo del 26 oct | `profiles` cambia en 1 fila (`updated_at`) |
| `fase2-cerrar-sesiones-lee.sql` (propuesta) | (sin frase aún) | Ver `PROPUESTA-LEE-CIERRE-DE-SESIONES.md` | Hoy **0** sesiones de `lee`: no habría efecto |

Después del bloqueo se comprueba que **`finanzas`, `lee` y `marco` siguen entrando** (el script no los toca).

## 7. Cuándo detenerse y revertir (todas las ventanas)

Se **detiene** y se aplica la **reversa de esa pieza** (y de las anteriores, en orden inverso) si, tras cualquier paso:
- falla un recorrido por rol que antes pasaba;
- un usuario legítimo pierde una acción que tenía;
- aumentan los `401/403/5xx` contra la línea base;
- **algún conteo o huella cambia sin explicación demostrada**;
- la medición posterior no coincide con la prevista;
- el alta de usuarios falla (recorrido 3), una remisión a cliente moroso deja de bloquearse (U12) o un vendedor no puede crear una remisión normal (U13);
- el rastro de `bridge_bitacora` no aparece tras desplegar las funciones.
Un `REVOKE`/`DROP` que falle por dependencia: **no** `CASCADE`; se detiene y se reporta. Se reporta qué pasó, qué se revirtió y el estado final.

## 8. Al terminar cada fase

1. `INTEGRIDAD-RESULTADO-FASE-<n>.md`: tabla por tabla antes y después, veredicto **«la información se mantuvo: sí/no (y en qué tablas no)»**, diferencias explicadas, estado final de permisos frente al objetivo.
2. Repetir la línea base completa (`REPORTE-FASE-<n>.md`).
3. `RESUMEN-PARA-CUADERNO.md` (una página, lenguaje simple, cifras de antes y después).
4. Avisar a los administradores; una semana de observación.

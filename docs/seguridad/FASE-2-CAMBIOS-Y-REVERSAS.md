# Fase 2 — qué cambia, riesgo y reversa

**Nada de esto está aplicado en producción.** Se aplica solo dentro de la ventana y tras la frase de Polo (`RUNBOOK-VENTANA-FASE-2.md`).
Orden: primero la **Fase 1** (PR #12). La Fase 2 depende de ella y sus migraciones van a continuación (`20261107…`, después de `20261031…`).
Cada cambio es una migración, con su reversa en `supabase/reversas/` y su verificación dentro del propio archivo. Todas son idempotentes y no tocan datos.

## 1. Criterio → qué lo cumple

| Criterio | Qué lo cumple | Dónde vive la regla |
|---|---|---|
| **C1** Nadie se asciende a sí mismo | Cambio 1 (trigger) + `admin-update-user` | **Base** y código |
| **C2** Un admin de área no sube de rango a nadie | Cambios 1, 2 y 3 + `admin-create-user`, `admin-update-user`, `admin-reset-user-password` | **Base** y código (mismas reglas) |
| **C3** Super admins protegidos | Cambios 1, 2 y 5 + las tres funciones | **Base** y código |
| **C4** Lista de los 6 de Dirección | Documento `SUPER-ADMINS-Y-ADMIN-DIRECCION.md` | — (sin cambios en datos) |
| **C5** Cartera vencida | Cambio 4 | **Base** |
| **C6** Revisión de lo ya ocurrido | Documento `REVISION-PERFILES-HISTORICOS.md` | — (solo lectura) |
| **C7** Error de contraseña filtrada | PR del front [kit-to-drive#74](https://github.com/Lbassoco95/kit-to-drive/pull/74) + `complete-password-change` | Front y función |

## 2. Migraciones

### Cambio 1 — `20261107000001_fase2_perfiles_campos_protegidos` (C1, C2, C3)
- **Qué hace:** trigger `trg_proteger_perfil_fase2` (BEFORE INSERT/UPDATE en `profiles`), solo cuando hay sesión de usuario.
  1. Sobre el **propio** perfil solo se cambia el nombre.
  2. Sobre un perfil **ajeno**: si es super admin, solo otro super admin; un administrador global puede lo demás; un admin de área solo toca a usuarios de **su área y de nivel menor**; los demás, nada.
  3. INSERT: `es_vendedor`, `es_administrativo` y `codigo_vendedor` quedan reservados al administrador global.
  4. `id` y `created_at` no cambian.
- **Se suma** a `proteger_profile_activo` y `proteger_campos_privilegiados_profiles`; no quita nada.
- **Riesgo:** una pantalla que edite el perfil propio con otro campo dejaría de poder. **Revisado:** el front no escribe el perfil propio (solo lee); `Usuarios.tsx` solo cambia `activo` de **otro** usuario. `handle_new_user` (alta) corre sin sesión de usuario y no se afecta (probado).
- **Reversa:** `DROP TRIGGER` + `DROP FUNCTION`. **Probada** (catálogo idéntico).

### Cambio 2 — `20261107000002_fase2_roles_rango_y_super_admins` (C2, C3)
- **Qué hace:** reemplaza `impedir_escalada_rol()` conservando **todas** sus reglas y mensajes, y suma: (a) los roles de un super admin solo los cambia otro super admin; (b) un admin de área no crea ni modifica a otro administrador, ni siquiera de su área. Crea el trigger si no existe (en producción ya existe igual) y **trae la función al repo** (hallazgo D1).
- **Riesgo (cambio de comportamiento):** **un admin de área ya no puede crear administradores de su área**; solo un administrador global. `asignar_super_admin()` sigue funcionando (probado).
- **Reversa:** restituye la definición de producción del 25 oct (respaldo del esquema). **Probada.**

### Cambio 3 — `20261107000003_fase2_profiles_politica_por_area` (C2)
- **Qué hace:** `DROP POLICY profiles_update_admin`. Esa política dejaba a **cualquier** admin de **cualquier** área pasar la seguridad por filas sobre cualquier perfil y anulaba a `admin de area actualiza profiles`. Queda la de área (que ya incluye al administrador global) y `profiles_update_propio`.
- **Riesgo:** una pantalla que dependiera de editar perfiles de otra área. **Revisado:** `Usuarios.tsx` solo activa/desactiva y el resto pasa por Edge Functions (no usan RLS).
- **Es una segunda barrera:** el cambio 1 ya impide el daño; este quita la puerta abierta. Se puede omitir sin perder los criterios.
- **Reversa:** recrea la política con el texto exacto de producción. **Probada.**

### Cambio 4 — `20261107000004_fase2_cxc_vencidas_solo_quien_ve_al_cliente` (C5)
- **Qué hace:** `ALTER FUNCTION … SECURITY INVOKER` en `cliente_tiene_cxc_vencidas(uuid)` y `cxc_vencidas_resumen(uuid)`. Leen `cuentas_por_cobrar` con los permisos de quien llama, y esa tabla solo deja leer una cuenta si el usuario **ve al cliente**.
- **Quién las usa:** solo `evaluarBloqueoPorCartera()` (`src/lib/creditoDb.ts`), desde **Remisiones** (alta y edición): comercial, administración y quien ve al cliente. **No son solo de finanzas.**
- **Por qué no «solo finanzas y administración»:** el front **falla abierto** (si la función da error, deja pasar). Restringirla por rol haría que un vendedor reciba error y **se dejaría de bloquear la remisión a clientes con cartera vencida**, sin avisar. Con INVOKER, cada quien ve la cartera de los clientes que ya ve.
- **Probado:** antes, **los 12 roles** (incluidos «sin área» y otro vendedor) veían la cartera del cliente; después, **10 la ven y 2 no** (sin área y el vendedor que no es dueño).
- **Reversa:** `ALTER FUNCTION … SECURITY DEFINER`. **Probada.**

### Cambio 5 — `20261107000005_fase2_super_admins_rastro` (C3, opcional)
- **Qué hace:** trigger que deja un renglón en `bitacora_super_admin` cuando la lista `super_admins` cambia **fuera** de `asignar_super_admin()` (llave de servicio o SQL Editor). No bloquea nada.
- **Reversa:** `DROP TRIGGER` + `DROP FUNCTION`; los renglones ya escritos se conservan. **Probada.**

## 3. Edge Functions y código (se despliegan con el flujo manual `deploy-edge-functions.yml`)

Las funciones de usuarios escriben con la **llave de servicio**: ahí `auth.uid()` es nulo y los triggers de la base no actúan. Por eso **identifican al llamador y aplican la regla en código, antes de usar la llave** (`_shared/permisos.ts`, las mismas reglas que la base, probadas con 42 pruebas).

| Función | Qué cambia |
|---|---|
| `admin-update-user` | Reescrita. Compara contra el estado actual y valida **lo que de verdad cambia** (el front manda todos los campos). Aplica C1, C2, C3. Antes de escribir deja el **rastro** (actor, correlación, campos); **si el rastro falla, no cambia nada** (503). Escribe solo lo que cambió. El rol se escribe con **un solo `upsert`** (antes: borrar y volver a insertar, con una ventana sin rol). |
| `admin-create-user` | Valida con las mismas reglas (área, nivel, y que un admin de área no cree admins). No reutiliza una cuenta que es super admin. Deja rastro **antes** de mandar el correo y crear la cuenta. |
| `admin-reset-user-password` | Misma regla de área y **nivel**; a un super admin solo otro super admin; deja rastro antes de cambiar la contraseña. Cada admin puede restablecer la suya. |
| `complete-password-change` | Devuelve `codigo: contrasena_filtrada` / `contrasena_debil` con mensaje en español (C7). Sigue siendo un 400. |
| `seed-demo-users` | Sigue **apagada**. Contraseña aleatoria de un solo uso por correo; no toca cuentas existentes. |

**Errores que arreglan de paso (hallazgo O8 y otros):** antes, editar solo el nombre de un usuario dado de baja **lo reactivaba** (`activo ?? true`) y, si el cuerpo no traía correo, **dejaba el correo del perfil en nulo**. Ya no.

**Rastro:** renglón en `bridge_bitacora` (`usuario.crear`, `usuario.editar`, `usuario.restablecer_password`) con `actor_id`, correo del actor y un identificador de correlación (`x-request-id` de la petición o uno nuevo, que también se devuelve en la respuesta). Nunca lleva contraseñas. **La auditoría completa es la Fase 4**; esto solo deja el punto de enlace.
Hoy `mati-api` y la compuerta **no** mandan un identificador de correlación (hallazgo O16): cuando lo manden, estas funciones ya lo recogen.

## 4. Lo que cambia para las personas (avisar antes de la ventana)

1. Un **admin de área ya no crea ni modifica administradores**; solo un administrador global.
2. Un **admin de área ya no edita** a usuarios de otra área ni a otro administrador de la suya, y **no puede restablecerles la contraseña**.
3. **Nadie edita su propio perfil** salvo el nombre; tampoco se desactiva a sí mismo (hoy los administradores globales sí podían).
4. Un administrador global que **no es super admin** ya no modifica a S1 ni a S2.
5. Si el rastro no se puede guardar, la operación **se detiene** con «No se pudo registrar el cambio; no se aplicó nada».

## 5. Decisiones donde no se siguió la letra del criterio (para que Polo las confirme)

| Criterio | Qué se hizo | Por qué |
|---|---|---|
| **C5** «exigir finanzas y administración» | Exigir **ver al cliente** (invoker) | El código muestra que Remisiones (comercial) las usa; por rol se dejaría de bloquear a clientes morosos. |
| **C2** «solo activar/desactivar y es_*» | Además puede cambiar **datos del perfil** (nombre, correo, código) de usuarios de **menor nivel de su área** | Es lo que hace hoy la pantalla Usuarios; quitarlo la rompe. Lo que C2 prohíbe (otra área, nivel igual o superior, hacer global) **sí** queda cerrado. |
| **C3** «solo un super admin modifica a otro» | Se cumple para perfil y rol. **`asignar_super_admin()` sigue en manos de un administrador global que NO es super admin** | Cambiarla rompe la pantalla de Aprobaciones; ver `SUPER-ADMINS-Y-ADMIN-DIRECCION.md` §3 (opciones A y B). |
| **C1** | Tampoco puede cambiarse el `codigo_vendedor` ni el correo del perfil propio (los administradores sí podían) | «Ningún otro campo que dé poder». |

## 6. Cómo se revierte cada pieza

| Pieza | Reversa | Verificación |
|---|---|---|
| Migraciones 1–5 | `supabase/reversas/20261107000005…` a `…01…`, **en orden inverso** | El propio archivo devuelve 0/false; `consultas/02-conteos-linea-base.sql` vuelve a la línea base |
| Edge Functions | Volver a desplegar la versión anterior con el mismo flujo (`deploy-edge-functions.yml`) desde el commit anterior a este PR | Una edición desde Usuarios funciona como antes |
| Front (PR #74) | Revertir el commit en `kit-to-drive` y publicar | Cambiar contraseña funciona |
| Cuentas demo (scripts) | `…_reversa.sql` de cada script | Las cuentas vuelven a poder iniciar sesión |

## 7. Fuera de alcance (documentado, no hecho)

Rendimiento y políticas duplicadas (Fase 3); auditoría central (Fase 4); rotación de la llave pública `anon`; **activar contraseñas filtradas** (Polo, en el panel, **después** de publicar el PR del front); protección de ramas de GitHub, secretos de Vercel y segundo factor de MATI Admin; limpieza del historial de git; `asignar_super_admin` (decisión A/B); `saldo_refaccion_a_fecha` y `compras_parametro` (S2, menor sensibilidad); modificar índices o realtime.

## 8. No verificado

- Las Edge Functions **no se ejecutaron contra Supabase** (el entorno no tiene Deno ni acceso para desplegar): se probaron las reglas puras (vitest) y la forma del código; el comportamiento real se comprueba en la ventana (recorridos U1–U14).
- La respuesta del front al nuevo mensaje de 503/403 (pantalla): se ve en la ventana.

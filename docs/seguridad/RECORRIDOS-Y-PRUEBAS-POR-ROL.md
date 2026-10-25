# Recorridos y pruebas por rol (Fase 0, sección 3.5)

Hay dos niveles. **Nivel base de datos:** automatizado, corrido el 25 oct 2026 en la réplica (resultados abajo). **Nivel pantalla:** paso a paso para repetir en la ventana, porque necesita el front, la compuerta, Auth y MATI Admin reales (no se pueden ejecutar desde esta sesión).

## A. Recorridos de pantalla (a repetir antes y después de CADA migración de la Fase 1)

Usar **cuentas de prueba** (nunca datos ni usuarios reales de Dazon) o, si no existen, hacerlo con una cuenta de Polo/Leo y una remisión de prueba que luego se cancela. Un recorrido «pasa» si ocurre lo esperado y no aparece en la pantalla ni en la consola un error nuevo. Si falla alguno tras una migración: **revertir esa migración con su reversa, verificar la línea base y detenerse.**

| # | Recorrido | Pasos | Esperado |
|---|---|---|---|
| 1 | **Inicio de sesión de cada rol, con contraseña normal** | Entrar como operador, admin de área, super admin, finanzas, compras, ventas, almacén y logística | Entra y ve su menú; el menú coincide con su rol |
| 2 | **Inicio de sesión con contraseña temporal** | Con un usuario con «debe cambiar contraseña» | Pide cambiarla, la cambia, vuelve a `/auth?passwordUpdated=1` y entra con la nueva |
| 3 | **Alta de usuario desde MATI Admin** | Dar de alta un usuario de prueba con correo propio | Se crea, llega el correo con la contraseña temporal, el usuario entra y debe cambiarla. (La contraseña nunca se muestra en pantalla) |
| 4 | **Baja de usuario desde MATI Admin** | Desactivar ese usuario | Ya no puede entrar; su perfil queda `activo = false` |
| 5 | **Registro con el candado de 3 minutos** | Alta autorizada: crear usuario desde MATI Admin o `admin-create-user`. Después, intentar crear una cuenta **sin** autorización (llamada directa a Auth) | La autorizada pasa; la no autorizada falla con «Signups públicos deshabilitados» |
| 6 | **Crear y consultar una remisión** | Como ventas: crear remisión de prueba; como admin: abrirla y editarla | Se crea con folio, se ve, se edita; aparece en la bitácora |
| 7 | **Vista de cobranza** | Abrir Cobranza como finanzas/compras | Carga la lista; sin error |
| 8 | **Movimiento de inventario con notificación** | Como almacén, ajustar un artículo de prueba; mirar la campana del usuario avisado | El ajuste se guarda y la campana lo muestra **en ≤ 20 s** (en producción es consulta periódica, no tiempo real) |
| 9 | **Movimiento financiero y su registro** | Como finanzas, crear un movimiento de prueba; abrir su historial | Se crea; el trigger `log_movimiento` deja el renglón en `movimiento_bitacora` |
| 10 | **Ticket de soporte** | Como cualquier usuario, abrir un ticket en la pantalla de soporte; como admin, responderlo (desde MATI Admin) | Se abre, se responde, el usuario ve la respuesta |
| 11 | **Permitido y rechazado por rol** | Ver la tabla B: hacer la acción permitida y la rechazada con cada rol | Coincide con la tabla |
| 12 | **Cierre de lo que se cierra** | Con las herramientas del navegador (o `curl`) y la llave pública: `POST /rest/v1/<tabla>` sin sesión; `GET /rest/v1/v_clientes_credito` sin sesión; `POST /rest/v1/rpc/set_updated_at` con sesión | Las tres fallan (`401`/`403`/`42501`); **no** hay `5xx` |

**Contraseñas filtradas** (aparte, ver `CONTRASENAS-FILTRADAS.md`): prueba de inicio de sesión y de alta de usuario con la protección activada.

## B. Matriz permitido / rechazado por rol (resultado automático)

Corrida con `ensayo/probar-recorridos.py` sobre la réplica con los datos sintéticos de `ensayo/datos-sinteticos.sql` (una fila en las tablas principales; 8 usuarios sintéticos `…@ejemplo.test`). Cada acción corre en su propia subtransacción que se deshace. Lectura de la celda: **✓ n** = se ejecutó (n = filas o resultado); **✗ código** = la base la rechazó (`42501` sin permiso o por seguridad por filas, `P0001` bloqueo de un trigger de protección, `23514` candado). **«A → B»** = cambió con la Fase 1.

| Acción (nivel base de datos) | Admin de área (Comercial) | Almacén | Compras | Finanzas | Logística (supervisor) | Operador (Fábrica) | Super admin | Ventas |
|---|---|---|---|---|---|---|---|---|
| asignarse el rol admin | ✗ P0001 | ✗ P0001 | ✗ P0001 | ✗ P0001 | ✗ P0001 | ✗ P0001 | ✗ P0001 | ✗ P0001 |
| cambiar el correo de otra persona | ✓ 1 | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 1 | ✓ 0 |
| cambiar el correo del SUPER ADMIN | ✓ 1 | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 0 |
| desactivarse a sí mismo | ✗ P0001 | ✗ P0001 | ✗ P0001 | ✗ P0001 | ✗ P0001 | ✗ P0001 | ✓ 1 | ✗ P0001 |
| editar el nombre de OTRA ÁREA (finanzas) | ✓ 1 | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 1 | ✓ 0 |
| editar el nombre de otra persona | ✓ 1 | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 1 | ✓ 0 |
| editar el nombre del SUPER ADMIN | ✓ 1 | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 0 |
| editar su nombre (dispara triggers) | ✓ 1 | ✓ 1 | ✓ 1 | ✓ 1 | ✓ 1 | ✓ 1 | ✓ 1 | ✓ 1 |
| leer clientes | ✓ 1 | ✓ 1 | ✓ 1 | ✓ 1 | ✓ 1 | ✓ 1 | ✓ 1 | ✓ 0 |
| leer movimientos financieros | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 1 | ✓ 0 | ✓ 0 | ✓ 1 | ✓ 0 |
| leer refacciones | ✓ 1 | ✓ 1 | ✓ 1 | ✓ 1 | ✓ 1 | ✓ 0 | ✓ 1 | ✓ 1 |
| leer remisiones | ✓ 1 | ✓ 1 | ✓ 0 | ✓ 1 | ✓ 1 | ✓ 1 | ✓ 1 | ✓ 0 |
| leer su propio rol | ✓ 1 | ✓ 1 | ✓ 1 | ✓ 1 | ✓ 1 | ✓ 1 | ✓ 1 | ✓ 1 |
| leer vista de cobranza | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 0 |
| preguntar si es super admin (RPC) | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 1 | ✓ 0 |
| quitarle el rol al SUPER ADMIN | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 0 |
| registrar su conexión (RPC) | ✓ 1 | ✓ 1 | ✓ 1 | ✓ 1 | ✓ 1 | ✓ 1 | ✓ 1 | ✓ 1 |
| subirse a administrador | ✗ P0001 | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 0 | ✓ 1 | ✓ 0 |
| vaciar la bitácora de eventos | ✓ 0 → **✗ 42501** | ✓ 0 → **✗ 42501** | ✓ 0 → **✗ 42501** | ✓ 0 → **✗ 42501** | ✓ 0 → **✗ 42501** | ✓ 0 → **✗ 42501** | ✓ 0 → **✗ 42501** | ✓ 0 → **✗ 42501** |
| ver la tabla de super admins | ✗ 42501 | ✗ 42501 | ✗ 42501 | ✗ 42501 | ✗ 42501 | ✗ 42501 | ✗ 42501 | ✗ 42501 |

**Cómo leerla (lo que ya dice sobre seguridad):**
- Nadie puede **asignarse un rol** ni **desactivarse** (salvo el super admin): bloquea `impedir_escalada_rol` / `proteger_profile_activo` (`P0001`).
- Solo `super_admin` y `finanzas` ven `movimientos_financieros`; nadie puede leer `super_admins` (`42501`).
- **Hallazgo confirmado, fuera de la Fase 1:** el **admin de área (Comercial)** puede cambiar el **nombre y el correo del perfil de otra área y del super admin** (`✓ 1`). Los triggers protegen `activo`, el rol y la baja del administrador global, pero el trigger de `profiles` y la política `profiles_update_admin` tratan como «admin» a cualquier usuario con nivel admin **de cualquier área**. Ver `HALLAZGOS-PENDIENTES.md`.
- La única fila que cambia con la Fase 1 es **«vaciar la bitácora de eventos»** (`TRUNCATE`): hoy **cualquier rol con sesión puede** (en la réplica se deshace); después, `42501` para todos.

## C. Pruebas genéricas

Sobre las 93 tablas, 18 vistas y 53 funciones de trigger. Formato: resultados por código de error y cuántos objetos dieron cada uno.

| Prueba | Antes | Después |
|---|---|---|
| anon: DELETE sin filtro por tabla | {"err 42501": 17, "ok (0 filas)": 76} | **{"err 42501": 93}** |
| anon: INSERT por tabla | {"err 23502": 1, "err 42501": 90, "err P0001": 2} | **{"err 42501": 93}** |
| anon: TRUNCATE por tabla | {"err 0A000": 31, "err 42501": 11, "ok": 51} | **{"err 42501": 93}** |
| anon: leer vistas (18 vistas) | {"err 42501": 7, "ok": 11} | **{"err 42501": 18}** |
| anon: llamar funciones de trigger por RPC | {"err 0A000": 2, "err 42501": 51} | **{"err 42501": 53}** |
| authenticated: TRUNCATE por tabla (93 tablas) | {"err 0A000": 31, "err 42501": 11, "ok": 51} | **{"err 42501": 93}** |
| authenticated: leer vistas | {"ok": 18} | **{"ok": 18}** |
| authenticated: llamar funciones de trigger por RPC (53) | {"err 0A000": 47, "err 42501": 6} | **{"err 42501": 53}** |

- **`0A000` en «antes»:** `TRUNCATE` lo frena una llave foránea («no se puede truncar una tabla referenciada»), no un permiso; o «las funciones de trigger solo se llaman como trigger». Es una protección accidental, no de seguridad.
- **Alta de usuario** (rol de Auth + triggers de `auth.users`): antes `{"alta autorizada": "ok 1", "alta sin autorización": "err 23514", "perfil creado por handle_new_user": "ok 1"}`; después `{"alta autorizada": "ok 1", "alta sin autorización": "err 23514", "perfil creado por handle_new_user": "ok 1"}`. **Idéntico.**

## D. Cómo repetirlo

```
# réplica nueva con el esquema de producción (solo estructura) y ensayo completo
PGHOST=/var/run/postgresql PGUSER=root PGOPTIONS='-c role=postgres' \
  python3 docs/seguridad/ensayo/construir-replica-fiel.py kit_prod_like <definiciones.json>
PGHOST=/var/run/postgresql PGUSER=root PGOPTIONS='-c role=postgres' \
  python3 docs/seguridad/ensayo/ensayar-fase-1.py kit_prod_like salida.json
# solo los recorridos por rol
PGHOST=/var/run/postgresql PGUSER=root python3 docs/seguridad/ensayo/probar-recorridos.py kit_prod_like salida.json
```
`<definiciones.json>` se obtiene con `consultas/04-extraer-definiciones-faltantes.sql` (solo lectura).

## E. Verificación en producción después de cada migración (solo lectura)

1. `consultas/02-conteos-linea-base.sql` y comparar con la columna «después» de `LINEA-BASE-2026-10-25.md`.
2. Preguntar a la propia base: `SELECT has_table_privilege('anon','public.clientes','INSERT')` → `false` tras el punto 5; `has_function_privilege('authenticated','public.set_updated_at()','EXECUTE')` → `false` tras el punto 2.
3. Asesor de seguridad: `function_search_path_mutable` y `anon_security_definer_function_executable` en 0 tras los puntos 3 y 2.
4. Registros de la API (`edge_logs`) y de la compuerta: ningún `5xx` ni `42501` nuevos en rutas que no estaban en la línea base (la sección 4 de la línea base es la referencia).

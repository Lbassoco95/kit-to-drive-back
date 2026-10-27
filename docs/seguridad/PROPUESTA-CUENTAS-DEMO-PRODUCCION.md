# Cuatro cuentas demo en producción: propuesta para revisar (26 oct 2026)

**Nada se ha ejecutado.** Sobre producción solo se verificó el proyecto (`get_project_url` → `dmhzhyeivvuliumcgsmm`, producción) y se leyeron conteos. No se inició sesión en ninguna cuenta ni se probó ninguna contraseña. Se espera la frase: «Autorizo crear cuentas demo en producción, ventana del 2026-10-26».

## 1. Tres cosas que no se pueden cumplir tal cual (hay que decidir)

1. **«El mismo método que la pantalla de Usuarios» + «sin correo» + «contraseña solo en tu terminal» chocan.** La pantalla llama a la función `admin-create-user`, que (a) exige la sesión de un administrador, (b) **genera la contraseña en el servidor y la manda por correo, y si el correo no sale no crea nada**, y (c) no devuelve la contraseña. Con direcciones sin buzón esa función no sirve. El script hace **los mismos cinco pasos, en el mismo orden y con las mismas tablas** que la función (rastro en `bridge_bitacora` → `altas_autorizadas` → Auth con correo confirmado → `profiles` → `user_roles`), pero **desde tu terminal con la llave de servicio, sin enviar correo, y con la contraseña generada ahí**. Es la única forma que respeta tus reglas de contraseña; **el SQL directo a `auth.users` no es opción** porque la contraseña tendría que pasar por mí.
2. **Los perfiles que dices no existen tal cual.** El sistema tiene 3 niveles (operador, supervisor, admin) en 6 áreas; no hay perfil «Lectura» de solo lectura. **Propuesta** (la decides tú):

| Correo | Perfil propuesto | Por qué / alternativa |
|---|---|---|
| `demo.vendedor@demo.kawiil.mx` | Comercial · operador, marcado vendedor | Es el vendedor. |
| `demo.operador@demo.kawiil.mx` | Fábrica · operador | «Operador» existe en todas las áreas; Fábrica es la más típica. Alternativa: Almacén y logística · operador. |
| `demo.direccion@demo.kawiil.mx` | **Dirección · supervisor** | **No propongo Dirección · admin:** es el administrador global y con una contraseña compartida en producción es el riesgo mayor. Supervisor ve todo y no administra usuarios. Si necesitas probar al admin global, dímelo. |
| `demo.lectura@demo.kawiil.mx` | Dirección · operador | Lo más cercano a «lectura»: ve de forma amplia, **pero no es solo lectura** (hallazgo R6 de la matriz: puede crear clientes y remisiones). |

3. **Cómo marcarlas como demo.** El sistema **sí** tiene su mecanismo: la tabla `inventario_usuarios_prueba` (modo prueba). Pero (a) su restricción exige correos `prueba.%@…`, y los tuyos son `demo.%`; (b) el modo prueba hace que la cuenta **solo vea y toque datos de prueba**, nunca los reales.

| Opción | Qué implica |
|---|---|
| **A: mecanismo del sistema** | Cambiar los correos a `prueba.vendedor@demo.kawiil.mx`, etc., y registrarlos en `inventario_usuarios_prueba` (+4 filas, sin columnas ni tablas nuevas). Las cuentas **no ven datos reales**: lo más seguro con una contraseña compartida, pero prueba los perfiles sobre datos de prueba. |
| **B: marca propia (la del script)** | Mantiene tus correos. Marca en `app_metadata` de Auth (`managed_by = cuentas-demo`, `demo = true`, solo la Admin API la escribe) y nombre «DEMO …» en el perfil. Las cuentas **ven datos reales** según su perfil. El script de bloqueo solo actúa sobre cuentas con esa marca. |

Recomiendo **A** si lo que quieres es comprobar que los permisos de M1–M2 y M4 no rompen pantallas; **B** si necesitas verlas sobre datos reales. El script que está en la rama es **B**; si eliges A, lo ajusto antes de que lo corras.

Un detalle más: la función obliga a cambiar la contraseña al primer ingreso. Para cuentas compartidas **propongo no obligarlo** (`must_change_password = false`), porque si la primera persona la cambia, la que imprimí deja de servir. Dime si prefieres lo contrario.

## 2. Archivos (rama `claude/cuentas-demo-produccion`)

| Archivo | Para qué | sha256 (16) |
|---|---|---|
| `supabase/operaciones/cuentas-demo/crear-cuentas-demo.mjs` | Alta de las 4 cuentas. Ensayo por defecto; escribe solo con `--ejecutar` y `CONFIRMO_VENTANA=2026-10-26`. | `3b48bb5cc16ed87b` |
| `…/ensayo-con-servidor-falso.mjs` | Prueba del script contra un servidor falso local: 12 de 12. | `8e5cc3e040ee48fe` |
| `…/bloquear-cuentas-demo.sql` | Bloquea las 4 a la vez (Auth `banned_until = infinity` y perfil inactivo). **No ejecutar.** | `08bf893f3b97560d` |
| `…/bloquear-cuentas-demo_reversa.sql` | Reabre las 4. | `949100f3f7963491` |

**Guardas del script:** solo la URL exacta de producción (rechaza QA y cualquier otra); la llave debe ser `service_role` **de ese proyecto**; si alguno de los 4 correos ya existe, aborta sin tocar nada (nunca toca cuentas existentes); si falla un paso, se detiene y **no borra nada**; la contraseña (24 caracteres, las 4 clases, generada con `crypto.randomInt`) se imprime **una vez** al final, solo en stdout, y no aparece en errores, logs, archivos ni tablas fuera de Auth. **Probado:** el ensayo no escribe; el orden de pasos por cuenta; contraseña una sola vez; sin llamadas de correo o invitación; aborta si el correo ya existe; se detiene al primer error sin borrar.
**Guardas del bloqueo:** exactamente 4 cuentas, las 4 con la marca de demo, ninguna ya bloqueada o inactiva. **Probado en la réplica:** aborta sin marca, bloquea 4, aborta el segundo intento, la reversa reabre las 4 y es idempotente.

## 3. Cómo se correría (cuando apruebes y des la frase)

En **tu terminal** (la llave no se pega en el chat ni en ningún archivo):
```
read -rs SUPABASE_SERVICE_ROLE_KEY; export SUPABASE_SERVICE_ROLE_KEY
export SUPABASE_URL=https://dmhzhyeivvuliumcgsmm.supabase.co
node crear-cuentas-demo.mjs                                           # ensayo: lee y muestra el plan y los conteos
CONFIRMO_VENTANA=2026-10-26 node crear-cuentas-demo.mjs --ejecutar    # crea y muestra la contraseña una vez
```
Antes de eso, yo verifico el proyecto con `get_project_url`, tomo V, A1 y A3 por lectura y los pego. Después, los vuelvo a tomar y comparo. **Esto no pasa por el conector de escritura ni por `apply_migration`**; el bloqueo sí iría por `execute_sql`, un archivo por llamada y con tu aprobación.

## 4. Efecto esperado sobre los conteos (medido ejecutando los mismos pasos en la réplica)

| Objeto | Antes | Después |
|---|---|---|
| `auth.users` | 26 | **30** |
| `profiles` | 26 | **30** |
| `user_roles` | 25 | **29** |
| `bridge_bitacora` (rastro del alta) | 3 | **7** |
| `auth.identities` (la crea Auth; no simulable en la réplica) | 28 | **32** |
| `altas_autorizadas` | 0 | 0 (las filas se consumen o caducan en 3 minutos) |
| Filas totales de `public` | 20,626 | **20,638** |
| `migraciones_aplicadas` | 92 | 92 (no es una migración y no deja registro ahí; el rastro queda en `bridge_bitacora`) |

**Sobre «la misma huella de las 92 tablas»:** no puede ser literal. Crear usuarios cambia **forzosamente** tres tablas de `public`: `profiles`, `user_roles` y `bridge_bitacora`. Lo que sí se verifica es que **las otras 90 tablas** (incluida `migraciones_aplicadas`) tengan la misma huella y los mismos conteos, que `auth.users` solo gane esas 4 filas con las huellas de las 26 existentes intactas, y que storage no cambie. Con la opción A, `inventario_usuarios_prueba` sería la cuarta tabla (7 → 11).

## 5. Lo que te devuelvo al terminar
Solo: los 4 correos con su perfil, el conteo de usuarios antes y después, y la comparación de huellas del resto. Nunca la contraseña.

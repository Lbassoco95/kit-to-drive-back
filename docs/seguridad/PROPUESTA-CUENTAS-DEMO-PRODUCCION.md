# Tres cuentas de prueba en producción (opción A, modo prueba): versión final para revisar (26 oct 2026)

**Nada se ha ejecutado.** Sobre producción solo se verificó el proyecto (`get_project_url` → `dmhzhyeivvuliumcgsmm`) y se leyeron conteos. Se espera la frase: «Autorizo crear cuentas demo en producción, ventana del 2026-10-26». Decisiones de Polo: **opción A** (mecanismo del sistema, correos `prueba.*`) y **sin `demo.lectura`**.

## 1. Cuentas
| Correo | Perfil | Nota |
|---|---|---|
| `prueba.vendedor@demo.kawiil.mx` | Comercial · operador, marcado vendedor | |
| `prueba.operador@demo.kawiil.mx` | Fábrica · operador | Alternativa: Almacén y logística · operador |
| `prueba.direccion@demo.kawiil.mx` | **Dirección · supervisor** | No admin global. Si Polo prefiere admin, es un cambio de una línea; el modo prueba ya aísla datos, pero no cambia lo que el rol puede administrar. |

Las tres se registran en `inventario_usuarios_prueba` (la tabla exige el prefijo `prueba.`) **antes** de crearse en Auth, y llevan además la marca `app_metadata.managed_by = cuentas-demo`. Contraseña: una sola para las tres, 24 caracteres, impresa una vez en la terminal de Polo. `must_change_password = false` (si la primera persona la cambiara, la impresa dejaría de servir).

## 2. Qué cubre el modo prueba (medido en la réplica y por catálogo; no por pantallas)
**Lo que protege (aislamiento):** la cuenta solo ve filas con `es_prueba = true`, y los rastros de lo que cree quedan marcados como prueba. Hay filtro de lectura en **69 de las 93 tablas** y candado de escritura en **79**. Las 18 vistas son `security_invoker`, así que el filtro también las alcanza. **No es solo inventario**: cubre clientes, remisiones (de refacciones y de motocarros), cobranza, compras, CRM, kárdex y los reportes de refacciones.

**Pero «cubre» no es «se puede probar».** Hay tres casos:

| Área | Qué ve y qué puede hacer la cuenta de prueba | Datos de prueba hoy en producción |
|---|---|---|
| **Clientes**, artículos de refacciones, **kárdex** (movimientos), remisiones de refacciones, compras, cobranza | Ve **solo lo de prueba**. Si crea un cliente, el sistema lo marca como prueba solo. Puede escribir sobre lo de prueba; sobre lo real, no ve nada que tocar. | Clientes 1 · artículos 5 · movimientos de kárdex 5 · remisiones de refacciones 1 · compras 0 · pagos de cobranza 0 |
| **Remisiones de motocarros**, motocarros, **cuentas por cobrar** y vista de crédito, **CRM** (oportunidades, rutas, actividades) | **No ve ninguna fila y no puede escribir** (el intento se rechaza con «Estás en MODO PRUEBA…»). Está aislada, pero **no existe dato de prueba** en estas tablas. | No existe mecanismo de datos de prueba para ellas |
| Reportes y kárdex | `reporte_ventas_refacciones` se filtra por las políticas de las tablas; `ventas_mensuales_refacciones` y la rotación filtran por `es_prueba`; `kardex_refaccion` y `kardex_refacciones_multi` piden que el artículo sea de prueba. Ejecutados por la cuenta devolverían solo lo de prueba o nada. | Los 5 artículos y 5 movimientos de prueba |

**Medido:** con una cuenta de prueba simulada, **0 remisiones, 0 motocarros, 0 cuentas por cobrar, 0 filas de CRM, 0 clientes reales** visibles; crear una remisión, una cuenta por cobrar o una oportunidad se rechaza; crear un cliente lo guarda marcado como prueba; solo ve su propio perfil.
**Sin cubrir (24 tablas sin filtro de lectura de prueba):** configuración y catálogos (`config_general`, `compras_parametros`, `inventario_almacenes`, `app_modulos`, `flujo_capacidades`, `flujo_dinero`), `firmas_*`, `soporte_*`, `solicitudes_aprobacion`, bitácoras, `super_admins`. La mayoría tiene su propia política por rol; la cuenta de prueba sigue sujeta a ella.

**Consecuencia para tu objetivo.** Con la opción A, las cuentas sirven para comprobar que **las pantallas cargan sin errores de permisos** con el perfil correcto (funciones, vistas, tablas) tras M1, M2 y M4, sobre datos de prueba. **No sirven para ejercitar los flujos de ventas con remisiones de motocarros, cartera o CRM**, porque esas tablas no admiten datos de prueba. Si necesitas ver esos flujos con datos, hay que usar una cuenta real o definir datos de prueba para esas tablas (otra decisión).

## 3. Archivos (rama `claude/cuentas-demo-produccion`)
| Archivo | Para qué | sha256 (16) |
|---|---|---|
| `supabase/operaciones/cuentas-demo/crear-cuentas-demo.mjs` | Alta. Ensayo por defecto; escribe solo con `--ejecutar` y `CONFIRMO_VENTANA=2026-10-26`. | `30edae089bf283cc` |
| `…/ensayo-con-servidor-falso.mjs` | Prueba contra un servidor falso local: **14 de 14**. | `accffa7287431e88` |
| `…/bloquear-cuentas-demo.sql` | Bloquea las 3 a la vez (`banned_until = infinity` y perfil inactivo). **No ejecutar.** No toca el registro de modo prueba. | `35acef9069d4aee9` |
| `…/bloquear-cuentas-demo_reversa.sql` | Reabre las 3. | `8273a0a53abb5ea3` |

**Guardas del alta:** solo la URL exacta de producción (rechaza QA y cualquier otra); la llave debe ser `service_role` de ese proyecto; los correos deben empezar con `prueba.`; si alguno ya existe en Auth o en `inventario_usuarios_prueba`, aborta sin escribir; si falla un paso, se detiene y no borra nada; la contraseña no sale en errores, archivos ni logs.
**Probado:** 14 de 14 contra el servidor falso (orden de 6 pasos por cuenta, el registro de modo prueba antes de Auth, contraseña una vez y solo en stdout, sin llamadas de correo, aborta si el correo existe, se detiene al primer error). En la réplica: el bloqueo aborta sin marca, bloquea 3, aborta el segundo intento, y la reversa reabre las 3.

## 4. Cómo se correría
En la terminal de Polo (la llave no pasa por el chat ni se guarda en archivos):
```
read -rs SUPABASE_SERVICE_ROLE_KEY; export SUPABASE_SERVICE_ROLE_KEY
export SUPABASE_URL=https://dmhzhyeivvuliumcgsmm.supabase.co
node crear-cuentas-demo.mjs                                           # ensayo: lee y muestra plan y conteos
CONFIRMO_VENTANA=2026-10-26 node crear-cuentas-demo.mjs --ejecutar    # crea y muestra la contraseña una vez
```
Antes y después tomo V, A1 y A3 por lectura y comparo. No pasa por el conector de escritura ni por `apply_migration`; el bloqueo sí iría por `execute_sql`, un archivo por llamada y con aprobación.

## 5. Efecto esperado (medido ejecutando los mismos pasos en la réplica)
| Objeto | Antes | Después |
|---|---|---|
| `auth.users` | 26 | **29** |
| `profiles` | 26 | **29** |
| `user_roles` | 25 | **28** |
| `bridge_bitacora` | 3 | **6** |
| `inventario_usuarios_prueba` | 7 | **10** |
| `auth.identities` (la crea Auth; no simulable) | 28 | **31** |
| `altas_autorizadas` | 0 | 0 |
| Filas totales de `public` | 20,626 | **20,638** |
| `migraciones_aplicadas` | 92 | 92 (no es migración) |

**Huellas:** cambian forzosamente **cuatro** tablas de `public` (`profiles`, `user_roles`, `bridge_bitacora`, `inventario_usuarios_prueba`). Las **otras 89** deben conservar conteo y huella (incluida `migraciones_aplicadas`); `auth.users` solo gana 3 filas con las huellas de las 26 existentes intactas; storage sin cambios. En la réplica, solo esas cuatro cambiaron de huella.

## 6. Qué te devuelvo
Solo: los 3 correos con su perfil, el conteo de usuarios antes y después, y la confirmación de que el resto no cambió. Nunca la contraseña.

# Pendientes de Polo (por dependencia) y guion de cada ventana

**Estado al 26 oct: nada aplicado en producción.** Conector de lectura probado (ver `docs/seguridad/COMO-APLICA-CODE-POR-EL-CONECTOR.md`). Code no usa `apply_migration` ni el conector general de claude.ai.

## Parte 1. Lo que Code necesita de Polo, en orden de dependencia

### Bloque 0 — Una sola vez, antes de la Fase 1

| # | Qué | Opciones y recomendación |
|---|---|---|
| 0.1 | **Desconectar el conector general de claude.ai** (Configuración → Conectores → Supabase) | **A (recomendada): desconectarlo** y dejar solo `supabase-prod-lectura` (+ el de escritura en ventana). B: dejarlo con herramientas de escritura y administración en «Nunca». Razón: ve todos los proyectos, QA incluido, y con él `get_project_url` no protege. |
| 0.2 | Confirmar si los repos `kit-to-drive-back`, `kit-to-drive` y `kit-to-drive-front` son **privados** | Los documentos describen el esquema y los controles. **Recomendación:** privados. |

### Bloque 1 — Para abrir la Fase 1 (martes 27 oct, 19:00–00:00)

| # | Qué | Quién |
|---|---|---|
| 1.1 | Revisar y **mezclar** el PR de la Fase 1 del repo back (Code no hace merge) | Polo |
| 1.2 | **Respaldo** del mismo día o del anterior: fecha y hora, escritas en la sesión | Polo |
| 1.3 | **Persona de pruebas** presente toda la ventana, con **una cuenta por rol** de `HOJA-DE-PRUEBAS-POR-ROL.md` (contraseñas solo con ella, nunca en el chat) | Polo |
| 1.4 | **Aviso a Dazon** (lunes 26 y al empezar) | Polo |
| 1.5 | Persona dueña de la cuenta que aplicó migraciones anteriores | Polo (no bloquea) |
| 1.6 | La frase: «Autorizo Fase 1 en producción, ventana del 2026-10-27» | Polo |
| 1.7 | En la ventana: agregar `supabase-prod-escritura` tras la frase; quitarlo al terminar el último paso | Polo |

### Bloque 2 — Para abrir el Paquete 1 (jueves 29 oct, 19:00–22:00). Depende de que la Fase 1 haya salido limpia (V, A1, A3 y D2 del miércoles 28 y del jueves antes de empezar, sin diferencias inexplicadas)

| # | Qué | Quién |
|---|---|---|
| 2.1 | Mezclar el PR #16 del back (Paquete 1) y el PR #75 del front. **No** mezclar aún el PR #8 de la compuerta | Polo |
| 2.2 | Dos clientes de prueba **sin vendedor** («ZZ PRUEBA P1 sin asignar A» y «B»), creados por un supervisor; se **desactivan** al final, no se borran | Polo / supervisor |
| 2.3 | Cuentas: un **vendedor sin clientes**, **otro vendedor**, un **supervisor** de Comercial, un **administrativo** de Comercial y **Dirección** | Polo + persona de pruebas |
| 2.4 | **D8 = A** ya decidida: Code hace el cambio de texto en el PR #75. **Necesito tu «sí, hazlo»** (no es parte de ninguna ventana; va en el front) | Polo |
| 2.5 | Respaldo del día; aviso a Dazon (miércoles y al empezar) | Polo |
| 2.6 | La frase: «Autorizo paquete 1 (permisos de vendedor) en producción, ventana del 2026-10-29» | Polo |
| 2.7 | **Mezclar el PR #8 de la compuerta** (despliega en producción en Vercel): **después de verificar M1 y M2 y antes de los recorridos** | Polo |
| 2.8 | **Después de la ventana:** Martin devuelve el nivel a los vendedores subidos a supervisor y **asigna clientes** (D6). Hasta entonces el vendedor ve «0 de 0» en Clientes | Martin |

### Bloque 3 — Para abrir la Fase 2 (sábado 31 oct, 10:00–15:00). Depende del Bloque 2 limpio

| # | Qué | Opciones y recomendación |
|---|---|---|
| 3.1 | Mezclar los PR #14 (back) y #74 (front) | Polo |
| 3.2 | **`asignar_super_admin`** (decisión A/B pendiente de la Fase 2) | Los detalles de A y B están en `FASE-2-CAMBIOS-Y-REVERSAS.md`; **recomendación:** la que mantiene el rastro obligatorio sin dar a los admins de área el control de super admins. Dime cuál prefieres antes del jueves. |
| 3.3 | Confirmar quiénes son las cuentas `finanzas`, `lee`, `marco` y `edgar`, y qué hacer con las de `yoltik.mx` que nunca entraron | Polo |
| 3.4 | **Dos super admins activos** (no se modifican) y un **administrador global** con acceso a Usuarios para revertir desde la pantalla; alguien con acceso al panel de Supabase | Polo |
| 3.5 | Aviso a los administradores (uno de ellos en China): los admins de área ya no crean ni modifican administradores | Polo |
| 3.6 | Desplegar las **Edge Functions** (Actions → Run workflow, una a la vez, después de las migraciones) | Polo |
| 3.7 | La frase: «Autorizo Fase 2 en producción, ventana del 2026-10-31» | Polo |

Fuera de esa ventana, aparte y con su propia frase: activar contraseñas filtradas (panel, después de publicar el PR del front), segundo factor con Peter, y las frases de las cuentas demo, `lee` y `marco` (`RUNBOOK-CONSOLIDADO-VENTANAS.md` §0).

### Bloque 4 — Decisiones del Paquete 2 (reportes y buscadores; solo lectura). Depende de la Fase 2 aplicada

| # | Pregunta | A | B | Recomendación |
|---|---|---|---|---|
| 4.1 | ¿«Ventas» es de refacciones o también de unidades? | Solo refacciones | Refacciones y motocarros | **A**: «ítem» y «almacén» apuntan a refacciones; unidades después |
| 4.2 | ¿Qué cuenta como venta? | Fecha de la remisión, sin canceladas ni datos de prueba | Fecha de surtido o entrega | **A**: es la más simple y la que ya ven los reportes de Compras |
| 4.3 | ¿Administrativos y supervisores ven todas las ventas? | Sí | Solo las de su equipo | **A**: ya ven todas las remisiones por RLS |
| 4.4 | ¿El vendedor entra a Kardex y Rotación? | No | Sí | **A**: son de inventario; el vendedor solo tiene ventas y Entregas |

### Bloque 5 — Decisiones del Paquete 3 (crédito, fecha y eliminación). Depende del Paquete 2 y de la Fase 2 (usa la cartera vencida con `SECURITY INVOKER`)

| # | Pregunta | A | B | Recomendación |
|---|---|---|---|---|
| 5.1 (D-A1) | «Modo prueba» para eliminar | Interruptor global nuevo, que Dirección apaga al entrar en operación | Eliminar solo remisiones de prueba | **A**: es lo que describiste |
| 5.2 (D-A2) | Los borrados directos de administradores y de administradores de Comercial | Se cierran: solo el super admin elimina, por la función | Se dejan | **A** |
| 5.3 (D-A3) | «Factura» que bloquea eliminar | `movimientos_financieros` (`factura_url`, `tiene_factura`) | Otro dato | **A**, si confirmas que es ese |
| 5.4 (D-B1) | Fecha de una remisión de refacciones ya surtida | **Prohibir** editarla | Corregir también el movimiento del kárdex (cambia saldos históricos) | **A**: no toca el histórico |
| 5.5 (D-B2) | Vencimiento al cambiar la fecha | Solo **avisar** a finanzas | Mover el vencimiento de la cuenta por cobrar | **A**: mover el vencimiento afecta cartera |
| 5.6 (D-B3) | Alcance de la fecha editable | Las dos remisiones | Solo una | **A** |
| 5.7 (D-C1) | Crédito | Cabe = límite − saldo abierto; se bloquea con cartera vencida; vencimiento = fecha + días de crédito (tope 60); aplica también a refacciones | Variantes por tipo de remisión | **A**; confírmalo línea por línea |

## Parte 2. Guion de cada ventana

**Reglas comunes (aplican a todas):** nada sin la frase con fecha; la ventana permitida es después de las 19:00 entre semana o fines de semana. Cada paso lo hace Code por `execute_sql` en el conector de escritura (nunca `apply_migration`), **un archivo por llamada**, dentro de `begin; … commit;`, con el registro en `migraciones_aplicadas` en la misma llamada. Antes de **cada** escritura: `get_project_url` (debe decir `dmhzhyeivvuliumcgsmm`; si dice `qszllskpizvpnzcytqpj`, detenerse) y bloque 0 (`zz_lista_oct = 2219`, `super_admins = 2`). Code dice qué herramienta va a usar y pega la huella `sha256` del archivo. Tú apruebas cada llamada. Después de cada paso, Code pega V, A1 y A3 y espera tu «sigue». Se detiene y revierte si V no coincide, si un recorrido que pasaba falla, si suben los 401/403/5xx (D2) o si algo no se comporta como una sola transacción. Al terminar el último paso: D2 final, bloques finales, y tú quitas el conector de escritura.

### Ventana Fase 1 — martes 27 oct, 19:00 a 00:00

Orden: M1, M2, M4, M5, M6 y, **al final y solo**, M3 (solo si empieza a más tardar a las 22:15). Detalle y SQL completo: `docs/seguridad/RUNBOOK-FINAL-FASE-1.md`.

| Hora | Qué |
|---|---|
| 19:00–19:30 | Frase, conector de escritura, bloque 0, V/A1/A3/D2 «antes» |
| 19:30–20:05 | Paso 1 (M1) |
| 20:05–20:40 | Paso 2 (M2) — incluye alta de usuario |
| 20:40–21:10 | Paso 3 (M4) |
| 21:10–21:40 | Paso 4 (M5) |
| 21:40–21:55 | Paso 5 (M6) |
| 21:55–22:35 | Paso 6 (M3), solo si cabe |
| 22:35–23:20 | Cierre: V/A1/A3/D2 finales |
| 23:20–00:00 | Colchón |

**Valores esperados del bloque V** (`F` = `filas_totales` de esa tarde; `registros_migraciones` y `filas_totales` suben de uno en uno):

| Momento | `tablas_anon_escribe` | `truncate_authenticated` | `con_trigger` | `vistas_anon_lee` | `funciones_anon` | `secdef_authenticated` | `sin_search_path` | `politicas` | `registros_migraciones` |
|---|---|---|---|---|---|---|---|---|---|
| Antes | 81 | 82 | 103 | 16 | 2 | 208 | 14 | 301 | 90 |
| Tras M1 | 81 | 0 | 0 | 16 | 2 | 208 | 14 | 301 | 91 |
| Tras M2 | 81 | 0 | 0 | 16 | 0 | 178 | 14 | 301 | 92 |
| Tras M4 | 81 | 0 | 0 | 0 | 0 | 178 | 14 | 301 | 93 |
| Tras M5 | 0 | 0 | 0 | 0 | 0 | 178 | 14 | 301 | 94 |
| Tras M6 | 0 | 0 | 0 | 0 | 0 | 178 | 14 | 301 | 95 |
| Tras M3 | 0 | 0 | 0 | 0 | 0 | 178 | 0 | 301 | 96 |

**Recorridos:** persona de pruebas por rol (`HOJA-DE-PRUEBAS-POR-ROL.md`); obligatorios el 1 y el 6; el alta de usuario tras M2. **Detener y revertir** (orden inverso M3, M6, M5, M4, M2, M1): falla un recorrido, un usuario pierde algo, suben los errores de D2 o V no coincide. **Cierre:** `RUNBOOK-FINAL-FASE-1.md` §7. Observación hasta el Paquete 1.

### Ventana Paquete 1 — jueves 29 oct, 19:00 a 22:00

Detalle y recorridos R1–R11: `docs/mejoras/VENTANA-PAQUETE-1.md`. Orden: **M1 → verificar → M2 → verificar → mezclar PR #8 de la compuerta (esperar «Ready» en Vercel) → R1–R8 → M3 → verificar → R9–R11**.

| Momento | `funciones` | `secdef_authenticated` | `triggers` | `politicas` | `registros_migraciones` |
|---|---|---|---|---|---|
| Antes | 268 | 178 | T0 | 301 | 96 |
| Tras M1 | 269 | 179 | T0 | 301 | 97 |
| Tras M2 | 272 | 179 | T0+2 | 301 | 98 |
| Tras M3 | 272 | 179 | T0+2 | 301 | 99 |

Con M1: `catalogo_definer_con_search_path` = 1, `catalogo_authenticated_ejecuta` = true, `catalogo_anon_ejecuta` = false. Con M2: `funciones_alta_cliente` = 3, `triggers_alta_cliente` = 2, `alta_cliente_ejecutables` = 0 y `clientes_sin_vendedor` sin cambio. Con M3: `refacciones_con_administrativo` y `refacciones_sin_comercial` = true. El bloque V de la Fase 1 cambia `secdef_authenticated` a 179 desde M1 (esperado). **Detener y revertir** (M3, M2, M1) si falla R5, R8, R10 o R11, si suben los errores de D2, o si el bloque P1V no coincide. A las 21:30 un paso a medias se revierte.

### Ventana Fase 2 — sábado 31 oct, 10:00 a 15:00

Detalle: `docs/seguridad/RUNBOOK-VENTANA-FASE-2.md`. Antes de empezar: huellas de producción iguales a la línea base, V/A1/A3 y D2 sin diferencias, recorridos U1–U14 «antes». Orden de migraciones (una por llamada): `…07000001` perfiles, `…02` roles y super admins, `…03` política de `profiles`, `…04` cartera vencida, `…05` rastro (opcional); luego las Edge Functions (`admin-update-user`, `admin-create-user`, `admin-reset-user-password`, por Actions).

| Momento (con el Paquete 1 ya aplicado) | `funciones` | `secdef_authenticated` | `politicas` |
|---|---|---|---|
| Antes de la Fase 2 | 272 | 179 | 301 |
| Tras la 1.ª | 273 | 179 | 301 |
| Tras la 2.ª | 273 | 179 | 301 |
| Tras la 3.ª | 273 | 179 | 300 |
| Tras la 4.ª | 273 | 177 | 300 |
| Tras la 5.ª | 274 | 177 | 300 |

**Recorridos:** U1, U2, U9, U10 tras la 1.ª; U3–U8 tras la 2.ª; U12 y U13 tras la 4.ª; Edge Functions: U1/U3/U4/U5/U7/U8/U14, U6/U10 y U11. **Rastro obligatorio:** tras la primera edición debe aparecer `usuario.editar` en `bridge_bitacora`; si no aparece o hay 503, detener y revertir. **Detener y revertir** si falla un recorrido, un usuario legítimo pierde una acción, suben los errores o el rastro no aparece.

### Paquete 2 y Paquete 3

**No tienen guion ejecutable todavía.** El Paquete 2 (solo lectura) y el Paquete 3 (crédito, fecha y eliminación) están solo en diseño (`PAQUETE-2-…md`, `PAQUETE-3-…md`) y esperan las decisiones de los Bloques 4 y 5. Con ellas, Code escribe las migraciones con su reversa, las ensaya en la réplica (con Fase 1, Paquete 1 y Fase 2 ya aplicados) y entrega su guion con el mismo formato. Van en ventanas propias, **en este orden: Paquete 2 después de la Fase 2, Paquete 3 al final**, cada una con su frase con fecha.

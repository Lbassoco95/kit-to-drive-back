# Paquete 1 — Permisos del vendedor

**Estado: preparado, NADA APLICADO.** Va en su propia ventana (propuesta: martes 3 de noviembre de 2026, después de las 19:00 CDMX), solo si la Fase 1 salió limpia, y **antes** de la Fase 2. Frase de autorización (la escribe Polo, con fecha): «Autorizo paquete 1 (permisos de vendedor) en producción, ventana del `<fecha>`». Diagnóstico: `DIAGNOSTICO-VENDEDOR.md`. Guion de la ventana: `VENTANA-PAQUETE-1.md`. Matriz rol por pantalla: `MATRIZ-ROL-POR-PANTALLA.md`.

**No se resuelve subiendo de rol a nadie.** El parche actual (poner al vendedor como supervisor) le da `ve_todo_comercial` y ve todo el equipo; este paquete lo hace innecesario.

## 1. Criterio de Polo → qué cambia

| # | Criterio | Cambio | Migración |
|---|---|---|---|
| 1 | El vendedor ve y trabaja con sus clientes y con los **sin vendedor asignado**; nunca los asignados a otro | `leer clientes`: se agrega `vendedor_id IS NULL` a la cláusula del vendedor. Todo lo demás de la política, idéntico | `20261103000001` |
| 2 | Un vendedor crea un cliente y queda asignado a él | Trigger `trg_clientes_asignar_vendedor` (BEFORE INSERT): si quien crea es **vendedor** (operador de Comercial, activo, no administrativo), `vendedor_id := él`, aunque la captura diga otra cosa o venga vacío | `20261103000002` |
| 3 | Crea oportunidad, ruta y actividad con cualquier cliente que **pueda ver**; si usa uno sin asignar, **queda a su nombre** | Trigger `trg_crm_a_validar_cliente` (INVOKER, aplica la política de clientes): rechaza un cliente que no ve. Trigger `trg_crm_b_asignar_cliente` (DEFINER): si el vendedor usa un cliente sin vendedor, lo asigna a él y lo anota en `clientes_bitacora`. En oportunidades, actividades y paradas de ruta | `20261103000002` |
| 4 | Un vendedor ve **únicamente** las remisiones donde él es el vendedor, de motocarros y de refacciones | Motocarros: ya se cumplía. Refacciones: `puede_leer_remision_refaccion()` ya no incluye «comercial» en su lista final | `20261103000003` |
| 5 | Dirección, supervisores y administrativos conservan lo que ven | Supervisores: `rol_comercial` (ya estaba). Administrativos: `es_administrativo_comercial` (se agrega explícito). Dirección, Administración y Almacén/Logística: siguen en la lista | `20261103000003` |
| 6 | Si las migraciones `20261007000001–3` plasmaron otra regla de negocio, no cambiarla y reportarla | **Se reporta, ver D1** | — |
| 7 | Matriz rol por pantalla con pruebas | `MATRIZ-ROL-POR-PANTALLA.md` | — |

Cada migración tiene su reversa en `supabase/reversas/` y su registro en `supabase/diagnostico_esquema.sql`. Versiones únicas, **anteriores a `20261107…`** (Fase 2).

## 2. Objetos nuevos (todos nacen cerrados; ninguno es RPC)

- Funciones: `es_vendedor_comercial(uuid)`, `clientes_asignar_vendedor_al_crear()`, `crm_validar_cliente_visible()`, `crm_asignar_cliente_al_usar()`. Cada una: `SET search_path = public` y `REVOKE ALL … FROM PUBLIC, anon, authenticated` (no necesitan EXECUTE: PostgreSQL no lo revisa al disparar un trigger).
- Triggers: 1 en `clientes` y 3 + 3 en `crm_oportunidades`, `crm_actividades` y `crm_ruta_paradas` (7 en total).
- **Ninguna tabla ni vista nueva.** **Lista blanca de la compuerta (`kit-to-drive-front`): sin cambio** — la compuerta solo abre tablas, vistas y funciones que el front llama; los 4 objetos nuevos son triggers y un auxiliar que solo llaman ellos. Sigue en 71 tablas y vistas y 85 funciones.
- Front (`kit-to-drive`): **solo** `src/test/contrato-back.json` (copia del contrato con el back, +4 nombres). Ninguna pantalla cambia: la lista de clientes, el selector de oportunidades y las remisiones leen por RLS y se corrigen solas.

## 3. Pruebas (réplica local de PostgreSQL 16, datos sintéticos)

`docs/mejoras/ensayo/ensayar-paquete-1.py` (resultados en `resultado-paquete-1-con-fase1.json` y `…-sin-fase1.json`): 9 roles sintéticos (vendedor, otro vendedor, supervisor, administrativo, Dirección, Finanzas, Almacén, Compras, Fábrica), 3 clientes (de cada vendedor y sin asignar) más 2 sin asignar, remisiones, remisiones de refacciones, cartera y CRM de cada vendedor. Se mide **antes**, se aplican las tres migraciones, se mide **después**, se prueban los casos de escritura, se aplica cada reversa y se reaplica.

| Comprobación | Con Fase 1 aplicada | Sin Fase 1 |
|---|---|---|
| Las 3 migraciones se aplican en una transacción | sí | sí |
| Reaplicarlas deja el catálogo idéntico (idempotente) | sí | sí |
| Las reversas, en orden inverso, restauran **exactamente** lo que ve cada rol y el catálogo completo (políticas, funciones con su definición y permisos, triggers) | sí | sí |
| Funciones / SECDEF ejecutables por `authenticated` / políticas | 268 → 272 / 178 → 178 / 301 → 301 | 268 → 272 / 208 → 208 / 301 → 301 |
| Triggers en `public` (de la réplica) | 243 → 250 (+7) | 243 → 250 (+7) |

**Lo que ve cada rol cambia solo así** (todo lo demás es idéntico antes y después): el vendedor ve además el cliente sin asignar y su cartera; deja de ver las remisiones de refacciones del otro vendedor. Detalle en la matriz.

**Escritura, antes → después** (vendedor = operador de Comercial):

| Caso | Antes | Después |
|---|---|---|
| Vendedor crea cliente sin indicar vendedor | queda **sin vendedor** (y él ya no lo ve) | queda **a su nombre** |
| Vendedor crea cliente a nombre de otro vendedor | se permite | queda a su nombre |
| Vendedor crea oportunidad, actividad o ruta+parada con un cliente **sin asignar** | el cliente sigue sin asignar | **queda a su nombre** |
| Vendedor lo hace con un cliente de **otro** vendedor | se permite | **se rechaza** («No puedes usar ese cliente: no está entre los que ves») |
| Vendedor cambia su oportunidad a un cliente ajeno | se permite | se rechaza |
| Supervisor o administrativo usa un cliente sin asignar | no cambia | **no cambia** (no se auto-asigna) |
| Tras usarlo el vendedor 1, el vendedor 2 ve ese cliente | no | no |

Pruebas del repo: `tests/paquete-1.test.ts` (7), junto con las existentes (todas pasan). Cada migración nueva figura en `supabase/diagnostico_esquema.sql` (probado: `FALTA` antes de aplicarla, `APLICADO` después).

## 4. Decisiones y avisos para Polo

- **D1 — Regla de «clientes de mis remisiones» (criterio 6).** `20261007000002` plasmó que el vendedor ve «los que tiene asignados **+ los de sus propias remisiones**». Eso contradice, en un caso, «nunca ve los clientes asignados a otro vendedor»: un cliente reasignado a otro vendedor sigue visible para quien le hizo una remisión. **No lo cambié**: la cláusula se conserva tal cual. Si quieres que el criterio 1 sea estricto, se quita esa cláusula en una migración aparte (con su reversa) y cambia lo que ve cada vendedor de sus clientes ya reasignados.
- **D2 — Cartera y crédito de los clientes sin asignar.** Comentarios, bitácora, documentos del cliente, `cuentas_por_cobrar`, `cxc_abonos` y `v_clientes_credito` siguen a la política de clientes. Con este paquete, **todos los vendedores verán el crédito, el saldo y los documentos de los clientes sin asignar**. Es consecuencia directa del criterio 1; confírmalo.
- **D3 — Refacciones: ¿era una regla o un efecto?** `20261020000002` dice «las remisiones de refacciones ya las ve toda el área comercial» (como un hecho). El criterio 4 pide lo contrario, y se implementó; confirma que nadie de Comercial que **no** sea vendedor dueño, supervisor, administrativo, Dirección ni Almacén necesita verlas.
- **D4 — CRM a nombre de otro.** Las políticas `crm_*_insert_area` (sin migración en el repo) dejan a cualquiera de Comercial insertar con el `vendedor_id` de otro. **No lo cerré** porque no estaba en tus criterios; solo se exige que el cliente sea visible. Si quieres que el vendedor solo capture CRM a su nombre, se agrega una comprobación al trigger.
- **D5 — Efecto en cobranza de refacciones.** `solicitar_saldo_favor()` y las políticas de cobranza de refacciones usan `puede_leer_remision_refaccion`: un vendedor solo podrá operar sobre **sus** remisiones de refacciones.
- **D6 — El parche actual.** Los vendedores que hoy están como supervisor siguen viendo todo hasta que se les devuelva su nivel (es un cambio de datos en Usuarios, no de código). El bloque 3 del diagnóstico los cuenta.
- **D7 — Hallazgo aparte.** Las tablas de CRM de producción tienen columnas y políticas sin migración en el repo (`DIAGNOSTICO-VENDEDOR.md` §5). Para que el ensayo use la forma real, el script las alinea con `crm-columnas-produccion.json`.

## 5. Choques con la Fase 2 (PR #14) y orden

Ver `ORDEN-Y-CHOQUES.md`. **No toca nada de lo que cambia la Fase 2** (profiles, user_roles, super_admins, `impedir_escalada_rol`, las funciones de cuentas por cobrar): lo comprueba `tests/paquete-1.test.ts`. El ensayo de la Fase 2 se **rehízo con este paquete aplicado**: todo se aplica y se revierte exacto; solo cambian los totales de funciones (+4). **El paquete 1 puede ir antes de la Fase 2.**

## 6. Plan de ventana

`VENTANA-PAQUETE-1.md`: duración estimada 2 h 15 min, orden M1 → M2 → M3, SQL de verificación con valores esperados, reversas y criterios de detención.

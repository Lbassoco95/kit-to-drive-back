# Paquete 3 — Crédito, fecha de remisión y eliminar remisión

**Estado: ANÁLISIS Y DISEÑO. No se escribió código ni migraciones todavía.** Va **al final** (después de la Fase 2 y del Paquete 2): usa `cliente_tiene_cxc_vencidas` y `cxc_vencidas_resumen`, que la Fase 2 pasa a `SECURITY INVOKER`. Frase: «Autorizo paquete 3 (crédito, fecha y eliminación de remisiones) en producción, ventana del `<fecha>`». **Hay decisiones de Polo que bloquean partes (§6); donde hay conflicto se reporta y se espera, como pediste.**

## Reglas que se respetarán

- Si el paquete vuelve a crear `cliente_tiene_cxc_vencidas` o `cxc_vencidas_resumen`, **no** puede ponerles `SECURITY DEFINER` (desharía la Fase 2). Un test del repo lo comprobará.
- Se prueba contra la réplica con Fase 1 + Fase 2 aplicadas. Con INVOKER **un vendedor ve la cartera de los clientes que ve** (los suyos y, con el Paquete 1, los sin asignar): se contempla en las pruebas.
- Todo objeto nuevo trae sus permisos y su RLS; alta en la compuerta; versiones posteriores a las del Paquete 2.

## A. Eliminar una remisión

**Hallazgo: ya existe un borrado duro desde la pantalla, y deja filas huérfanas.** `Remisiones.tsx` hace, desde el navegador y **en dos pasos no atómicos**, un `INSERT` en `bitacora_eliminaciones` y luego `DELETE FROM remisiones`. Pueden borrar los usuarios con rol heredado `admin` y los administradores del área Comercial (`borrar remisiones admin`, `admin de area borra remisiones`). Las llaves foráneas dejan: `motocarros.remision_id` → `SET NULL` (la unidad queda libre pero **no se restablece su estado de entrega**), `cuentas_por_cobrar.remision_id` y `movimientos_financieros.remision_id` → `SET NULL` (**filas huérfanas de dinero**), `remision_items`, `remisiones_bitacora` y `avisos` → `CASCADE` (la bitácora de la remisión se pierde; solo queda la copia que alcanzó a guardarse).

**Diseño:** una función atómica `eliminar_remision(_remision_id, _folio_confirmacion, _motivo)`, `SECURITY DEFINER`, que en **una transacción**:
1. exige **super admin** (`es_super_admin`) y que el folio escrito coincida con el de la remisión;
2. exige que el **modo prueba** esté activo (ver D-A1);
3. **rechaza** si la remisión tiene: pago (`pagado`, `comprobante_pago_url`), cobranza (`cuentas_por_cobrar` o `movimientos_financieros` con `remision_id`; para refacciones, `cobranza_aplicaciones` con `remision_id`), **entrega confirmada** (`motocarros.estatus_entrega = 'ENTREGADA'`, o `remisiones_refacciones.entregada_at`), o **factura** (`movimientos_financieros.tiene_factura`/`factura_url`); esas solo se **cancelan**;
4. guarda en `bitacora_eliminaciones` la copia completa: la remisión, sus partidas, sus unidades y su bitácora (`jsonb`), con quién, cuándo y el motivo (obligatorio);
5. **libera** cada unidad igual que `desasignar_motocarro_de_remision` (`remision_id = NULL`, `estatus_entrega = 'NO_APLICA'`) y devuelve el inventario (refacciones: movimientos inversos con `_mover_inventario_refaccion` o liberación de lo bloqueado);
6. borra la remisión y comprueba que **no quedó ninguna fila que la referencie** (consulta de huérfanos contra todas las llaves foráneas; si hay una, aborta).

La opción desaparece del front cuando el modo prueba se apaga (la función también lo exige: el front es solo comodidad). **Se cierran los `DELETE` directos** de las dos políticas actuales y de la compuerta, para que **solo** exista este camino.

**Pruebas que se escribirán** (réplica con Fase 1+2): super admin elimina una remisión de prueba sin pagos → no queda ninguna fila huérfana y las unidades y el inventario quedan disponibles; con un pago, una cuenta por cobrar, una entrega confirmada o una factura → se rechaza; un admin que no es super admin → se rechaza; folio distinto → se rechaza; con el modo prueba apagado → se rechaza; copia en bitácora completa; el borrado directo con `DELETE` ya no funciona para nadie.

## B. Editar la fecha de la remisión

**Diseño:** tabla nueva `remision_fecha_cambios` (remisión, tipo, fecha original, fecha nueva, quién, cuándo, **motivo obligatorio**) con RLS y permisos explícitos, y una función `cambiar_fecha_remision(_tipo, _id, _fecha_nueva, _motivo)` solo para **Dirección y administrativos de Comercial** (`es_area direccion` o `es_administrativo_comercial`). Cada cambio guarda original/nueva/quién/cuándo/motivo, y la fecha original nunca se pierde.

**Qué depende de `fecha_remision` (leído del repo y del respaldo):**
| Dependiente | Qué pasa al cambiar la fecha | Propuesta |
|---|---|---|
| Vistas de cobranza (`v_cobranza_remisiones`) y la función de remisiones por cliente (`flujo_dinero`) | Ordenan y filtran por `fecha_remision` | Se actualizan solas |
| **Movimientos del kárdex** de refacciones | Al surtir, el movimiento usa la fecha de la remisión como `fecha_efectiva` (visto en los datos de prueba: `_mover_inventario_refaccion(..., r.fecha_remision, 'venta', 'remision', …)`); cambiar la fecha **no** mueve el movimiento ya hecho | **Conflicto: reportar y esperar (D-B1)** |
| Vencimiento del crédito | `cuentas_por_cobrar.fecha_emision` y `fecha_vencimiento` son **independientes** (las captura finanzas, no se derivan de la remisión) | No se tocan; se avisa a finanzas del cambio (D-B2) |
| Folio | Es texto único (`folio_remision`), no se genera con la fecha | Sin efecto |
| Reportes (ventas por periodo, Paquete 2) | Leen `fecha_remision` | Respetan la nueva fecha |

## C. Tipo de pago «crédito»

**Hallazgo:** `tipo_pago` existe en `remisiones` (`'anticipado'`, `'contra_entrega'`, con `CHECK`) y en `remisiones_refacciones` (nulo o los mismos dos). **«Crédito» no existe**: hay que ampliar el `CHECK` en las dos tablas.

**Conexión con cuentas por cobrar (diseño):** una función `SECURITY DEFINER` que, al crear una remisión de crédito, (1) comprueba que el cliente **tiene crédito autorizado** (`clientes.limite_credito > 0` y `dias_credito > 0`, que son los campos que usa `v_clientes_credito`) y que el **monto cabe en el límite disponible** (límite menos saldo abierto de `cuentas_por_cobrar`); (2) **crea su cuenta por cobrar** con `fecha_vencimiento = fecha de la remisión + dias_credito` (tope `config_general.plazo_max_credito_dias` = 60); y (3) rechaza el alta si el cliente tiene cartera vencida (`cliente_tiene_cxc_vencidas`, **versión INVOKER de la Fase 2**).
**Quién ve qué:** un vendedor ve la cartera **de los clientes que ve** (Fase 2 + Paquete 1: los suyos y los sin asignar); finanzas, Dirección y administrativos, la de todos; Compras, la de cobranza que ya lee. **La inserción de la cuenta por cobrar hoy es solo de finanzas** (`cxc_insert: es_finanzas`): por eso la crea la función `DEFINER`, no el vendedor.
**Remisiones existentes:** **no se cambian**. Nada se actualiza retroactivamente; las existentes siguen en anticipado o contra entrega.

## D. Choques con la Fase 2 y con los demás paquetes

- **Fase 2:** depende de ella (cartera vencida INVOKER). No toca profiles, user_roles ni super_admins; **sí** usa `es_super_admin`, que la Fase 2 no cambia.
- **Paquete 1:** el crédito usa la visibilidad de clientes del Paquete 1.
- **Paquete 2:** el reporte de ventas lee `fecha_remision` y `tipo_pago`.
- **Cambia permisos de `DELETE`** de remisiones (cierra los dos actuales): nada de eso lo toca otro paquete.

## 6. Decisiones de Polo que bloquean partes

- **D-A1 — «Modo prueba».** En el sistema, «modo prueba» es por **usuario** (la tabla `inventario_usuarios_prueba`, 7 correos en producción) y marca datos de prueba (`es_prueba`); **no existe un interruptor global**. ¿Quieres (a) un interruptor global nuevo (por ejemplo en `compras_parametros`) que Dirección apaga cuando el sistema entre en operación definitiva, o (b) que la eliminación solo funcione sobre remisiones marcadas como de prueba? Lo primero es lo que describiste; hay que crearlo.
- **D-A2 — Los borrados directos actuales** (administradores y administradores de Comercial) **se cierran**: ¿confirmas que, tras el paquete, solo el super admin puede eliminar y solo por la función?
- **D-A3 — «Factura».** En el esquema solo hay factura en `movimientos_financieros` (`factura_url`, `tiene_factura`): ¿es ese el dato que bloquea la eliminación?
- **D-B1 — Kárdex y fecha.** Cambiar la fecha de una remisión de refacciones ya surtida deja el movimiento del kárdex con la fecha vieja. ¿Se corrige también la fecha del movimiento (cambia saldos históricos del kárdex) o se **prohíbe** editar la fecha de remisiones ya surtidas?
- **D-B2 — Vencimiento.** Las cuentas por cobrar no dependen de la fecha de la remisión. ¿Se avisa a finanzas, o la nueva fecha debe mover el vencimiento de su cuenta por cobrar?
- **D-B3 — Alcance.** ¿La fecha editable es de las dos remisiones (motocarros y refacciones) o solo de una?
- **D-C1 — Crédito.** ¿«Monto cabe en su límite» = límite − saldo abierto de cuentas por cobrar? ¿Se bloquea con cartera vencida? ¿La fecha de vencimiento es fecha de la remisión + días de crédito del cliente (con el tope de 60 días)? ¿Aplica también a refacciones?

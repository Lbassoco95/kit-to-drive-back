# Unificar Control financiero y Flujo de dinero

Criterio de Polo (27 oct 2026): todo movimiento de dinero (ingreso, reembolso, salida) sigue **Recibe → Caja → Aplica**. El libro solo se alimenta cuando **Caja** confirma. No existe otra forma de meter dinero al sistema. Control financiero deja de tener lógica propia y se guía por el flujo.

Estado: **Fase 1 (inventario) y Fase 2 (diseño) hechas; Fase 3 (construcción local) en la rama `claude/unificar-control-flujo`; Fase 4 (despliegue) sin autorización.** Producción solo se leyó.

---

## FASE 1 · Inventario (producción, solo lectura, 27 oct 2026)

### 1.1 Puertas por las que hoy nace o se altera dinero

| # | Puerta | Dónde | Quién puede | Efecto | Veredicto |
|---|---|---|---|---|---|
| 1 | Captura directa de ingreso/egreso | Control financiero → «Nuevo ingreso / Nuevo egreso» (`Finanzas.tsx` → `INSERT movimientos_financieros`) · política `movimientos_insert` | `es_finanzas`: roles admin, admin_financiero, finanzas | Nace en PENDIENTE y luego se confirma | **Cerrar** |
| 2 | Confirmar / editar / cancelar / comprobar / borrar un movimiento | Detalle de movimiento (`FinanzasMovimiento.tsx` → `UPDATE`/`DELETE`) · políticas `movimientos_update_admin`, `movimientos_update_propio`, `movimientos_delete` | admin financiero (todo); rol finanzas (sus propios en BORRADOR/PENDIENTE) | Confirmar mete dinero al libro; borrar lo quita sin rastro de motivo | **Cerrar** (queda cancelar/ajustar con motivo por RPC, solo administrador financiero) |
| 3 | Confirmación de Caja | `flujo_confirmar_caja` (etapa Caja) | quien tenga Caja | Inserta el ingreso/egreso CONFIRMADO | **Única puerta** |
| 4 | Adjuntos del expediente | `ExpedienteAdjuntos.tsx` → `INSERT/DELETE movimiento_adjuntos` | es_finanzas | Documentación, no mueve dinero | Se conserva |
| 5 | Registrar pago de cliente | Cobranza → «Registrar pago» (`registrar_pago_cobranza`) | Compras o Finanzas | Crea `cobranza_pagos` (pendiente o validado); **no toca el libro** | **Cerrar** |
| 6 | Validar y aplicar pagos | `validar_pago_cobranza` (Finanzas) · `aplicar_pago_cobranza` (Compras o admin) | — | Reparte a remisiones y genera saldo a favor | **Cerrar** (lo hace `flujo_aplicar`) |
| 7 | Aplicación del flujo | `flujo_aplicar` | quien tenga Aplica | Crea el pago validado y las aplicaciones | **Única puerta** |
| 8 | Saldos iniciales | `cargar_saldos_iniciales_cobranza` | solo administrador; parámetro `cargador_saldos_habilitado` = falso; sin pantalla | Crea saldos a favor / por cobrar | Se conserva apagado (excepción explícita) |
| 9 | Abono a cuenta por cobrar | Crédito → «Abonar» (`registrarAbono` → `INSERT cxc_abonos`) · política `cxc_abonos_insert` + trigger `aplicar_abono_cxc` | es_finanzas | Baja el saldo de la CxC; **`movimiento_id` queda vacío: el dinero nunca llega al libro** | **Cerrar** (nace solo del flujo) |
| 10 | Alta y edición de cuentas por cobrar | Crédito → `INSERT/UPDATE cuentas_por_cobrar` · políticas `cxc_insert`, `cxc_update` | es_finanzas | Puede reescribir `saldo`/`estatus` a mano; `cxc_abonos_delete` borra un abono sin devolver el saldo | **Cerrar el saldo**; alta de la CxC se conserva (no es dinero) |
| 11 | Saldo inicial de cuentas | `cuentas_financieras` · política `cuentas_write` | administrador financiero | Cambiar `saldo_inicial` cambia el saldo de caja sin movimiento | **Cerrar** (RPC con motivo y bitácora) |
| 12 | Marcar pagada una remisión | `marcar_pago_remision_refaccion` / `_con_evidencia` | Finanzas | Solo una bandera (`pagado`); no registra dinero | Se conserva; **recomendación**: derivarla del saldo cobrado |
| 13 | Remisiones de unidades | `remisiones.pagado`, `tipo_pago`, comprobante | ventas / admin | Bandera y archivo; sin saldo ni aplicación | Fuera del flujo (decisión aparte) |
| 14 | Aplicar saldo a favor | `aplicar_saldo_favor` | quien lo autorice | Paga con dinero ya registrado; no es dinero nuevo | Se conserva |
| 15 | Compuerta (`kit-to-drive-api`) | REST `POST/PATCH/DELETE` abierto sobre `movimientos_financieros`, `cxc_abonos`, `cuentas_por_cobrar`, `cuentas_financieras`; RPC `registrar/validar/aplicar_pago_cobranza` abiertas | cualquier sesión (la base decide) | Es el camino del front a las puertas 1, 2, 5, 6, 9 | **Cerrar** (solo lectura + RPC del flujo) |
| 16 | Datos de prueba | `sembrar/reiniciar_datos_prueba_compras` (authenticated, con confirmación; solo tocan datos de prueba); `_prueba_pago`, `_prueba_aplicar` (solo service_role) | — | Solo prueba | Sin cambio |

Hallazgo: `authenticated` tiene `INSERT/UPDATE/DELETE` a nivel de tabla en todas las de dinero; lo único que las cierra hoy es RLS (que en el libro y en CxC está abierta a finanzas). Las políticas del flujo (`flujo_dinero`) sí están cerradas.

### 1.2 Cómo se relacionan hoy

- **Libro** (`movimientos_financieros`): ingresos/egresos por cuenta; `v_saldos_cuentas` suma solo `CONFIRMADO`. Hoy tiene **1 fila**: un ingreso «DEMO» de 45,000 capturado directo por Martin (27 oct).
- **Cobranza** (`cobranza_pagos`, `cobranza_aplicaciones`, `cobranza_saldos_favor`): cobro de **remisiones de refacciones**. **No tiene vínculo con el libro**: un pago registrado en Cobranza nunca entra a la caja. Hoy: 3 pagos de demostración (1 validado, 2 revertidos) y 3 de prueba del flujo.
- **Crédito** (`cuentas_por_cobrar`, `cxc_abonos`): cartera. `cxc_abonos.movimiento_id` existe pero la pantalla nunca lo llena. Hoy: 2 CxC y 1 abono de demostración.
- **Flujo** (`flujo_dinero`): puente parcial. `movimiento_id` → libro (lo crea Caja) y `cobranza_pago_id` → cobranza (lo crea Aplica) **solo para pagos de cliente a remisiones**. No cubre CxC, no guarda evidencia, y su reversa no existe: revertir en Cobranza deja el flujo en «Aplicado» y el libro intacto.
- Resultado: tres libros que no se hablan y dos formas de meter el mismo dinero.

### 1.3 Qué campos de Control financiero se perderían o cambian

| Campo / función del libro | Hoy | Con la unificación |
|---|---|---|
| Comprobación de efectivo (`requiere_comprobacion`, `comprobado`, monto comprobado/devuelto, padre) | Se captura al crear el egreso y se comprueba después | Se captura en **Recibe** (`datos_libro`) y llega al libro desde Caja; la comprobación sigue en Control financiero por RPC. **Sin pérdida.** |
| Factura (folio, UUID CFDI, RFC, `tiene_factura`) | Campos del formulario + adjunto FACTURA | Viajan en `datos_libro`; el adjunto se sigue subiendo al expediente. **Sin pérdida.** |
| Proveedor / empleado / `contraparte_tipo` | Selector en el formulario | En **Aplica** (reembolso proveedor/empleado, pago a proveedor) y en `datos_libro`. **Sin pérdida.** |
| Intermediario (vía directa o por intermediario, quién del equipo o externo) | Formulario | `datos_libro`. **Sin pérdida.** |
| Categoría, descripción, remisión de unidades (`remision_id`), oportunidad, contenedor | Formulario | `datos_libro` (opcionales). **Sin pérdida.** |
| Autorización (`autorizado_*`) y estado BORRADOR/PENDIENTE | Flujo propio de Control financiero | **Se retira**: la autorización es Caja; no hay borradores. Los campos se conservan en la tabla. |
| Adjuntos (`movimiento_adjuntos`) | Subida manual | Caja crea el adjunto con la **evidencia de Recibe** (VALE_EFECTIVO / COMPROBANTE_PAGO); el expediente sigue aceptando más. |
| Borrar movimiento | Admin financiero | **Se retira** (nada se borra; se cancela con motivo). |
| Todo lo existente | — | Se conserva: la unificación solo agrega columnas y tablas; el movimiento de 45,000 queda marcado `HISTORICO_DIRECTO`. |

---

## FASE 2 · Diseño

### 2.1 Una sola puerta (requisito 1)
- **Libro**: se revoca `INSERT/UPDATE/DELETE` a `authenticated` en `movimientos_financieros`; se eliminan las políticas de escritura. Un candado `BEFORE INSERT` exige que el alta venga de `flujo_confirmar_caja` (o del contra-movimiento de una reversa): ni finanzas, ni administrador, ni el SQL editor sin el interruptor interno pueden insertar.
- **Corrección** (solo administrador financiero, siempre con motivo, por RPC): `movimiento_cancelar` (pasa a CANCELADO; no se borra), `movimiento_ajustar` (solo campos no monetarios: categoría, descripción, factura, contraparte) y `movimiento_comprobar`. Cambiar monto o cuenta no se edita: se cancela y el dinero se vuelve a registrar por el flujo. Quien confirmó en Caja no cancela ese mismo movimiento.
- **Cobranza**: se revoca `EXECUTE` de `registrar_pago_cobranza`, `validar_pago_cobranza`, `aplicar_pago_cobranza`. Cobranza queda para consulta, saldos a favor, recibos y reversas.
- **Crédito**: se revoca `INSERT/UPDATE/DELETE` de `cxc_abonos`; trigger que protege `monto/saldo/estatus` de `cuentas_por_cobrar` (se conserva alta y cancelación).
- **Cuentas**: `saldo_inicial` solo cambia con `cuenta_ajustar_saldo_inicial(motivo)`, con bitácora.
- **Compuerta**: `movimientos_financieros`, `cxc_abonos`, `cuentas_por_cobrar`, `cuentas_financieras`, `movimiento_bitacora` pasan a solo lectura; se retiran las RPC de pagos directos; se abren las nuevas.

### 2.2 El libro solo recibe de Caja; cada movimiento muestra su origen (requisito 2)
Nuevas columnas en `movimientos_financieros`: `origen` (`FLUJO`, `HISTORICO_DIRECTO`, `CONTRA_MOVIMIENTO`) y `flujo_id`. La vista `v_movimientos_financieros` agrega `origen`, `flujo_folio`, `flujo_etapa`. Todo movimiento nuevo muestra **FD-xxxxxx**.

### 2.3 Evidencia obligatoria (requisito 3)
`flujo_dinero` guarda `evidencia_path` y `evidencia_tipo`. `flujo_recibir` exige la evidencia (imagen o PDF del comprobante, o el vale de efectivo) para los tres tipos; sin ella no se registra. Se reutiliza el bucket `evidencias-compras` y la subida que ya usa Cobranza. Al confirmar Caja, la evidencia se vuelve adjunto del movimiento del libro; al aplicar un pago de cliente, se copia al pago de cobranza.

### 2.4 Destinos al aplicar (requisito 4)
Pago de cliente: `REMISION` (como hoy), **`CXC`** (abono a cuenta por cobrar, crédito; se crea el `cxc_abonos` ligado al movimiento del libro y al flujo), **`SALDO_FAVOR`** (todo a saldo a favor) y `OTRO`. El remanente de `REMISION` y de `CXC` queda como saldo a favor. Reembolso: proveedor, empleado, otro. Salida: gasto, pago a proveedor, otro. Un cobro mixto (remisión + crédito) se registra como dos movimientos. Los abonos a CxC solo nacen aquí.

### 2.5 Egresos (requisito 5)
Siguen el flujo con las mismas tres etapas. En Recibe se captura, si aplica, que **requiere comprobación de efectivo** (y vía/intermediario); llega al libro desde Caja y se comprueba después en Control financiero (RPC `movimiento_comprobar`).

### 2.6 Reversa coherente (requisito 6)
Nueva etapa `REVERTIDO` y tabla `flujo_dinero_eventos` (historial inmutable de cada paso: quién, cuándo, de qué etapa a cuál, motivo).
- **Revertir una aplicación** (desde Cobranza): se deshace lo aplicado (aplicaciones revertidas, remanente a saldo a favor cancelado si no se usó, abonos a CxC revertidos y su saldo restaurado, pago de cobranza revertido) y el flujo **regresa a «En caja, por aplicar»**. El libro no cambia (el dinero sigue en caja). Para evitar estados a medias, al revertir una aplicación de un pago que viene del flujo se deshace **toda** la aplicación de ese movimiento.
- **Revertir un pago** (dinero inválido): igual que lo anterior y además el movimiento del libro se **cancela con motivo** y el flujo queda en **REVERTIDO**.
- **Rechazar** (ya existe): pasa a RECHAZADO con motivo; si ya estaba en caja, se cancela su movimiento del libro.
- Nada se borra; todo queda en el historial. **Decisión pendiente de Polo:** si «revertir pago» debe dejar el dinero fuera del libro (propuesto) o también regresar a «En caja».

### 2.7 Separación de funciones (requisito 7)
Por movimiento y por persona: quien recibe no confirma en Caja; quien recibió o confirmó en Caja no aplica **ese** movimiento; quien confirmó en Caja no cancela ese movimiento del libro. Un administrador con las tres etapas puede operar movimientos distintos, nunca dos etapas del mismo. Lo hace cumplir la base (no la pantalla). Las reversas las hacen Compras, Finanzas o el administrador global.

### 2.8 Transición (requisito 8)
- Los movimientos del libro anteriores quedan **`HISTORICO_DIRECTO`** (columna con valor por omisión; sin reescribir filas ni disparar bitácora). Hoy: 1 (el ingreso DEMO).
- Pagos de cobranza directos anteriores (CP-00001 a CP-00003, demostración): se conservan; se marcan `origen = HISTORICO_DIRECTO` (los nuevos del flujo, `FLUJO`). No hay pagos pendientes de aplicar: lo que sobraba ya es saldo a favor. Un pago directo sin flujo **no** se puede aplicar a futuro (la función se cierra); si apareciera uno pendiente, se trata como saldo a favor con autorización de Polo.
- Abonos a CxC anteriores: el de demostración queda `HISTORICO_DIRECTO`.
- Sin pérdida: ninguna tabla ni columna se elimina.

### 2.9 Control financiero guiado por el flujo (requisito adicional)
1. **Estado e historial**: cada movimiento muestra su estado del flujo (Recibido, En caja, Aplicado, Rechazado, Revertido) y su historial: quién recibió, quién confirmó en Caja, quién aplicó y cuándo (`flujo_dinero_eventos`).
2. **Bandeja por etapa**: la entrada de Control financiero abre en **«Mi bandeja»**: lo pendiente de la etapa de cada quien (Recibe: nada pendiente, botón «Recibí dinero»; Caja: lo recibido por confirmar; Aplica: lo que está en caja por aplicar) y desde ahí actúa. No hay otra forma de iniciar un movimiento.
3. **Totales solo con lo confirmado**: saldos de caja, totales y Dashboard usan solo `CONFIRMADO` (ya es así en `v_saldos_cuentas`; se agregan tarjetas separadas). **«En tránsito»** = recibido y aún sin confirmar por Caja, mostrado aparte con monto por moneda.
4. **Rechazados y revertidos** se muestran en su propia pestaña con motivo, quién y cuándo; los cancelados del libro también; no se borra nada.
5. **Una sola guía** (`docs/finanzas/guia-flujo-dinero-equipo.md`): recibir, confirmar en Caja, aplicar y qué hacer si algo sale mal.
6. **Una sola entrada de menú y una sola lógica de permisos**:
   - Hoy hay dos entradas (Finanzas, módulo `finanzas` del área Administración; Flujo de dinero, abierto por capacidad) y una tercera (Cobranza, Compras/Administración), con tres reglas de permiso distintas.
   - Propuesta: **una sola entrada «Control financiero»** (`/finanzas`) visible para quien tenga una etapa, administre o sea de Administración. Dentro: **Mi bandeja** · **Movimientos** (libro, con origen y estado) · **En tránsito** · **Rechazados y revertidos** · **Cuentas y saldos** · **Cobranza** (consulta, saldos a favor, reversas). Cada pestaña se muestra según la etapa; la base sigue decidiendo.
   - Permiso único: las **etapas** (capacidades; con perfiles, cuando se migren) deciden quién opera; **administrador financiero** decide quién corrige (cancelar/ajustar) y revierte; Administración solo-lectura consulta. Desaparece «iniciar un movimiento» como permiso de área.

### 2.10 Sin pérdida de información (requisito 9)
Solo se agregan columnas y tablas; ninguna se elimina ni se reescribe. La auditoría existente (`movimiento_bitacora`, `bitacora_compras_inventario`, `remision_refaccion_eventos`, aplicaciones y pagos revertidos) se conserva y se complementa con `flujo_dinero_eventos`.

### 2.11 Decisiones que necesito de Polo
1. «Revertir pago»: ¿el dinero sale del libro (propuesto) o regresa a «En caja»?
2. Evidencia también en **salidas**: se propone exigirla en los tres tipos (vale en salidas de efectivo).
3. Los pagos y movimientos de demostración (45,000; CP-0000x; CxC/abono demo): ¿se dejan marcados como históricos (propuesto) o se anulan?
4. Cobro mixto (remisión + crédito en un solo pago): hoy son dos movimientos; ¿se requiere uno solo?
5. `marcar_pago_remision_*` (bandera sin dinero): ¿se deriva del saldo cobrado en una siguiente etapa?

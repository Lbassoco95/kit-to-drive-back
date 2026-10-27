# Flujo de dinero unificado · Fase 1 (inventario) y Fase 2 (diseño) — 27 oct 2026

Sustituye los prompts anteriores. Integra lo construido (migraciones `20261030000001` unificación y `20261031000001` bancos por empresa + búsqueda; ramas `claude/unificar-control-flujo` en back, front y compuerta). Nada de esto se ha aplicado en producción.

## FASE 1 · Inventario (solo lectura, producción al 27 oct)

### Datos reales hoy
| Libro | Estatus | Monto | Cuenta | Origen real |
|---|---|---|---|---|
| ING-000004 «DEMO» | CONFIRMADO | 45,000 MXN | Caja chica | Directo (Martin) |
| ING-000005 «Venta moto» | PENDIENTE | 3,050 MXN | sin cuenta; vía intermediario sin nombre | Directo (Polo) |
| ING-000006 «Pago de cliente Irene» | CONFIRMADO | 3,050 MXN | Caja chica | Del flujo (FD-000009, hoy EN_CAJA, real) |
| EGR-000004 pago final contenedor | CONFIRMADO | 8,664.41 USD · TC 18.68 · transferencia | **Caja dólares (efectivo)** | Directo (Martin) |

Saldos: Caja chica 48,050 · **Caja dólares −8,664.41** · Banco principal 0. Cuentas: Caja chica (efectivo MXN), Caja dólares (efectivo USD), Banco principal (banco MXN, sin nombre de banco). 3 pagos de cobranza reales: CP-00001 3,000 efectivo validado (sin entrada en el libro); CP-00002 y CP-00003 revertidos. 1 abono de crédito. 9 flujos (8 de prueba; FD-000009 real).
Personas: Jair (admin_financiero; Recibe), Leticia (admin_financiero; Caja), Luna (admin_financiero; **tiene Recibe, Caja y Aplica**), Martin y Polo (admin; las 3 etapas). Catálogo de categorías: tabla `categorias_financieras` (egresos hoy: Pago a proveedor, Compra de partes, Flete / transporte, Aduana / importación, Nómina / raya, Servicios (luz, agua, renta), Mantenimiento, Impuestos, Viáticos, Otro egreso); el movimiento guarda el **nombre** como texto. Ningún movimiento usa «Mantenimiento», así que no hay nada que reclasificar hoy.
Empresa: no existe en clientes, remisiones ni movimientos (solo `config_general.empresa_nombre`). **La empresa de un movimiento no se puede deducir del cliente ni de la remisión: la tiene que elegir quien captura.**
`tipo_cambio` existe en `flujo_dinero` y en `movimientos_financieros` (más `monto_mxn`). Solo EGR-000004 lo usa. No hay entrada de USD que dé costo a la posición en USD.

### Puertas por las que nace dinero (antes de la unificación) y estado en lo construido
| Puerta | Quién la usa hoy | Estado en la rama |
|---|---|---|
| Control financiero: Registrar ingreso/egreso → INSERT en libro | Martin, Polo (ING-4/5, EGR-4) | Cerrada (sin política ni privilegio; guardia en base) |
| Control financiero: confirmar / cancelar / comprobar / editar / borrar | Admin financiero | Confirmar y borrar eliminados; cancelar, ajustar, comprobar por RPC con motivo |
| Cobranza: registrar pago, validar, aplicar | Compras/Finanzas | Cerradas (REVOKE); revertir sigue, coherente con el flujo |
| Crédito: registrar abono (INSERT en `cxc_abonos`) | Finanzas | Cerrada; el abono nace del flujo (destino «crédito») |
| Flujo de dinero: Recibe/Caja/Aplica | Jair, Leti, Luna, Martin | Se mantiene, ahora con evidencia, empresa, reversa |
| `cuentas_financieras` escritura directa | Admin financiero | Cerrada; alta/edición por RPC con bitácora |
| `marcar_pago_remision_con_evidencia`, remisiones con pago | Ventas/Compras | Pendiente de inventariar a fondo (bandera de pago; no crea dinero) |
| Carga histórica de remisiones | Una sola vez | Aparte, no mueve dinero |

### Qué cambia o se pierde con la unificación (campos del libro)
Comprobación de efectivo, factura (folio/UUID/RFC), proveedor/empleado, intermediario y adjuntos **se conservan** en los movimientos existentes; en los nuevos viajan en `datos_libro` y la evidencia pasa a `movimiento_adjuntos` al confirmar. Ya no se puede capturar a mano: via/intermediario, remisión y contenedor se asignan en Aplica o por ajuste con motivo. Montos, cuentas, fechas y método no se editan nunca (se cancela y se registra otra vez).

### Estado de lo construido y probado (local)
Migración A (unificación) y B (empresas, cuentas por empresa con últimos 4, búsqueda de remisiones, cambio de cliente, crédito, políticas de evidencia), front con pestañas, compuerta, reversa SQL, respaldo, plan de ventana; suites SQL (flujo, unificación, transición, bancos/búsqueda) y vitest/typecheck/build en verde.

## FASE 2 · Diseño: qué cambia respecto a lo construido

| Pedido | Hoy en la rama | Cambio |
|---|---|---|
| Dos entradas: «Flujo de dinero» (operar) y «Control financiero» (consultar, conciliar, saldos, reportes, corregir) | Un solo módulo con 5 pestañas | **Separar**: `/finanzas/flujo` = Recibe, Caja, Aplica, Gastos. `/finanzas` = Saldos y en tránsito, Movimientos (libro con folio FD), bandeja de pendientes por etapa (solo lectura, con enlace al FD), Cuentas bancarias, Categorías, Posición USD. Mismas pantallas, solo se reparten. |
| Gastos: Jair captura, Luna confirma | SALIDA = Recibe → Caja → Aplica (clasifica) | **Cambia el modelo de SALIDA** (ver D). Perfiles nuevos `captura_gasto` y `confirma_gasto` en `flujo_capacidades`, asignables desde el mismo diálogo de permisos del flujo (sin SQL). |
| Evidencia obligatoria en ingresos y gastos | Hecha | Sin cambio (para gastos: factura o comprobante). |
| Empresa del movimiento | La elige Recibe | Igual; también en gastos. No se deduce del cliente. |
| Cuenta de salida del gasto | La elige Caja | En gastos la propone quien captura (filtrada por empresa/moneda/método) y quien confirma valida. |
| Cuentas de prueba y categorías de prueba separadas | Cuentas compartidas | Agregar `es_prueba` a empresas, cuentas y categorías; el prueba solo ve lo suyo; el saldo de prueba se calcula del flujo de prueba (el libro real nunca se toca). |
| Cuatro tipos de cuenta | `tipo` (efectivo/banco) + `moneda` | Ya lo cubre; se valida que sea MXN o USD (ver decisión 4). |
| Desactivar cuenta con saldo ≠ 0 | Pide motivo | Igual, y bloquea movimientos nuevos en cuentas inactivas (ya lo hace `flujo_cuentas`). |
| Cancelar/ajustar solo administrador financiero con motivo | Hecho; bloquea a quien confirmó | **Agregar**: tampoco lo hace quien capturó ese movimiento (Jair es admin_financiero). |

### Gastos (D) — modelo propuesto
1. Jair captura: empresa, categoría, proveedor/beneficiario, monto, moneda, cuenta de salida, método, evidencia. Queda **«Por confirmar»**.
2. Luna ve la bandeja de gastos por confirmar, revisa y **confirma** o **rechaza con motivo** (Jair lo ve y corrige y reenvía). Al confirmar se crea el egreso CONFIRMADO en el libro con folio FD. Sin etapa Aplica (la categoría ya viene capturada).
3. Saldo suficiente: se valida al capturar (aviso) y **al confirmar (bloqueo)** con el saldo confirmado de la cuenta; el mensaje dice cuenta, saldo y faltante. Ya no se confirma nada que deje la cuenta en negativo.
4. Separación: quien captura no confirma el mismo gasto; un administrador con ambos perfiles opera gastos distintos.
5. **Efectivo (decisión tuya)**: A) solo la confirmación de Luna (más simple; la comprobación de efectivo queda obligatoria después). B) *Recomendada*: para gastos en efectivo, Luna **autoriza** y **Leti registra la entrega**; el libro se mueve cuando Leti entrega (el dinero salió de verdad) y la comprobación posterior sigue. En transferencia y banco basta Luna.

### Perfiles y convivencia
Capacidades independientes por persona: `recibe`, `caja`, `aplica` (ingresos) y `captura_gasto`, `confirma_gasto` (gastos). Ejemplo: Jair = recibe + captura_gasto; Leti = caja (y entrega de efectivo si eliges B); Martin = aplica; Luna = confirma_gasto. La separación se aplica por movimiento, no por persona. La migración de perfiles-por-etapa que dejé sin aplicar se absorbe aquí.

### Categorías (E)
`categorias_financieras` + columnas `ambito` (NACIONAL/INTERNACIONAL), `moneda_extranjera` (bool), `afecta_totales` (bool), `es_prueba`. Nuevas: Proveedor internacional, Flete internacional (ambos exigen moneda ≠ MXN y cuenta en esa moneda), Mantenimiento de oficina, Mantenimiento de vehículos. «Pago a proveedor» y «Flete / transporte» quedan nacionales (se marca el ámbito; **el texto del nombre no cambia** para no romper movimientos históricos). «Mantenimiento» pasa a inactiva para capturas nuevas. Reclasificación: hoy hay 0 movimientos en «Mantenimiento»; si aparecieran, un listado para que lo revises y una función que reclasifica con motivo uno por uno. Alta, renombre y desactivación por RPC con bitácora, solo administrador financiero y administrador, nunca borrado. Las de cambio de divisa llevan `afecta_totales = false`.

### Bancos por empresa (F) — ubicación
Sección «Cuentas bancarias» y «Categorías» dentro de **Control financiero** (administración del catálogo, no captura de dinero). Migración sin pérdida: las 3 cuentas conservan su id e historial y siguen funcionando sin empresa hasta que el administrador les asigne una; los datos reales los das tú. «Caja dólares» queda como efectivo USD y «Banco principal» como banco MXN.

### Cambio de divisa y posición en USD (G) — diseño, para la segunda ventana
Una operación atómica `flujo_cambio_divisa`: cuenta origen (moneda A, monto A) → cuenta destino (moneda B, monto B), tipo de cambio efectivo = monto MXN / monto USD; dos movimientos del libro con el mismo `operacion_id`, categoría «Cambio de divisa» con `afecta_totales = false`; mismo flujo (captura → confirma, evidencia obligatoria, personas distintas). Posición en USD: vista por cuenta y empresa con saldo, entradas, salidas del periodo y **costo promedio ponderado** (cada entrada en USD — cambio de divisa o ingreso con tipo de cambio — recalcula el promedio móvil). Pagos internacionales: se valúan al costo promedio vigente; la diferencia contra el tipo de cambio del día se reporta aparte como resultado cambiario. Requiere un **saldo inicial de USD con su tipo de cambio** que me des (hoy la caja está en −8,664.41).

### Reversa (H)
Hecha en la unificación: revertir la aplicación regresa el flujo a «En caja, por aplicar» sin tocar el libro; revertir el pago deja el flujo REVERTIDO y cancela el libro con motivo. Los gastos agregan: rechazo con motivo y, si ya estaban confirmados, cancelación por administrador financiero distinto de quien capturó o confirmó.

### Transición (I)
Los 4 movimientos directos se marcan `HISTORICO_DIRECTO` (solo una marca; montos, fechas, estatus y cuentas intactos). **ING-000004 e ING-000005 no se modifican.** CP-00001 (3,000 cobrado y validado fuera del flujo, no está en el libro) queda como histórico sin libro; propuesta de tratamiento en las decisiones. Respaldo previo de las 5 tablas (`docs/ventana/00_respaldo.sql`).

### Guía (J)
Una sola guía: se registra todo en Flujo de dinero (Jair, Leti, Martin, Luna) y se corrige desde Control financiero. Se actualiza la que ya existe.

### Orden de despliegue
Ventana 1: respaldo → unificación (única puerta, evidencia, reversa) → bancos por empresa y cuentas (con es_prueba) → categorías → gastos → búsqueda de remisiones → compuerta → front. Ventana 2: cambio de divisa y posición en USD. Fuera del horario de Jair y Leti (necesito ese horario).

## Contradicciones y decisiones que necesito de ti
1. **ING-000005 (3,050 pendiente)**: con una sola puerta ya no existe el botón Confirmar. Para no tocarlo y que puedas resolverlo, propongo una función única `movimiento_historico_resolver` (solo administrador financiero, solo movimientos históricos PENDIENTES, motivo y bitácora) para confirmarlo con cuenta o cancelarlo. ¿Va? También: parece el mismo dinero que ING-000006/FD-000009 (3,050 de «Irene»); revísalo.
2. **EGR-000004** (8,664.41 USD por transferencia salió de «Caja dólares», efectivo): contradice la regla método↔cuenta que quieres y deja la caja en negativo. Se conserva tal cual como histórico; ¿cómo lo regularizamos (saldo inicial de USD, o cancelar y recapturar por el flujo)?
3. **Efectivo de gastos**: A (solo Luna) o B (Luna autoriza, Leti entrega) — recomiendo B.
4. **«USD u otra moneda»** vs cuatro tipos de cuenta (solo MXN y USD): ¿habrá cuentas en CNY u otras? Si sí, serían más tipos.
5. **Cambio de cliente**: recomiendo que **no** exija segunda persona (quien aplica ya es una tercera persona distinta de Recibe y Caja, el pago aún no ha movido nada, y queda con motivo y bitácora visible en Control financiero). Queda un parámetro para exigir administrador si lo prefieres.
6. **Permisos de Luna**: hoy tiene Recibe, Caja y Aplica. ¿Se las quito y solo confirma gastos?
7. **Jair es administrador financiero**: puede cancelar/ajustar y administrar catálogos aunque capture gastos; por eso bloquearé que cancele lo que él capturó. ¿De acuerdo?
8. **CP-00001** (3,000 real cobrado sin pasar por el flujo ni el libro): ¿lo dejamos como histórico sin libro (la caja no lo refleja) o lo regularizamos con un movimiento autorizado por ti?
9. **«Conciliar»**: no existe conciliación en el libro. Propongo una marca simple «conciliado» (quién y cuándo) en Control financiero. ¿Es eso?
10. Datos reales: empresas (nombre y razón social), banco y últimos 4 de las cuentas, saldo inicial de USD con tipo de cambio, y el horario en que Jair y Leti capturan.


---

# FASE 3 · Construcción local y pruebas (decisiones de Polo del 27 oct) — resultado

## Decisiones aplicadas
1. Históricos: función única `movimiento_historico_resolver` (solo administrador financiero, motivo y bitácora). ING-000005 y ING-000004 los cancela Polo en la ventana con el procedimiento P3 (yo no los toco).
2. EGR-000004: se conserva; P4 = entrada de USD (`movimiento_regularizar`) + reclasificación al banco USD (`movimiento_reclasificar_cuenta`, dos contra-movimientos que no suman en totales; el original no se modifica).
3. Efectivo de gastos (opción B): Luna autoriza, Leti registra la entrega y el libro se mueve al entregar. Banco: Luna confirma y sale del banco.
4. Monedas: parámetro `monedas_permitidas` (hoy MXN y USD), ampliable sin código. Categorías internacionales exigen moneda distinta de MXN.
5. Cambio de cliente sin segunda persona, con parámetro `flujo_cambio_cliente_exige_admin`.
6. Luna: P1 le quita Recibe, Caja y Aplica y le deja confirmación de gastos.
7. Regla para toda persona: nadie cancela ni ajusta un movimiento que capturó, confirmó, autorizó, entregó o aplicó.
8. CP-00001: `cobranza_pago_regularizar` (movimiento histórico con marca REGULARIZACION, cuenta y fecha reales); se ejecuta en P5 con los datos de Polo.
9. Conciliación: marca simple `conciliado` (quién y cuándo) en Control financiero.
10. Empresas y cuentas reales: pantalla vacía y procedimiento P2 listo; no hay datos inventados.

## Qué cambia respecto a lo anterior
- Menú: dos entradas (Flujo de dinero: Recibe, Caja, Aplica, Gastos · Control financiero: Movimientos y saldos, Pendientes, Cuentas bancarias, Categorías).
- SALIDA ya no pasa por Recibe/Caja/Aplica: tiene captura y confirmación propias; `flujo_recibir/confirmar_caja/aplicar/rechazar` rechazan gastos con un mensaje claro.
- Empresas, cuentas y categorías con `es_prueba`: los usuarios de prueba tienen su empresa, sus 4 cuentas (MXN/USD, efectivo/banco) y sus categorías; no ven las reales y viceversa. El saldo de una cuenta de prueba sale del flujo de prueba (el libro real no se toca).
- Los tests viejos de SALIDA se reescribieron al flujo de gastos; las suites anteriores siguen en verde.

## Cambio de divisa y posición en USD (G) — DISEÑO (segunda ventana; no construido)
**Operación atómica** `flujo_cambio_divisa`: captura (Jair) → confirma (Luna), evidencia obligatoria, personas distintas. Datos: cuenta origen (moneda A, monto A), cuenta destino (moneda B, monto B), empresa (misma en ambas). Tipo de cambio efectivo = monto en MXN ÷ monto en USD (se calcula, no se captura). Al confirmar, en una sola transacción: dos movimientos del libro (egreso en origen, ingreso en destino) con el mismo `operacion_id`, categoría «Cambio de divisa» (`afecta_totales = false`, ya creada), origen FLUJO. Se bloquea si el origen no tiene saldo. No suma en totales de gastos ni de ingresos; sí mueve los saldos de las dos cuentas. Reversa: cancelar la operación cancela los dos movimientos juntos con motivo.
**Posición en USD** (vista en Control financiero): por cuenta y empresa, saldo en USD, entradas y salidas del periodo y **costo promedio ponderado móvil**: cada entrada en USD (cambio de divisa o ingreso con tipo de cambio o regularización) recalcula `(saldo_prev × costo_prev + entrada × TC) ÷ (saldo_prev + entrada)`; las salidas bajan saldo al costo vigente. Un pago internacional se valúa al costo promedio vigente (no al tipo de cambio del día); la diferencia contra el tipo de cambio de captura se reporta aparte como **resultado cambiario** (utilidad/pérdida), para que el gasto en MXN sea explicable. En reportes: «pagos internacionales a costo promedio» y «resultado cambiario» en dos renglones. Requiere un saldo inicial de USD con su tipo de cambio (P4 lo carga como regularización con `_afecta_totales = false`).
Inventario previo: `tipo_cambio` existe en `flujo_dinero` y en `movimientos_financieros` (con `monto_mxn`); hoy solo EGR-000004 lo usa (18.68) y «Caja dólares» está en −8,664.41 hasta P4.

## Pruebas (local)
- `probar_gastos.sh` (nuevo, 10 secciones): perfiles; gastos por transferencia (evidencia, categoría, moneda, cuenta, saldo suficiente con mensaje, rechazo con motivo, corrección, Luna no confirma lo que capturó); gastos en efectivo (autoriza → entrega, libro solo al entregar, saldo en ambos pasos, ninguno de los participantes cancela); categorías; **puertas cerradas** (ningún rol inserta directo en libro, cuentas, categorías, pagos ni abonos; ni el dueño); históricos (resolver, cancelar con motivo y bitácora, regularizar y reclasificar EGR sin tocar el original, históricos intactos); CP-00001; conciliación; **prueba/real** aislados; monedas por parámetro.
- Suites anteriores en verde: flujo de dinero, unificación, transición (sin pérdida de datos), bancos y búsqueda (cuentas por empresa y tipo, regla método/moneda, búsqueda y reparto de remisiones, cambio de cliente).
- Ensayo de los procedimientos P1–P5 contra una base con los 4 movimientos, CP-00001 y los usuarios reales: pasan.
- Back: vitest 91 en verde; front: typecheck, 500 pruebas y build; compuerta: 19 pruebas.

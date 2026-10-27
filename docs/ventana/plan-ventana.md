# Plan de despliegue (Fase 4) · Flujo de dinero y Control financiero — versión del 27 oct 2026 (v2)

Nada se ejecuta en producción sin la autorización escrita de Polo, con fecha y ventana, **por fase**. Ventana **fuera del horario en que Jair y Leti capturan** (el horario lo da Polo). SQL que Polo corre: va pegado en el chat y está en `docs/ventana/`.

## Ventana 1 — única puerta, evidencia, gastos, categorías, bancos por empresa y cuentas en USD, búsqueda de remisiones
Migraciones que se aplican, en este orden: `20261030000001` (unificación) → `20261031000001` (bancos por empresa, búsqueda, cambio de cliente) → `20261101000001` (gastos, categorías, es_prueba, monedas, históricos y regularización).

| # | Paso | Verificación después | Reversa |
|---|------|----------------------|---------|
| 0 | Aviso al equipo (texto abajo) y confirmar que Jair, Leti, Martin y Luna no están capturando | Polo confirma | — |
| 1 | **Respaldo** `00_respaldo.sql` (movimientos_financieros, cuentas_financieras, cobranza_pagos, cxc_abonos, flujo_dinero) | Conteos vivo = respaldo (4·3·6·1·9 al día de hoy) | `DROP SCHEMA respaldo_20261027 CASCADE` solo si ya no hace falta |
| 2 | Migración `20261030000001` | V1 (conteos y saldos idénticos), V2 (sin_origen = 0; libro/registrar cerrados) | `reversa_unificacion_y_bancos.sql` |
| 3 | Migración `20261031000001` | V1, V3 (empresas 0, cuentas sin empresa 3, funciones nuevas) | misma reversa |
| 4 | Migración `20261101000001` | V1 y V5 (categorías nuevas, Mantenimiento inactiva, cuentas de prueba, parámetro monedas) | `reversa_gastos_categorias.sql` |
| 5 | Registrar las 3 migraciones en `migraciones_aplicadas` (SQL pegado en el chat) | 3 filas nuevas | borrar esas filas |
| 6 | **Compuerta** (allowlist + solo lectura en libro, cuentas, abonos, categorías) | `POST movimientos_financieros` → 403; `flujo_capturar_gasto` pasa | rollback del despliegue |
| 7 | **Front** a `main`, Vercel despliega (dos entradas de menú) | Vercel verde para ese SHA | rollback del deployment **junto con** la reversa SQL |
| 8 | **P1** perfiles (o por el diálogo, sin SQL): Luna solo confirma gastos; Jair captura gastos | lista de capacidades | `flujo_asignar_capacidad` inverso |
| 9 | **P2** empresas y cuentas reales (con los datos de Polo): las 3 cuentas conservan id y saldo | V4: saldos iguales a V1 | desactivar (no se borra) |
| 10 | **P3** cancelar ING-000005 (duplicado de ING-000006 / FD-000009) e ING-000004 (DEMO) — actúa Jair | libro: 2 cancelados con motivo; Caja chica = 3,050 | no tiene reversa (cancelación con motivo, queda en bitácora) |
| 11 | **P4** EGR-000004: entrada de USD + reclasificación al banco en USD — actúa Jair | Caja dólares 0; banco USD = entrada − 8,664.41; EGR-000004 intacto | los contra-movimientos se cancelan con `movimiento_cancelar` (otro administrador) |
| 12 | **P5** CP-00001 con cuenta y fecha reales | libro: 1 movimiento REGULARIZACION de 3,000 | `movimiento_cancelar` |
| 13 | **Prueba de humo** con cuentas `prueba.*` y luego con cada persona real: Jair (recibe y captura gasto), Leti (caja y entrega), Martin (aplica), Luna (confirma gasto) | cada uno completa su paso; el libro real solo cambia con lo confirmado | el libro real no se toca en la prueba |
| 14 | Avisar al equipo y reabrir | Jair y Leti trabajan sus pestañas | **Reabrir la puerta directa** con `reversa_unificacion_y_bancos.sql` si hay un bloqueo que impida trabajar |

## Cómo se cierra la puerta directa sin dejar a nadie sin poder trabajar
1. El hallazgo: hoy se captura directo (EGR-000004 se capturó así hoy). Desde el paso 2 esa vía deja de existir.
2. Todo está construido antes de cerrar: el front nuevo y la compuerta se despliegan **inmediatamente después** de las migraciones, en la misma ventana, y la ventana es fuera del horario de captura. Entre el paso 2 y el 7 nadie debe abrir la pantalla vieja (ya exige evidencia y empresa).
3. Lo que alguien capture el mismo día por la vía directa **antes de la ventana** se conserva y queda marcado como histórico; se regulariza con el mismo procedimiento. Después, solo hay flujo.
4. Cada persona tiene su camino antes de reabrir (paso 13): Jair recibe y captura gastos; Leti confirma en caja y entrega efectivo de gastos; Martin aplica; Luna confirma gastos. Si algo bloquea, la reversa reabre la puerta anterior en minutos y los datos no se pierden.
5. Primer día: acompañamiento a Jair y Leti en vivo; todo lo que no puedan hacer por falta de datos (empresa, cuenta, categoría) se corrige desde Control financiero (cuentas bancarias / categorías), sin SQL.

## Ventana 2 — cambio de divisa y posición en USD (diseñado, no construido)
Ver el documento de diseño. Se despliega solo con autorización y tras probarse en local.

## Aviso para el equipo (para enviar antes de la ventana)
> Equipo: el <fecha> de <hora> a <hora> actualizamos el manejo del dinero. Durante ese tiempo no capturen ni confirmen movimientos. Desde el <fecha> **todo el dinero (ingresos, reembolsos y gastos) se registra únicamente en «Flujo de dinero»**: Jair recibe los pagos y captura los gastos con su evidencia; Leti confirma en caja (y entrega el efectivo de los gastos); Martin aplica los pagos a remisiones; Luna confirma o rechaza los gastos. «Control financiero» queda para consultar saldos, conciliar y corregir (con motivo). Ya no hay otra forma de capturar un movimiento. Cualquier cosa que quieran capturar antes de la ventana, anótenla y se registra al terminar. Guía: «Control financiero: guía del equipo».

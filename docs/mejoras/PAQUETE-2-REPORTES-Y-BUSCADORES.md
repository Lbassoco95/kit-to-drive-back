# Paquete 2 — Reportes y buscadores (solo lectura)

**Estado: MIGRACIONES Y REVERSAS LISTAS Y ENSAYADAS; NADA APLICADO. El front de este paquete todavía NO está escrito.** Va **después de la Fase 2** (ventana propia; guion: `VENTANA-PAQUETE-2.md`). Frase: «Autorizo paquete 2 (reportes y buscadores) en producción, ventana del `<fecha>`». Hay decisiones de alcance (§5) que cambian lo que se construye; conviene tenerlas antes de escribir.

## 1. Lo que ya existe (leído del repo y del respaldo de producción)

| Pantalla pedida | Hoy | Datos y volumen (25 oct) |
|---|---|---|
| Reporte de ventas | **No existe** un reporte de ventas filtrable. Hay `v_reporte_remisiones`, `v_reporte_pagos`, `v_reporte_pipeline`, `v_reporte_produccion` (vistas con `security_invoker`), y Rotación (`ventas_mensuales_refacciones`) | remisiones 93; remisiones de refacciones 16 órdenes y 15 remisiones; partidas de refacciones 32; movimientos de almacén 1,079 |
| Kardex | `Kardex.tsx` con `kardex_refaccion(_producto, _desde, _hasta)`: **un solo artículo**, sin filtro de almacén; exige `puede_leer_compras_inventario` o `puede_ver_almacen_refacciones` | movimientos 1,079; productos 2,237 |
| Rotación y clasificación | `RotacionABC.tsx` con `resumen_rotacion_refacciones(_desde,_hasta,_incluir_prueba)`: todos los artículos; sin filtro de ítem ni de almacén | productos 2,237 |
| Entregas | `Entregas.tsx`: lee `remisiones_refacciones` y `motocarros` por RLS y llama RPC para marcar | motocarros 183 |
| Fecha programada de entrega (refacciones) | **La columna ya existe**: `remisiones_refacciones.fecha_entrega_programada`; hace falta mostrarla | — |

Quién ve Kardex, Rotación y los reportes de Compras: compras/inventario, almacén físico, finanzas/cobranza y Dirección (`puede_leer_compras_inventario`). **Un vendedor hoy no entra a ninguno.**

## 2. Diseño propuesto

1. **Reporte de ventas filtrable (almacén, vendedor, ítem uno o varios, periodo).** Función de solo lectura **`SECURITY INVOKER`** sobre las partidas de remisión de refacciones (`remision_refaccion_items` + `remisiones_refacciones`, y su almacén): así **la visibilidad sale de la RLS del Paquete 1** (el vendedor ve solo las suyas; Dirección, administrativos y supervisores, todas) sin una segunda regla que mantener. Parámetros con arreglos (`_productos uuid[]`, `_vendedores uuid[]`, `_almacenes text[]`). Devuelve piezas, monto neto (con descuento) por ítem/vendedor/almacén/mes.
2. **Kardex con varios ítems.** `kardex_refacciones_multi(_productos uuid[], _desde, _hasta, _almacen)`, con la misma restricción de acceso que `kardex_refaccion`, saldo por ítem (`sum(...) OVER (PARTITION BY producto ...)`) y saldo inicial por ítem.
3. **Rotación y clasificación con buscador.** Una sobrecarga de `resumen_rotacion_refacciones` con filtros de ítem y almacén; la clasificación ABC se calcula sobre el conjunto filtrado **y** se muestra la del conjunto total para no confundir.
4. **Entregas.** Filtros en pantalla (pendientes, entregadas hoy, periodo, cliente, vendedor) sobre los mismos datos que ya lee por RLS: no necesita función nueva. Un vendedor ve **solo sus entregas** (garantizado por la RLS del Paquete 1, que es lo que corrige las remisiones de refacciones).
5. **Fecha programada en la remisión de refacciones:** solo front (la columna existe y ya está en el `select *`).

Ninguna pantalla escribe: las funciones nuevas son `STABLE`, sin `INSERT/UPDATE/DELETE`, y las pruebas lo verifican.

## 3. Rendimiento

Con los volúmenes actuales (1,079 movimientos; 2,237 productos; 32 partidas; 183 unidades) cualquier consulta de estas es de milisegundos. **Índices propuestos: ninguno por ahora**; ya existen `idx_ref_mov_producto_fecha (producto_id, fecha_efectiva, created_at)`, `idx_ref_mov_documento (documento_id)` e `idx_rem_ref_cliente`. Se pediría uno solo si una consulta del reporte de ventas por almacén o vendedor pasara de ~200 ms en la réplica con volumen multiplicado ×100; se propondría sin aplicarlo.

## 4. Objetos nuevos y permisos (por la regla «todo nace cerrado»)

3 funciones (`reporte_ventas_refacciones`, `kardex_refacciones_multi`, sobrecarga de rotación), cada una con `REVOKE ALL … FROM PUBLIC, anon` y `GRANT EXECUTE … TO authenticated` explícito, `SET search_path = public`. **Alta en la lista blanca de la compuerta** (`RPCS` de `kit-to-drive-front/src/allowlist.ts`: hoy 85) y en `contrato/funciones.json` + `src/test/contrato-back.json` del front. Versiones de migración **posteriores a `20261107…`**.

## 5. Decisiones de Polo (26 oct 2026) — todas A

1. **«Ventas» = solo refacciones.** Las unidades (motocarros) quedan fuera por ahora.
2. **Qué cuenta como venta:** la partida de una remisión de refacciones **no cancelada**, por la **fecha de la remisión**, **sin datos de prueba** (con `_incluir_prueba` solo para quien ve datos de prueba). El importe es el **vigente** de la cobranza (`importe_partida_refaccion` sobre surtido + bloqueado, con el descuento de la partida y el general).
3. **Administrativos y supervisores ven todas las ventas.** **Confirmado por Polo: se mantiene la visibilidad por RLS actual.** Por construcción lo mismo ven los roles que ya leen todas las remisiones de refacciones por su RLS (**compras/inventario, finanzas/cobranza, almacén y Dirección**, medido en el ensayo): no hay una segunda regla que mantener. `fabrica` ve 0.
4. **El vendedor no entra a Kardex ni Rotación** (el ensayo lo comprueba: «Sin acceso»); solo reporte de ventas y Entregas.

## 5.1 Qué se construyó (migraciones `20261108…`, ensayadas con Fase 1 + Paquete 1 + Fase 2)

| Archivo | Objeto | Notas |
|---|---|---|
| `…0001_paquete2_reporte_ventas_refacciones` | `reporte_ventas_refacciones(_desde, _hasta, _almacenes[], _vendedores[], _productos[], _incluir_prueba)` | **SECURITY INVOKER**, STABLE; una fila por mes × almacén × vendedor × artículo; el vendedor solo ve las suyas por la RLS |
| `…0002_paquete2_kardex_varios_articulos` | `kardex_refacciones_multi(_productos[], _desde, _hasta, _almacen)` | DEFINER con la puerta del kárdex original; máx. 50 artículos; saldo corrido y saldo inicial por artículo; con un artículo da lo mismo que `kardex_refaccion` |
| `…0003_paquete2_rotacion_filtrada` | `resumen_rotacion_refacciones_filtrado(_desde, _hasta, _incluir_prueba, _productos[], _almacen)` | **Otro nombre, no una sobrecarga** (con opcionales haría ambiguas las llamadas por RPC). La clasificación ABC la calcula el front (`clasificarABC`) sobre lo que recibe |
| `…0004_paquete2_reporte_ventas_totales` | `reporte_ventas_refacciones_totales(…)` (mismos filtros) | **SECURITY INVOKER**; una fila con el total de **remisiones distintas**, piezas y monto neto. Añadida tras el front: sumar la columna `remisiones` de las filas cuenta de más una remisión con varios artículos o almacenes (el ensayo lo demuestra) |

Entregas (filtros) y la fecha programada son **solo front**. Ninguna función escribe (el ensayo y `tests/paquete-2.test.ts` lo verifican). **Falta el front** y el alta en la compuerta de las 3 RPC (`RPCS`: hoy 106 en `main`, 107 con el Paquete 1, 110 con este). Resultados: `ensayo/resultado-paquetes-2-3.json`.

## 6. Choques

- **Con la Fase 2 (PR #14 y #74):** ninguno de objetos. El reporte lee `profiles` para el filtro de vendedor; la Fase 2 solo cambia la política de **edición** de `profiles`, no la lectura.
- **Con el Paquete 1:** depende de él (la visibilidad del vendedor en remisiones de refacciones).
- **Con el Paquete 3:** el Paquete 3 agrega «crédito» a `tipo_pago` y una fecha editable de remisión; el reporte de ventas debe leer la **fecha vigente** (si la edición de fecha se aplica después, el reporte ya la respeta porque lee `fecha_remision`).

# Paquete 2 — Reportes y buscadores (solo lectura)

**Estado: DISEÑO. No se escribió código ni migraciones todavía.** Va **después de la Fase 2** (ventana propia). Frase: «Autorizo paquete 2 (reportes y buscadores) en producción, ventana del `<fecha>`». Hay decisiones de alcance (§5) que cambian lo que se construye; conviene tenerlas antes de escribir.

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

## 5. Decisiones que faltan (cambian lo que se construye)

1. **¿«Ventas» es solo de refacciones (productos) o también de unidades (motocarros)?** «Ítem uno o varios» y «almacén» apuntan a refacciones; las unidades se venden por remisión de motocarros (modelo, color).
2. **¿Qué cuenta como venta?** La fecha de la remisión, la del surtido o la de la entrega; si entran las **canceladas**; y si entran los datos de **prueba** (hoy los reportes de Compras los excluyen salvo que se pida).
3. **¿Qué pueden ver los administrativos y los supervisores en ventas?** Hoy ven todas las remisiones (por RLS); se asumió que ven todas las ventas.
4. **¿El vendedor entra a «Kardex» y «Rotación»?** Hoy no. Se asumió que **no** (son de inventario); solo el reporte de ventas y Entregas son suyos.

## 6. Choques

- **Con la Fase 2 (PR #14 y #74):** ninguno de objetos. El reporte lee `profiles` para el filtro de vendedor; la Fase 2 solo cambia la política de **edición** de `profiles`, no la lectura.
- **Con el Paquete 1:** depende de él (la visibilidad del vendedor en remisiones de refacciones).
- **Con el Paquete 3:** el Paquete 3 agrega «crédito» a `tipo_pago` y una fecha editable de remisión; el reporte de ventas debe leer la **fecha vigente** (si la edición de fecha se aplica después, el reporte ya la respeta porque lee `fecha_remision`).

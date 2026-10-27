# Carga de remisiones históricas de refacciones (propuesta, sin aplicar)

**Para qué.** Las ventas de octubre ya se descontaron del inventario por otro lado. Crearlas por el camino normal (Ventas crea → Almacén libera) las descontaría dos veces. Esta carga deja la remisión **confirmada, entregada y con su total** para cobrarla por el flujo de dinero, **sin mover inventario**.

**Decisiones de diseño**
- Solo administrador global (`es_admin_global`: Polo y Martin). Nadie más la ve ni la llama.
- Marcada: `es_historica`, referencia original, lote, quién y cuándo. Folio de la serie normal (RF-xxxxx).
- Primero se **simula** (por omisión): valida todo y devuelve errores juntos; no escribe nada. Una carga con errores no escribe nada.
- Una referencia (cliente + folio original) no se carga dos veces.
- **No toca inventario**: sin apartado, sin movimiento, y un candado final revisa que `stock` y movimientos queden idénticos (si no, deshace todo).
- Auditoría: evento en la remisión, bitácora (`cobranza` / `carga_historica`) y un registro por lote (`cargas_remisiones_historicas`).
- Candado: una histórica no se corrige, cancela ni borra por los caminos normales (devolvería existencias que no salieron por aquí). Se **anula** con `anular_remision_historica_refacciones`, que no mueve inventario y exige que no tenga cobros aplicados (primero se revierten en Cobranza).
- Cobranza y el flujo de dinero la ven como `confirmada` con saldo = total.

**Límites a conocer**
1. Los reportes de ventas y rotación (`ventas_mensuales_refacciones`, `resumen_rotacion_refacciones`, `salidas_por_cliente_mes`, kardex) leen `almacen_refacciones_movimientos`: **las históricas no aparecen en ellos**, porque no hay movimiento. Si se quieren ahí, hay que ampliar esos reportes (decisión aparte).
2. Cada partida necesita un artículo del catálogo (código nuevo), cantidad y precio. Si solo se tiene el total de la venta, hay que crear una partida por artículo o definir un artículo comodín (decisión aparte).
3. Se cargan como entregadas. Una venta de octubre aún sin entregar no es histórica: va por el camino normal.

**Cómo se usa (cuando se autorice)**
1. Polo pega la migración en el SQL editor y registra el script en `migraciones_aplicadas`.
2. Martin (o Polo) arma el JSON con las remisiones (formato en el comentario de la función) y la corre en **simulación**: `select public.cargar_remisiones_historicas_refacciones('<json>'::jsonb, 'Libro de octubre');`
3. Corrige lo que marque y la corre con `_simular = false`.
4. Verifica: remisiones `es_historica`, saldo = total en Cobranza, inventario igual (suma de stock y conteo de movimientos antes/después).
5. Recibe → Caja → Aplica cobran como cualquier remisión.

**Reversa.** Por remisión: `anular_remision_historica_refacciones(id, motivo)`. De toda la migración: quitar triggers, funciones, tabla y columnas (solo si no hay históricas cargadas).

**Pruebas.** `scripts/db-local/probar_remisiones_historicas.sh` (Postgres local): solo admin; simulación sin escritura; errores juntos; carga real sin mover inventario; marca y auditoría; idempotencia; cobro completo por el flujo; candados; anulación; `tests/remisiones-historicas.test.ts` (estructura).

## Esfuerzo estimado
| Pieza | Esfuerzo |
|---|---|
| Migración, funciones, candados y pruebas en base local (**ya hecho**, falta revisión) | 0.5 día de revisión y ajustes |
| Camino corto: Martin corre la función desde el SQL editor con un JSON armado desde su hoja | 0.5 día (plantilla de hoja → JSON, simulación y carga) |
| Pantalla de carga para administrador (pegar/subir CSV, vista previa con la simulación, confirmar, resultado) + etiqueta «Histórica» en Remisiones y Cobranza + lista blanca de la compuerta + contrato | 2 a 3 días |
| Ventana de aplicación, verificación y reversa preparada | 0.5 día |
| Reportes que incluyan históricas (límite 1) | 1 a 2 días, solo si se pide |

Alternativa más corta: aplicar la migración y cargar octubre con la función en SQL (≈1 día en total). La pantalla es comodidad, no requisito.

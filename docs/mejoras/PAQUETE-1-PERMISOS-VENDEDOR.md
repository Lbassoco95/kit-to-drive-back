# Paquete 1 — Permisos del vendedor (rehecho el 26 oct 2026)

**Estado: preparado, NADA APLICADO.** Va en su propia ventana, **todo el paquete en una sola** (base, compuerta y front): propuesta **martes 27 de octubre de 2026, de 19:00 a 00:00 CDMX** (la Fase 1 quedó completa y verificada el 26 oct, 96 registros), y **antes** de la Fase 2. Frase de autorización (la escribe Polo, con fecha): «Autorizo paquete 1 (permisos de vendedor) en producción, ventana del 2026-10-27». Diagnóstico: `DIAGNOSTICO-VENDEDOR.md`. Columnas, mecanismo y pantallas: `CATALOGO-BASICO-Y-PANTALLAS.md`. Guion de la ventana: `VENTANA-PAQUETE-1.md`. Matriz: `MATRIZ-ROL-POR-PANTALLA.md`.

**Qué cambió respecto a la primera versión.** Con **0 de 1,786 clientes asignados** (diagnóstico de Polo), «el vendedor ve los clientes sin asignar» le abría a todo vendedor el crédito, el saldo y los documentos de **todos** los clientes, y contradecía la Fase 2. Se **retiró** (la política «leer clientes» queda **sin cambio**) y se cambió por un catálogo básico. Tampoco se asigna ya un cliente sin asignar al usarlo.

## 1. Criterios (decisión de Polo) → qué hace el paquete

| # | Criterio | Cambio | Migración |
|---|---|---|---|
| 1 | Catálogo básico para vendedores: nombre y código de todos los clientes, solo para elegir cliente en oportunidad, ruta y actividad (**sin teléfono**, decisión del 27 oct) | Función de solo lectura `catalogo_clientes_basico()` (**5 columnas**: id, código, folio, nombre, activo). Los selectores del CRM la leen | `20261103000001` + front |
| 2 | Ficha completa, crédito, saldo, documentos y cartera solo para el vendedor dueño, supervisores, administrativos y Dirección | **No se toca ninguna política**: «leer clientes» y todo lo que la sigue (cartera, documentos, bitácora) quedan como están | — (verificado) |
| 3 | No asignar automáticamente un cliente sin asignar al usarlo; solo un cliente NUEVO de un vendedor queda a su nombre | Trigger de alta en `clientes`: si quien crea es vendedor, `vendedor_id := él`. **No hay** asignación al usar en CRM | `20261103000002` |
| 4 | Un vendedor crea oportunidad, ruta y actividad con cualquier cliente del catálogo básico | Las políticas de alta de CRM ya lo permiten (no comprueban el cliente); se verificó con pruebas, y el front deja de depender de la ficha | — (verificado) + front |
| 5 | Remisiones de refacciones: solo las del vendedor | `puede_leer_remision_refaccion` ya no incluye «comercial» en su lista final; administrativos, supervisores, Dirección y Almacén conservan lo que ven | `20261103000003` |
| 6 | D1, D4, D5 como las indicaste; D2 resuelta; D6 es tarea de Martin | Ver §4 | — |

Además, **una consecuencia que cierra la migración 2:** el vendedor solo captura una remisión a un cliente que **ya ve** (`CATALOGO-BASICO-Y-PANTALLAS.md` §4.3).

## 2. Objetos nuevos (todos nacen cerrados)

- **Funciones (4):** `catalogo_clientes_basico()` (**DEFINER** necesaria, con `search_path` fijo, `GRANT` explícito a `authenticated` y `service_role`, nada para `anon`); `es_vendedor_comercial(uuid)` y `clientes_asignar_vendedor_al_crear()` (DEFINER, `REVOKE ALL` a todos; solo las usan triggers); `remisiones_validar_cliente_visible()` (**INVOKER**, aplica la política de clientes; `REVOKE ALL`).
- **Triggers (2):** `trg_clientes_asignar_vendedor`, `trg_remisiones_validar_cliente`.
- **Ninguna tabla, vista ni política nueva.** Lista blanca de la compuerta: **+1 RPC** (`catalogo_clientes_basico`).
- **Front (`kit-to-drive`):** `cargarCatalogoBasico`, `cargarClientesParaElegir`, `cargarClienteParaMostrar` y `leerFichaParcial` en `catalogoClientes.ts`; CRM Oportunidades, Rutas, Actividades, Tracker y Detalle de oportunidad las usan; `src/lib/dazon.ts` (mensaje si falta la migración) y `src/test/contrato-back.json`. **Funciona en cualquier orden de publicación** (si la RPC no existe, el front usa lo que ya leía).

## 3. Pruebas (réplica local de PostgreSQL 16, datos sintéticos)

`docs/mejoras/ensayo/ensayar-paquete-1.py`; resultados en `resultado-paquete-1-con-fase1.json` y `…-sin-fase1.json`: 11 roles sintéticos (vendedor, otro vendedor, vendedor con cuenta de **prueba**, supervisor, administrativo, Dirección administrador, Dirección sin ser administrador, Finanzas, Almacén, Compras, Fábrica), 6 clientes (2 con dueño, 3 sin asignar, 1 de prueba), remisiones, refacciones, cartera y CRM. Se mide **antes**, se aplican las 3 migraciones, se mide **después**, se prueban los casos de escritura, se aplica cada reversa y se reaplica.

| Comprobación | Con Fase 1 | Sin Fase 1 |
|---|---|---|
| Las 3 migraciones se aplican en una transacción | sí | sí |
| Reaplicarlas deja el catálogo idéntico | sí | sí |
| Las reversas, en orden inverso, restauran **exactamente** lo que ve cada rol y el catálogo completo | sí | sí |
| Funciones / SECDEF ejecutables por `authenticated` / políticas / triggers (réplica) | 268 → **272** / 178 → **179** / 301 → 301 / 243 → **245** | 268 → 272 / 208 → 209 / 301 → 301 / 243 → 245 |

**Lo que ve cada rol cambia solo así:** el vendedor deja de ver las remisiones de refacciones del otro vendedor. **Nada más cambia** en las tablas (clientes, cartera, CRM, remisiones de motocarros): criterio 2. El catálogo devuelve **las 5 columnas, nada más**, a Comercial y Dirección; **Finanzas, Almacén, Compras y Fábrica reciben `42501`**; el usuario de prueba ve solo clientes de prueba.

**Escritura (vendedor = operador de Comercial), antes → después:**

| Caso | Antes | Después |
|---|---|---|
| Vendedor crea cliente sin indicar vendedor | queda **sin vendedor** (y él ya no lo ve) | queda **a su nombre** |
| Vendedor crea cliente a nombre de otro vendedor | se permite | queda a su nombre |
| Supervisor o administrativo crea cliente | sin vendedor | **igual** (no se auto-asignan) |
| Vendedor usa un cliente sin asignar, propio o **de otro vendedor** en oportunidad, actividad o ruta+parada | se permite; no cambia al cliente | **se permite; no cambia al cliente** (criterios 3 y 4) |
| Tras usar el cliente de otro vendedor, ve su ficha o su cartera | no | **no** |
| Vendedor captura una remisión a un cliente de otro vendedor o sin asignar (por la API) | **se permite y le abre la ficha** | **se rechaza** («No puedes capturar una remisión a un cliente que no ves») |
| Vendedor captura una remisión a un cliente suyo | se permite | se permite |

Pruebas del repo: `tests/paquete-1.test.ts` (9) y, en el front, `src/test/catalogo-basico-crm.test.ts` (9) más las existentes. Cada migración figura en `supabase/diagnostico_esquema.sql`.

## 4. Decisiones

- **D1, D4, D5 (decididas por Polo).** **D1:** se queda como está (el vendedor sigue viendo el cliente de sus propias remisiones aunque otro vendedor lo tenga asignado; se revisa después). **D4:** fuera del Paquete 1; las políticas `crm_*_insert_area` (permiten crear CRM a nombre de otro vendedor) quedan como pendiente de un paquete posterior. **D5:** aceptada; el vendedor opera saldo a favor y cobranza de refacciones solo sobre sus propias remisiones. **D3:** el vendedor ve solo sus remisiones de refacciones.
- **D2 resuelta** (la ficha ya no se abre). **D3 resuelta** (refacciones solo del vendedor). **D6:** tarea de Martin después de la ventana (devolver el nivel a los vendedores subidos a supervisor y **asignar clientes**; hasta entonces el vendedor no ve clientes en Clientes ni elige cliente al capturar remisión).
- **D8 — DECIDIDA: A (26 oct).** El vendedor sin clientes verá «Aún no tienes clientes asignados; pídele a tu supervisor que te los asigne» (cambio solo de front, **pendiente de hacer** en el PR #75). Pregunta original:  El vendedor sin clientes asignados seguirá viendo «0 de 0» en **Clientes**. ¿Cambiamos el texto vacío («Aún no tienes clientes asignados; pídele a tu supervisor que te los asigne») o lo dejamos?
- **D9 — DECIDIDA: A (26 oct), REVISABLE; ajustada el 27 oct: sin teléfono.** El catálogo se queda con las 5 columnas básicas (id, código, folio, nombre comercial, activo). **Si Martin pide `estado`, `municipio` o coordenadas, se agregan con una migración nueva** (con su reversa y su ventana). Pregunta original:  Columnas **no sensibles** que hoy usan algunas pantallas y no están en el catálogo (Polo pidió nombre, código y teléfono): `razon_social` (búsqueda en listas), `estado` y `municipio` (precarga al completar una visita), `latitud` y `longitud` (distancia del check-in). Sin ellas, para un cliente que el vendedor no ve: se busca solo por código y nombre, la visita se completa sin región ni municipio precargados y el check-in no valida la distancia. ¿Se agregan al catálogo?
- **D10 — DECIDIDA: A (26 oct).** El buscador global se queda como está (solo los clientes que el vendedor ve). Pregunta original:  El buscador global solo encuentra los clientes que el vendedor ve. ¿Debe buscar también en el catálogo básico?
- **D7 (hallazgo).** Las tablas de CRM de producción tienen columnas y políticas sin migración en el repo (`DIAGNOSTICO-VENDEDOR.md` §5).

## 5. Choques con la Fase 2 (PR #14 y #74) y orden

`ORDEN-Y-CHOQUES.md`. **No toca nada de lo que cambia la Fase 2.** El ensayo de la Fase 2 se **rehízo con este paquete aplicado**: todo se aplica y se revierte exacto. **El paquete 1 puede ir antes de la Fase 2.**

## 6. Plan de ventana

`VENTANA-PAQUETE-1.md`: estimado 2 h 15 min, orden M1 → M2 → M3, SQL de verificación con valores esperados, reversas y criterios de detención.

## 7. Decisiones del 27 oct 2026 y pendiente aparte

- **D11 — teléfono fuera del catálogo (Polo, 27 oct).** `catalogo_clientes_basico()` devuelve id, código, folio, nombre comercial y activo. Ningún selector del CRM usaba el teléfono del catálogo (el front lo lee, donde lo ve el rol, de la ficha). M1 y las pruebas se rehicieron; la reversa no cambia (borra la función por nombre).
- **Crédito del vendedor (decisión del 26 oct):** el vendedor **ve** el crédito de sus propios clientes (los suyos y los de sus propias remisiones, D1). El paquete no toca ninguna política de `clientes` ni de cartera, así que la respeta tal cual.
- **R8 — PENDIENTE PARA UN PAQUETE APARTE, no se toca aquí.** Hoy el vendedor **también puede editar** el límite, los días y la moneda de crédito de sus clientes (y la pestaña «Crédito» de la ficha se le muestra para editar). Es la decisión de crédito D-C1 de Martin. Opciones cuando se trate: A) trigger que solo deje cambiar esas columnas a Administración y Dirección; B) dejar que Comercial las capture. Evidencia: `docs/seguridad/MATRIZ-ACCION-POR-ROL.md` (acción `cli07`, regla R8).
- **Front:** el PR #75 se cerró y lo sustituye `kit-to-drive#76` (desde `main`, sin nada de la Fase 2); el #75 estaba apilado sobre el PR #74.

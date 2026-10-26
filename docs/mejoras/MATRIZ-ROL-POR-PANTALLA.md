# Matriz rol por pantalla — Paquete 1 rehecho (antes y después)

**Qué se midió:** en la réplica local, con la Fase 1 aplicada y también sin ella, con usuarios y datos sintéticos (`ensayo/resultado-paquete-1-con-fase1.json` y `…-sin-fase1.json`): para cada rol, qué filas de cada tabla ve **antes** y **después** de las 3 migraciones, y qué devuelve el catálogo básico. **Qué no se midió:** el «administrador de Comercial» se comporta como «supervisor» (`rol_comercial = supervisor`); los recorridos de pantalla los hace la persona de pruebas (`VENTANA-PAQUETE-1.md` §5).

Leyenda: **V** = solo los suyos (los asignados a él, y los de sus propias remisiones); **T** = todos; **—** = ninguno; **Cat.** = catálogo básico (id, código, folio, nombre, teléfono, activo; **sin** crédito, saldo, documentos ni cartera).

| Pantalla | Vendedor — antes | Vendedor — **después** | Supervisor / admin de Comercial | Administrativo de Comercial | Dirección | Finanzas · Almacén · Compras · Fábrica |
|---|---|---|---|---|---|---|
| **Clientes** (ficha completa, crédito, documentos) | V | **V (sin cambio)** | T | T | T | T |
| **Selector de cliente en CRM** (oportunidad, ruta, actividad) | los de V | **Cat. de TODOS los clientes** | T (ficha) | T (ficha) | T (ficha) | sin CRM |
| Cartera y crédito (`cuentas_por_cobrar`, `v_clientes_credito`) | la de V | **la de V (sin cambio)** | T | T | T | T |
| **Oportunidades** | V | V (sin cambio) | T | — | T | — |
| **Rutas** | V | V (sin cambio) | T | — | T | — |
| **Actividades** | V | V (sin cambio) | T | — | T | — |
| **Remisiones de motocarros** (y unidades) | V | V (sin cambio) | T | T | T | Finanzas, Almacén, Fábrica: T · Compras: según su política |
| **Remisiones de refacciones** | **T** | **V** | T | T | T | Finanzas, Almacén, Compras: T · Fábrica: — |
| **Entregas** | motocarros: V · refacciones: T | **V y V** | T | T | T | según sus políticas |
| **Capturar una remisión a un cliente** (por la API) | a cualquiera | **solo a un cliente que ya ve** | a cualquiera | a cualquiera | a cualquiera | — |
| Reportes de Compras / Inventario (Kardex, rotación) | sin acceso | sin acceso (no cambia) | según rol | según rol | T | T |
| **Catálogo básico** (`catalogo_clientes_basico`) | no existe | **sí** | sí | sí | sí | **no** (`42501`) |

**Lo que cambia, por rol:**
- **Vendedor:** elige cliente en CRM de **todo el catálogo** (antes, de los suyos); deja de ver las remisiones de refacciones de otros vendedores; **ya no puede capturar una remisión a un cliente que no ve**. La ficha, el crédito, el saldo, los documentos y la cartera **no cambian**: solo los de sus clientes. Un cliente **nuevo** que cree queda a su nombre.
- **Supervisor, administrativo, Dirección, Finanzas, Almacén, Compras, Fábrica:** **no cambia nada** (medido). Supervisores, administrativos y Dirección reciben también el catálogo, pero siguen leyendo la ficha completa.
- **Vendedor con cuenta de prueba:** el catálogo le devuelve **solo clientes de prueba** (medido).

**Pruebas que lo demuestran:** `ensayo/ensayar-paquete-1.py` (matriz, catálogo por rol y casos de escritura, antes y después, con y sin Fase 1), `tests/paquete-1.test.ts` y, en el front, `src/test/catalogo-basico-crm.test.ts`.

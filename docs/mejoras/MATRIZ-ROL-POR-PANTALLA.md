# Matriz rol por pantalla — Paquete 1 (antes y después)

**Qué se midió:** en la réplica local con la Fase 1 aplicada, con usuarios y datos sintéticos (`ensayo/resultado-paquete-1-con-fase1.json`): para cada rol, qué filas de cada tabla ve **antes** y **después** de las 3 migraciones. «Mismo» = idéntico antes y después. **Qué no se midió:** los roles sin fila propia en el ensayo («admin de Comercial» y «supervisor» son el mismo caso: `rol_comercial = supervisor`; Logística y Almacén se midieron como Almacén). Los recorridos de pantalla los hace la persona de pruebas (`VENTANA-PAQUETE-1.md` §5).

Leyenda: **V** = solo los suyos; **S** = los sin vendedor asignado; **T** = todos; **—** = ninguno.

| Pantalla (tabla) | Vendedor — antes | Vendedor — **después** | Supervisor / admin de Comercial | Administrativo de Comercial | Dirección / super admin | Finanzas | Compras | Almacén / Logística | Fábrica |
|---|---|---|---|---|---|---|---|---|---|
| **Clientes** | V (sus asignados + los de sus remisiones) | **V + S** | T (mismo) | T (mismo) | T (mismo) | T (mismo) | T (mismo) | T (mismo) | T (mismo) |
| Cartera y crédito del cliente (`cuentas_por_cobrar`, `v_clientes_credito`) | la de sus clientes visibles | **la de V + S** | T (mismo) | T (mismo) | T (mismo) | T (mismo) | T (mismo) | T (mismo) | T (mismo) |
| **Oportunidades** | V | V (mismo) | T | — (mismo) | T | — | — | — | — |
| **Rutas** | V | V (mismo) | T | — | T | — | — | — | — |
| **Actividades** | V | V (mismo) | T | — | T | — | — | — | — |
| **Remisiones de motocarros** (y sus unidades) | V | V (mismo) | T | T | T | T | — (por su política de Compras) | T | T |
| **Remisiones de refacciones** (partidas, órdenes, eventos) | **T** (las ve todas) | **V** | T (mismo) | T (mismo) | T (mismo) | T (mismo) | T (mismo) | T (mismo) | — (mismo) |
| **Entregas** (lee unidades de motocarros y remisiones de refacciones) | motocarros: V · refacciones: T | **V y V** | T | T | T | T | según sus políticas | T | motocarros: T |
| Reportes de Compras / Inventario (Kardex, rotación) | sin acceso | sin acceso (**no cambia**) | según rol | según rol | T | T | T | T | — |

**Lo que cambia, en una línea por rol:**
- **Vendedor:** ve además los clientes sin asignar (y su cartera) y deja de ver las remisiones de refacciones de otros vendedores. Al crear un cliente, queda a su nombre; al usar un cliente sin asignar en una oportunidad, ruta o actividad, queda a su nombre; no puede usar un cliente de otro vendedor.
- **Supervisor, administrativo, Dirección, Finanzas, Compras, Almacén, Fábrica:** **no cambia nada** (medido).

**Escritura:** ver las tablas de `PAQUETE-1-PERMISOS-VENDEDOR.md` §3. **Pruebas que lo demuestran:** `ensayo/ensayar-paquete-1.py` (matriz y casos de escritura, antes y después, con y sin Fase 1) y `tests/paquete-1.test.ts`.

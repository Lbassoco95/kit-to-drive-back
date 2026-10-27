# Catálogo básico de clientes: columnas, mecanismo y pantallas del front que leen `clientes`

**Estado: preparado, NADA APLICADO.** Decisión de Polo (26 oct 2026): el vendedor ve un catálogo **básico** de todos los clientes solo para **elegir** cliente en oportunidad, ruta y actividad; la ficha completa, el crédito, el saldo, los documentos y la cartera siguen siendo solo del vendedor dueño, supervisores, administrativos y Dirección.

## 1. Qué columnas de `clientes` son básicas y cuáles sensibles

| Grupo | Columnas de `clientes` | ¿Catálogo básico? |
|---|---|---|
| **Identificación (básicas)** | `id`, `codigo_erp`, `folio_interno`, `nombre_comercial`, `activo` | **Sí: es todo lo que devuelve** |
| Teléfono | `telefono` | **No** (quitado por decisión de Polo, 27 oct; lo lee de la ficha quien la ve) |
| Crédito | `limite_credito`, `dias_credito`, `moneda_credito` | No (sensible) |
| Fiscal y legal | `razon_social`, `rfc` | No (sensible; ver D9) |
| Contacto | `email`, `email_cobranza`, `nombre_contacto`, `cargo_contacto`, `telefono_contacto` | No (sensible) |
| Domicilio y ubicación | `direccion`, `calle`, `num_exterior`, `num_interior`, `colonia`, `municipio`, `estado`, `codigo_postal`, `pais`, `latitud`, `longitud` | No (sensible; ver D9 sobre `estado`, `municipio` y coordenadas) |
| Documentos | `doc_constancia_sf_url`, `doc_comprobante_domicilio_url`, `doc_ine_representante_url`, `doc_acta_constitutiva_url`, `doc_poder_notarial_url` y el bucket `clientes-docs` | No (sensible) |
| Internas | `vendedor_id`, `notas`, `fecha_alta`, `created_at`, `updated_at`, `es_prueba` | No |
| **Cartera y saldo (otras tablas)** | `cuentas_por_cobrar`, `cxc_abonos`, `v_clientes_credito`, `v_estado_cuenta_cliente`, cobranza y saldos a favor, `clientes_comentarios`, `clientes_bitacora` | No: siguen a «leer clientes», **sin cambio** |

`folio_interno` y `codigo_erp` son los dos códigos con que se reconoce al cliente en las listas («código · nombre»); por eso van los dos.

## 2. Mecanismo: función de solo lectura `catalogo_clientes_basico()`

- **Sin parámetros**, devuelve únicamente las 5 columnas básicas, ordenadas por folio, código e id (orden estable para leerla por tramos de mil).
- **Quién la ejecuta:** `authenticated` (con permiso explícito) y `service_role`; **`anon` no**. Dentro, solo quien trabaja en Comercial (operador, supervisor o administrador global) o en Dirección, y activo; otro rol recibe `42501`.
- **Modo prueba:** un usuario de prueba solo ve clientes de prueba (misma regla que su política de lectura).
- **`SECURITY DEFINER` es necesario aquí y es el único que se agrega** (el trigger de remisiones es INVOKER): la política «leer clientes» oculta por diseño las filas de otros vendedores, así que sin saltarla la función devolvería 0 filas. Con `search_path` fijo y las 6 columnas escritas a mano (sin `*`); un test del repo falla si se agrega una columna sensible.
- **Por qué no una vista:** una vista `security_invoker` devolvería 0 filas por la misma razón; una vista sin `security_invoker` rompería el estado «18 de 18 vistas con security_invoker» de la Fase 1 y dispara el aviso de seguridad de Supabase. **Por qué no una tabla copia:** duplica datos y exige un trigger de sincronía. **Por qué no permisos por columna:** quitar columnas a `authenticated` rompería a todo el que hoy lea `clientes`.
- **Compuerta (`kit-to-drive-front`):** alta de `catalogo_clientes_basico` en `RPCS`. En la rama actual del back de la compuerta hay **67 tablas y vistas y 60 RPC**; con esta alta quedan **61 RPC**. *(Las cifras «71 y 85» que mencionaste no coinciden con la rama `claude/busy-allen-temk9b`: puede que vengan de otra versión; dime cuál es la vigente.)*

## 3. Pantallas del front que leen `clientes` y cuáles se ven afectadas

**Lecturas directas de la tabla `clientes`** (por política de lectura, que **no cambia**):

| Pantalla | Cómo lee | ¿Afectada? | Qué pasa |
|---|---|---|---|
| **Clientes** (`Clientes.tsx`) | `cargarClientes()` (ficha completa) y altas/ediciones | **No cambia su código.** Para un vendedor sin clientes asignados **sigue diciendo «0 de 0»**: es el criterio 2 (la ficha es del dueño) | Ver D8: el texto vacío podría explicarlo |
| **CRM · Oportunidades** | selector y nombres | **Sí, cambiada** | Lee el catálogo básico **+** la ficha de los que ve |
| **CRM · Rutas** | selector, nombres, coordenadas del check-in | **Sí, cambiada** | Igual; las coordenadas se leen de la ficha solo si el rol la ve (**y ya no se guarda ubicación encima de un cliente que solo trae el renglón básico**) |
| **CRM · Actividades** | selector, nombres, estado y municipio al completar una visita | **Sí, cambiada** | Igual; estado y municipio salen de la ficha si el rol la ve |
| **CRM · Tracker** | nombres y códigos de clientes | **Sí, cambiada** | Catálogo básico + ficha |
| **CRM · Detalle de oportunidad** | `select("*")` de un cliente con `.single()` | **Sí, cambiada** | Antes mostraba «sin cliente» para un cliente que el vendedor no ve (el `single()` no devolvía fila); ahora usa la ficha si la ve y si no el renglón básico |
| **Remisiones** (alta) | `cargarClientes()` para elegir cliente; alta de cliente en línea | No cambia | El vendedor elige entre los clientes que ve (los suyos). Sin clientes asignados no puede capturar remisión por la pantalla **hasta que se le asignen** (D6, tarea de Martin) |
| **Remisiones de refacciones** | `cargarClientes()` | No cambia | Igual que arriba |
| **Cobranza** | `cargarClientes()` (filtro de cliente) | No (finanzas ve todo) | — |
| Buscador global (`Buscar`, `PaletaGlobal`) | busca en `clientes` | No cambia | El vendedor solo encuentra sus clientes (D10: ¿buscar también en el catálogo?) |
| Finanzas (`ContraparteSelector`), Importar | lectura/alta de clientes | No | — |

**Lecturas indirectas** (`clientes(...)` embebido dentro de una remisión o unidad): `BandejaRemisiones`, `MisMotocarros`, `Entregas`, `Produccion`, `busquedaUnidades`, buscadores. **No cambian**: el cliente de una remisión propia lo ve el vendedor por la regla «los clientes de mis propias remisiones» (D1, se conserva).

**Orden de publicación:** no importa. El front intenta el catálogo y, si la RPC no existe todavía o el rol no tiene acceso, **se queda con lo que ya leía** (la ficha). Probado con pruebas.

## 4. Lo que el catálogo NO resuelve (consecuencias de la decisión)

1. **Un vendedor sin clientes asignados** no ve nada en **Clientes** ni puede elegir cliente al **capturar una remisión**; solo puede elegir en oportunidad, ruta y actividad. Se corrige asignando clientes (tarea de Martin).
2. **Las 16 remisiones de motocarros sin vendedor** no las ve ningún vendedor, solo supervisores y administrativos.
3. **Puerta cerrada:** el catálogo le da al vendedor el `id` de todos los clientes. Como «leer clientes» abre la ficha de los clientes de las propias remisiones, un vendedor podía capturar por la API una remisión a **cualquier** cliente y abrir su ficha (crédito, saldo, documentos). **Probado en el ensayo** (antes del paquete lo logra; después, no). La migración 2 agrega un trigger que lo cierra: el vendedor solo captura una remisión a un cliente que **ya ve**. La pantalla nunca lo permitió.

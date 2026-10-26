# Diagnóstico: por qué el vendedor ve «0 de 0 clientes» y por qué «los vendedores ven todas las remisiones»

**Solo lectura; no se aplicó nada.** Todo sale de las políticas de producción del respaldo del 25 oct 2026 (`docs/seguridad/respaldo/politicas-public-y-storage.sql`, capturado de producción) y de las migraciones del repo. **Qué falta confirmar con datos de producción:** los bloques SQL de la §4, que corre Polo.

## 1. Qué decide hoy qué ve un vendedor (rol Comercial / Operador)

| Qué | Política o función | Regla para el vendedor | Origen |
|---|---|---|---|
| **Clientes** (leer) | `leer clientes` | Solo los de `vendedor_id = él`, o los clientes de **sus propias remisiones**. Supervisores (`ve_todo_comercial`), administrativos, Dirección, Administración, Fábrica, Almacén, Compras y Finanzas ven todos | `20261007000002_vendedor_clientes_credito.sql` |
| Clientes (leer, administrativos) | `administrativo comercial lee clientes` | Quien tenga `profiles.es_administrativo` en Comercial ve todos | `20261020000002_administrativas_ven_todas_remisiones.sql` |
| Clientes (crear) | `comercial crea clientes` | **Cualquier** usuario de Comercial, Administración o admin global; **no** comprueba a nombre de quién queda (`vendedor_id` puede ir vacío o ser de otro) | `20260823000005_usuarios_niveles_areas.sql` |
| Clientes (editar) | `actualizar clientes`, `comercial supervisa clientes` | Un operador de Comercial **no** edita clientes (solo roles heredados `ventas`/`auxiliar_ventas` sobre los suyos, y supervisores) | `20260823000005_usuarios_niveles_areas.sql` (supervisores); `20260717000003_clientes_expediente_digital.sql` (roles heredados) |
| Comentarios, bitácora, documentos del cliente, cartera (`cuentas_por_cobrar`, `cxc_abonos`, `v_clientes_credito`) | `… IN (SELECT … FROM clientes)` | **Siguen a «leer clientes»**: ven lo de los clientes que ven | `20261007000002` |
| **Oportunidades, actividades, rutas** (leer) | `crm_oport_select`, `crm_act_select`, `crm_rutas_select` | Solo las de `vendedor_id = él`; supervisores y admin, todas | `20261007000003_vendedor_crm_asignacion.sql` |
| CRM (crear) | `crm_*_insert` **y** `crm_*_insert_area` | La primera exige `vendedor_id = él`; la segunda (`es_area comercial`) **no pide nada**, y las políticas permisivas se suman: en la práctica **cualquiera de Comercial inserta a nombre de cualquiera y con cualquier cliente**, sin comprobar que lo ve | 20261007000003 + `*_insert_area` (sin migración en el repo) |
| Paradas de ruta | `crm_paradas_all` y `crm_ruta_paradas_*` | Siguen a la ruta visible | 20261007000003 |
| **Remisiones de motocarros** | `comercial lee remisiones`, `leer remisiones por rol` | Solo `vendedor_id = él`. Ven todas: supervisores/admin de Comercial, administrativos (`es_administrativo_comercial`), Dirección, Administración, Compras que supervisa, Fábrica, Logística, coordinadores, Finanzas | `20261007000001_vendedor_solo_su_informacion.sql`, `20261008000001`, `20261020000002` |
| Unidades (`motocarros`) y partidas | `comercial lee motocarros`, `remision_items_select` | Siguen a la remisión (solo las suyas) | 20261007000001 |
| **Remisiones de refacciones** (y sus partidas, órdenes, eventos, correcciones) | `leer remisiones refacciones` → `puede_leer_remision_refaccion()` | **Todo usuario del área comercial las lee todas**: la función termina en `RETURN _area IN ('direccion','administracion','almacen_logistica','comercial')` | `20260925000001_remision_refacciones_seguimiento.sql` |

Definiciones auxiliares: `ve_todo_comercial(uid)` = `supervisa_area(uid,'comercial')` = nivel supervisor o admin en Comercial, o admin de Dirección (`20261007000001`, `20260824000003`). `rol_comercial(uid)` devuelve `global`, `supervisor`, `operador` o `ninguno` (`20260902000001`).

## 2. El motivo exacto de «0 de 0 clientes»

La política `leer clientes` deja al operador de Comercial ver solo los clientes cuyo `vendedor_id` es él (o los de sus propias remisiones). Si **ninguno de los 1,786 clientes** tiene a Carlos como vendedor ni tiene una remisión suya, la lista queda en 0, y el selector de «nueva oportunidad» lee esa misma lista (catálogo filtrado por la política): de ahí «No hay clientes en el catálogo». **No es un error de pantalla: es la política funcionando sobre datos que nunca se asignaron.** Es lo que se espera si los clientes se importaron sin vendedor (`vendedor_id` vacío). Lo confirma el bloque 1 y el bloque 2 de la §4.

## 3. El motivo de «los vendedores ven todas las remisiones» (dos causas distintas)

1. **Remisiones de refacciones: confirmado en el código.** Cualquier usuario de Comercial las ve todas (`puede_leer_remision_refaccion`). Las de motocarros no. Las dos reglas **son incoherentes entre sí**: la de motocarros se endureció el 7 oct («el vendedor solo ve su información»), la de refacciones nunca. El comentario de `20261020000002` lo registra como si fuera una regla: «las remisiones de refacciones ya las ve toda el área comercial».
2. **Remisiones de motocarros: depende de los datos.** Un vendedor las ve todas **si tiene nivel supervisor/admin en Comercial** o **si tiene la casilla «Administrativo»**. Martin dice que hoy sube de rol a los vendedores como parche (por ejemplo a supervisor) para que «vean clientes»: eso les da `ve_todo_comercial`, y entonces ven **todos** los clientes, remisiones, oportunidades, rutas y actividades del equipo. El bloque 3 de la §4 cuenta cuántos usuarios de Comercial hay en cada nivel y cuántos son administrativos.

## 4. SQL de solo lectura para confirmarlo (los corre Polo en el SQL Editor y pega el resultado)

Cada bloque es independiente, de solo lectura (`begin read only; … rollback;`) y devuelve **solo conteos e indicadores**. No muestran nombres ni correos: el nombre «chavarr» se usa solo como filtro en el bloque 2. Si el editor solo muestra «Success. No rows returned», borra las dos líneas de los extremos (`begin read only;` y `rollback;`) y corre solo el `select`.

### Bloque 1 — clientes con y sin vendedor asignado

**Esperado:** `clientes_total` = 1786 (más los que se hayan agregado), `sin_vendedor` cercano a `clientes_total` (esto explica los «0 de 0»), `con_vendedor` pequeño.

```sql
begin read only;
select count(*) as clientes_total,
       count(*) filter (where vendedor_id is not null) as con_vendedor,
       count(*) filter (where vendedor_id is null) as sin_vendedor,
       count(distinct vendedor_id) as vendedores_con_clientes,
       count(*) filter (where activo) as activos
from public.clientes;
rollback;
```

### Bloque 2 — indicadores del perfil de Carlos (sin nombre ni correo)

**Esperado:** `perfiles_que_coinciden` = 1; `area` = `comercial`, `nivel` = `operador`; `escalera_comercial` = `operador`; `ve_todo_comercial` = `false`; `clientes_asignados` = 0 y `remisiones_como_vendedor` = 0 (esto confirma la causa de los «0 de 0»). **Si sale distinto:** `ve_todo_comercial` = `true` o `nivel` = `supervisor` significa que ya tiene el parche y no debería ver «0 de 0»; `perfiles_que_coinciden` mayor a 1 significa que el filtro por apellido toma a más de una persona y hay que afinarlo.

```sql
begin read only;
select count(*) over () as perfiles_que_coinciden,
       ur.area, ur.nivel, ur.role as rol_legado, p.activo, p.es_vendedor, p.es_administrativo,
       public.rol_comercial(p.id) as escalera_comercial,
       public.ve_todo_comercial(p.id) as ve_todo_comercial,
       public.es_administrativo_comercial(p.id) as administrativo_comercial,
       (select count(*) from public.user_roles x where x.user_id = p.id) as filas_de_rol,
       (select count(*) from public.clientes c where c.vendedor_id = p.id) as clientes_asignados,
       (select count(*) from public.remisiones r where r.vendedor_id = p.id) as remisiones_como_vendedor,
       (select count(*) from public.remisiones_refacciones r where r.vendedor_id = p.id) as remisiones_refacciones_como_vendedor
  from public.profiles p
  left join public.user_roles ur on ur.user_id = p.id
 where p.nombre_completo ilike '%chavarr%';
rollback;
```

### Bloque 3 — cuántos usuarios de Comercial hay en cada nivel

**Esperado:** unos pocos con `nivel` = `operador` y `es_administrativo` = `false` (vendedores) y los demás supervisores o administrativos. Si hay **vendedores con nivel `supervisor` o `admin`**, ese es el parche de Martin: esos usuarios hoy ven todo.

```sql
begin read only;
select ur.area, ur.nivel, p.es_administrativo, p.es_vendedor, count(*) as usuarios_activos
  from public.user_roles ur join public.profiles p on p.id = ur.user_id
 where ur.area = 'comercial' and p.activo is not false
 group by 1, 2, 3, 4 order by 2, 3, 4;
rollback;
```

### Bloque 4 — remisiones sin vendedor

**Esperado:** `motocarros_sin_vendedor` y `refacciones_sin_vendedor` en 0 o muy pocos. Una remisión sin vendedor no la ve ningún vendedor (solo supervisores, administrativos, etc.).

```sql
begin read only;
select (select count(*) from public.remisiones) as remisiones_motocarros,
       (select count(*) from public.remisiones where vendedor_id is null) as motocarros_sin_vendedor,
       (select count(*) from public.remisiones_refacciones) as remisiones_refacciones,
       (select count(*) from public.remisiones_refacciones where vendedor_id is null) as refacciones_sin_vendedor;
rollback;
```

## 5. Hallazgos adicionales (no cambian lo pedido)

- **Las tablas de CRM de producción no coinciden con las migraciones del repo.** Producción tiene columnas que ninguna migración crea (`titulo`, `fecha_ruta`, `created_by`, `checkin_*`…) y políticas `crm_*_insert_area` / `*_update_area` / `*_delete_area` sin migración. Ya estaba anotado en `docs/seguridad/HISTORIAL-MIGRACIONES-HALLAZGO.md` (hallazgo D1). Para ensayar con la forma real, `docs/mejoras/ensayo/crm-columnas-produccion.json` trae solo el esquema de producción de esas 4 tablas.
- **Regla de clientes de remisiones propias** (la cláusula `EXISTS … remisiones … vendedor_id = él` de `leer clientes`): es distinta del criterio «nunca ve clientes asignados a otro vendedor». Se conserva sin cambio y se reporta en `PAQUETE-1-PERMISOS-VENDEDOR.md`, decisión D1.

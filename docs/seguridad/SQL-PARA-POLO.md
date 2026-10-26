# SQL de solo lectura para Polo — todo en un solo documento

**Estado: NADA APLICADO.** Generado por `scripts/ventana/generar-sql-para-polo.py` a partir de `docs/seguridad/consultas/` (si cambia una consulta, se regenera este archivo).

## Reglas de este modo de trabajo

1. **Claude no usa el conector de Supabase de claude.ai para nada, ni para leer.** Esto se repite en cada reporte.
2. Claude **no ve producción**. Polo corre cada bloque en el **SQL Editor** de Supabase y **pega el resultado** en la sesión.
3. Todo bloque es de **solo lectura**: va envuelto en `begin read only; … rollback;`. Si alguna instrucción intentara escribir, Postgres la rechaza.
4. Solo se piden **conteos, huellas (md5) y catálogo**. Ningún bloque devuelve filas con datos de personas, correos, contraseñas ni el texto de migraciones. **Si un resultado trae algo que parezca un dato personal o un secreto, no lo pegues** y avísame.
5. No hay nada que escribir en ninguna base. Los bloques no crean tablas ni funciones.
6. **Todo SQL que se le pide a Polo va pegado completo en el chat**, en un bloque propio, con una línea de «resultado esperado». Este archivo es el respaldo en el repo, no la forma de entregarlo.

## Cómo correr un bloque (una vez por bloque)

1. Abre el proyecto **`kit-to-drive`** (ref `dmhzhyeivvuliumcgsmm`) — **no** `kit-to-drive-db-qa`. El primer bloque (0) lo comprueba: debe decir `zz_lista_oct = 2219` y `super_admins = 2` (a la fecha del 26 oct; si cambiaron por actividad, dilo).
2. SQL Editor → *New query* → pega **un solo bloque** completo (de `begin read only;` a `rollback;`) → *Run*.
3. Copia el resultado (botón *Copy as Markdown* o *Copy as CSV* de la cuadrícula) y pégalo en la sesión, **con el nombre del bloque** (por ejemplo «A2»).
4. **Si el editor solo muestra «Success. No rows returned»** (puede mostrar únicamente la última instrucción, que es `rollback;`): borra **las dos líneas de los extremos**, `begin read only;` y `rollback;`, y corre solo el `select`. Es una sola lectura: no escribe. **No borres solo el `rollback;`**: dejaría una transacción abierta que podría estorbar a la ventana. Dímelo y reescribo los bloques. *No he podido probar el editor de Supabase desde aquí; los bloques sí los probé en una réplica local de PostgreSQL 16.*

## Orden

| Bloque | Qué mide | Qué me devuelves |
|---|---|---|
| 0 | Salud previa y comprobación de que es producción | 1 fila |
| A1 | ¿Cambió algo desde la foto del 25 oct? | solo las tablas distintas (o vacío) |
| A2 | **Foto fresca antes de la ventana** (compacta) | 1 fila con una celda larga: pégala entera |
| A3 | Auth y Storage (conteos y huellas) | ~15 filas |
| B1–B3 | Historial de migraciones, solo lo que afecta a la Fase 1 y 2 | 1 tabla de 34 filas + 2 pequeñas |
| C | Puente de Patio (constancia) | 1 fila |
| D1 | Conteos de permisos (línea base del catálogo) | 1 fila ancha |
| D2 | Errores de las últimas 24 h (Logs Explorer) | 2 tablas pequeñas |

Corre A1–A3 y 0 **el día de la ventana, antes de empezar** (y los de A y D1 otra vez después de cada paso, según el runbook). B, C y D se pueden correr hoy.

---

## 0. Salud previa y comprobación de producción

```sql
begin read only;
select now() as medido_en,
       current_database() as base,
       (select count(*) from public.zz_lista_oct) as zz_lista_oct,
       (select count(*) from public.super_admins) as super_admins,
       (select count(*) from pg_stat_activity where datname = current_database()) as conexiones,
       (select count(*) from pg_stat_activity where datname = current_database() and state <> 'idle') as conexiones_activas,
       (select coalesce(max(now() - xact_start), interval '0') from pg_stat_activity where datname = current_database() and xact_start is not null and pid <> pg_backend_pid()) as transaccion_mas_larga,
       (select count(*) from pg_locks where not granted) as bloqueos_esperando,
       pg_size_pretty(pg_database_size(current_database())) as tamano_base,
       current_setting('statement_timeout') as statement_timeout,
       current_setting('lock_timeout') as lock_timeout;
rollback;
```

Esperado: `base` = `postgres`; `zz_lista_oct` = 2219 y `super_admins` = 2; `transaccion_mas_larga` de segundos; `bloqueos_esperando` = 0.

---

## A. Foto de integridad

### A1. Comparación con la foto del 25 oct (`integridad/antes-tablas.txt`)

Devuelve **solo** las tablas cuyo conteo o huella no coincide. **Resultado vacío = la información se mantuvo igual.** Cada fila distinta se explica con la fecha/hora de creación de sus filas (la pido después).

```sql
begin read only;
with tabs as (select c.oid, c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','p')),
pk as (select i.indrelid, string_agg(quote_ident(a.attname), ',' order by array_position(i.indkey::int2[], a.attnum)) cols from pg_index i join pg_attribute a on a.attrelid=i.indrelid and a.attnum = any(i.indkey::int2[]) where i.indisprimary group by i.indrelid),
vivo as (select t.relname,
 (xpath('/row/n/text()', query_to_xml(format('select count(*) n from public.%I', t.relname), false, true, '')))[1]::text::bigint as filas,
 (xpath('/row/h/text()', query_to_xml(format('select coalesce(md5(string_agg(x::text, ''|'' order by %s)), ''vacia'') h from public.%I x', coalesce(pk.cols, 'x::text'), t.relname), false, true, '')))[1]::text as huella
from tabs t left join pk on pk.indrelid=t.oid),
antes as (select split_part(l,'|',1) relname, split_part(l,'|',2)::bigint filas, split_part(l,'|',3) huella from unnest(array[
'abc_leyenda_combinaciones|9|542c4d75c18c52266284ec00e192ba0a',
'ajuste_inventario_lineas|1053|53501aaaebf460e588de98fc00b4f100',
'ajustes_inventario|11|2360bb03d19f3e7b05f77bdb239ddc7d',
'almacen_refacciones_acceso|3|99e76cce875c7837481609964d038713',
'almacen_refacciones_codigos|2925|c792d0226ed6b8ec70d040b8f00631a8',
'almacen_refacciones_movimientos|1079|207ca9473777e57354ab7497956e09db',
'almacen_refacciones_producto_compat|5065|fbd6989e27238eebf23e425599646615',
'almacen_refacciones_productos|2237|d400652a1693bd0579ea848623285090',
'almacen_refacciones_unidad_alias|0|vacia',
'almacen_refacciones_unidades|1858|03ad1c8f2a284141c7ffa706a9f723c4',
'altas_autorizadas|0|vacia',
'app_modulos|26|84bfe09de093b885d46074bef9a3c6aa',
'avisos|15|2ab97636abd38a27ef1568baa9c74933',
'bitacora_color|67|9015d8228497164208fde7c4510e26c4',
'bitacora_compras_inventario|42|352ce0943292ea7e5b59b5e51e6caef1',
'bitacora_eliminaciones|6|7d4b5689a2dfcda11a59116af46445a8',
'bitacora_eventos|460|01afcbf92d5996f9888952fad1f0bf52',
'bitacora_orden_armado|0|vacia',
'bitacora_super_admin|258|f5e33ee7d5897aa616b53aabba7511fa',
'bridge_bitacora|3|a9e1e8660c70df6c84aa9ab9d7140f4b',
'categorias_financieras|18|263d3bd9054ece4a90b3f33f0acf67a7',
'clientes|1786|d45426afd6192450518064854b0c8d9f',
'clientes_bitacora|13|f0c44f45a0a11f6a88eb44630bbf3796',
'clientes_comentarios|0|vacia',
'cobranza_aplicaciones|6|bb2af8d589380d39abcb31e3fb995291',
'cobranza_pagos|3|866cab1b9dd61b22f579e4aa66e1545f',
'cobranza_saldos_favor|6|8f81087c865b65bfad91e6cc01befaf5',
'cobranza_solicitudes_saldo|0|vacia',
'comentarios_motocarros|2|fbb50661715948891f6c4b4c50f6bbcb',
'compra_lineas|0|vacia',
'compra_refaccion_lineas|1|3363892423806409772a483eee6b551c',
'compra_refaccion_pendientes|0|vacia',
'compras|0|vacia',
'compras_folios|5|7aaaad3858e2a13c9a570ca587fd7624',
'compras_parametros|10|1d843ed19429072ff990847bcfe63905',
'compras_refacciones|1|38ae6f3fea1a67b994eeb31b5d5ba090',
'config_general|1|d2a42cc848162f021271742c23fb689f',
'contenedor_partes|0|vacia',
'contenedores|5|1f4ee00ba412a6e32cbb4916b15fe087',
'crm_actividades|4|50f8d6642a996df93c09a9c55b70c051',
'crm_oportunidades|2|63032ae967349bd46ed3a3f405fb205d',
'crm_ruta_paradas|11|f86b8f48d6fffca0ea1253490c53cea7',
'crm_rutas|7|c09e0b90e155e1334c3092ece7b94b63',
'cuentas_financieras|3|68389d3cfbea786c10c87d0c378f757e',
'cuentas_por_cobrar|2|41c7d998fc361a90312c1754dcb8c3c7',
'cxc_abonos|1|77841ebb26c1e844ffc82234c2a7db5f',
'documento_inventario_lineas|0|vacia',
'documentos_inventario|0|vacia',
'firmas_firmantes|0|vacia',
'firmas_solicitudes|0|vacia',
'flujo_capacidades|3|fac380f925c231edf2d60d16fcfb4094',
'flujo_dinero|0|vacia',
'historial_conexiones|109|83f32dd51ec3dd7340a87a6b45de469c',
'incidencias_chasis|0|vacia',
'incidencias_chasis_eventos|0|vacia',
'inventario_almacenes|3|36d19af1e4b7fbf7c95d80309797debd',
'inventario_chasis|155|7a243c52ebbac578d8cba435ec239939',
'inventario_colores|11|0f0d57351040a54e6d139dae9a33a594',
'inventario_motivos_ajuste|6|805f45e9994ae1750f40d1b218164c21',
'inventario_motor|155|302dfb987d8b15a101cbbec1d941765f',
'inventario_partes|0|vacia',
'inventario_reglas_modo_prueba|43|24559ec8553658961d64973c51629b5a',
'inventario_unidades_venta|5|c57e19f772a7a883665ed759d1fe32a2',
'inventario_usuarios_prueba|7|4f192ca099b3da1aeb8e211c1894567c',
'migraciones_aplicadas|90|0478424ffd54a0357fef15c395c9ee3b',
'modelos_producto|5|673f4c1d8f47135a9f535989b0af4aea',
'motocarros|183|5567a6b5ffa6f1901ae975f833025ab2',
'movimiento_adjuntos|0|vacia',
'movimiento_bitacora|0|vacia',
'movimientos_financieros|0|vacia',
'notificaciones|37|a108aafd3ccd3659a16dbde66994c60e',
'pagos|0|vacia',
'profiles|26|a3149603bead1f99225ac9f1c0d9681f',
'proveedores|1|dc976c81a4a7cdff0439f6cf1029d9f8',
'recepcion_refaccion_lineas|0|vacia',
'recepciones_refacciones|0|vacia',
'remision_items|104|fc560da92da550ce62d8655f0e41bba9',
'remision_refaccion_correcciones|26|2e3ed9b311c8dbf0ff9887d4d36df240',
'remision_refaccion_eventos|92|265227272d41fbecbf5ea59217afc26f',
'remision_refaccion_items|32|c3c4cc7e9894f8aed3c7c2037f116a68',
'remision_refaccion_ordenes|16|1caf5f405f8ea8aa7f798112897a644a',
'remisiones|93|7b7ceace6bab81e699a733176deb87fb',
'remisiones_asignacion_acceso|1|cea74ab5549a0466f28a92b8505ac3f7',
'remisiones_bitacora|125|cc3f4a64ef0b1d37213acef419def1a6',
'remisiones_refacciones|15|e0bcb1b482f7f87cc235b7595a9b6bdf',
'reportes_turno|7|9aacf148154a65dae4ff3e6de53111c6',
'solicitudes_aprobacion|7|4f74c4c2d79e6adea7052154b0d903d1',
'soporte_mensajes|1|2641f7536d08a3986de6fb10ae1a97b7',
'soporte_tickets|1|c7f83beb7b1657c40b06501cb3b9529b',
'super_admins|2|5354475effe5675da1627a42f4edb16d',
'tareas|1|8e1fcd02bcf412f97073e8a4468310c9',
'user_roles|25|8a8c0b7e252a899f80e4494a1aec7008',
'zz_lista_oct|2219|6f402bf731f346b6ff527d10045f2336']) l)
select coalesce(a.relname, v.relname) as tabla, a.filas as filas_antes, v.filas as filas_ahora,
       case when a.relname is null then 'tabla NUEVA' when v.relname is null then 'tabla FALTA'
            when a.filas <> v.filas then 'cambió el número de filas' else 'cambió el contenido (misma cantidad de filas)' end as diferencia
from vivo v full join antes a on a.relname = v.relname
where a.relname is null or v.relname is null or a.filas <> v.filas or left(v.huella, length(a.huella)) <> a.huella
order by 1;
rollback;
```

### A2. Foto fresca antes de la ventana (formato compacto)

Una fila: `medido_en`, `tablas`, `filas_total`, `huella_global` y `detalle_compacto` (`tabla|filas|huella12;…`). **Pega la fila entera**; yo la guardo como `integridad/antes-ventana-fase-1.txt` y de ahí salen las comparaciones de después de cada paso (`generar-comparacion.py` acepta este formato).

```sql
begin read only;
with tabs as (select c.oid, c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','p')),
pk as (select i.indrelid, string_agg(quote_ident(a.attname), ',' order by array_position(i.indkey::int2[], a.attnum)) cols from pg_index i join pg_attribute a on a.attrelid=i.indrelid and a.attnum = any(i.indkey::int2[]) where i.indisprimary group by i.indrelid),
r as (select t.relname,
 (xpath('/row/n/text()', query_to_xml(format('select count(*) n from public.%I', t.relname), false, true, '')))[1]::text::bigint as filas,
 (xpath('/row/h/text()', query_to_xml(format('select coalesce(md5(string_agg(x::text, ''|'' order by %s)), ''vacia'') h from public.%I x', coalesce(pk.cols, 'x::text'), t.relname), false, true, '')))[1]::text as huella
from tabs t left join pk on pk.indrelid=t.oid)
select now() as medido_en, count(*) as tablas, sum(filas) as filas_total,
 md5(string_agg(relname||'|'||filas||'|'||huella, E'\n' order by relname)) as huella_global,
 string_agg(relname||'|'||filas||'|'||left(huella,12), ';' order by relname) as detalle_compacto,
 md5(string_agg(relname||'|'||filas||'|'||left(huella,12), ';' order by relname)) as huella_del_detalle
from r;
rollback;
```

### A3. Auth y Storage

Se compara con `integridad/antes-auth-storage.txt` (referencia del 25 oct: `auth.users` 26, 0 bloqueados; `identities` 28; `storage.objects` 72).

```sql
begin read only;
select 'auth.users' as objeto, count(*)::text as total,
  count(*) filter (where banned_until is null or banned_until < now())::text as activos_no_bloqueados,
  count(*) filter (where banned_until is not null and banned_until >= now())::text as bloqueados,
  count(*) filter (where email_confirmed_at is not null)::text as confirmados,
  md5(string_agg(id::text||'|'||coalesce(email,'')||'|'||created_at::text||'|'||coalesce(banned_until::text,'')||'|'||coalesce(raw_app_meta_data::text,'')||'|'||coalesce(raw_user_meta_data::text,''), E'\n' order by id)) as huella_sin_contrasena,
  md5(string_agg(id::text||'|'||coalesce(encrypted_password,''), E'\n' order by id)) as huella_contrasenas
from auth.users
union all select 'auth.identities', count(*)::text, null, null, null, md5(string_agg(id::text||'|'||user_id::text||'|'||provider, E'\n' order by id)), null from auth.identities
union all select 'auth.sessions', count(*)::text, count(*) filter (where not_after is null or not_after > now())::text, null, null, null, null from auth.sessions
union all select 'auth.refresh_tokens', count(*)::text, count(*) filter (where not revoked)::text, null, null, null, null from auth.refresh_tokens
union all select 'auth.mfa_factors', count(*)::text, null, null, null, null, null from auth.mfa_factors
union all select 'storage.buckets', count(*)::text, null, null, null, md5(string_agg(id||'|'||public::text||'|'||coalesce(file_size_limit::text,'')||'|'||coalesce(allowed_mime_types::text,''), E'\n' order by id)), null from storage.buckets
union all select 'storage.objects total', count(*)::text, sum(coalesce((metadata->>'size')::bigint,0))::text, null, null, md5(string_agg(bucket_id||'|'||name||'|'||coalesce(metadata->>'size','')||'|'||coalesce(metadata->>'eTag',''), E'\n' order by bucket_id, name)), null from storage.objects
union all select 'storage.objects ['||bucket_id||']', count(*)::text, sum(coalesce((metadata->>'size')::bigint,0))::text, null, null, md5(string_agg(name||'|'||coalesce(metadata->>'size','')||'|'||coalesce(metadata->>'eTag',''), E'\n' order by name)), null from storage.objects group by bucket_id
order by 1;
rollback;
```

---

## B. Historial de migraciones (solo lo que afecta a aplicar la Fase 1 y la Fase 2)

Qué respondo con esto: **quién y cuándo** aplicó cada migración (`created_by`, si la versión de Supabase lo guarda), si **algo de la Fase 1/2 ya figura** en el registro, y si el historial anterior ya cambió **permisos, `search_path` o `TRUNCATE`** (lo que la Fase 1 toca). Ningún bloque devuelve texto de sentencias.

### B1. Historial de la CLI: quién y cuándo (la versión es la fecha UTC en que se aplicó)

```sql
begin read only;
select s.version,
       to_timestamp(s.version, 'YYYYMMDDHH24MISS') at time zone 'utc' as aplicada_utc,
       s.name,
       to_jsonb(s) ->> 'created_by' as created_by,
       array_length(s.statements, 1) as sentencias
  from supabase_migrations.schema_migrations s
 order by s.version;
rollback;
```

### B2. Registro propio (migraciones_aplicadas): resumen por estado, las 12 más recientes y si algo de la Fase 1/2 ya figura (una sola consulta: tipo = resumen | reciente | fase1o2)

```sql
begin read only;
select * from (
  select 'resumen' as tipo, estado as dato1, count(*)::text as dato2, min(script) as dato3, max(script) as dato4 from public.migraciones_aplicadas group by estado
  union all
  (select 'reciente', script, estado, aplicada_at::text, null from public.migraciones_aplicadas order by script desc limit 12)
  union all
  select 'fase1o2', script, estado, null, null from public.migraciones_aplicadas where script like '2026103%' or script like '202611%'
) x
order by case tipo when 'resumen' then 1 when 'reciente' then 2 else 3 end, dato1 desc;
rollback;
```

### B3. ¿Algún historial anterior ya tocó lo que la Fase 1 cambia? (banderas por migración, sin texto)

```sql
begin read only;
select s.version, s.name,
       array_to_string(s.statements, E'\n') ~* 'alter\s+default\s+privileges' as default_privileges,
       array_to_string(s.statements, E'\n') ~* '\mrevoke\M'                    as revoke_,
       array_to_string(s.statements, E'\n') ~* '\mgrant\M'                     as grant_,
       array_to_string(s.statements, E'\n') ~* 'search_path'                   as search_path,
       array_to_string(s.statements, E'\n') ~* '\mtruncate\M'                  as truncate_
  from supabase_migrations.schema_migrations s
 where array_to_string(s.statements, E'\n') ~* '(alter\s+default\s+privileges|\mrevoke\M|search_path|\mtruncate\M)'
 order by s.version;
rollback;
```

---

## C. Puente de Patio (constancia)

Polo ya confirmó que no existe. Esto lo deja por escrito (no muestra ningún valor). Esperado: `NULL`, `0`, `0` o `1`, `0`.

```sql
begin read only;
select to_regclass('public.patio_bridge_secret') as tabla_patio_bridge_secret,
       (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname like '%patio%') as funciones_patio,
       (select count(*) from public.migraciones_aplicadas where script like '20261009000002%') as registrada_20261009000002,
       (select count(*) from supabase_migrations.schema_migrations where name ilike '%patio%') as historial_cli_con_patio;
rollback;
```

---

## D. Otras mediciones pendientes de la Parte A

### D1. Conteos de permisos (línea base del catálogo)

Es la medición que se repite idéntica antes y después de cada paso. Referencia del 25 oct en `LINEA-BASE-2026-10-25.md`.

```sql
begin read only;
with t as (select c.oid, c.relname, c.relkind, c.relrowsecurity, c.reloptions
             from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public'),
f as (select p.oid, p.proname, p.prosecdef, p.proconfig
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.prokind in ('f', 'p'))
select
 (select count(*) from t where relkind in ('r','p')) as tablas_public,
 (select count(*) from t where relkind in ('r','p') and relrowsecurity) as tablas_con_rls,
 (select count(*) from t where relkind = 'v') as vistas,
 (select count(*) from t where relkind = 'v' and coalesce(reloptions::text,'') ~ 'security_invoker=(true|on)') as vistas_security_invoker,
 (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'bkp' and c.relkind in ('r','p')) as tablas_bkp,
 (select count(*) from f) as funciones_total,
 (select count(*) from f where prosecdef) as funciones_secdef,
 (select count(*) from f where prosecdef and has_function_privilege('authenticated', oid, 'EXECUTE')) as secdef_ejecutables_authenticated,
 (select count(*) from f where has_function_privilege('anon', oid, 'EXECUTE')) as funciones_ejecutables_anon,
 (select coalesce(string_agg(proname, ', ' order by proname), '-') from f where has_function_privilege('anon', oid, 'EXECUTE')) as nombres_ejecutables_anon,
 (select count(*) from f where proconfig is null or not exists (select 1 from unnest(proconfig) x where x like 'search_path=%')) as funciones_sin_search_path,
 (select count(*) from t where relkind in ('r','p') and has_table_privilege('anon', oid, 'INSERT') and has_table_privilege('anon', oid, 'UPDATE') and has_table_privilege('anon', oid, 'DELETE')) as tablas_anon_insert_update_delete,
 (select count(*) from t where relkind in ('r','p') and has_table_privilege('authenticated', oid, 'TRUNCATE')) as tablas_authenticated_truncate,
 (select count(*) from t where relkind in ('r','p') and has_table_privilege('anon', oid, 'TRUNCATE')) as tablas_anon_truncate,
 (select count(*) from t where relkind in ('r','p','v') and (has_table_privilege('anon', oid, 'TRIGGER') or has_table_privilege('authenticated', oid, 'TRIGGER'))) as relaciones_con_trigger_anon_o_auth,
 (select count(*) from t where relkind in ('r','p','v') and (has_table_privilege('anon', oid, 'REFERENCES') or has_table_privilege('authenticated', oid, 'REFERENCES'))) as relaciones_con_references_anon_o_auth,
 (select count(*) from t where relkind = 'v' and has_table_privilege('anon', oid, 'SELECT')) as vistas_anon_select,
 (select coalesce(string_agg(relname, ', ' order by relname), '-') from t where relkind = 'v' and not has_table_privilege('anon', oid, 'SELECT')) as vistas_sin_anon,
 (select coalesce(string_agg(schemaname || '.' || tablename, ', ' order by tablename), '-') from pg_publication_tables where pubname = 'supabase_realtime') as realtime,
 (select count(*) from pg_policies where schemaname = 'public' and roles = '{public}') as politicas_tablas_rol_public,
 (select count(*) from pg_policies where schemaname = 'storage' and roles = '{public}') as politicas_storage_rol_public,
 (select count(*) from pg_policies where schemaname = 'public') as politicas_public_total;
rollback;
```

### D2. Errores de las últimas 24 h (línea base)

**No son para el SQL Editor.** Van en *Dashboard → Logs → Logs Explorer* (rango *Last 24 hours*). Solo cuentan, no muestran mensajes ni datos. *Sintaxis de Logs Explorer no probada desde aquí; si falla, dime qué error da.*

```sql
-- API: respuestas con error, por código
select r.status_code as codigo, count(*) as total
from edge_logs
cross join unnest(metadata) as m
cross join unnest(m.response) as r
where r.status_code >= 400
group by 1 order by 1
```

```sql
-- Postgres: errores graves, por severidad
select p.error_severity as severidad, count(*) as total
from postgres_logs
cross join unnest(metadata) as m
cross join unnest(m.parsed) as p
where p.error_severity in ('ERROR', 'FATAL', 'PANIC')
group by 1 order by 1
```

### D3. Lo que no se mide con SQL y solo puede dar Polo

- «Respaldo del *fecha y hora*» (Database → Backups): del mismo día o del anterior. **Sin esto no empieza la ventana.**
- Nombre de la **persona de pruebas** y confirmación de que estará toda la ventana.
- **Fecha** de la ventana (sábado o domingo, o entre semana después de las 19:00 CDMX).

---

## Qué hago con cada resultado

- **A1 vacío** y **A3 igual a la referencia** → la información sigue como el 25 oct; la ventana puede empezar.
- **A1 con filas** → no empiezo hasta explicarlas: te pido (con un bloque de solo lectura) la fecha/hora de creación o edición de esas filas, sin contenido.
- **B** → completo `HISTORIAL-MIGRACIONES-HALLAZGO.md` y confirmo si algo del historial choca con las migraciones de la Fase 1/2.
- **D1** → lo comparo con la línea base; la Fase 1 debe partir de esos números.

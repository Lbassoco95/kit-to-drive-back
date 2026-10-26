# Runbook final de la Fase 1 (solo permisos) — ventana del **`<fecha>`**

**Estado: NADA APLICADO.** Generado por `scripts/ventana/generar-runbook-final.py` (no lo edites a mano; cambia el script y vuelve a generarlo). **Claude no usa el conector de Supabase de claude.ai para nada, ni para leer.** Claude no ve producción: tú corres el SQL y pegas el resultado en la sesión, y Claude compara y dice «sigue» o «detente».

**Solo se corre con tu frase, escrita en la sesión:** «Autorizo Fase 1 en producción, ventana del `<fecha>`». Sin ella, nada de la sección 5 en adelante se ejecuta.

## 0. Campos por llenar (los escribe Polo; Claude no los inventa)

| Dato | Valor |
|---|---|
| Fecha de la ventana | `<por llenar>` |
| Respaldo (fecha y hora, Database → Backups) | `<por llenar>` |
| Persona de pruebas | `<por llenar>` |
| Cuentas por rol (una por cada rol de `HOJA-DE-PRUEBAS-POR-ROL.md`, **sin contraseñas aquí**) | `<por llenar>` |
| Persona dueña de la cuenta que aplicó las migraciones anteriores | **pendiente de Polo** (no bloquea la ventana) |

## 1. Quién corre qué y dónde

| Qué | Quién | Dónde |
|---|---|---|
| Escribir la frase de autorización y la fecha del respaldo | Polo | Esta sesión |
| Conectar a producción (la contraseña la escribe Polo, sin que se vea) | Polo | Su terminal |
| Aplicar cada migración y, si hace falta, su reversa | Polo | Su terminal (`psql`) |
| Correr los bloques de verificación (0, V, A1, A2, A3, D2) | Polo | SQL Editor de Supabase (D2: Logs Explorer) |
| Pegar los resultados | Polo | Esta sesión |
| Comparar con los valores esperados y decir «sigue» o «detente» | Claude | Esta sesión |
| Ejecutar los recorridos de la hoja de pruebas y anotar «Después» | Persona de pruebas | Su hoja impresa (`HOJA-DE-PRUEBAS-POR-ROL.md`) |
| Aplicar o revertir **algo** en producción | **Solo Polo.** Claude no aplica nada | — |

## 2. Horario propuesto: sábado 31 de octubre de 2026, 10:00 a 15:00 (CDMX)

La propuesta de 10:00–15:00 **cabe con 40 minutos de colchón** si la preparación dura 30 min (lo pesado se deja hecho el viernes) y el paso 5 (permisos por defecto, que no cambia nada de lo existente) dura 15 min. Con los tiempos completos anteriores (45 min de preparación y 30 en el paso 5) el total sería 4 h 50 min: **cabe, pero con solo 10 minutos de colchón**, y no lo recomiendo.

| Hora | Qué |
|---|---|
| 10:00–10:30 | Preparación y verificación previa (§3, §4) |
| 10:30–11:05 | Paso 1 (M1) |
| 11:05–11:40 | Paso 2 (M2) |
| 11:40–12:10 | Paso 3 (M4) |
| 12:10–12:40 | Paso 4 (M5) |
| 12:40–12:55 | Paso 5 (M6) |
| 12:55–13:35 | Paso 6 (M3, `search_path`), **solo si empieza a más tardar a las 13:15** |
| 13:35–14:20 | Cierre: bloques finales, registro de resultado |
| 14:20–15:00 | Colchón |

*Son estimaciones, no mediciones: la aplicación de cada archivo tarda segundos; el tiempo lo ponen la persona de pruebas y las verificaciones.* **Qué se recorta si no cabe** (en este orden): 1) los recorridos de los pasos 3, 4 y 5 se reducen a los obligatorios de la hoja (1 y 6; 7 y 8 solo en los pasos que los piden); 2) el paso 6 (M3) **pasa a otra ventana**: ya está diseñado para ir al final y solo, y es seguro dejar la Fase 1 en el paso 5.

## 3. Lista previa (marca cada casilla; sin todas, no se empieza)

☐ Frase «Autorizo Fase 1 en producción, ventana del `<fecha>`» escrita en la sesión, con fecha, y la hora de inicio dentro de la ventana permitida.
☐ **Respaldo** del mismo día o del anterior, y la fecha y hora escritas en la sesión.
☐ **Persona de pruebas** presente toda la ventana, con **una cuenta por cada rol** de la hoja (las contraseñas las maneja ella, nunca en el chat).
☐ **Aviso al equipo de Dazon** (el día anterior y al empezar): «Sábado 31 de octubre, de 10:00 a 15:00, hacemos un ajuste de seguridad de la base. No debería notarse; si algo falla o se ve lento, avisen a Polo. Por favor eviten capturar remisiones o movimientos durante ese rato.»
☐ **Terminal lista** en la carpeta del repo, en la rama revisada y mezclada. Comprueba que están las doce piezas y que no cambiaron (los primeros 16 caracteres deben coincidir):
```bash
sha256sum supabase/migrations/2026103100000*.sql supabase/reversas/2026103100000*_reversa.sql | cut -c1-16,65-
```
```
b7c0b998d0924ded  migrations/20261031000001_fase1_quitar_truncate_trigger_references.sql
c585002782381041  migrations/20261031000002_fase1_cerrar_funciones_de_trigger.sql
4712ed54a77f9bc4  migrations/20261031000003_fase1_fijar_search_path.sql
8a6a203c847c774c  migrations/20261031000004_fase1_quitar_lectura_anon_de_vistas.sql
1b6028ff9e2160bf  migrations/20261031000005_fase1_quitar_escritura_anon_de_tablas.sql
41239028219a80ad  migrations/20261031000006_fase1_lo_nuevo_nace_cerrado.sql
a0961cd3958d4767  reversas/20261031000001_fase1_quitar_truncate_trigger_references_reversa.sql
0e5eaa52e84453e0  reversas/20261031000002_fase1_cerrar_funciones_de_trigger_reversa.sql
f38187ccb5b492f5  reversas/20261031000003_fase1_fijar_search_path_reversa.sql
fac482bda807dc05  reversas/20261031000004_fase1_quitar_lectura_anon_de_vistas_reversa.sql
e6f908ba163022ee  reversas/20261031000005_fase1_quitar_escritura_anon_de_tablas_reversa.sql
e202db64dd4d5c76  reversas/20261031000006_fase1_lo_nuevo_nace_cerrado_reversa.sql
```
☐ **Conexión a producción:** `source scripts/ventana/conectar.sh` (pide la contraseña sin mostrarla y se detiene si no es producción). Después: `export FECHA=<AAAA-MM-DD>` y `mkdir -p ventana-logs`.
☐ **Canal de reversa listo:** la misma terminal, los 6 archivos de `supabase/reversas/` presentes (arriba) y esta hoja abierta en la sección 8. La reversa se aplica en orden **inverso**: 3, 6, 5, 4, 2, 1.
☐ **Bloques de la §4 corridos y pegados** (0, V, A1, A3 y, si la foto del A2 trae diferencias, A2). Claude los lee: todo **verde**, o diferencias **explicadas**.
☐ D2 (§10) de línea base, pegado.
☐ Es producción, no QA: el bloque 0 dice `zz_lista_oct = 2219` y `super_admins = 2`.

## 4. Bloques de verificación (se corren en el SQL Editor de Supabase, proyecto `kit-to-drive`)

**Cómo:** pega **un bloque completo** y dale *Run*. Todos son de solo lectura (`begin read only; … rollback;`). **Si el editor solo muestra «Success. No rows returned»** (puede mostrar solo la última instrucción), borra las dos líneas de los extremos, `begin read only;` y `rollback;`, y corre solo el `select`. No borres solo el `rollback;`. No he podido probar el editor de Supabase; los bloques sí los probé en una réplica local de PostgreSQL 16.

### Bloque 0 — ¿Es producción y está tranquila?

**Esperado:** `base` = `postgres`, `zz_lista_oct` = 2219, `super_admins` = 2, `bloqueos_esperando` = 0, `transaccion_mas_larga` de segundos.

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

### Bloque V — Verificación del paso (una fila)

**Esperado:** los valores de la tabla de la §6 para ese momento. Además: `tablas` = 93, `auth_conserva_alta` y `auth_conserva_candado` = `true` **siempre**. `triggers_authenticated` y las tres `defaults_…`: **anótalas antes del paso 1**; `triggers_authenticated` debe quedar en 0 tras el paso 2, y las tres `defaults_…` en `true, true, true` tras el paso 5.

```sql
begin read only;
with t as (select c.oid, c.relkind from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public'),
f as (select p.oid, p.prosecdef, p.proconfig, p.prorettype from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.prokind in ('f', 'p') and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')),
tabs as (select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind in ('r', 'p'))
select
 (select count(*) from t where relkind in ('r','p') and has_table_privilege('anon', oid, 'INSERT') and has_table_privilege('anon', oid, 'UPDATE') and has_table_privilege('anon', oid, 'DELETE')) as tablas_anon_escribe,
 (select count(*) from t where relkind in ('r','p') and has_table_privilege('authenticated', oid, 'TRUNCATE')) as truncate_authenticated,
 (select count(*) from t where relkind in ('r','p') and has_table_privilege('anon', oid, 'TRUNCATE')) as truncate_anon,
 (select count(*) from t where relkind in ('r','p','v') and (has_table_privilege('anon', oid, 'TRIGGER') or has_table_privilege('authenticated', oid, 'TRIGGER'))) as con_trigger,
 (select count(*) from t where relkind in ('r','p','v') and (has_table_privilege('anon', oid, 'REFERENCES') or has_table_privilege('authenticated', oid, 'REFERENCES'))) as con_references,
 (select count(*) from t where relkind = 'v' and has_table_privilege('anon', oid, 'SELECT')) as vistas_anon_lee,
 (select count(*) from f where has_function_privilege('anon', oid, 'EXECUTE')) as funciones_anon,
 (select count(*) from f where prosecdef and has_function_privilege('authenticated', oid, 'EXECUTE')) as secdef_authenticated,
 (select count(*) from f where prorettype = 'trigger'::regtype and has_function_privilege('authenticated', oid, 'EXECUTE')) as triggers_authenticated,
 (select count(*) from f where proconfig is null or not exists (select 1 from unnest(proconfig) x where x like 'search_path=%')) as sin_search_path,
 (select count(*) from pg_policies where schemaname = 'public') as politicas,
 (select count(*) from public.migraciones_aplicadas) as registros_migraciones,
 (select sum((xpath('/row/n/text()', query_to_xml(format('select count(*) n from public.%I', relname), false, true, '')))[1]::text::bigint) from tabs) as filas_totales,
 (select count(*) from tabs) as tablas,
 not exists (select 1 from pg_default_acl d, aclexplode(d.defaclacl) x where d.defaclrole = 'postgres'::regrole and d.defaclnamespace = 'public'::regnamespace and d.defaclobjtype = 'r' and x.grantee = 'anon'::regrole) as defaults_tablas_sin_anon,
 not exists (select 1 from pg_default_acl d, aclexplode(d.defaclacl) x where d.defaclrole = 'postgres'::regrole and d.defaclnamespace = 'public'::regnamespace and d.defaclobjtype = 'r' and x.grantee = 'authenticated'::regrole and x.privilege_type in ('TRUNCATE','TRIGGER','REFERENCES')) as defaults_sin_truncate,
 exists (select 1 from pg_default_acl d where d.defaclrole = 'postgres'::regrole and d.defaclnamespace = 0 and d.defaclobjtype = 'f' and not exists (select 1 from aclexplode(d.defaclacl) x where x.grantee = 0)) as defaults_funciones_sin_public,
 has_function_privilege('supabase_auth_admin', 'public.handle_new_user()', 'EXECUTE') as auth_conserva_alta,
 has_function_privilege('supabase_auth_admin', 'public.reject_public_signups()', 'EXECUTE') as auth_conserva_candado;
rollback;
```

### Bloque A1 — ¿Cambió alguna tabla respecto a la foto del 25 oct?

**Esperado antes del paso 1:** **ninguna fila**. **Esperado después de cada paso, antes de que la persona de pruebas entre al sistema: exactamente una fila**, la de `migraciones_aplicadas` (`cambió el número de filas`, de 90 a 90 + los pasos hechos). Cualquier otra tabla en la lista: **detente**.

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

### Bloque A2 — Foto fresca de las 93 tablas (para guardar)

**Esperado antes del paso 1:** `tablas` = 93, `filas_total` = 20610, `huella_global` = `f14b7f9d221eb9465000913f8aaf5f36`. Pégalo en la sesión como se indicó: los valores sueltos en un bloque y `detalle_compacto` completo en otro, con `huella_del_detalle` para comprobar que se pegó completo. **Esperado después de un paso:** distinta solo por `migraciones_aplicadas` (más filas); A1 dice cuál.

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

### Bloque A3 — Auth y Storage

**Esperado antes del paso 1** (y después de cada paso, **antes** de los recorridos): `auth.users` 26 (0 bloqueados, huellas `1ac193c5…` y `b5ce83d1…`), `auth.identities` 28 (`b7e8b61f…`), `auth.mfa_factors` 0, `storage.buckets` 9 (`002c2d12…`), `storage.objects total` 72 (107052615 bytes, `e47ebdcc…`), `[evidencias-compras]` 7 y `[remisiones-docs]` 65. **Informativos** (cambian con el uso normal): `auth.sessions` 21, `auth.refresh_tokens` 118 (21 no revocados; los 2 tokens nuevos del 26 oct fueron una renovación normal de sesión: se emite uno y se revoca el anterior). **Después de los recorridos** pueden cambiar sesiones y tokens (la persona de pruebas entra con sus cuentas): es esperado, pero **usuarios, identidades, contraseñas y Storage no deben cambiar**.

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

## 5. Los pasos (en este orden: M1, M2, M4, M5, M6 y, por último y solo, M3)

Correspondencia con la **hoja de pruebas**, que numera por orden de ejecución: paso 1 = M1, paso 2 = M2, paso 3 = M4, paso 4 = M5, paso 5 = M6, paso 6 = M3.

### Paso 1 — migración M1: Quitar TRUNCATE, TRIGGER y REFERENCES a `anon` y `authenticated`

*Archivo:* `supabase/migrations/20261031000001_fase1_quitar_truncate_trigger_references.sql` · *Estimado:* 35 min · *Recorridos obligatorios de la hoja de pruebas:* 1, 2, 3, 5, 6.

**Aplicar** (es lo mismo que hace `scripts/ventana/aplicar.sh 20261031000001_fase1_quitar_truncate_trigger_references 1 $FECHA`, que además te pide escribir la referencia del proyecto antes de seguir; usa el script si prefieres la red de seguridad):

```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/migrations/20261031000001_fase1_quitar_truncate_trigger_references.sql \
  -c "INSERT INTO public.migraciones_aplicadas (script, estado, notas) VALUES ('20261031000001_fase1_quitar_truncate_trigger_references', 'aplicado', 'Fase 1, ventana del $FECHA') ON CONFLICT (script) DO UPDATE SET estado='aplicado', aplicada_at=now(), notas=EXCLUDED.notas" \
  2>&1 | tee "ventana-logs/aplicar-M1.log"
```

**Esperado en pantalla:** termina sin la palabra `ERROR` y muestra una línea con cuatro ceros: `0 | 0 | 0 | 0`. Si hay `ERROR`, no quedó nada aplicado (es una sola transacción): pasa el texto a Claude y **no repitas**.

### Paso 2 — migración M2: Cerrar las funciones de trigger a quien no debe llamarlas

*Archivo:* `supabase/migrations/20261031000002_fase1_cerrar_funciones_de_trigger.sql` · *Estimado:* 35 min · *Recorridos obligatorios de la hoja de pruebas:* 1, 2, 3, 5, 6 (incluye el **alta de usuario**).

**Aplicar** (es lo mismo que hace `scripts/ventana/aplicar.sh 20261031000002_fase1_cerrar_funciones_de_trigger 1 $FECHA`, que además te pide escribir la referencia del proyecto antes de seguir; usa el script si prefieres la red de seguridad):

```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/migrations/20261031000002_fase1_cerrar_funciones_de_trigger.sql \
  -c "INSERT INTO public.migraciones_aplicadas (script, estado, notas) VALUES ('20261031000002_fase1_cerrar_funciones_de_trigger', 'aplicado', 'Fase 1, ventana del $FECHA') ON CONFLICT (script) DO UPDATE SET estado='aplicado', aplicada_at=now(), notas=EXCLUDED.notas" \
  2>&1 | tee "ventana-logs/aplicar-M2.log"
```

**Esperado en pantalla:** termina sin la palabra `ERROR` y muestra el aviso «Funciones de trigger cerradas: 53» y `0 | 0 | t | t`. Si hay `ERROR`, no quedó nada aplicado (es una sola transacción): pasa el texto a Claude y **no repitas**.

### Paso 3 — migración M4: Quitar la lectura de `anon` en 16 vistas

*Archivo:* `supabase/migrations/20261031000004_fase1_quitar_lectura_anon_de_vistas.sql` · *Estimado:* 30 min · *Recorridos obligatorios de la hoja de pruebas:* 1, 6, 7.

**Aplicar** (es lo mismo que hace `scripts/ventana/aplicar.sh 20261031000004_fase1_quitar_lectura_anon_de_vistas 1 $FECHA`, que además te pide escribir la referencia del proyecto antes de seguir; usa el script si prefieres la red de seguridad):

```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/migrations/20261031000004_fase1_quitar_lectura_anon_de_vistas.sql \
  -c "INSERT INTO public.migraciones_aplicadas (script, estado, notas) VALUES ('20261031000004_fase1_quitar_lectura_anon_de_vistas', 'aplicado', 'Fase 1, ventana del $FECHA') ON CONFLICT (script) DO UPDATE SET estado='aplicado', aplicada_at=now(), notas=EXCLUDED.notas" \
  2>&1 | tee "ventana-logs/aplicar-M4.log"
```

**Esperado en pantalla:** termina sin la palabra `ERROR` y muestra el aviso «Vistas cerradas a anon: 16» y `0 | 18`. Si hay `ERROR`, no quedó nada aplicado (es una sola transacción): pasa el texto a Claude y **no repitas**.

### Paso 4 — migración M5: Quitar INSERT, UPDATE y DELETE de `anon` en las tablas

*Archivo:* `supabase/migrations/20261031000005_fase1_quitar_escritura_anon_de_tablas.sql` · *Estimado:* 30 min · *Recorridos obligatorios de la hoja de pruebas:* 1, 6, 8.

**Aplicar** (es lo mismo que hace `scripts/ventana/aplicar.sh 20261031000005_fase1_quitar_escritura_anon_de_tablas 1 $FECHA`, que además te pide escribir la referencia del proyecto antes de seguir; usa el script si prefieres la red de seguridad):

```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/migrations/20261031000005_fase1_quitar_escritura_anon_de_tablas.sql \
  -c "INSERT INTO public.migraciones_aplicadas (script, estado, notas) VALUES ('20261031000005_fase1_quitar_escritura_anon_de_tablas', 'aplicado', 'Fase 1, ventana del $FECHA') ON CONFLICT (script) DO UPDATE SET estado='aplicado', aplicada_at=now(), notas=EXCLUDED.notas" \
  2>&1 | tee "ventana-logs/aplicar-M5.log"
```

**Esperado en pantalla:** termina sin la palabra `ERROR` y muestra un solo valor: `0`. Si hay `ERROR`, no quedó nada aplicado (es una sola transacción): pasa el texto a Claude y **no repitas**.

### Paso 5 — migración M6: Que lo que se cree en el futuro nazca cerrado

*Archivo:* `supabase/migrations/20261031000006_fase1_lo_nuevo_nace_cerrado.sql` · *Estimado:* 15 min · *Recorridos obligatorios de la hoja de pruebas:* 1, 6.

**Aplicar** (es lo mismo que hace `scripts/ventana/aplicar.sh 20261031000006_fase1_lo_nuevo_nace_cerrado 1 $FECHA`, que además te pide escribir la referencia del proyecto antes de seguir; usa el script si prefieres la red de seguridad):

```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/migrations/20261031000006_fase1_lo_nuevo_nace_cerrado.sql \
  -c "INSERT INTO public.migraciones_aplicadas (script, estado, notas) VALUES ('20261031000006_fase1_lo_nuevo_nace_cerrado', 'aplicado', 'Fase 1, ventana del $FECHA') ON CONFLICT (script) DO UPDATE SET estado='aplicado', aplicada_at=now(), notas=EXCLUDED.notas" \
  2>&1 | tee "ventana-logs/aplicar-M6.log"
```

**Esperado en pantalla:** termina sin la palabra `ERROR` y muestra `t | t | t`. Si hay `ERROR`, no quedó nada aplicado (es una sola transacción): pasa el texto a Claude y **no repitas**.

### Paso 6 — migración M3: Fijar el `search_path` de 14 funciones (**al final y sola**)

*Archivo:* `supabase/migrations/20261031000003_fase1_fijar_search_path.sql` · *Estimado:* 40 min · *Recorridos obligatorios de la hoja de pruebas:* **todos, del 1 al 11**.

**Aplicar** (es lo mismo que hace `scripts/ventana/aplicar.sh 20261031000003_fase1_fijar_search_path 1 $FECHA`, que además te pide escribir la referencia del proyecto antes de seguir; usa el script si prefieres la red de seguridad):

```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/migrations/20261031000003_fase1_fijar_search_path.sql \
  -c "INSERT INTO public.migraciones_aplicadas (script, estado, notas) VALUES ('20261031000003_fase1_fijar_search_path', 'aplicado', 'Fase 1, ventana del $FECHA') ON CONFLICT (script) DO UPDATE SET estado='aplicado', aplicada_at=now(), notas=EXCLUDED.notas" \
  2>&1 | tee "ventana-logs/aplicar-M3.log"
```

**Esperado en pantalla:** termina sin la palabra `ERROR` y muestra el aviso «Funciones con search_path fijado: 14» y `0`. Si aparece «No existe …: se omite», **detente**. Si hay `ERROR`, no quedó nada aplicado (es una sola transacción): pasa el texto a Claude y **no repitas**.

### Rutina de cada paso (siempre igual)

1. **Aplicar** el comando del paso (terminal). Leer lo que muestra y compararlo con «Esperado en pantalla».
2. **Bloque V** (SQL Editor) y compararlo con la fila de la §6. Pegar en la sesión.
3. **Bloque A1** (debe dar solo `migraciones_aplicadas`) y **A3**. Pegar en la sesión. **Todavía nadie entra al sistema.**
4. Claude dice «verde, sigue a los recorridos» o «detente».
5. La **persona de pruebas** hace los recorridos obligatorios de ese paso y anota «Después» en su hoja. Cualquier falla que antes pasaba: **detente**.
6. **Bloque A1 otra vez**: ahora pueden aparecer tablas de **actividad** (historial de conexiones, bitácoras, notificaciones) por las pruebas; se aceptan **solo con la hora de creación de sus filas dentro del rato de pruebas** (Claude te pide un bloque de solo lectura para comprobarlo). Datos de negocio que cambian sin explicación: **detente**.
7. Claude dice «sigue con el paso siguiente» y se anota la hora de fin.

## 6. Valores esperados del bloque V

`registros_migraciones` y `filas_totales` suben **de uno en uno** porque cada migración se anota en `migraciones_aplicadas` (**las 20,610 filas de hoy pasan a 20,616 al final; no es un cambio de datos**). Los valores salen del ensayo local en el orden de la ventana (aplicar, medir, revertir, medir) y de la medición de producción del 26 oct.

| Momento | `tablas_anon_escribe` | `truncate_authenticated` | `truncate_anon` | `con_trigger` | `con_references` | `vistas_anon_lee` | `funciones_anon` | `secdef_authenticated` | `sin_search_path` | `politicas` | `registros_migraciones` | `filas_totales` |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Antes (preparación) | 81 | 82 | 82 | 103 | 103 | 16 | 2 | 208 | 14 | 301 | 90 | 20,610 |
| Tras el paso 1 (M1) | 81 | 0 | 0 | 0 | 0 | 16 | 2 | 208 | 14 | 301 | 91 | 20,611 |
| Tras el paso 2 (M2) | 81 | 0 | 0 | 0 | 0 | 16 | 0 | 178 | 14 | 301 | 92 | 20,612 |
| Tras el paso 3 (M4) | 81 | 0 | 0 | 0 | 0 | 0 | 0 | 178 | 14 | 301 | 93 | 20,613 |
| Tras el paso 4 (M5) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 178 | 14 | 301 | 94 | 20,614 |
| Tras el paso 5 (M6) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 178 | 14 | 301 | 95 | 20,615 |
| Tras el paso 6 (M3) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 178 | 0 | 301 | 96 | 20,616 |

## 7. Después de los seis pasos (cierre)

1. Bloque V (la fila «Tras el paso 6»), A1, A3 y D2 final, todos pegados.
2. Claude escribe `INTEGRIDAD-RESULTADO-FASE-1.md` con el veredicto «la información se mantuvo: sí/no» y lo explicado.
3. `unset PGPASSWORD PGHOST PGUSER` y cerrar la terminal. Avisar al equipo de Dazon.
4. Esa noche y al día siguiente por la mañana: repetir V, A1, A3 y D2. **Fase 2 no se abre** si algo subió o cambió sin explicación (`RUNBOOK-CONSOLIDADO-VENTANAS.md` §5 y §6).

## 8. Reversa (orden inverso: M3, M6, M5, M4, M2, M1)

Se revierte **el paso que falló y los anteriores**, en el orden inverso al aplicado (si falló M5, se revierte M5 y luego M4, M2, M1... según lo que ya se aplicó, siempre del último al primero). Cada reversa es una transacción y marca el renglón de `migraciones_aplicadas` como `superado` (**no se borra**: por eso `registros_migraciones` y `filas_totales` **no bajan**). La reversa de M4 devuelve a `anon` los permisos tal como estaban el 25 oct, incluido `MAINTAIN` (permiso de PostgreSQL 17, que no existe en mi réplica local: **esa línea no la pude ensayar**; el resto de las reversas sí se ensayó completo).

**Revertir M3**

```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/reversas/20261031000003_fase1_fijar_search_path_reversa.sql \
  -c "UPDATE public.migraciones_aplicadas SET estado='superado', notas='REVERTIDA en la ventana del $FECHA (Fase 1)' WHERE script='20261031000003_fase1_fijar_search_path'" \
  2>&1 | tee "ventana-logs/revertir-M3.log"
```

**Revertir M6**

```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/reversas/20261031000006_fase1_lo_nuevo_nace_cerrado_reversa.sql \
  -c "UPDATE public.migraciones_aplicadas SET estado='superado', notas='REVERTIDA en la ventana del $FECHA (Fase 1)' WHERE script='20261031000006_fase1_lo_nuevo_nace_cerrado'" \
  2>&1 | tee "ventana-logs/revertir-M6.log"
```

**Revertir M5**

```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/reversas/20261031000005_fase1_quitar_escritura_anon_de_tablas_reversa.sql \
  -c "UPDATE public.migraciones_aplicadas SET estado='superado', notas='REVERTIDA en la ventana del $FECHA (Fase 1)' WHERE script='20261031000005_fase1_quitar_escritura_anon_de_tablas'" \
  2>&1 | tee "ventana-logs/revertir-M5.log"
```

**Revertir M4**

```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/reversas/20261031000004_fase1_quitar_lectura_anon_de_vistas_reversa.sql \
  -c "UPDATE public.migraciones_aplicadas SET estado='superado', notas='REVERTIDA en la ventana del $FECHA (Fase 1)' WHERE script='20261031000004_fase1_quitar_lectura_anon_de_vistas'" \
  2>&1 | tee "ventana-logs/revertir-M4.log"
```

**Revertir M2**

```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/reversas/20261031000002_fase1_cerrar_funciones_de_trigger_reversa.sql \
  -c "UPDATE public.migraciones_aplicadas SET estado='superado', notas='REVERTIDA en la ventana del $FECHA (Fase 1)' WHERE script='20261031000002_fase1_cerrar_funciones_de_trigger'" \
  2>&1 | tee "ventana-logs/revertir-M2.log"
```

**Revertir M1**

```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/reversas/20261031000001_fase1_quitar_truncate_trigger_references_reversa.sql \
  -c "UPDATE public.migraciones_aplicadas SET estado='superado', notas='REVERTIDA en la ventana del $FECHA (Fase 1)' WHERE script='20261031000001_fase1_quitar_truncate_trigger_references'" \
  2>&1 | tee "ventana-logs/revertir-M1.log"
```

**Después de cada reversa:** bloque V, que debe dar los valores de esta tabla (la primera columna de cada fila es lo que se acaba de revertir); y al final de **todas**, A1 (la única diferencia, `migraciones_aplicadas`, con seis renglones más).

| Momento | `tablas_anon_escribe` | `truncate_authenticated` | `truncate_anon` | `con_trigger` | `con_references` | `vistas_anon_lee` | `funciones_anon` | `secdef_authenticated` | `sin_search_path` | `politicas` | `registros_migraciones` | `filas_totales` |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Tras revertir M3 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 178 | 14 | 301 | 96 | 20,616 |
| Tras revertir M6 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 178 | 14 | 301 | 96 | 20,616 |
| Tras revertir M5 | 81 | 0 | 0 | 0 | 0 | 0 | 0 | 178 | 14 | 301 | 96 | 20,616 |
| Tras revertir M4 | 81 | 0 | 0 | 0 | 0 | 16 | 0 | 178 | 14 | 301 | 96 | 20,616 |
| Tras revertir M2 | 81 | 0 | 0 | 0 | 0 | 16 | 2 | 208 | 14 | 301 | 96 | 20,616 |
| Tras revertir M1 | 81 | 82 | 82 | 103 | 103 | 16 | 2 | 208 | 14 | 301 | 96 | 20,616 |

## 9. Tiempos y qué hacer

| Situación | Qué se hace |
|---|---|
| Un paso lleva **más de 1,5×** su estimado sin conclusión (p. ej. 53 min en uno de 35) | **Pausa.** Claude resume qué falta; Polo decide: terminar la prueba o revertir el paso |
| El comando de `psql` **no termina** (más de 2 min) o se corta la conexión | `psql` deshace la transacción solo. **No repitas todavía:** corre el bloque V y la consulta del registro (`select script, estado from public.migraciones_aplicadas where script like '202610310%';`, dentro de `begin read only; … rollback;`) para ver en qué estado quedó |
| Son las **13:15** y el paso 6 (M3) no ha empezado | **M3 pasa a otra ventana.** Se cierra con lo ya aplicado |
| Son las **14:15** con un paso a medias | Se **revierte** ese paso y se cierra con V, A1 y A3. **Nunca se deja un paso sin verificar** |
| Falta la persona de pruebas | **Se detiene.** No se avanza sin recorridos |

## 10. Bloque D2 — errores del día (Logs Explorer, no el SQL Editor)

Se corre **al empezar** (línea base de las últimas 24 h) y **al terminar**. **La sintaxis de Logs Explorer no está probada desde aquí.** Va en *Dashboard → Logs → Logs Explorer*, rango *Last 24 hours*. **Esperado:** el conteo de errores 401, 403 y 5xx al final **no sube** respecto al del inicio (los 400 y 404 sueltos son normales). **Si falla la sintaxis:** copia el mensaje de error y pásalo a Claude; mientras tanto usa *Dashboard → Reports → API* (gráficas de errores 4xx y 5xx de las últimas 24 h) y anota los números a ojo; no se bloquea la ventana por esto, pero **sin ninguna de las dos medidas no se declara «los errores no subieron»**.

```sql
select r.status_code as codigo, count(*) as total
from edge_logs
cross join unnest(metadata) as m
cross join unnest(m.response) as r
where r.status_code >= 400
group by 1 order by 1
```

```sql
select p.error_severity as severidad, count(*) as total
from postgres_logs
cross join unnest(metadata) as m
cross join unnest(m.parsed) as p
where p.error_severity in ('ERROR', 'FATAL', 'PANIC')
group by 1 order by 1
```

## 11. Cuándo detenerse y revertir

**Detente** (y revierte ese paso y los anteriores, en orden inverso) si, tras cualquier paso:
- falla un recorrido que antes pasaba;
- un usuario legítimo pierde una acción que tenía;
- aumentan los errores 401, 403 o 5xx contra la línea base;
- **cualquier conteo o huella cambia sin explicación demostrada** (distinto de `migraciones_aplicadas` y de la actividad de las pruebas);
- el bloque V no coincide con la tabla de la §6;
- el alta de usuarios falla (recorrido 3) o `auth_conserva_alta` / `auth_conserva_candado` dejan de ser `true`.

Un `REVOKE` que falle por dependencia: **no uses `CASCADE`**; detente y reporta. Se reporta qué pasó, qué se revirtió y en qué estado quedó.

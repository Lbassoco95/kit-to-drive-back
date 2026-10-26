-- ============================================================================
-- Integridad de la información: conteo exacto y huella de cada tabla de public.
-- SOLO LECTURA. Envolver SIEMPRE en una transacción de solo lectura:
--     begin read only;  <esta consulta>;  commit;
-- No devuelve filas de datos: solo nombre de tabla, número de filas y un hash (md5).
-- Huella = md5 del contenido de la tabla en texto, ordenado por la llave primaria
-- (las 93 tablas tienen llave primaria; si alguna no la tuviera, se ordena por el texto de la fila).
-- Salida: una línea `tabla|filas|huella` por tabla, y una huella global de todas las líneas.
-- ============================================================================
with tabs as (select c.oid, c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','p')),
pk as (select i.indrelid, string_agg(quote_ident(a.attname), ',' order by array_position(i.indkey::int2[], a.attnum)) cols from pg_index i join pg_attribute a on a.attrelid=i.indrelid and a.attnum = any(i.indkey::int2[]) where i.indisprimary group by i.indrelid),
r as (select t.relname,
 (xpath('/row/n/text()', query_to_xml(format('select count(*) n from public.%I', t.relname), false, true, '')))[1]::text::bigint as filas,
 (xpath('/row/h/text()', query_to_xml(format('select coalesce(md5(string_agg(x::text, ''|'' order by %s)), ''vacia'') h from public.%I x', coalesce(pk.cols, 'x::text'), t.relname), false, true, '')))[1]::text as huella,
 pk.cols is not null as con_pk
from tabs t left join pk on pk.indrelid=t.oid)
select count(*) tablas, sum(filas) filas_total, count(*) filter (where filas=0) vacias, count(*) filter (where not con_pk) sin_pk,
 md5(string_agg(relname||'|'||filas||'|'||huella, E'\n' order by relname)) huella_global,
 string_agg(relname||'|'||filas||'|'||huella, E'\n' order by relname) detalle
from r;

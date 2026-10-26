-- Foto de integridad en formato COMPACTO (una sola fila, una sola celda de detalle). SOLO LECTURA.
-- Misma medición que 05 (conteo exacto + md5 por tabla, ordenado por llave primaria), pero con la huella
-- recortada a 12 caracteres y separada con «;», para poder pegarla de vuelta en un solo mensaje.
-- generar-comparacion.py acepta este formato directamente. No devuelve filas de datos.
begin read only;
with tabs as (select c.oid, c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','p')),
pk as (select i.indrelid, string_agg(quote_ident(a.attname), ',' order by array_position(i.indkey::int2[], a.attnum)) cols from pg_index i join pg_attribute a on a.attrelid=i.indrelid and a.attnum = any(i.indkey::int2[]) where i.indisprimary group by i.indrelid),
r as (select t.relname,
 (xpath('/row/n/text()', query_to_xml(format('select count(*) n from public.%I', t.relname), false, true, '')))[1]::text::bigint as filas,
 (xpath('/row/h/text()', query_to_xml(format('select coalesce(md5(string_agg(x::text, ''|'' order by %s)), ''vacia'') h from public.%I x', coalesce(pk.cols, 'x::text'), t.relname), false, true, '')))[1]::text as huella
from tabs t left join pk on pk.indrelid=t.oid)
select now() as medido_en, count(*) as tablas, sum(filas) as filas_total,
 md5(string_agg(relname||'|'||filas||'|'||huella, E'\n' order by relname)) as huella_global,
 string_agg(relname||'|'||filas||'|'||left(huella,12), ';' order by relname) as detalle_compacto
from r;
rollback;

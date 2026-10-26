#!/usr/bin/env python3
"""Genera la consulta de comparación de integridad (solo lectura) a partir de un archivo `tabla|filas|huella`.

Uso:  python3 docs/seguridad/integridad/generar-comparacion.py docs/seguridad/integridad/antes-tablas.txt > comparar.sql
Se pega `comparar.sql` en el SQL Editor (o en el MCP de solo lectura). La huella del archivo puede venir truncada (formato compacto de 12 caracteres): se compara el prefijo.
Devuelve SOLO las tablas cuyo conteo o
huella NO coincide con el archivo, y las tablas que faltan o sobran. Resultado vacío = la información se mantuvo igual.
No contiene datos: solo nombres, conteos y hashes.
"""
import sys
import re
texto = ''.join(l for l in open(sys.argv[1], encoding='utf-8') if not l.startswith('#'))
lineas = [l.strip() for l in re.split(r'[;\n]', texto) if l.strip()]
if any(l.count('|') != 2 for l in lineas): sys.exit('Formato inválido: se espera tabla|filas|huella (una por línea o separadas por ;)')
valores = ',\n'.join("'" + l.replace("'", "''") + "'" for l in lineas)
print(f"""begin read only;
with tabs as (select c.oid, c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','p')),
pk as (select i.indrelid, string_agg(quote_ident(a.attname), ',' order by array_position(i.indkey::int2[], a.attnum)) cols from pg_index i join pg_attribute a on a.attrelid=i.indrelid and a.attnum = any(i.indkey::int2[]) where i.indisprimary group by i.indrelid),
vivo as (select t.relname,
 (xpath('/row/n/text()', query_to_xml(format('select count(*) n from public.%I', t.relname), false, true, '')))[1]::text::bigint as filas,
 (xpath('/row/h/text()', query_to_xml(format('select coalesce(md5(string_agg(x::text, ''|'' order by %s)), ''vacia'') h from public.%I x', coalesce(pk.cols, 'x::text'), t.relname), false, true, '')))[1]::text as huella
from tabs t left join pk on pk.indrelid=t.oid),
antes as (select split_part(l,'|',1) relname, split_part(l,'|',2)::bigint filas, split_part(l,'|',3) huella from unnest(array[
{valores}]) l)
select coalesce(a.relname, v.relname) as tabla, a.filas as filas_antes, v.filas as filas_ahora,
       case when a.relname is null then 'tabla NUEVA' when v.relname is null then 'tabla FALTA'
            when a.filas <> v.filas then 'cambió el número de filas' else 'cambió el contenido (misma cantidad de filas)' end as diferencia
from vivo v full join antes a on a.relname = v.relname
where a.relname is null or v.relname is null or a.filas <> v.filas or left(v.huella, length(a.huella)) <> a.huella
order by 1;
rollback;""")

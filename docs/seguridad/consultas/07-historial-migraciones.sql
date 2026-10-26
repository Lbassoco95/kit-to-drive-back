-- Historial de migraciones de producción, limitado a lo que afecta a aplicar las de la Fase 1 y la Fase 2.
-- SOLO LECTURA. NO devuelve el texto de las sentencias (podrían contener valores sensibles): solo nombres,
-- versiones, fechas, autor (si el historial lo guarda), conteos y banderas.
-- Cada bloque va envuelto en begin read only; … rollback; Se corren por separado y se pega cada resultado.

-- ─── B1. Historial de la CLI: quién y cuándo (la versión es la fecha UTC en que se aplicó) ───────────────────
begin read only;
select s.version,
       to_timestamp(s.version, 'YYYYMMDDHH24MISS') at time zone 'utc' as aplicada_utc,
       s.name,
       to_jsonb(s) ->> 'created_by' as created_by,
       array_length(s.statements, 1) as sentencias
  from supabase_migrations.schema_migrations s
 order by s.version;
rollback;

-- ─── B2. Registro propio (migraciones_aplicadas): resumen por estado, las 12 más recientes y si algo de la Fase 1/2 ya figura (una sola consulta: tipo = resumen | reciente | fase1o2) ───
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

-- ─── B3. ¿Algún historial anterior ya tocó lo que la Fase 1 cambia? (banderas por migración, sin texto) ──────
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

-- Estado del puente de Patio en producción. Solo lectura; no muestra el token.
begin read only;

-- 1) ¿Existe la tabla del token? (solo existencia, nunca su contenido)
select to_regclass('public.patio_bridge_secret') as tabla_patio_bridge_secret;

-- 2) ¿Existen funciones patio_*? y permisos de anon sobre ellas
select p.oid::regprocedure as funcion,
       has_function_privilege('anon', p.oid, 'EXECUTE') as anon_ejecuta,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_ejecuta
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname like '%patio%';

-- 3) ¿Está la migración 20261009000002 en el historial de la CLI o en migraciones_aplicadas?
select 'cli' as registro, version, name
from supabase_migrations.schema_migrations
where version like '20261009%' or name ilike '%puente%' or name ilike '%patio%';

select 'migraciones_aplicadas' as registro, *
from public.migraciones_aplicadas
where archivo ilike '%20261009000002%' or archivo ilike '%puente_heredado%';

commit;

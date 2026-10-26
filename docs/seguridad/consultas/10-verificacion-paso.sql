-- Verificación de la Fase 1 después de CADA migración (y después de cada reversa). SOLO LECTURA. Una sola fila.
-- Compara cada columna con la tabla «valor esperado» de docs/seguridad/RUNBOOK-FINAL-FASE-1.md.
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

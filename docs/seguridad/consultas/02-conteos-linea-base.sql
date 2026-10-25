-- ============================================================================
-- Conteos de permisos de la sección 2 del encargo. SOLO LECTURA.
-- Se corre idéntica antes y después de cada fase, en producción y en el ensayo.
-- ============================================================================
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

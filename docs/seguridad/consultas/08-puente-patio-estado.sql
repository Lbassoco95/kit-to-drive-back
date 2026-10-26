-- Estado del puente de Patio en producción. SOLO LECTURA. No muestra ningún token ni el contenido de la tabla.
-- Polo ya confirmó (26 oct) que no existe; esta consulta deja la constancia por escrito.
begin read only;
select to_regclass('public.patio_bridge_secret') as tabla_patio_bridge_secret,
       (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname like '%patio%') as funciones_patio,
       (select count(*) from public.migraciones_aplicadas where script like '20261009000002%') as registrada_20261009000002,
       (select count(*) from supabase_migrations.schema_migrations where name ilike '%patio%') as historial_cli_con_patio;
rollback;

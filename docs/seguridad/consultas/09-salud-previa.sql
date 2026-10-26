-- Salud de la base antes de abrir la ventana. SOLO LECTURA. Solo conteos, sin consultas ni datos de nadie.
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

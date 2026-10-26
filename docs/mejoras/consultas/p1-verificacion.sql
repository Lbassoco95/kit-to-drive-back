-- Verificación del PAQUETE 1 después de cada migración (y después de cada reversa). SOLO LECTURA. Una fila.
begin read only;
select
 (select count(*) from pg_policies where schemaname = 'public') as politicas,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prokind in ('f', 'p')) as funciones,
 (select count(*) from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and not t.tgisinternal) as triggers,
 (select count(*) from pg_policies where schemaname = 'public' and tablename = 'clientes' and policyname = 'leer clientes' and qual ilike '%vendedor_id IS NULL%') as clientes_sin_asignar_visibles,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'
    and p.proname in ('es_vendedor_comercial', 'clientes_asignar_vendedor_al_crear', 'crm_validar_cliente_visible', 'crm_asignar_cliente_al_usar')) as funciones_paquete1,
 (select count(*) from pg_trigger where not tgisinternal and tgname in ('trg_clientes_asignar_vendedor', 'trg_crm_a_validar_cliente', 'trg_crm_b_asignar_cliente')) as triggers_paquete1,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'
    and p.proname in ('es_vendedor_comercial', 'clientes_asignar_vendedor_al_crear', 'crm_validar_cliente_visible', 'crm_asignar_cliente_al_usar')
    and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('authenticated', p.oid, 'EXECUTE'))) as paquete1_ejecutables,
 pg_get_functiondef('public.puede_leer_remision_refaccion(uuid,uuid)'::regprocedure) ilike '%es_administrativo_comercial%' as refacciones_con_administrativo,
 pg_get_functiondef('public.puede_leer_remision_refaccion(uuid,uuid)'::regprocedure) !~ $q$'almacen_logistica', 'comercial'$q$ as refacciones_sin_comercial,
 (select count(*) from public.clientes) as clientes,
 (select count(*) from public.clientes where vendedor_id is null) as clientes_sin_vendedor,
 (select count(*) from public.migraciones_aplicadas) as registros_migraciones;
rollback;

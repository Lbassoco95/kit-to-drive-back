-- Verificación del PAQUETE 3 después de cada migración (y después de cada reversa). SOLO LECTURA. Una fila.
begin read only;
select
 (select count(*) from pg_policies where schemaname = 'public') as politicas,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prokind in ('f', 'p')) as funciones,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind in ('f', 'p') and p.prosecdef and has_function_privilege('authenticated', p.oid, 'EXECUTE')) as secdef_authenticated,
 (select count(*) from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and not t.tgisinternal) as triggers,
 (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r') as tablas,
 (select valor::text from public.compras_parametros where clave = 'modo_prueba_global') as modo_prueba_global,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('modo_prueba_global_activo', 'fijar_modo_prueba_global', 'proteger_modo_prueba_global',
         'eliminar_remision', 'cambiar_fecha_remision', 'remision_fecha_solo_por_funcion')) as funciones_p3,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('modo_prueba_global_activo', 'fijar_modo_prueba_global', 'proteger_modo_prueba_global',
         'eliminar_remision', 'cambiar_fecha_remision', 'remision_fecha_solo_por_funcion') and has_function_privilege('anon', p.oid, 'EXECUTE')) as p3_ejecutables_por_anon,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('proteger_modo_prueba_global', 'remision_fecha_solo_por_funcion') and has_function_privilege('authenticated', p.oid, 'EXECUTE')) as funciones_de_trigger_ejecutables,
 (select count(*) from pg_policies where schemaname = 'public' and tablename = 'remisiones' and cmd = 'DELETE') as politicas_delete_remisiones,
 has_table_privilege('authenticated', 'public.remisiones', 'DELETE') as authenticated_puede_delete_remisiones,
 (to_regclass('public.remision_fecha_cambios') is not null) as existe_tabla_fechas,
 (select count(*) from pg_trigger where tgname in ('trg_proteger_modo_prueba_global', 'trg_remisiones_fecha_solo_funcion', 'trg_remisiones_refacciones_fecha_solo_funcion') and not tgisinternal) as triggers_p3,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('cliente_tiene_cxc_vencidas', 'cxc_vencidas_resumen') and not p.prosecdef) as cartera_sigue_invoker,
 (select count(*) from public.migraciones_aplicadas) as registros_migraciones;
rollback;

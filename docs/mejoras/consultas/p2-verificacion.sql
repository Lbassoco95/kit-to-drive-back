-- Verificación del PAQUETE 2 después de cada migración (y después de cada reversa). SOLO LECTURA. Una fila.
begin read only;
select
 (select count(*) from pg_policies where schemaname = 'public') as politicas,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prokind in ('f', 'p')) as funciones,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind in ('f', 'p') and p.prosecdef and has_function_privilege('authenticated', p.oid, 'EXECUTE')) as secdef_authenticated,
 (select count(*) from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and not t.tgisinternal) as triggers,
 (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r') as tablas,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('reporte_ventas_refacciones', 'reporte_ventas_refacciones_totales', 'kardex_refacciones_multi', 'resumen_rotacion_refacciones_filtrado')) as funciones_p2,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('reporte_ventas_refacciones', 'reporte_ventas_refacciones_totales') and not p.prosecdef) as reporte_es_invoker,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('reporte_ventas_refacciones', 'reporte_ventas_refacciones_totales', 'kardex_refacciones_multi', 'resumen_rotacion_refacciones_filtrado')
     and has_function_privilege('anon', p.oid, 'EXECUTE')) as p2_ejecutables_por_anon,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('reporte_ventas_refacciones', 'reporte_ventas_refacciones_totales', 'kardex_refacciones_multi', 'resumen_rotacion_refacciones_filtrado')
     and has_function_privilege('authenticated', p.oid, 'EXECUTE')) as p2_ejecutables_por_authenticated,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('cliente_tiene_cxc_vencidas', 'cxc_vencidas_resumen') and not p.prosecdef) as cartera_sigue_invoker,
 (select count(*) from public.migraciones_aplicadas) as registros_migraciones;
rollback;

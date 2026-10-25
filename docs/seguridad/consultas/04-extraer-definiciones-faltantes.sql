-- ============================================================================
-- Definiciones que producción tiene y el repo no crea (para construir la réplica
-- fiel del ensayo). SOLO LECTURA. Solo estructura, sin datos de negocio.
-- Devuelve un JSON: funciones, vistas, columnas de zz_lista_oct y triggers.
-- ============================================================================
select jsonb_build_object(
 'funciones', (select jsonb_agg(jsonb_build_object('n', p.proname, 'def', pg_get_functiondef(p.oid))) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('confirmar_entrega_credito','impedir_escalada_rol','logistica_puede_entregar','patch_corregir_surtido_indebido_faltante','proteger_profile_activo','registrar_paqueteria','trg_crm_actividades_aviso_correo','usuario_operativo')),
 'vistas', (select jsonb_agg(jsonb_build_object('n', c.relname, 'opts', c.reloptions::text, 'def', pg_get_viewdef(c.oid, true))) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='v' and c.relname in ('v_almacen_refacciones_movimientos','v_reporte_pagos','v_reporte_produccion','v_reporte_remisiones')),
 'zz_lista_oct', (select jsonb_agg(jsonb_build_object('col', a.attname, 'tipo', format_type(a.atttypid, a.atttypmod))) from pg_attribute a where a.attrelid='public.zz_lista_oct'::regclass and a.attnum>0 and not a.attisdropped),
 'triggers', (select jsonb_agg(jsonb_build_object('t', c.relname, 'n', t.tgname, 'def', pg_get_triggerdef(t.oid))) from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and not t.tgisinternal)
) as j;

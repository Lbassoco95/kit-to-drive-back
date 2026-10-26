-- ============================================================================
-- Historial de migraciones de producción y cruce con lo que existe solo en producción.
-- SOLO LECTURA. Se corre con el MCP de solo lectura (o en el SQL Editor) envuelta en:
--     begin read only;  <esta consulta>;  commit;
-- No devuelve el texto de las sentencias: solo versión, nombre, autor (si el historial lo guarda),
-- número de sentencias y una huella; y qué migraciones MENCIONAN cada objeto «solo producción».
-- Si `created_by` no existe en esta versión de Supabase, quitar esa columna de la primera consulta.
-- ============================================================================

-- 1) Las migraciones del historial: quién y cuándo (la versión es la fecha UTC en que se aplicó).
select version,
       to_timestamp(version, 'YYYYMMDDHH24MISS') at time zone 'utc' as aplicada_utc,
       name,
       created_by,
       array_length(statements, 1) as sentencias,
       md5(array_to_string(statements, E'\n')) as huella
  from supabase_migrations.schema_migrations
 order by version;

-- 2) Objetos que producción tiene y el repo no (Fase 0, hallazgo D1: 17 políticas, 8 funciones, 8 triggers, 4 vistas,
--    1 tabla): ¿qué migración del historial los menciona?  Sin coincidencia = se crearon por otra vía.
with t as (select version, name, array_to_string(statements, E'\n') as txt from supabase_migrations.schema_migrations),
obj(tipo, nombre) as (values
  ('politica','crm_actividades_delete'),('politica','crm_actividades_insert'),('politica','crm_actividades_select'),('politica','crm_actividades_update'),
  ('politica','crm_oportunidades_delete'),('politica','crm_oportunidades_insert'),('politica','crm_oportunidades_select'),('politica','crm_oportunidades_update'),
  ('politica','crm_ruta_paradas_insert'),('politica','crm_ruta_paradas_select'),('politica','crm_ruta_paradas_update'),
  ('politica','ref_fotos_actualizar'),('politica','ref_fotos_borrar'),('politica','ref_fotos_leer'),('politica','ref_fotos_leer_anon'),('politica','ref_fotos_subir'),
  ('politica','gestionar_roles'),
  ('funcion','confirmar_entrega_credito'),('funcion','impedir_escalada_rol'),('funcion','logistica_puede_entregar'),('funcion','patch_corregir_surtido_indebido_faltante'),
  ('funcion','proteger_profile_activo'),('funcion','registrar_paqueteria'),('funcion','trg_crm_actividades_aviso_correo'),('funcion','usuario_operativo'),
  ('trigger','trg_impedir_escalada_rol'),('trigger','trg_proteger_profile_activo'),('trigger','trg_oportunidades_updated'),('trigger','trg_rutas_updated'),
  ('trigger','trg_actividades_updated'),('trigger','trg_crm_actividades_aviso_correo'),
  ('vista','v_almacen_refacciones_movimientos'),('vista','v_reporte_pagos'),('vista','v_reporte_produccion'),('vista','v_reporte_remisiones'),
  ('tabla','zz_lista_oct'))
select o.tipo, o.nombre,
       coalesce(string_agg(t.version || ' ' || t.name, '; ' order by t.version), '— ninguna (otra vía)') as migraciones_que_lo_mencionan
  from obj o left join t on t.txt ilike '%' || o.nombre || '%'
 group by o.tipo, o.nombre
 order by o.tipo, o.nombre;

-- 3) Lo contrario: de las 5 políticas que el repo crea y producción NO tiene, ¿alguna migración del historial las quita?
with t as (select version, name, array_to_string(statements, E'\n') as txt from supabase_migrations.schema_migrations)
select p.nombre, coalesce(string_agg(t.version || ' ' || t.name, '; ' order by t.version), '— ninguna') as migraciones_que_la_mencionan
  from (values ('insertar bitacora autenticados'),('crm_act_delete'),('crm_oport_delete'),('crm_rutas_delete'),('admin gestiona roles')) p(nombre)
  left join t on t.txt ilike '%' || p.nombre || '%'
 group by p.nombre order by 1;

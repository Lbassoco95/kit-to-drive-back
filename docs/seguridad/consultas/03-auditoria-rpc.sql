-- ============================================================================
-- Insumo de la auditoría de RPC (grupo 3 de CLASIFICACION-FUNCIONES.md).
-- SOLO LECTURA. Por cada función de public, busca en su cuerpo si verifica
-- identidad (auth.uid()) y permiso (funciones de rol/área) y si rechaza con
-- RAISE EXCEPTION. Es una revisión automática de primer nivel: lo que sale
-- como «sin verificación visible» se revisa a mano.
-- ============================================================================
with f as (
  select p.oid, p.proname, pg_get_function_identity_arguments(p.oid) as args,
         p.prosecdef, p.prosrc, p.prorettype::regtype::text as ret,
         (p.proconfig is not null and exists (select 1 from unnest(p.proconfig) x where x like 'search_path=%')) as con_search_path
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind in ('f', 'p')
     and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
)
select jsonb_agg(jsonb_build_object(
  'f', f.proname, 'a', f.args, 'secdef', f.prosecdef, 'ret', f.ret,
  'auth', has_function_privilege('authenticated', f.oid, 'EXECUTE'),
  'uid', f.prosrc ~* 'auth\.uid\(\)',
  'helpers', coalesce((select jsonb_agg(distinct lower(m[1]))
                         from regexp_matches(f.prosrc,
                           '\m(has_role|es_admin_global|es_admin_area|es_admin_de_area|nivel_al_menos|es_area|es_finanzas|es_super_admin|usuario_activo|ve_todo_comercial|es_administrativo_comercial|mi_nivel|mi_area|puede_[a-z_]+|compras_[a-z_]+|admin_[a-z_]+|es_usuario_prueba)\M', 'gi') m), '[]'::jsonb),
  'raises', (select count(*) from regexp_matches(f.prosrc, 'RAISE\s+EXCEPTION', 'gi')),
  'sp', f.con_search_path
) order by f.proname) as filas
from f;

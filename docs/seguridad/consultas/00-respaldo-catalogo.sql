-- ============================================================================
-- Respaldo del catálogo que la Fase 1 puede tocar. SOLO LECTURA.
-- No contiene datos de negocio: únicamente permisos, políticas y configuración.
-- Devuelve un JSON con filas {k: tipo, o: objeto, l: línea}; los archivos de
-- docs/seguridad/respaldo/ se generan a partir de ese resultado.
-- ============================================================================
select jsonb_agg(jsonb_build_object('k', k, 'o', o, 'l', l) order by k, o, l) as filas
from (
  -- Permisos de tablas, vistas y vistas materializadas (anon, authenticated, PUBLIC)
  select 'acl_relacion' as k,
         r.nspname || '.' || r.relname as o,
         format('GRANT %s ON %s.%s TO %s%s;  -- tipo %s, otorgado por %s',
                string_agg(x.privilege_type, ', ' order by x.privilege_type),
                quote_ident(r.nspname), quote_ident(r.relname),
                case when x.grantee = 0 then 'PUBLIC' else quote_ident(x.grantee::regrole::text) end,
                case when x.is_grantable then ' WITH GRANT OPTION' else '' end,
                r.relkind, x.grantor::regrole::text) as l
  from (select c.oid, n.nspname, c.relname, c.relkind,
               coalesce(c.relacl, acldefault('r', c.relowner)) as acl
          from pg_class c join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm', 'f')) r
  cross join lateral aclexplode(r.acl) x
  where x.grantee = 0 or x.grantee::regrole::text in ('anon', 'authenticated')
  group by r.nspname, r.relname, r.relkind, x.grantee, x.is_grantable, x.grantor

  union all
  -- Permisos por columna (si existieran)
  select 'acl_columna', n.nspname || '.' || c.relname || '.' || a.attname, a.attacl::text
    from pg_attribute a
    join pg_class c on c.oid = a.attrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and a.attacl is not null and not a.attisdropped

  union all
  -- Permisos de ejecución de funciones (anon, authenticated, PUBLIC)
  select 'acl_funcion', p.proname,
         format('GRANT EXECUTE ON FUNCTION public.%I(%s) TO %s%s;  -- %s, otorgado por %s',
                p.proname, pg_get_function_identity_arguments(p.oid),
                case when x.grantee = 0 then 'PUBLIC' else quote_ident(x.grantee::regrole::text) end,
                case when x.is_grantable then ' WITH GRANT OPTION' else '' end,
                case when p.prosecdef then 'SECURITY DEFINER' else 'SECURITY INVOKER' end,
                x.grantor::regrole::text)
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) x
   where n.nspname = 'public' and p.prokind in ('f', 'p')
     and (x.grantee = 0 or x.grantee::regrole::text in ('anon', 'authenticated'))

  union all
  -- Configuración y huella del cuerpo de cada función (search_path, secdef, tipo de retorno)
  select 'funcion', p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
         format('md5=%s | config=%s | %s | retorna=%s',
                md5(p.prosrc), coalesce(p.proconfig::text, 'NULL'),
                case when p.prosecdef then 'SECURITY DEFINER' else 'SECURITY INVOKER' end,
                p.prorettype::regtype)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind in ('f', 'p')

  union all
  -- Permisos por defecto para objetos nuevos
  select 'default_acl',
         d.defaclrole::regrole::text || ' en ' || coalesce(d.defaclnamespace::regnamespace::text, '(global)'),
         format('tipo=%s acl=%s', d.defaclobjtype, d.defaclacl::text)
    from pg_default_acl d

  union all
  -- Políticas de seguridad por filas (public y storage)
  select 'politica', schemaname || '.' || tablename || '.' || policyname,
         format('CREATE POLICY %I ON %I.%I AS %s FOR %s TO %s%s%s;',
                policyname, schemaname, tablename, permissive, cmd,
                array_to_string(roles, ', '),
                case when qual is null then '' else ' USING (' || qual || ')' end,
                case when with_check is null then '' else ' WITH CHECK (' || with_check || ')' end)
    from pg_policies
   where schemaname in ('public', 'storage')

  union all
  -- Estado de seguridad por filas y opciones de las vistas
  select 'rls_vista', n.nspname || '.' || c.relname,
         format('tipo=%s rls=%s force=%s opciones=%s',
                c.relkind, c.relrowsecurity, c.relforcerowsecurity, coalesce(c.reloptions::text, '-'))
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r', 'p', 'v')
) q;

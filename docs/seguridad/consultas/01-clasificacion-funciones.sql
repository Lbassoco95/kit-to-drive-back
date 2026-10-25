-- ============================================================================
-- Insumo de CLASIFICACION-FUNCIONES.md. SOLO LECTURA.
-- Por cada función de public: tipo, quién la ejecuta y qué objetos de la base
-- dependen de ella (políticas, vistas, defaults, restricciones, triggers) según
-- pg_depend, que es más fiable que buscar el nombre en el texto.
-- ============================================================================
with f as (
  select p.oid, p.proname, pg_get_function_identity_arguments(p.oid) as args,
         p.prosecdef, p.prorettype::regtype::text as ret, p.prosrc
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind in ('f', 'p')
),
dep as (
  select d.refobjid as oid,
         count(*) filter (where d.classid = 'pg_policy'::regclass)     as n_politicas,
         count(*) filter (where d.classid = 'pg_rewrite'::regclass)    as n_vistas,
         count(*) filter (where d.classid = 'pg_attrdef'::regclass)    as n_defaults,
         count(*) filter (where d.classid = 'pg_constraint'::regclass) as n_restricciones,
         count(*) filter (where d.classid = 'pg_trigger'::regclass)    as n_triggers
    from pg_depend d
   where d.refclassid = 'pg_proc'::regclass and d.deptype = 'n'
   group by d.refobjid
),
pol as (
  select d.refobjid as oid,
         string_agg(distinct pc.relnamespace::regnamespace::text || '.' || pc.relname || ':' || pp.polname, ', ') as politicas
    from pg_depend d
    join pg_policy pp on pp.oid = d.objid and d.classid = 'pg_policy'::regclass
    join pg_class pc on pc.oid = pp.polrelid
   where d.refclassid = 'pg_proc'::regclass
   group by d.refobjid
),
llamadores as (
  select a.oid, string_agg(distinct b.proname, ', ' order by b.proname) as llamada_por
    from f a join f b on b.oid <> a.oid and b.prosrc ~ ('\m' || a.proname || '\M')
   group by a.oid
)
select jsonb_agg(jsonb_build_object(
         'f', f.proname, 'a', f.args, 'secdef', f.prosecdef, 'ret', f.ret,
         'trigger', f.ret in ('trigger', 'event_trigger'),
         'anon', has_function_privilege('anon', f.oid, 'EXECUTE'),
         'auth', has_function_privilege('authenticated', f.oid, 'EXECUTE'),
         'pol', coalesce(d.n_politicas, 0), 'vistas', coalesce(d.n_vistas, 0),
         'def', coalesce(d.n_defaults, 0), 'chk', coalesce(d.n_restricciones, 0),
         'trg', coalesce(d.n_triggers, 0),
         'politicas', left(coalesce(p.politicas, ''), 300),
         'llamada_por', left(coalesce(l.llamada_por, ''), 300)
       ) order by f.proname) as filas
  from f
  left join dep d on d.oid = f.oid
  left join pol p on p.oid = f.oid
  left join llamadores l on l.oid = f.oid;

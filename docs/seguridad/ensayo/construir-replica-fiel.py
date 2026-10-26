#!/usr/bin/env python3
"""Construye en un Postgres LOCAL una réplica del esquema de producción de
Kit-to-Drive, con datos sintéticos (ninguno real), para ensayar la Fase 1.

Pasos (ver docs/seguridad/ENSAYO-FASE-1.md):
  1. Base nueva con las migraciones del repo SIN las de la Fase 1 ni las de la Fase 2
     (scripts/db-local/aplicar_migraciones.sh sobre una copia del repo).
  2. Agrega lo que producción tiene y el repo no crea: funciones, vistas, la
     tabla zz_lista_oct y triggers (de consultas/04-extraer-definiciones-faltantes.sql).
  3. Quita lo que el repo crea y producción no tiene (3 funciones).
  4. Reemplaza las políticas de public y storage por las de producción
     (respaldo/politicas-public-y-storage.sql).
  5. Deja los permisos de tablas, vistas y funciones EXACTAMENTE como el respaldo
     (respaldo/permisos-relaciones.sql, permisos-funciones.sql) y los permisos
     por defecto como producción.

Uso:  PGHOST=/var/run/postgresql PGUSER=root PGOPTIONS='-c role=postgres' \\
      construir-replica-fiel.py <base> <definiciones.json>
Límite conocido: el motor local es PostgreSQL 16; MAINTAIN (PG17) no existe.
"""
import json, os, re, subprocess, sys, shutil, tempfile

base, defs = sys.argv[1], sys.argv[2]
RAIZ = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
RESP = os.path.join(RAIZ, 'docs', 'seguridad', 'respaldo')

def psql(sql, db=None, check=True, quiet=True):
    r = subprocess.run(['psql', '-X', '-q', '-d', db or base, '-v', 'ON_ERROR_STOP=0'], input=sql, text=True, capture_output=True)
    errs = [l for l in r.stderr.splitlines() if 'ERROR' in l]
    return r.stdout, errs

# 1. base con las migraciones del repo sin la Fase 1
tmp = tempfile.mkdtemp()
shutil.copytree(RAIZ, tmp + '/repo', ignore=shutil.ignore_patterns('node_modules', '.git'))
for f in os.listdir(tmp + '/repo/supabase/migrations'):
    # Sin la Fase 1 (20261031…) ni la Fase 2 (20261107…): la réplica es producción tal como estaba el 25 oct.
    if re.match(r'\d{14}_', f) and f >= '20261031': os.remove(tmp + '/repo/supabase/migrations/' + f)
r = subprocess.run(['bash', tmp + '/repo/scripts/db-local/aplicar_migraciones.sh', base], capture_output=True, text=True)
print(r.stdout.strip().splitlines()[-1]); shutil.rmtree(tmp)

d = json.load(open(defs)); d = d[0]['j'] if isinstance(d, list) else d
# En Supabase las extensiones viven en el esquema `extensions`, no en public.
psql("""CREATE SCHEMA IF NOT EXISTS extensions; GRANT USAGE ON SCHEMA extensions TO anon, authenticated, service_role;
ALTER EXTENSION pgcrypto SET SCHEMA extensions;""")
psql(f'ALTER DATABASE {base} SET search_path = "$user", public, extensions;')
# 3. lo que el repo crea y producción no
psql("""DROP FUNCTION IF EXISTS public.definir_compatibilidades_articulo(uuid, uuid[]);
DROP FUNCTION IF EXISTS public.eliminar_articulo_refaccion(uuid);
DROP FUNCTION IF EXISTS public.asignar_chasis_remision(uuid, integer, text);""")
# 2. lo que producción tiene y el repo no crea
errores = []
for fx in d['funciones']:
    errores += psql(fx['def'])[1]
psql(open(os.path.join(RAIZ, 'supabase/control/001_migraciones_aplicadas.sql')).read().split('INSERT INTO')[0])
cols = ', '.join(f"{c['col']} {c['tipo']}" for c in d['zz_lista_oct'])
psql(f"CREATE TABLE IF NOT EXISTS public.zz_lista_oct ({cols}); ALTER TABLE public.zz_lista_oct ENABLE ROW LEVEL SECURITY;")
# Columna que producción tiene y ningún script del repo crea (la usa v_reporte_pagos).
psql("""ALTER TABLE public.pagos ADD COLUMN IF NOT EXISTS tipo_cambio numeric,
  ADD COLUMN IF NOT EXISTS categoria text NOT NULL DEFAULT '', ADD COLUMN IF NOT EXISTS fecha_pago date,
  ADD COLUMN IF NOT EXISTS estatus text NOT NULL DEFAULT 'pendiente', ADD COLUMN IF NOT EXISTS referencia_externa text;""")
for v in d['vistas']:
    opts = 'WITH (security_invoker=true) ' if v['opts'] and 'security_invoker' in v['opts'] else ''
    errores += psql(f"CREATE OR REPLACE VIEW public.{v['n']} {opts}AS {v['def']}")[1]
existentes = set(l.strip() for l in psql("select c.relname||'.'||t.tgname from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and not t.tgisinternal")[0].splitlines())
nuevos = 0
for t in d['triggers']:
    if f"{t['t']}.{t['n']}" not in existentes:
        errores += psql(t['def'])[1]; nuevos += 1
print('triggers agregados:', nuevos)
# 4. políticas de producción
psql("""DO $$ DECLARE p record; BEGIN
  FOR p IN SELECT schemaname, tablename, policyname FROM pg_policies WHERE schemaname IN ('public','storage') LOOP
    EXECUTE format('DROP POLICY %I ON %I.%I', p.policyname, p.schemaname, p.tablename); END LOOP; END $$;""")
pol = [l for l in open(os.path.join(RESP, 'politicas-public-y-storage.sql')).read().split('\n') if not l.startswith('--')]
sqlp = '\n'.join(pol)
out, e = psql(sqlp); errores += e
# 5. permisos como el respaldo
psql("""DO $$ DECLARE r record; BEGIN
  FOR r IN SELECT c.oid::regclass AS rel FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p','v') LOOP
    EXECUTE format('REVOKE ALL ON %s FROM PUBLIC, anon, authenticated', r.rel); END LOOP;
  FOR r IN SELECT p.oid::regprocedure AS f FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prokind IN ('f','p') AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid=p.oid AND d.deptype='e') LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', r.f); END LOOP; END $$;""")
for fich in ('permisos-relaciones.sql', 'permisos-funciones.sql'):
    L = [re.sub(r',\s*MAINTAIN|MAINTAIN,\s*', '', l) for l in open(os.path.join(RESP, fich)).read().split('\n') if l.startswith('GRANT')]
    o, e = psql('\n'.join(L)); errores += e
psql("""GRANT EXECUTE ON FUNCTION public.handle_new_user(), public.reject_public_signups(), public.vigilar_super_admin() TO supabase_auth_admin;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon;""")
print('errores durante la construcción:', len(errores))
for e in errores[:25]: print('  ', e[:200])

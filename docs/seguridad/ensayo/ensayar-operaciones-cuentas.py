#!/usr/bin/env python3
"""Ensayo de (1) los scripts de cuentas de supabase/operaciones/ (bloquear edgar, bloquear test-scan, migrar el correo de lee) y
(2) la migración 20261110000001 (asignar_super_admin: opción B). Datos SINTÉTICOS; nada real.

Parte 1 usa una base mínima creada aquí (auth.users con banned_until, auth.identities, profiles, user_roles, super_admins y las tablas
con vendedor_id que miran las guardas). Parte 2 usa una COPIA de la réplica con Fase 1 + Paquete 1 + Fase 2 aplicados.

Uso: PGHOST=/var/run/postgresql PGUSER=root PGOPTIONS='-c role=postgres' ensayar-operaciones-cuentas.py <base_replica> <salida.json>
"""
import json, os, re, subprocess, sys

REPLICA, SALIDA = sys.argv[1], sys.argv[2]
RAIZ = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
OPS = os.path.join(RAIZ, 'supabase', 'operaciones')
MIGR = '20261110000001_asignar_super_admin_solo_super_admin'
HUELLA_PROD_ASIGNAR = '8d3eb529c8b66bb2a7863a1fce250435'   # md5(prosrc) de asignar_super_admin en producción (26 oct 2026, solo lectura)
CHK = []
def chk(n, ok, d=''): CHK.append((n, bool(ok), str(d)[:260]))

def psql(db, sql, tuples=True):
    a = ['psql', '-X', '-q', '-d', db, '-v', 'ON_ERROR_STOP=0'] + (['-At', '-F', '|'] if tuples else [])
    return subprocess.run(a, input=sql, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT).stdout
def archivo(db, ruta, sustituciones=None):
    t = open(ruta).read()
    for a, b in (sustituciones or {}).items(): t = t.replace(a, b)
    r = subprocess.run(['psql', '-X', '-d', db, '-v', 'ON_ERROR_STOP=1', '-At', '-F', '|'], input=t, text=True, capture_output=True)
    return r.returncode == 0, (r.stdout + r.stderr)
def error_de(r):
    m = re.findall(r'ERROR:\s+(?:[0-9A-Z]{5}: )?(.*)', r); return m[0].strip() if m else None

# ───────────────────────── Parte 1: scripts de cuentas ─────────────────────────
def base_cuentas():
    psql('postgres', 'DROP DATABASE IF EXISTS ops_cuentas;'); psql('postgres', 'CREATE DATABASE ops_cuentas;')
    psql('ops_cuentas', """
CREATE SCHEMA auth;
CREATE TABLE auth.users (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), email text, raw_user_meta_data jsonb DEFAULT '{}', banned_until timestamptz, updated_at timestamptz DEFAULT now());
CREATE TABLE auth.identities (id uuid DEFAULT gen_random_uuid(), user_id uuid, provider text, identity_data jsonb, updated_at timestamptz);
CREATE TABLE public.profiles (id uuid PRIMARY KEY, email text, activo boolean, nombre_completo text);
CREATE TABLE public.user_roles (user_id uuid, area text, nivel text);
CREATE TABLE public.super_admins (user_id uuid);
CREATE TABLE public.remisiones (id uuid DEFAULT gen_random_uuid(), vendedor_id uuid);
CREATE TABLE public.remisiones_refacciones (id uuid DEFAULT gen_random_uuid(), vendedor_id uuid);
CREATE TABLE public.clientes (id uuid DEFAULT gen_random_uuid(), vendedor_id uuid);
CREATE TABLE public.crm_oportunidades (id uuid DEFAULT gen_random_uuid(), vendedor_id uuid);
CREATE TABLE public.crm_rutas (id uuid DEFAULT gen_random_uuid(), vendedor_id uuid);
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
 ('00000000-0000-4000-8000-000000000001', 'edgar@dazon.demo', '{"email":"edgar@dazon.demo"}'),
 ('00000000-0000-4000-8000-000000000002', 'test-scan@test.com', '{}'),
 ('00000000-0000-4000-8000-000000000003', 'lee@dazon.demo', '{"email":"lee@dazon.demo","nombre":"Lee"}'),
 ('00000000-0000-4000-8000-000000000004', 'marco@dazon.demo', '{"email":"marco@dazon.demo"}'),
 ('00000000-0000-4000-8000-000000000005', 'otra@dazon.demo', '{}');
INSERT INTO auth.identities (user_id, provider, identity_data) SELECT id, 'email', jsonb_build_object('email', email) FROM auth.users;
INSERT INTO public.profiles (id, email, activo, nombre_completo) VALUES
 ('00000000-0000-4000-8000-000000000001', 'edgar@dazon.demo', false, 'Edgar'),
 ('00000000-0000-4000-8000-000000000002', NULL, true, 'test-scan@test.com'),
 ('00000000-0000-4000-8000-000000000003', 'lee@dazon.demo', true, 'Lee'),
 ('00000000-0000-4000-8000-000000000004', NULL, true, 'Marco'),
 ('00000000-0000-4000-8000-000000000005', 'otra@dazon.demo', true, 'Otra');
INSERT INTO public.user_roles VALUES ('00000000-0000-4000-8000-000000000001', 'fabrica', 'operador'),
 ('00000000-0000-4000-8000-000000000003', 'comercial', 'admin'), ('00000000-0000-4000-8000-000000000004', 'comercial', 'supervisor');
""", False)

def foto():
    return psql('ops_cuentas', """SELECT md5(string_agg(x, '|' ORDER BY x)) FROM (
      SELECT 'u|'||id||'|'||coalesce(email,'')||'|'||raw_user_meta_data::text||'|'||coalesce(banned_until::text,'') FROM auth.users
      UNION ALL SELECT 'i|'||user_id||'|'||identity_data::text FROM auth.identities
      UNION ALL SELECT 'p|'||id||'|'||coalesce(email,'')||'|'||coalesce(activo::text,'')||'|'||coalesce(nombre_completo,'') FROM public.profiles
      UNION ALL SELECT 'r|'||user_id||'|'||area||'|'||nivel FROM public.user_roles) q;""").strip().splitlines()[-1]
def q(sql): return psql('ops_cuentas', sql).strip()

def parte_cuentas():
    base_cuentas(); f0 = foto()
    # —— Edgar
    ed, ed_rev = os.path.join(OPS, 'fase2-bloquear-edgar.sql'), os.path.join(OPS, 'fase2-bloquear-edgar_reversa.sql')
    ok, out = archivo('ops_cuentas', ed)
    chk('Edgar: el script aplica y bloquea SOLO a edgar (1 bloqueada, 1 existe, 0 perfiles activos)', ok and out.strip().splitlines()[-2:-1] != [] and '1|1|0' in out, out[-200:])
    chk('Edgar: nadie más quedó bloqueado y no se tocó ningún perfil ni rol', q("select count(*) from auth.users where banned_until is not null") == '1' and q("select count(*) from public.profiles where activo") == '4')
    ok2, out2 = archivo('ops_cuentas', ed); chk('Edgar: aplicarlo dos veces ABORTA (ya bloqueada)', (not ok2) and 'ya estaba bloqueada' in out2, out2[-150:])
    ok, out = archivo('ops_cuentas', ed_rev); chk('Edgar: la reversa lo desbloquea y la base queda EXACTAMENTE como estaba', ok and foto() == f0, out[-150:])
    for nombre, prep, esperado in [
        ('perfil ACTIVO', "UPDATE public.profiles SET activo = true WHERE email = 'edgar@dazon.demo';", 'NO está inactivo'),
        ('con datos propios', "INSERT INTO public.remisiones (vendedor_id) VALUES ('00000000-0000-4000-8000-000000000001');", 'registro(s) propios'),
        ('ya bloqueada', "UPDATE auth.users SET banned_until = 'infinity' WHERE email = 'edgar@dazon.demo';", 'ya estaba bloqueada'),
        ('cuenta duplicada', "INSERT INTO auth.users (email) VALUES ('edgar@dazon.demo');", 'Se esperaba 1 cuenta')]:
        base_cuentas(); psql('ops_cuentas', prep); antes = foto()
        ok, out = archivo('ops_cuentas', ed); chk(f"Edgar: guarda «{nombre}» aborta sin cambiar nada", (not ok) and esperado in out and foto() == antes, out[-150:])
    # —— test-scan
    ts, ts_rev = os.path.join(OPS, 'fase2-bloquear-test-scan.sql'), os.path.join(OPS, 'fase2-bloquear-test-scan_reversa.sql')
    base_cuentas(); f0 = foto()
    ok, out = archivo('ops_cuentas', ts)
    chk('test-scan: el script aplica, bloquea en Auth y desactiva el perfil (1, 1, 0)', ok and '1|1|0' in out, out[-200:])
    chk('test-scan: nadie más cambió (1 bloqueada; quedan 3 perfiles activos → lee, marco, otra)', q("select count(*) from auth.users where banned_until is not null") == '1' and q("select count(*) from public.profiles where activo") == '3')
    ok, out = archivo('ops_cuentas', ts_rev); chk('test-scan: la reversa devuelve la base EXACTAMENTE como estaba (banned NULL y activo true)', ok and foto() == f0, out[-150:])
    for nombre, prep, esperado in [
        ('YA tiene área o nivel', "INSERT INTO public.user_roles VALUES ('00000000-0000-4000-8000-000000000002', 'comercial', 'operador');", 'YA tiene área o nivel'),
        ('es super admin', "INSERT INTO public.super_admins VALUES ('00000000-0000-4000-8000-000000000002');", 'es super admin'),
        ('con datos propios', "INSERT INTO public.crm_oportunidades (vendedor_id) VALUES ('00000000-0000-4000-8000-000000000002');", 'registro(s) propios'),
        ('perfil ya inactivo', "UPDATE public.profiles SET activo = false WHERE nombre_completo = 'test-scan@test.com';", 'ya está inactivo'),
        ('ya bloqueada', "UPDATE auth.users SET banned_until = 'infinity' WHERE email = 'test-scan@test.com';", 'ya estaba bloqueada')]:
        base_cuentas(); psql('ops_cuentas', prep); antes = foto()
        ok, out = archivo('ops_cuentas', ts); chk(f"test-scan: guarda «{nombre}» aborta sin cambiar nada", (not ok) and esperado in out and foto() == antes, out[-150:])
    # —— Lee
    lm, lm_rev = os.path.join(OPS, 'fase2-migrar-correo-real-lee.sql'), os.path.join(OPS, 'fase2-migrar-correo-real-lee_reversa.sql')
    base_cuentas(); f0 = foto()
    ok, out = archivo('ops_cuentas', lm); chk('Lee: con el texto CORREO_REAL_DE_LEE sin reemplazar el script ABORTA y no cambia nada', (not ok) and 'forma de correo' in out and foto() == f0, out[-160:])
    nuevo = {'CORREO_REAL_DE_LEE': 'Lee.Real@ejemplo.test'}
    ok, out = archivo('ops_cuentas', lm, nuevo)
    chk('Lee: con un correo real aplica (1, 1, 1 y 0 con correo demo)', ok and '1|1|1|0' in out, out[-200:])
    chk('Lee: cambia solo a lee (usuario, identidad, perfil y metadato) y el correo queda en minúsculas',
        q("select email from auth.users where id = '00000000-0000-4000-8000-000000000003'") == 'lee.real@ejemplo.test'
        and q("select identity_data->>'email' from auth.identities where user_id = '00000000-0000-4000-8000-000000000003'") == 'lee.real@ejemplo.test'
        and q("select email from public.profiles where id = '00000000-0000-4000-8000-000000000003'") == 'lee.real@ejemplo.test'
        and q("select raw_user_meta_data->>'email' from auth.users where id = '00000000-0000-4000-8000-000000000003'") == 'lee.real@ejemplo.test'
        and q("select raw_user_meta_data->>'nombre' from auth.users where id = '00000000-0000-4000-8000-000000000003'") == 'Lee'
        and q("select count(*) from auth.users where email like '%@dazon.demo'") == '3')
    chk('Lee: Marco NO cambia (queda como está, A)', q("select email from auth.users where id = '00000000-0000-4000-8000-000000000004'") == 'marco@dazon.demo' and q("select coalesce(email,'NULL') from public.profiles where id = '00000000-0000-4000-8000-000000000004'") == 'NULL')
    chk('Lee: rol, área, nivel, activo y bloqueo intactos', q("select area||'/'||nivel from public.user_roles where user_id = '00000000-0000-4000-8000-000000000003'") == 'comercial/admin' and q("select activo from public.profiles where id = '00000000-0000-4000-8000-000000000003'") == 't' and q("select count(*) from auth.users where banned_until is not null") == '0')
    ok2, out2 = archivo('ops_cuentas', lm, nuevo); chk('Lee: aplicarlo dos veces ABORTA (ya no existe lee@dazon.demo)', not ok2, out2[-150:])
    ok, out = archivo('ops_cuentas', lm_rev, nuevo); chk('Lee: la reversa devuelve la base EXACTAMENTE como estaba', ok and foto() == f0, out[-150:])
    for nombre, nuevo_c, prep, esperado in [
        ('correo @dazon.demo', {'CORREO_REAL_DE_LEE': 'lee2@dazon.demo'}, '', 'sigue siendo @dazon.demo'),
        ('sin forma de correo', {'CORREO_REAL_DE_LEE': 'sin-arroba'}, '', 'forma de correo'),
        ('correo ya existente (otra mayúscula)', {'CORREO_REAL_DE_LEE': 'OTRA@dazon.demo'.replace('dazon.demo', 'ejemplo.test')}, "UPDATE auth.users SET email = 'otra@ejemplo.test' WHERE email = 'otra@dazon.demo';", 'ya existe'),
        ('perfil inactivo', {'CORREO_REAL_DE_LEE': 'lee.real@ejemplo.test'}, "UPDATE public.profiles SET activo = false WHERE email = 'lee@dazon.demo';", 'perfil inactivo'),
        ('lee no existe', {'CORREO_REAL_DE_LEE': 'lee.real@ejemplo.test'}, "UPDATE auth.users SET email = 'otro@dazon.demo' WHERE email = 'lee@dazon.demo';", 'Se esperaba la cuenta')]:
        base_cuentas(); psql('ops_cuentas', prep); antes = foto()
        ok, out = archivo('ops_cuentas', lm, nuevo_c); chk(f"Lee: guarda «{nombre}» aborta sin cambiar nada", (not ok) and esperado in out and foto() == antes, out[-150:])
    # —— todos: sin borrar, sin contraseñas, no son migraciones
    for f in ('fase2-bloquear-edgar.sql', 'fase2-bloquear-test-scan.sql', 'fase2-migrar-correo-real-lee.sql'):
        t = re.sub(r'--.*$', '', open(os.path.join(OPS, f)).read(), flags=re.M).replace('ON COMMIT DROP', '')
        chk(f"{f}: no borra (sin DELETE, DROP ni TRUNCATE) y no toca contraseñas", not re.search(r'\bDELETE\s+FROM\b|\bDROP\s|\bTRUNCATE\b|encrypted_password', t, re.I))

# ───────────────────────── Parte 2: asignar_super_admin opción B ─────────────────────────
ROLES = {'sa1': ('direccion', 'admin', True), 'sa2': ('direccion', 'admin', True), 'dirglobal': ('direccion', 'admin', False),
         'admcom': ('comercial', 'admin', False), 'superv': ('comercial', 'supervisor', False), 'vend1': ('comercial', 'operador', False),
         'finanzas': ('administracion', 'operador', False), 'destino': ('comercial', 'operador', False)}
def uid(n): return f"00000000-0000-4000-8000-{abs(sum((i + 1) * ord(c) for i, c in enumerate(n)) * 7919):012d}"[:36]
CLAIMS = "SELECT set_config('request.jwt.claim.sub', '{u}', true), set_config('request.jwt.claims', '{{\"sub\":\"{u}\",\"role\":\"authenticated\"}}', true) \\g /dev/null\n"
def como(rol, cuerpo): return psql('p_asig', "BEGIN;\nSET LOCAL ROLE authenticated;\n" + CLAIMS.format(u=uid(rol)) + cuerpo + "\nROLLBACK;\n")
def como_prep(rol, prep, cuerpo): return psql('p_asig', "BEGIN;\n" + prep + "\nSET LOCAL ROLE authenticated;\n" + CLAIMS.format(u=uid(rol)) + cuerpo + "\nROLLBACK;\n")

def catalogo():
    return psql('p_asig', """SELECT md5(string_agg(x, E'\\n' ORDER BY x)) FROM (
      SELECT 'p|'||schemaname||'.'||tablename||'|'||policyname||'|'||cmd||'|'||coalesce(qual,'')||'|'||coalesce(with_check,'') FROM pg_policies WHERE schemaname IN ('public','storage')
      UNION ALL SELECT 'f|'||p.oid::regprocedure::text||'|'||md5(pg_get_functiondef(p.oid))||'|'||coalesce(p.proacl::text,'') FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prokind IN ('f','p')
      UNION ALL SELECT 't|'||c.relname||'|'||t.tgname||'|'||md5(pg_get_triggerdef(t.oid)) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE NOT t.tgisinternal AND n.nspname='public') q;""").strip().splitlines()[-1]
def funciones_salvo_asignar():
    return psql('p_asig', "SELECT md5(string_agg(p.oid::regprocedure::text||md5(pg_get_functiondef(p.oid)), '|' ORDER BY p.oid::regprocedure::text)) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prokind IN ('f','p') AND p.proname <> 'asignar_super_admin';").strip().splitlines()[-1]

def parte_super_admin():
    psql('postgres', 'DROP DATABASE IF EXISTS p_asig;'); psql('postgres', f'CREATE DATABASE p_asig TEMPLATE {REPLICA};')
    s = []
    for n, (area, nivel, sa) in ROLES.items():
        u = uid(n); em = f"{n}@ejemplo.test"
        s.append(f"""INSERT INTO public.altas_autorizadas (email, expira_at) VALUES ('{em}', now() + interval '5 minutes') ON CONFLICT (email) DO UPDATE SET expira_at = EXCLUDED.expira_at;
INSERT INTO auth.users (id, email) VALUES ('{u}', '{em}') ON CONFLICT (id) DO NOTHING;
UPDATE public.profiles SET nombre_completo = 'Sintético {n}', activo = true WHERE id = '{u}';
DELETE FROM public.user_roles WHERE user_id = '{u}';
INSERT INTO public.user_roles (user_id, area, nivel) VALUES ('{u}', '{area}', '{nivel}');""")
        if sa: s.append(f"INSERT INTO public.super_admins (user_id) VALUES ('{u}') ON CONFLICT DO NOTHING;")
    psql('p_asig', '\n'.join(s))
    d = uid('destino'); asig = lambda rol, tgt, act, prep='': como_prep(rol, prep, f"SELECT public.asignar_super_admin('{uid(tgt)}', {act});\nRESET ROLE;\nSELECT 'super_admin=' || exists(SELECT 1 FROM public.super_admins WHERE user_id = '{uid(tgt)}');")
    # ANTES (opción A, la de hoy): solo un administrador global que NO es super admin
    antes = {r: ('ok' if error_de(asig(r, 'destino', 'true')) is None else 'rechazado') for r in ROLES}
    chk('ANTES (opción A de hoy): solo el administrador global que no es super admin asigna; los super admins NO', antes['dirglobal'] == 'ok' and antes['sa1'] == 'rechazado' and antes['sa2'] == 'rechazado', antes)
    cat0, fun0 = catalogo(), funciones_salvo_asignar()
    ok = subprocess.run(['psql', '-X', '-q', '-d', 'p_asig', '-v', 'ON_ERROR_STOP=1', '--single-transaction', '-f', os.path.join(RAIZ, 'supabase', 'migrations', MIGR + '.sql')], capture_output=True, text=True)
    chk('La migración 20261110000001 aplica sin error', ok.returncode == 0, ok.stderr[-200:])
    despues = {r: ('ok' if error_de(asig(r, 'destino', 'true')) is None else 'rechazado') for r in ROLES}
    chk('DESPUÉS (opción B): solo un super admin asigna; el administrador global que no es super admin, ya no', despues['sa1'] == 'ok' and despues['sa2'] == 'ok' and all(despues[r] == 'rechazado' for r in ROLES if r not in ('sa1', 'sa2')), despues)
    e = error_de(asig('dirglobal', 'destino', 'true')); chk('Polo (administrador global, no super admin): mensaje claro «Sólo un super admin…»', e and 'Sólo un super admin' in e, e)
    r = asig('sa1', 'destino', 'true'); chk('Un super admin asigna: el destino queda en super_admins', 'super_admin=t' in r, r[-120:])
    r = como('sa1', f"SELECT public.asignar_super_admin('{d}', true);\nRESET ROLE;\nSELECT 'rol=' || area || '/' || nivel FROM public.user_roles WHERE user_id = '{d}';\nSELECT 'bitacora=' || count(*) FROM public.bitacora_super_admin WHERE operacion = 'ASIGNAR' AND registro_id = '{d}';")
    chk('La asignación sube al destino a Dirección/admin y deja renglón en bitacora_super_admin', 'rol=direccion/admin' in r and 'bitacora=1' in r, r[-160:])
    e = error_de(asig('sa1', 'sa1', 'false')); chk('Un super admin no se quita a sí mismo', e and 'tu propio tipo' in e, e)
    r = asig('sa1', 'sa2', 'false'); chk('Con DOS super admins, uno quita al otro', 'super_admin=f' in r and error_de(r) is None, r[-120:])
    # sin sesión
    e = error_de(psql('p_asig', f"BEGIN;\nSET LOCAL ROLE authenticated;\nSELECT public.asignar_super_admin('{d}', true);\nROLLBACK;")); chk('Sin sesión (auth.uid() nulo) se rechaza', e and 'Sólo un super admin' in e, e)
    pe = psql('p_asig', "SELECT has_function_privilege('anon','public.asignar_super_admin(uuid,boolean)','EXECUTE')::text||has_function_privilege('authenticated','public.asignar_super_admin(uuid,boolean)','EXECUTE')::text;").strip().splitlines()[-1]
    chk('Permisos: anon no ejecuta y authenticated sí', pe == 'falsetrue', pe)
    chk('Una sola firma (sin sobrecargas) y ninguna otra función cambió (Fase 1, Paquete 1, Fase 2, Paquetes 2 y 3 intactas)', psql('p_asig', "SELECT count(*) FROM pg_proc WHERE proname='asignar_super_admin';").strip().splitlines()[-1] == '1' and funciones_salvo_asignar() == fun0)
    cat1 = catalogo()
    subprocess.run(['psql', '-X', '-q', '-d', 'p_asig', '--single-transaction', '-f', os.path.join(RAIZ, 'supabase', 'migrations', MIGR + '.sql')], capture_output=True)
    chk('Reaplicar la migración no cambia nada (idempotente)', catalogo() == cat1)
    rv = subprocess.run(['psql', '-X', '-q', '-d', 'p_asig', '-v', 'ON_ERROR_STOP=1', '--single-transaction', '-f', os.path.join(RAIZ, 'supabase', 'reversas', MIGR + '_reversa.sql')], capture_output=True, text=True)
    chk('La reversa aplica sin error', rv.returncode == 0, rv.stderr[-200:])
    chk('La reversa deja el catálogo EXACTAMENTE como estaba antes', catalogo() == cat0)
    h = psql('p_asig', "SELECT md5(prosrc) FROM pg_proc WHERE proname='asignar_super_admin';").strip().splitlines()[-1]
    chk('Tras la reversa, la función tiene la MISMA huella que en producción (8d3eb529…)', h == HUELLA_PROD_ASIGNAR, h)
    despues_rev = {r: ('ok' if error_de(asig(r, 'destino', 'true')) is None else 'rechazado') for r in ROLES}
    chk('Tras la reversa vuelve la opción A (el administrador global asigna; los super admins no)', despues_rev == antes, despues_rev)
    return {'antes': antes, 'despues': despues}

def main():
    out = {}
    parte_cuentas(); out['parte_super_admin'] = parte_super_admin()
    out['chequeos'] = [{'caso': a, 'ok': b, 'detalle': c} for a, b, c in CHK]
    json.dump(out, open(SALIDA, 'w'), ensure_ascii=False, indent=1, sort_keys=True)
    fallos = [c for c in CHK if not c[1]]
    print(f"chequeos: {len(CHK) - len(fallos)}/{len(CHK)} en verde")
    for a, b, c in fallos: print('  FALLA:', a, '->', c)
main()

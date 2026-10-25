#!/usr/bin/env python3
"""Recorridos por rol a nivel de base de datos, sobre la réplica local.

Crea usuarios SINTÉTICOS (correos @ejemplo.test, ningún dato real) para 8 roles,
corre una lista de acciones como cada uno (una permitida y otra que debe ser
rechazada, entre otras) y las pruebas genéricas de la Fase 1:

  · `authenticated` y `anon` no pueden TRUNCATE ninguna tabla.
  · `anon` no puede escribir en ninguna tabla ni leer ninguna vista.
  · `anon` y `authenticated` no pueden ejecutar funciones de trigger por RPC.
  · El alta de usuario (rol de Auth + triggers de auth.users) sigue funcionando
    y el registro sin autorización sigue rechazado.

Cada acción corre dentro de una transacción que se revierte. Devuelve un JSON
{"roles": {...}, "generico": {...}} que ensayar-fase-1.py compara antes y después.

Uso: PGHOST=/var/run/postgresql PGUSER=root probar-recorridos.py <base> [salida.json]
Limite: es el nivel SQL (RLS, permisos, triggers). Los recorridos de pantalla
(front, compuerta, MATI Admin) están en docs/seguridad/RECORRIDOS-Y-PRUEBAS-POR-ROL.md.
"""
import json, re, subprocess, sys

DB = sys.argv[1]
SALIDA = sys.argv[2] if len(sys.argv) > 2 else None

ROLES = {  # nombre: (area, nivel, super_admin)
    'operador':        ('fabrica', 'operador', False),
    'admin_de_area':   ('comercial', 'admin', False),
    'super_admin':     ('direccion', 'admin', True),
    'finanzas':        ('administracion', 'operador', False),
    'compras':         ('compras', 'operador', False),
    'ventas':          ('comercial', 'operador', False),
    'almacen':         ('almacen_logistica', 'operador', False),
    'logistica':       ('almacen_logistica', 'supervisor', False),
}
def uid(nombre): return f"00000000-0000-4000-8000-{abs(hash_estable(nombre)):012d}"[:36]
def hash_estable(s): return sum((i + 1) * ord(c) for i, c in enumerate(s)) * 7919

def psql(sql, db=DB):
    r = subprocess.run(['psql', '-X', '-q', '-d', db, '-v', 'ON_ERROR_STOP=0'], input=sql, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return r.stdout

def lista_sql(sql, db=DB):
    r = subprocess.run(['psql', '-X', '-At', '-d', db], input=sql, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return [l.strip() for l in r.stdout.splitlines() if l.strip()]

def crear_usuarios():
    filas = []
    for n, (area, nivel, sa) in ROLES.items():
        u = uid(n); em = f"{n}@ejemplo.test"
        filas.append(f"""
INSERT INTO public.altas_autorizadas (email, expira_at) VALUES ('{em}', now() + interval '3 minutes')
  ON CONFLICT (email) DO UPDATE SET expira_at = EXCLUDED.expira_at;
INSERT INTO auth.users (id, email) VALUES ('{u}', '{em}') ON CONFLICT (id) DO NOTHING;
UPDATE public.profiles SET nombre_completo = 'Sintético {n}', activo = true, es_vendedor = {str(area == 'comercial').lower()} WHERE id = '{u}';
DELETE FROM public.user_roles WHERE user_id = '{u}';
INSERT INTO public.user_roles (user_id, area, nivel) VALUES ('{u}', '{area}', '{nivel}');""")
        if sa: filas.append(f"INSERT INTO public.super_admins (user_id) VALUES ('{u}') ON CONFLICT DO NOTHING;")
    out = psql('\n'.join(filas))
    return [l for l in out.splitlines() if 'ERROR' in l]

def accion(nombre, cuerpo):
    """cuerpo: ('q', sql escalar) o ('dml', sentencia). Cada acción se deshace sola (subtransacción)
    para que una no contamine a la siguiente. Emite RES|nombre|ok/err|valor."""
    tipo, sql = cuerpo
    sql = sql.replace("'", "''")
    if tipo == 'q':
        ejecuta = f"EXECUTE '{sql}' INTO n;"
    else:
        ejecuta = f"EXECUTE '{sql}'; GET DIAGNOSTICS n = ROW_COUNT;"
    return f"""DO $do$ DECLARE n bigint; BEGIN BEGIN {ejecuta}
  RAISE EXCEPTION 'deshacer' USING ERRCODE = 'RB001';
  EXCEPTION WHEN SQLSTATE 'RB001' THEN RAISE NOTICE 'RES|{nombre}|ok|%', n;
            WHEN OTHERS THEN RAISE NOTICE 'RES|{nombre}|err|%', SQLSTATE; END; END $do$;"""

def corrida(rol_pg, claims_uid, acciones):
    sql = "BEGIN;\n" + f"SET LOCAL ROLE {rol_pg};\n"
    if claims_uid:
        sql += f"SELECT set_config('request.jwt.claim.sub', '{claims_uid}', true), set_config('request.jwt.claims', '{{\"sub\":\"{claims_uid}\",\"role\":\"authenticated\"}}', true) \\g /dev/null\n"
    sql += '\n'.join(accion(n, c) for n, c in acciones) + "\nROLLBACK;\n"
    res = {}
    for l in psql(sql).splitlines():
        m = re.search(r'RES\|([^|]+)\|(ok|err)\|(.*)$', l)
        if m: res[m.group(1)] = ('ok ' if m.group(2) == 'ok' else 'err ') + m.group(3).strip()
    return res

def acciones_rol(n):
    u = uid(n); otro = uid('ventas' if n != 'ventas' else 'compras')
    return [
        ('leer remisiones',                  ('q', 'select count(*) from public.remisiones')),
        ('leer clientes',                    ('q', 'select count(*) from public.clientes')),
        ('leer movimientos financieros',     ('q', 'select count(*) from public.movimientos_financieros')),
        ('leer vista de cobranza',           ('q', 'select count(*) from public.v_cobranza_remisiones')),
        ('leer refacciones',                 ('q', 'select count(*) from public.almacen_refacciones_productos')),
        ('leer su propio rol',               ('q', f"select count(*) from public.user_roles where user_id = '{u}'")),
        ('editar su nombre (dispara triggers)', ('dml', f"update public.profiles set nombre_completo = nombre_completo || '' where id = '{u}'")),
        ('desactivarse a sí mismo',          ('dml', f"update public.profiles set activo = false where id = '{u}'")),
        ('asignarse el rol admin',           ('dml', f"insert into public.user_roles (user_id, area, nivel) values ('{u}', 'direccion', 'admin')")),
        ('subirse a administrador',          ('dml', f"update public.user_roles set area = 'direccion', nivel = 'admin' where user_id = '{u}'")),
        ('editar el nombre de otra persona', ('dml', f"update public.profiles set nombre_completo = 'x' where id = '{otro}'")),
        ('cambiar el correo de otra persona', ('dml', f"update public.profiles set email = 'x@ejemplo.test' where id = '{otro}'")),
        ('editar el nombre de OTRA ÁREA (finanzas)', ('dml', f"update public.profiles set nombre_completo = 'x' where id = '{uid('finanzas')}' and id <> '{u}'")),
        ('editar el nombre del SUPER ADMIN',  ('dml', f"update public.profiles set nombre_completo = 'x' where id = '{uid('super_admin')}' and id <> '{u}'")),
        ('cambiar el correo del SUPER ADMIN', ('dml', f"update public.profiles set email = 'x@ejemplo.test' where id = '{uid('super_admin')}' and id <> '{u}'")),
        ('quitarle el rol al SUPER ADMIN',    ('dml', f"delete from public.user_roles where user_id = '{uid('super_admin')}' and user_id <> '{u}'")),
        ('ver la tabla de super admins',     ('q', 'select count(*) from public.super_admins')),
        ('registrar su conexión (RPC)',      ('q', 'select count(*) from (select public.registrar_conexion()) s')),
        ('preguntar si es super admin (RPC)', ('q', f"select case when public.es_super_admin('{u}') then 1 else 0 end")),
        ('vaciar la bitácora de eventos',    ('dml', 'truncate public.bitacora_eventos')),
    ]

def generico():
    g = {}
    tablas = lista_sql("select relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','p') order by 1")
    vistas = lista_sql("select relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='v' order by 1")
    trig = lista_sql("select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prorettype='trigger'::regtype and not exists (select 1 from pg_depend d where d.objid=p.oid and d.deptype='e') order by 1")
    def barrido(rol, items, plantilla):
        cuentas = {}
        for it in items:
            r = corrida(rol, uid('ventas') if rol == 'authenticated' else None, [(it, ('dml' if plantilla[0] != 'q' else 'q', plantilla[1].format(t=it)))])
            v = r.get(it, 'sin resultado')
            if v.startswith('ok'):
                n = int(v.split()[1]) if len(v.split()) > 1 and v.split()[1].isdigit() else 0
                es_borrado = plantilla[1].startswith(('delete', 'insert'))
                v = ('ok (0 filas)' if n == 0 else 'ok (AFECTÓ FILAS)') if es_borrado else 'ok'
            cuentas[v] = cuentas.get(v, 0) + 1
        return dict(sorted(cuentas.items()))
    g['authenticated: TRUNCATE por tabla (%d tablas)' % len(tablas)] = barrido('authenticated', tablas, ('dml', 'truncate public.{t}'))
    g['anon: TRUNCATE por tabla'] = barrido('anon', tablas, ('dml', 'truncate public.{t}'))
    g['anon: DELETE sin filtro por tabla'] = barrido('anon', tablas, ('dml', 'delete from public.{t}'))
    g['anon: INSERT por tabla'] = barrido('anon', tablas, ('dml', 'insert into public.{t} default values'))
    g['anon: leer vistas (%d vistas)' % len(vistas)] = barrido('anon', vistas, ('q', 'select count(*) from public.{t}'))
    g['authenticated: leer vistas'] = barrido('authenticated', vistas, ('q', 'select count(*) from public.{t}'))
    g['authenticated: llamar funciones de trigger por RPC (%d)' % len(trig)] = barrido('authenticated', trig, ('q', 'select count(*) from (select public.{t}()) s'))
    g['anon: llamar funciones de trigger por RPC'] = barrido('anon', trig, ('q', 'select count(*) from (select public.{t}()) s'))
    return g

def alta_de_usuario():
    """El alta la hace GoTrue con el rol supabase_auth_admin: debe pasar con autorización y fallar sin ella."""
    prep = """GRANT USAGE ON SCHEMA auth TO supabase_auth_admin; GRANT INSERT, SELECT ON auth.users TO supabase_auth_admin;
INSERT INTO public.altas_autorizadas (email, expira_at) VALUES ('alta.autorizada@ejemplo.test', now() + interval '3 minutes') ON CONFLICT (email) DO UPDATE SET expira_at = EXCLUDED.expira_at;"""
    psql(prep)
    ok = psql("""BEGIN; SET LOCAL ROLE supabase_auth_admin;
DO $do$ BEGIN BEGIN INSERT INTO auth.users (id, email) VALUES ('00000000-0000-4000-8000-0000000a1a1a', 'alta.autorizada@ejemplo.test');
RAISE NOTICE 'RES|alta autorizada|ok|%', 1; EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'RES|alta autorizada|err|%', SQLSTATE; END; END $do$;
DO $do$ BEGIN BEGIN INSERT INTO auth.users (id, email) VALUES ('00000000-0000-4000-8000-0000000b1b1b', 'sin.autorizacion@ejemplo.test');
RAISE NOTICE 'RES|alta sin autorización|ok|%', 1; EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'RES|alta sin autorización|err|%', SQLSTATE; END; END $do$;
RESET ROLE; SELECT 'RES|perfil creado por handle_new_user|' || count(*) FROM public.profiles WHERE id = '00000000-0000-4000-8000-0000000a1a1a';
ROLLBACK;""")
    res = {}
    for l in ok.splitlines():
        m = re.search(r'RES\|([^|]+)\|(ok|err)\|(.*)$', l)
        if m: res[m.group(1)] = ('ok ' if m.group(2) == 'ok' else 'err ') + m.group(3).strip()
        m = re.search(r'RES\|perfil creado por handle_new_user\|(\d+)', l)
        if m: res['perfil creado por handle_new_user'] = 'ok ' + m.group(1)
    return res

if __name__ == '__main__':
    errs = crear_usuarios()
    if lista_sql("select count(*) from public.clientes") == ['0']:
        psql(open(__file__.replace('probar-recorridos.py', 'datos-sinteticos.sql')).read())
    out = {'errores_al_crear_usuarios': errs, 'roles': {}, 'generico': {}}
    for n in ROLES:
        out['roles'][n] = corrida('authenticated', uid(n), acciones_rol(n))
    out['generico'] = generico()
    out['alta_de_usuario'] = alta_de_usuario()
    txt = json.dumps(out, ensure_ascii=False, indent=1, sort_keys=True)
    if SALIDA: open(SALIDA, 'w').write(txt)
    print(txt if not SALIDA else f"guardado en {SALIDA}")

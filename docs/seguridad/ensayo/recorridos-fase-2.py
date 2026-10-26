#!/usr/bin/env python3
"""Recorridos por rol de la Fase 2 (perfiles, roles, super admins y cartera vencida).

Corre sobre la réplica local (construir-replica-fiel.py + Fase 1). Usuarios SINTÉTICOS
(@ejemplo.test), ningún dato real. Cada acción corre en una subtransacción que se revierte.
Para cada acción hay un resultado ESPERADO por rol (lo que la Fase 2 debe dejar):
  ok    = la acción debe poder hacerse (1 fila afectada / dato visible)
  bloq  = debe quedar rechazada (error o 0 filas)
El script informa las diferencias entre lo esperado y lo real: antes de la Fase 2 muestran los
huecos; después no debe haber ninguna.

Uso: PGHOST=/var/run/postgresql PGUSER=root recorridos-fase-2.py <base> [salida.json]
Límite: nivel SQL (RLS, permisos, triggers, funciones). No cubre Auth, API, edge functions ni pantallas.
"""
import json, re, subprocess, sys

DB = sys.argv[1]
SALIDA = sys.argv[2] if len(sys.argv) > 2 else None

# nombre: (area, nivel, es_vendedor, es_administrativo, super)  · area None = sin fila en user_roles
ROLES = {
    'sin_area':        (None, None, False, False, False),
    'vendedor':        ('comercial', 'operador', True, False, False),
    'vendedor_2':      ('comercial', 'operador', True, False, False),
    'administrativo':  ('comercial', 'operador', False, True, False),
    'admin_de_area':   ('comercial', 'admin', False, False, False),
    'admin_par':       ('comercial', 'admin', False, False, False),   # otro admin de la misma área
    'admin_otra_area': ('administracion', 'admin', False, False, False),
    'admin_global':    ('direccion', 'admin', False, False, False),   # Dirección/admin que NO es super admin
    'super_admin':     ('direccion', 'admin', False, False, True),
    'super_admin_2':   ('direccion', 'admin', False, False, True),
    'operador_fabrica': ('fabrica', 'operador', False, False, False),
    'finanzas':        ('administracion', 'operador', False, False, False),
    # destino de las ediciones (no actúa)
    'objetivo_comercial': ('comercial', 'operador', False, False, False),
}
ACTORES = [r for r in ROLES if r != 'objetivo_comercial']
def uid(n): return f"00000000-0000-4000-8000-{abs(sum((i + 1) * ord(c) for i, c in enumerate(n)) * 7919):012d}"[:36]

def psql(sql):
    r = subprocess.run(['psql', '-X', '-q', '-d', DB, '-v', 'ON_ERROR_STOP=0'], input=sql, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return r.stdout

def crear_usuarios():
    f = []
    for n, (area, nivel, ev, ea, sa) in ROLES.items():
        u = uid(n); em = f"{n}@ejemplo.test"
        f.append(f"""INSERT INTO public.altas_autorizadas (email, expira_at) VALUES ('{em}', now() + interval '3 minutes')
  ON CONFLICT (email) DO UPDATE SET expira_at = EXCLUDED.expira_at;
INSERT INTO auth.users (id, email) VALUES ('{u}', '{em}') ON CONFLICT (id) DO NOTHING;
UPDATE public.profiles SET nombre_completo = 'Sintético {n}', activo = true, es_vendedor = {str(ev).lower()},
  es_administrativo = {str(ea).lower()}, email = '{em}', codigo_vendedor = NULL WHERE id = '{u}';
DELETE FROM public.user_roles WHERE user_id = '{u}';""")
        if area: f.append(f"INSERT INTO public.user_roles (user_id, area, nivel) VALUES ('{u}', '{area}', '{nivel}');")
        f.append(f"DELETE FROM public.super_admins WHERE user_id = '{u}';")
        if sa: f.append(f"INSERT INTO public.super_admins (user_id) VALUES ('{u}');")
    # Un cliente de 'vendedor' con una cuenta por cobrar vencida (datos inventados) para probar la cartera.
    f.append(f"""DO $$ DECLARE c uuid; BEGIN
  SELECT id INTO c FROM public.clientes LIMIT 1;
  IF c IS NULL THEN c := ensayo.fila('public.clientes'::regclass); END IF;
  UPDATE public.clientes SET vendedor_id = '{uid('vendedor')}' WHERE id = c;
  DELETE FROM public.cuentas_por_cobrar;
  INSERT INTO public.cuentas_por_cobrar (cliente_id, concepto, monto, saldo, estatus, fecha_emision, fecha_vencimiento)
    VALUES (c, 'sintética', 100, 100, 'ABIERTA', current_date - 40, current_date - 10);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'cartera sintética omitida: %', SQLERRM; END $$;""")
    return [l for l in psql('\n'.join(f)).splitlines() if 'ERROR' in l or 'omitida' in l]

def accion(nombre, tipo, sql):
    sql = sql.replace("'", "''")
    ej = f"EXECUTE '{sql}' INTO n;" if tipo == 'q' else f"EXECUTE '{sql}'; GET DIAGNOSTICS n = ROW_COUNT;"
    return f"""DO $do$ DECLARE n bigint; BEGIN BEGIN {ej}
  RAISE EXCEPTION 'deshacer' USING ERRCODE = 'RB001';
  EXCEPTION WHEN SQLSTATE 'RB001' THEN RAISE NOTICE 'RES|{nombre}|ok|%', n;
            WHEN OTHERS THEN RAISE NOTICE 'RES|{nombre}|err|%', SQLSTATE; END; END $do$;"""

def corrida(actor, acciones):
    sql = f"BEGIN;\nSET LOCAL ROLE authenticated;\nSELECT set_config('request.jwt.claim.sub', '{uid(actor)}', true), set_config('request.jwt.claims', '{{\"sub\":\"{uid(actor)}\",\"role\":\"authenticated\"}}', true) \\g /dev/null\n"
    sql += '\n'.join(accion(n, t, s) for n, t, s in acciones) + "\nROLLBACK;\n"
    res = {}
    for l in psql(sql).splitlines():
        m = re.search(r'RES\|([^|]+)\|(ok|err)\|(.*)$', l)
        if m: res[m.group(1)] = (m.group(2), m.group(3).strip())
    return res

CX, F = uid('objetivo_comercial'), uid('finanzas')
CLI = {'id': '00000000-0000-0000-0000-000000000000'}   # cliente de 'vendedor' con cartera vencida (se fija en correr())
MISMA_AREA_ADMIN = {'admin_de_area', 'admin_par', 'admin_global', 'super_admin', 'super_admin_2'}
GLOBALES = {'admin_global', 'super_admin', 'super_admin_2'}
SUPERS = {'super_admin', 'super_admin_2'}
def otro_super(a): return uid('super_admin_2') if a == 'super_admin' else uid('super_admin')

# (nombre, constructor(actor) -> (tipo, sql), esperado(actor) -> True si DEBE poder)
def catalogo():
    u = uid
    A = [
        ('C1 propio: cambiar su nombre',           lambda a: ('dml', f"update public.profiles set nombre_completo = 'Nombre nuevo' where id = '{u(a)}'"), lambda a: True),
        ('C1 propio: ponerse es_vendedor',         lambda a: ('dml', f"update public.profiles set es_vendedor = true where id = '{u(a)}' and not es_vendedor"), lambda a: False),
        ('C1 propio: ponerse es_administrativo',   lambda a: ('dml', f"update public.profiles set es_administrativo = true where id = '{u(a)}' and not es_administrativo"), lambda a: False),
        ('C1 propio: desactivarse',                lambda a: ('dml', f"update public.profiles set activo = false where id = '{u(a)}'"), lambda a: False),
        ('C1 propio: cambiar su código de vendedor', lambda a: ('dml', f"update public.profiles set codigo_vendedor = 'ZZ9' where id = '{u(a)}'"), lambda a: False),
        ('C1 propio: cambiar su correo',           lambda a: ('dml', f"update public.profiles set email = 'otro@ejemplo.test' where id = '{u(a)}'"), lambda a: False),
        ('C1 propio: cambiarse el rol', lambda a: ('dml', f"update public.user_roles set area = 'direccion', nivel = case when nivel = 'admin' then 'supervisor' else 'admin' end where user_id = '{u(a)}'"), lambda a: False),
        ('C2 otro usuario de su área: es_vendedor', lambda a: ('dml', f"update public.profiles set es_vendedor = true where id = '{CX}'"), lambda a: a in MISMA_AREA_ADMIN),
        ('C2 otro usuario de su área: es_administrativo', lambda a: ('dml', f"update public.profiles set es_administrativo = true where id = '{CX}'"), lambda a: a in MISMA_AREA_ADMIN),
        ('C2 otro usuario de su área: desactivar',  lambda a: ('dml', f"update public.profiles set activo = false where id = '{CX}'"), lambda a: a in MISMA_AREA_ADMIN),
        ('C2 otro usuario de su área: cambiar nombre', lambda a: ('dml', f"update public.profiles set nombre_completo = 'x' where id = '{CX}'"), lambda a: a in MISMA_AREA_ADMIN),
        ('C2 usuario de OTRA área: cambiar nombre', lambda a: ('dml', f"update public.profiles set nombre_completo = 'x' where id = '{F}' and id <> '{u(a)}'"), lambda a: a in GLOBALES or a == 'admin_otra_area'),
        ('C2 usuario de OTRA área: es_administrativo', lambda a: ('dml', f"update public.profiles set es_administrativo = true where id = '{F}' and id <> '{u(a)}'"), lambda a: a in GLOBALES or a == 'admin_otra_area'),
        ('C2 otro administrador de su área: cambiar nombre', lambda a: ('dml', f"update public.profiles set nombre_completo = 'x' where id = '{u('admin_par')}' and id <> '{u(a)}'"), lambda a: a in GLOBALES),
        ('C2 subir de nivel a un operador de su área', lambda a: ('dml', f"update public.user_roles set nivel = 'admin' where user_id = '{CX}'"), lambda a: a in GLOBALES),
        ('C2 pasar a un usuario a otra área',       lambda a: ('dml', f"update public.user_roles set area = 'administracion' where user_id = '{CX}'"), lambda a: a in GLOBALES),
        ('C2 hacer administrador global a un usuario', lambda a: ('dml', f"update public.user_roles set area = 'direccion', nivel = 'admin' where user_id = '{CX}'"), lambda a: a in GLOBALES),
        ('C3 super admin: cambiar su nombre',      lambda a: ('dml', f"update public.profiles set nombre_completo = 'x' where id = '{otro_super(a)}'"), lambda a: a in SUPERS),
        ('C3 super admin: cambiar su correo',      lambda a: ('dml', f"update public.profiles set email = 'x@ejemplo.test' where id = '{otro_super(a)}'"), lambda a: a in SUPERS),
        ('C3 super admin: desactivarlo',           lambda a: ('dml', f"update public.profiles set activo = false where id = '{otro_super(a)}'"), lambda a: a in SUPERS),
        ('C3 super admin: quitarle el rol',        lambda a: ('dml', f"delete from public.user_roles where user_id = '{otro_super(a)}'"), lambda a: a in SUPERS),
        ('C3 super admin: bajarle el nivel',       lambda a: ('dml', f"update public.user_roles set nivel = 'operador' where user_id = '{otro_super(a)}'"), lambda a: a in SUPERS),
        ('C3 lista: escribir en super_admins',     lambda a: ('dml', f"insert into public.super_admins (user_id) values ('{CX}')"), lambda a: False),
        ('C3 lista: borrar de super_admins',       lambda a: ('dml', f"delete from public.super_admins where user_id = '{otro_super(a)}'"), lambda a: False),
        ('C3 asignar_super_admin (RPC) a un usuario normal', lambda a: ('q', f"select count(*) from (select public.asignar_super_admin('{CX}', true)) s"), lambda a: a == 'admin_global'),
        # C5: la función debe responder solo a quien ya puede ver al cliente (misma regla que la tabla). No ve al cliente: otro vendedor y quien no tiene área.
        ('C5 cartera vencida: ¿tiene? (cliente de vendedor)', lambda a: ('q', f"select case when public.cliente_tiene_cxc_vencidas('{CLI['id']}') then 1 else 0 end"), lambda a: a not in ('sin_area', 'vendedor_2')),
        ('C5 cartera vencida: resumen (cliente de vendedor)', lambda a: ('q', f"select count(*) from public.cxc_vencidas_resumen('{CLI['id']}')"), lambda a: a not in ('sin_area', 'vendedor_2')),
        ('C5 leer la tabla cuentas_por_cobrar (referencia)', lambda a: ('q', "select count(*) from public.cuentas_por_cobrar"), None),
    ]
    return A

def correr():
    if subprocess.run(['psql', '-X', '-At', '-d', DB, '-c', 'select count(*) from public.clientes'], text=True, capture_output=True).stdout.strip() == '0':
        psql(open(__file__.replace('recorridos-fase-2.py', 'datos-sinteticos.sql')).read())
    out = {'errores_al_crear': crear_usuarios(), 'resultados': {}, 'diferencias': []}
    cid = subprocess.run(['psql', '-X', '-At', '-d', DB, '-c', f"select id from public.clientes where vendedor_id = '{uid('vendedor')}' limit 1"], text=True, capture_output=True).stdout.strip()
    if cid: CLI['id'] = cid
    cat = catalogo()
    for a in ACTORES:
        res = corrida(a, [(n, *c(a)) for n, c, e in cat])
        out['resultados'][a] = {n: f"{v[0]} {v[1]}" for n, v in res.items()}
        for n, c, e in cat:
            if e is None: continue
            tipo, val = res.get(n, ('err', 'sin resultado'))
            puede = tipo == 'ok' and val.isdigit() and int(val) > 0
            if puede != e(a):
                out['diferencias'].append({'rol': a, 'accion': n, 'esperado': 'puede' if e(a) else 'bloqueado', 'real': f'{tipo} {val}'})
    # Sin sesión de usuario (service_role / SQL interno): la base NO restringe; las Edge Functions deben validar en código.
    sql = "BEGIN;\n" + accion('servicio: es_vendedor de otro', 'dml', f"update public.profiles set es_vendedor = true where id = '{CX}'") + "\nROLLBACK;\n"
    out['sin_sesion_de_usuario'] = {m.group(1): m.group(2) + ' ' + m.group(3).strip() for l in psql(sql).splitlines() for m in [re.search(r'RES\|([^|]+)\|(ok|err)\|(.*)$', l)] if m}
    # C5: el dueño y quien ve a todos los clientes siguen viendo la cartera; los demás vendedores no.
    c5 = {a: out['resultados'][a].get('C5 cartera vencida: ¿tiene? (cliente de vendedor)') for a in ACTORES}
    out['cartera_por_rol'] = c5
    return out

if __name__ == '__main__':
    r = correr()
    txt = json.dumps(r, ensure_ascii=False, indent=1, sort_keys=True)
    if SALIDA: open(SALIDA, 'w').write(txt)
    print(f"{len(r['diferencias'])} diferencias entre lo esperado y lo real" + (f"; guardado en {SALIDA}" if SALIDA else ''))
    if not SALIDA: print(txt)

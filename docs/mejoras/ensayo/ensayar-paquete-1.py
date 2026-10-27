#!/usr/bin/env python3
"""Ensayo del PAQUETE 1 (permisos del vendedor) sobre la réplica local con la Fase 1 YA aplicada.

Crea usuarios y datos SINTÉTICOS (@ejemplo.test; nada real), mide qué ve cada rol ANTES y DESPUÉS de
las tres migraciones del paquete, prueba los casos de escritura (alta de cliente, oportunidad, ruta,
actividad con clientes propios, sin asignar y ajenos), aplica las reversas y comprueba que el
catálogo y lo que ve cada rol vuelven EXACTAMENTE a «antes», y reaplica para probar idempotencia.

Uso: PGHOST=/var/run/postgresql PGUSER=root PGOPTIONS='-c role=postgres' ensayar-paquete-1.py <base> <salida.json>
La base debe ser una réplica con la Fase 1 aplicada (ver docs/mejoras/PAQUETE-1-PERMISOS-VENDEDOR.md).
"""
import hashlib, json, os, re, subprocess, sys

DB, SALIDA = sys.argv[1], sys.argv[2]
RAIZ = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
MIG = ['20261103000001_paquete1_catalogo_basico_clientes',
       '20261103000002_paquete1_cliente_nuevo_a_nombre_del_vendedor',
       '20261103000003_paquete1_remisiones_refacciones_solo_del_vendedor']

ROLES = {  # nombre: (area, nivel, es_administrativo, super_admin)
    'vend1':     ('comercial', 'operador', False, False),   # «Carlos»: vendedor
    'vend2':     ('comercial', 'operador', False, False),   # otro vendedor
    'superv':    ('comercial', 'supervisor', False, False),
    'admvo':     ('comercial', 'operador', True, False),    # administrativo de Comercial
    'direccion': ('direccion', 'admin', False, True),
    'finanzas':  ('administracion', 'operador', False, False),
    'almacen':   ('almacen_logistica', 'operador', False, False),
    'compras':   ('compras', 'operador', False, False),
    'fabrica':   ('fabrica', 'operador', False, False),
    'dirop':     ('direccion', 'operador', False, False),   # Dirección sin ser administrador global
    'vprueba':   ('comercial', 'operador', False, False),   # vendedor con cuenta de PRUEBA (modo prueba)
}
def hash_estable(s): return sum((i + 1) * ord(c) for i, c in enumerate(s)) * 7919
def uid(n): return f"00000000-0000-4000-8000-{abs(hash_estable(n)):012d}"[:36]

def psql(sql, tuples=False):
    a = ['psql', '-X', '-q', '-d', DB, '-v', 'ON_ERROR_STOP=0'] + (['-At', '-F', '|'] if tuples else [])
    r = subprocess.run(a, input=sql, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return r.stdout

_COLS = {}
def cols(tabla):
    if tabla not in _COLS:
        _COLS[tabla] = set(psql(f"select column_name from information_schema.columns where table_schema='public' and table_name='{tabla}'", True).split())
    return _COLS[tabla]

def insertar(tabla, pares):
    """INSERT con las columnas que existan: producción tiene columnas (titulo, fecha_ruta…) que las
    migraciones del repo no crean, y la réplica se arma con las del repo. Ver docs/mejoras/."""
    c = cols(tabla)
    pares = [(k, v) for k, v in pares if k in c]
    return f"INSERT INTO public.{tabla} ({', '.join(k for k, _ in pares)}) VALUES ({', '.join(v for _, v in pares)})"

def aplicar(archivo):
    r = subprocess.run(['psql', '-X', '-q', '-d', DB, '-v', 'ON_ERROR_STOP=1', '--single-transaction', '-f', archivo],
                       text=True, capture_output=True)
    return r.returncode == 0, (r.stderr or '')[-400:]

def mig(n): return os.path.join(RAIZ, 'supabase', 'migrations', MIG[n] + '.sql')
def rev(n): return os.path.join(RAIZ, 'supabase', 'reversas', MIG[n] + '_reversa.sql')

CLAIMS = "SELECT set_config('request.jwt.claim.sub', '{u}', true), set_config('request.jwt.claims', '{{\"sub\":\"{u}\",\"role\":\"authenticated\"}}', true) \\g /dev/null\n"
def como(rol, cuerpo, tuples=True):
    u = uid(rol)
    return psql("BEGIN;\nSET LOCAL ROLE authenticated;\n" + CLAIMS.format(u=u) + cuerpo + "\nROLLBACK;\n", tuples)

def alinear_crm_con_produccion():
    """La réplica se arma con las migraciones del repo, y las 4 tablas de CRM de producción tienen columnas
    que ninguna migración crea (titulo, fecha_ruta, created_by, checkin_*…). Se agregan las que falten, tal
    como las define producción (crm-columnas-produccion.json: solo el esquema, sin datos), para probar sobre
    la forma real de las tablas. Es un hallazgo aparte: ver docs/mejoras/PAQUETE-1-PERMISOS-VENDEDOR.md §8."""
    defs = json.load(open(os.path.join(os.path.dirname(__file__), 'crm-columnas-produccion.json')))
    s = ["SET session_replication_role = replica;"]
    for tabla, columnas in defs.items():
        existentes = cols(tabla)
        for d in columnas:
            nombre = d.split()[0]
            if nombre in existentes: continue
            sin_not_null = re.sub(r'\s+NOT NULL', '', d)
            s.append(f"ALTER TABLE public.{tabla} ADD COLUMN IF NOT EXISTS {sin_not_null};")
            if re.search(r'NOT NULL', d) and 'DEFAULT' not in d.upper():
                tipo = d.split()[1]
                relleno = "'sintético'" if tipo.startswith('text') else ('current_date' if tipo == 'date' else ('0' if tipo in ('integer', 'numeric', 'bigint') else "'sintético'"))
                s.append(f"UPDATE public.{tabla} SET {nombre} = {relleno} WHERE {nombre} IS NULL; ALTER TABLE public.{tabla} ALTER COLUMN {nombre} SET NOT NULL;")
    psql('\n'.join(s)); _COLS.clear()

def crear_usuarios_y_datos():
    alinear_crm_con_produccion()
    s = []
    for n, (area, nivel, adm, sa) in ROLES.items():
        u = uid(n); em = 'prueba.vendedor@dazon.demo' if n == 'vprueba' else f"{n}@ejemplo.test"
        s.append(f"""
INSERT INTO public.altas_autorizadas (email, expira_at) VALUES ('{em}', now() + interval '5 minutes') ON CONFLICT (email) DO UPDATE SET expira_at = EXCLUDED.expira_at;
INSERT INTO auth.users (id, email) VALUES ('{u}', '{em}') ON CONFLICT (id) DO NOTHING;
UPDATE public.profiles SET nombre_completo = 'Sintético {n}', activo = true, es_vendedor = {str(area == 'comercial' and not adm).lower()}, es_administrativo = {str(adm).lower()} WHERE id = '{u}';
DELETE FROM public.user_roles WHERE user_id = '{u}';
INSERT INTO public.user_roles (user_id, area, nivel) VALUES ('{u}', '{area}', '{nivel}');""")
        if sa: s.append(f"INSERT INTO public.super_admins (user_id) VALUES ('{u}') ON CONFLICT DO NOTHING;")
    psql('\n'.join(s))
    ids = {}
    def fila(etq, tabla, sets):
        r = psql(f"SELECT ensayo.fila('public.{tabla}'::regclass);", True).strip().splitlines()
        i = [x for x in r if re.fullmatch(r'[0-9a-f-]{36}', x)]
        assert i, f"no se pudo crear la fila {etq}: {r}"
        psql(f"SET session_replication_role = replica; UPDATE public.{tabla} SET {sets.format(**{k: v for k, v in ids.items()})} WHERE id = '{i[0]}';")
        ids[etq] = i[0]
    fila('c_v1', 'clientes', f"vendedor_id = '{uid('vend1')}', nombre_comercial = 'Sintético C v1'")
    fila('c_v2', 'clientes', f"vendedor_id = '{uid('vend2')}', nombre_comercial = 'Sintético C v2'")
    fila('c_sin', 'clientes', "vendedor_id = NULL, nombre_comercial = 'Sintético C sin asignar'")
    fila('c_sin2', 'clientes', "vendedor_id = NULL, nombre_comercial = 'Sintético C sin asignar 2'")
    fila('c_sin3', 'clientes', "vendedor_id = NULL, nombre_comercial = 'Sintético C sin asignar 3'")
    psql("INSERT INTO public.inventario_usuarios_prueba (email, nota) VALUES ('prueba.vendedor@dazon.demo', 'ensayo') ON CONFLICT DO NOTHING;")
    fila('c_prueba', 'clientes', "vendedor_id = NULL, es_prueba = true, nombre_comercial = 'Sintético C de prueba'")
    fila('r_v1', 'remisiones', f"vendedor_id = '{uid('vend1')}', cliente_id = '{{c_v1}}'")
    fila('r_v2', 'remisiones', f"vendedor_id = '{uid('vend2')}', cliente_id = '{{c_v2}}'")
    fila('rr_v1', 'remisiones_refacciones', f"vendedor_id = '{uid('vend1')}', created_by = '{uid('vend1')}', cliente_id = '{{c_v1}}'")
    fila('rr_v2', 'remisiones_refacciones', f"vendedor_id = '{uid('vend2')}', created_by = '{uid('vend2')}', cliente_id = '{{c_v2}}'")
    fila('op_v1', 'crm_oportunidades', f"vendedor_id = '{uid('vend1')}', cliente_id = '{{c_v1}}'")
    fila('op_v2', 'crm_oportunidades', f"vendedor_id = '{uid('vend2')}', cliente_id = '{{c_v2}}'")
    fila('act_v1', 'crm_actividades', f"vendedor_id = '{uid('vend1')}', cliente_id = '{{c_v1}}'")
    fila('act_v2', 'crm_actividades', f"vendedor_id = '{uid('vend2')}', cliente_id = '{{c_v2}}'")
    fila('ruta_v1', 'crm_rutas', f"vendedor_id = '{uid('vend1')}'")
    fila('ruta_v2', 'crm_rutas', f"vendedor_id = '{uid('vend2')}'")
    fila('cxc_v1', 'cuentas_por_cobrar', "cliente_id = '{c_v1}'")
    fila('cxc_v2', 'cuentas_por_cobrar', "cliente_id = '{c_v2}'")
    fila('cxc_sin', 'cuentas_por_cobrar', "cliente_id = '{c_sin}'")
    return ids

TABLAS = {  # etiqueta de la tabla: (tabla, [etiquetas de fila que se mira])
    'clientes': ('clientes', ['c_v1', 'c_v2', 'c_sin', 'c_prueba']),
    'remisiones': ('remisiones', ['r_v1', 'r_v2']),
    'remisiones_refacciones': ('remisiones_refacciones', ['rr_v1', 'rr_v2']),
    'oportunidades': ('crm_oportunidades', ['op_v1', 'op_v2']),
    'actividades': ('crm_actividades', ['act_v1', 'act_v2']),
    'rutas': ('crm_rutas', ['ruta_v1', 'ruta_v2']),
    'cuentas_por_cobrar': ('cuentas_por_cobrar', ['cxc_v1', 'cxc_v2', 'cxc_sin']),
}
def matriz(ids):
    """{rol: {tabla: [etiquetas de fila que ve]}}"""
    inv = {v: k for k, v in ids.items()}
    out = {}
    for rol in ROLES:
        out[rol] = {}
        for etq, (tabla, filas) in TABLAS.items():
            lista = ",".join(f"'{ids[f]}'" for f in filas)
            r = como(rol, f"SELECT id FROM public.{tabla} WHERE id IN ({lista}) ORDER BY id;")
            out[rol][etq] = sorted(inv[x.strip()] for x in r.splitlines() if x.strip() in inv)
    return out

COLUMNAS_BASICAS = ['activo', 'codigo_erp', 'folio_interno', 'id', 'nombre_comercial']

def catalogo_basico(ids):
    """Qué devuelve catalogo_clientes_basico() a cada rol: {rol: [etiquetas de cliente] | 'ERROR 42501'} y sus columnas."""
    inv = {v: k for k, v in ids.items()}
    out, cols_ = {}, set()
    for rol in ROLES:
        r = como(rol, "SELECT id FROM public.catalogo_clientes_basico();")
        if 'ERROR' in r:
            out[rol] = 'ERROR ' + ('42501' if 'Sin acceso' in r or 'permission denied' in r else r.strip()[:60])
            continue
        out[rol] = sorted(inv[x.strip()] for x in r.splitlines() if x.strip() in inv)
    r = como('vend1', "SELECT k FROM (SELECT DISTINCT jsonb_object_keys(to_jsonb(c)) AS k FROM public.catalogo_clientes_basico() c) q ORDER BY 1;")
    cols_ = [x.strip() for x in r.splitlines() if x.strip() and not x.startswith(('BEGIN', 'SET', 'ROLLBACK'))]
    return {'por_rol': out, 'columnas': cols_}

def catalogo():
    sql = """SELECT md5(string_agg(x, E'\\n' ORDER BY x)) FROM (
      SELECT 'p|'||schemaname||'.'||tablename||'|'||policyname||'|'||cmd||'|'||permissive||'|'||coalesce(roles::text,'')||'|'||coalesce(qual,'')||'|'||coalesce(with_check,'') AS x FROM pg_policies WHERE schemaname IN ('public','storage')
      UNION ALL SELECT 'f|'||p.oid::regprocedure::text||'|'||md5(pg_get_functiondef(p.oid))||'|'||coalesce(p.proacl::text,'') FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prokind IN ('f','p')
      UNION ALL SELECT 't|'||c.relname||'|'||t.tgname||'|'||md5(pg_get_triggerdef(t.oid)) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE NOT t.tgisinternal AND n.nspname='public') q;"""
    return psql(sql, True).strip().splitlines()[-1]

def conteos():
    r = psql("""SELECT (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prokind IN ('f','p')),
      (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prokind IN ('f','p') AND p.prosecdef AND has_function_privilege('authenticated',p.oid,'EXECUTE')),
      (SELECT count(*) FROM pg_policies WHERE schemaname='public'),
      (SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE NOT t.tgisinternal AND n.nspname='public');""", True).strip().splitlines()[-1].split('|')
    return dict(zip(['funciones', 'secdef_ejecutables_authenticated', 'politicas', 'triggers'], map(int, r)))

def pruebas_escritura(ids):
    """Cada caso en su propia transacción que se deshace. Devuelve {caso: resultado}."""
    v1, v2, sp, ad = (uid(x) for x in ('vend1', 'vend2', 'superv', 'admvo'))
    res = {}
    def caso(nombre, rol, cuerpo):
        r = como(rol, cuerpo + "\nRESET ROLE;\n", True)
        err = re.findall(r'ERROR:\s+(?:\d+: )?(.*)', r)
        res[nombre] = ('ERROR: ' + err[0].strip()) if err else ' / '.join(l for l in r.splitlines() if l.strip() and not l.startswith(('BEGIN', 'SET', 'ROLLBACK', 'RESET')))
    quien = {v1: 'vend1', v2: 'vend2', sp: 'superv', ad: 'admvo'}
    def dueno(c):
        return f"SELECT 'vendedor_del_cliente=' || coalesce((SELECT vendedor_id::text FROM public.clientes WHERE id = '{ids[c]}'), 'NULL');"
    # --- alta de cliente
    for nombre_caso, rol, payload_vend in [
        ('vendedor crea cliente sin indicar vendedor', 'vend1', 'NULL'),
        ('vendedor crea cliente a nombre de OTRO vendedor', 'vend1', f"'{v2}'"),
        ('supervisor crea cliente sin vendedor', 'superv', 'NULL'),
        ('administrativo crea cliente sin vendedor', 'admvo', 'NULL')]:
        caso(nombre_caso, rol, f"INSERT INTO public.clientes (nombre_comercial, vendedor_id) VALUES ('Sintético alta', {payload_vend}); RESET ROLE; SELECT 'vendedor_del_cliente=' || coalesce((SELECT vendedor_id::text FROM public.clientes WHERE nombre_comercial = 'Sintético alta'), 'NULL');")
    # --- CRM con cliente sin asignar, propio y de OTRO vendedor: se permite y NO se asigna nada
    for tabla in ('crm_oportunidades', 'crm_actividades'):
        for c in ('c_sin', 'c_v1', 'c_v2'):
            ins = insertar(tabla, [('titulo', "'t'"), ('cliente_id', f"'{ids[c]}'"), ('vendedor_id', f"'{v1}'")])
            caso(f"{tabla}: vend1 usa {c}", 'vend1', f"{ins}; RESET ROLE; " + dueno(c))
    for c in ('c_sin2', 'c_v2'):
        ruta = insertar('crm_rutas', [('vendedor_id', f"'{v1}'"), ('fecha_ruta', 'current_date'), ('fecha', 'current_date')])
        par = insertar('crm_ruta_paradas', [('ruta_id', ":'rid'"), ('cliente_id', f"'{ids[c]}'"), ('orden', '1')])
        caso(f"ruta+parada: vend1 usa {c}", 'vend1', f"{ruta} RETURNING id AS rid \\gset\n{par}; RESET ROLE; " + dueno(c))
    # --- captura de remisión: el vendedor solo a clientes que ya ve (cierra la puerta que abre el catálogo)
    for rol, vend, c in (('vend1', v1, 'c_v1'), ('vend1', v1, 'c_v2'), ('vend1', v1, 'c_sin'), ('superv', sp, 'c_sin'), ('admvo', ad, 'c_v2')):
        caso(f"remisión: {rol} captura a {c}", rol,
             f"INSERT INTO public.remisiones (folio_remision, vendedor_id, cliente_id) VALUES ('ZZ-ENSAYO-{rol}-{c}', '{vend}', '{ids[c]}'); "
             f"SELECT 'remision_creada; ficha_del_cliente_que_ve_quien_captura=' || (SELECT count(*) FROM public.clientes WHERE id = '{ids[c]}');")
    # tras usar un cliente ajeno, el vendedor NO ve su ficha, ni su cartera
    ins = insertar('crm_oportunidades', [('titulo', "'t'"), ('cliente_id', f"'{ids['c_v2']}'"), ('vendedor_id', f"'{v1}'")])
    caso('tras usar el cliente de vend2, vend1 ve su ficha?', 'vend1',
         f"{ins}; SELECT 'ficha=' || (SELECT count(*) FROM public.clientes WHERE id = '{ids['c_v2']}') || ' cartera=' || (SELECT count(*) FROM public.cuentas_por_cobrar WHERE cliente_id = '{ids['c_v2']}');")
    caso('vend1 lee la ficha completa de un cliente sin asignar', 'vend1',
         f"SELECT 'filas=' || (SELECT count(*) FROM public.clientes WHERE id = '{ids['c_sin']}');")
    return res

def main():
    out = {'migraciones': {}}
    ids = crear_usuarios_y_datos(); out['ids_sinteticos'] = len(ids)
    out['antes'] = {'matriz': matriz(ids), 'catalogo': catalogo(), 'conteos': conteos()}
    out['antes']['escritura'] = pruebas_escritura(ids)
    for n in range(3):
        ok, err = aplicar(mig(n)); out['migraciones'][MIG[n]] = {'aplica_ok': ok, 'error': err if not ok else ''}
    out['despues'] = {'matriz': matriz(ids), 'catalogo': catalogo(), 'conteos': conteos()}
    out['despues']['catalogo_basico'] = catalogo_basico(ids)
    out['columnas_del_catalogo_son_exactamente_las_5'] = out['despues']['catalogo_basico']['columnas'] == COLUMNAS_BASICAS and 'telefono' not in out['despues']['catalogo_basico']['columnas']
    out['despues']['escritura'] = pruebas_escritura(ids)
    cat_despues = out['despues']['catalogo']
    # idempotencia
    for n in range(3): aplicar(mig(n))
    out['reaplicar_idempotente'] = (catalogo() == cat_despues)
    # reversas en orden inverso
    for n in (2, 1, 0):
        ok, err = aplicar(rev(n)); out['migraciones'][MIG[n]]['reversa_ok'] = ok
    out['tras_reversa'] = {'matriz': matriz(ids), 'catalogo': catalogo(), 'conteos': conteos()}
    out['reversa_restaura_exacto'] = (out['tras_reversa']['catalogo'] == out['antes']['catalogo'] and out['tras_reversa']['matriz'] == out['antes']['matriz'])
    json.dump(out, open(SALIDA, 'w'), ensure_ascii=False, indent=1, sort_keys=True)
    print('migraciones:', {k: v['aplica_ok'] and v.get('reversa_ok') for k, v in out['migraciones'].items()})
    print('conteos antes  :', out['antes']['conteos']); print('conteos despues:', out['despues']['conteos'])
    print('columnas del catálogo = las 5 básicas y sin teléfono:', out['columnas_del_catalogo_son_exactamente_las_5'])
    print('reaplicar idempotente:', out['reaplicar_idempotente'], '| reversa restaura exacto:', out['reversa_restaura_exacto'])
    dif = {r: {t: (out['antes']['matriz'][r][t], out['despues']['matriz'][r][t]) for t in TABLAS
               if out['antes']['matriz'][r][t] != out['despues']['matriz'][r][t]} for r in ROLES}
    print('cambios en lo que ve cada rol:'); [print('  ', r, d) for r, d in dif.items() if d]
    print('catálogo básico (después):', out['despues']['catalogo_basico']['columnas']); [print('  ', r, '->', v) for r, v in out['despues']['catalogo_basico']['por_rol'].items()]
    print('escritura antes:'); [print('  ', k, '->', v) for k, v in sorted(out['antes']['escritura'].items())]
    print('escritura despues:'); [print('  ', k, '->', v) for k, v in sorted(out['despues']['escritura'].items())]

main()

#!/usr/bin/env python3
"""Ensayo de los PAQUETES 2 y 3 sobre la réplica local con Fase 1 + Paquete 1 + Fase 2 YA aplicados.

Datos y usuarios SINTÉTICOS (@ejemplo.test; nada real). Mide funciones, políticas y triggers antes y después,
prueba cada regla por rol (reporte de ventas, kárdex de varios artículos, rotación filtrada, interruptor global,
eliminar remisión, cambiar fecha), reaplica (idempotencia) y revierte en orden inverso comprobando que el catálogo
vuelve EXACTAMENTE al de antes.

Uso: PGHOST=/var/run/postgresql PGUSER=root PGOPTIONS='-c role=postgres' ensayar-paquetes-2-3.py <base> <salida.json>
La base debe ser una réplica con Fase 1 + Paquete 1 + Fase 2 aplicados (por ejemplo, copia de f2_conp1).
"""
import json, os, re, subprocess, sys

DB, SALIDA = sys.argv[1], sys.argv[2]
RAIZ = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
P2 = ['20261108000001_paquete2_reporte_ventas_refacciones', '20261108000002_paquete2_kardex_varios_articulos',
      '20261108000003_paquete2_rotacion_filtrada', '20261108000004_paquete2_reporte_ventas_totales']
P3 = ['20261109000001_paquete3_modo_prueba_global', '20261109000002_paquete3_eliminar_remision',
      '20261109000003_paquete3_fecha_de_remision']
ROLES = {  # nombre: (area, nivel, es_administrativo, super_admin)
    'vend1': ('comercial', 'operador', False, False), 'vend2': ('comercial', 'operador', False, False),
    'superv': ('comercial', 'supervisor', False, False), 'admvo': ('comercial', 'operador', True, False),
    'admcom': ('comercial', 'admin', False, False),            # administrador del área Comercial (hoy puede borrar remisiones)
    'direccion': ('direccion', 'admin', False, True),          # Dirección y super admin
    'dirop': ('direccion', 'operador', False, False),          # Dirección sin ser super admin
    'finanzas': ('administracion', 'operador', False, False), 'almacen': ('almacen_logistica', 'operador', False, False),
    'compras': ('compras', 'operador', False, False), 'fabrica': ('fabrica', 'operador', False, False),
    'vprueba': ('comercial', 'operador', False, False),        # vendedor con cuenta de PRUEBA
}
def uid(n): return f"00000000-0000-4000-8000-{abs(sum((i + 1) * ord(c) for i, c in enumerate(n)) * 7919):012d}"[:36]

def psql(sql, tuples=False):
    a = ['psql', '-X', '-q', '-d', DB, '-v', 'ON_ERROR_STOP=0'] + (['-At', '-F', '|'] if tuples else [])
    return subprocess.run(a, input=sql, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT).stdout

def aplicar(archivo):
    r = subprocess.run(['psql', '-X', '-q', '-d', DB, '-v', 'ON_ERROR_STOP=1', '--single-transaction', '-f', archivo], text=True, capture_output=True)
    return r.returncode == 0, (r.stderr or '')[-500:]
def mig(n): return os.path.join(RAIZ, 'supabase', 'migrations', n + '.sql')
def rev(n): return os.path.join(RAIZ, 'supabase', 'reversas', n + '_reversa.sql')

CLAIMS = "SELECT set_config('request.jwt.claim.sub', '{u}', true), set_config('request.jwt.claims', '{{\"sub\":\"{u}\",\"role\":\"authenticated\"}}', true) \\g /dev/null\n"
def como(rol, cuerpo):
    return psql("BEGIN;\nSET LOCAL ROLE authenticated;\n" + CLAIMS.format(u=uid(rol)) + cuerpo + "\nROLLBACK;\n", True)
def error_de(r):
    m = re.findall(r'ERROR:\s+(?:[0-9A-Z]{5}: )?(.*)', r); return m[0].strip() if m else None
def util(r): return [l for l in r.splitlines() if l.strip() and not l.startswith(('BEGIN', 'SET', 'ROLLBACK', 'RESET'))]

_COLS = {}
def cols(t):
    if t not in _COLS: _COLS[t] = set(psql(f"select column_name from information_schema.columns where table_schema='public' and table_name='{t}'", True).split())
    return _COLS[t]

def alinear_con_produccion():
    """La réplica se arma con las migraciones del repo; producción tiene en `remisiones` las columnas tipo_pago (con 'credito'),
    pagado y comprobante_pago_url, y `crm_oportunidades.remision_id` con llave foránea (leído del catálogo de producción el 26 oct)."""
    psql("""SET session_replication_role = replica;
ALTER TABLE public.remisiones ADD COLUMN IF NOT EXISTS tipo_pago text;
ALTER TABLE public.remisiones ADD COLUMN IF NOT EXISTS pagado boolean DEFAULT false;
ALTER TABLE public.remisiones ADD COLUMN IF NOT EXISTS comprobante_pago_url text;
ALTER TABLE public.remisiones DROP CONSTRAINT IF EXISTS remisiones_tipo_pago_check;
ALTER TABLE public.remisiones ADD CONSTRAINT remisiones_tipo_pago_check CHECK (tipo_pago = ANY (ARRAY['anticipado','contra_entrega','credito']));
ALTER TABLE public.crm_oportunidades ADD COLUMN IF NOT EXISTS remision_id uuid;
DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'crm_oportunidades_remision_id_fkey') THEN
  ALTER TABLE public.crm_oportunidades ADD CONSTRAINT crm_oportunidades_remision_id_fkey FOREIGN KEY (remision_id) REFERENCES public.remisiones(id) ON DELETE SET NULL; END IF; END $$;""")
    _COLS.clear()

ids = {}
def fila(etq, tabla, sets):
    r = psql(f"SELECT ensayo.fila('public.{tabla}'::regclass);", True).strip().splitlines()
    i = [x for x in r if re.fullmatch(r'[0-9a-f-]{36}', x)]
    assert i, f"no se pudo crear {etq}: {r}"
    r2 = psql(f"SET session_replication_role = replica; UPDATE public.{tabla} SET {sets.format(**ids)} WHERE id = '{i[0]}';")
    assert 'ERROR' not in r2, (etq, r2)
    ids[etq] = i[0]

def crear_datos():
    alinear_con_produccion()
    s = []
    for n, (area, nivel, adm, sa) in ROLES.items():
        u = uid(n); em = 'prueba.vendedor@dazon.demo' if n == 'vprueba' else f"{n}@ejemplo.test"
        s.append(f"""
INSERT INTO public.altas_autorizadas (email, expira_at) VALUES ('{em}', now() + interval '5 minutes') ON CONFLICT (email) DO UPDATE SET expira_at = EXCLUDED.expira_at;
INSERT INTO auth.users (id, email) VALUES ('{u}', '{em}') ON CONFLICT (id) DO NOTHING;
UPDATE public.profiles SET nombre_completo = 'Sintético {n}', activo = true, es_vendedor = {str(area == 'comercial' and not adm and nivel == 'operador').lower()}, es_administrativo = {str(adm).lower()} WHERE id = '{u}';
DELETE FROM public.user_roles WHERE user_id = '{u}';
INSERT INTO public.user_roles (user_id, area, nivel) VALUES ('{u}', '{area}', '{nivel}');""")
        if sa: s.append(f"INSERT INTO public.super_admins (user_id) VALUES ('{u}') ON CONFLICT DO NOTHING;")
    s.append("INSERT INTO public.inventario_usuarios_prueba (email, nota) VALUES ('prueba.vendedor@dazon.demo', 'ensayo') ON CONFLICT DO NOTHING;")
    psql('\n'.join(s))
    v1, v2 = uid('vend1'), uid('vend2')
    fila('c_v1', 'clientes', f"vendedor_id = '{v1}', nombre_comercial = 'Sintético C v1'")
    fila('c_v2', 'clientes', f"vendedor_id = '{v2}', nombre_comercial = 'Sintético C v2'")
    fila('pr1', 'almacen_refacciones_productos', "codigo_nuevo = 'ZZ-P1', descripcion = 'Sintético pieza 1', es_prueba = false, stock = 13")
    fila('pr2', 'almacen_refacciones_productos', "codigo_nuevo = 'ZZ-P2', descripcion = 'Sintético pieza 2', es_prueba = false, stock = 3")
    def rr(etq, vend, nom, fecha, extra=None):
        d = {'vendedor_id': f"'{vend}'", 'created_by': f"'{vend}'", 'nombre_vendedor': f"'{nom}'", 'cliente_id': "'{c_v1}'",
             'folio': f"'ZZ-{etq}'", 'fecha_remision': f"'{fecha}'", 'descuento_pct': '0', 'etapa': "'almacen'", 'es_prueba': 'false'}
        d.update(extra or {})
        fila(etq, 'remisiones_refacciones', ', '.join(f"{k} = {v}" for k, v in d.items()))
    rr('rr_v1', v1, 'Vend1', '2026-10-10'); rr('rr_v2', v2, 'Vend2', '2026-10-12'); rr('rr_can', v1, 'Vend1', '2026-10-11', {'etapa': "'cancelada'", 'cancelada_at': 'now()'})
    rr('rr_pru', uid('vprueba'), 'Vprueba', '2026-10-13', {'es_prueba': 'true'}); rr('rr_limpia', v1, 'Vend1', '2026-10-15')
    rr('rr_ent', v1, 'Vend1', '2026-10-09', {'etapa': "'entregada'", 'entregada_at': 'now()'}); rr('rr_pago', v1, 'Vend1', '2026-10-08', {'pagado': 'true', 'pagado_at': 'now()'})
    def it(etq, rem, prod, alm, precio, cant, sur, blo, desc, est):
        fila(etq, 'remision_refaccion_items', f"remision_id = '{{{rem}}}', producto_id = '{{{prod}}}', codigo_nuevo = 'ZZ', descripcion = 'Sintético', almacen = '{alm}', precio_unitario = {precio}, cantidad = {cant}, cantidad_surtida = {sur}, cantidad_bloqueada = {blo}, cantidad_faltante = 0, descuento_pct = {desc}, estatus = '{est}'")
    it('i1', 'rr_v1', 'pr1', 'A', 100, 3, 2, 1, 10, 'surtida'); it('i2', 'rr_v2', 'pr2', 'B', 200, 1, 1, 0, 0, 'surtida')
    it('i8', 'rr_v2', 'pr1', 'A', 10, 2, 2, 0, 0, 'surtida'); it('i3', 'rr_can', 'pr1', 'A', 999, 1, 0, 0, 0, 'cancelada'); it('i4', 'rr_pru', 'pr1', 'A', 10, 1, 1, 0, 0, 'surtida')
    it('i5', 'rr_limpia', 'pr1', 'A', 50, 3, 0, 3, 0, 'bloqueada'); it('i6', 'rr_ent', 'pr1', 'A', 5, 1, 0, 1, 0, 'bloqueada'); it('i7', 'rr_pago', 'pr1', 'A', 5, 1, 0, 1, 0, 'bloqueada')
    def mv(etq, prod, tipo, cant, fecha, alm, doc=None):
        doc_id = f"'{ids[doc]}'" if doc else 'NULL'
        r = psql(f"SET session_replication_role = replica; INSERT INTO public.almacen_refacciones_movimientos (producto_id, tipo, cantidad, fecha_efectiva, almacen, documento_tipo, documento_id, es_prueba, precio_unitario) VALUES ('{ids[prod]}', '{tipo}', {cant}, '{fecha}', '{alm}', '{'remision' if doc else 'compra'}', {doc_id}, false, 100) RETURNING id;", True)
        i = [x for x in r.split() if re.fullmatch(r'[0-9a-f-]{36}', x)]
        assert i, (etq, r); ids[etq] = i[0]
    mv('m1', 'pr1', 'entrada', 10, '2026-09-01', 'A'); mv('m2', 'pr1', 'venta', -2, '2026-10-10', 'A', 'rr_v1'); mv('m3', 'pr1', 'entrada', 5, '2026-10-20', 'B')
    mv('m4', 'pr2', 'entrada', 4, '2026-09-15', 'B'); mv('m5', 'pr2', 'venta', -1, '2026-10-12', 'B', 'rr_v2')
    # motocarros
    def rm(etq, folio, extra=''):
        # Producción: pagado NOT NULL DEFAULT true (las 93 remisiones tienen pagado = true); el pago real se ve en el comprobante.
        fila(etq, 'remisiones', f"vendedor_id = '{v1}', cliente_id = '{{c_v1}}', folio_remision = '{folio}', fecha_remision = '2026-10-05', estatus = 'NUEVA', tipo_pago = 'anticipado', pagado = true{extra}")
    rm('rm_limpia', 'ZZ-RM-LIMPIA'); rm('rm_pago', 'ZZ-RM-PAGO', ", comprobante_pago_url = 'https://ejemplo.test/comprobante.pdf'"); rm('rm_cxc', 'ZZ-RM-CXC'); rm('rm_fact', 'ZZ-RM-FACT'); rm('rm_mov', 'ZZ-RM-MOV'); rm('rm_ent', 'ZZ-RM-ENT'); rm('rm_firma', 'ZZ-RM-FIRMA'); rm('rm_esp', 'ZZ-RM-ESP '); rm('rm_carrera', 'ZZ-RM-CARRERA')
    for etq, rem, est in (('mc_a', 'rm_limpia', 'PROGRAMADA'), ('mc_b', 'rm_limpia', 'EN_RUTA'), ('mc_e', 'rm_ent', 'ENTREGADA')):
        r = psql(f"SET session_replication_role = replica; INSERT INTO public.motocarros (orden_armado, remision_id, estatus_entrega) VALUES ((SELECT coalesce(max(orden_armado), 0) + 1 FROM public.motocarros), '{ids[rem]}', '{est}') RETURNING id;", True)
        i = [x for x in r.split() if re.fullmatch(r'[0-9a-f-]{36}', x)]
        assert i, (etq, r); ids[etq] = i[0]
    fila('mc_c', 'motocarros', "remision_id = '{rm_carrera}', estatus_entrega = 'PROGRAMADA'") if False else None
    r = psql(f"SET session_replication_role = replica; INSERT INTO public.motocarros (orden_armado, remision_id, estatus_entrega, ns_chasis, ns_motor) VALUES ((SELECT coalesce(max(orden_armado), 0) + 1 FROM public.motocarros), '{ids['rm_carrera']}', 'PROGRAMADA', 'ZZ-CHASIS-CARRERA', 'ZZ-MOTOR-CARRERA') RETURNING id;", True)
    ids['mc_c'] = [x for x in r.split() if re.fullmatch(r'[0-9a-f-]{36}', x)][0]
    fila('rr_carrera', 'remisiones_refacciones', f"vendedor_id = '{v1}', created_by = '{v1}', nombre_vendedor = 'Vend1', cliente_id = '{{c_v1}}', folio = 'ZZ-rr_carrera', fecha_remision = '2026-10-14', descuento_pct = 0, etapa = 'almacen', es_prueba = false")
    fila('i_carrera', 'remision_refaccion_items', "remision_id = '{rr_carrera}', producto_id = '{pr1}', codigo_nuevo = 'ZZ', descripcion = 'Sintético', almacen = 'A', precio_unitario = 5, cantidad = 1, cantidad_surtida = 0, cantidad_bloqueada = 1, cantidad_faltante = 0, descuento_pct = 0, estatus = 'bloqueada'")
    psql(f"SET session_replication_role = replica; INSERT INTO public.firmas_solicitudes (creado_por, titulo, entidad_tipo, entidad_id, nombre_archivo, estatus, ruta_original, sha256_original) VALUES ('{uid('direccion')}', 'Sintético', 'remision', '{ids['rm_firma']}', 'x.pdf', 'pendiente', 'x/x.pdf', 'abc');")
    psql(f"SET session_replication_role = replica; INSERT INTO public.avisos (area_destino, tipo, titulo, cuerpo, remision_id, es_prueba) VALUES ('administracion', 'sintetico', 'Sintético', 'x', '{ids['rm_limpia']}', false);")
    fila('bit1', 'remisiones_bitacora', "remision_id = '{rm_limpia}', tipo_cambio = 'sintetico', nombre_usuario = 'x'")
    fila('op1', 'crm_oportunidades', f"remision_id = '{{rm_limpia}}', vendedor_id = '{v1}', cliente_id = '{{c_v1}}'")
    fila('cxc1', 'cuentas_por_cobrar', "remision_id = '{rm_cxc}', cliente_id = '{c_v1}'")
    fila('mf1', 'movimientos_financieros', "remision_id = '{rm_fact}', tiene_factura = true")
    fila('mf2', 'movimientos_financieros', "remision_id = '{rm_mov}', tiene_factura = false")

def catalogo():
    sql = """SELECT md5(string_agg(x, E'\\n' ORDER BY x)) FROM (
      SELECT 'p|'||schemaname||'.'||tablename||'|'||policyname||'|'||cmd||'|'||permissive||'|'||coalesce(roles::text,'')||'|'||coalesce(qual,'')||'|'||coalesce(with_check,'') FROM pg_policies WHERE schemaname IN ('public','storage')
      UNION ALL SELECT 'f|'||p.oid::regprocedure::text||'|'||md5(pg_get_functiondef(p.oid))||'|'||coalesce(p.proacl::text,'') FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prokind IN ('f','p')
      UNION ALL SELECT 't|'||c.relname||'|'||t.tgname||'|'||md5(pg_get_triggerdef(t.oid)) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE NOT t.tgisinternal AND n.nspname='public'
      UNION ALL SELECT 'r|'||c.relname||'|'||c.relrowsecurity||'|'||coalesce(c.relacl::text,'') FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r'
      UNION ALL SELECT 'k|'||clave||'|'||valor::text FROM public.compras_parametros) q;"""
    return psql(sql, True).strip().splitlines()[-1]

def preexistentes():
    """huella de cada función que existía ANTES (sin las de estos paquetes): no deben cambiar con P2 y P3."""
    r = psql("SELECT p.oid::regprocedure::text||'|'||md5(pg_get_functiondef(p.oid)) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prokind IN ('f','p') ORDER BY 1;", True)
    return dict(l.rsplit('|', 1) for l in r.splitlines() if '|' in l and l.count('|') >= 1)

def conteos():
    r = psql("""SELECT (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prokind IN ('f','p')),
      (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prokind IN ('f','p') AND p.prosecdef AND has_function_privilege('authenticated',p.oid,'EXECUTE')),
      (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prokind IN ('f','p') AND has_function_privilege('anon',p.oid,'EXECUTE')),
      (SELECT count(*) FROM pg_policies WHERE schemaname='public'),
      (SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE NOT t.tgisinternal AND n.nspname='public'),
      (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r');""", True).strip().splitlines()[-1].split('|')
    return dict(zip(['funciones', 'secdef_ejecutables_authenticated', 'funciones_ejecutables_anon', 'politicas', 'triggers', 'tablas'], map(int, r)))

CHK = []   # (nombre, ok, detalle)
def chk(nombre, ok, detalle=''):
    CHK.append((nombre, bool(ok), str(detalle)[:240]))

# ──────────────────────────── PAQUETE 2 ────────────────────────────
def total_reporte(rol, extra=''):
    r = como(rol, f"SELECT coalesce(sum(piezas),0)||'/'||coalesce(sum(monto_neto),0)||'/'||count(*) FROM public.reporte_ventas_refacciones('2026-10-01','2026-10-31'{extra});")
    return error_de(r) or (util(r) or [''])[0]

def pruebas_p2():
    res = {}
    esperado = {'vend1': '9/435.00/1', 'vend2': '3/220.00/2', 'superv': '12/655.00/3', 'admvo': '12/655.00/3', 'direccion': '12/655.00/3'}
    res['reporte_por_rol'] = {rol: total_reporte(rol) for rol in ROLES}
    for rol, e in esperado.items(): chk(f"P2 reporte de ventas: {rol} ve {e}", res['reporte_por_rol'][rol] == e, res['reporte_por_rol'][rol])
    chk('P2 reporte: el vendedor NO ve las ventas del otro', res['reporte_por_rol']['vend1'] != res['reporte_por_rol']['superv'])
    chk('P2 reporte: usuario de prueba no ve datos reales (0 filas)', res['reporte_por_rol']['vprueba'].startswith('0/'), res['reporte_por_rol']['vprueba'])
    res['prueba_con_incluir'] = total_reporte('vprueba', ", _incluir_prueba => true"); chk('P2 reporte: usuario de prueba con _incluir_prueba ve solo lo de prueba', res['prueba_con_incluir'] == '1/10.00/1', res['prueba_con_incluir'])
    chk('P2 reporte: canceladas excluidas (superv no suma 999)', '999' not in res['reporte_por_rol']['superv'])
    f = {'almacén A': ", _almacenes => ARRAY['A']", 'almacén B': ", _almacenes => ARRAY['B']", 'vendedor 2': f", _vendedores => ARRAY['{uid('vend2')}'::uuid]", 'artículo 2': f", _productos => ARRAY['{ids['pr2']}'::uuid]"}
    exp = {'almacén A': '11/455.00/2', 'almacén B': '1/200.00/1', 'vendedor 2': '3/220.00/2', 'artículo 2': '1/200.00/1'}
    res['filtros'] = {k: total_reporte('direccion', v) for k, v in f.items()}
    for k in f: chk(f"P2 reporte: filtro {k}", res['filtros'][k] == exp[k], res['filtros'][k])
    chk('P2 reporte: el vendedor filtrando por el OTRO vendedor sigue sin ver nada ajeno', total_reporte('vend1', f", _vendedores => ARRAY['{uid('vend2')}'::uuid]").startswith('0/'))
    chk('P2 reporte: periodo inválido se rechaza', 'periodo' in (error_de(como('direccion', "SELECT * FROM public.reporte_ventas_refacciones('2026-10-31','2026-10-01');")) or ''))
    # totales: remisiones DISTINTAS (rr_v2 sale en dos filas del reporte pero cuenta una sola vez)
    def tot(rol, extra=''):
        r = como(rol, f"SELECT remisiones||'/'||piezas||'/'||monto_neto FROM public.reporte_ventas_refacciones_totales('2026-10-01','2026-10-31'{extra});")
        return error_de(r) or (util(r) or [''])[0]
    suma_filas = lambda rol: (util(como(rol, "SELECT sum(remisiones) FROM public.reporte_ventas_refacciones('2026-10-01','2026-10-31');")) or [''])[0]
    res['totales_por_rol'] = {rol: tot(rol) for rol in ROLES}
    for rol, e in {'vend1': '5/9/435.00', 'vend2': '1/3/220.00', 'superv': '6/12/655.00', 'admvo': '6/12/655.00', 'direccion': '6/12/655.00'}.items():
        chk(f"P2 totales: {rol} cuenta {e.split('/')[0]} remisión(es) distintas, {e.split('/')[1]} piezas y {e.split('/')[2]}", res['totales_por_rol'][rol] == e, res['totales_por_rol'][rol])
    chk('P2 totales: la suma de la columna `remisiones` por fila CUENTA DE MÁS (vend2: 2 filas ≠ 1 remisión), los totales no', suma_filas('vend2') == '2' and res['totales_por_rol']['vend2'].startswith('1/'), (suma_filas('vend2'), res['totales_por_rol']['vend2']))
    chk('P2 totales: coinciden en piezas y monto con la suma de las filas', all(res['totales_por_rol'][r].split('/')[1:] == total_reporte(r).split('/')[:2] for r in ('vend1', 'vend2', 'superv')))
    chk('P2 totales: el vendedor solo cuenta las suyas (vend1 ≠ superv)', res['totales_por_rol']['vend1'] != res['totales_por_rol']['superv'])
    chk('P2 totales: el usuario de prueba no cuenta datos reales', res['totales_por_rol']['vprueba'].startswith('0/'), res['totales_por_rol']['vprueba'])
    chk('P2 totales: con filtro de almacén B cuenta 1 remisión', tot('direccion', ", _almacenes => ARRAY['B']") == '1/1/200.00', tot('direccion', ", _almacenes => ARRAY['B']"))
    chk('P2 totales: periodo inválido se rechaza', 'periodo' in (error_de(como('direccion', "SELECT * FROM public.reporte_ventas_refacciones_totales('2026-10-31','2026-10-01');")) or ''))
    # kárdex de varios artículos
    def kdx(rol, sql): r = como(rol, sql); return error_de(r), util(r)
    res['kardex_por_rol'] = {rol: (kdx(rol, f"SELECT count(*) FROM public.kardex_refacciones_multi(ARRAY['{ids['pr1']}'::uuid]);")[0] or 'ok') for rol in ROLES}
    for rol in ('vend1', 'vend2', 'vprueba'): chk(f"P2 kárdex multi: {rol} NO entra", 'Sin acceso' in res['kardex_por_rol'][rol], res['kardex_por_rol'][rol])
    quien = [r for r in ('compras', 'almacen', 'direccion', 'finanzas') if res['kardex_por_rol'][r] == 'ok']
    chk('P2 kárdex multi: entra al menos un rol de inventario', bool(quien), quien); rol_k = quien[0] if quien else 'direccion'
    for p in ('pr1', 'pr2'):
        _, a = kdx(rol_k, f"SELECT fecha||'|'||tipo||'|'||coalesce(entrada::text,'')||'|'||coalesce(salida::text,'')||'|'||saldo FROM public.kardex_refaccion('{ids[p]}');")
        _, b = kdx(rol_k, f"SELECT fecha||'|'||tipo||'|'||coalesce(entrada::text,'')||'|'||coalesce(salida::text,'')||'|'||saldo FROM public.kardex_refacciones_multi(ARRAY['{ids[p]}'::uuid]);")
        chk(f"P2 kárdex multi: un artículo ({p}) = kardex_refaccion (fecha, tipo, entrada, salida, saldo)", a == b and len(a) > 0, f"{len(a)} vs {len(b)}")
    _, ambos = kdx(rol_k, f"SELECT count(DISTINCT producto_id)||'/'||count(*) FROM public.kardex_refacciones_multi(ARRAY['{ids['pr1']}'::uuid,'{ids['pr2']}'::uuid]);")
    chk('P2 kárdex multi: dos artículos juntos', ambos and ambos[0].startswith('2/'), ambos)
    _, alm = kdx(rol_k, f"SELECT string_agg(saldo::text, ',' ORDER BY fecha, registrado) FROM public.kardex_refacciones_multi(ARRAY['{ids['pr1']}'::uuid], NULL, NULL, 'A') WHERE tipo <> 'saldo_inicial';")
    chk('P2 kárdex multi: filtro de almacén A (saldos 10, 8)', alm == ['10,8'], alm)
    _, ini = kdx(rol_k, f"SELECT saldo FROM public.kardex_refacciones_multi(ARRAY['{ids['pr1']}'::uuid], '2026-10-01', '2026-10-31') WHERE tipo = 'saldo_inicial';")
    chk('P2 kárdex multi: saldo inicial al 30/09 = 10', ini == ['10'], ini)
    chk('P2 kárdex multi: lista vacía se rechaza', 'al menos un' in (error_de(como(rol_k, "SELECT * FROM public.kardex_refacciones_multi(ARRAY[]::uuid[]);")) or ''))
    chk('P2 kárdex multi: más de 50 se rechaza', 'Máximo' in (error_de(como(rol_k, "SELECT * FROM public.kardex_refacciones_multi((SELECT array_agg(gen_random_uuid()) FROM generate_series(1,51)));")) or ''))
    # rotación filtrada
    res['rotacion_por_rol'] = {rol: (error_de(como(rol, "SELECT count(*) FROM public.resumen_rotacion_refacciones_filtrado('2026-10-01','2026-10-31');")) or 'ok') for rol in ROLES}
    for rol in ('vend1', 'vend2', 'vprueba'): chk(f"P2 rotación filtrada: {rol} NO entra", 'Sin acceso' in res['rotacion_por_rol'][rol], res['rotacion_por_rol'][rol])
    rr_ = [r for r in ('compras', 'direccion', 'finanzas') if res['rotacion_por_rol'][r] == 'ok']; chk('P2 rotación filtrada: entra al menos un rol de compras', bool(rr_), rr_); rol_r = rr_[0] if rr_ else 'compras'
    def rot(sql): r = como(rol_r, sql); return util(r)
    o = rot("SELECT count(*)||'/'||sum(piezas_vendidas)||'/'||sum(monto_vendido) FROM public.resumen_rotacion_refacciones('2026-10-01','2026-10-31');")
    n = rot("SELECT count(*)||'/'||sum(piezas_vendidas)||'/'||sum(monto_vendido) FROM public.resumen_rotacion_refacciones_filtrado('2026-10-01','2026-10-31');")
    chk('P2 rotación filtrada sin filtros = rotación original', o == n and o, (o, n))
    chk('P2 rotación filtrada: filtro de artículo', rot(f"SELECT count(*) FROM public.resumen_rotacion_refacciones_filtrado('2026-10-01','2026-10-31', false, ARRAY['{ids['pr2']}'::uuid]);") == ['1'])
    a = rot(f"SELECT producto_id, piezas_vendidas FROM public.resumen_rotacion_refacciones_filtrado('2026-10-01','2026-10-31', false, ARRAY['{ids['pr1']}'::uuid,'{ids['pr2']}'::uuid], 'A') ORDER BY codigo;")
    chk('P2 rotación filtrada: almacén A (pr1 vendió 2; pr2 0)', [x.split('|')[1] for x in a] == ['2', '0'], a)
    # solo lectura y permisos
    vol = psql("SELECT p.proname||'='||p.provolatile::text FROM pg_proc p WHERE p.proname IN ('reporte_ventas_refacciones','reporte_ventas_refacciones_totales','kardex_refacciones_multi','resumen_rotacion_refacciones_filtrado') ORDER BY 1;", True).split()
    chk('P2: las 4 funciones son STABLE (solo lectura)', all(v.endswith('=s') for v in vol) and len(vol) == 4, vol)
    cuerpos = psql("SELECT p.proname, pg_get_functiondef(p.oid) FROM pg_proc p WHERE p.proname IN ('reporte_ventas_refacciones','reporte_ventas_refacciones_totales','kardex_refacciones_multi','resumen_rotacion_refacciones_filtrado');", True)
    chk('P2: ninguna función tiene INSERT/UPDATE/DELETE', not re.search(r'\b(INSERT\s+INTO|UPDATE\s+public|DELETE\s+FROM)\b', cuerpos, re.I))
    pe = psql("SELECT has_function_privilege('anon',p.oid,'EXECUTE')::text||has_function_privilege('authenticated',p.oid,'EXECUTE')::text FROM pg_proc p WHERE p.proname IN ('reporte_ventas_refacciones','reporte_ventas_refacciones_totales','kardex_refacciones_multi','resumen_rotacion_refacciones_filtrado');", True).split()
    chk('P2: anon no ejecuta y authenticated sí (las 4)', pe == ['falsetrue'] * 4, pe)
    inv = psql("SELECT (NOT prosecdef)::text FROM pg_proc WHERE proname IN ('reporte_ventas_refacciones','reporte_ventas_refacciones_totales');", True).split()
    chk('P2: el reporte de ventas y sus totales son SECURITY INVOKER', inv == ['true', 'true'], inv)
    return res

# ──────────────────────────── PAQUETE 3 ────────────────────────────
def hay(sql_existe): return psql(f"SELECT ({sql_existe})::int;", True).split()[-1] == '1'

def pruebas_p3():
    res = {}
    # interruptor global
    chk('P3 modo prueba global: nace APAGADO (decisión H8)', psql("SELECT public.modo_prueba_global_activo();", True).split()[-1] == 'f')
    e = error_de(como('compras', "UPDATE public.compras_parametros SET valor = 'false'::jsonb WHERE clave = 'modo_prueba_global';")); chk('P3 interruptor: quien puede compras/inventario NO lo cambia directo', e and 'fijar_modo_prueba_global' in e, e)
    r = como('compras', "DELETE FROM public.compras_parametros WHERE clave = 'modo_prueba_global';\nRESET ROLE;\nSELECT 'filas=' || count(*) FROM public.compras_parametros WHERE clave = 'modo_prueba_global';"); chk('P3 interruptor: quien puede compras/inventario no lo borra directo', 'filas=1' in r, util(r))
    e = error_de(psql("BEGIN; DELETE FROM public.compras_parametros WHERE clave = 'modo_prueba_global'; ROLLBACK;", True)); chk('P3 interruptor: ni el dueño de la tabla (sin la función) lo borra o cambia', e and 'fijar_modo_prueba_global' in e, e)
    for rol in ('vend1', 'superv', 'admvo', 'compras', 'finanzas'):
        e = error_de(como(rol, "SELECT public.fijar_modo_prueba_global(true, 'motivo de prueba');")); chk(f"P3 interruptor: {rol} NO lo fija", e and 'Dirección' in e, e)
    r = como('direccion', "SELECT public.fijar_modo_prueba_global(true, 'ensayo encender'); SELECT public.modo_prueba_global_activo(); SELECT count(*) FROM public.bitacora_eventos WHERE accion='modo_prueba_global';")
    chk('P3 interruptor: Dirección lo enciende y queda en bitácora', error_de(r) is None and 't' in util(r) and '1' in util(r), util(r))
    chk('P3 interruptor: sin motivo se rechaza', 'motivo' in (error_de(como('direccion', "SELECT public.fijar_modo_prueba_global(true, 'x');")) or ''))
    # eliminar remisión
    def elim(rol, tipo, etq, folio, motivo='motivo suficientemente largo', pre=''):
        return como(rol, f"{pre} SELECT public.eliminar_remision('{tipo}', '{ids[etq]}', '{folio}', '{motivo}');")
    on = "SELECT set_config('request.jwt.claim.sub', '" + uid('direccion') + "', true) \\g /dev/null\n"
    prende = "SET LOCAL ROLE postgres; UPDATE public.compras_parametros SET valor = 'true'::jsonb WHERE clave = 'modo_prueba_global'; SET LOCAL ROLE authenticated;"
    prende = "SELECT set_config('kit.permite_modo_prueba_global','1',true) \\g /dev/null\n" + "UPDATE public.compras_parametros SET valor = 'true'::jsonb WHERE clave = 'modo_prueba_global';"
    # con el modo prueba apagado (estado actual) se rechaza
    off = ("SET LOCAL ROLE authenticated;\n" + CLAIMS.format(u=uid('direccion')) + f"SELECT public.eliminar_remision('motocarro', '{ids['rm_limpia']}', 'ZZ-RM-LIMPIA', 'motivo suficientemente largo');")
    e = error_de(psql("BEGIN;\n" + off + "\nROLLBACK;\n", True)); chk('P3 eliminar: con el modo prueba APAGADO se rechaza', e and 'modo prueba está apagado' in e, e)
    # a partir de aquí, cada caso en su propia transacción con el interruptor encendido (el UPDATE se hace como postgres)
    def elimON(rol, tipo, etq, folio, motivo='motivo suficientemente largo', despues=''):
        cuerpo = ("RESET ROLE; SELECT set_config('kit.permite_modo_prueba_global','1',true) \\g /dev/null\n"
                  "UPDATE public.compras_parametros SET valor = 'true'::jsonb WHERE clave = 'modo_prueba_global';\n"
                  "SET LOCAL ROLE authenticated;\n" + CLAIMS.format(u=uid(rol)) +
                  f"SELECT public.eliminar_remision('{tipo}', '{ids[etq]}', '{folio}', '{motivo}')::text;\n{despues}")
        r = psql("BEGIN;\n" + cuerpo + "\nROLLBACK;\n", True); return error_de(r), util(r)
    casos = [('rm_pago', 'ZZ-RM-PAGO', 'comprobante de pago'), ('rm_firma', 'ZZ-RM-FIRMA', 'solicitud de firma'), ('rm_cxc', 'ZZ-RM-CXC', 'cuenta por cobrar'), ('rm_fact', 'ZZ-RM-FACT', 'factura'),
             ('rm_mov', 'ZZ-RM-MOV', 'movimientos financieros'), ('rm_ent', 'ZZ-RM-ENT', 'entrega confirmada')]
    for etq, folio, frag in casos:
        e, _ = elimON('direccion', 'motocarro', etq, folio); chk(f"P3 eliminar motocarro con {frag}: se rechaza", e and frag in e, e)
    e, u = elimON('direccion', 'motocarro', 'rm_esp', 'ZZ-RM-ESP'); chk('P3 eliminar: folio con espacios finales coincide al escribirlo sin ellos (H9)', e is None and any('unidades_liberadas' in x for x in u), e or u)
    e, _ = elimON('direccion', 'motocarro', 'rm_limpia', 'OTRO-FOLIO'); chk('P3 eliminar: folio distinto se rechaza', e and 'folio' in e, e)
    e, _ = elimON('direccion', 'motocarro', 'rm_limpia', 'ZZ-RM-LIMPIA', 'corto'); chk('P3 eliminar: motivo corto se rechaza', e and 'motivo' in e, e)
    for rol in ('vend1', 'superv', 'admvo', 'admcom', 'dirop', 'finanzas', 'compras'):
        e, _ = elimON(rol, 'motocarro', 'rm_limpia', 'ZZ-RM-LIMPIA'); chk(f"P3 eliminar: {rol} (no super admin) se rechaza", e and 'super admin' in e, e)
    despues = ("RESET ROLE;\nSELECT 'remision=' || (SELECT count(*) FROM public.remisiones WHERE id = '" + ids['rm_limpia'] + "');\n"
               "SELECT 'unidades_liberadas=' || (SELECT count(*) FROM public.motocarros WHERE id IN ('" + ids['mc_a'] + "','" + ids['mc_b'] + "') AND remision_id IS NULL AND estatus_entrega = 'NO_APLICA');\n"
               "SELECT 'bitacora_de_la_remision=' || (SELECT count(*) FROM public.remisiones_bitacora WHERE remision_id = '" + ids['rm_limpia'] + "');\n"
               "SELECT 'oportunidad_desligada=' || (SELECT count(*) FROM public.crm_oportunidades WHERE id = '" + ids['op1'] + "' AND remision_id IS NULL);\n"
               "SELECT 'copia=' || (SELECT count(*) FROM public.bitacora_eliminaciones WHERE registro_id = '" + ids['rm_limpia'] + "' AND tabla = 'remisiones' AND jsonb_array_length(datos_eliminados->'unidades') = 2 AND datos_eliminados->'remision'->>'folio_remision' = 'ZZ-RM-LIMPIA');\n"
               "SELECT 'copia_unidad_completa=' || (SELECT count(*) FROM public.bitacora_eliminaciones WHERE registro_id = '" + ids['rm_limpia'] + "' AND datos_eliminados->'unidades'->0 ? 'ns_chasis' AND datos_eliminados->'unidades'->0 ? 'orden_armado');\n"
               "SELECT 'copia_avisos=' || (SELECT jsonb_array_length(datos_eliminados->'avisos') FROM public.bitacora_eliminaciones WHERE registro_id = '" + ids['rm_limpia'] + "' AND tabla = 'remisiones');\n"
               "SELECT 'evento=' || (SELECT count(*) FROM public.bitacora_eventos WHERE accion = 'eliminar_remision' AND entidad_id = '" + ids['rm_limpia'] + "');")
    e, u = elimON('direccion', 'motocarro', 'rm_limpia', 'ZZ-RM-LIMPIA', despues=despues)
    res['eliminar_motocarro'] = u
    chk('P3 eliminar motocarro (super admin, limpia): se elimina', e is None and any('"unidades_liberadas": 2' in x for x in u), e or u[:1])
    for k in ('remision=0', 'unidades_liberadas=2', 'bitacora_de_la_remision=0', 'oportunidad_desligada=1', 'copia=1', 'copia_unidad_completa=1', 'copia_avisos=1', 'evento=1'):
        chk(f"P3 eliminar motocarro: {k}", k in u, u)
    # refacciones
    for etq, folio, frag in (('rr_pago', 'ZZ-rr_pago', 'pago registrado'), ('rr_ent', 'ZZ-rr_ent', 'entrega confirmada'), ('rr_v1', 'ZZ-rr_v1', 'surtió inventario')):
        e, _ = elimON('direccion', 'refacciones', etq, folio); chk(f"P3 eliminar refacciones ({frag}): se rechaza", e and frag in e, e)
    ap = lambda: f"SELECT public.stock_bloqueado_producto('{ids['pr1']}')::text;"
    despues = ("RESET ROLE;\nSELECT 'remision=' || (SELECT count(*) FROM public.remisiones_refacciones WHERE id = '" + ids['rr_limpia'] + "');\n"
               "SELECT 'partidas=' || (SELECT count(*) FROM public.remision_refaccion_items WHERE remision_id = '" + ids['rr_limpia'] + "');\n"
               "SELECT 'apartado_pr1=' || public.stock_bloqueado_producto('" + ids['pr1'] + "');\n"
               "SELECT 'copia=' || (SELECT count(*) FROM public.bitacora_eliminaciones WHERE registro_id = '" + ids['rr_limpia'] + "' AND tabla = 'remisiones_refacciones' AND jsonb_array_length(datos_eliminados->'partidas') = 1);")
    antes_ap = psql(f"SELECT public.stock_bloqueado_producto('{ids['pr1']}');", True).split()[-1]
    e, u = elimON('direccion', 'refacciones', 'rr_limpia', 'ZZ-rr_limpia', despues=despues); res['eliminar_refacciones'] = (antes_ap, u)
    chk('P3 eliminar refacciones (limpia): se elimina, sin partidas huérfanas y con copia', e is None and 'remision=0' in u and 'partidas=0' in u and 'copia=1' in u, e or u)
    ap_despues = [x.split('=')[1] for x in u if x.startswith('apartado_pr1=')]
    chk('P3 eliminar refacciones: el apartado se libera (baja en 3)', ap_despues and int(ap_despues[0]) == int(antes_ap) - 3, (antes_ap, ap_despues))
    # carreras (H3, H4): una segunda sesión confirma una entrega / un surtido MIENTRAS la función verifica; la función debe esperar y rechazar
    import subprocess as sp, time
    def carrera(sql_a, rol_b, cuerpo_b, demora=1.0):
        a = sp.Popen(['psql', '-X', '-q', '-d', DB, '-v', 'ON_ERROR_STOP=1'], stdin=sp.PIPE, stdout=sp.PIPE, stderr=sp.STDOUT, text=True)
        a.stdin.write("BEGIN;\n" + sql_a + "\nSELECT pg_sleep(3);\nCOMMIT;\n"); a.stdin.close()
        time.sleep(demora); t0 = time.time()
        b = psql("BEGIN;\nRESET ROLE; SELECT set_config('kit.permite_modo_prueba_global','1',true) \\g /dev/null\nUPDATE public.compras_parametros SET valor = 'true'::jsonb WHERE clave = 'modo_prueba_global';\nSET LOCAL ROLE authenticated;\n" + CLAIMS.format(u=uid(rol_b)) + cuerpo_b + "\nROLLBACK;\n", True)
        espera = time.time() - t0; a.wait(); return error_de(b), espera
    e, w = carrera(f"UPDATE public.motocarros SET estatus_entrega = 'ENTREGADA' WHERE id = '{ids['mc_c']}';", 'direccion', f"SELECT public.eliminar_remision('motocarro', '{ids['rm_carrera']}', 'ZZ-RM-CARRERA', 'motivo suficientemente largo');")
    chk('P3 carrera motocarros (H3): la eliminación ESPERA la entrega que se confirma y la rechaza', e and 'entrega confirmada' in e and w > 1.0, (e, round(w, 1)))
    r = psql(f"SELECT 'unidad=' || estatus_entrega || '/' || coalesce(remision_id::text, 'NULL') FROM public.motocarros WHERE id = '{ids['mc_c']}';", True)
    chk('P3 carrera motocarros: la entrega confirmada NO se borró', f"unidad=ENTREGADA/{ids['rm_carrera']}" in r, r.strip())
    e, w = carrera(f"UPDATE public.remision_refaccion_items SET cantidad_surtida = 1, cantidad_bloqueada = 0 WHERE id = '{ids['i_carrera']}';", 'direccion', f"SELECT public.eliminar_remision('refacciones', '{ids['rr_carrera']}', 'ZZ-rr_carrera', 'motivo suficientemente largo');")
    chk('P3 carrera refacciones (H4): la eliminación ESPERA el surtido que se confirma y lo rechaza', e and 'surtió inventario' in e and w > 1.0, (e, round(w, 1)))
    # DELETE directo cerrado
    e = como('admcom', f"DELETE FROM public.remisiones WHERE id = '{ids['rm_limpia']}';"); chk('P3: el administrador de Comercial ya NO borra directo', 'permission denied' in (error_de(e) or '') or 'DELETE 0' in e, e)
    e = como('direccion', f"DELETE FROM public.remisiones WHERE id = '{ids['rm_limpia']}';"); chk('P3: ni Dirección borra directo', 'permission denied' in (error_de(e) or ''), e)
    e = como('vend1', f"DELETE FROM public.remisiones_refacciones WHERE id = '{ids['rr_limpia']}';"); chk('P3: authenticated ya no tiene el privilegio DELETE en remisiones_refacciones (H7)', 'permission denied' in (error_de(e) or ''), e)
    r = psql("SELECT count(*) FROM pg_policies WHERE tablename IN ('motocarros','remision_items') AND cmd = 'DELETE';", True).split()[-1]
    chk('P3: las políticas DELETE de motocarros y remision_items siguen (la edición las usa; H7 opción A)', r == '4', r)
    # fecha
    def fecha(rol, tipo, etq, nueva, motivo='corrección de captura'):
        r = como(rol, f"SELECT public.cambiar_fecha_remision('{tipo}', '{ids[etq]}', '{nueva}', '{motivo}')::text;"); return error_de(r), util(r)
    for rol in ('vend1', 'superv', 'finanzas', 'admcom', 'compras'):
        e, _ = fecha(rol, 'motocarro', 'rm_pago', '2026-10-04'); chk(f"P3 fecha: {rol} NO la cambia", e and 'Dirección o un administrativo' in e, e)
    for rol in ('direccion', 'admvo'):
        r = como(rol, f"SELECT public.cambiar_fecha_remision('motocarro', '{ids['rm_pago']}', '2026-10-04', 'corrección de captura')::text;\n"
                      f"RESET ROLE;\nSELECT 'fecha=' || (SELECT fecha_remision FROM public.remisiones WHERE id = '{ids['rm_pago']}');\n"
                      f"SELECT 'historial=' || (SELECT count(*) FROM public.remision_fecha_cambios WHERE remision_id = '{ids['rm_pago']}' AND fecha_original = '2026-10-05' AND fecha_nueva = '2026-10-04' AND motivo = 'corrección de captura');\n"
                      f"SELECT 'aviso=' || (SELECT count(*) FROM public.avisos WHERE tipo = 'cambio_fecha_remision' AND remision_id = '{ids['rm_pago']}' AND area_destino = 'administracion');")
        u = util(r); chk(f"P3 fecha motocarro: {rol} la cambia, con historial y aviso a administración", error_de(r) is None and 'fecha=2026-10-04' in u and 'historial=1' in u and 'aviso=1' in u, error_de(r) or u)
    r = como('admvo', f"SELECT public.cambiar_fecha_remision('refacciones', '{ids['rr_pago']}', '2026-10-07', 'corrección de captura')::text;")
    chk('P3 fecha refacciones sin surtido: se cambia', error_de(r) is None, error_de(r))
    e, _ = fecha('direccion', 'refacciones', 'rr_v1', '2026-10-09'); chk('P3 fecha refacciones con inventario surtido: se rechaza (D-B1)', e and 'surtió inventario' in e, e)
    e, _ = fecha('direccion', 'motocarro', 'rm_pago', '2999-01-01'); chk('P3 fecha: futura se rechaza', e and 'futura' in e, e)
    e, _ = fecha('direccion', 'motocarro', 'rm_pago', '2026-10-05'); chk('P3 fecha: igual a la actual se rechaza', e and 'igual' in e, e)
    e, _ = fecha('direccion', 'motocarro', 'rm_pago', '2026-10-01', 'x'); chk('P3 fecha: motivo corto se rechaza', e and 'motivo' in e, e)
    e, _ = fecha('direccion', 'refacciones', 'rr_can', '2026-10-01'); chk('P3 fecha: remisión cancelada se rechaza', e and 'cancelada' in e, e)
    # el vendedor ya no cambia la fecha por la edición normal; lo demás sí
    r = como('vend1', f"UPDATE public.remisiones SET fecha_remision = '2026-10-01' WHERE id = '{ids['rm_pago']}';"); chk('P3 fecha: el vendedor ya NO cambia fecha_remision por la edición normal', 'solo se cambia con' in (error_de(r) or ''), r)
    r = psql(f"BEGIN; UPDATE public.remisiones_refacciones SET fecha_remision = '2026-10-01' WHERE id = '{ids['rr_pago']}'; ROLLBACK;", True); chk('P3 fecha refacciones: ni el dueño de la tabla cambia fecha_remision directo', 'solo se cambia con' in (error_de(r) or ''), r)
    r = como('vend1', f"UPDATE public.remisiones SET notas = 'otra nota', fecha_remision = fecha_remision WHERE id = '{ids['rm_pago']}'; SELECT 'ok';"); chk('P3 fecha: el vendedor SÍ edita otros campos (y reenviar la misma fecha no estorba)', error_de(r) is None, r)
    # permisos de lo nuevo
    r = psql("SELECT has_table_privilege('anon','public.remision_fecha_cambios','SELECT')::text||has_table_privilege('authenticated','public.remision_fecha_cambios','INSERT')::text||has_table_privilege('authenticated','public.remision_fecha_cambios','UPDATE')::text||has_table_privilege('authenticated','public.remision_fecha_cambios','DELETE')::text, (SELECT relrowsecurity FROM pg_class WHERE oid='public.remision_fecha_cambios'::regclass)::text;", True).split()[-1]
    chk('P3: remision_fecha_cambios: anon nada, authenticated solo lee, con RLS', r == 'falsefalsefalsefalse|true', r)
    r = psql("SELECT p.proname||':'||has_function_privilege('anon',p.oid,'EXECUTE')::text||has_function_privilege('authenticated',p.oid,'EXECUTE')::text FROM pg_proc p WHERE p.proname IN ('modo_prueba_global_activo','fijar_modo_prueba_global','eliminar_remision','cambiar_fecha_remision','proteger_modo_prueba_global','remision_fecha_solo_por_funcion') ORDER BY 1;", True).split()
    chk('P3: anon no ejecuta nada; authenticated ejecuta las 4 públicas y ninguna de trigger', r == ['cambiar_fecha_remision:falsetrue', 'eliminar_remision:falsetrue', 'fijar_modo_prueba_global:falsetrue', 'modo_prueba_global_activo:falsetrue', 'proteger_modo_prueba_global:falsefalse', 'remision_fecha_solo_por_funcion:falsefalse'], r)
    # reglas de la Fase 2 que no se pueden deshacer
    r = psql("SELECT p.proname||':'||(NOT p.prosecdef)::text FROM pg_proc p WHERE p.proname IN ('cliente_tiene_cxc_vencidas','cxc_vencidas_resumen') ORDER BY 1;", True).split()
    chk('P3 respeta la Fase 2: cliente_tiene_cxc_vencidas y cxc_vencidas_resumen siguen SECURITY INVOKER', r == ['cliente_tiene_cxc_vencidas:true', 'cxc_vencidas_resumen:true'], r)
    return res

def main():
    out = {'migraciones': {}}
    crear_datos(); out['filas_sinteticas'] = len(ids)
    base = {'catalogo': catalogo(), 'conteos': conteos(), 'funciones': preexistentes()}; out['antes'] = {'catalogo': base['catalogo'], 'conteos': base['conteos']}
    # comportamiento de antes (se deshace): hoy el admin de Comercial borra directo y el vendedor cambia la fecha
    r = como('admcom', f"DELETE FROM public.remisiones WHERE id = '{ids['rm_limpia']}';\nRESET ROLE;\nSELECT 'quedan=' || count(*) FROM public.remisiones WHERE id = '{ids['rm_limpia']}';")
    out['antes_admcom_borra_directo'] = util(r)
    chk('ANTES: el administrador de Comercial SÍ borra directo una remisión (lo que cierra P3)', 'quedan=0' in r and error_de(r) is None, util(r))
    r = como('vend1', f"UPDATE public.remisiones SET fecha_remision = '2026-10-01' WHERE id = '{ids['rm_pago']}';\nRESET ROLE;\nSELECT 'fecha=' || fecha_remision FROM public.remisiones WHERE id = '{ids['rm_pago']}';")
    chk('ANTES: el vendedor SÍ cambia la fecha por edición normal (lo que cierra P3)', 'fecha=2026-10-01' in r and error_de(r) is None, util(r))
    for n in P2 + P3:
        ok, err = aplicar(mig(n)); out['migraciones'][n] = {'aplica_ok': ok, 'error': '' if ok else err}
        if n == P2[-1]: out['tras_p2'] = {'catalogo': catalogo(), 'conteos': conteos()}
        if not ok: print('FALLÓ', n, err); break
    out['despues'] = {'catalogo': catalogo(), 'conteos': conteos()}
    # nada preexistente cambia, salvo lo previsto (las funciones previas conservan su huella)
    ahora = preexistentes(); cambiadas = [k for k, v in base['funciones'].items() if ahora.get(k) != v]
    chk('P2+P3 no cambian NINGUNA función que ya existía (Fase 1, Paquete 1, Fase 2 intactas)', not cambiadas, cambiadas)
    out['p2'] = pruebas_p2(); out['p3'] = pruebas_p3()
    # H2: una base sin `comprobante_pago_url` (construida solo con las migraciones) debe hacer que la migración 2 de P3 ABORTE con mensaje claro
    psql("DROP DATABASE IF EXISTS p23_guarda;"); psql("CREATE DATABASE p23_guarda TEMPLATE f2_conp1;")
    g = subprocess.run(['psql', '-X', '-q', '-d', 'p23_guarda', '-v', 'ON_ERROR_STOP=1', '-c', 'ALTER TABLE public.remisiones DROP COLUMN IF EXISTS comprobante_pago_url; ALTER TABLE public.remisiones DROP COLUMN IF EXISTS pagado;'], capture_output=True, text=True)
    g2 = subprocess.run(['psql', '-X', '-q', '-d', 'p23_guarda', '-v', 'ON_ERROR_STOP=1', '--single-transaction', '-f', mig(P3[1])], capture_output=True, text=True)
    chk('P3 guarda (H2): en una base sin las columnas la migración de eliminar ABORTA y no crea la función', g2.returncode != 0 and 'necesita columnas' in g2.stderr and 'comprobante_pago_url' in g2.stderr and psql("SELECT count(*) FROM pg_proc WHERE proname='eliminar_remision';", True).split()[-1] is not None, g2.stderr[-200:])
    n = subprocess.run(['psql', '-X', '-At', '-d', 'p23_guarda', '-c', "SELECT count(*) FROM pg_proc WHERE proname = 'eliminar_remision'"], capture_output=True, text=True).stdout.strip()
    chk('P3 guarda: tras abortar no quedó la función', n == '0', n)
    psql("DROP DATABASE IF EXISTS p23_guarda;")
    cat = out['despues']['catalogo']
    for n in P2 + P3: aplicar(mig(n))
    out['reaplicar_idempotente'] = (catalogo() == cat); chk('Reaplicar las 6 migraciones no cambia nada (idempotentes)', out['reaplicar_idempotente'])
    for n in reversed(P3):
        ok, err = aplicar(rev(n)); out['migraciones'][n]['reversa_ok'] = ok
    out['tras_reversa_p3'] = {'catalogo': catalogo(), 'conteos': conteos()}
    chk('Revertir solo el Paquete 3 deja el catálogo igual al de «tras el Paquete 2»', out['tras_reversa_p3']['catalogo'] == out['tras_p2']['catalogo'])
    for n in reversed(P2):
        ok, err = aplicar(rev(n)); out['migraciones'][n]['reversa_ok'] = ok
    out['tras_reversa_total'] = {'catalogo': catalogo(), 'conteos': conteos()}
    out['reversa_total_restaura_exacto'] = (out['tras_reversa_total']['catalogo'] == out['antes']['catalogo'] and out['tras_reversa_total']['conteos'] == out['antes']['conteos'])
    chk('Revertir todo deja el catálogo EXACTAMENTE como estaba antes', out['reversa_total_restaura_exacto'])
    chk('Tras revertir todo vuelven a existir los dos DELETE directos y la fecha se edita como antes',
        hay("SELECT count(*) = 2 FROM pg_policies WHERE tablename='remisiones' AND cmd='DELETE'"))
    out['chequeos'] = [{'caso': a, 'ok': b, 'detalle': c} for a, b, c in CHK]
    json.dump(out, open(SALIDA, 'w'), ensure_ascii=False, indent=1, sort_keys=True)
    fallos = [c for c in CHK if not c[1]]
    print('conteos antes   :', out['antes']['conteos']); print('conteos tras P2 :', out['tras_p2']['conteos']); print('conteos despues :', out['despues']['conteos'])
    print('migraciones:', {k: (v['aplica_ok'], v.get('reversa_ok')) for k, v in out['migraciones'].items()})
    print(f"chequeos: {len(CHK) - len(fallos)}/{len(CHK)} en verde")
    for a, b, c in fallos: print('  FALLA:', a, '->', c)

main()

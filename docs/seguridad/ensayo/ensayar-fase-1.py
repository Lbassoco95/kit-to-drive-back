#!/usr/bin/env python3
"""Ensayo de la Fase 1 sobre la réplica local (construir-replica-fiel.py).

Por cada migración, en orden:
  1. Foto exacta del catálogo (permisos de tablas, vistas y funciones, search_path,
     permisos por defecto) y conteos de la sección 2 del encargo.
  2. Aplica la migración en UNA transacción (como el SQL editor de Supabase).
  3. Conteos y recorridos por rol (probar-recorridos.py) después.
  4. Aplica su REVERSA y comprueba que el catálogo vuelve EXACTAMENTE a la foto 1.
  5. Vuelve a aplicar la migración (comprueba idempotencia: el catálogo no cambia).
Al final aplica las seis, corre los recorridos, aplica las reversas en orden
inverso y comprueba que se recupera la línea base completa.

Uso: PGHOST=/var/run/postgresql PGUSER=root PGOPTIONS='-c role=postgres' ensayar-fase-1.py <base> <salida.json>
"""
import hashlib, json, os, subprocess, sys

BASE, SALIDA = sys.argv[1], sys.argv[2]
RAIZ = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
MIG = [
    '20261031000001_fase1_quitar_truncate_trigger_references',
    '20261031000002_fase1_cerrar_funciones_de_trigger',
    '20261031000003_fase1_fijar_search_path',
    '20261031000004_fase1_quitar_lectura_anon_de_vistas',
    '20261031000005_fase1_quitar_escritura_anon_de_tablas',
    '20261031000006_fase1_lo_nuevo_nace_cerrado',
]
CANON = """
select 'rel|' || c.relname || '|' || c.relkind::text || '|' || (select coalesce(string_agg(x, ',' order by x), '') from unnest(coalesce(c.relacl::text[], '{}')) x) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','p','v','S')
union all
select 'fun|' || p.oid::regprocedure::text || '|' || (select coalesce(string_agg(x, ',' order by x), '') from unnest(coalesce(p.proacl::text[], '{}')) x) || '|' || coalesce(p.proconfig::text,'') from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and not exists (select 1 from pg_depend d where d.objid=p.oid and d.deptype='e')
union all
select 'def|' || d.defaclrole::regrole::text || '|' || d.defaclnamespace::regnamespace::text || '|' || d.defaclobjtype::text || '|' || (select coalesce(string_agg(x, ',' order by x), '') from unnest(d.defaclacl::text[]) x) from pg_default_acl d where d.defaclrole = 'postgres'::regrole
order by 1;
"""

def psql(args, entrada=None):
    r = subprocess.run(['psql', '-X', '-At', '-d', BASE] + args, input=entrada, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return r.returncode, r.stdout

def catalogo():
    _, o = psql(['-c', CANON.strip().rstrip(';')])
    lineas = [l for l in o.splitlines() if l.startswith(('rel|', 'fun|', 'def|'))]
    if len(lineas) < 300: sys.exit('La foto del catálogo salió incompleta (%d líneas): %s' % (len(lineas), o[:300]))
    return hashlib.md5('\n'.join(lineas).encode()).hexdigest(), lineas

def conteos():
    sql = open(os.path.join(RAIZ, 'docs/seguridad/consultas/02-conteos-linea-base.sql')).read().strip().rstrip(';')
    _, o = psql(['-c', f"select row_to_json(q) from ({sql}) q"])
    return json.loads(o.splitlines()[-1])

def aplicar(ruta):
    """MAINTAIN es de PostgreSQL 17 (producción); el motor local es 16 y no lo conoce: se quita solo aquí."""
    import re, tempfile
    texto = open(ruta).read()
    _, ver = psql(['-c', 'show server_version_num'])
    if int(ver.strip().splitlines()[-1]) < 170000:
        texto = re.sub(r',\s*MAINTAIN|MAINTAIN,\s*', '', texto)
    with tempfile.NamedTemporaryFile('w', suffix='.sql', delete=False) as t: t.write(texto)
    rc, o = psql(['-v', 'ON_ERROR_STOP=1', '--single-transaction', '-f', t.name])
    os.unlink(t.name)
    return rc, o

def recorridos(nombre):
    ruta = SALIDA.replace('.json', f'_{nombre}.json')
    subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), 'probar-recorridos.py'), BASE, ruta],
                   env={k: v for k, v in os.environ.items() if k != 'PGOPTIONS'}, stdout=subprocess.DEVNULL)
    return json.load(open(ruta))

def difs(a, b):
    sa, sb = set(a), set(b)
    return {'solo_antes': sorted(sa - sb)[:6], 'solo_despues': sorted(sb - sa)[:6], 'n': len(sa ^ sb)}

def mig(n): return os.path.join(RAIZ, 'supabase/migrations', n + '.sql')
def rev(n): return os.path.join(RAIZ, 'supabase/reversas', n + '_reversa.sql')

res = {'pasos': []}
h0, c0 = catalogo(); res['catalogo_inicial'] = h0
res['conteos_inicial'] = conteos(); res['recorridos_inicial'] = recorridos('0_antes')
for n in MIG:
    paso = {'migracion': n}
    h_antes, c_antes = catalogo(); paso['conteos_antes'] = conteos()
    rc, out = aplicar(mig(n)); paso['aplicar_ok'] = rc == 0; paso['aplicar_salida'] = [l for l in out.splitlines() if l.strip()][-6:]
    if rc != 0:
        paso['error'] = out[-600:]; res['pasos'].append(paso); break
    h_apl, c_apl = catalogo(); paso['conteos_despues'] = conteos(); paso['catalogo_cambio'] = h_apl != h_antes
    paso['recorridos'] = recorridos(n[:14])
    rc2, out2 = aplicar(rev(n)); h_rev, c_rev = catalogo()
    paso['reversa_ok'] = rc2 == 0; paso['reversa_restaura_exacto'] = (h_rev == h_antes)
    if h_rev != h_antes: paso['reversa_difiere'] = difs(c_antes, c_rev)
    paso['reversa_salida'] = out2[-300:] if rc2 != 0 else ''
    aplicar(mig(n)); h_re, _ = catalogo(); paso['reaplicar_idempotente'] = (h_re == h_apl)
    res['pasos'].append(paso)
res['conteos_final'] = conteos(); res['recorridos_final'] = recorridos('7_despues_de_todas')
h_f, c_f = catalogo(); res['catalogo_final'] = h_f
# reversas en orden inverso -> línea base exacta
for n in reversed(MIG): aplicar(rev(n))
h_r, c_r = catalogo(); res['reversa_total_restaura_exacto'] = (h_r == h0)
if h_r != h0: res['reversa_total_difiere'] = difs(c0, c_r)
res['conteos_tras_reversa_total'] = conteos()
for n in MIG: aplicar(mig(n))
h_o, _ = catalogo(); res['reaplicar_todas_igual_que_la_primera_vez'] = (h_o == h_f)
json.dump(res, open(SALIDA, 'w'), ensure_ascii=False, indent=1, sort_keys=True)
print('guardado en', SALIDA)

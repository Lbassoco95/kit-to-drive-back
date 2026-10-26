#!/usr/bin/env python3
"""Ensayo de la Fase 2 sobre la réplica local (construir-replica-fiel.py + Fase 1).

Pasos:
  0. Aplica la Fase 1 (20261031000001–06) si la réplica aún no la tiene (la Fase 2 depende de ella).
  1. Línea base: foto del catálogo de lo que toca la Fase 2 (triggers, políticas y funciones de
     profiles, user_roles, super_admins y las dos funciones de cartera), conteos de la sección 2 y
     recorridos por rol de la Fase 2 (recorridos-fase-2.py) y los de la Fase 1 (probar-recorridos.py).
  2. Por cada migración de la Fase 2, en orden: la aplica en UNA transacción, repite los recorridos,
     aplica su REVERSA y comprueba que la foto vuelve EXACTAMENTE a la de antes, y la vuelve a aplicar
     (idempotencia).
  3. Al final aplica las cinco, corre todos los recorridos, aplica las reversas en orden inverso y
     comprueba que se recupera la línea base completa.

Uso: PGHOST=/var/run/postgresql PGUSER=root PGOPTIONS='-c role=postgres' ensayar-fase-2.py <base> <salida.json>
"""
import hashlib, json, os, re, subprocess, sys, tempfile

BASE, SALIDA = sys.argv[1], sys.argv[2]
RAIZ = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
FASE1 = ['20261031000001_fase1_quitar_truncate_trigger_references', '20261031000002_fase1_cerrar_funciones_de_trigger',
         '20261031000003_fase1_fijar_search_path', '20261031000004_fase1_quitar_lectura_anon_de_vistas',
         '20261031000005_fase1_quitar_escritura_anon_de_tablas', '20261031000006_fase1_lo_nuevo_nace_cerrado']
FASE2 = ['20261107000001_fase2_perfiles_campos_protegidos', '20261107000002_fase2_roles_rango_y_super_admins',
         '20261107000003_fase2_profiles_politica_por_area', '20261107000004_fase2_cxc_vencidas_solo_quien_ve_al_cliente',
         '20261107000005_fase2_super_admins_rastro']
# Foto de lo que toca la Fase 2 (más los permisos generales, que no deben moverse).
FOTO = """
select 'trg|' || c.relname || '|' || t.tgname || '|' || pg_get_triggerdef(t.oid) from pg_trigger t join pg_class c on c.oid = t.tgrelid
 where c.relname in ('profiles','user_roles','super_admins') and not t.tgisinternal
union all select 'pol|' || tablename || '|' || policyname || '|' || cmd || '|' || coalesce(qual,'') || '|' || coalesce(with_check,'') from pg_policies
 where schemaname = 'public' and tablename in ('profiles','user_roles','super_admins')
union all select 'fun|' || p.oid::regprocedure::text || '|' || p.prosecdef::text || '|' || md5(pg_get_functiondef(p.oid)) || '|' || coalesce(p.proconfig::text,'')
  from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('impedir_escalada_rol','proteger_perfil_fase2','proteger_profile_activo',
   'proteger_campos_privilegiados_profiles','cliente_tiene_cxc_vencidas','cxc_vencidas_resumen','rastro_lista_super_admins','asignar_super_admin','es_super_admin')
union all select 'acl|' || p.oid::regprocedure::text || '|' || coalesce(p.proacl::text,'') from pg_proc p where p.pronamespace = 'public'::regnamespace
union all select 'rel|' || c.relname || '|' || coalesce(c.relacl::text,'') from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r','v','p')
order by 1
"""
def psql(args, entrada=None):
    r = subprocess.run(['psql', '-X', '-At', '-d', BASE] + args, input=entrada, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return r.returncode, r.stdout
def foto():
    _, o = psql(['-c', FOTO.strip()])
    l = [x for x in o.splitlines() if x.startswith(('trg|', 'pol|', 'fun|', 'acl|', 'rel|'))]
    if len(l) < 300: sys.exit('Foto incompleta: ' + o[:300])
    return hashlib.md5('\n'.join(l).encode()).hexdigest(), l
def conteos():
    sql = open(os.path.join(RAIZ, 'docs/seguridad/consultas/02-conteos-linea-base.sql')).read().strip().rstrip(';')
    _, o = psql(['-c', f"select row_to_json(q) from ({sql}) q"]); return json.loads(o.splitlines()[-1])
def aplicar(ruta):
    t = open(ruta).read()
    _, ver = psql(['-c', 'show server_version_num'])
    if int(ver.strip().splitlines()[-1]) < 170000: t = re.sub(r',\s*MAINTAIN|MAINTAIN,\s*', '', t)
    with tempfile.NamedTemporaryFile('w', suffix='.sql', delete=False) as f: f.write(t)
    rc, o = psql(['-v', 'ON_ERROR_STOP=1', '--single-transaction', '-f', f.name]); os.unlink(f.name); return rc, o
def mig(n): return os.path.join(RAIZ, 'supabase/migrations', n + '.sql')
def rev(n): return os.path.join(RAIZ, 'supabase/reversas', n + '_reversa.sql')
def recorridos2(nombre):
    ruta = SALIDA.replace('.json', f'_r2_{nombre}.json')
    subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), 'recorridos-fase-2.py'), BASE, ruta], env={k: v for k, v in os.environ.items() if k != 'PGOPTIONS'}, stdout=subprocess.DEVNULL)
    return json.load(open(ruta))
def recorridos1(nombre):
    ruta = SALIDA.replace('.json', f'_r1_{nombre}.json')
    subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), 'probar-recorridos.py'), BASE, ruta], env={k: v for k, v in os.environ.items() if k != 'PGOPTIONS'}, stdout=subprocess.DEVNULL)
    return json.load(open(ruta))
def difs(a, b):
    sa, sb = set(a), set(b); return {'solo_antes': sorted(sa - sb)[:5], 'solo_despues': sorted(sb - sa)[:5], 'n': len(sa ^ sb)}
def resumen2(r): return {'diferencias': len(r['diferencias']), 'detalle': r['diferencias'], 'cartera_por_rol': r['cartera_por_cobrar'] if 'cartera_por_cobrar' in r else r['cartera_por_rol']}
def cambios_r1(a, b):
    """Acciones de los 8 roles de la Fase 1 cuyo resultado cambió entre dos corridas."""
    c = []
    for rol, accs in a['roles'].items():
        for n, v in accs.items():
            if b['roles'].get(rol, {}).get(n) != v: c.append({'rol': rol, 'accion': n, 'antes': v, 'despues': b['roles'][rol].get(n)})
    return c

res = {'pasos': []}
# 0. Fase 1
_, o = psql(['-c', "select count(*) from pg_proc where proname='proteger_perfil_fase2'"])
for n in FASE1:
    rc, o = aplicar(mig(n))
    if rc != 0: sys.exit('Falló la Fase 1 en ' + n + ': ' + o[-400:])
res['fase1_aplicada'] = True
h0, c0 = foto(); res['foto_inicial'] = h0; res['conteos_inicial'] = conteos()
res['r2_inicial'] = resumen2(recorridos2('0_antes')); res['r1_inicial'] = recorridos1('0_antes')
for n in FASE2:
    p = {'migracion': n}
    h_a, c_a = foto(); p['conteos_antes'] = conteos()
    rc, out = aplicar(mig(n)); p['aplicar_ok'] = rc == 0; p['aplicar_salida'] = [l for l in out.splitlines() if l.strip()][-4:]
    if rc != 0: p['error'] = out[-700:]; res['pasos'].append(p); break
    h_p, c_p = foto(); p['conteos_despues'] = conteos(); p['foto_cambio'] = h_p != h_a
    p['recorridos_fase2'] = resumen2(recorridos2(n[:14]))
    rc2, out2 = aplicar(rev(n)); h_r, c_r = foto()
    p['reversa_ok'] = rc2 == 0; p['reversa_restaura_exacto'] = h_r == h_a
    if h_r != h_a: p['reversa_difiere'] = difs(c_a, c_r)
    if rc2 != 0: p['reversa_error'] = out2[-400:]
    aplicar(mig(n)); h_re, _ = foto(); p['reaplicar_idempotente'] = h_re == h_p
    aplicar(mig(n))  # segunda vez seguida: idempotencia pura
    h_re2, _ = foto(); p['reaplicar_dos_veces_igual'] = h_re2 == h_p
    res['pasos'].append(p)
res['conteos_final'] = conteos(); res['r2_final'] = resumen2(recorridos2('9_final'))
r1f = recorridos1('9_final'); res['r1_final_cambios_vs_inicial'] = cambios_r1(res['r1_inicial'], r1f)
res['r1_generico_igual'] = res['r1_inicial']['generico'] == r1f['generico']; res['r1_alta_igual'] = res['r1_inicial']['alta_de_usuario'] == r1f['alta_de_usuario']
h_f, c_f = foto(); res['foto_final'] = h_f
for n in reversed(FASE2): aplicar(rev(n))
h_r, c_r = foto(); res['reversa_total_restaura_exacto'] = h_r == h0
if h_r != h0: res['reversa_total_difiere'] = difs(c0, c_r)
res['conteos_tras_reversa_total'] = conteos(); res['conteos_iguales_tras_reversa'] = res['conteos_tras_reversa_total'] == res['conteos_inicial']
r1r = recorridos1('9_tras_reversa'); res['r1_tras_reversa_cambios'] = cambios_r1(res['r1_inicial'], r1r)
res['r2_tras_reversa'] = resumen2(recorridos2('9_tras_reversa'))
for n in FASE2: aplicar(mig(n))
h_o, _ = foto(); res['reaplicar_todas_igual'] = h_o == h_f
json.dump(res, open(SALIDA, 'w'), ensure_ascii=False, indent=1, sort_keys=True); print('guardado en', SALIDA)

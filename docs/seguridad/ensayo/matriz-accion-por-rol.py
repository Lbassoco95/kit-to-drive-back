#!/usr/bin/env python3
"""Matriz acción × rol sobre la réplica local: lo esperado (reglas del front) contra lo que la base permite.

Para cada rol (área × nivel, más casos especiales) crea un usuario SINTÉTICO (@ejemplo.test), abre una
transacción, siembra filas propias y ajenas, simula al rol con `SET LOCAL ROLE authenticated` + claims JWT y
corre cada acción dentro de una subtransacción que se deshace; al final hace ROLLBACK. No toca producción ni usa
contraseñas ni cuentas reales.

Lo esperado sale de las reglas del front (`permisosDe` de src/lib/permissions.ts, volcadas a
`permisos-front-permisosDe.json` con `node --experimental-strip-types`), con la regla de alcance «el operador solo
trabaja con lo suyo». Cada celda queda en una de estas clases:
  OK          el front y la base coinciden
  BRECHA      la base PERMITE lo que el front no permite  → la regla vive solo en el front
  SOLO-UI     el front lo ofrece y la base lo RECHAZA      → botón que falla, no es un hueco de seguridad
Uso: PGHOST=/var/run/postgresql matriz-accion-por-rol.py <base> [salida.json]    (como usuario postgres)
"""
import json, os, re, subprocess, sys, uuid

DB = sys.argv[1]
SALIDA = sys.argv[2] if len(sys.argv) > 2 else None
AQUI = os.path.dirname(os.path.abspath(__file__))
FRONT = json.load(open(os.path.join(AQUI, 'permisos-front-permisosDe.json')))
NS = uuid.UUID('6d617472-697a-4000-8000-000000000001')

def uid(n): return str(uuid.uuid5(NS, n))
def fx(n): return str(uuid.uuid5(NS, 'fx-' + n))

AREAS = ['comercial', 'fabrica', 'almacen_logistica', 'administracion', 'compras', 'direccion']
NIVELES = ['operador', 'supervisor', 'admin']

# clave: (área, nivel, es_vendedor, es_administrativo, super, activo, con_rol)
ACTORES = {}
for a in AREAS:
    for n in NIVELES:
        ACTORES[f'{a}/{n}'] = dict(area=a, nivel=n, vend=(a == 'comercial' and n == 'operador'), admv=False, sup=False, activo=True, rol=True)
ACTORES['comercial/operador+administrativo'] = dict(area='comercial', nivel='operador', vend=False, admv=True, sup=False, activo=True, rol=True)
ACTORES['SUPER ADMIN'] = dict(area='direccion', nivel='admin', vend=False, admv=False, sup=True, activo=True, rol=True)
ACTORES['inactivo (comercial/operador)'] = dict(area='comercial', nivel='operador', vend=True, admv=False, sup=False, activo=False, rol=True)
ACTORES['sin rol asignado'] = dict(area=None, nivel=None, vend=False, admv=False, sup=False, activo=True, rol=False)

def psql(sql, db=DB):
    r = subprocess.run(['psql', '-X', '-q', '-d', db, '-v', 'ON_ERROR_STOP=0'], input=sql, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return r.stdout

def crear_pool():
    """Usuarios sintéticos: un actor por rol, otro vendedor (V2), un objetivo por área y dos especiales."""
    fil = []
    def alta(clave, area, nivel, vend=False, admv=False, sup=False, activo=True, rol=True):
        u = uid(clave); em = f"{re.sub('[^a-z0-9]', '', clave.lower())}@ejemplo.test"
        fil.append(f"""INSERT INTO public.altas_autorizadas (email, expira_at) VALUES ('{em}', now() + interval '10 minutes')
  ON CONFLICT (email) DO UPDATE SET expira_at = EXCLUDED.expira_at;
INSERT INTO auth.users (id, email) VALUES ('{u}', '{em}') ON CONFLICT (id) DO NOTHING;
UPDATE public.profiles SET nombre_completo = 'Sintético {clave}', activo = true, es_vendedor = {str(vend).lower()}, es_administrativo = {str(admv).lower()} WHERE id = '{u}';
DELETE FROM public.user_roles WHERE user_id = '{u}';""")
        if rol: fil.append(f"INSERT INTO public.user_roles (user_id, area, nivel) VALUES ('{u}', '{area}', '{nivel}');")
        if sup: fil.append(f"INSERT INTO public.super_admins (user_id) VALUES ('{u}') ON CONFLICT DO NOTHING;")
        if not activo: fil.append(f"UPDATE public.profiles SET activo = false WHERE id = '{u}';")
    for k, v in ACTORES.items():
        alta('actor ' + k, v['area'], v['nivel'], v['vend'], v['admv'], v['sup'], v['activo'], v['rol'])
    alta('V2 otro vendedor', 'comercial', 'operador', vend=True)
    for a in AREAS: alta('obj ' + a, a, 'operador')
    alta('obj sin rol', None, None, rol=False)
    alta('obj super', 'direccion', 'admin', sup=True)
    return [l for l in psql('\n'.join(fil)).splitlines() if 'ERROR' in l]

def otra_area(area): return 'fabrica' if area == 'comercial' else 'comercial'

def contexto(clave, a):
    """Identificadores que usan las acciones para este actor."""
    area = a['area'] or 'comercial'
    u = uid('actor ' + clave)
    # Solo un actor de Comercial (o inactivo, para probar que no lee lo suyo) es dueño de filas «propias».
    # Para los demás roles las filas «propias» son de otro vendedor: no tienen clientes ni remisiones propios.
    dueno = u if (a['rol'] and a['area'] == 'comercial') else uid('V2 otro vendedor')
    return dict(
        u=u, own=dueno, v2=uid('V2 otro vendedor'),
        cli_d=fx('cli-d'), cli_da=fx('cli-da'), rem_d=fx('rem-d'), rem_da=fx('rem-da'), cxc_d=fx('cxc-d'), rut_a=fx('rut-a'),
        cli_p=fx('cli-p'), cli_a=fx('cli-a'), rem_p=fx('rem-p'), rem_a=fx('rem-a'),
        cxc_p=fx('cxc-p'), cxc_a=fx('cxc-a'), abo_a=fx('abo-a'), sol_m=fx('sol-m'), sol_o=fx('sol-o'),
        area=area, otra=otra_area(area),
        obj_m=uid('obj ' + area), obj_o=uid('obj ' + otra_area(area)), obj_s=uid('obj super'), obj_n=uid('obj sin rol'))

def siembra(c):
    return f"""INSERT INTO public.clientes (id, nombre_comercial, vendedor_id) VALUES ('{c['cli_p']}', 'Fx propio', '{c['own']}'), ('{c['cli_a']}', 'Fx ajeno', '{c['v2']}'),
  ('{c['cli_d']}', 'Fx borrable propio', '{c['own']}'), ('{c['cli_da']}', 'Fx borrable ajeno', '{c['v2']}');
INSERT INTO public.remisiones (id, folio_remision, vendedor_id, cliente_id) VALUES ('{c['rem_p']}', 'FX-P', '{c['own']}', '{c['cli_p']}'), ('{c['rem_a']}', 'FX-A', '{c['v2']}', '{c['cli_a']}'),
  ('{c['rem_d']}', 'FX-D', '{c['own']}', '{c['cli_p']}'), ('{c['rem_da']}', 'FX-DA', '{c['v2']}', '{c['cli_a']}');
INSERT INTO public.cuentas_por_cobrar (id, cliente_id, concepto, monto, saldo, fecha_vencimiento) VALUES ('{c['cxc_p']}', '{c['cli_p']}', 'fx', 100, 100, current_date), ('{c['cxc_a']}', '{c['cli_a']}', 'fx', 100, 100, current_date),
  ('{c['cxc_d']}', '{c['cli_p']}', 'fx', 100, 100, current_date);
INSERT INTO public.crm_rutas (id, vendedor_id, fecha) VALUES ('{c['rut_a']}', '{c['v2']}', current_date);
INSERT INTO public.cxc_abonos (id, cxc_id, monto) VALUES ('{c['abo_a']}', '{c['cxc_a']}', 10);
INSERT INTO public.solicitudes_aprobacion (id, tipo, objeto, area, motivo, solicitado_por) VALUES
  ('{c['sol_m']}', 'borrar', 'clientes', '{c['area']}', 'fx', '{c['v2']}'), ('{c['sol_o']}', 'borrar', 'clientes', '{c['otra']}', 'fx', '{c['v2']}');"""

# (id, dominio, descripción, tipo, SQL, módulo, clase de regla)
# clase: ver_propio, ver_ajeno, crear, crear_a_otro, editar_propio, editar_ajeno, eliminar, nadie, super,
#        usr_misma, usr_otra, usr_global, aprobar_misma, aprobar_otra, global
def acciones():
    A = []
    def add(i, d, desc, tipo, sql, mod, regla): A.append((i, d, desc, tipo, sql, mod, regla))
    # --- Clientes
    add('cli01', 'Clientes', 'Leer un cliente suyo', 'q', "select count(*) from public.clientes where id='{cli_p}'", 'clientes', 'ver_propio')
    add('cli02', 'Clientes', 'Leer el cliente de otro vendedor', 'q', "select count(*) from public.clientes where id='{cli_a}'", 'clientes', 'ver_ajeno')
    add('cli03', 'Clientes', 'Crear un cliente a su nombre', 'dml', "insert into public.clientes (nombre_comercial, vendedor_id) values ('Fx nuevo', '{u}')", 'clientes', 'crear')
    add('cli04', 'Clientes', 'Crear un cliente a nombre de otro vendedor', 'dml', "insert into public.clientes (nombre_comercial, vendedor_id) values ('Fx nuevo', '{v2}')", 'clientes', 'crear_a_otro')
    add('cli05', 'Clientes', 'Editar un cliente suyo', 'dml', "update public.clientes set notas='x' where id='{cli_p}'", 'clientes', 'editar_propio')
    add('cli06', 'Clientes', 'Editar el cliente de otro vendedor', 'dml', "update public.clientes set notas='x' where id='{cli_a}'", 'clientes', 'editar_ajeno')
    add('cli07', 'Clientes', 'Cambiar el límite de crédito de un cliente suyo', 'dml', "update public.clientes set limite_credito=999999 where id='{cli_p}'", 'credito', 'editar_ajeno')
    add('cli08', 'Clientes', 'Pasar un cliente suyo a otro vendedor', 'dml', "update public.clientes set vendedor_id='{v2}' where id='{cli_p}'", 'clientes', 'editar_ajeno')
    add('cli09', 'Clientes', 'Borrar un cliente suyo', 'dml', "delete from public.clientes where id='{cli_d}'", 'clientes', 'eliminar')
    add('cli10', 'Clientes', 'Borrar el cliente de otro vendedor', 'dml', "delete from public.clientes where id='{cli_da}'", 'clientes', 'eliminar')
    # --- Remisiones
    add('rem01', 'Remisiones', 'Leer una remisión suya', 'q', "select count(*) from public.remisiones where id='{rem_p}'", 'remisiones', 'ver_propio')
    add('rem02', 'Remisiones', 'Leer la remisión de otro vendedor', 'q', "select count(*) from public.remisiones where id='{rem_a}'", 'remisiones', 'ver_ajeno')
    add('rem03', 'Remisiones', 'Crear una remisión suya a un cliente suyo', 'dml', "insert into public.remisiones (folio_remision, vendedor_id, cliente_id) values ('FX-N1', '{u}', '{cli_p}')", 'remisiones', 'crear')
    add('rem04', 'Remisiones', 'Crear una remisión a un cliente de otro vendedor', 'dml', "insert into public.remisiones (folio_remision, vendedor_id, cliente_id) values ('FX-N2', '{u}', '{cli_a}')", 'remisiones', 'crear_a_otro')
    add('rem05', 'Remisiones', 'Crear una remisión a nombre de otro vendedor', 'dml', "insert into public.remisiones (folio_remision, vendedor_id, cliente_id) values ('FX-N3', '{v2}', '{cli_p}')", 'remisiones', 'crear_a_otro')
    add('rem06', 'Remisiones', 'Editar una remisión suya', 'dml', "update public.remisiones set notas='x' where id='{rem_p}'", 'remisiones', 'editar_propio')
    add('rem07', 'Remisiones', 'Editar la remisión de otro vendedor', 'dml', "update public.remisiones set notas='x' where id='{rem_a}'", 'remisiones', 'editar_ajeno')
    add('rem08', 'Remisiones', 'Cambiar el vendedor de una remisión suya (UPDATE directo)', 'dml', "update public.remisiones set vendedor_id='{v2}' where id='{rem_p}'", 'remisiones', 'editar_ajeno')
    add('rem09', 'Remisiones', 'Cancelar una remisión suya (UPDATE directo a CANCELADA)', 'dml', "update public.remisiones set estatus='CANCELADA' where id='{rem_p}'", 'remisiones', 'editar_ajeno')
    add('rem10', 'Remisiones', 'Borrar una remisión suya', 'dml', "delete from public.remisiones where id='{rem_d}'", 'remisiones', 'eliminar')
    add('rem11', 'Remisiones', 'Borrar la remisión de otro vendedor', 'dml', "delete from public.remisiones where id='{rem_da}'", 'remisiones', 'eliminar')
    add('rem12', 'Remisiones', 'Asignar vendedor por la función asignar_vendedor_remision', 'q', "select count(*) from (select public.asignar_vendedor_remision('motocarros', '{rem_a}', '{v2}')) s", 'remisiones', 'editar_ajeno')
    # --- Cuentas por cobrar
    add('cxc01', 'Cuentas por cobrar', 'Leer una cuenta por cobrar de un cliente suyo', 'q', "select count(*) from public.cuentas_por_cobrar where id='{cxc_p}'", 'credito', 'ver_propio')
    add('cxc02', 'Cuentas por cobrar', 'Leer la cuenta por cobrar de un cliente ajeno', 'q', "select count(*) from public.cuentas_por_cobrar where id='{cxc_a}'", 'credito', 'ver_ajeno')
    add('cxc03', 'Cuentas por cobrar', 'Crear una cuenta por cobrar', 'dml', "insert into public.cuentas_por_cobrar (cliente_id, concepto, monto, saldo, fecha_vencimiento) values ('{cli_p}', 'fx', 5, 5, current_date)", 'credito', 'editar_ajeno')
    add('cxc04', 'Cuentas por cobrar', 'Editar (perdonar saldo de) una cuenta por cobrar', 'dml', "update public.cuentas_por_cobrar set saldo=0 where id='{cxc_p}'", 'credito', 'editar_ajeno')
    add('cxc05', 'Cuentas por cobrar', 'Borrar una cuenta por cobrar', 'dml', "delete from public.cuentas_por_cobrar where id='{cxc_d}'", 'credito', 'eliminar')
    add('cxc06', 'Cuentas por cobrar', 'Registrar un abono', 'dml', "insert into public.cxc_abonos (cxc_id, monto, created_by) values ('{cxc_p}', 1, '{u}')", 'credito', 'editar_ajeno')
    add('cxc07', 'Cuentas por cobrar', 'Borrar un abono', 'dml', "delete from public.cxc_abonos where id='{abo_a}'", 'credito', 'eliminar')
    add('cxc08', 'Cuentas por cobrar', 'Leer la vista de crédito de clientes', 'q', "select count(*) from public.v_clientes_credito where id='{cli_p}'", 'credito', 'ver_propio')
    # --- Usuarios y roles
    add('usr01', 'Usuarios y roles', 'Leer el perfil de otra persona', 'q', "select count(*) from public.profiles where id='{obj_o}'", 'dashboard', 'ver_propio')
    add('usr02', 'Usuarios y roles', 'Leer los roles de otra persona', 'q', "select count(*) from public.user_roles where user_id='{obj_o}'", 'usuarios', 'usr_otra')
    add('usr03', 'Usuarios y roles', 'Editar el nombre de alguien de su área', 'dml', "update public.profiles set nombre_completo='x' where id='{obj_m}' and id<>'{u}'", 'usuarios', 'usr_misma')
    add('usr04', 'Usuarios y roles', 'Editar el nombre de alguien de OTRA área', 'dml', "update public.profiles set nombre_completo='x' where id='{obj_o}'", 'usuarios', 'usr_otra')
    add('usr05', 'Usuarios y roles', 'Editar el nombre del SUPER ADMIN', 'dml', "update public.profiles set nombre_completo='x' where id='{obj_s}'", 'usuarios', 'usr_global')
    add('usr06', 'Usuarios y roles', 'Desactivar a alguien de su área', 'dml', "update public.profiles set activo=false where id='{obj_m}' and id<>'{u}'", 'usuarios', 'usr_misma')
    add('usr07', 'Usuarios y roles', 'Desactivar a alguien de OTRA área', 'dml', "update public.profiles set activo=false where id='{obj_o}'", 'usuarios', 'usr_otra')
    add('usr08', 'Usuarios y roles', 'Cambiar el correo (perfil) de alguien de su área', 'dml', "update public.profiles set email='x@ejemplo.test' where id='{obj_m}' and id<>'{u}'", 'usuarios', 'usr_misma')
    add('usr09', 'Usuarios y roles', 'Cambiar el correo (perfil) de alguien de OTRA área', 'dml', "update public.profiles set email='x@ejemplo.test' where id='{obj_o}'", 'usuarios', 'usr_otra')
    add('usr10', 'Usuarios y roles', 'Cambiar el código de vendedor de otra persona', 'dml', "update public.profiles set codigo_vendedor='ZZ9' where id='{obj_o}'", 'usuarios', 'usr_otra')
    add('usr11', 'Usuarios y roles', 'Marcarse a sí mismo «administrativo» (campo es_administrativo)', 'dml', "update public.profiles set es_administrativo=true where id='{u}'", 'usuarios', 'usr_misma')
    add('usr12', 'Usuarios y roles', 'Marcarse a sí mismo «vendedor» (campo es_vendedor)', 'dml', "update public.profiles set es_vendedor=true where id='{u}'", 'usuarios', 'usr_misma')
    add('usr13', 'Usuarios y roles', 'Autoascenso: marcarse «administrativo» y luego leer clientes ajenos', 'plsql',
        "update public.profiles set es_administrativo=true where id='{u}'; select count(*) into n from public.clientes where id='{cli_a}';", 'clientes', 'ver_ajeno')
    add('usr14', 'Usuarios y roles', 'Dar rol a alguien sin rol, en su área', 'dml', "insert into public.user_roles (user_id, area, nivel) values ('{obj_n}', '{area}', 'operador')", 'usuarios', 'usr_misma')
    add('usr15', 'Usuarios y roles', 'Dar rol a alguien sin rol, en OTRA área', 'dml', "insert into public.user_roles (user_id, area, nivel) values ('{obj_n}', '{otra}', 'operador')", 'usuarios', 'usr_otra')
    add('usr16', 'Usuarios y roles', 'Dar a alguien el rol de administrador global (Dirección/admin)', 'dml', "insert into public.user_roles (user_id, area, nivel) values ('{obj_n}', 'direccion', 'admin')", 'usuarios', 'usr_global')
    add('usr17', 'Usuarios y roles', 'Subir de nivel a alguien de su área', 'dml', "update public.user_roles set nivel='admin' where user_id='{obj_m}' and user_id<>'{u}'", 'usuarios', 'usr_misma')
    add('usr18', 'Usuarios y roles', 'Subir de nivel a alguien de OTRA área', 'dml', "update public.user_roles set nivel='admin' where user_id='{obj_o}'", 'usuarios', 'usr_otra')
    add('usr19', 'Usuarios y roles', 'Pasar a alguien de su área a Dirección/admin', 'dml', "update public.user_roles set area='direccion', nivel='admin' where user_id='{obj_m}' and user_id<>'{u}'", 'usuarios', 'usr_global')
    add('usr20', 'Usuarios y roles', 'Quitar el rol a alguien de su área', 'dml', "delete from public.user_roles where user_id='{obj_m}' and user_id<>'{u}'", 'usuarios', 'usr_misma')
    add('usr21', 'Usuarios y roles', 'Quitar el rol a alguien de OTRA área', 'dml', "delete from public.user_roles where user_id='{obj_o}'", 'usuarios', 'usr_otra')
    add('usr22', 'Usuarios y roles', 'Subirse a sí mismo a Dirección/admin (para Dirección/admin no cambia nada)', 'dml', "update public.user_roles set area='direccion', nivel='admin' where user_id='{u}'", 'nadie', 'autoascenso')
    add('usr23', 'Usuarios y roles', 'Leer la tabla de super admins directamente', 'q', "select count(*) from public.super_admins", 'nadie', 'nadie')
    add('usr24', 'Usuarios y roles', 'Insertarse como super admin (INSERT directo)', 'dml', "insert into public.super_admins (user_id) values ('{obj_m}')", 'nadie', 'nadie')
    add('usr25', 'Usuarios y roles', 'Asignar super admin por la función asignar_super_admin', 'q', "select count(*) from (select public.asignar_super_admin('{obj_m}', true)) s", 'usuarios', 'global_no_super')
    # --- Aprobaciones
    add('apr01', 'Aprobaciones', 'Leer una solicitud de su área', 'q', "select count(*) from public.solicitudes_aprobacion where id='{sol_m}'", 'aprobaciones', 'aprobar_misma')
    add('apr02', 'Aprobaciones', 'Leer una solicitud de OTRA área', 'q', "select count(*) from public.solicitudes_aprobacion where id='{sol_o}'", 'aprobaciones', 'aprobar_otra')
    add('apr03', 'Aprobaciones', 'Crear una solicitud (INSERT directo)', 'dml', "insert into public.solicitudes_aprobacion (tipo, objeto, area, motivo, solicitado_por) values ('borrar','clientes','{area}','fx','{u}')", 'nadie', 'nadie')
    add('apr04', 'Aprobaciones', 'Marcar una solicitud como aprobada (UPDATE directo)', 'dml', "update public.solicitudes_aprobacion set estado='aprobada' where id='{sol_m}'", 'nadie', 'nadie')
    add('apr05', 'Aprobaciones', 'Borrar una solicitud (DELETE directo)', 'dml', "delete from public.solicitudes_aprobacion where id='{sol_m}'", 'nadie', 'nadie')
    add('apr06', 'Aprobaciones', 'Pedir una aprobación por la función solicitar_aprobacion', 'q', "select count(*) from (select public.solicitar_aprobacion('borrar','clientes','{{\"id\":\"{cli_p}\"}}'::jsonb,'fx','motivo fx')) s", 'nadie', 'super')
    add('apr07', 'Aprobaciones', 'Resolver (rechazar) una solicitud de su área', 'q', "select count(*) from (select public.resolver_solicitud_aprobacion('{sol_m}', false, 'fx')) s", 'aprobaciones', 'aprobar_misma')
    add('apr08', 'Aprobaciones', 'Resolver (rechazar) una solicitud de OTRA área', 'q', "select count(*) from (select public.resolver_solicitud_aprobacion('{sol_o}', false, 'fx')) s", 'aprobaciones', 'aprobar_otra')
    add('apr09', 'Aprobaciones', 'Eliminar una solicitud por la función eliminar_solicitud_aprobacion', 'q', "select count(*) from (select public.eliminar_solicitud_aprobacion('{sol_m}')) s", 'aprobaciones', 'global')
    # --- Escrituras sin comprobación de rol (políticas que solo piden «ser yo»)
    add('abi01', 'Escrituras abiertas', 'Anotar en la bitácora de un cliente que no ve (clientes_bitacora)', 'dml', "insert into public.clientes_bitacora (cliente_id, usuario_id, tipo_cambio, motivo) values ('{cli_a}', '{u}', 'edicion', 'fx')", 'clientes', 'editar_ajeno')
    add('abi02', 'Escrituras abiertas', 'Comentar en la ficha de un cliente que no ve (clientes_comentarios)', 'dml', "insert into public.clientes_comentarios (cliente_id, usuario_id, comentario) values ('{cli_a}', '{u}', 'fx')", 'clientes', 'ver_ajeno')
    add('abi03', 'Escrituras abiertas', 'Anotar en la bitácora de una remisión ajena (remisiones_bitacora)', 'dml', "insert into public.remisiones_bitacora (remision_id, usuario_id, motivo) values ('{rem_a}', '{u}', 'motivo de la prueba fx')", 'remisiones', 'editar_ajeno')
    add('abi04', 'Escrituras abiertas', 'Mandar un aviso a Dirección (avisos; el front nunca inserta en avisos)', 'dml', "insert into public.avisos (area_destino, titulo, creado_por) values ('direccion', 'fx', '{u}')", 'nadie', 'nadie')
    add('abi05', 'Escrituras abiertas', 'Mandar una notificación a otra persona (notificaciones)', 'dml', "insert into public.notificaciones (usuario_destino, titulo, creado_por) values ('{v2}', 'fx', '{u}')", 'dashboard', 'rol_activo')
    add('abi06', 'Escrituras abiertas', 'Agregar una parada a la ruta de otro vendedor (crm_ruta_paradas)', 'dml', "insert into public.crm_ruta_paradas (ruta_id, descripcion) values ('{rut_a}', 'fx')", 'crm', 'editar_ajeno')
    # Controles positivos: lo legítimo que el front hace sobre lo suyo debe seguir pasando
    add('abp01', 'Controles positivos', 'Anotar en la bitácora de un cliente suyo', 'dml', "insert into public.clientes_bitacora (cliente_id, usuario_id, tipo_cambio, motivo) values ('{cli_p}', '{u}', 'edicion', 'fx')", 'clientes', 'editar_propio')
    add('abp02', 'Controles positivos', 'Comentar en la ficha de un cliente suyo', 'dml', "insert into public.clientes_comentarios (cliente_id, usuario_id, comentario) values ('{cli_p}', '{u}', 'fx')", 'clientes', 'editar_propio')
    add('abp03', 'Controles positivos', 'Anotar en la bitácora de una remisión suya', 'dml', "insert into public.remisiones_bitacora (remision_id, usuario_id, motivo) values ('{rem_p}', '{u}', 'motivo de la prueba fx')", 'remisiones', 'editar_propio')
    # --- Lecturas con USING (true)
    add('lec01', 'Lecturas abiertas', 'Leer inventario_motivos_ajuste (USING true)', 'q', "select count(*) from public.inventario_motivos_ajuste", 'dashboard', 'rol_activo')
    add('lec02', 'Lecturas abiertas', 'Leer inventario_reglas_modo_prueba (USING true)', 'q', "select count(*) from public.inventario_reglas_modo_prueba", 'dashboard', 'rol_activo')
    add('lec03', 'Lecturas abiertas', 'Leer inventario_unidades_venta (USING true)', 'q', "select count(*) from public.inventario_unidades_venta", 'dashboard', 'rol_activo')
    return A

def esperado(clave, a, accion):
    """¿Debería poder según el front? (None si el actor no tiene sesión útil: siempre False.)"""
    _, _, _, _, _, mod, regla = accion
    if not a['rol'] or not a['activo']: return False
    p = FRONT[f"{a['area']}/{a['nivel']}"]
    glob = p['esAdminGlobal']; sup = a['sup']
    m = p['mod'].get(mod, {})
    if regla == 'nadie': return False
    if regla == 'super': return sup
    if regla == 'global': return glob
    if regla == 'global_no_super': return glob and not sup
    if regla == 'autoascenso': return glob
    if regla == 'rol_activo': return True
    if regla == 'ver_cualquiera': return m['ver']
    if regla == 'ver_propio': return m['ver']
    if regla == 'ver_ajeno': return m['ver'] and (not m['propios'] or a['area'] != 'comercial')
    if regla == 'crear': return m['crear']
    if regla in ('crear_a_otro', 'editar_ajeno'): return m['editar']
    if regla == 'editar_propio': return m['crear']
    if regla == 'eliminar': return m['eliminar']
    if regla == 'usr_misma': return p['gestionaUsuarios'] and m['ver']
    if regla == 'usr_otra': return glob
    if regla == 'usr_global': return glob
    if regla == 'aprobar_misma': return m['aprobar']
    if regla == 'aprobar_otra': return glob or sup
    raise ValueError(regla)

def cuerpo(accion, ctx):
    i, d, desc, tipo, sql, mod, regla = accion
    sql = sql.format(**ctx)
    if tipo == 'plsql':
        return f"""DO $do$ DECLARE n bigint := 0; BEGIN BEGIN {sql}
  RAISE EXCEPTION 'deshacer' USING ERRCODE = 'RB001';
  EXCEPTION WHEN SQLSTATE 'RB001' THEN RAISE NOTICE 'RES|{i}|ok|%', n;
            WHEN OTHERS THEN RAISE NOTICE 'RES|{i}|err|%', SQLSTATE; END; END $do$;"""
    esc = sql.replace("'", "''")
    ej = f"EXECUTE '{esc}' INTO n;" if tipo == 'q' else f"EXECUTE '{esc}'; GET DIAGNOSTICS n = ROW_COUNT;"
    return f"""DO $do$ DECLARE n bigint; BEGIN BEGIN {ej}
  RAISE EXCEPTION 'deshacer' USING ERRCODE = 'RB001';
  EXCEPTION WHEN SQLSTATE 'RB001' THEN RAISE NOTICE 'RES|{i}|ok|%', n;
            WHEN OTHERS THEN RAISE NOTICE 'RES|{i}|err|%', SQLSTATE; END; END $do$;"""

def corre(clave, a, acs, anon=False):
    ctx = contexto(clave, a)
    sql = "BEGIN;\n" + siembra(ctx) + "\n"
    if anon:
        sql += "SET LOCAL ROLE anon;\n"
    else:
        sql += "SET LOCAL ROLE authenticated;\n"
        sql += f"SELECT set_config('request.jwt.claim.sub', '{ctx['u']}', true), set_config('request.jwt.claims', '{{\"sub\":\"{ctx['u']}\",\"role\":\"authenticated\"}}', true) \\g /dev/null\n"
    sql += '\n'.join(cuerpo(x, ctx) for x in acs) + "\nROLLBACK;\n"
    salida = psql(sql); res = {}
    for l in salida.splitlines():
        m = re.search(r'RES\|([^|]+)\|(ok|err)\|(.*)$', l)
        if m: res[m.group(1)] = (m.group(2), m.group(3).strip())
    errs = [l for l in salida.splitlines() if 'ERROR' in l and 'RES|' not in l]
    return res, errs

def permite(r):
    if r is None: return None
    st, v = r
    if st == 'err': return False
    return int(v or 0) > 0

if __name__ == '__main__':
    e = crear_pool()
    acs = acciones()
    out = {'errores_al_crear_usuarios': e, 'acciones': {x[0]: dict(dominio=x[1], desc=x[2], modulo=x[5], regla=x[6]) for x in acs}, 'actores': {}, 'anon': {}, 'errores_de_siembra': {}}
    for clave, a in ACTORES.items():
        res, errs = corre(clave, a, acs)
        if errs: out['errores_de_siembra'][clave] = errs[:5]
        celdas = {}
        for x in acs:
            r = res.get(x[0]); real = permite(r); esp = esperado(clave, a, x)
            clase = 'SIN-RESULTADO' if real is None else ('OK' if real == esp else ('BRECHA' if real else 'SOLO-UI'))
            celdas[x[0]] = dict(base=('permite' if real else 'rechaza'), detalle=(r[1] if r else None), esperado=('permite' if esp else 'rechaza'), clase=clase)
        out['actores'][clave] = celdas
    res, errs = corre('anon', dict(area='comercial', nivel='operador', rol=False), acs, anon=True)
    out['anon'] = {x[0]: ('permite' if permite(res.get(x[0])) else 'rechaza') + ' ' + (res[x[0]][1] if x[0] in res else '-') for x in acs}
    txt = json.dumps(out, ensure_ascii=False, indent=1, sort_keys=True)
    if SALIDA: open(SALIDA, 'w').write(txt); print('guardado en', SALIDA)
    resumen = {}
    for clave, cel in out['actores'].items():
        for k, v in cel.items(): resumen[v['clase']] = resumen.get(v['clase'], 0) + 1
    print(resumen, 'siembra con errores:', list(out['errores_de_siembra']))

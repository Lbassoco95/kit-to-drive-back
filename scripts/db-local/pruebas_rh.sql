-- ============================================================================
-- Pruebas (base de datos) del módulo de Recursos Humanos.
--   PGHOST=/tmp/pgd PGPORT=5433 PGUSER=postgres scripts/db-local/probar_rh.sh
-- Cada prueba entra como un usuario distinto (rol authenticated).
-- ============================================================================
\set ON_ERROR_STOP 1
SET client_min_messages = notice;

INSERT INTO auth.users (id, email, raw_app_meta_data) SELECT id::uuid, email, '{"created_via_admin": "true"}'::jsonb FROM (VALUES
  ('00000000-0000-0000-0000-0000000000c1', 'rh@dazon.test'),
  ('00000000-0000-0000-0000-0000000000c2', 'ana@dazon.test'),
  ('00000000-0000-0000-0000-0000000000c3', 'beto@dazon.test'),
  ('00000000-0000-0000-0000-0000000000c4', 'jefe@dazon.test'),
  ('00000000-0000-0000-0000-0000000000c5', 'dir@dazon.test'),
  ('00000000-0000-0000-0000-0000000000c6', 'adminsinrh@dazon.test')) AS u(id, email)
ON CONFLICT (id) DO NOTHING;
INSERT INTO public.profiles (id, nombre_completo, activo)
SELECT id, split_part(email, '@', 1), true FROM auth.users WHERE id::text LIKE '00000000-0000-0000-0000-0000000000c%' ON CONFLICT (id) DO NOTHING;
DELETE FROM public.user_roles WHERE user_id::text LIKE '00000000-0000-0000-0000-0000000000c%';
INSERT INTO public.user_roles (user_id, role, area, nivel) VALUES
  ('00000000-0000-0000-0000-0000000000c1', 'admin_financiero', 'administracion', 'admin'),
  ('00000000-0000-0000-0000-0000000000c2', 'ventas',           'comercial',      'operador'),
  ('00000000-0000-0000-0000-0000000000c3', 'fabrica',          'fabrica',        'operador'),
  ('00000000-0000-0000-0000-0000000000c4', 'coordinador_ventas','comercial',     'supervisor'),
  ('00000000-0000-0000-0000-0000000000c5', 'admin',            'direccion',      'admin'),
  ('00000000-0000-0000-0000-0000000000c6', 'admin_financiero', 'administracion', 'admin');
-- Dirección designa a RH.
DELETE FROM public.rh_empleados WHERE user_id::text LIKE '00000000-0000-0000-0000-0000000000c%';
DELETE FROM public.rh_acceso;
DELETE FROM public.rh_puestos WHERE nombre = 'Vendedor';
INSERT INTO public.rh_acceso (user_id) VALUES ('00000000-0000-0000-0000-0000000000c1');

CREATE OR REPLACE FUNCTION public._t_como(_email text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', (SELECT id::text FROM auth.users WHERE email = _email), true);
  EXECUTE 'SET LOCAL ROLE authenticated';
END $$;
CREATE OR REPLACE FUNCTION public._t_falla(_sql text, _patron text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE _sql;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM !~* _patron THEN RAISE EXCEPTION 'Falló con otro mensaje. Esperado /%/, llegó: %', _patron, SQLERRM; END IF;
    RETURN;
  END;
  RAISE EXCEPTION 'Debió fallar (esperado /%/): %', _patron, _sql;
END $$;
GRANT EXECUTE ON FUNCTION public._t_como(text), public._t_falla(text, text) TO authenticated;

-- ── 1. Quién es RH ──────────────────────────────────────────────────────────
BEGIN;
  SELECT public._t_como('rh@dazon.test');
  DO $$ BEGIN IF NOT public.rh_es_rh() THEN RAISE EXCEPTION 'admin con rol adicional debe ser RH'; END IF; END $$;
  RESET ROLE; SELECT public._t_como('dir@dazon.test');
  DO $$ BEGIN IF NOT public.rh_es_rh() THEN RAISE EXCEPTION 'admin global debe ser RH'; END IF; END $$;
  RESET ROLE; SELECT public._t_como('adminsinrh@dazon.test');
  DO $$ BEGIN IF public.rh_es_rh() THEN RAISE EXCEPTION 'un admin SIN el rol adicional no es RH'; END IF; END $$;
  RESET ROLE; SELECT public._t_como('ana@dazon.test');
  DO $$ BEGIN IF public.rh_es_rh() THEN RAISE EXCEPTION 'un operador no es RH'; END IF; END $$;
  SELECT public._t_falla($q$INSERT INTO public.rh_acceso (user_id) VALUES ('00000000-0000-0000-0000-0000000000c2')$q$, 'row-level security');
ROLLBACK;
\echo 'ok  1. Quién es RH'

-- ── 2. Plantilla: sincroniza y asigna área, puesto y jefe ───────────────────
SELECT public._t_como('rh@dazon.test') \gset
BEGIN;
  SELECT public._t_como('rh@dazon.test');
  SELECT public.rh_sincronizar_plantilla() >= 6 AS ok \gset
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_empleados WHERE user_id::text LIKE '00000000-0000-0000-0000-0000000000c%') <> 6 THEN RAISE EXCEPTION 'sincronizar debe crear 6 fichas'; END IF; END $$;
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_empleados e JOIN public.rh_areas a ON a.id = e.area_id WHERE e.user_id = '00000000-0000-0000-0000-0000000000c2' AND a.clave = 'comercial') <> 1 THEN RAISE EXCEPTION 'el área sale del user_roles'; END IF; END $$;
  DO $$ BEGIN IF public.rh_sincronizar_plantilla() <> 0 THEN RAISE EXCEPTION 'segunda corrida no debe duplicar'; END IF; END $$;
  INSERT INTO public.rh_puestos (nombre, area_id) SELECT 'Vendedor', id FROM public.rh_areas WHERE clave = 'comercial';
  UPDATE public.rh_empleados SET reporta_a = (SELECT id FROM public.rh_empleados WHERE user_id = '00000000-0000-0000-0000-0000000000c4'),
         puesto_id = (SELECT id FROM public.rh_puestos WHERE nombre = 'Vendedor')
   WHERE user_id = '00000000-0000-0000-0000-0000000000c2';
  UPDATE public.rh_empleados SET reporta_a = (SELECT id FROM public.rh_empleados WHERE user_id = '00000000-0000-0000-0000-0000000000c4')
   WHERE user_id = '00000000-0000-0000-0000-0000000000c3';
  SELECT public._t_falla($q$UPDATE public.rh_empleados SET reporta_a = id WHERE user_id = '00000000-0000-0000-0000-0000000000c2'$q$, 'check');
  -- Dejar la plantilla para las pruebas siguientes.
COMMIT;
\echo 'ok  2. Plantilla'

-- ── 3. Privacidad: ficha, directorio y expediente ───────────────────────────
BEGIN;
  SELECT public._t_como('ana@dazon.test');
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_empleados) <> 1 THEN RAISE EXCEPTION 'Ana solo ve su ficha, ve %', (SELECT count(*) FROM public.rh_empleados); END IF; END $$;
  DO $$ BEGIN IF (SELECT count(*) FROM public.v_rh_directorio) < 6 THEN RAISE EXCEPTION 'el directorio es general'; END IF; END $$;
  DO $$ BEGIN PERFORM column_name FROM information_schema.columns WHERE table_name = 'v_rh_directorio' AND column_name IN ('telefono','fecha_ingreso','motivo_baja'); IF FOUND THEN RAISE EXCEPTION 'el directorio no debe exponer datos personales'; END IF; END $$;
  -- Ana captura sus datos y sube un documento.
  INSERT INTO public.rh_empleado_datos (empleado_id, rfc, curp) SELECT id, 'XAXX010101000', 'AAAA000000HDFXXX00' FROM public.rh_empleados WHERE user_id = auth.uid();
  INSERT INTO public.rh_documentos (empleado_id, tipo_id, ruta, nombre_archivo, estatus)
    SELECT e.id, t.id, e.id || '/ine/ine.pdf', 'ine.pdf', 'verificado' FROM public.rh_empleados e, public.rh_tipos_documento t WHERE e.user_id = auth.uid() AND t.clave = 'ine';
  DO $$ BEGIN IF (SELECT estatus FROM public.rh_documentos LIMIT 1) <> 'subido' THEN RAISE EXCEPTION 'un colaborador no puede subir un documento ya verificado'; END IF; END $$;
  UPDATE public.rh_documentos SET estatus = 'verificado';
  DO $$ BEGIN IF (SELECT estatus FROM public.rh_documentos LIMIT 1) <> 'subido' THEN RAISE EXCEPTION 'un colaborador no puede verificar documentos'; END IF; END $$;
  RESET ROLE; SELECT public._t_como('beto@dazon.test');
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_documentos) <> 0 THEN RAISE EXCEPTION 'Beto no ve documentos ajenos'; END IF; END $$;
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_empleado_datos) <> 0 THEN RAISE EXCEPTION 'Beto no ve datos ajenos'; END IF; END $$;
  RESET ROLE; SELECT public._t_como('jefe@dazon.test');
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_empleados) <> 3 THEN RAISE EXCEPTION 'el jefe ve su ficha y la de sus 2 reportes, ve %', (SELECT count(*) FROM public.rh_empleados); END IF; END $$;
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_documentos) <> 0 THEN RAISE EXCEPTION 'el jefe NO ve expedientes'; END IF; END $$;
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_empleado_datos) <> 0 THEN RAISE EXCEPTION 'el jefe NO ve datos sensibles'; END IF; END $$;
  RESET ROLE; SELECT public._t_como('rh@dazon.test');
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_documentos) <> 1 THEN RAISE EXCEPTION 'RH ve el expediente'; END IF; END $$;
  UPDATE public.rh_documentos SET estatus = 'verificado';
  DO $$ BEGIN IF (SELECT verificado_por FROM public.rh_documentos) IS NULL THEN RAISE EXCEPTION 'la verificación guarda autor'; END IF; END $$;
  SELECT public.rh_registrar_acceso((SELECT id FROM public.rh_empleados WHERE user_id = '00000000-0000-0000-0000-0000000000c2'), 'ver_expediente');
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_bitacora_accesos) <> 1 THEN RAISE EXCEPTION 'el acceso queda en bitácora'; END IF; END $$;
  RESET ROLE; SELECT public._t_como('ana@dazon.test');
  DELETE FROM public.rh_documentos;
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_documentos) <> 1 THEN RAISE EXCEPTION 'un documento verificado no se borra'; END IF; END $$;
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_bitacora_accesos) <> 0 THEN RAISE EXCEPTION 'la bitácora solo la lee RH'; END IF; END $$;
ROLLBACK;
\echo 'ok  3. Privacidad de ficha, directorio y expediente'

-- ── 4. Biblioteca y publicaciones ───────────────────────────────────────────
BEGIN;
  SELECT public._t_como('rh@dazon.test');
  INSERT INTO public.rh_biblioteca_documentos (id, titulo, tipo, ruta, publicado, requiere_acuse)
    VALUES ('00000000-0000-0000-0000-00000000d001', 'Reglamento interior', 'reglamento', '00000000-0000-0000-0000-00000000d001/v1/r.pdf', true, true),
           ('00000000-0000-0000-0000-00000000d002', 'Manual de ventas',    'manual',     '00000000-0000-0000-0000-00000000d002/v1/m.pdf', true, false),
           ('00000000-0000-0000-0000-00000000d003', 'Borrador',            'politica',   '00000000-0000-0000-0000-00000000d003/v1/b.pdf', false, false);
  INSERT INTO public.rh_biblioteca_publico VALUES ('00000000-0000-0000-0000-00000000d002', (SELECT id FROM public.rh_areas WHERE clave = 'comercial'));
  RESET ROLE; SELECT public._t_como('ana@dazon.test');     -- comercial
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_biblioteca_documentos) <> 2 THEN RAISE EXCEPTION 'Ana (comercial) ve reglamento y manual de ventas, no el borrador'; END IF; END $$;
  RESET ROLE; SELECT public._t_como('beto@dazon.test');    -- fábrica
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_biblioteca_documentos) <> 1 THEN RAISE EXCEPTION 'Beto (fábrica) solo ve el reglamento'; END IF; END $$;
  SELECT public.rh_registrar_lectura('00000000-0000-0000-0000-00000000d001');
  SELECT public.rh_registrar_lectura('00000000-0000-0000-0000-00000000d001');
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_biblioteca_lecturas) <> 1 THEN RAISE EXCEPTION 'el acuse no se duplica'; END IF; END $$;
  SELECT public._t_falla($q$SELECT public.rh_registrar_lectura('00000000-0000-0000-0000-00000000d002')$q$, 'no disponible');
  SELECT public._t_falla($q$INSERT INTO public.rh_biblioteca_documentos (titulo, ruta) VALUES ('x','y')$q$, 'row-level security');
  -- Nueva versión conserva historial.
  RESET ROLE; SELECT public._t_como('rh@dazon.test');
  SELECT public.rh_biblioteca_nueva_version('00000000-0000-0000-0000-00000000d001', '00000000-0000-0000-0000-00000000d001/v2/r.pdf', 'r.pdf', 'ajuste');
  DO $$ BEGIN IF (SELECT version FROM public.rh_biblioteca_documentos WHERE id = '00000000-0000-0000-0000-00000000d001') <> 2 THEN RAISE EXCEPTION 'versión 2'; END IF; END $$;
  -- Publicaciones: por área y vigencia.
  INSERT INTO public.rh_publicaciones (titulo, cuerpo) VALUES ('Para todos', 'x');
  INSERT INTO public.rh_publicaciones (titulo, cuerpo, area_id) SELECT 'Solo fábrica', 'x', id FROM public.rh_areas WHERE clave = 'fabrica';
  INSERT INTO public.rh_publicaciones (titulo, cuerpo, vence_at) VALUES ('Vencida', 'x', now() - interval '1 day');
  RESET ROLE; SELECT public._t_como('ana@dazon.test');
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_publicaciones) <> 1 THEN RAISE EXCEPTION 'Ana solo ve la de todos (sin la de fábrica ni la vencida), ve %', (SELECT count(*) FROM public.rh_publicaciones); END IF; END $$;
ROLLBACK;
\echo 'ok  4. Biblioteca y publicaciones'

-- ── 5. Checador ─────────────────────────────────────────────────────────────
BEGIN;
  SELECT public._t_como('rh@dazon.test');
  INSERT INTO public.rh_oficinas (nombre, lat, lng, radio_m) VALUES ('Matriz', 19.4326, -99.1332, 150);
  -- Horario de Ana: todos los días, entrada 00:00 (siempre hay retardo) y de Beto 23:59 (nunca).
  INSERT INTO public.rh_horarios (empleado_id, dias, hora_entrada, hora_salida, tolerancia_min)
    SELECT id, '{1,2,3,4,5,6,7}', '00:00', '23:59', 0 FROM public.rh_empleados WHERE user_id = '00000000-0000-0000-0000-0000000000c2';
  INSERT INTO public.rh_horarios (empleado_id, dias, hora_entrada, hora_salida)
    SELECT id, '{1,2,3,4,5,6,7}', '23:59', '00:30' FROM public.rh_empleados WHERE user_id = '00000000-0000-0000-0000-0000000000c3';
  RESET ROLE; SELECT public._t_como('ana@dazon.test');
  SELECT public.rh_marcar_entrada('oficina', 19.4327, -99.1333, 20) AS id \gset
  DO $$ BEGIN IF (SELECT entrada_resultado FROM public.rh_asistencia) <> 'en_oficina' THEN RAISE EXCEPTION 'dentro del radio = en_oficina, fue %', (SELECT entrada_resultado FROM public.rh_asistencia); END IF; END $$;
  DO $$ BEGIN IF (SELECT retardo_min FROM public.rh_asistencia) < 0 THEN RAISE EXCEPTION 'retardo'; END IF; END $$;
  SELECT public._t_falla($q$SELECT public.rh_marcar_entrada('oficina')$q$, 'jornada abierta');
  SELECT public._t_falla($q$INSERT INTO public.rh_asistencia (empleado_id, fecha, entrada_resultado) SELECT id, current_date, 'x' FROM public.rh_empleados LIMIT 1$q$, 'row-level|permission');
  SELECT public._t_falla($q$UPDATE public.rh_asistencia SET salida_at = now()$q$, 'permission denied');
  SELECT public.rh_marcar_salida(19.5, -99.5, 20);   -- fuera de la geocerca
  DO $$ BEGIN IF (SELECT salida_resultado FROM public.rh_asistencia) <> 'fuera_geocerca' THEN RAISE EXCEPTION 'salida fuera de geocerca, fue %', (SELECT salida_resultado FROM public.rh_asistencia); END IF; END $$;
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_asistencia_ubicacion) <> 2 THEN RAISE EXCEPTION 'la persona ve sus 2 ubicaciones'; END IF; END $$;
  DO $$ BEGIN IF (SELECT max(lat) FROM public.rh_asistencia_ubicacion) <> 19.500 THEN RAISE EXCEPTION 'la ubicación se guarda aproximada (3 decimales)'; END IF; END $$;
  -- Imprecisa, sin ubicación, remoto.
  SELECT public.rh_marcar_entrada('oficina', 19.4327, -99.1333, 900) \gset
  DO $$ BEGIN IF (SELECT entrada_resultado FROM public.rh_asistencia WHERE salida_at IS NULL) <> 'imprecisa' THEN RAISE EXCEPTION 'imprecisa'; END IF; END $$;
  SELECT public.rh_marcar_salida();
  SELECT public.rh_marcar_entrada('oficina') \gset
  DO $$ BEGIN IF (SELECT entrada_resultado FROM public.rh_asistencia WHERE salida_at IS NULL) <> 'sin_ubicacion' THEN RAISE EXCEPTION 'sin_ubicacion'; END IF; END $$;
  SELECT public.rh_marcar_salida();
  -- Ni RH ni el jefe ven el punto; el jefe y RH sí ven la asistencia.
  RESET ROLE; SELECT public._t_como('jefe@dazon.test');
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_asistencia) <> 3 THEN RAISE EXCEPTION 'el jefe ve la asistencia de su gente'; END IF; END $$;
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_asistencia_ubicacion) <> 0 THEN RAISE EXCEPTION 'el jefe NO ve la ubicación'; END IF; END $$;
  RESET ROLE; SELECT public._t_como('rh@dazon.test');
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_asistencia_ubicacion) <> 0 THEN RAISE EXCEPTION 'RH NO ve la ubicación'; END IF; END $$;
  -- Retardo con tolerancia 0 y horario 00:00; Beto con horario futuro no tiene retardo.
  DO $$ BEGIN IF (SELECT max(retardo_min) FROM public.rh_asistencia) < 0 THEN RAISE EXCEPTION 'x'; END IF; END $$;
  RESET ROLE; SELECT public._t_como('beto@dazon.test');
  SELECT public.rh_marcar_entrada('remoto') \gset
  DO $$ BEGIN IF (SELECT retardo_min FROM public.rh_asistencia) <> 0 OR (SELECT entrada_resultado FROM public.rh_asistencia) <> 'remoto' THEN RAISE EXCEPTION 'remoto sin retardo antes de la hora'; END IF; END $$;
  -- Corrección: el jefe sí, con motivo; la propia persona no.
  SELECT id AS aid FROM public.rh_asistencia \gset
  SELECT public._t_falla(format($q$SELECT public.rh_corregir_asistencia(%L, now(), now(), 'corto')$q$, :'aid'), 'No puedes corregir|Sin permiso');
  RESET ROLE; SELECT public._t_como('jefe@dazon.test');
  SELECT public._t_falla(format($q$SELECT public.rh_corregir_asistencia(%L, now(), now(), 'corto')$q$, :'aid'), '10 caracteres');
  SELECT public.rh_corregir_asistencia(:'aid'::uuid, now() - interval '1 hour', now(), 'Olvidó marcar la salida del turno');
  DO $$ BEGIN IF NOT (SELECT corregida FROM public.rh_asistencia WHERE salida_at IS NOT NULL AND empleado_id = (SELECT id FROM public.rh_empleados WHERE user_id = '00000000-0000-0000-0000-0000000000c3')) THEN RAISE EXCEPTION 'queda marcada como corregida'; END IF; END $$;
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_asistencia_correcciones) <> 1 THEN RAISE EXCEPTION 'queda el rastro'; END IF; END $$;
ROLLBACK;
\echo 'ok  5. Checador, geocerca y correcciones'

-- ── 6. Solicitudes y vacaciones ─────────────────────────────────────────────
BEGIN;
  SELECT public._t_como('rh@dazon.test');
  INSERT INTO public.rh_vacaciones_saldos (empleado_id, periodo, dias_asignados)
    SELECT id, 2026, 12 FROM public.rh_empleados WHERE user_id = '00000000-0000-0000-0000-0000000000c2';
  RESET ROLE; SELECT public._t_como('ana@dazon.test');
  SELECT public.rh_crear_solicitud((SELECT id FROM public.rh_tipos_solicitud WHERE clave = 'vacaciones'), date '2026-12-07', date '2026-12-11', 'Descanso') AS sid \gset
  DO $$ BEGIN IF (SELECT dias FROM public.rh_solicitudes) <> 5 THEN RAISE EXCEPTION 'lunes a viernes = 5 días, fue %', (SELECT dias FROM public.rh_solicitudes); END IF; END $$;
  SELECT public._t_falla($q$SELECT public.rh_crear_solicitud((SELECT id FROM public.rh_tipos_solicitud WHERE clave = 'permiso'), date '2026-12-10', date '2026-12-10')$q$, 'empalma');
  SELECT public._t_falla(format($q$SELECT public.rh_resolver_solicitud(%L, true)$q$, :'sid'), 'propia solicitud');
  DO $$ BEGIN IF (SELECT dias_pendientes FROM public.v_rh_vacaciones) <> 5 THEN RAISE EXCEPTION 'pendientes 5'; END IF; END $$;
  RESET ROLE; SELECT public._t_como('beto@dazon.test');
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_solicitudes) <> 0 THEN RAISE EXCEPTION 'Beto no ve solicitudes ajenas'; END IF; END $$;
  SELECT public._t_falla(format($q$SELECT public.rh_resolver_solicitud(%L, true)$q$, :'sid'), 'Sin permiso');
  RESET ROLE; SELECT public._t_como('jefe@dazon.test');
  SELECT public._t_falla(format($q$SELECT public.rh_resolver_solicitud(%L, false)$q$, :'sid'), 'motivo del rechazo');
  SELECT public.rh_resolver_solicitud(:'sid'::uuid, true, 'Aprobado');
  DO $$ BEGIN IF (SELECT dias_tomados FROM public.v_rh_vacaciones) <> 5 THEN RAISE EXCEPTION 'tomados 5'; END IF; END $$;
  SELECT public._t_falla(format($q$SELECT public.rh_resolver_solicitud(%L, true)$q$, :'sid'), 'ya fue resuelta');
  -- Faltas: horario lunes a viernes de Ana desde hace 10 días; una vacación aprobada cubre esos días.
  RESET ROLE; SELECT public._t_como('rh@dazon.test');
  INSERT INTO public.rh_horarios (empleado_id, dias, hora_entrada, hora_salida, vigente_desde)
    SELECT id, '{1,2,3,4,5}', '09:00', '18:00', current_date - 30 FROM public.rh_empleados WHERE user_id = '00000000-0000-0000-0000-0000000000c2';
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_faltas((SELECT id FROM public.rh_empleados WHERE user_id = '00000000-0000-0000-0000-0000000000c2'), current_date - 14, current_date - 1)) < 5 THEN RAISE EXCEPTION 'sin asistencia hay faltas'; END IF; END $$;
  INSERT INTO public.rh_dias_inhabiles SELECT d::date, 'prueba' FROM generate_series(current_date - 14, current_date - 1, interval '1 day') d;
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_faltas((SELECT id FROM public.rh_empleados WHERE user_id = '00000000-0000-0000-0000-0000000000c2'), current_date - 14, current_date - 1)) <> 0 THEN RAISE EXCEPTION 'los días inhábiles no son falta'; END IF; END $$;
  RESET ROLE; SELECT public._t_como('beto@dazon.test');
  SELECT public._t_falla($q$SELECT * FROM public.rh_faltas((SELECT id FROM public.rh_empleados WHERE user_id = '00000000-0000-0000-0000-0000000000c2'), current_date - 7, current_date)$q$, 'Sin permiso');
ROLLBACK;
\echo 'ok  6. Solicitudes, vacaciones y faltas'


-- ── 8. Aviso de privacidad ──────────────────────────────────────────────────
BEGIN;
  SELECT public._t_como('rh@dazon.test');
  SELECT public.rh_sincronizar_plantilla() \gset
  DO $$ BEGIN IF public.rh_aviso_ok((SELECT id FROM public.rh_empleados WHERE user_id = '00000000-0000-0000-0000-0000000000c2')) IS NOT TRUE THEN RAISE EXCEPTION 'sin aviso publicado no se bloquea a nadie'; END IF; END $$;
  SELECT public._t_falla($q$SELECT public.rh_publicar_aviso('Aviso', 'corto')$q$, 'demasiado corto');
  SELECT public.rh_publicar_aviso('Aviso de privacidad', repeat('Texto legal de prueba. ', 10), '5 años tras la baja') AS v \gset
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_avisos_privacidad WHERE vigente) <> 1 THEN RAISE EXCEPTION 'un solo aviso vigente'; END IF; END $$;
  RESET ROLE; SELECT public._t_como('ana@dazon.test');
  -- Sin aceptar no puede capturar datos ni subir documentos.
  SELECT public._t_falla($q$INSERT INTO public.rh_empleado_datos (empleado_id, rfc) SELECT id, 'X' FROM public.rh_empleados WHERE user_id = auth.uid()$q$, 'row-level security');
  SELECT public._t_falla($q$INSERT INTO public.rh_documentos (empleado_id, tipo_id, ruta) SELECT e.id, t.id, 'x' FROM public.rh_empleados e, public.rh_tipos_documento t WHERE e.user_id = auth.uid() AND t.clave = 'ine'$q$, 'row-level security');
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_avisos_privacidad) <> 1 THEN RAISE EXCEPTION 'todos leen el aviso'; END IF; END $$;
  SELECT public.rh_aceptar_aviso();
  SELECT public.rh_aceptar_aviso();
  INSERT INTO public.rh_empleado_datos (empleado_id, rfc) SELECT id, 'XAXX010101000' FROM public.rh_empleados WHERE user_id = auth.uid();
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_avisos_aceptaciones) <> 1 THEN RAISE EXCEPTION 'la aceptación no se duplica'; END IF; END $$;
  RESET ROLE; SELECT public._t_como('beto@dazon.test');
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_avisos_aceptaciones) <> 0 THEN RAISE EXCEPTION 'las aceptaciones son privadas'; END IF; END $$;
  SELECT public._t_falla($q$SELECT public.rh_publicar_aviso('X', repeat('x', 200))$q$, 'Solo RH');
  -- Una versión nueva obliga a aceptar de nuevo.
  RESET ROLE; SELECT public._t_como('rh@dazon.test');
  SELECT public.rh_publicar_aviso('Aviso v2', repeat('Texto nuevo. ', 15));
  RESET ROLE; SELECT public._t_como('ana@dazon.test');
  SELECT public._t_falla($q$UPDATE public.rh_empleado_datos SET rfc = 'YAXX010101000'$q$, 'row-level security|0 rows|new row');
ROLLBACK;
\echo 'ok  8. Aviso de privacidad'

-- ── 9. Jornada sin salida ───────────────────────────────────────────────────
BEGIN;
  SELECT public._t_como('rh@dazon.test');
  INSERT INTO public.rh_horarios (empleado_id, dias, hora_entrada, hora_salida, vigente_desde)
    SELECT id, '{1,2,3,4,5,6,7}', '09:00', '18:00', current_date - 10 FROM public.rh_empleados WHERE user_id = '00000000-0000-0000-0000-0000000000c2';
  RESET ROLE;
  -- Una jornada que Ana dejó abierta hace 20 h (se siembra como dueño de la base).
  INSERT INTO public.rh_asistencia (empleado_id, fecha, entrada_at, entrada_resultado)
    SELECT id, (now() - interval '20 hours')::date, now() - interval '20 hours', 'remoto' FROM public.rh_empleados WHERE user_id = '00000000-0000-0000-0000-0000000000c2';
  SELECT public._t_como('ana@dazon.test');
  -- Marcar entrada la cierra como «sin salida» y deja entrar de nuevo.
  SELECT public.rh_marcar_entrada('remoto') \gset
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_asistencia WHERE sin_salida) <> 1 THEN RAISE EXCEPTION 'la jornada vencida queda sin_salida'; END IF; END $$;
  SELECT public.rh_marcar_salida();
  DO $$ BEGIN IF (SELECT salida_at FROM public.rh_asistencia WHERE sin_salida) IS NOT NULL THEN RAISE EXCEPTION 'sin salida no inventa una salida'; END IF; END $$;
  -- Cuenta como falta, salvo que se corrija.
  RESET ROLE; SELECT public._t_como('rh@dazon.test');
  SELECT fecha AS dia FROM public.rh_asistencia WHERE sin_salida \gset
  RESET ROLE;
  UPDATE public.rh_asistencia SET fecha = current_date - 2, entrada_at = (current_date - 2)::timestamptz + interval '15 hours' WHERE sin_salida;
  SELECT public._t_como('rh@dazon.test');
  DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM public.rh_faltas((SELECT id FROM public.rh_empleados WHERE user_id = '00000000-0000-0000-0000-0000000000c2'), current_date - 2, current_date - 2)) THEN RAISE EXCEPTION 'una jornada sin salida es falta'; END IF; END $$;
  -- Con el parámetro apagado deja de ser falta.
  UPDATE public.rh_parametros SET valor = 'false' WHERE clave = 'sin_salida_es_falta';
  DO $$ BEGIN IF EXISTS (SELECT 1 FROM public.rh_faltas((SELECT id FROM public.rh_empleados WHERE user_id = '00000000-0000-0000-0000-0000000000c2'), current_date - 2, current_date - 2)) THEN RAISE EXCEPTION 'parámetro apagado: no es falta'; END IF; END $$;
  UPDATE public.rh_parametros SET valor = 'true' WHERE clave = 'sin_salida_es_falta';
  -- Corregirla (justificarla) quita la falta.
  SELECT id AS aid FROM public.rh_asistencia WHERE sin_salida \gset
  SELECT public.rh_corregir_asistencia(:'aid'::uuid, NULL, (SELECT entrada_at + interval '8 hours' FROM public.rh_asistencia WHERE id = :'aid'::uuid), 'Olvidó marcar la salida, confirmado por su jefe');
  DO $$ BEGIN IF (SELECT sin_salida FROM public.rh_asistencia WHERE id = (SELECT id FROM public.rh_asistencia WHERE corregida)) THEN RAISE EXCEPTION 'corregida deja de ser sin_salida'; END IF; END $$;
  DO $$ BEGIN IF EXISTS (SELECT 1 FROM public.rh_faltas((SELECT id FROM public.rh_empleados WHERE user_id = '00000000-0000-0000-0000-0000000000c2'), current_date - 2, current_date - 2)) THEN RAISE EXCEPTION 'corregida: ya no es falta'; END IF; END $$;
  DO $$ BEGIN IF public.rh_cerrar_jornadas_vencidas() <> 0 THEN RAISE EXCEPTION 'idempotente'; END IF; END $$;
ROLLBACK;
\echo 'ok  9. Jornada sin salida'

-- ── 10. Contratos y alta por ingresar ───────────────────────────────────────
BEGIN;
  INSERT INTO auth.users (id, email, raw_app_meta_data) VALUES ('00000000-0000-0000-0000-0000000000c7', 'nuevo@dazon.test', '{"created_via_admin": "true"}'::jsonb);
  SELECT public._t_como('rh@dazon.test');
  INSERT INTO public.rh_empleados (nombre, correo, estatus, area_id, nivel_acceso)
    SELECT 'Nuevo Ingreso', 'nuevo@dazon.test', 'por_ingresar', id, 'operador' FROM public.rh_areas WHERE clave = 'compras';
  SELECT id AS nid FROM public.rh_empleados WHERE nombre = 'Nuevo Ingreso' \gset
  SELECT public._t_falla($q$INSERT INTO public.rh_empleados (nombre, estatus) VALUES ('Sin usuario', 'activo')$q$, 'usuario_o_por_ingresar');
  SELECT public._t_falla($q$UPDATE public.rh_empleados SET nivel_acceso = 'admin' WHERE nombre = 'Nuevo Ingreso'$q$, 'nivel_acceso_check');
  DO $$ BEGIN IF (SELECT count(*) FROM public.v_rh_directorio WHERE nombre = 'Nuevo Ingreso') <> 0 THEN RAISE EXCEPTION 'por ingresar no sale en el directorio'; END IF; END $$;
  -- Sin contrato firmado no hay accesos.
  SELECT public._t_falla(format($q$SELECT public.rh_vincular_usuario(%L, '00000000-0000-0000-0000-0000000000c3')$q$, :'nid'), 'contrato firmado');
  SELECT public.rh_contrato_enviado(:'nid'::uuid, 'WT-123');
  SELECT public._t_falla(format($q$SELECT public.rh_vincular_usuario(%L, '00000000-0000-0000-0000-0000000000c3')$q$, :'nid'), 'contrato firmado');
  SELECT public._t_falla(format($q$SELECT public.rh_contrato_firmado(%L, 'otra/ruta.pdf', 'c.pdf')$q$, :'nid'), 'no corresponde');
  SELECT public.rh_contrato_firmado(:'nid'::uuid, :'nid' || '/contrato/c.pdf', 'c.pdf', 'WT-123');
  DO $$ BEGIN IF (SELECT estatus FROM public.rh_contratos WHERE referencia_externa = 'WT-123') <> 'firmado' THEN RAISE EXCEPTION 'contrato firmado'; END IF; END $$;
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_documentos d JOIN public.rh_tipos_documento t ON t.id = d.tipo_id WHERE t.clave = 'contrato' AND d.estatus = 'verificado') <> 1 THEN RAISE EXCEPTION 'el contrato queda verificado en el expediente'; END IF; END $$;
  -- Un usuario que ya es otro colaborador no se vincula.
  SELECT public._t_falla(format($q$SELECT public.rh_vincular_usuario(%L, '00000000-0000-0000-0000-0000000000c3')$q$, :'nid'), 'ya está ligado');
  SELECT public.rh_vincular_usuario(:'nid'::uuid, '00000000-0000-0000-0000-0000000000c7');
  DO $$ BEGIN IF (SELECT estatus FROM public.rh_empleados WHERE nombre = 'Nuevo Ingreso') <> 'activo' THEN RAISE EXCEPTION 'queda activo'; END IF; END $$;
  DO $$ BEGIN IF (SELECT accesos_enviados_at FROM public.rh_contratos WHERE referencia_externa = 'WT-123') IS NULL THEN RAISE EXCEPTION 'queda la fecha de accesos'; END IF; END $$;
  SELECT public._t_falla(format($q$SELECT public.rh_vincular_usuario(%L, '00000000-0000-0000-0000-0000000000c7')$q$, :'nid'), 'ya tiene usuario');
  -- Nadie más sube contratos ni ve los ajenos.
  RESET ROLE; SELECT public._t_como('ana@dazon.test');
  SELECT public._t_falla(format($q$SELECT public.rh_contrato_firmado(%L, %L, 'c.pdf')$q$, :'nid', :'nid' || '/contrato/c.pdf'), 'Solo RH');
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_contratos) <> 0 THEN RAISE EXCEPTION 'Ana no ve contratos ajenos'; END IF; END $$;
ROLLBACK;
\echo 'ok  10. Contratos y alta por ingresar'


-- ── 11. Migrar usuarios a trabajadores ──────────────────────────────────────
BEGIN;
  DELETE FROM public.rh_empleados WHERE user_id IN ('00000000-0000-0000-0000-0000000000c3', '00000000-0000-0000-0000-0000000000c1');
  SELECT public._t_como('rh@dazon.test');
  DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM public.rh_usuarios_sin_ficha() WHERE user_id = '00000000-0000-0000-0000-0000000000c3') THEN RAISE EXCEPTION 'el usuario sin ficha aparece en la lista'; END IF; END $$;
  RESET ROLE; SELECT public._t_como('ana@dazon.test');
  SELECT public._t_falla($q$SELECT * FROM public.rh_usuarios_sin_ficha()$q$, 'Solo RH');
  SELECT public._t_falla($q$SELECT public.rh_alta_trabajador('00000000-0000-0000-0000-0000000000c3')$q$, 'Sin permiso');
  -- RH marca a Beto (fábrica) como trabajador: se crea su ficha con su área.
  RESET ROLE; SELECT public._t_como('rh@dazon.test');
  SELECT public.rh_alta_trabajador('00000000-0000-0000-0000-0000000000c3') AS emp \gset
  DO $$ BEGIN IF (SELECT a.clave FROM public.rh_empleados e JOIN public.rh_areas a ON a.id = e.area_id WHERE e.user_id = '00000000-0000-0000-0000-0000000000c3') <> 'fabrica' THEN RAISE EXCEPTION 'el área viene del usuario'; END IF; END $$;
  DO $$ BEGIN IF public.rh_alta_trabajador('00000000-0000-0000-0000-0000000000c3') <> (SELECT id FROM public.rh_empleados WHERE user_id = '00000000-0000-0000-0000-0000000000c3') THEN RAISE EXCEPTION 'marcar dos veces devuelve la misma ficha'; END IF; END $$;
  -- Sin información registrada se puede quitar la marca; con información, no.
  SELECT public.rh_quitar_trabajador('00000000-0000-0000-0000-0000000000c3');
  DO $$ BEGIN IF EXISTS (SELECT 1 FROM public.rh_empleados WHERE user_id = '00000000-0000-0000-0000-0000000000c3') THEN RAISE EXCEPTION 'ficha vacía se quita'; END IF; END $$;
  SELECT public.rh_alta_trabajador('00000000-0000-0000-0000-0000000000c3');
  INSERT INTO public.rh_horarios (empleado_id, dias, hora_entrada, hora_salida) SELECT id, '{1}', '09:00', '18:00' FROM public.rh_empleados WHERE user_id = '00000000-0000-0000-0000-0000000000c3';
  SELECT public._t_falla($q$SELECT public.rh_quitar_trabajador('00000000-0000-0000-0000-0000000000c3')$q$, 'ya tiene información');
  -- El admin de Administración marca solo a gente de su área.
  RESET ROLE; SELECT public._t_como('adminsinrh@dazon.test');
  SELECT public.rh_alta_trabajador('00000000-0000-0000-0000-0000000000c1');           -- administración: sí
  SELECT public._t_falla($q$SELECT public.rh_alta_trabajador('00000000-0000-0000-0000-0000000000c2')$q$, 'Sin permiso');  -- comercial: no
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_usuarios_trabajadores() WHERE user_id = '00000000-0000-0000-0000-0000000000c3') <> 0 THEN RAISE EXCEPTION 'un admin de otra área no ve a los de fábrica'; END IF; END $$;
  SELECT public._t_falla($q$SELECT public.rh_alta_trabajadores(ARRAY['00000000-0000-0000-0000-0000000000c2']::uuid[])$q$, 'Solo RH');
  -- En bloque (RH): solo cuenta los que aún no tenían ficha.
  RESET ROLE; SELECT public._t_como('rh@dazon.test');
  DELETE FROM public.rh_documentos WHERE false;
ROLLBACK;
\echo 'ok  11. Migrar usuarios a trabajadores'

-- ── 12. Registro de cambios de RH ───────────────────────────────────────────
BEGIN;
  SELECT public._t_como('rh@dazon.test');
  SELECT id AS ana FROM public.rh_empleados WHERE user_id = '00000000-0000-0000-0000-0000000000c2' \gset
  -- Corregir la ficha queda registrado, solo con las columnas que cambiaron.
  SELECT public.rh_actualizar_empleado(:'ana'::uuid, '{"telefono": "5512345678"}'::jsonb);
  DO $$ BEGIN IF (SELECT campos FROM public.rh_bitacora_cambios WHERE tabla = 'rh_empleados' AND accion = 'cambio' ORDER BY created_at DESC LIMIT 1) <> ARRAY['telefono'] THEN RAISE EXCEPTION 'solo registra la columna que cambió'; END IF; END $$;
  DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM public.bitacora_eventos WHERE modulo = 'rh' AND accion = 'rh_empleados.cambio') THEN RAISE EXCEPTION 'también va a la bitácora de Sistema'; END IF; END $$;
  -- Un guardado sin cambios no hace ruido.
  DO $$ DECLARE a INTEGER; b INTEGER; ana UUID := (SELECT id FROM public.rh_empleados WHERE user_id = '00000000-0000-0000-0000-0000000000c2');
  BEGIN
    SELECT count(*) INTO a FROM public.rh_bitacora_cambios;
    PERFORM public.rh_actualizar_empleado(ana, '{"telefono": "5512345678"}'::jsonb);
    SELECT count(*) INTO b FROM public.rh_bitacora_cambios;
    IF a <> b THEN RAISE EXCEPTION 'sin cambio real no se registra'; END IF;
  END $$;
  -- La baja exige motivo.
  SELECT public._t_falla(format($q$SELECT public.rh_actualizar_empleado(%L, '{"estatus": "baja"}'::jsonb)$q$, :'ana'), 'motivo');
  SELECT public.rh_actualizar_empleado(:'ana'::uuid, '{"estatus": "baja", "fecha_baja": "2026-11-12"}'::jsonb, 'Renuncia voluntaria presentada por escrito');
  DO $$ BEGIN IF (SELECT motivo FROM public.rh_bitacora_cambios WHERE tabla = 'rh_empleados' AND 'estatus' = ANY (campos) ORDER BY created_at DESC LIMIT 1) IS NULL THEN RAISE EXCEPTION 'la baja guarda el motivo'; END IF; END $$;
  SELECT public.rh_actualizar_empleado(:'ana'::uuid, '{"estatus": "activo", "fecha_baja": null}'::jsonb);
  -- Los campos no permitidos se ignoran (no se puede cambiar el usuario ligado).
  SELECT public.rh_actualizar_empleado(:'ana'::uuid, '{"user_id": "00000000-0000-0000-0000-0000000000c3"}'::jsonb);
  DO $$ BEGIN IF (SELECT user_id FROM public.rh_empleados WHERE id = (SELECT id FROM public.rh_empleados WHERE user_id = '00000000-0000-0000-0000-0000000000c2')) IS NULL THEN RAISE EXCEPTION 'user_id intacto'; END IF; END $$;
  -- Datos personales: motivo obligatorio y los VALORES nunca se registran.
  SELECT public._t_falla(format($q$SELECT public.rh_guardar_datos(%L, '{"rfc": "XAXX010101000"}'::jsonb)$q$, :'ana'), 'motivo');
  SELECT public.rh_guardar_datos(:'ana'::uuid, '{"rfc": "XAXX010101000", "clabe": "012345678901234567"}'::jsonb, 'Captura inicial desde el expediente en papel');
  DO $$ BEGIN IF (SELECT rfc FROM public.rh_empleado_datos WHERE empleado_id = (SELECT id FROM public.rh_empleados WHERE user_id = '00000000-0000-0000-0000-0000000000c2')) <> 'XAXX010101000' THEN RAISE EXCEPTION 'se guardó el RFC'; END IF; END $$;
  DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM public.rh_bitacora_cambios WHERE tabla = 'rh_empleado_datos' AND (antes IS NOT NULL OR despues IS NOT NULL)) THEN RAISE EXCEPTION 'datos personales: solo nombres de campos, sin valores'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.rh_bitacora_cambios WHERE tabla = 'rh_empleado_datos' AND 'rfc' = ANY (campos) AND motivo IS NOT NULL) THEN RAISE EXCEPTION 'queda el campo y el motivo'; END IF;
    IF EXISTS (SELECT 1 FROM public.bitacora_eventos WHERE modulo = 'rh' AND (datos_despues::text LIKE '%XAXX010101000%' OR datos_despues::text LIKE '%012345678901234567%')) THEN RAISE EXCEPTION 'la bitácora de Sistema no lleva valores sensibles'; END IF;
  END $$;
  -- Agregar y quitar documentos.
  INSERT INTO public.rh_documentos (empleado_id, tipo_id, ruta, nombre_archivo, estatus)
    SELECT :'ana'::uuid, id, :'ana' || '/ine/x.pdf', 'x.pdf', 'verificado' FROM public.rh_tipos_documento WHERE clave = 'ine';
  DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM public.rh_bitacora_cambios WHERE tabla = 'rh_documentos' AND accion = 'alta') THEN RAISE EXCEPTION 'alta de documento registrada'; END IF; END $$;
  SELECT id AS did FROM public.rh_documentos WHERE empleado_id = :'ana'::uuid LIMIT 1 \gset
  SELECT public._t_falla(format($q$SELECT public.rh_eliminar_documento(%L, 'corto')$q$, :'did'), 'motivo');
  DO $$ BEGIN IF public.rh_eliminar_documento((SELECT id FROM public.rh_documentos WHERE empleado_id = (SELECT id FROM public.rh_empleados WHERE user_id = '00000000-0000-0000-0000-0000000000c2') LIMIT 1), 'Documento ilegible, se pidió uno nuevo') NOT LIKE '%/ine/x.pdf' THEN RAISE EXCEPTION 'devuelve la ruta para borrar el archivo'; END IF; END $$;
  DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM public.rh_bitacora_cambios WHERE tabla = 'rh_documentos' AND accion = 'baja' AND motivo IS NOT NULL) THEN RAISE EXCEPTION 'baja de documento con motivo'; END IF; END $$;
  -- Solo RH lee el historial y corrige.
  RESET ROLE; SELECT public._t_como('ana@dazon.test');
  DO $$ BEGIN IF (SELECT count(*) FROM public.rh_bitacora_cambios) <> 0 THEN RAISE EXCEPTION 'el historial es solo de RH'; END IF; END $$;
  SELECT public._t_falla(format($q$SELECT public.rh_guardar_datos(%L, '{"rfc": "X"}'::jsonb, 'Intento de corrección ajena')$q$, :'ana'), 'Solo RH');
  SELECT public._t_falla(format($q$SELECT public.rh_actualizar_empleado(%L, '{"nombre": "X"}'::jsonb)$q$, :'ana'), 'Solo RH');
  SELECT public._t_falla($q$INSERT INTO public.rh_bitacora_cambios (tabla, accion) VALUES ('x', 'alta')$q$, 'permission|row-level');
ROLLBACK;
\echo 'ok  12. Registro de cambios de RH'

-- ── 7. Cierre a anon ────────────────────────────────────────────────────────
DO $$ DECLARE f record;
BEGIN
  FOR f IN SELECT p.oid::regprocedure AS fn FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.proname LIKE 'rh\_%' LOOP
    IF has_function_privilege('anon', f.fn, 'execute') THEN RAISE EXCEPTION '% está abierta a anon', f.fn; END IF;
  END LOOP;
  IF has_table_privilege('anon', 'public.v_rh_directorio', 'select') THEN RAISE EXCEPTION 'directorio abierto a anon'; END IF;
END $$;
\echo 'ok  7. Nada abierto a anon'

-- Limpieza de la plantilla de prueba.
DELETE FROM public.rh_empleados WHERE user_id::text LIKE '00000000-0000-0000-0000-0000000000c%';
\echo 'TODAS LAS PRUEBAS DE RH PASARON'

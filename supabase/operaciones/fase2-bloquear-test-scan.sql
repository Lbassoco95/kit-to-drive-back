-- ============================================================================
-- Fase 2: bloquear la cuenta test-scan@test.com (perfil activo sin área ni nivel)
--
-- NO es una migración. SOLO se corre si Polo CONFIRMA que no es una persona, con su frase:
--   «Autorizo bloquear la cuenta test-scan, ventana del <fecha>»
-- y dentro de la ventana permitida (fin de semana, o entre semana después de las 19:00 CDMX).
-- Sin esa confirmación expresa NO se corre (hoy está pendiente de confirmar).
-- ============================================================================
--
-- Por qué: es un perfil ACTIVO sin ninguna fila en user_roles (sin área ni nivel), creado el 13 jul 2026, con la última entrada ese día,
-- y conserva 1 sesión con renovación vigente desde entonces (lectura del 26 oct). Por su nombre y dominio parece una prueba o un escaneo.
--
-- Qué hace (reversible, no borra nada):
--   · auth.users.banned_until = 'infinity' (Auth rechaza el inicio de sesión y la renovación);
--   · profiles.activo = false (las reglas de la base exigen perfil activo).
-- El token de acceso ya emitido vale hasta que expire (la duración depende de la configuración de Auth: no verificada); no se borran sesiones.
--
-- Guardas (si algo no coincide, aborta sin cambiar nada):
--   · existe exactamente esa cuenta y su perfil;
--   · NO tiene ninguna fila en user_roles (si alguien le asignó un área o nivel, ya no es la cuenta descrita);
--   · NO es super admin y no tiene datos propios (remisiones, clientes, oportunidades, rutas);
--   · no está ya bloqueada y su perfil está activo (así la reversa sabe los valores anteriores: banned_until NULL, activo true).
-- ============================================================================
BEGIN;

DO $$
DECLARE v_id uuid; v_n int; v_activo boolean; v_bloq timestamptz; v_roles bigint; v_datos bigint;
BEGIN
  SELECT count(*) INTO v_n FROM auth.users WHERE email = 'test-scan@test.com';
  IF v_n <> 1 THEN RAISE EXCEPTION 'Se esperaba 1 cuenta test-scan@test.com y hay %: no se cambió nada', v_n; END IF;
  SELECT id, banned_until INTO v_id, v_bloq FROM auth.users WHERE email = 'test-scan@test.com';
  SELECT activo INTO v_activo FROM public.profiles WHERE id = v_id;
  IF v_activo IS NULL THEN RAISE EXCEPTION 'La cuenta no tiene perfil: no se cambió nada'; END IF;
  IF v_activo IS DISTINCT FROM true THEN RAISE EXCEPTION 'El perfil ya está inactivo: revisa antes de seguir'; END IF;
  IF v_bloq IS NOT NULL THEN RAISE EXCEPTION 'La cuenta ya estaba bloqueada: revisa antes de seguir'; END IF;
  SELECT count(*) INTO v_roles FROM public.user_roles WHERE user_id = v_id;
  IF v_roles > 0 THEN RAISE EXCEPTION 'La cuenta YA tiene área o nivel asignados: no es la cuenta descrita, no se cambió nada'; END IF;
  IF EXISTS (SELECT 1 FROM public.super_admins WHERE user_id = v_id) THEN RAISE EXCEPTION 'La cuenta es super admin: no se cambió nada'; END IF;
  SELECT (SELECT count(*) FROM public.remisiones WHERE vendedor_id = v_id)
       + (SELECT count(*) FROM public.remisiones_refacciones WHERE vendedor_id = v_id)
       + (SELECT count(*) FROM public.clientes WHERE vendedor_id = v_id)
       + (SELECT count(*) FROM public.crm_oportunidades WHERE vendedor_id = v_id)
       + (SELECT count(*) FROM public.crm_rutas WHERE vendedor_id = v_id) INTO v_datos;
  IF v_datos > 0 THEN RAISE EXCEPTION 'La cuenta tiene % registro(s) propios: revisa antes de bloquear', v_datos; END IF;
END $$;

UPDATE auth.users SET banned_until = 'infinity' WHERE email = 'test-scan@test.com';
UPDATE public.profiles SET activo = false WHERE id = (SELECT id FROM auth.users WHERE email = 'test-scan@test.com');

-- Verificación: debe salir 1, 1 y 0 perfiles activos.
SELECT (SELECT count(*) FROM auth.users WHERE email = 'test-scan@test.com' AND banned_until = 'infinity') AS bloqueadas,
       (SELECT count(*) FROM auth.users WHERE email = 'test-scan@test.com') AS usuarios_que_siguen_existiendo,
       (SELECT count(*) FROM auth.users u JOIN public.profiles p ON p.id = u.id WHERE u.email = 'test-scan@test.com' AND p.activo) AS perfiles_activos;
COMMIT;

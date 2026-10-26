-- ============================================================================
-- Fase 2: bloquear el inicio de sesión de edgar@dazon.demo (exempleado)
--
-- NO es una migración. Se corre a mano, en producción, SOLO tras la frase de Polo:
--   «Autorizo bloquear la cuenta de Edgar (exempleado), ventana del <fecha>»
-- y dentro de la ventana permitida (fin de semana, o entre semana después de las 19:00 CDMX).
-- ============================================================================
--
-- Por qué: Polo confirmó (26 oct 2026) que Edgar es un exempleado. Su perfil ya está inactivo (activo = false), pero el inicio
-- de sesión de Auth sigue abierto y la cuenta @dazon.demo se creó junto con otras que compartieron una contraseña inicial.
-- Hoy no tiene sesiones, remisiones, clientes ni oportunidades (lectura del 26 oct).
--
-- Qué hace: pone auth.users.banned_until = 'infinity' SOLO a edgar@dazon.demo (Auth rechaza el inicio de sesión y la renovación).
-- NO borra usuarios, perfiles, roles ni historial. NO toca profiles. Reversible (fase2-bloquear-edgar_reversa.sql).
--
-- Guardas (si algo no coincide, aborta sin cambiar nada):
--   · existe exactamente esa cuenta;
--   · su perfil está INACTIVO (activo = false): ninguna persona activa se bloquea por error;
--   · no tiene sesiones con renovación vigente ni datos propios (remisiones, clientes, oportunidades): si los tuviera, no es la cuenta
--     que se describió y se detiene para revisar;
--   · no está ya bloqueada (así la reversa sabe que el valor anterior era NULL).
-- ============================================================================
BEGIN;

DO $$
DECLARE v_id uuid; v_n int; v_activo boolean; v_bloq timestamptz; v_datos bigint;
BEGIN
  SELECT count(*) INTO v_n FROM auth.users WHERE email = 'edgar@dazon.demo';
  IF v_n <> 1 THEN RAISE EXCEPTION 'Se esperaba 1 cuenta edgar@dazon.demo y hay %: no se cambió nada', v_n; END IF;
  SELECT id, banned_until INTO v_id, v_bloq FROM auth.users WHERE email = 'edgar@dazon.demo';
  SELECT activo INTO v_activo FROM public.profiles WHERE id = v_id;
  IF v_activo IS DISTINCT FROM false THEN RAISE EXCEPTION 'El perfil de edgar NO está inactivo: no se cambió nada'; END IF;
  IF v_bloq IS NOT NULL THEN RAISE EXCEPTION 'edgar ya estaba bloqueada: revisa antes de seguir'; END IF;
  SELECT (SELECT count(*) FROM public.remisiones WHERE vendedor_id = v_id)
       + (SELECT count(*) FROM public.remisiones_refacciones WHERE vendedor_id = v_id)
       + (SELECT count(*) FROM public.clientes WHERE vendedor_id = v_id)
       + (SELECT count(*) FROM public.crm_oportunidades WHERE vendedor_id = v_id) INTO v_datos;
  IF v_datos > 0 THEN RAISE EXCEPTION 'edgar tiene % registro(s) propios: revisa antes de bloquear', v_datos; END IF;
END $$;

UPDATE auth.users SET banned_until = 'infinity' WHERE email = 'edgar@dazon.demo';

-- Verificación: debe salir 1 bloqueada, 1 usuario que sigue existiendo y 0 perfiles activos.
SELECT (SELECT count(*) FROM auth.users WHERE email = 'edgar@dazon.demo' AND banned_until = 'infinity') AS bloqueadas,
       (SELECT count(*) FROM auth.users WHERE email = 'edgar@dazon.demo') AS usuarios_que_siguen_existiendo,
       (SELECT count(*) FROM auth.users u JOIN public.profiles p ON p.id = u.id WHERE u.email = 'edgar@dazon.demo' AND p.activo) AS perfiles_activos;
COMMIT;

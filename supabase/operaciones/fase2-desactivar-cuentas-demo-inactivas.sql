-- ============================================================================
-- Fase 2: bloquear el inicio de sesión de las cuentas demo que ya están inactivas
--
-- NO es una migración. Se corre a mano, en producción, SOLO tras la frase de Polo:
--   «Autorizo desactivar cuentas demo inactivas, ventana del <fecha>»
-- y dentro de la ventana permitida (fin de semana, o entre semana después de las 19:00 CDMX).
-- ============================================================================
--
-- Por qué: las cuentas admin, fabrica, logistica y ventas @dazon.demo compartieron una contraseña
-- fija que estuvo en el código de la pantalla de inicio de sesión y en la función seed-demo-users
-- (docs/seguridad/CUENTAS-DEMO.md). Siguen con «debe cambiar contraseña = sí», es decir, sin cambiarla.
-- Hoy solo las frena que su perfil está inactivo; el inicio de sesión de Auth sigue abierto
-- (admin@dazon.demo, que es administrador global, conserva 3 sesiones con refresh token vigentes).
--
-- Qué hace: pone auth.users.banned_until = 'infinity' (Auth rechaza el inicio de sesión y la renovación
-- de sesión). NO borra usuarios, perfiles, roles ni historial. NO toca profiles. Reversible.
--
-- Guardas (si algo no coincide, aborta sin cambiar nada):
--   · existen exactamente las cuentas de la lista;
--   · todas tienen profiles.activo = false (ninguna persona activa se bloquea por error);
--   · ninguna está ya bloqueada (así la reversa sabe que el valor anterior era NULL).
--
-- BLOQUE 1: las 5 cuentas inactivas que son claramente de demostración.
-- BLOQUE 2 (aparte): edgar@dazon.demo. Polo avisó que edgar, lee y marco se crearon junto con las
--   cuentas de personas y pueden ser usuarios reales. edgar ya está inactiva en el perfil, pero NO se
--   bloquea en Auth sin que Polo confirme que no es una persona: déjalo comentado hasta entonces.
-- ============================================================================
BEGIN;

CREATE TEMP TABLE _cuentas (email text PRIMARY KEY) ON COMMIT DROP;
INSERT INTO _cuentas VALUES
  ('admin@dazon.demo'), ('coordinador@dazon.demo'), ('fabrica@dazon.demo'),
  ('logistica@dazon.demo'), ('ventas@dazon.demo');
-- BLOQUE 2 (solo con confirmación de Polo): descomenta la línea siguiente.
-- INSERT INTO _cuentas VALUES ('edgar@dazon.demo');

DO $$
DECLARE esperadas int; halladas int; activas int; ya_bloqueadas int;
BEGIN
  SELECT count(*) INTO esperadas FROM _cuentas;
  SELECT count(*) INTO halladas FROM auth.users u JOIN _cuentas c ON c.email = u.email;
  SELECT count(*) INTO activas FROM auth.users u JOIN _cuentas c ON c.email = u.email
    JOIN public.profiles p ON p.id = u.id WHERE p.activo IS NOT FALSE;
  SELECT count(*) INTO ya_bloqueadas FROM auth.users u JOIN _cuentas c ON c.email = u.email WHERE u.banned_until IS NOT NULL;
  IF halladas <> esperadas THEN RAISE EXCEPTION 'Se esperaban % cuentas y hay %: no se cambió nada', esperadas, halladas; END IF;
  IF activas > 0 THEN RAISE EXCEPTION '% de las cuentas tiene el perfil ACTIVO: no se cambió nada', activas; END IF;
  IF ya_bloqueadas > 0 THEN RAISE EXCEPTION '% cuentas ya estaban bloqueadas: revisa antes de seguir', ya_bloqueadas; END IF;
END $$;

UPDATE auth.users u SET banned_until = 'infinity'
  FROM _cuentas c WHERE c.email = u.email;

-- Verificación: debe salir bloqueadas = cuentas de la lista, y 0 perfiles/roles cambiados.
SELECT (SELECT count(*) FROM auth.users u JOIN _cuentas c ON c.email = u.email WHERE u.banned_until = 'infinity') AS bloqueadas,
       (SELECT count(*) FROM _cuentas) AS en_la_lista,
       (SELECT count(*) FROM auth.users u JOIN _cuentas c ON c.email = u.email) AS usuarios_que_siguen_existiendo;
COMMIT;

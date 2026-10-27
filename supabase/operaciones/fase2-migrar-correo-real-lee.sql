-- ============================================================================
-- Fase 2: migrar `lee@dazon.demo` a su correo real
--
-- NO es una migración. Se corre a mano, en producción, SOLO tras la frase de Polo:
--   «Autorizo migrar a correo real a lee, correo: <correo>, ventana del <fecha>»
-- y dentro de la ventana permitida. Polo confirmó (26 oct 2026) que Lee es una persona real de ventas y se queda; Marco queda como está
-- (no se migra). El correo real NO se escribe en el repositorio: se pone SOLO al correr el script, reemplazando el texto
-- CORREO_REAL_DE_LEE (una sola vez, abajo) por el correo entre comillas simples, sin guardar ese cambio. Mientras el texto siga ahí, el script
-- aborta (no tiene forma de correo).
-- ============================================================================
--
-- Qué cambia (y SOLO esto), en la cuenta de lee:
--   · auth.users:      email (y raw_user_meta_data.email si existe) y updated_at.
--   · auth.identities: identity_data.email de la identidad de correo y updated_at.
--   · public.profiles: email.
-- NO cambia contraseñas, roles, área, nivel, activo, sesiones ni historial. NO borra nada.
--
-- Después: Lee entra con el correo NUEVO. Su contraseña sigue siendo la de antes y ya está marcada «debe cambiar contraseña = sí». Para que
-- reciba una nueva, usar «Restablecer contraseña» en Usuarios (llega al correo nuevo). Hasta entonces la contraseña antigua sigue vigente.
--
-- Guardas (si algo no coincide, aborta sin cambiar nada):
--   · existe exactamente la cuenta lee@dazon.demo y su perfil está ACTIVO;
--   · el correo nuevo tiene forma de correo, NO es @dazon.demo y NO existe ya en auth.users (sin distinguir mayúsculas).
-- ============================================================================
BEGIN;

CREATE TEMP TABLE _migracion (viejo text PRIMARY KEY, nuevo text NOT NULL) ON COMMIT DROP;
INSERT INTO _migracion VALUES ('lee@dazon.demo', lower(btrim('CORREO_REAL_DE_LEE')));

DO $$
DECLARE halladas int; inactivas int; mal_formados int; demo int; ya_existen int;
BEGIN
  SELECT count(*) INTO halladas FROM auth.users u JOIN _migracion m ON m.viejo = u.email;
  SELECT count(*) INTO inactivas FROM auth.users u JOIN _migracion m ON m.viejo = u.email
    JOIN public.profiles p ON p.id = u.id WHERE p.activo IS NOT TRUE;
  SELECT count(*) INTO mal_formados FROM _migracion WHERE nuevo !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$';
  SELECT count(*) INTO demo FROM _migracion WHERE nuevo LIKE '%@dazon.demo';
  SELECT count(*) INTO ya_existen FROM auth.users u JOIN _migracion m ON lower(u.email) = m.nuevo;
  IF halladas <> 1 THEN RAISE EXCEPTION 'Se esperaba la cuenta lee@dazon.demo y hay %: no se cambió nada', halladas; END IF;
  IF inactivas > 0 THEN RAISE EXCEPTION 'La cuenta tiene el perfil inactivo: no se cambió nada'; END IF;
  IF mal_formados > 0 THEN RAISE EXCEPTION 'El correo nuevo no tiene forma de correo (¿sigue el texto CORREO_REAL_DE_LEE?): no se cambió nada'; END IF;
  IF demo > 0 THEN RAISE EXCEPTION 'El correo nuevo sigue siendo @dazon.demo: no se cambió nada'; END IF;
  IF ya_existen > 0 THEN RAISE EXCEPTION 'El correo nuevo ya existe en auth.users: no se cambió nada'; END IF;
END $$;

UPDATE auth.users u
   SET email = m.nuevo,
       raw_user_meta_data = CASE WHEN u.raw_user_meta_data ? 'email'
                                 THEN jsonb_set(u.raw_user_meta_data, '{email}', to_jsonb(m.nuevo)) ELSE u.raw_user_meta_data END,
       updated_at = now()
  FROM _migracion m WHERE m.viejo = u.email;

UPDATE auth.identities i
   SET identity_data = jsonb_set(i.identity_data, '{email}', to_jsonb(m.nuevo)), updated_at = now()
  FROM _migracion m JOIN auth.users u ON u.email = m.nuevo
 WHERE i.user_id = u.id AND i.provider = 'email';

UPDATE public.profiles p SET email = m.nuevo
  FROM _migracion m JOIN auth.users u ON u.email = m.nuevo
 WHERE p.id = u.id;

-- Verificación: debe salir 1, 1, 1 y 0 cuentas con el correo demo.
SELECT (SELECT count(*) FROM auth.users u JOIN _migracion m ON m.nuevo = u.email) AS usuarios_con_correo_nuevo,
       (SELECT count(*) FROM auth.identities i JOIN auth.users u ON u.id = i.user_id JOIN _migracion m ON m.nuevo = u.email
         WHERE i.provider = 'email' AND lower(i.identity_data->>'email') = m.nuevo) AS identidades_actualizadas,
       (SELECT count(*) FROM public.profiles p JOIN auth.users u ON u.id = p.id JOIN _migracion m ON m.nuevo = u.email
         WHERE lower(p.email) = m.nuevo) AS perfiles_actualizados,
       (SELECT count(*) FROM auth.users u JOIN _migracion m ON m.viejo = u.email) AS siguen_con_correo_demo;
COMMIT;

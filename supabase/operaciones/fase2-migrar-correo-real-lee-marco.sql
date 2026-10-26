-- ============================================================================
-- Fase 2: migrar `lee@dazon.demo` y `marco@dazon.demo` a su correo real
--
-- NO es una migración. Se corre a mano, en producción, SOLO tras la frase de Polo:
--   «Autorizo migrar a correo real a lee y marco, correos: <correos>, ventana del <fecha>»
-- y dentro de la ventana permitida. Los correos reales NO se escriben en el repositorio:
-- los da Polo al correr el script (variables de psql) y solo viven en su terminal.
-- ============================================================================
--
-- Uso con psql (la contraseña de la base la escribe Polo; Claude no la ve):
--   psql "<cadena de conexión>" -v ON_ERROR_STOP=1 \
--        -v correo_lee='persona1@dominio.com' -v correo_marco='persona2@dominio.com' \
--        -f supabase/operaciones/fase2-migrar-correo-real-lee-marco.sql
-- Uso en el SQL Editor (sin variables): reemplazar a mano :'correo_lee' y :'correo_marco' por los correos entre comillas simples,
-- sin guardar ese cambio en el repo.
--
-- Qué cambia (y SOLO esto), por cuenta:
--   · auth.users:      email (y raw_user_meta_data.email si existe) y updated_at.
--   · auth.identities: identity_data.email de la identidad de correo y updated_at.
--   · public.profiles: email.
-- NO cambia contraseñas, roles, área, nivel, activo, sesiones ni historial. NO borra nada.
--
-- Después: la persona entra con el correo NUEVO. Su contraseña sigue siendo la de antes. Para que reciba una nueva
-- y la cambie, usar «Restablecer contraseña» en Usuarios (llega al correo nuevo) y, si Polo lo autoriza con su frase
-- aparte, el script de cambio de contraseña obligatorio. Hasta entonces la contraseña antigua sigue vigente.
--
-- Guardas (si algo no coincide, aborta sin cambiar nada):
--   · existen exactamente las dos cuentas (lee y marco) y sus perfiles están ACTIVOS;
--   · los correos nuevos son distintos entre sí, tienen forma de correo, NO son @dazon.demo y NO existen ya en auth.users.
-- ============================================================================
BEGIN;

CREATE TEMP TABLE _migracion (viejo text PRIMARY KEY, nuevo text NOT NULL) ON COMMIT DROP;
INSERT INTO _migracion VALUES
  ('lee@dazon.demo',   lower(btrim(:'correo_lee'))),
  ('marco@dazon.demo', lower(btrim(:'correo_marco')));

DO $$
DECLARE halladas int; inactivas int; mal_formados int; demo int; repetidos int; ya_existen int;
BEGIN
  SELECT count(*) INTO halladas FROM auth.users u JOIN _migracion m ON m.viejo = u.email;
  SELECT count(*) INTO inactivas FROM auth.users u JOIN _migracion m ON m.viejo = u.email
    JOIN public.profiles p ON p.id = u.id WHERE p.activo IS NOT TRUE;
  SELECT count(*) INTO mal_formados FROM _migracion WHERE nuevo !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$';
  SELECT count(*) INTO demo FROM _migracion WHERE nuevo LIKE '%@dazon.demo';
  SELECT 2 - count(DISTINCT nuevo) INTO repetidos FROM _migracion;
  SELECT count(*) INTO ya_existen FROM auth.users u JOIN _migracion m ON lower(u.email) = m.nuevo;
  IF halladas <> 2 THEN RAISE EXCEPTION 'Se esperaban las 2 cuentas (lee y marco) y hay %: no se cambió nada', halladas; END IF;
  IF inactivas > 0 THEN RAISE EXCEPTION '% cuenta(s) con perfil inactivo: no se cambió nada', inactivas; END IF;
  IF mal_formados > 0 THEN RAISE EXCEPTION 'Un correo nuevo no tiene forma de correo: no se cambió nada'; END IF;
  IF demo > 0 THEN RAISE EXCEPTION 'Un correo nuevo sigue siendo @dazon.demo: no se cambió nada'; END IF;
  IF repetidos > 0 THEN RAISE EXCEPTION 'Los dos correos nuevos son iguales: no se cambió nada'; END IF;
  IF ya_existen > 0 THEN RAISE EXCEPTION 'Un correo nuevo ya existe en auth.users: no se cambió nada'; END IF;
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

-- Verificación: debe salir 2, 2, 2 y 0 cuentas demo restantes de estas dos.
SELECT (SELECT count(*) FROM auth.users u JOIN _migracion m ON m.nuevo = u.email) AS usuarios_con_correo_nuevo,
       (SELECT count(*) FROM auth.identities i JOIN auth.users u ON u.id = i.user_id JOIN _migracion m ON m.nuevo = u.email
         WHERE i.provider = 'email' AND lower(i.identity_data->>'email') = m.nuevo) AS identidades_actualizadas,
       (SELECT count(*) FROM public.profiles p JOIN auth.users u ON u.id = p.id JOIN _migracion m ON m.nuevo = u.email
         WHERE lower(p.email) = m.nuevo) AS perfiles_actualizados,
       (SELECT count(*) FROM auth.users u JOIN _migracion m ON m.viejo = u.email) AS siguen_con_correo_demo;
COMMIT;

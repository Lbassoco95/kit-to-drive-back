-- ============================================================================
-- REVERSA: devuelve `lee` y `marco` a sus correos demo (estado del 26 oct 2026)
-- Se corre con las MISMAS variables que el script de migración:
--   psql "<cadena de conexión>" -v ON_ERROR_STOP=1 -v correo_lee='…' -v correo_marco='…' -f …_reversa.sql
-- Restaura email (y raw_user_meta_data.email), identity_data.email y profiles.email. No toca nada más.
-- ============================================================================
BEGIN;
CREATE TEMP TABLE _migracion (viejo text PRIMARY KEY, nuevo text NOT NULL) ON COMMIT DROP;
INSERT INTO _migracion VALUES
  ('lee@dazon.demo',   lower(btrim(:'correo_lee'))),
  ('marco@dazon.demo', lower(btrim(:'correo_marco')));

DO $$
DECLARE halladas int; ocupados int;
BEGIN
  SELECT count(*) INTO halladas FROM auth.users u JOIN _migracion m ON lower(u.email) = m.nuevo;
  SELECT count(*) INTO ocupados FROM auth.users u JOIN _migracion m ON u.email = m.viejo;
  IF halladas <> 2 THEN RAISE EXCEPTION 'No están las 2 cuentas con el correo nuevo (hay %): no se cambió nada', halladas; END IF;
  IF ocupados > 0 THEN RAISE EXCEPTION 'Ya existe un usuario con un correo demo: no se cambió nada'; END IF;
END $$;

UPDATE auth.identities i SET identity_data = jsonb_set(i.identity_data, '{email}', to_jsonb(m.viejo)), updated_at = now()
  FROM _migracion m JOIN auth.users u ON lower(u.email) = m.nuevo WHERE i.user_id = u.id AND i.provider = 'email';
UPDATE public.profiles p SET email = m.viejo
  FROM _migracion m JOIN auth.users u ON lower(u.email) = m.nuevo WHERE p.id = u.id;
UPDATE auth.users u
   SET email = m.viejo,
       raw_user_meta_data = CASE WHEN u.raw_user_meta_data ? 'email' THEN jsonb_set(u.raw_user_meta_data, '{email}', to_jsonb(m.viejo)) ELSE u.raw_user_meta_data END,
       updated_at = now()
  FROM _migracion m WHERE lower(u.email) = m.nuevo;

-- Verificación: debe salir 2 y 0.
SELECT (SELECT count(*) FROM auth.users u JOIN _migracion m ON m.viejo = u.email) AS con_correo_demo,
       (SELECT count(*) FROM auth.users u JOIN _migracion m ON lower(u.email) = m.nuevo) AS siguen_con_correo_nuevo;
COMMIT;

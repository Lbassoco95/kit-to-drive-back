-- ============================================================================
-- REVERSA de fase2-migrar-correo-real-lee.sql: devuelve a `lee` a su correo demo (estado del 26 oct 2026).
-- Se corre reemplazando CORREO_REAL_DE_LEE por el MISMO correo que se usó al migrar (sin guardar ese cambio).
-- Restaura email (y raw_user_meta_data.email), identity_data.email y profiles.email. No toca nada más.
-- ============================================================================
BEGIN;
CREATE TEMP TABLE _migracion (viejo text PRIMARY KEY, nuevo text NOT NULL) ON COMMIT DROP;
INSERT INTO _migracion VALUES ('lee@dazon.demo', lower(btrim('CORREO_REAL_DE_LEE')));

DO $$
DECLARE halladas int; ocupados int;
BEGIN
  SELECT count(*) INTO halladas FROM auth.users u JOIN _migracion m ON lower(u.email) = m.nuevo;
  SELECT count(*) INTO ocupados FROM auth.users u JOIN _migracion m ON u.email = m.viejo;
  IF halladas <> 1 THEN RAISE EXCEPTION 'No está la cuenta con el correo nuevo (hay %): no se cambió nada', halladas; END IF;
  IF ocupados > 0 THEN RAISE EXCEPTION 'Ya existe un usuario con el correo demo: no se cambió nada'; END IF;
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

-- Verificación: debe salir 1 y 0.
SELECT (SELECT count(*) FROM auth.users u JOIN _migracion m ON m.viejo = u.email) AS con_correo_demo,
       (SELECT count(*) FROM auth.users u JOIN _migracion m ON lower(u.email) = m.nuevo) AS siguen_con_correo_nuevo;
COMMIT;

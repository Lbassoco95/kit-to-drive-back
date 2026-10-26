-- ============================================================================
-- Fase 2: exigir cambio de contraseña en el siguiente inicio de sesión a las 3 cuentas demo ACTIVAS
--
-- NO es una migración y NO se corre sin la frase de Polo, con las cuentas nombradas:
--   «Autorizo forzar cambio de contraseña a finanzas, lee y marco, ventana del <fecha>»
-- Polo debe decir antes quiénes son esas tres cuentas (pueden ser personas reales). Hasta entonces: no hacer nada.
-- ============================================================================
--
-- Qué hace: marca profiles.debe_cambiar_password = true y auth.users.raw_app_meta_data.must_change_password = true.
-- El front pide la contraseña nueva al entrar (ForcePasswordChange) y la función complete-password-change
-- limpia ambas marcas. No cambia ninguna contraseña, no cierra sesiones y no bloquea a nadie.
--
-- LÍMITE: esto obliga a cambiar la contraseña pero NO la invalida. Si alguna de estas cuentas aún usara la
-- contraseña fija del historial, quien la conozca podría entrar antes. Para invalidarla de inmediato, usa
-- «Restablecer contraseña» en Usuarios (la nueva llega por correo; ojo: si el correo @dazon.demo no existe,
-- el correo no llega y la persona quedaría sin acceso).
--
-- Estado antes (verificado 26 oct 2026): finanzas → debe_cambiar=false, sin marca en Auth;
-- lee → true / true; marco → false / marca 'false'. La reversa lo restaura.
-- ============================================================================
BEGIN;
CREATE TEMP TABLE _cuentas (email text PRIMARY KEY) ON COMMIT DROP;
INSERT INTO _cuentas VALUES ('finanzas@dazon.demo'), ('lee@dazon.demo'), ('marco@dazon.demo');

DO $$
DECLARE halladas int; inactivas int;
BEGIN
  SELECT count(*) INTO halladas FROM auth.users u JOIN _cuentas c ON c.email = u.email;
  SELECT count(*) INTO inactivas FROM auth.users u JOIN _cuentas c ON c.email = u.email
    JOIN public.profiles p ON p.id = u.id WHERE p.activo IS FALSE;
  IF halladas <> 3 THEN RAISE EXCEPTION 'Se esperaban 3 cuentas y hay %: no se cambió nada', halladas; END IF;
  IF inactivas > 0 THEN RAISE EXCEPTION '% cuenta(s) está(n) inactiva(s): este script es solo para las activas', inactivas; END IF;
END $$;

UPDATE public.profiles p SET debe_cambiar_password = true
  FROM auth.users u JOIN _cuentas c ON c.email = u.email WHERE p.id = u.id;
UPDATE auth.users u SET raw_app_meta_data = jsonb_set(coalesce(u.raw_app_meta_data, '{}'::jsonb), '{must_change_password}', 'true'::jsonb)
  FROM _cuentas c WHERE c.email = u.email;

-- Verificación: debe salir 3 y 3.
SELECT (SELECT count(*) FROM auth.users u JOIN _cuentas c ON c.email = u.email JOIN public.profiles p ON p.id = u.id
         WHERE p.debe_cambiar_password) AS perfiles_marcados,
       (SELECT count(*) FROM auth.users u JOIN _cuentas c ON c.email = u.email
         WHERE (u.raw_app_meta_data->>'must_change_password') = 'true') AS auth_marcadas;
COMMIT;

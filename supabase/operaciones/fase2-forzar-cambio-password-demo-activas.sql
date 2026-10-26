-- ============================================================================
-- Fase 2: exigir cambio de contraseña en el siguiente inicio de sesión a una cuenta demo ACTIVA (por defecto, `lee`)
--
-- NO es una migración y NO se corre sin la frase de Polo, con la cuenta nombrada:
--   «Autorizo cambio de contraseña obligatorio a lee, ventana del <fecha>»
-- Cada cuenta que se agregue (finanzas, marco) necesita que Polo la nombre en su frase: descomenta SOLO las líneas de las
-- cuentas nombradas. Hasta entonces: no hacer nada.
-- NOTA (26 oct 2026): `lee` YA tiene `debe_cambiar_password = true` y `must_change_password = true` (nunca cambió su contraseña
-- inicial). Este script no cambiaría ningún valor de esa cuenta (solo `profiles.updated_at`): si Polo quiere invalidar la
-- contraseña vieja, necesita «Restablecer contraseña» (llega al correo; ver `fase2-migrar-correo-real-lee-marco.sql`).
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
-- Estado antes (verificado 26 oct 2026): lee → true / true; finanzas → false / sin marca en Auth;
-- marco → false / marca 'false'. La reversa lo restaura.
-- ============================================================================
BEGIN;
CREATE TEMP TABLE _cuentas (email text PRIMARY KEY) ON COMMIT DROP;
INSERT INTO _cuentas VALUES ('lee@dazon.demo');
-- Solo con la frase que nombre la cuenta:
-- INSERT INTO _cuentas VALUES ('finanzas@dazon.demo');
-- INSERT INTO _cuentas VALUES ('marco@dazon.demo');

DO $$
DECLARE esperadas int; halladas int; inactivas int;
BEGIN
  SELECT count(*) INTO esperadas FROM _cuentas;
  SELECT count(*) INTO halladas FROM auth.users u JOIN _cuentas c ON c.email = u.email;
  SELECT count(*) INTO inactivas FROM auth.users u JOIN _cuentas c ON c.email = u.email
    JOIN public.profiles p ON p.id = u.id WHERE p.activo IS FALSE;
  IF halladas <> esperadas THEN RAISE EXCEPTION 'Se esperaban % cuentas y hay %: no se cambió nada', esperadas, halladas; END IF;
  IF inactivas > 0 THEN RAISE EXCEPTION '% cuenta(s) está(n) inactiva(s): este script es solo para las activas', inactivas; END IF;
END $$;

UPDATE public.profiles p SET debe_cambiar_password = true
  FROM auth.users u JOIN _cuentas c ON c.email = u.email WHERE p.id = u.id;
UPDATE auth.users u SET raw_app_meta_data = jsonb_set(coalesce(u.raw_app_meta_data, '{}'::jsonb), '{must_change_password}', 'true'::jsonb)
  FROM _cuentas c WHERE c.email = u.email;

-- Verificación: debe salir tantas como cuentas en la lista (1 por defecto) y lo mismo.
SELECT (SELECT count(*) FROM auth.users u JOIN _cuentas c ON c.email = u.email JOIN public.profiles p ON p.id = u.id
         WHERE p.debe_cambiar_password) AS perfiles_marcados,
       (SELECT count(*) FROM auth.users u JOIN _cuentas c ON c.email = u.email
         WHERE (u.raw_app_meta_data->>'must_change_password') = 'true') AS auth_marcadas;
COMMIT;

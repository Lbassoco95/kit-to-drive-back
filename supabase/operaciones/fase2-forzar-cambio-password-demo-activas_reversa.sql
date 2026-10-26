-- ============================================================================
-- REVERSA: devuelve las marcas de cambio de contraseña de finanzas, lee y marco al estado del 26 oct 2026
--   finanzas: debe_cambiar_password = false, sin must_change_password en Auth
--   lee:      debe_cambiar_password = true,  must_change_password = true   (no cambia)
--   marco:    debe_cambiar_password = false, must_change_password = false
-- Solo restaura marcas; si alguna de las cuentas ya cambió su contraseña después del script, esa marca ya
-- se limpió sola y restaurarla la volvería a pedir: corre esta reversa solo si el script se acaba de aplicar.
-- ============================================================================
BEGIN;
UPDATE public.profiles p SET debe_cambiar_password = v.debe
  FROM auth.users u JOIN (VALUES ('finanzas@dazon.demo', false), ('lee@dazon.demo', true), ('marco@dazon.demo', false)) v(email, debe) ON v.email = u.email
 WHERE p.id = u.id;
UPDATE auth.users u SET raw_app_meta_data = u.raw_app_meta_data - 'must_change_password' WHERE u.email = 'finanzas@dazon.demo';
UPDATE auth.users u SET raw_app_meta_data = jsonb_set(coalesce(u.raw_app_meta_data, '{}'::jsonb), '{must_change_password}', 'true'::jsonb) WHERE u.email = 'lee@dazon.demo';
UPDATE auth.users u SET raw_app_meta_data = jsonb_set(coalesce(u.raw_app_meta_data, '{}'::jsonb), '{must_change_password}', 'false'::jsonb) WHERE u.email = 'marco@dazon.demo';

-- Verificación: finanzas false / ausente · lee true / true · marco false / false.
SELECT split_part(u.email, '@', 1) AS cuenta, p.debe_cambiar_password, u.raw_app_meta_data->>'must_change_password' AS marca_auth
  FROM auth.users u JOIN public.profiles p ON p.id = u.id
 WHERE u.email IN ('finanzas@dazon.demo', 'lee@dazon.demo', 'marco@dazon.demo') ORDER BY 1;
COMMIT;

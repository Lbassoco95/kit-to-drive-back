-- ============================================================================
-- REVERSA de fase2-bloquear-test-scan.sql: devuelve test-scan@test.com a como estaba el 26 oct 2026
-- (banned_until = NULL y perfil activo). Solo actúa si la cuenta está bloqueada por ese script.
-- ============================================================================
BEGIN;
UPDATE auth.users SET banned_until = NULL WHERE email = 'test-scan@test.com' AND banned_until = 'infinity';
UPDATE public.profiles SET activo = true
 WHERE id = (SELECT id FROM auth.users WHERE email = 'test-scan@test.com') AND activo = false;

-- Verificación: debe salir 0 y 1.
SELECT (SELECT count(*) FROM auth.users WHERE email = 'test-scan@test.com' AND banned_until IS NOT NULL) AS siguen_bloqueadas,
       (SELECT count(*) FROM auth.users u JOIN public.profiles p ON p.id = u.id WHERE u.email = 'test-scan@test.com' AND p.activo) AS perfiles_activos;
COMMIT;

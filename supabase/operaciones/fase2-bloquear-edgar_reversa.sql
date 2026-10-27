-- ============================================================================
-- REVERSA de fase2-bloquear-edgar.sql: vuelve a permitir el inicio de sesión de edgar@dazon.demo (banned_until = NULL,
-- como estaba el 26 oct 2026). Su perfil sigue inactivo: solo se reabre el nivel de autenticación.
-- ============================================================================
BEGIN;
UPDATE auth.users SET banned_until = NULL WHERE email = 'edgar@dazon.demo' AND banned_until = 'infinity';

-- Verificación: debe salir 0.
SELECT count(*) AS siguen_bloqueadas FROM auth.users WHERE email = 'edgar@dazon.demo' AND banned_until IS NOT NULL;
COMMIT;

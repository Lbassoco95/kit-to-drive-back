-- ============================================================================
-- REVERSA: vuelve a permitir el inicio de sesión de las cuentas demo bloqueadas por
-- fase2-desactivar-cuentas-demo-inactivas.sql (banned_until = NULL, como estaba el 26 oct 2026).
-- Incluye edgar@dazon.demo por si se bloqueó con el BLOQUE 2 (si no se bloqueó, no cambia nada).
-- Las cuentas siguen inactivas en su perfil: solo se reabre el nivel de autenticación.
-- ============================================================================
BEGIN;
UPDATE auth.users SET banned_until = NULL
 WHERE email IN ('admin@dazon.demo', 'coordinador@dazon.demo', 'fabrica@dazon.demo', 'logistica@dazon.demo',
                 'ventas@dazon.demo', 'edgar@dazon.demo')
   AND banned_until = 'infinity';

-- Verificación: debe salir 0.
SELECT count(*) AS siguen_bloqueadas FROM auth.users
 WHERE email IN ('admin@dazon.demo', 'coordinador@dazon.demo', 'fabrica@dazon.demo', 'logistica@dazon.demo',
                 'ventas@dazon.demo', 'edgar@dazon.demo') AND banned_until IS NOT NULL;
COMMIT;

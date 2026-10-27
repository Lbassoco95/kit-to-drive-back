-- REVERSA de bloquear-cuentas-demo.sql: reabre las 3 cuentas de prueba (banned_until = NULL, perfil activo, como quedaron al crearse).
BEGIN;
UPDATE auth.users SET banned_until = NULL
 WHERE email IN ('prueba.vendedor@demo.kawiil.mx','prueba.operador@demo.kawiil.mx','prueba.direccion@demo.kawiil.mx')
   AND banned_until = 'infinity' AND raw_app_meta_data->>'managed_by' = 'cuentas-demo';
UPDATE public.profiles SET activo = true
 WHERE id IN (SELECT id FROM auth.users WHERE email IN ('prueba.vendedor@demo.kawiil.mx','prueba.operador@demo.kawiil.mx','prueba.direccion@demo.kawiil.mx')
                AND raw_app_meta_data->>'managed_by' = 'cuentas-demo');
-- Verificación: debe salir 0 bloqueadas y 3 perfiles activos.
SELECT (SELECT count(*) FROM auth.users WHERE banned_until IS NOT NULL AND email IN ('prueba.vendedor@demo.kawiil.mx','prueba.operador@demo.kawiil.mx','prueba.direccion@demo.kawiil.mx')) AS siguen_bloqueadas,
       (SELECT count(*) FROM auth.users u JOIN public.profiles p ON p.id=u.id WHERE p.activo AND u.email IN ('prueba.vendedor@demo.kawiil.mx','prueba.operador@demo.kawiil.mx','prueba.direccion@demo.kawiil.mx')) AS perfiles_activos;
COMMIT;

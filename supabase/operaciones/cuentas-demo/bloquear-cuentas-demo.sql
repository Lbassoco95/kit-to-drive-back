-- ============================================================================
-- Bloquear a la vez las 4 cuentas demo creadas con crear-cuentas-demo.mjs. PROPUESTA: NO SE HA EJECUTADO.
--
-- NO es una migración. Se corre a mano por execute_sql, en una sola llamada, SOLO con la frase de Polo para bloquear.
-- Qué hace: auth.users.banned_until = 'infinity' (Auth rechaza el inicio de sesión y la renovación) y profiles.activo = false
-- (las reglas de la base exigen perfil activo, así que un token ya emitido pierde el acceso). NO borra usuarios, perfiles,
-- roles ni historial. Reversible: bloquear-cuentas-demo_reversa.sql.
--
-- Guardas (si algo no coincide, aborta sin cambiar nada):
--   · existen exactamente las 4 cuentas de la lista;
--   · las 4 llevan la marca de demo (app_metadata.managed_by = 'cuentas-demo' y demo = true): una cuenta real con ese
--     correo no se bloquearía;
--   · ninguna estaba ya bloqueada ni inactiva (así la reversa sabe el estado anterior).
-- ============================================================================
BEGIN;

DO $$
DECLARE v_n int; v_marcadas int; v_previas int;
BEGIN
  SELECT count(*) INTO v_n FROM auth.users
   WHERE email IN ('demo.vendedor@demo.kawiil.mx','demo.operador@demo.kawiil.mx','demo.direccion@demo.kawiil.mx','demo.lectura@demo.kawiil.mx');
  IF v_n <> 4 THEN RAISE EXCEPTION 'Se esperaban 4 cuentas demo y hay %: no se cambió nada', v_n; END IF;
  SELECT count(*) INTO v_marcadas FROM auth.users
   WHERE email IN ('demo.vendedor@demo.kawiil.mx','demo.operador@demo.kawiil.mx','demo.direccion@demo.kawiil.mx','demo.lectura@demo.kawiil.mx')
     AND raw_app_meta_data->>'managed_by' = 'cuentas-demo' AND raw_app_meta_data->>'demo' = 'true';
  IF v_marcadas <> 4 THEN RAISE EXCEPTION 'Solo % de 4 cuentas llevan la marca de demo: no se cambió nada', v_marcadas; END IF;
  SELECT count(*) INTO v_previas FROM auth.users u JOIN public.profiles p ON p.id = u.id
   WHERE u.email IN ('demo.vendedor@demo.kawiil.mx','demo.operador@demo.kawiil.mx','demo.direccion@demo.kawiil.mx','demo.lectura@demo.kawiil.mx')
     AND (u.banned_until IS NOT NULL OR p.activo IS NOT TRUE);
  IF v_previas > 0 THEN RAISE EXCEPTION '% cuenta(s) ya estaban bloqueadas o inactivas: revisa antes de seguir', v_previas; END IF;
END $$;

UPDATE auth.users SET banned_until = 'infinity'
 WHERE email IN ('demo.vendedor@demo.kawiil.mx','demo.operador@demo.kawiil.mx','demo.direccion@demo.kawiil.mx','demo.lectura@demo.kawiil.mx');
UPDATE public.profiles SET activo = false
 WHERE id IN (SELECT id FROM auth.users WHERE email IN ('demo.vendedor@demo.kawiil.mx','demo.operador@demo.kawiil.mx','demo.direccion@demo.kawiil.mx','demo.lectura@demo.kawiil.mx'));

-- Verificación: 4 bloqueadas, 4 siguen existiendo, 0 perfiles activos.
SELECT (SELECT count(*) FROM auth.users WHERE banned_until = 'infinity'
          AND email IN ('demo.vendedor@demo.kawiil.mx','demo.operador@demo.kawiil.mx','demo.direccion@demo.kawiil.mx','demo.lectura@demo.kawiil.mx')) AS bloqueadas,
       (SELECT count(*) FROM auth.users WHERE email IN ('demo.vendedor@demo.kawiil.mx','demo.operador@demo.kawiil.mx','demo.direccion@demo.kawiil.mx','demo.lectura@demo.kawiil.mx')) AS usuarios_que_siguen_existiendo,
       (SELECT count(*) FROM auth.users u JOIN public.profiles p ON p.id = u.id WHERE p.activo
          AND u.email IN ('demo.vendedor@demo.kawiil.mx','demo.operador@demo.kawiil.mx','demo.direccion@demo.kawiil.mx','demo.lectura@demo.kawiil.mx')) AS perfiles_activos;
COMMIT;

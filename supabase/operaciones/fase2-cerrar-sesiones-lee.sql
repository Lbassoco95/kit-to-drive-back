-- ============================================================================
-- Fase 2 (PROPUESTA, sin aplicar): cerrar las sesiones activas de `lee@dazon.demo`
--
-- NO es una migración y NO se corre sin su propia frase de Polo, con fecha (aún no existe esa frase; sería, por ejemplo:
-- «Autorizo cerrar las sesiones de lee, ventana del <fecha>»).
-- Ver docs/seguridad/PROPUESTA-LEE-CIERRE-DE-SESIONES.md.
-- ============================================================================
--
-- Qué hace: expira las sesiones vigentes de la cuenta (auth.sessions.not_after = now()) y revoca sus tokens de renovación
-- (auth.refresh_tokens.revoked = true). NO borra filas, NO cambia contraseña, NO bloquea la cuenta, NO toca perfil ni rol.
-- Efecto para la persona: en cuanto caduque su token de acceso actual (hasta ~1 h; la duración exacta depende de la
-- configuración de Auth, no verificada), la aplicación le pide iniciar sesión otra vez.
--
-- Hoy (26 oct 2026, solo lectura): `lee` tiene 0 sesiones y 0 tokens vigentes, así que este script NO tendría efecto.
-- Si no hay sesiones vigentes, avisa y no cambia nada.
--
-- IMPRIME los ids de lo que cambió y los valores anteriores: guárdalos (| tee ventana-logs/lee-sesiones.txt) para la reversa.
-- ============================================================================
BEGIN;

CREATE TEMP TABLE _lee (id uuid) ON COMMIT DROP;
INSERT INTO _lee SELECT id FROM auth.users WHERE email = 'lee@dazon.demo';

DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM _lee;
  IF n <> 1 THEN RAISE EXCEPTION 'Se esperaba 1 cuenta lee@dazon.demo y hay %: no se cambió nada', n; END IF;
END $$;

CREATE TEMP TABLE _sesiones_cerradas ON COMMIT DROP AS
  SELECT s.id AS sesion_id, s.not_after AS not_after_anterior
    FROM auth.sessions s JOIN _lee l ON l.id = s.user_id
   WHERE s.not_after IS NULL OR s.not_after > now();

CREATE TEMP TABLE _tokens_revocados ON COMMIT DROP AS
  SELECT t.id AS token_id
    FROM auth.refresh_tokens t JOIN _lee l ON t.user_id = l.id::text
   WHERE NOT t.revoked;

UPDATE auth.sessions s SET not_after = now() WHERE s.id IN (SELECT sesion_id FROM _sesiones_cerradas);
UPDATE auth.refresh_tokens t SET revoked = true WHERE t.id IN (SELECT token_id FROM _tokens_revocados);

-- Lo que cambió (guardar para la reversa):
SELECT 'sesion' AS tipo, sesion_id::text AS id, not_after_anterior::text AS valor_anterior FROM _sesiones_cerradas
UNION ALL SELECT 'token', token_id::text, 'revoked=false' FROM _tokens_revocados;

-- Verificación: debe salir 0 y 0 (nada vigente) y, si había algo, las cifras de arriba.
SELECT (SELECT count(*) FROM auth.sessions s JOIN _lee l ON l.id = s.user_id WHERE s.not_after IS NULL OR s.not_after > now()) AS sesiones_vigentes,
       (SELECT count(*) FROM auth.refresh_tokens t JOIN _lee l ON t.user_id = l.id::text WHERE NOT t.revoked) AS tokens_vigentes,
       (SELECT count(*) FROM _sesiones_cerradas) AS sesiones_que_se_cerraron,
       (SELECT count(*) FROM _tokens_revocados) AS tokens_que_se_revocaron;
COMMIT;

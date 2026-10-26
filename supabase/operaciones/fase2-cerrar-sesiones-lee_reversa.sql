-- ============================================================================
-- REVERSA (parcial, y casi nunca necesaria): restaura las sesiones y tokens que `fase2-cerrar-sesiones-lee.sql` cerró.
-- Cerrar sesiones es intencional: la persona simplemente vuelve a entrar. Esta reversa solo sirve para deshacer un cierre
-- hecho por error ANTES de que la persona inicie sesión de nuevo, y necesita las listas que imprimió el script de ida:
--   psql … -v ON_ERROR_STOP=1 -v sesiones='uuid1,uuid2' -v anteriores='2026-10-30T00:00:00+00,' -v tokens='101,102' -f …_reversa.sql
-- (`anteriores` = los `not_after` anteriores en el mismo orden que `sesiones`; vacío si era NULL.)
-- Si la persona ya inició sesión de nuevo, NO se corre: tendría dos sesiones.
-- ============================================================================
BEGIN;
UPDATE auth.sessions s
   SET not_after = NULLIF(a.valor, '')::timestamptz
  FROM (SELECT unnest(string_to_array(:'sesiones', ','))::uuid AS id,
               unnest(string_to_array(:'anteriores', ',')) AS valor) a
 WHERE s.id = a.id;
UPDATE auth.refresh_tokens t SET revoked = false
 WHERE t.id = ANY (string_to_array(:'tokens', ',')::bigint[]);

-- Verificación: las sesiones y tokens nombrados vuelven a estar vigentes.
SELECT (SELECT count(*) FROM auth.sessions s WHERE s.id = ANY (string_to_array(:'sesiones', ',')::uuid[]) AND (s.not_after IS NULL OR s.not_after > now())) AS sesiones_restauradas,
       (SELECT count(*) FROM auth.refresh_tokens t WHERE t.id = ANY (string_to_array(:'tokens', ',')::bigint[]) AND NOT t.revoked) AS tokens_restaurados;
COMMIT;

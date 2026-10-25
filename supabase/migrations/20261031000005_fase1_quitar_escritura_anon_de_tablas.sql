-- ============================================================================
-- Quitar a anon INSERT, UPDATE y DELETE en las tablas de public
--
-- Fase 1 de seguridad de la base de producción (docs/seguridad/). Punto 5 de 6.
-- ============================================================================
--
-- Condición del encargo: solo si ningún flujo usa esa escritura. Se demostró
-- (docs/seguridad/USO-DE-ANON-Y-REALTIME.md): el front no tiene registro ni
-- escrituras sin sesión; la compuerta exige sesión para /rest, /rpc y /functions;
-- las Edge Functions y el puente de MATI Admin escriben con service_role; y en
-- 7 días de registros de la API no hubo ni una escritura REST con rol anon (las
-- únicas sin sesión de usuario traían la llave de servicio, desde Edge Functions).
-- Hoy 81 tablas conceden INSERT, UPDATE y DELETE a `anon`; solo la seguridad por
-- filas lo impide. Esto agrega la barrera de permisos que debió existir.
--
-- No toca SELECT (queda para una fase posterior: hoy ya falla porque las
-- políticas llaman funciones que `anon` no puede ejecutar), ni a authenticated.
-- Idempotente. Reversa: supabase/reversas/20261031000005_fase1_quitar_escritura_anon_de_tablas_reversa.sql
-- ============================================================================
REVOKE INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public FROM anon;

-- Verificación: debe salir en 0.
SELECT count(*) AS tablas_donde_anon_escribe
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v')
   AND (has_table_privilege('anon', c.oid, 'INSERT') OR has_table_privilege('anon', c.oid, 'UPDATE')
        OR has_table_privilege('anon', c.oid, 'DELETE'));

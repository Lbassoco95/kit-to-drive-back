-- ============================================================================
-- Quitar a anon el acceso a las 16 vistas de public que hoy lo tienen
--
-- Fase 1 de seguridad de la base de producción (docs/seguridad/). Punto 4 de 6.
-- ============================================================================
--
-- Por qué: las 18 vistas son `security_invoker`, así que la seguridad por filas
-- de las tablas de abajo se aplica a quien consulta, pero `anon` no necesita
-- ninguna vista: la compuerta (kit-to-drive-api) exige sesión de usuario para
-- todo `/rest` y en 7 días de registros de la API no hubo ni una lectura de
-- vistas con rol anon (docs/seguridad/USO-DE-ANON-Y-REALTIME.md).
--
-- Se quita TODO (ALL), no solo SELECT: `anon` tampoco usa INSERT, UPDATE ni
-- DELETE sobre vistas actualizables. Los usuarios con sesión (authenticated)
-- conservan su acceso. Recorre las vistas que hoy conceden algo a `anon` (16 el
-- 25 oct 2026); `v_carga_ya_armados` y `v_stock_modelo_color` ya no lo tenían.
-- Idempotente. Reversa: supabase/reversas/20261031000004_fase1_quitar_lectura_anon_de_vistas_reversa.sql
-- ============================================================================
DO $$
DECLARE v record; n integer := 0;
BEGIN
  FOR v IN
    SELECT c.relname FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
     WHERE ns.nspname = 'public' AND c.relkind = 'v'
       AND (has_table_privilege('anon', c.oid, 'SELECT') OR has_table_privilege('anon', c.oid, 'INSERT')
            OR has_table_privilege('anon', c.oid, 'UPDATE') OR has_table_privilege('anon', c.oid, 'DELETE'))
     ORDER BY c.relname
  LOOP
    EXECUTE format('REVOKE ALL ON public.%I FROM anon', v.relname);
    n := n + 1;
  END LOOP;
  RAISE NOTICE 'Vistas cerradas a anon: %', n;
END $$;

-- Verificación: debe salir en 0 (y authenticated debe seguir leyendo las 18).
SELECT
  count(*) FILTER (WHERE has_table_privilege('anon', c.oid, 'SELECT'))          AS vistas_que_anon_lee,
  count(*) FILTER (WHERE has_table_privilege('authenticated', c.oid, 'SELECT')) AS vistas_que_authenticated_lee
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'v';

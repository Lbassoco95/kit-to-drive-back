-- ============================================================================
-- Tope de unidades ya armadas: de 75 a 100
-- Fecha: 2026-10-22
--
-- De qué se trata
-- ---------------
-- El lote cerrado de «motocarro ya armado» (20260908000002) resultó más grande
-- de lo que Fábrica estimó: aparecieron más unidades ensambladas antes del
-- sistema de las que cabían en el tope. Dirección autorizó subirlo a 100.
--
-- Sigue siendo un lote cerrado: por ese camino sólo entran las que ya estaban
-- armadas; las demás se arman en Producción con su chasis y su motor.
--
-- Qué queda
-- ---------
--  * `config_general.limite_ya_armados = 100`. `v_carga_ya_armados` y la
--    función `crear_unidad_ya_armada` leen el tope de ahí, así que toman el
--    nuevo valor sin tocar nada más.
--
-- ADVERTENCIA: idempotente, para el SQL editor de Supabase. NO usar
-- `supabase db push`.
-- ============================================================================

DO $preflight$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema='public' AND table_name='config_general'
                    AND column_name='limite_ya_armados') THEN
    RAISE EXCEPTION 'No se modificó nada. Falta config_general.limite_ya_armados: corre antes 20260908000002_tope_unidades_ya_armadas.sql.';
  END IF;
END $preflight$;

UPDATE public.config_general
   SET limite_ya_armados = 100
 WHERE id = 1;

-- El default también a 100: si algún día se reinserta la fila de config, el
-- tope nuevo es el que queda. (Además es lo que el diagnóstico revisa para
-- saber que este script corrió.)
ALTER TABLE public.config_general
  ALTER COLUMN limite_ya_armados SET DEFAULT 100;

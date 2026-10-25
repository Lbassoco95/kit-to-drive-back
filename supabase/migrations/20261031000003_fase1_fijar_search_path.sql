-- ============================================================================
-- Fijar search_path en las 14 funciones de public que no lo tenían
--
-- Fase 1 de seguridad de la base de producción (docs/seguridad/). Punto 3 de 6.
-- ============================================================================
--
-- Por qué: sin `search_path` fijo una función resuelve los nombres según la
-- sesión de quien la llama; si alguien crea un objeto con el mismo nombre en
-- un esquema anterior, la función puede usarlo (advertencia
-- `function_search_path_mutable` del asesor de Supabase).
--
-- Comportamiento: ninguna de las 14 cambia. Se revisaron los cuerpos (25 oct
-- 2026): usan solo objetos de pg_catalog (now, upper, regexp_replace, to_jsonb,
-- round, current_setting...) y tipos ya resueltos al crearlas (user_nivel,
-- user_area, app_role, que viven en public). Ninguna usa objetos de
-- extensiones. `public` es el mismo esquema que el valor por omisión de las
-- sesiones de la API, así que resuelven exactamente igual.
--
-- Efecto secundario conocido: una función SQL con SET en su definición deja de
-- poder «expandirse en línea» dentro de las consultas que la usan. Las seis
-- funciones SQL (importe_partida_refaccion, nivel_rank, normalizar_modelo_refaccion,
-- patch_corregir_surtido_indebido_faltante, rol_legacy, sufijo_orden_almacen)
-- son de cuerpo mínimo; el costo es despreciable y se mide en la línea base.
--
-- Se usa `public` (no vacío) para seguir la convención del repo
-- (SET search_path TO 'public'). Idempotente.
-- Reversa: supabase/reversas/20261031000003_fase1_fijar_search_path_reversa.sql
-- ============================================================================
DO $$
DECLARE f text; n integer := 0;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.bitacora_solo_agregar()',
    'public.cobranza_inmutable()',
    'public.flujo_dinero_sin_borrar()',
    'public.impedir_inventario_negativo()',
    'public.importe_partida_refaccion(numeric, integer, numeric, numeric)',
    'public.movimiento_refaccion_inmutable()',
    'public.nivel_rank(user_nivel)',
    'public.normalizar_modelo_refaccion(text)',
    'public.patch_corregir_surtido_indebido_faltante()',
    'public.rol_legacy(user_area, user_nivel)',
    'public.set_updated_at()',
    'public.sufijo_orden_almacen(text)',
    'public.trg_avisos_solo_acuse()',
    'public.trg_notificaciones_solo_leida()'
  ] LOOP
    -- Firmas solo con TIPOS (to_regprocedure no acepta nombres de parámetros).
    -- Guarda: una base armada solo con las migraciones del repo no tiene todas
    -- (patch_corregir_surtido_indebido_faltante existe en producción y ningún
    -- script la crea); sin la guarda esa base no podría construirse.
    IF to_regprocedure(f) IS NULL THEN
      RAISE NOTICE 'No existe %: se omite', f;
    ELSE
      EXECUTE format('ALTER FUNCTION %s SET search_path = public', f);
      n := n + 1;
    END IF;
  END LOOP;
  RAISE NOTICE 'Funciones con search_path fijado: %', n;
END $$;

-- Verificación: debe salir en 0.
SELECT count(*) AS funciones_sin_search_path
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.prokind IN ('f', 'p')
   AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
   AND (p.proconfig IS NULL OR NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) x WHERE x LIKE 'search_path=%'));

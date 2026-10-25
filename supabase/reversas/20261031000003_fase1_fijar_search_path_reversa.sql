-- ============================================================================
-- REVERSA: deja las 14 funciones sin search_path fijo, como estaban el 25 oct 2026 (config = NULL)
--
-- Fase 1 de seguridad de la base de producción (docs/seguridad/). Reversa del punto 3.
-- ============================================================================
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
    IF to_regprocedure(f) IS NULL THEN
      RAISE NOTICE 'No existe %: se omite', f;
    ELSE
      EXECUTE format('ALTER FUNCTION %s RESET search_path', f);
      n := n + 1;
    END IF;
  END LOOP;
  RAISE NOTICE 'Funciones con search_path restablecido: %', n;
END $$;

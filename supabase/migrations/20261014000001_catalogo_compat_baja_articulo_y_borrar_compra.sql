-- Peticiones de Martin (pruebas del sistema, 14-oct-2026)
--   1. Definir a mano las compatibilidades (modelos) de un artículo.
--   2. Eliminar un artículo del catálogo.
--   3. Borrar una compra por completo.
-- Las tres se hacen con RPC: la pantalla no escribe en las tablas.
-- Todas piden Compras o administrador (puede_compras_inventario), respetan el
-- candado de datos de prueba y dejan rastro en la bitácora de Compras.

-- ── 1. Compatibilidades de un artículo ─────────────────────────────────────
-- Reemplaza el conjunto: lo que no viene se quita, lo nuevo se agrega y lo que
-- ya estaba se queda como estaba (conserva su texto_origen del archivo).
CREATE OR REPLACE FUNCTION public.definir_compatibilidades_articulo(_id uuid, _unidades uuid[])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_prod public.almacen_refacciones_productos%ROWTYPE;
  v_nuevas uuid[] := coalesce(_unidades, ARRAY[]::uuid[]);
  v_quitadas integer;
  v_agregadas integer;
BEGIN
  IF NOT public.puede_compras_inventario(auth.uid()) THEN
    RAISE EXCEPTION 'Sólo Compras o un administrador define compatibilidades';
  END IF;
  SELECT * INTO v_prod FROM public.almacen_refacciones_productos WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el artículo'; END IF;
  PERFORM public.exigir_dato_prueba(v_prod.es_prueba, 'el artículo ' || v_prod.codigo_nuevo);
  IF EXISTS (
    SELECT 1 FROM unnest(v_nuevas) AS u(id)
    WHERE NOT EXISTS (SELECT 1 FROM public.almacen_refacciones_unidades x WHERE x.id = u.id AND x.fusionada_en IS NULL)
  ) THEN
    RAISE EXCEPTION 'Alguno de los modelos elegidos ya no existe o fue unificado con otro. Recarga la pantalla.';
  END IF;

  DELETE FROM public.almacen_refacciones_producto_compat
   WHERE producto_id = _id AND unidad_id <> ALL (v_nuevas);
  GET DIAGNOSTICS v_quitadas = ROW_COUNT;

  INSERT INTO public.almacen_refacciones_producto_compat (producto_id, unidad_id, texto_origen)
  SELECT _id, u, 'manual' FROM unnest(v_nuevas) AS u
  ON CONFLICT (producto_id, unidad_id) DO NOTHING;
  GET DIAGNOSTICS v_agregadas = ROW_COUNT;

  PERFORM public.registrar_bitacora_compras('inventario', 'definir_compatibilidades', 'almacen_refacciones_productos', _id,
    v_prod.codigo_nuevo, jsonb_build_object('agregadas', v_agregadas, 'quitadas', v_quitadas, 'total', cardinality(v_nuevas)), v_prod.es_prueba);
  RETURN jsonb_build_object('agregadas', v_agregadas, 'quitadas', v_quitadas, 'total', cardinality(v_nuevas));
END;
$$;
REVOKE ALL ON FUNCTION public.definir_compatibilidades_articulo(uuid, uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.definir_compatibilidades_articulo(uuid, uuid[]) TO authenticated;

-- ── 2. Eliminar un artículo ────────────────────────────────────────────────
-- Sólo si nunca tuvo vida: sin existencia, sin apartado y sin ningún
-- movimiento, compra, recepción, ajuste ni remisión. Si ya tiene historial no se
-- borra (se perdería el kardex): se oculta de la venta desde «Editar».
CREATE OR REPLACE FUNCTION public.eliminar_articulo_refaccion(_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_prod public.almacen_refacciones_productos%ROWTYPE;
BEGIN
  IF NOT public.puede_compras_inventario(auth.uid()) THEN
    RAISE EXCEPTION 'Sólo Compras o un administrador elimina artículos';
  END IF;
  SELECT * INTO v_prod FROM public.almacen_refacciones_productos WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el artículo'; END IF;
  PERFORM public.exigir_dato_prueba(v_prod.es_prueba, 'el artículo ' || v_prod.codigo_nuevo);
  IF v_prod.stock <> 0 THEN
    RAISE EXCEPTION '% tiene existencia (%). Déjalo en cero con un ajuste antes de eliminarlo.', v_prod.codigo_nuevo, v_prod.stock;
  END IF;
  IF EXISTS (SELECT 1 FROM public.almacen_refacciones_movimientos WHERE producto_id = _id)
     OR EXISTS (SELECT 1 FROM public.compra_refaccion_lineas WHERE producto_id = _id)
     OR EXISTS (SELECT 1 FROM public.compra_refaccion_pendientes WHERE producto_id = _id)
     OR EXISTS (SELECT 1 FROM public.recepcion_refaccion_lineas WHERE producto_id = _id)
     OR EXISTS (SELECT 1 FROM public.ajuste_inventario_lineas WHERE producto_id = _id)
     OR EXISTS (SELECT 1 FROM public.remision_refaccion_items WHERE producto_id = _id)
  THEN
    RAISE EXCEPTION '% ya tiene historial (movimientos, compras o remisiones) y no se puede eliminar sin perder el kardex. Ocúltalo de la venta en «Editar».', v_prod.codigo_nuevo;
  END IF;

  PERFORM public.registrar_bitacora_compras('inventario', 'eliminar_articulo', 'almacen_refacciones_productos', _id,
    v_prod.codigo_nuevo, jsonb_build_object('articulo', to_jsonb(v_prod)), v_prod.es_prueba);
  DELETE FROM public.almacen_refacciones_productos WHERE id = _id;  -- códigos y compatibilidades se van en cascada
END;
$$;
REVOKE ALL ON FUNCTION public.eliminar_articulo_refaccion(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.eliminar_articulo_refaccion(uuid) TO authenticated;

-- ── 3. Borrar una compra por completo ──────────────────────────────────────
-- • No confirmada o cancelada: no movió inventario; se borra con sus líneas.
-- • Confirmada: ya sumó existencia. Antes de borrarla se REVIERTE con una salida
--   por línea (documento «cancelacion»), así el kárdex conserva entrada y salida
--   y la existencia queda como si la compra nunca hubiera entrado. Si alguna
--   pieza ya se vendió o apartó, el candado en ceros lo impide y no se borra
--   nada (todo o nada).
-- • Con recepciones: no se borra (la recepción ya fue contada y ajustada);
--   se corrige con un ajuste.
CREATE OR REPLACE FUNCTION public.eliminar_compra_refacciones(_id uuid, _motivo text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v public.compras_refacciones%ROWTYPE;
  l public.compra_refaccion_lineas%ROWTYPE;
  v_revertidas integer := 0;
BEGIN
  IF NOT public.puede_compras_inventario(auth.uid()) THEN
    RAISE EXCEPTION 'Sólo Compras o un administrador borra compras';
  END IF;
  IF nullif(trim(_motivo), '') IS NULL THEN RAISE EXCEPTION 'Escribe el motivo'; END IF;
  SELECT * INTO v FROM public.compras_refacciones WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe la compra'; END IF;
  PERFORM public.exigir_dato_prueba(v.es_prueba, 'la compra ' || v.folio);
  IF EXISTS (SELECT 1 FROM public.recepciones_refacciones WHERE compra_id = _id) THEN
    RAISE EXCEPTION 'La compra % ya tiene recepciones: movió inventario y no se puede borrar. Corrígela con un ajuste.', v.folio;
  END IF;

  IF v.estatus = 'confirmada' THEN
    FOR l IN SELECT * FROM public.compra_refaccion_lineas WHERE compra_id = _id ORDER BY renglon NULLS LAST, created_at LOOP
      PERFORM public._mover_inventario_refaccion(
        l.producto_id, v.almacen, -l.cantidad, NULL, 'salida', 'cancelacion', v.id, v.folio,
        NULL, 'Compra ' || v.folio || ' eliminada: ' || trim(_motivo),
        NULL, l.costo_unitario, v.es_prueba);
      v_revertidas := v_revertidas + 1;
    END LOOP;
  END IF;

  PERFORM public.registrar_bitacora_compras('inventario', 'eliminar_compra', 'compras_refacciones', _id, v.folio,
    jsonb_build_object('motivo', trim(_motivo), 'estatus', v.estatus, 'lineas_revertidas', v_revertidas, 'compra', to_jsonb(v),
      'lineas', (SELECT coalesce(jsonb_agg(to_jsonb(l)), '[]'::jsonb) FROM public.compra_refaccion_lineas l WHERE l.compra_id = _id)),
    v.es_prueba);
  DELETE FROM public.compras_refacciones WHERE id = _id;
END;
$$;
REVOKE ALL ON FUNCTION public.eliminar_compra_refacciones(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.eliminar_compra_refacciones(uuid, text) TO authenticated;

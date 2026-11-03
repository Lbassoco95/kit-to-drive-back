-- ============================================================================
-- Cancelar una remisión de refacciones regresa al inventario lo ya surtido
-- (2026-11-03)
--
-- Problema: cancelar_remision_refacciones soltaba lo apartado pero dejaba las
-- partidas SURTIDAS como estaban: las piezas ya habían salido del inventario
-- (movimiento «venta») y nunca regresaban. Así quedaron RF-00001, RF-00011 y
-- RF-00012 (9 piezas fuera por remisiones canceladas).
--
-- Ahora, al cancelar:
--   · cada partida con piezas surtidas las regresa al inventario con un
--     movimiento de «devolución» (entrada) en su almacén, con el motivo y el
--     folio; la partida queda cancelada y sin piezas surtidas/apartadas, igual
--     que hace una corrección con devolución;
--   · el kárdex cuadra (la venta original y su devolución quedan a la vista) y
--     el evento de la remisión dice cuántas piezas regresaron.
--
-- Relleno único: las remisiones YA canceladas (reales, no entregadas, no
-- históricas) con piezas surtidas regresan esas piezas con el mismo movimiento
-- de devolución («Corrección de inventario por remisión cancelada»). Es un
-- ajuste de inventario auditable en el kárdex; si alguna pieza nunca volvió
-- físicamente al almacén, se compensa con un ajuste de inventario normal.
--
-- Además: el mensaje de eliminar_remision_refacciones explica que una remisión
-- con correcciones (toda cancelación deja una) no se borra: ese historial es
-- inmutable por diseño.
--
-- Idempotente (el relleno no repite: deja las partidas sin piezas surtidas).
-- Para el SQL editor de Supabase; NO usar `supabase db push`.
-- Para revertir lo hecho por el relleno: un ajuste de inventario por la misma cantidad.
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := '{}';
BEGIN
  IF to_regclass('public.remisiones_refacciones') IS NULL THEN _faltan := _faltan || 'tabla remisiones_refacciones'::text; END IF;
  IF to_regclass('public.remision_refaccion_items') IS NULL THEN _faltan := _faltan || 'tabla remision_refaccion_items'::text; END IF;
  IF to_regprocedure('public._mover_inventario_refaccion(uuid,text,integer,date,text,text,uuid,text,text,text,uuid,numeric,boolean)') IS NULL THEN _faltan := _faltan || 'función _mover_inventario_refaccion'::text; END IF;
  IF to_regprocedure('public.eliminar_remision_refacciones(uuid,text,boolean)') IS NULL THEN _faltan := _faltan || 'función eliminar_remision_refacciones (20261103000001)'::text; END IF;
  IF to_regprocedure('public.rol_comercial(uuid)') IS NULL THEN _faltan := _faltan || 'función rol_comercial'::text; END IF;
  IF to_regprocedure('public.compras_supervisa_remisiones(uuid)') IS NULL THEN _faltan := _faltan || 'función compras_supervisa_remisiones'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='remisiones_refacciones' AND column_name='es_historica') THEN
    _faltan := _faltan || 'columna remisiones_refacciones.es_historica'::text;
  END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ', ');
  END IF;
END;
$preflight$;

-- ── 1. Regresa al inventario lo surtido de una remisión ─────────────────────
CREATE OR REPLACE FUNCTION public._devolver_surtido_remision_refaccion(_remision_id uuid, _motivo text)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r public.remisiones_refacciones%ROWTYPE;
  i public.remision_refaccion_items%ROWTYPE;
  v_hoy date := (now() AT TIME ZONE 'America/Mexico_City')::date;
  v_total integer := 0;
BEGIN
  SELECT * INTO r FROM public.remisiones_refacciones WHERE id = _remision_id;
  IF NOT FOUND THEN RETURN 0; END IF;
  FOR i IN SELECT * FROM public.remision_refaccion_items
            WHERE remision_id = _remision_id AND cantidad_surtida > 0 ORDER BY id FOR UPDATE LOOP
    PERFORM public._mover_inventario_refaccion(
      i.producto_id,
      (SELECT p.linea_catalogo FROM public.almacen_refacciones_productos p WHERE p.id = i.producto_id),
      i.cantidad_surtida, v_hoy, 'entrada', 'devolucion', r.id, r.folio, NULL,
      'Devolución por ' || _motivo, r.cliente_id, i.precio_unitario, r.es_prueba);
    UPDATE public.remision_refaccion_items
       SET cantidad_surtida = 0, cantidad_bloqueada = 0, cantidad_faltante = 0, estatus = 'cancelada'
     WHERE id = i.id;
    v_total := v_total + i.cantidad_surtida;
  END LOOP;
  RETURN v_total;
END;
$$;
REVOKE ALL ON FUNCTION public._devolver_surtido_remision_refaccion(uuid, text) FROM PUBLIC, anon, authenticated;

-- ── 2. Cancelar regresa lo surtido ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.cancelar_remision_refacciones(_remision_id uuid, _motivo text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_row public.remisiones_refacciones%ROWTYPE;
  v_rol text;
  v_piezas integer;
BEGIN
  IF nullif(trim(_motivo), '') IS NULL OR char_length(trim(_motivo)) < 3 THEN
    RAISE EXCEPTION 'Escribe el motivo (mínimo 3 caracteres)';
  END IF;

  SELECT * INTO v_row FROM public.remisiones_refacciones WHERE id = _remision_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró la remisión';
  END IF;
  IF v_row.etapa = 'cancelada' THEN
    RAISE EXCEPTION 'Esta remisión ya está cancelada';
  END IF;
  IF v_row.etapa = 'entregada' OR v_row.entregada_at IS NOT NULL THEN
    RAISE EXCEPTION 'Una remisión entregada no se cancela; queda en Entregadas';
  END IF;

  v_rol := public.rol_comercial();
  IF NOT (
    v_rol IN ('global', 'supervisor')
    OR public.compras_supervisa_remisiones(auth.uid())
    OR (v_rol = 'operador' AND (v_row.vendedor_id = auth.uid() OR v_row.created_by = auth.uid()))
  ) THEN
    RAISE EXCEPTION 'No puedes cancelar esta remisión';
  END IF;

  -- El motivo queda en el historial de correcciones de las partidas que cambian.
  PERFORM set_config('kit.motivo_correccion', trim(_motivo), true);

  -- Lo ya surtido regresa al inventario; lo apartado se suelta.
  v_piezas := public._devolver_surtido_remision_refaccion(_remision_id, 'cancelación de ' || v_row.folio || ': ' || trim(_motivo));

  UPDATE public.remision_refaccion_items
     SET cantidad_bloqueada = 0, cantidad_faltante = 0, estatus = 'cancelada'
   WHERE remision_id = _remision_id
     AND (estatus <> 'cancelada' OR cantidad_bloqueada <> 0 OR cantidad_faltante <> 0);

  UPDATE public.remisiones_refacciones
     SET etapa = 'cancelada', area_actual = 'ventas', abierta = false,
         motivo_cancelacion = trim(_motivo), cancelada_at = now()
   WHERE id = _remision_id;

  INSERT INTO public.remision_refaccion_eventos (remision_id, area, accion, detalle, usuario_id)
  VALUES (
    _remision_id, 'ventas', 'cancelar_remision',
    'Cancelada. Quedó en Canceladas para revisión.'
      || CASE WHEN v_piezas > 0 THEN ' Regresaron ' || v_piezas || ' pieza(s) ya surtidas al inventario.' ELSE '' END
      || ' ' || trim(_motivo),
    auth.uid()
  );

  PERFORM set_config('kit.motivo_correccion', '', true);
END;
$$;
REVOKE ALL ON FUNCTION public.cancelar_remision_refacciones(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancelar_remision_refacciones(uuid, text) TO authenticated;

-- ── 3. Eliminar: mensaje claro con el historial inmutable ───────────────────
CREATE OR REPLACE FUNCTION public.eliminar_remision_refacciones(_remision_id uuid, _motivo text, _devolver_inventario boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r public.remisiones_refacciones%ROWTYPE;
  m record;
  v_hoy date := (now() AT TIME ZONE 'America/Mexico_City')::date;
  v_devueltas integer := 0;
  v_nombre text;
  v_snapshot jsonb;
BEGIN
  IF NOT (public.rol_comercial() = 'global' OR public.es_admin_area(auth.uid(), 'comercial'::public.user_area)) THEN
    RAISE EXCEPTION 'Sólo el administrador de Comercial puede eliminar una remisión por completo';
  END IF;
  IF nullif(trim(_motivo), '') IS NULL OR char_length(trim(_motivo)) < 10 THEN
    RAISE EXCEPTION 'Escribe el motivo de la eliminación (mínimo 10 caracteres)';
  END IF;

  SELECT * INTO r FROM public.remisiones_refacciones WHERE id = _remision_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No se encontró la remisión'; END IF;
  PERFORM public.exigir_dato_prueba(r.es_prueba, 'la remisión ' || r.folio);

  IF r.es_historica THEN
    RAISE EXCEPTION 'La remisión % es histórica: un administrador la anula con anular_remision_historica_refacciones', r.folio;
  END IF;
  IF r.etapa = 'entregada' AND NOT r.es_prueba THEN
    RAISE EXCEPTION 'La remisión % ya se entregó y es real: no se elimina (queda en Entregadas). Si fue un error, Compras la corrige con una devolución.', r.folio;
  END IF;
  IF EXISTS (SELECT 1 FROM public.cobranza_aplicaciones WHERE remision_id = _remision_id)
     OR EXISTS (SELECT 1 FROM public.cobranza_saldos_favor WHERE remision_origen_id = _remision_id)
     OR EXISTS (SELECT 1 FROM public.cobranza_solicitudes_saldo WHERE remision_id = _remision_id)
     OR EXISTS (SELECT 1 FROM public.remision_refaccion_correcciones WHERE remision_id = _remision_id) THEN
    RAISE EXCEPTION 'La remisión % tiene cobros, saldos a favor o correcciones (una cancelación también deja su registro) y ese historial no se borra: queda en la remisión como cancelada.', r.folio;
  END IF;

  IF coalesce(_devolver_inventario, true) THEN
    FOR m IN
      SELECT i.producto_id, sum(i.cantidad_surtida)::integer AS piezas
        FROM public.remision_refaccion_items i
       WHERE i.remision_id = _remision_id AND i.cantidad_surtida > 0
       GROUP BY i.producto_id
    LOOP
      PERFORM public._mover_inventario_refaccion(
        m.producto_id,
        (SELECT p.linea_catalogo FROM public.almacen_refacciones_productos p WHERE p.id = m.producto_id),
        m.piezas, v_hoy, 'entrada', 'devolucion', r.id, r.folio, NULL,
        'Devolución por eliminación de ' || r.folio || ': ' || trim(_motivo),
        r.cliente_id, NULL, r.es_prueba);
      v_devueltas := v_devueltas + m.piezas;
    END LOOP;
  END IF;

  SELECT coalesce(nullif(p.nombre_completo, ''), p.email) INTO v_nombre FROM public.profiles p WHERE p.id = auth.uid();
  v_snapshot := jsonb_build_object(
    'remision', to_jsonb(r),
    'partidas', coalesce((SELECT jsonb_agg(to_jsonb(i)) FROM public.remision_refaccion_items i WHERE i.remision_id = _remision_id), '[]'::jsonb),
    'inventario_devuelto', coalesce(_devolver_inventario, true),
    'piezas_devueltas_a_inventario', v_devueltas
  );
  INSERT INTO public.bitacora_eliminaciones (tabla, registro_id, eliminado_por, nombre_usuario, motivo, datos_eliminados)
  VALUES ('remisiones_refacciones', _remision_id, auth.uid(), coalesce(v_nombre, auth.uid()::text), trim(_motivo), v_snapshot);

  -- Partidas, eventos y órdenes se van en cascada; avisos también.
  DELETE FROM public.remisiones_refacciones WHERE id = _remision_id;

  RETURN jsonb_build_object('folio', r.folio, 'piezas_devueltas', v_devueltas);
END;
$$;

-- ── 4. Relleno único: remisiones ya canceladas con piezas surtidas ──────────
DO $relleno$
DECLARE
  r record;
  v_n integer;
  v_total integer := 0;
BEGIN
  FOR r IN
    SELECT x.id, x.folio FROM public.remisiones_refacciones x
     WHERE x.etapa = 'cancelada' AND NOT x.es_prueba AND NOT x.es_historica AND x.entregada_at IS NULL
       AND EXISTS (SELECT 1 FROM public.remision_refaccion_items i WHERE i.remision_id = x.id AND i.cantidad_surtida > 0)
     ORDER BY x.folio
  LOOP
    PERFORM set_config('kit.motivo_correccion', 'Corrección de inventario: remisión cancelada con piezas surtidas', true);
    v_n := public._devolver_surtido_remision_refaccion(r.id, 'corrección de inventario: ' || r.folio || ' está cancelada y sus piezas surtidas no habían regresado');
    IF v_n > 0 THEN
      INSERT INTO public.remision_refaccion_eventos (remision_id, area, accion, detalle)
      VALUES (r.id, 'almacen', 'correccion', 'Corrección de inventario: regresaron ' || v_n || ' pieza(s) surtidas de la remisión cancelada.');
      RAISE NOTICE 'Remisión %: regresaron % pieza(s) al inventario', r.folio, v_n;
      v_total := v_total + v_n;
    END IF;
  END LOOP;
  PERFORM set_config('kit.motivo_correccion', '', true);
  RAISE NOTICE 'Relleno de inventario por remisiones canceladas: % pieza(s) en total', v_total;
END
$relleno$;

DO $postflight$
BEGIN
  IF position('_devolver_surtido_remision_refaccion' in pg_get_functiondef('public.cancelar_remision_refacciones(uuid,text)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'cancelar_remision_refacciones no quedó con la devolución de inventario.';
  END IF;
  IF has_function_privilege('anon', 'public.cancelar_remision_refacciones(uuid,text)', 'execute')
     OR has_function_privilege('authenticated', 'public._devolver_surtido_remision_refaccion(uuid,text)', 'execute') THEN
    RAISE EXCEPTION 'Permisos incorrectos en las funciones de cancelación.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.remisiones_refacciones x JOIN public.remision_refaccion_items i ON i.remision_id = x.id
              WHERE x.etapa = 'cancelada' AND NOT x.es_prueba AND NOT x.es_historica AND x.entregada_at IS NULL AND i.cantidad_surtida > 0) THEN
    RAISE EXCEPTION 'Quedaron remisiones canceladas con piezas surtidas sin regresar.';
  END IF;
END $postflight$;

-- ── Verificación (solo lectura) ─────────────────────────────────────────────
-- SELECT r.folio, sum(i.cantidad_surtida) FROM remisiones_refacciones r JOIN remision_refaccion_items i ON i.remision_id = r.id
--  WHERE r.etapa = 'cancelada' GROUP BY 1 HAVING sum(i.cantidad_surtida) > 0;   -- debe quedar vacío
-- Kárdex de un artículo: la venta original y su «devolución» por la cancelación.

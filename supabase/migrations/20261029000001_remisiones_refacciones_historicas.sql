-- ============================================================================
-- Carga de remisiones HISTÓRICAS de refacciones (PROPUESTA, sin aplicar)
--
-- Para ventas ya hechas (p. ej. octubre) cuyo inventario ya se descontó por
-- otro lado. La remisión nace CONFIRMADA (no es cotización), ENTREGADA y con su
-- total, para que el flujo de dinero y Cobranza la cobren, pero:
--   · NO mueve inventario: no toca `almacen_refacciones_productos.stock` ni
--     escribe en `almacen_refacciones_movimientos`, y no aparta existencias;
--   · queda MARCADA como histórica (es_historica, origen, lote, quién y cuándo);
--   · SOLO la carga un administrador global (es_admin_global);
--   · deja rastro: evento de la remisión, bitácora de compras y un registro del lote;
--   · una vez cargada NO se corrige ni se cancela desde Almacén (eso devolvería
--     existencias que nunca salieron por aquí): solo `anular_remision_historica_refacciones`,
--     que no mueve inventario y exige que no tenga cobros vigentes.
-- Se simula primero (por omisión `_simular = true`): valida todo y no escribe nada.
-- Cargar dos veces la misma referencia (cliente + referencia) se rechaza.
--
-- Nota: los reportes de ventas y rotación leen `almacen_refacciones_movimientos`;
-- como esta carga no mueve inventario, estas remisiones NO aparecen en ellos.
--
-- Idempotente. Para el SQL editor de Supabase; NO usar `supabase db push`.
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.remisiones_refacciones') IS NULL THEN _faltan := _faltan || 'tabla remisiones_refacciones'::text; END IF;
  IF to_regclass('public.remision_refaccion_items') IS NULL THEN _faltan := _faltan || 'tabla remision_refaccion_items'::text; END IF;
  IF to_regclass('public.remision_refaccion_eventos') IS NULL THEN _faltan := _faltan || 'tabla remision_refaccion_eventos'::text; END IF;
  IF to_regprocedure('public.es_admin_global(uuid)') IS NULL THEN _faltan := _faltan || 'es_admin_global(uuid)'::text; END IF;
  IF to_regprocedure('public._siguiente_folio_compras(text,boolean)') IS NULL THEN _faltan := _faltan || '_siguiente_folio_compras'::text; END IF;
  IF to_regprocedure('public.registrar_bitacora_compras(text,text,text,uuid,text,jsonb,boolean)') IS NULL THEN _faltan := _faltan || 'registrar_bitacora_compras'::text; END IF;
  IF to_regprocedure('public.exigir_dato_prueba(boolean,text)') IS NULL THEN _faltan := _faltan || 'exigir_dato_prueba'::text; END IF;
  IF to_regprocedure('public.estado_cobro_remision_refaccion(uuid)') IS NULL THEN _faltan := _faltan || 'estado_cobro_remision_refaccion'::text; END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ', ');
  END IF;
END $preflight$;

-- ── 1. Marca de histórica en la remisión ───────────────────────────────────
ALTER TABLE public.remisiones_refacciones
  ADD COLUMN IF NOT EXISTS es_historica   boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS historica_ref  text,
  ADD COLUMN IF NOT EXISTS historica_lote uuid,
  ADD COLUMN IF NOT EXISTS historica_por  uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS historica_at   timestamptz;
-- Cargar dos veces la misma referencia del mismo cliente no se permite.
CREATE UNIQUE INDEX IF NOT EXISTS ux_remision_refaccion_historica_ref
  ON public.remisiones_refacciones (cliente_id, historica_ref) WHERE es_historica;
COMMENT ON COLUMN public.remisiones_refacciones.es_historica IS
  'Remisión cargada a posteriori (venta ya hecha): confirmada con su total, sin mover inventario.';

-- ── 2. Registro de cada carga (lote) ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.cargas_remisiones_historicas (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at   timestamptz NOT NULL DEFAULT now(),
  usuario_id   uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  fuente       text NOT NULL,
  remisiones   integer NOT NULL,
  total        numeric(18, 2) NOT NULL,
  folios       text[] NOT NULL,
  es_prueba    boolean NOT NULL DEFAULT false
);
ALTER TABLE public.cargas_remisiones_historicas ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.cargas_remisiones_historicas FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.cargas_remisiones_historicas TO authenticated;
GRANT ALL ON public.cargas_remisiones_historicas TO service_role;
DROP POLICY IF EXISTS cargas_historicas_leer ON public.cargas_remisiones_historicas;
CREATE POLICY cargas_historicas_leer ON public.cargas_remisiones_historicas FOR SELECT TO authenticated
  USING (public.es_admin_global(auth.uid()) AND es_prueba = public.es_usuario_prueba(auth.uid()));

-- ── 3. Candado: una histórica no se corrige ni se borra por los caminos normales
-- (cancelar o corregir desde Almacén devolvería existencias que nunca salieron por aquí).
CREATE OR REPLACE FUNCTION public.remision_historica_protegida()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_hist boolean; v_folio text;
BEGIN
  IF coalesce(current_setting('kit.historica_admin', true), '') = 'on' THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'remisiones_refacciones' THEN
    v_hist := OLD.es_historica; v_folio := OLD.folio;
    IF NOT v_hist THEN
      IF TG_OP = 'UPDATE' AND NEW.es_historica THEN
        RAISE EXCEPTION 'Una remisión no se vuelve histórica después de creada.';
      END IF;
      RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    IF TG_OP = 'DELETE'
       OR NEW.etapa IS DISTINCT FROM OLD.etapa OR NEW.abierta IS DISTINCT FROM OLD.abierta
       OR NEW.descuento_pct IS DISTINCT FROM OLD.descuento_pct OR NEW.cliente_id IS DISTINCT FROM OLD.cliente_id
       OR NEW.fecha_remision IS DISTINCT FROM OLD.fecha_remision OR NEW.es_historica IS DISTINCT FROM OLD.es_historica
       OR NEW.historica_ref IS DISTINCT FROM OLD.historica_ref THEN
      RAISE EXCEPTION 'La remisión % es histórica: no se corrige, cancela ni borra desde los caminos normales (devolvería existencias que nunca salieron por aquí). Un administrador la anula con anular_remision_historica_refacciones.', v_folio;
    END IF;
    RETURN NEW;
  END IF;

  -- remision_refaccion_items
  SELECT r.es_historica, r.folio INTO v_hist, v_folio
    FROM public.remisiones_refacciones r WHERE r.id = CASE WHEN TG_OP = 'DELETE' THEN OLD.remision_id ELSE NEW.remision_id END;
  IF coalesce(v_hist, false) THEN
    IF TG_OP = 'DELETE' OR TG_OP = 'INSERT'
       OR NEW.cantidad IS DISTINCT FROM OLD.cantidad OR NEW.cantidad_bloqueada IS DISTINCT FROM OLD.cantidad_bloqueada
       OR NEW.cantidad_surtida IS DISTINCT FROM OLD.cantidad_surtida OR NEW.cantidad_faltante IS DISTINCT FROM OLD.cantidad_faltante
       OR NEW.estatus IS DISTINCT FROM OLD.estatus OR NEW.precio_unitario IS DISTINCT FROM OLD.precio_unitario
       OR NEW.descuento_pct IS DISTINCT FROM OLD.descuento_pct OR NEW.producto_id IS DISTINCT FROM OLD.producto_id THEN
      RAISE EXCEPTION 'La remisión % es histórica: sus partidas no se corrigen ni se borran desde los caminos normales (no mueven inventario). Un administrador la anula con anular_remision_historica_refacciones.', v_folio;
    END IF;
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;
DROP TRIGGER IF EXISTS trg_remision_historica_protegida ON public.remisiones_refacciones;
CREATE TRIGGER trg_remision_historica_protegida BEFORE UPDATE OR DELETE ON public.remisiones_refacciones
  FOR EACH ROW EXECUTE FUNCTION public.remision_historica_protegida();
DROP TRIGGER IF EXISTS trg_remision_historica_protegida ON public.remision_refaccion_items;
CREATE TRIGGER trg_remision_historica_protegida BEFORE UPDATE OR DELETE ON public.remision_refaccion_items
  FOR EACH ROW EXECUTE FUNCTION public.remision_historica_protegida();

-- ── 4. Cargar (simular primero) ────────────────────────────────────────────
-- _remisiones: [{ "referencia": "…", "fecha": "2026-10-05", "cliente_id": uuid, "vendedor_id": uuid,
--                 "descuento_pct": 0, "tipo_pago": "anticipado|contra_entrega", "forma_pago": "efectivo|transferencia|credito",
--                 "notas": "…", "partidas": [{ "codigo_nuevo": "…", "cantidad": 2, "precio_unitario": 30.5, "descuento_pct": 0 }] }]
CREATE OR REPLACE FUNCTION public.cargar_remisiones_historicas_refacciones(
  _remisiones jsonb, _fuente text, _simular boolean DEFAULT true
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r jsonb; p jsonb;
  v_n integer; v_i integer := 0;
  v_errores jsonb := '[]'::jsonb;
  v_detalle jsonb := '[]'::jsonb;
  v_ref text; v_fecha date; v_cli public.clientes%ROWTYPE; v_vend public.profiles%ROWTYPE; v_prod public.almacen_refacciones_productos%ROWTYPE;
  v_desc numeric; v_cant integer; v_precio numeric; v_pdesc numeric; v_tipo_pago text; v_forma text;
  v_total numeric; v_total_lote numeric := 0; v_partidas integer;
  v_prueba boolean := public.es_usuario_prueba(auth.uid());
  v_lote uuid := gen_random_uuid();
  v_id uuid; v_folio text; v_folios text[] := ARRAY[]::text[];
  v_stock0 bigint; v_mov0 bigint; v_stock1 bigint; v_mov1 bigint;
  v_vistos text[] := ARRAY[]::text[];
  v_ok boolean;
BEGIN
  IF auth.uid() IS NULL OR NOT public.es_admin_global(auth.uid()) THEN
    RAISE EXCEPTION 'Sólo un administrador carga remisiones históricas de refacciones';
  END IF;
  IF nullif(btrim(coalesce(_fuente, '')), '') IS NULL THEN RAISE EXCEPTION 'Indica la fuente de la carga (de dónde salen las remisiones)'; END IF;
  IF _remisiones IS NULL OR jsonb_typeof(_remisiones) <> 'array' OR jsonb_array_length(_remisiones) = 0 THEN
    RAISE EXCEPTION 'Manda al menos una remisión';
  END IF;
  v_n := jsonb_array_length(_remisiones);
  IF v_n > 200 THEN RAISE EXCEPTION 'Máximo 200 remisiones por carga (mandaste %)', v_n; END IF;

  -- ── Validación completa (no escribe nada) ──
  FOR r IN SELECT value FROM jsonb_array_elements(_remisiones) LOOP
    v_i := v_i + 1;
    v_ref := nullif(btrim(coalesce(r->>'referencia', '')), '');
    v_ok := true;
    IF v_ref IS NULL THEN
      v_errores := v_errores || jsonb_build_object('fila', v_i, 'error', 'Falta la referencia (folio de la remisión original)'); CONTINUE;
    END IF;
    BEGIN
      v_fecha := (r->>'fecha')::date;
    EXCEPTION WHEN OTHERS THEN v_fecha := NULL; END;
    IF v_fecha IS NULL THEN v_errores := v_errores || jsonb_build_object('fila', v_i, 'referencia', v_ref, 'error', 'Fecha inválida o faltante'); CONTINUE; END IF;
    IF v_fecha > current_date THEN v_errores := v_errores || jsonb_build_object('fila', v_i, 'referencia', v_ref, 'error', 'La fecha no puede ser futura'); v_ok := false; END IF;

    SELECT * INTO v_cli FROM public.clientes WHERE id = nullif(r->>'cliente_id', '')::uuid;
    IF NOT FOUND THEN v_errores := v_errores || jsonb_build_object('fila', v_i, 'referencia', v_ref, 'error', 'No existe el cliente'); CONTINUE; END IF;
    IF v_prueba AND NOT coalesce(v_cli.es_prueba, false) THEN
      v_errores := v_errores || jsonb_build_object('fila', v_i, 'referencia', v_ref, 'error', 'Estás en MODO PRUEBA: el cliente es real'); CONTINUE;
    END IF;
    IF NOT v_prueba AND coalesce(v_cli.es_prueba, false) THEN
      v_errores := v_errores || jsonb_build_object('fila', v_i, 'referencia', v_ref, 'error', 'El cliente es de prueba y tu usuario es real: no se mezclan'); CONTINUE;
    END IF;
    IF (v_cli.id::text || '|' || v_ref) = ANY (v_vistos) THEN
      v_errores := v_errores || jsonb_build_object('fila', v_i, 'referencia', v_ref, 'error', 'Referencia repetida dentro de la carga'); v_ok := false;
    END IF;
    v_vistos := v_vistos || (v_cli.id::text || '|' || v_ref);
    IF EXISTS (SELECT 1 FROM public.remisiones_refacciones x WHERE x.es_historica AND x.cliente_id = v_cli.id AND x.historica_ref = v_ref) THEN
      v_errores := v_errores || jsonb_build_object('fila', v_i, 'referencia', v_ref, 'error', 'Esa referencia ya se cargó para este cliente'); v_ok := false;
    END IF;

    SELECT * INTO v_vend FROM public.profiles WHERE id = nullif(r->>'vendedor_id', '')::uuid;
    IF NOT FOUND THEN v_errores := v_errores || jsonb_build_object('fila', v_i, 'referencia', v_ref, 'error', 'Falta el vendedor (vendedor_id)'); v_ok := false; END IF;

    v_desc := coalesce(nullif(r->>'descuento_pct', '')::numeric, 0);
    IF v_desc < 0 OR v_desc > 100 THEN v_errores := v_errores || jsonb_build_object('fila', v_i, 'referencia', v_ref, 'error', 'El descuento general debe estar entre 0 y 100'); v_ok := false; END IF;
    v_tipo_pago := nullif(r->>'tipo_pago', ''); v_forma := nullif(r->>'forma_pago', '');
    IF v_tipo_pago IS NOT NULL AND v_tipo_pago NOT IN ('anticipado', 'contra_entrega') THEN
      v_errores := v_errores || jsonb_build_object('fila', v_i, 'referencia', v_ref, 'error', 'tipo_pago inválido'); v_ok := false; END IF;
    IF v_forma IS NOT NULL AND v_forma NOT IN ('efectivo', 'transferencia', 'credito') THEN
      v_errores := v_errores || jsonb_build_object('fila', v_i, 'referencia', v_ref, 'error', 'forma_pago inválida'); v_ok := false; END IF;

    IF r->'partidas' IS NULL OR jsonb_typeof(r->'partidas') <> 'array' OR jsonb_array_length(r->'partidas') = 0 THEN
      v_errores := v_errores || jsonb_build_object('fila', v_i, 'referencia', v_ref, 'error', 'La remisión necesita al menos una partida'); CONTINUE;
    END IF;
    v_total := 0; v_partidas := 0;
    FOR p IN SELECT value FROM jsonb_array_elements(r->'partidas') LOOP
      SELECT * INTO v_prod FROM public.almacen_refacciones_productos WHERE codigo_nuevo = nullif(btrim(coalesce(p->>'codigo_nuevo', '')), '') AND es_prueba = coalesce(v_cli.es_prueba, false);
      IF NOT FOUND THEN
        v_errores := v_errores || jsonb_build_object('fila', v_i, 'referencia', v_ref, 'error', 'No existe el artículo ' || coalesce(p->>'codigo_nuevo', '(vacío)')); v_ok := false; CONTINUE;
      END IF;
      v_cant := nullif(p->>'cantidad', '')::integer; v_precio := nullif(p->>'precio_unitario', '')::numeric;
      v_pdesc := coalesce(nullif(p->>'descuento_pct', '')::numeric, 0);
      IF v_cant IS NULL OR v_cant <= 0 THEN v_errores := v_errores || jsonb_build_object('fila', v_i, 'referencia', v_ref, 'error', 'Cantidad inválida en ' || v_prod.codigo_nuevo); v_ok := false; CONTINUE; END IF;
      IF v_precio IS NULL OR v_precio < 0 THEN v_errores := v_errores || jsonb_build_object('fila', v_i, 'referencia', v_ref, 'error', 'Precio inválido en ' || v_prod.codigo_nuevo); v_ok := false; CONTINUE; END IF;
      IF v_pdesc < 0 OR v_pdesc > 100 THEN v_errores := v_errores || jsonb_build_object('fila', v_i, 'referencia', v_ref, 'error', 'Descuento inválido en ' || v_prod.codigo_nuevo); v_ok := false; CONTINUE; END IF;
      v_total := v_total + public.importe_partida_refaccion(v_precio, v_cant, v_pdesc, v_desc);
      v_partidas := v_partidas + 1;
    END LOOP;
    IF v_ok THEN
      v_total_lote := v_total_lote + v_total;
      v_detalle := v_detalle || jsonb_build_object('referencia', v_ref, 'total', v_total, 'partidas', v_partidas);
    END IF;
  END LOOP;

  IF jsonb_array_length(v_errores) > 0 THEN
    IF _simular THEN
      RETURN jsonb_build_object('ok', false, 'simulada', true, 'errores', v_errores, 'sin_errores', v_detalle);
    END IF;
    RAISE EXCEPTION 'La carga tiene errores y no se escribió nada: %', v_errores::text;
  END IF;
  IF _simular THEN
    RETURN jsonb_build_object('ok', true, 'simulada', true, 'remisiones', v_n, 'total', v_total_lote, 'detalle', v_detalle);
  END IF;

  -- ── Escritura ──
  SELECT coalesce(sum(stock), 0) INTO v_stock0 FROM public.almacen_refacciones_productos;
  SELECT count(*) INTO v_mov0 FROM public.almacen_refacciones_movimientos;
  v_i := 0;
  FOR r IN SELECT value FROM jsonb_array_elements(_remisiones) LOOP
    v_i := v_i + 1;
    v_ref := btrim(r->>'referencia');
    v_fecha := (r->>'fecha')::date;
    SELECT * INTO v_cli FROM public.clientes WHERE id = (r->>'cliente_id')::uuid;
    SELECT * INTO v_vend FROM public.profiles WHERE id = (r->>'vendedor_id')::uuid;
    v_desc := coalesce(nullif(r->>'descuento_pct', '')::numeric, 0);
    v_folio := public._siguiente_folio_compras('RF', coalesce(v_cli.es_prueba, false));
    INSERT INTO public.remisiones_refacciones
      (folio, cliente_id, vendedor_id, nombre_vendedor, fecha_remision, notas, etapa, area_actual, abierta, created_by,
       tipo_envio, tipo_pago, forma_pago, descuento_pct, pagado, lista_logistica_at, entregada_at, entregada_por,
       es_historica, historica_ref, historica_lote, historica_por, historica_at)
    VALUES
      (v_folio, v_cli.id, v_vend.id, coalesce(nullif(btrim(v_vend.nombre_completo), ''), v_vend.email), v_fecha,
       'Remisión histórica ' || v_ref || '. Fuente: ' || btrim(_fuente) || '. Sin movimiento de inventario.' ||
         coalesce(' ' || nullif(btrim(coalesce(r->>'notas', '')), ''), ''),
       'entregada', 'logistica', false, auth.uid(),
       'recoge', nullif(r->>'tipo_pago', ''), nullif(r->>'forma_pago', ''), v_desc, false,
       v_fecha::timestamptz, v_fecha::timestamptz, auth.uid(),
       true, v_ref, v_lote, auth.uid(), now())
    RETURNING id INTO v_id;

    FOR p IN SELECT value FROM jsonb_array_elements(r->'partidas') LOOP
      SELECT * INTO v_prod FROM public.almacen_refacciones_productos WHERE codigo_nuevo = btrim(p->>'codigo_nuevo') AND es_prueba = coalesce(v_cli.es_prueba, false);
      v_cant := (p->>'cantidad')::integer;
      INSERT INTO public.remision_refaccion_items
        (remision_id, producto_id, codigo_nuevo, codigo_antiguo, descripcion, precio_unitario, cantidad,
         cantidad_bloqueada, cantidad_surtida, cantidad_faltante, estatus, descuento_pct)
      VALUES
        (v_id, v_prod.id, v_prod.codigo_nuevo, v_prod.codigo_antiguo, v_prod.descripcion, (p->>'precio_unitario')::numeric, v_cant,
         0, v_cant, 0, 'surtida', coalesce(nullif(p->>'descuento_pct', '')::numeric, 0));
    END LOOP;

    v_total := public.total_vigente_remision_refaccion(v_id);
    INSERT INTO public.remision_refaccion_eventos (remision_id, etapa, area, accion, detalle, usuario_id)
    VALUES (v_id, 'entregada', 'finanzas', 'carga_historica',
            'Remisión histórica cargada (ref. ' || v_ref || ', fuente: ' || btrim(_fuente) || '). Total ' ||
            to_char(v_total, 'FM999,999,990.00') || '. No movió inventario.', auth.uid());
    PERFORM public.registrar_bitacora_compras('cobranza', 'carga_historica', 'remisiones_refacciones', v_id, v_folio,
      jsonb_build_object('referencia', v_ref, 'fuente', btrim(_fuente), 'total', v_total, 'lote', v_lote), coalesce(v_cli.es_prueba, false));
    v_folios := v_folios || v_folio;
    v_detalle := v_detalle; -- (detalle ya calculado en la validación)
  END LOOP;

  -- Candado final: el inventario no se movió.
  SELECT coalesce(sum(stock), 0) INTO v_stock1 FROM public.almacen_refacciones_productos;
  SELECT count(*) INTO v_mov1 FROM public.almacen_refacciones_movimientos;
  IF v_stock1 <> v_stock0 OR v_mov1 <> v_mov0 THEN
    RAISE EXCEPTION 'La carga movió inventario (stock % → %, movimientos % → %): se deshace todo.', v_stock0, v_stock1, v_mov0, v_mov1;
  END IF;

  INSERT INTO public.cargas_remisiones_historicas (id, usuario_id, fuente, remisiones, total, folios, es_prueba)
  VALUES (v_lote, auth.uid(), btrim(_fuente), v_n, v_total_lote, v_folios, v_prueba);

  RETURN jsonb_build_object('ok', true, 'simulada', false, 'lote', v_lote, 'remisiones', v_n, 'total', v_total_lote, 'folios', to_jsonb(v_folios));
END;
$$;

-- ── 5. Anular una histórica (sin mover inventario) ─────────────────────────
CREATE OR REPLACE FUNCTION public.anular_remision_historica_refacciones(_remision_id uuid, _motivo text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.remisiones_refacciones%ROWTYPE; e record;
BEGIN
  IF auth.uid() IS NULL OR NOT public.es_admin_global(auth.uid()) THEN
    RAISE EXCEPTION 'Sólo un administrador anula remisiones históricas';
  END IF;
  IF length(btrim(coalesce(_motivo, ''))) < 3 THEN RAISE EXCEPTION 'El motivo es obligatorio'; END IF;
  SELECT * INTO r FROM public.remisiones_refacciones WHERE id = _remision_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe la remisión'; END IF;
  IF NOT r.es_historica THEN RAISE EXCEPTION '% no es histórica: se cancela por el camino normal', r.folio; END IF;
  PERFORM public.exigir_dato_prueba(r.es_prueba, 'la remisión ' || r.folio);
  IF r.etapa = 'cancelada' THEN RAISE EXCEPTION '% ya está anulada', r.folio; END IF;
  SELECT * INTO e FROM public.estado_cobro_remision_refaccion(r.id);
  IF coalesce(e.cobrado_dinero, 0) + coalesce(e.cobrado_saldo_favor, 0) > 0 THEN
    RAISE EXCEPTION '% ya tiene cobros aplicados (%): reviértelos primero en Cobranza', r.folio,
      to_char(coalesce(e.cobrado_dinero, 0) + coalesce(e.cobrado_saldo_favor, 0), 'FM999,999,990.00');
  END IF;
  PERFORM set_config('kit.historica_admin', 'on', true);
  PERFORM set_config('kit.motivo_correccion', 'Anulación de remisión histórica: ' || btrim(_motivo), true);
  UPDATE public.remisiones_refacciones
     SET etapa = 'cancelada', cancelada_at = now(), motivo_cancelacion = 'Histórica anulada: ' || btrim(_motivo)
   WHERE id = r.id;
  PERFORM set_config('kit.historica_admin', 'off', true);
  INSERT INTO public.remision_refaccion_eventos (remision_id, etapa, area, accion, detalle, usuario_id)
  VALUES (r.id, 'cancelada', 'finanzas', 'anulacion_historica', 'Remisión histórica anulada: ' || btrim(_motivo) || '. No movió inventario.', auth.uid());
  PERFORM public.registrar_bitacora_compras('cobranza', 'anulacion_historica', 'remisiones_refacciones', r.id, r.folio,
    jsonb_build_object('motivo', btrim(_motivo)), r.es_prueba);
END;
$$;

REVOKE ALL ON FUNCTION public.remision_historica_protegida() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cargar_remisiones_historicas_refacciones(jsonb, text, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.anular_remision_historica_refacciones(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cargar_remisiones_historicas_refacciones(jsonb, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.anular_remision_historica_refacciones(uuid, text) TO authenticated;

DO $postflight$
BEGIN
  IF has_function_privilege('anon', 'public.cargar_remisiones_historicas_refacciones(jsonb,text,boolean)', 'execute') THEN
    RAISE EXCEPTION 'La carga histórica no debe estar abierta a anon.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'remisiones_refacciones' AND column_name = 'es_historica') THEN
    RAISE EXCEPTION 'Falta remisiones_refacciones.es_historica.';
  END IF;
END $postflight$;

SELECT to_regprocedure('public.cargar_remisiones_historicas_refacciones(jsonb,text,boolean)') IS NOT NULL AS carga,
       to_regprocedure('public.anular_remision_historica_refacciones(uuid,text)') IS NOT NULL AS anulacion,
       (SELECT count(*) FROM public.remisiones_refacciones WHERE es_historica) AS historicas;

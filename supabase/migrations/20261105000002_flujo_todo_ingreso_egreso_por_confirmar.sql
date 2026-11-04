-- ============================================================================
-- Todo ingreso y egreso del flujo aparece en Control Financiero «por confirmar»
-- desde el registro (2026-11-05)
--
-- Pedido del equipo: «igual los egresos». Antes solo el pago de cliente creaba su
-- movimiento PENDIENTE al registrarse. Ahora lo hace TODO renglón nuevo del flujo
-- (ingresos, egresos, reembolsos, formulario completo o rápido), de dinero real:
--   · Se crea con el detalle del formulario (categoría, contraparte, vía, factura…),
--     sin cuenta y sin mover saldos (los saldos solo cuentan lo CONFIRMADO).
--   · Caja lo confirma (mismo registro, toma la caja/cuenta) y rechazar lo cancela.
--   · Los datos de prueba no generan movimiento. Abonos de Crédito, pagos de
--     Cobranza e historial conectado siguen como estaban.
--
-- Además: un ingreso del formulario completo que viene de un CLIENTE, en pesos y en
-- efectivo/transferencia/depósito, se registra como PAGO_CLIENTE: así también aparece
-- en Cobranza y se puede APLICAR a remisiones (lo que antes se hacía desde Control
-- Financiero). Cualquier otro ingreso o egreso se aplica a «Otro» / gasto / proveedor.
--
-- Idempotente. Para el SQL editor de Supabase; NO usar `supabase db push`.
-- Para revertir: volver a _flujo_a_cobranza de 20261104000002 y a flujo_registrar_movimiento de 20261105000001.
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := '{}';
BEGIN
  IF to_regprocedure('public._flujo_a_cobranza()') IS NULL THEN _faltan := _faltan || 'función _flujo_a_cobranza (20261104000002)'::text; END IF;
  IF to_regprocedure('public.flujo_registrar_movimiento(jsonb)') IS NULL THEN _faltan := _faltan || 'flujo_registrar_movimiento (20261105000001)'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='flujo_dinero' AND column_name='quien_recibio') THEN
    _faltan := _faltan || 'columna flujo_dinero.quien_recibio (20261105000001)'::text;
  END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ', ');
  END IF;
END;
$preflight$;

-- ── 1. El movimiento «por confirmar» nace con el detalle del formulario ─────
CREATE OR REPLACE FUNCTION public._flujo_movimiento_pendiente(f public.flujo_dinero)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_mov uuid;
BEGIN
  PERFORM set_config('kit.flujo_escribe', 'on', true);
  INSERT INTO public.movimientos_financieros
    (tipo, estatus, concepto, categoria, descripcion, monto, moneda, tipo_cambio, fecha_movimiento, metodo_pago, referencia,
     contraparte_tipo, cliente_id, proveedor_id, empleado_id, contraparte_nombre, recibido_por, created_by,
     via, intermediario_id, intermediario_nombre, factura_folio, factura_uuid, factura_rfc, remision_id)
  VALUES
    (CASE WHEN f.tipo = 'SALIDA' THEN 'EGRESO'::public.mov_tipo ELSE 'INGRESO'::public.mov_tipo END, 'PENDIENTE',
     coalesce(f.concepto, 'Pago de cliente ' || f.contraparte_nombre), f.categoria,
     coalesce(f.descripcion, 'Flujo de dinero ' || f.folio),
     f.monto, f.moneda, f.tipo_cambio, f.fecha, f.metodo_pago, f.referencia,
     coalesce(f.contraparte_tipo::public.contraparte_tipo,
              CASE WHEN f.cliente_id IS NULL THEN 'OTRO'::public.contraparte_tipo ELSE 'CLIENTE'::public.contraparte_tipo END),
     f.cliente_id, f.proveedor_id, f.empleado_id, f.contraparte_nombre, coalesce(f.quien_recibio, f.recibido_por),
     coalesce(auth.uid(), f.recibido_por),
     CASE WHEN f.requiere_comprobacion OR f.via = 'INTERMEDIARIO' THEN 'INTERMEDIARIO'::public.mov_via ELSE 'DIRECTO'::public.mov_via END,
     f.intermediario_id,
     CASE WHEN f.requiere_comprobacion OR f.via = 'INTERMEDIARIO' THEN f.intermediario_nombre END,
     f.factura_folio, f.factura_uuid, f.factura_rfc, f.remision_id)
  RETURNING id INTO v_mov;
  PERFORM set_config('kit.flujo_escribe', '', true);
  RETURN v_mov;
END;
$$;
REVOKE ALL ON FUNCTION public._flujo_movimiento_pendiente(public.flujo_dinero) FROM PUBLIC, anon, authenticated;

-- ── 2. El trigger del flujo: movimiento por confirmar para todo, pago en Cobranza para pagos ──
CREATE OR REPLACE FUNCTION public._flujo_a_cobranza()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_pago uuid;
  v_folio text;
  v_cta text;
  v_mov uuid;
BEGIN
  IF NEW.cxc_abono_id IS NOT NULL THEN RETURN NULL; END IF;

  IF TG_OP = 'INSERT' THEN
    -- Solo lo que nace en el flujo (recibido, sin pago ni movimiento ligados): lo demás ya tiene su origen.
    IF NEW.etapa <> 'RECIBIDO' OR NEW.cobranza_pago_id IS NOT NULL OR NEW.movimiento_id IS NOT NULL THEN RETURN NULL; END IF;

    IF NEW.tipo = 'PAGO_CLIENTE' AND NEW.cliente_id IS NOT NULL THEN
      v_folio := public._siguiente_folio_compras('CP', NEW.es_prueba);
      PERFORM set_config('kit.flujo_sincroniza', 'on', true);
      INSERT INTO public.cobranza_pagos (folio, cliente_id, fecha, monto, forma, referencia, notas, estatus,
                                         conciliado, capturado_por, es_prueba)
      VALUES (v_folio, NEW.cliente_id, NEW.fecha, NEW.monto,
              CASE lower(NEW.metodo_pago::text) WHEN 'efectivo' THEN 'efectivo' WHEN 'deposito' THEN 'deposito' ELSE 'transferencia' END,
              NEW.referencia, 'Flujo de dinero ' || NEW.folio, 'registrado', false, NEW.recibido_por, NEW.es_prueba)
      RETURNING id INTO v_pago;
      PERFORM set_config('kit.flujo_sincroniza', '', true);
    END IF;

    -- Control Financiero: movimiento «por confirmar» (sin cuenta, no mueve saldos). Los datos de prueba no lo generan.
    IF NOT NEW.es_prueba THEN
      v_mov := public._flujo_movimiento_pendiente(NEW);
    END IF;

    IF v_pago IS NOT NULL OR v_mov IS NOT NULL THEN
      UPDATE public.flujo_dinero SET cobranza_pago_id = coalesce(v_pago, cobranza_pago_id), movimiento_id = coalesce(v_mov, movimiento_id)
       WHERE id = NEW.id;
    END IF;
    RETURN NULL;
  END IF;

  -- UPDATE de etapa: el pago de Cobranza sigue al flujo (solo los pagos que nacieron en el flujo).
  IF NEW.tipo <> 'PAGO_CLIENTE' OR NEW.cobranza_pago_id IS NULL OR NEW.etapa IS NOT DISTINCT FROM OLD.etapa THEN RETURN NULL; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.cobranza_pagos WHERE id = NEW.cobranza_pago_id AND notas LIKE 'Flujo de dinero %') THEN
    RETURN NULL;
  END IF;

  PERFORM set_config('kit.flujo_sincroniza', 'on', true);
  IF NEW.etapa = 'EN_CAJA' THEN
    SELECT nombre INTO v_cta FROM public.cuentas_financieras WHERE id = NEW.cuenta_id;
    UPDATE public.cobranza_pagos
       SET estatus = 'validado', conciliado = true, cuenta_destino = v_cta,
           validado_por = NEW.caja_por, validado_at = coalesce(NEW.caja_at, now())
     WHERE id = NEW.cobranza_pago_id AND estatus = 'registrado';
  ELSIF NEW.etapa = 'RECHAZADO' THEN
    UPDATE public.cobranza_pagos
       SET estatus = 'revertido', revertido_por = NEW.rechazado_por, revertido_at = coalesce(NEW.rechazado_at, now()),
           motivo_reversion = 'Rechazado en el flujo de dinero ' || NEW.folio || ': ' || coalesce(NEW.motivo_rechazo, '')
     WHERE id = NEW.cobranza_pago_id AND estatus <> 'revertido';
  END IF;
  PERFORM set_config('kit.flujo_sincroniza', '', true);
  RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION public._flujo_a_cobranza() FROM PUBLIC, anon, authenticated;

-- ── 3. Un ingreso de un cliente (pesos, efectivo/transferencia/depósito) es un pago de cliente ──
CREATE OR REPLACE FUNCTION public.flujo_registrar_movimiento(_datos jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_tipo text;
  v_monto numeric;
  v_moneda text := coalesce(nullif(btrim(coalesce(_datos->>'moneda', '')), ''), 'MXN');
  v_tc numeric := nullif(_datos->>'tipo_cambio', '')::numeric;
  v_metodo text := coalesce(nullif(_datos->>'metodo_pago', ''), 'EFECTIVO');
  v_fecha date := coalesce(nullif(_datos->>'fecha_movimiento', '')::date, (now() AT TIME ZONE 'America/Mexico_City')::date);
  v_contra text := coalesce(nullif(_datos->>'contraparte_tipo', ''), 'OTRO');
  v_nombre text := nullif(btrim(coalesce(_datos->>'contraparte_nombre', '')), '');
  v_concepto text := nullif(btrim(coalesce(_datos->>'concepto', '')), '');
  v_cli uuid := nullif(_datos->>'cliente_id', '')::uuid;
  v_prov uuid := nullif(_datos->>'proveedor_id', '')::uuid;
  v_emp uuid := nullif(_datos->>'empleado_id', '')::uuid;
  v_via text := coalesce(nullif(_datos->>'via', ''), 'DIRECTO');
  v_inter_id uuid := nullif(_datos->>'intermediario_id', '')::uuid;
  v_inter text := nullif(btrim(coalesce(_datos->>'intermediario_nombre', '')), '');
  v_cuenta uuid := nullif(_datos->>'cuenta_id', '')::uuid;
  v_cta public.cuentas_financieras%ROWTYPE;
  v_prueba boolean := public.es_usuario_prueba(auth.uid());
  v_cl public.clientes%ROWTYPE;
  v_id uuid;
  v_folio text;
BEGIN
  IF NOT (public.flujo_cap('recibe') OR public.flujo_es_admin()) THEN
    RAISE EXCEPTION 'No tienes asignada la etapa de recepción';
  END IF;
  v_tipo := CASE upper(coalesce(_datos->>'tipo', '')) WHEN 'INGRESO' THEN 'INGRESO' WHEN 'EGRESO' THEN 'SALIDA' WHEN 'SALIDA' THEN 'SALIDA' END;
  IF v_tipo IS NULL THEN RAISE EXCEPTION 'Indica si es un ingreso o un egreso'; END IF;
  v_monto := round(nullif(_datos->>'monto', '')::numeric, 2);
  IF v_monto IS NULL OR v_monto <= 0 THEN RAISE EXCEPTION 'El monto debe ser mayor a cero'; END IF;
  IF v_concepto IS NULL THEN RAISE EXCEPTION 'El concepto es obligatorio'; END IF;
  IF v_nombre IS NULL THEN RAISE EXCEPTION 'Indica quién entregó o recibe el dinero'; END IF;
  IF v_contra NOT IN ('CLIENTE', 'PROVEEDOR', 'EMPLEADO', 'OTRO') THEN RAISE EXCEPTION 'Contraparte inválida'; END IF;
  IF v_contra = 'CLIENTE' AND v_cli IS NULL THEN RAISE EXCEPTION 'Elige el cliente'; END IF;
  IF v_contra = 'PROVEEDOR' AND v_prov IS NULL THEN RAISE EXCEPTION 'Elige el proveedor'; END IF;
  IF v_contra = 'EMPLEADO' AND v_emp IS NULL THEN RAISE EXCEPTION 'Elige al empleado'; END IF;
  -- Lo que un cliente paga en pesos por los medios de cobranza es un pago de cliente: se ve en Cobranza y se aplica a remisiones.
  IF v_tipo = 'INGRESO' AND v_contra = 'CLIENTE' AND v_moneda = 'MXN' AND v_metodo IN ('EFECTIVO', 'TRANSFERENCIA', 'DEPOSITO') THEN
    v_tipo := 'PAGO_CLIENTE';
  END IF;
  IF v_metodo NOT IN ('EFECTIVO', 'TRANSFERENCIA', 'CHEQUE', 'TARJETA', 'DEPOSITO', 'COMPENSACION', 'OTRO') THEN
    RAISE EXCEPTION 'Forma de pago inválida: %', v_metodo;
  END IF;
  IF v_moneda <> 'MXN' AND (v_tc IS NULL OR v_tc <= 0) THEN RAISE EXCEPTION 'Captura el tipo de cambio para %', v_moneda; END IF;
  IF v_via NOT IN ('DIRECTO', 'INTERMEDIARIO') THEN RAISE EXCEPTION 'Vía inválida'; END IF;
  IF v_via = 'INTERMEDIARIO' THEN
    IF v_inter_id IS NOT NULL AND v_inter IS NULL THEN v_inter := public.flujo_nombre(v_inter_id); END IF;
    IF v_inter IS NULL THEN RAISE EXCEPTION 'Indica quién lleva o trae el dinero'; END IF;
  ELSE
    v_inter_id := NULL; v_inter := NULL;
  END IF;
  IF v_cuenta IS NOT NULL THEN
    SELECT * INTO v_cta FROM public.cuentas_financieras WHERE id = v_cuenta AND activo;
    IF NOT FOUND THEN RAISE EXCEPTION 'La caja o cuenta elegida no existe o está inactiva'; END IF;
    IF v_cta.moneda <> v_moneda THEN
      RAISE EXCEPTION '«%» maneja % y el movimiento está en %', v_cta.nombre, v_cta.moneda, v_moneda;
    END IF;
  END IF;
  IF v_cli IS NOT NULL THEN
    SELECT * INTO v_cl FROM public.clientes WHERE id = v_cli;
    IF NOT FOUND THEN RAISE EXCEPTION 'El cliente no existe'; END IF;
    PERFORM public.exigir_dato_prueba(v_cl.es_prueba, 'el cliente ' || coalesce(v_cl.nombre_comercial, ''));
    v_prueba := v_cl.es_prueba;
  END IF;

  INSERT INTO public.flujo_dinero
    (tipo, monto, moneda, tipo_cambio, metodo_pago, fecha, contraparte_nombre, cliente_id, concepto, referencia, es_prueba,
     recibido_por, requiere_comprobacion, intermediario_nombre, categoria, descripcion, contraparte_tipo, proveedor_id, empleado_id,
     via, intermediario_id, factura_folio, factura_uuid, factura_rfc, remision_id, cuenta_prevista_id, quien_recibio)
  VALUES
    (v_tipo, v_monto, v_moneda, CASE WHEN v_moneda = 'MXN' THEN NULL ELSE v_tc END, v_metodo::public.metodo_pago, v_fecha, v_nombre,
     CASE WHEN v_contra = 'CLIENTE' THEN v_cli END, v_concepto, nullif(btrim(coalesce(_datos->>'referencia', '')), ''), v_prueba,
     auth.uid(), (v_tipo = 'SALIDA' AND v_metodo = 'EFECTIVO' AND v_via = 'INTERMEDIARIO'), v_inter,
     nullif(btrim(coalesce(_datos->>'categoria', '')), ''), nullif(btrim(coalesce(_datos->>'descripcion', '')), ''), v_contra,
     CASE WHEN v_contra = 'PROVEEDOR' THEN v_prov END, CASE WHEN v_contra = 'EMPLEADO' THEN v_emp END,
     v_via, v_inter_id, nullif(btrim(coalesce(_datos->>'factura_folio', '')), ''), nullif(btrim(coalesce(_datos->>'factura_uuid', '')), ''),
     nullif(btrim(coalesce(_datos->>'factura_rfc', '')), ''), nullif(_datos->>'remision_id', '')::uuid, v_cuenta,
     nullif(_datos->>'recibido_por', '')::uuid)
  RETURNING id, folio INTO v_id, v_folio;

  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_registrar_movimiento', 'flujo_dinero', v_id, v_folio,
    jsonb_build_object('tipo', v_tipo, 'monto', v_monto, 'moneda', v_moneda, 'cuenta_prevista', v_cuenta), v_prueba);
  RETURN jsonb_build_object('id', v_id, 'folio', v_folio);
END;
$$;

REVOKE ALL ON FUNCTION public.flujo_registrar_movimiento(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_registrar_movimiento(jsonb) TO authenticated;

DO $postflight$
BEGIN
  IF position('_flujo_movimiento_pendiente' in pg_get_functiondef('public._flujo_a_cobranza()'::regprocedure)) = 0 THEN
    RAISE EXCEPTION '_flujo_a_cobranza no quedó creando el movimiento por confirmar.';
  END IF;
  IF position($q$v_tipo := 'PAGO_CLIENTE'$q$ in pg_get_functiondef('public.flujo_registrar_movimiento(jsonb)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'flujo_registrar_movimiento no quedó convirtiendo el pago de cliente.';
  END IF;
  IF has_function_privilege('anon', 'public.flujo_registrar_movimiento(jsonb)', 'execute') THEN
    RAISE EXCEPTION 'flujo_registrar_movimiento no debe estar abierta a anon.';
  END IF;
END $postflight$;

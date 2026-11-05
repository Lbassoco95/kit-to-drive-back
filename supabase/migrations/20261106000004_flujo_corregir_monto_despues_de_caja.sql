-- ============================================================================
-- Flujo de dinero: el monto se puede corregir también después de caja (2026-11-06)
--
-- Pedido de Martín: «al corregir un ingreso o egreso ya registrado necesito poder cambiar el monto».
-- Antes de caja ya se podía (quien lo registró o un administrador). Ahora un ADMINISTRADOR DEL FLUJO
-- también lo cambia cuando ya entró a caja o se aplicó, con motivo y con estas protecciones:
--   · se actualiza el movimiento confirmado de Control Financiero (el saldo de la cuenta se ajusta);
--   · si es un pago de cliente que nació en el flujo y aún no se aplica, el pago de Cobranza se revierte
--     («Corrección de FD-…») y nace el nuevo ya validado, con el monto bueno;
--   · NO se cambia si ya está aplicado a remisiones o saldo a favor (primero se revierte esa aplicación),
--     ni si ya está comprobado (la comprobación depende del monto);
--   · la moneda, la forma de pago, la fecha, el cliente y la cuenta siguen sin cambiar después de caja
--     (se rechaza y se vuelve a registrar).
-- La bitácora guarda el antes y el después. Solo redefine flujo_corregir.
-- Idempotente. Para el SQL editor de Supabase; NO usar `supabase db push`.
-- Para revertir: volver a flujo_corregir de 20261106000003.
-- ============================================================================

DO $preflight$
BEGIN
  IF to_regprocedure('public.flujo_corregir(uuid,jsonb,text)') IS NULL THEN
    RAISE EXCEPTION 'No se modificó nada. Falta flujo_corregir (20261106000003).';
  END IF;
END;
$preflight$;

CREATE OR REPLACE FUNCTION public.flujo_corregir(_id uuid, _datos jsonb, _motivo text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  f public.flujo_dinero%ROWTYPE;
  n public.flujo_dinero%ROWTYPE;
  v_admin boolean := public.flujo_es_admin();
  v_dueno boolean;
  v_pago public.cobranza_pagos%ROWTYPE;
  v_cta public.cuentas_financieras%ROWTYPE;
  v_cl public.clientes%ROWTYPE;
  v_folio text;
  v_nuevo uuid;
  v_dinero_cambia boolean;
  v_monto_cambia boolean;
  v_pago_cambia boolean;
  v_antes jsonb;
  v_despues jsonb;
  v_contra text;
  v_via text;
BEGIN
  IF length(btrim(coalesce(_motivo, ''))) < 3 THEN RAISE EXCEPTION 'Escribe el motivo de la corrección'; END IF;
  IF _datos IS NULL OR jsonb_typeof(_datos) <> 'object' THEN RAISE EXCEPTION 'No hay datos que corregir'; END IF;
  SELECT * INTO f FROM public.flujo_dinero WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el movimiento'; END IF;
  PERFORM public.exigir_dato_prueba(f.es_prueba, 'el movimiento ' || f.folio);
  IF f.etapa = 'RECHAZADO' THEN RAISE EXCEPTION '% está rechazado: ya no se corrige (se registra de nuevo)', f.folio; END IF;
  IF f.cxc_abono_id IS NOT NULL THEN RAISE EXCEPTION '% es un abono de Crédito: se corrige en Crédito', f.folio; END IF;
  IF f.cobranza_pago_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.cobranza_pagos p WHERE p.id = f.cobranza_pago_id AND p.notas LIKE 'Flujo de dinero %') THEN
    RAISE EXCEPTION '% viene de Cobranza: se corrige en Cobranza', f.folio;
  END IF;
  v_dueno := (f.recibido_por = auth.uid() AND public.flujo_cap('recibe') AND f.etapa = 'RECIBIDO');
  IF NOT (v_dueno OR v_admin) THEN
    RAISE EXCEPTION 'Solo quien lo registró (mientras no entre a caja) o un administrador del flujo corrige este movimiento';
  END IF;

  n := f;
  -- Datos descriptivos (se pueden corregir en cualquier etapa no rechazada).
  IF _datos ? 'concepto' THEN n.concepto := nullif(btrim(coalesce(_datos->>'concepto', '')), ''); END IF;
  IF _datos ? 'categoria' THEN n.categoria := nullif(btrim(coalesce(_datos->>'categoria', '')), ''); END IF;
  IF _datos ? 'descripcion' THEN n.descripcion := nullif(btrim(coalesce(_datos->>'descripcion', '')), ''); END IF;
  IF _datos ? 'referencia' THEN n.referencia := nullif(btrim(coalesce(_datos->>'referencia', '')), ''); END IF;
  IF _datos ? 'contraparte_nombre' THEN n.contraparte_nombre := nullif(btrim(coalesce(_datos->>'contraparte_nombre', '')), ''); END IF;
  IF _datos ? 'factura_folio' THEN n.factura_folio := nullif(btrim(coalesce(_datos->>'factura_folio', '')), ''); END IF;
  IF _datos ? 'factura_uuid' THEN n.factura_uuid := nullif(btrim(coalesce(_datos->>'factura_uuid', '')), ''); END IF;
  IF _datos ? 'factura_rfc' THEN n.factura_rfc := nullif(btrim(coalesce(_datos->>'factura_rfc', '')), ''); END IF;
  IF _datos ? 'recibido_por' THEN n.quien_recibio := nullif(_datos->>'recibido_por', '')::uuid; END IF;
  IF _datos ? 'remision_id' THEN n.remision_id := nullif(_datos->>'remision_id', '')::uuid; END IF;
  IF _datos ? 'categoria' AND n.categoria IS NOT NULL AND length(n.categoria) > 120 THEN RAISE EXCEPTION 'La categoría es demasiado larga'; END IF;
  -- Datos del dinero y de la contraparte (solo mientras está «Recibido»).
  IF _datos ? 'monto' THEN n.monto := round(nullif(_datos->>'monto', '')::numeric, 2); END IF;
  IF _datos ? 'moneda' THEN n.moneda := coalesce(nullif(btrim(coalesce(_datos->>'moneda', '')), ''), 'MXN'); END IF;
  IF _datos ? 'tipo_cambio' THEN n.tipo_cambio := nullif(_datos->>'tipo_cambio', '')::numeric; END IF;
  IF _datos ? 'metodo_pago' THEN n.metodo_pago := (_datos->>'metodo_pago')::public.metodo_pago; END IF;
  IF _datos ? 'fecha_movimiento' THEN n.fecha := (_datos->>'fecha_movimiento')::date; END IF;
  IF _datos ? 'contraparte_tipo' THEN n.contraparte_tipo := nullif(_datos->>'contraparte_tipo', ''); END IF;
  IF _datos ? 'cliente_id' THEN n.cliente_id := nullif(_datos->>'cliente_id', '')::uuid; END IF;
  IF _datos ? 'proveedor_id' THEN n.proveedor_id := nullif(_datos->>'proveedor_id', '')::uuid; END IF;
  IF _datos ? 'empleado_id' THEN n.empleado_id := nullif(_datos->>'empleado_id', '')::uuid; END IF;
  IF _datos ? 'cuenta_id' THEN n.cuenta_prevista_id := nullif(_datos->>'cuenta_id', '')::uuid; END IF;
  IF _datos ? 'via' THEN n.via := coalesce(nullif(_datos->>'via', ''), 'DIRECTO'); END IF;
  IF _datos ? 'intermediario_id' THEN n.intermediario_id := nullif(_datos->>'intermediario_id', '')::uuid; END IF;
  IF _datos ? 'intermediario_nombre' THEN n.intermediario_nombre := nullif(btrim(coalesce(_datos->>'intermediario_nombre', '')), ''); END IF;

  v_dinero_cambia := (n.moneda, n.tipo_cambio, n.metodo_pago, n.fecha, n.cliente_id, n.contraparte_tipo, n.proveedor_id, n.empleado_id, n.cuenta_prevista_id, n.via, n.intermediario_id, n.intermediario_nombre)
                     IS DISTINCT FROM (f.moneda, f.tipo_cambio, f.metodo_pago, f.fecha, f.cliente_id, f.contraparte_tipo, f.proveedor_id, f.empleado_id, f.cuenta_prevista_id, f.via, f.intermediario_id, f.intermediario_nombre);
  v_monto_cambia := n.monto IS DISTINCT FROM f.monto;
  IF v_dinero_cambia AND f.etapa <> 'RECIBIDO' THEN
    RAISE EXCEPTION '% ya entró a caja: la moneda, la forma de pago, la fecha, el cliente y la cuenta ya no se corrigen aquí. Recházalo con motivo y regístralo de nuevo.', f.folio;
  END IF;
  -- El monto sí se corrige después de caja, pero solo un administrador y mientras nada dependa de él.
  IF v_monto_cambia AND f.etapa <> 'RECIBIDO' THEN
    IF NOT v_admin THEN RAISE EXCEPTION 'Después de caja solo un administrador del flujo corrige el monto'; END IF;
    IF f.comprobado THEN RAISE EXCEPTION '% ya está comprobado: su monto no se corrige (lo comprobado y el cambio devuelto dependen de él)', f.folio; END IF;
    IF f.tipo = 'PAGO_CLIENTE' AND (f.etapa = 'APLICADO'
       OR EXISTS (SELECT 1 FROM public.cobranza_aplicaciones a WHERE a.pago_id = f.cobranza_pago_id AND a.revertida_at IS NULL)
       OR EXISTS (SELECT 1 FROM public.cobranza_saldos_favor sf WHERE sf.pago_origen_id = f.cobranza_pago_id AND sf.cancelado_at IS NULL)) THEN
      RAISE EXCEPTION '% ya está aplicado a remisiones o saldo a favor: revierte esa aplicación y vuelve a aplicarlo antes de cambiar el monto', f.folio;
    END IF;
  END IF;

  IF n.monto IS NULL OR n.monto <= 0 THEN RAISE EXCEPTION 'El monto debe ser mayor a cero'; END IF;
  IF f.tipo <> 'PAGO_CLIENTE' AND n.concepto IS NULL THEN RAISE EXCEPTION 'El concepto es obligatorio'; END IF;
  IF n.contraparte_nombre IS NULL THEN RAISE EXCEPTION 'Indica quién entregó o recibe el dinero'; END IF;
  IF n.moneda <> 'MXN' AND (n.tipo_cambio IS NULL OR n.tipo_cambio <= 0) THEN RAISE EXCEPTION 'Captura el tipo de cambio para %', n.moneda; END IF;
  IF n.moneda = 'MXN' THEN n.tipo_cambio := NULL; END IF;
  v_contra := coalesce(n.contraparte_tipo, CASE WHEN n.cliente_id IS NULL THEN 'OTRO' ELSE 'CLIENTE' END);
  IF v_contra NOT IN ('CLIENTE', 'PROVEEDOR', 'EMPLEADO', 'OTRO') THEN RAISE EXCEPTION 'Contraparte inválida'; END IF;
  IF v_contra = 'CLIENTE' AND n.cliente_id IS NULL THEN RAISE EXCEPTION 'Elige el cliente'; END IF;
  IF v_contra = 'PROVEEDOR' AND n.proveedor_id IS NULL THEN RAISE EXCEPTION 'Elige el proveedor'; END IF;
  IF v_contra = 'EMPLEADO' AND n.empleado_id IS NULL THEN RAISE EXCEPTION 'Elige al empleado'; END IF;
  IF f.tipo = 'PAGO_CLIENTE' THEN
    IF n.cliente_id IS NULL THEN RAISE EXCEPTION 'Un pago de cliente lleva su cliente'; END IF;
    IF n.moneda <> 'MXN' OR n.metodo_pago::text NOT IN ('EFECTIVO', 'TRANSFERENCIA', 'DEPOSITO') THEN
      RAISE EXCEPTION 'Un pago de cliente se recibe en pesos, en efectivo, transferencia o depósito';
    END IF;
  END IF;
  v_via := coalesce(n.via, 'DIRECTO');
  IF v_via = 'INTERMEDIARIO' THEN
    IF n.intermediario_id IS NOT NULL AND n.intermediario_nombre IS NULL THEN n.intermediario_nombre := public.flujo_nombre(n.intermediario_id); END IF;
    IF n.intermediario_nombre IS NULL THEN RAISE EXCEPTION 'Indica quién lleva o trae el dinero'; END IF;
  ELSE
    n.intermediario_id := NULL; n.intermediario_nombre := NULL;
  END IF;
  n.requiere_comprobacion := (f.tipo = 'SALIDA' AND n.metodo_pago::text = 'EFECTIVO' AND v_via = 'INTERMEDIARIO' AND (f.requiere_comprobacion OR f.etapa = 'RECIBIDO'));
  IF f.comprobado THEN n.requiere_comprobacion := f.requiere_comprobacion; n.intermediario_nombre := f.intermediario_nombre; END IF;
  IF n.cuenta_prevista_id IS NOT NULL THEN
    SELECT * INTO v_cta FROM public.cuentas_financieras WHERE id = n.cuenta_prevista_id AND activo;
    IF NOT FOUND THEN RAISE EXCEPTION 'La caja o cuenta elegida no existe o está inactiva'; END IF;
    IF v_cta.moneda <> n.moneda THEN RAISE EXCEPTION '«%» maneja % y el movimiento está en %', v_cta.nombre, v_cta.moneda, n.moneda; END IF;
  END IF;
  IF n.cliente_id IS NOT NULL AND n.cliente_id IS DISTINCT FROM f.cliente_id THEN
    SELECT * INTO v_cl FROM public.clientes WHERE id = n.cliente_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'El cliente no existe'; END IF;
    PERFORM public.exigir_dato_prueba(v_cl.es_prueba, 'el cliente ' || coalesce(v_cl.nombre_comercial, ''));
  END IF;
  IF v_contra <> 'CLIENTE' AND f.tipo <> 'PAGO_CLIENTE' THEN n.cliente_id := NULL; END IF;
  IF v_contra <> 'PROVEEDOR' THEN n.proveedor_id := NULL; END IF;
  IF v_contra <> 'EMPLEADO' THEN n.empleado_id := NULL; END IF;

  v_antes := to_jsonb(f) - 'id' - 'created_at';
  v_despues := to_jsonb(n) - 'id' - 'created_at';
  IF v_antes = v_despues THEN RAISE EXCEPTION 'No hay ningún cambio que guardar'; END IF;

  UPDATE public.flujo_dinero SET
    monto = n.monto, moneda = n.moneda, tipo_cambio = n.tipo_cambio, metodo_pago = n.metodo_pago, fecha = n.fecha,
    contraparte_nombre = n.contraparte_nombre, cliente_id = n.cliente_id, concepto = n.concepto, referencia = n.referencia,
    categoria = n.categoria, descripcion = n.descripcion, contraparte_tipo = n.contraparte_tipo,
    proveedor_id = n.proveedor_id, empleado_id = n.empleado_id, via = n.via, intermediario_id = n.intermediario_id,
    intermediario_nombre = n.intermediario_nombre, requiere_comprobacion = n.requiere_comprobacion,
    factura_folio = n.factura_folio, factura_uuid = n.factura_uuid, factura_rfc = n.factura_rfc,
    remision_id = n.remision_id, cuenta_prevista_id = n.cuenta_prevista_id, quien_recibio = n.quien_recibio,
    corregido_por = auth.uid(), corregido_at = now(), correccion_motivo = btrim(_motivo)
  WHERE id = f.id;

  -- Control Financiero: el ingreso/egreso ligado se corrige igual (por confirmar: todo; confirmado: lo descriptivo).
  IF f.movimiento_id IS NOT NULL THEN
    PERFORM set_config('kit.flujo_escribe', 'on', true);
    IF f.etapa = 'RECIBIDO' THEN
      UPDATE public.movimientos_financieros SET
        concepto = coalesce(n.concepto, concepto), categoria = n.categoria, descripcion = coalesce(n.descripcion, 'Flujo de dinero ' || f.folio),
        monto = n.monto, moneda = n.moneda, tipo_cambio = n.tipo_cambio, fecha_movimiento = n.fecha, metodo_pago = n.metodo_pago,
        referencia = n.referencia, contraparte_tipo = v_contra::public.contraparte_tipo, cliente_id = n.cliente_id,
        proveedor_id = n.proveedor_id, empleado_id = n.empleado_id, contraparte_nombre = n.contraparte_nombre,
        recibido_por = coalesce(n.quien_recibio, f.recibido_por),
        via = CASE WHEN n.requiere_comprobacion OR v_via = 'INTERMEDIARIO' THEN 'INTERMEDIARIO'::public.mov_via ELSE 'DIRECTO'::public.mov_via END,
        intermediario_id = n.intermediario_id,
        intermediario_nombre = CASE WHEN n.requiere_comprobacion OR v_via = 'INTERMEDIARIO' THEN n.intermediario_nombre END,
        factura_folio = n.factura_folio, factura_uuid = n.factura_uuid, factura_rfc = n.factura_rfc, remision_id = n.remision_id
      WHERE id = f.movimiento_id AND estatus = 'PENDIENTE';
    ELSE
      UPDATE public.movimientos_financieros SET
        monto = n.monto,
        concepto = coalesce(n.concepto, concepto), categoria = n.categoria, descripcion = coalesce(n.descripcion, descripcion),
        referencia = n.referencia, contraparte_nombre = n.contraparte_nombre,
        recibido_por = coalesce(n.quien_recibio, recibido_por),
        factura_folio = n.factura_folio, factura_uuid = n.factura_uuid, factura_rfc = n.factura_rfc, remision_id = n.remision_id
      WHERE id = f.movimiento_id AND estatus <> 'CANCELADO';
    END IF;
    PERFORM set_config('kit.flujo_escribe', '', true);
  END IF;

  -- Cobranza: el pago que nació del flujo. Cobranza no edita pagos: si cambia algo que un pago no admite, se revierte y nace el nuevo.
  IF f.cobranza_pago_id IS NOT NULL AND (f.etapa = 'RECIBIDO' OR v_monto_cambia) THEN
    SELECT * INTO v_pago FROM public.cobranza_pagos WHERE id = f.cobranza_pago_id;
    v_pago_cambia := (n.monto, n.fecha, n.cliente_id, n.metodo_pago) IS DISTINCT FROM (f.monto, f.fecha, f.cliente_id, f.metodo_pago);
    PERFORM set_config('kit.flujo_sincroniza', 'on', true);
    IF v_pago_cambia AND v_pago.estatus IN ('registrado', 'validado') THEN
      UPDATE public.cobranza_pagos
         SET estatus = 'revertido', revertido_por = auth.uid(), revertido_at = now(),
             motivo_reversion = 'Corrección de ' || f.folio || ': ' || btrim(_motivo)
       WHERE id = v_pago.id;
      v_folio := public._siguiente_folio_compras('CP', f.es_prueba);
      INSERT INTO public.cobranza_pagos (folio, cliente_id, fecha, monto, forma, cuenta_destino, referencia, notas, estatus, conciliado,
                                         capturado_por, validado_por, validado_at, es_prueba)
      VALUES (v_folio, n.cliente_id, n.fecha, n.monto,
              CASE lower(n.metodo_pago::text) WHEN 'efectivo' THEN 'efectivo' WHEN 'deposito' THEN 'deposito' ELSE 'transferencia' END,
              v_pago.cuenta_destino, n.referencia, 'Flujo de dinero ' || f.folio, v_pago.estatus, v_pago.estatus = 'validado',
              f.recibido_por, v_pago.validado_por, v_pago.validado_at, f.es_prueba)
      RETURNING id INTO v_nuevo;
      UPDATE public.flujo_dinero SET cobranza_pago_id = v_nuevo WHERE id = f.id;
    ELSIF n.referencia IS DISTINCT FROM f.referencia AND v_pago.estatus = 'registrado' THEN
      UPDATE public.cobranza_pagos SET referencia = n.referencia WHERE id = v_pago.id;
    END IF;
    PERFORM set_config('kit.flujo_sincroniza', '', true);
  END IF;

  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_corregir', 'flujo_dinero', f.id, f.folio,
    jsonb_build_object('motivo', btrim(_motivo), 'antes', v_antes, 'despues', v_despues, 'por_admin', v_admin AND NOT v_dueno), f.es_prueba);
  RETURN jsonb_build_object('folio', f.folio, 'pago_nuevo', v_folio);
END;
$$;
REVOKE ALL ON FUNCTION public.flujo_corregir(uuid, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_corregir(uuid, jsonb, text) TO authenticated;

DO $postflight$
BEGIN
  IF position('v_monto_cambia' in pg_get_functiondef('public.flujo_corregir(uuid,jsonb,text)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'flujo_corregir no quedó con la corrección de monto.';
  END IF;
  IF has_function_privilege('anon', 'public.flujo_corregir(uuid,jsonb,text)', 'execute') THEN
    RAISE EXCEPTION 'flujo_corregir no debe estar abierta a anon.';
  END IF;
END $postflight$;

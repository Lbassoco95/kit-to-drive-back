-- ============================================================================
-- Flujo de dinero: regla de cuenta por método de pago (PROPUESTA, sin aplicar)
--
--   · Efectivo           → solo en cuentas de efectivo.
--   · Transferencia y depósito → solo en cuentas de banco.
--   · La moneda ya se exigía igual (una caja de efectivo en MXN recibe MXN).
--   · Otros métodos (cheque, tarjeta, compensación, otro) no se restringen.
--
-- Criterio (opción A): transferencias y depósitos los captura Recibe, los
-- confirma Caja contra el banco y los aplica Aplica. La regla vive en la etapa
-- de Caja (ahí se elige la cuenta); el mensaje sale en español y chino.
--
-- Solo redefine flujo_confirmar_caja (copia de producción + la regla).
-- Idempotente. Para el SQL editor de Supabase; NO usar `supabase db push`.
-- ============================================================================

DO $preflight$
BEGIN
  IF to_regprocedure('public.flujo_confirmar_caja(uuid,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'No se modificó nada. Falta flujo_confirmar_caja (20261012000001_flujo_dinero_tres_etapas).';
  END IF;
END $preflight$;

CREATE OR REPLACE FUNCTION public.flujo_confirmar_caja(_id uuid, _cuenta_id uuid, _notas text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  f public.flujo_dinero%ROWTYPE;
  c public.cuentas_financieras%ROWTYPE;
  v_mov uuid;
BEGIN
  IF NOT public.flujo_cap('caja') THEN RAISE EXCEPTION 'No tienes asignada la etapa de caja'; END IF;
  SELECT * INTO f FROM public.flujo_dinero WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el movimiento'; END IF;
  PERFORM public.exigir_dato_prueba(f.es_prueba, 'el movimiento ' || f.folio);
  IF f.etapa <> 'RECIBIDO' THEN RAISE EXCEPTION '% no está pendiente de caja (etapa: %)', f.folio, f.etapa; END IF;
  IF f.recibido_por = auth.uid() THEN
    RAISE EXCEPTION 'Quien recibió el dinero no puede registrarlo en caja: lo hace otra persona';
  END IF;
  SELECT * INTO c FROM public.cuentas_financieras WHERE id = _cuenta_id AND activo;
  IF NOT FOUND THEN RAISE EXCEPTION 'Elige una caja o cuenta válida'; END IF;
  IF c.moneda <> f.moneda THEN RAISE EXCEPTION '«%» maneja % y el movimiento está en %', c.nombre, c.moneda, f.moneda; END IF;

  -- Regla de cuenta por método de pago.
  IF f.metodo_pago = 'EFECTIVO' AND c.tipo <> 'EFECTIVO' THEN
    RAISE EXCEPTION 'El efectivo solo se registra en una caja de efectivo; «%» es una cuenta de banco. / 现金只能登记在现金账户；“%”是银行账户。', c.nombre, c.nombre;
  END IF;
  IF f.metodo_pago IN ('TRANSFERENCIA', 'DEPOSITO') AND c.tipo <> 'BANCO' THEN
    RAISE EXCEPTION 'La transferencia y el depósito solo se registran en una cuenta de banco; «%» es una caja de efectivo. / 转账和存款只能登记在银行账户；“%”是现金账户。', c.nombre, c.nombre;
  END IF;

  IF NOT f.es_prueba THEN
  INSERT INTO public.movimientos_financieros
    (tipo, estatus, concepto, descripcion, monto, moneda, tipo_cambio, fecha_movimiento, metodo_pago, cuenta_id, referencia,
     contraparte_tipo, cliente_id, contraparte_nombre, recibido_por, created_by, confirmado_por, confirmado_at)
  VALUES
    (CASE WHEN f.tipo = 'SALIDA' THEN 'EGRESO'::public.mov_tipo ELSE 'INGRESO'::public.mov_tipo END, 'CONFIRMADO',
     coalesce(f.concepto, 'Pago de cliente ' || f.contraparte_nombre), 'Flujo de dinero ' || f.folio,
     f.monto, f.moneda, f.tipo_cambio, f.fecha, f.metodo_pago, c.id, f.referencia,
     CASE WHEN f.cliente_id IS NULL THEN 'OTRO'::public.contraparte_tipo ELSE 'CLIENTE'::public.contraparte_tipo END,
     f.cliente_id, f.contraparte_nombre, f.recibido_por, auth.uid(), auth.uid(), now())
  RETURNING id INTO v_mov;
  END IF;

  UPDATE public.flujo_dinero
     SET etapa = 'EN_CAJA', cuenta_id = c.id, caja_por = auth.uid(), caja_at = now(),
         caja_notas = nullif(btrim(coalesce(_notas, '')), ''), movimiento_id = v_mov
   WHERE id = f.id;
  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_caja', 'flujo_dinero', f.id, f.folio,
    jsonb_build_object('cuenta', c.nombre, 'movimiento_id', v_mov), f.es_prueba);
END;
$$;

REVOKE ALL ON FUNCTION public.flujo_confirmar_caja(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_confirmar_caja(uuid, uuid, text) TO authenticated;

DO $postflight$
BEGIN
  IF position('cuenta de banco' in pg_get_functiondef('public.flujo_confirmar_caja(uuid,uuid,text)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'La regla de cuenta por método no quedó en flujo_confirmar_caja.';
  END IF;
  IF has_function_privilege('anon', 'public.flujo_confirmar_caja(uuid,uuid,text)', 'execute') THEN
    RAISE EXCEPTION 'flujo_confirmar_caja no debe estar abierta a anon.';
  END IF;
END $postflight$;

SELECT 'regla_cuenta_por_metodo' AS script,
       position('cuenta de banco' in pg_get_functiondef('public.flujo_confirmar_caja(uuid,uuid,text)'::regprocedure)) > 0 AS aplicada;

-- ============================================================================
-- Control Financiero muestra desde el registro el ingreso «por confirmar» (2026-11-04)
--
-- Un pago de cliente registrado en el Flujo de dinero (dinero real, no de prueba, MXN)
-- crea de inmediato su ingreso en Control Financiero con estatus PENDIENTE («Por
-- confirmar»), sin cuenta y SIN mover ningún saldo (los saldos solo cuentan lo CONFIRMADO).
--   · Entra a caja  → el mismo ingreso pasa a CONFIRMADO y toma la caja/cuenta elegida.
--   · Se rechaza    → el ingreso se cancela (flujo_rechazar ya lo hacía con movimiento_id).
-- flujo_confirmar_caja confirma el ingreso existente en vez de crear otro (si no existiera,
-- lo crea como antes). Solo pagos que nacen en el flujo; abonos de Crédito y pagos de
-- Cobranza siguen entrando a Control Financiero como hasta ahora.
--
-- Idempotente. Para el SQL editor de Supabase; NO usar `supabase db push`.
-- Para revertir: volver a _flujo_a_cobranza (20261104000001) y a flujo_confirmar_caja (20261103000005).
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := '{}';
BEGIN
  IF to_regprocedure('public._flujo_a_cobranza()') IS NULL THEN _faltan := _faltan || 'función _flujo_a_cobranza (20261104000001)'::text; END IF;
  IF to_regprocedure('public._candado_movimientos_solo_flujo()') IS NULL THEN _faltan := _faltan || 'candado (20261103000004)'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='flujo_dinero' AND column_name='requiere_comprobacion') THEN
    _faltan := _faltan || 'columna flujo_dinero.requiere_comprobacion (20261103000005)'::text;
  END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ', ');
  END IF;
END;
$preflight$;

-- ── 1. El ingreso nace «por confirmar» al registrar el pago en el flujo ─────
CREATE OR REPLACE FUNCTION public._flujo_a_cobranza()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_pago uuid;
  v_folio text;
  v_cta text;
  v_mov uuid;
BEGIN
  IF NEW.tipo <> 'PAGO_CLIENTE' OR NEW.cliente_id IS NULL OR NEW.cxc_abono_id IS NOT NULL THEN RETURN NULL; END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.etapa <> 'RECIBIDO' OR NEW.cobranza_pago_id IS NOT NULL THEN RETURN NULL; END IF;
    v_folio := public._siguiente_folio_compras('CP', NEW.es_prueba);
    PERFORM set_config('kit.flujo_sincroniza', 'on', true);
    INSERT INTO public.cobranza_pagos (folio, cliente_id, fecha, monto, forma, referencia, notas, estatus,
                                       conciliado, capturado_por, es_prueba)
    VALUES (v_folio, NEW.cliente_id, NEW.fecha, NEW.monto,
            CASE lower(NEW.metodo_pago::text) WHEN 'efectivo' THEN 'efectivo' WHEN 'deposito' THEN 'deposito' ELSE 'transferencia' END,
            NEW.referencia, 'Flujo de dinero ' || NEW.folio, 'registrado', false, NEW.recibido_por, NEW.es_prueba)
    RETURNING id INTO v_pago;
    PERFORM set_config('kit.flujo_sincroniza', '', true);

    -- Control Financiero: ingreso «por confirmar» (sin cuenta, no mueve saldos). Los datos de prueba no lo generan.
    IF NOT NEW.es_prueba AND NEW.moneda = 'MXN' THEN
      PERFORM set_config('kit.flujo_escribe', 'on', true);
      INSERT INTO public.movimientos_financieros
        (tipo, estatus, concepto, descripcion, monto, moneda, tipo_cambio, fecha_movimiento, metodo_pago, referencia,
         contraparte_tipo, cliente_id, contraparte_nombre, recibido_por, created_by)
      VALUES
        ('INGRESO'::public.mov_tipo, 'PENDIENTE', coalesce(NEW.concepto, 'Pago de cliente ' || NEW.contraparte_nombre),
         'Flujo de dinero ' || NEW.folio || ' (por confirmar en caja)', NEW.monto, NEW.moneda, NEW.tipo_cambio, NEW.fecha,
         NEW.metodo_pago, NEW.referencia, 'CLIENTE'::public.contraparte_tipo, NEW.cliente_id, NEW.contraparte_nombre,
         NEW.recibido_por, coalesce(auth.uid(), NEW.recibido_por))
      RETURNING id INTO v_mov;
      PERFORM set_config('kit.flujo_escribe', '', true);
    END IF;

    UPDATE public.flujo_dinero SET cobranza_pago_id = v_pago, movimiento_id = coalesce(v_mov, movimiento_id) WHERE id = NEW.id;
    RETURN NULL;
  END IF;

  IF NEW.cobranza_pago_id IS NULL OR NEW.etapa IS NOT DISTINCT FROM OLD.etapa THEN RETURN NULL; END IF;
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

-- ── 2. Caja confirma el ingreso que ya estaba por confirmar ─────────────────
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

  IF f.metodo_pago = 'EFECTIVO' AND c.tipo <> 'EFECTIVO' THEN
    RAISE EXCEPTION 'El efectivo solo se registra en una caja de efectivo; «%» es una cuenta de banco. / 现金只能登记在现金账户；“%”是银行账户。', c.nombre, c.nombre;
  END IF;
  IF f.metodo_pago IN ('TRANSFERENCIA', 'DEPOSITO') AND c.tipo <> 'BANCO' THEN
    RAISE EXCEPTION 'La transferencia y el depósito solo se registran en una cuenta de banco; «%» es una caja de efectivo. / 转账和存款只能登记在银行账户；“%”是现金账户。', c.nombre, c.nombre;
  END IF;

  IF NOT f.es_prueba THEN
  PERFORM set_config('kit.flujo_escribe', 'on', true);
  IF f.movimiento_id IS NOT NULL THEN
    -- El ingreso ya estaba en Control Financiero «por confirmar»: con caja se confirma y toma su cuenta.
    UPDATE public.movimientos_financieros
       SET estatus = 'CONFIRMADO', cuenta_id = c.id, confirmado_por = auth.uid(), confirmado_at = now(),
           concepto = coalesce(f.concepto, 'Pago de cliente ' || f.contraparte_nombre)
     WHERE id = f.movimiento_id AND estatus = 'PENDIENTE';
    v_mov := f.movimiento_id;
  ELSE
  INSERT INTO public.movimientos_financieros
    (tipo, estatus, concepto, descripcion, monto, moneda, tipo_cambio, fecha_movimiento, metodo_pago, cuenta_id, referencia,
     contraparte_tipo, cliente_id, contraparte_nombre, recibido_por, created_by, confirmado_por, confirmado_at,
     via, intermediario_nombre)
  VALUES
    (CASE WHEN f.tipo = 'SALIDA' THEN 'EGRESO'::public.mov_tipo ELSE 'INGRESO'::public.mov_tipo END, 'CONFIRMADO',
     coalesce(f.concepto, 'Pago de cliente ' || f.contraparte_nombre), 'Flujo de dinero ' || f.folio,
     f.monto, f.moneda, f.tipo_cambio, f.fecha, f.metodo_pago, c.id, f.referencia,
     CASE WHEN f.cliente_id IS NULL THEN 'OTRO'::public.contraparte_tipo ELSE 'CLIENTE'::public.contraparte_tipo END,
     f.cliente_id, f.contraparte_nombre, f.recibido_por, auth.uid(), auth.uid(), now(),
     CASE WHEN f.requiere_comprobacion THEN 'INTERMEDIARIO'::public.mov_via ELSE 'DIRECTO'::public.mov_via END,
     CASE WHEN f.requiere_comprobacion THEN f.intermediario_nombre END)
  RETURNING id INTO v_mov;
  END IF;
  PERFORM set_config('kit.flujo_escribe', '', true);
  END IF;

  IF f.cxc_abono_id IS NOT NULL THEN
    -- Abono de Crédito: ya bajó el saldo de la cuenta por cobrar; con caja queda aplicado.
    UPDATE public.flujo_dinero
       SET etapa = 'APLICADO', cuenta_id = c.id, caja_por = auth.uid(), caja_at = now(),
           caja_notas = nullif(btrim(coalesce(_notas, '')), ''), movimiento_id = v_mov,
           destino = 'OTRO', aplicado_por = auth.uid(), aplicado_at = now(),
           aplicado_notas = 'Abono a cuenta por cobrar (ya aplicado en Crédito)'
     WHERE id = f.id;
    UPDATE public.cxc_abonos SET movimiento_id = v_mov WHERE id = f.cxc_abono_id AND v_mov IS NOT NULL;
  ELSE
    UPDATE public.flujo_dinero
       SET etapa = 'EN_CAJA', cuenta_id = c.id, caja_por = auth.uid(), caja_at = now(),
           caja_notas = nullif(btrim(coalesce(_notas, '')), ''), movimiento_id = v_mov
     WHERE id = f.id;
  END IF;
  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_caja', 'flujo_dinero', f.id, f.folio,
    jsonb_build_object('cuenta', c.nombre, 'movimiento_id', v_mov), f.es_prueba);
END;
$$;
REVOKE ALL ON FUNCTION public.flujo_confirmar_caja(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_confirmar_caja(uuid, uuid, text) TO authenticated;

DO $postflight$
BEGIN
  IF position($q$estatus = 'PENDIENTE'$q$ in pg_get_functiondef('public.flujo_confirmar_caja(uuid,uuid,text)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'flujo_confirmar_caja no quedó confirmando el ingreso por confirmar.';
  END IF;
  IF has_function_privilege('anon', 'public.flujo_confirmar_caja(uuid,uuid,text)', 'execute') THEN
    RAISE EXCEPTION 'flujo_confirmar_caja no debe estar abierta a anon.';
  END IF;
END $postflight$;

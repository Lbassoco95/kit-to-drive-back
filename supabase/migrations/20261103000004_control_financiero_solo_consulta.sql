-- ============================================================================
-- Control Financiero es solo de consulta: el efectivo nace y se modifica solo
-- en el Flujo de dinero (2026-11-03)
--
-- Decisión de Polo/Martín: ingresos y egresos ya no se registran, editan,
-- confirman, cancelan ni eliminan en Control Financiero. Todo movimiento de
-- efectivo (ingreso o egreso) nace en el Flujo de dinero —directo, al aplicar o
-- registrar un pago en Cobranza, o al abonar en Crédito— y Control Financiero lo
-- muestra.
--
-- Candado en la base (no solo en la pantalla): movimientos_financieros no acepta
-- INSERT, DELETE ni UPDATE de datos de dinero salvo que lo haga una función del
-- flujo (flujo_confirmar_caja, flujo_rechazar o el espejo de Cobranza/Crédito),
-- que abren el candado dentro de su propia transacción. Siguen permitidos:
--   · cambios de los campos de factura (tiene_factura, factura_*), que mantiene
--     el expediente de documentos;
--   · el SQL editor / mantenimiento (sin usuario de sesión).
-- Un usuario, aunque sea administrador, recibe un mensaje claro.
--
-- Se redefinen con la llave del candado: flujo_confirmar_caja, flujo_rechazar y
-- _espejo_flujo_sincronizar (idénticas a las ya probadas + la llave).
--
-- Idempotente. Para el SQL editor de Supabase; NO usar `supabase db push`.
-- Para revertir: DROP TRIGGER aaa_candado_solo_flujo ON public.movimientos_financieros;
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := '{}';
BEGIN
  IF to_regclass('public.movimientos_financieros') IS NULL THEN _faltan := _faltan || 'tabla movimientos_financieros'::text; END IF;
  IF to_regprocedure('public.flujo_confirmar_caja(uuid,uuid,text)') IS NULL THEN _faltan := _faltan || 'función flujo_confirmar_caja'::text; END IF;
  IF to_regprocedure('public.flujo_rechazar(uuid,text)') IS NULL THEN _faltan := _faltan || 'función flujo_rechazar'::text; END IF;
  IF to_regprocedure('public._espejo_flujo_sincronizar(uuid)') IS NULL THEN _faltan := _faltan || 'función _espejo_flujo_sincronizar (20261103000002)'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='flujo_dinero' AND column_name='cxc_abono_id') THEN
    _faltan := _faltan || 'columna flujo_dinero.cxc_abono_id (20261103000003)'::text;
  END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ', ');
  END IF;
END;
$preflight$;

-- ── 1. Las funciones del flujo abren el candado dentro de su transacción ────
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

CREATE OR REPLACE FUNCTION public.flujo_rechazar(_id uuid, _motivo text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE f public.flujo_dinero%ROWTYPE;
BEGIN
  IF length(btrim(coalesce(_motivo, ''))) < 3 THEN RAISE EXCEPTION 'El motivo del rechazo es obligatorio'; END IF;
  SELECT * INTO f FROM public.flujo_dinero WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el movimiento'; END IF;
  PERFORM public.exigir_dato_prueba(f.es_prueba, 'el movimiento ' || f.folio);
  IF f.etapa NOT IN ('RECIBIDO', 'EN_CAJA') THEN RAISE EXCEPTION '% ya no se puede rechazar (etapa: %)', f.folio, f.etapa; END IF;
  IF NOT ((f.etapa = 'RECIBIDO' AND public.flujo_cap('caja'))
       OR (f.etapa = 'EN_CAJA' AND (public.flujo_cap('aplica') OR public.flujo_cap('caja')))) THEN
    RAISE EXCEPTION 'No tienes permiso para rechazar en esta etapa';
  END IF;
  IF f.movimiento_id IS NOT NULL THEN
    PERFORM set_config('kit.flujo_escribe', 'on', true);
    UPDATE public.movimientos_financieros
       SET estatus = 'CANCELADO', cancelado_por = auth.uid(), cancelado_at = now(),
           motivo_cancelacion = 'Rechazado en el flujo de dinero ' || f.folio || ': ' || btrim(_motivo)
     WHERE id = f.movimiento_id;
    PERFORM set_config('kit.flujo_escribe', '', true);
  END IF;
  UPDATE public.flujo_dinero
     SET etapa = 'RECHAZADO', motivo_rechazo = btrim(_motivo), rechazado_por = auth.uid(), rechazado_at = now()
   WHERE id = f.id;
  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_rechazar', 'flujo_dinero', f.id, f.folio,
    jsonb_build_object('motivo', _motivo, 'etapa', f.etapa), f.es_prueba);
END;
$$;

CREATE OR REPLACE FUNCTION public._espejo_flujo_sincronizar(_pago_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p public.cobranza_pagos%ROWTYPE;
  f public.flujo_dinero%ROWTYPE;
  cli public.clientes%ROWTYPE;
  v_metodo public.metodo_pago;
  v_quien uuid;
  v_etapa text;
  v_disp numeric;
  v_hay_aplic boolean;
  v_cuenta uuid;
  v_mov uuid;
BEGIN
  SELECT * INTO p FROM public.cobranza_pagos WHERE id = _pago_id;
  IF NOT FOUND THEN RETURN; END IF;
  -- Datos de prueba no entran al flujo; los pagos que nacen del flujo ya tienen su renglón.
  IF p.es_prueba OR coalesce(p.notas, '') LIKE 'Flujo de dinero %' THEN RETURN; END IF;

  PERFORM set_config('kit.espejo_cobranza', 'on', true);

  SELECT * INTO f FROM public.flujo_dinero WHERE cobranza_pago_id = p.id;
  IF NOT FOUND THEN
    v_quien := coalesce(p.capturado_por, p.validado_por);
    IF v_quien IS NULL THEN RETURN; END IF;
    SELECT * INTO cli FROM public.clientes WHERE id = p.cliente_id;
    v_metodo := (CASE WHEN upper(p.forma) IN ('EFECTIVO', 'TRANSFERENCIA', 'CHEQUE', 'TARJETA', 'DEPOSITO', 'COMPENSACION')
                      THEN upper(p.forma) ELSE 'OTRO' END)::public.metodo_pago;
    INSERT INTO public.flujo_dinero (tipo, etapa, monto, moneda, metodo_pago, fecha, contraparte_nombre, cliente_id,
                                     concepto, referencia, es_prueba, recibido_por, recibido_at, cobranza_pago_id)
    VALUES ('PAGO_CLIENTE', 'RECIBIDO', p.monto, 'MXN', v_metodo, p.fecha,
            coalesce(cli.nombre_comercial, cli.razon_social, cli.codigo_erp, 'Cliente'), p.cliente_id,
            'Pago registrado en Cobranza ' || p.folio,
            coalesce(nullif(btrim(coalesce(p.referencia, '')), ''), p.folio), false, v_quien, p.created_at, p.id)
    RETURNING * INTO f;
  END IF;

  v_disp := coalesce(public.disponible_pago_cobranza(p.id), p.monto);
  v_hay_aplic := EXISTS (SELECT 1 FROM public.cobranza_aplicaciones a WHERE a.pago_id = p.id AND a.revertida_at IS NULL);
  v_etapa := CASE p.estatus
               WHEN 'revertido' THEN 'RECHAZADO'
               WHEN 'validado' THEN CASE WHEN v_disp <= 0 THEN 'APLICADO' ELSE 'EN_CAJA' END
               ELSE 'RECIBIDO'
             END;

  v_mov := f.movimiento_id;
  v_cuenta := f.cuenta_id;

  -- Entra a Control Financiero cuando Finanzas lo valida.
  IF v_etapa IN ('EN_CAJA', 'APLICADO') AND v_mov IS NULL THEN
    v_cuenta := public._espejo_cuenta_para_pago(p.cuenta_destino, p.forma);
    IF v_cuenta IS NOT NULL THEN
      PERFORM set_config('kit.flujo_escribe', 'on', true);
      INSERT INTO public.movimientos_financieros
        (tipo, estatus, concepto, descripcion, monto, moneda, fecha_movimiento, metodo_pago, cuenta_id, referencia,
         contraparte_tipo, cliente_id, contraparte_nombre, recibido_por, created_by, confirmado_por, confirmado_at)
      VALUES
        ('INGRESO'::public.mov_tipo, 'CONFIRMADO', 'Pago de cliente ' || f.contraparte_nombre,
         'Cobranza ' || p.folio || ' (flujo ' || f.folio || ')', p.monto, 'MXN', p.fecha, f.metodo_pago, v_cuenta, f.referencia,
         'CLIENTE'::public.contraparte_tipo, p.cliente_id, f.contraparte_nombre, f.recibido_por,
         coalesce(auth.uid(), p.validado_por, f.recibido_por), coalesce(auth.uid(), p.validado_por, f.recibido_por), now())
      RETURNING id INTO v_mov;
      PERFORM set_config('kit.flujo_escribe', '', true);
    END IF;
  END IF;

  -- Se revierte en Cobranza: el movimiento se cancela (no se borra).
  IF v_etapa = 'RECHAZADO' AND v_mov IS NOT NULL THEN
    PERFORM set_config('kit.flujo_escribe', 'on', true);
    UPDATE public.movimientos_financieros
       SET estatus = 'CANCELADO', cancelado_por = coalesce(auth.uid(), p.revertido_por), cancelado_at = now(),
           motivo_cancelacion = 'Pago ' || p.folio || ' revertido en Cobranza: ' || coalesce(p.motivo_reversion, '')
     WHERE id = v_mov AND estatus <> 'CANCELADO';
    PERFORM set_config('kit.flujo_escribe', '', true);
  END IF;

  UPDATE public.flujo_dinero SET
    etapa = v_etapa,
    cuenta_id = CASE WHEN v_etapa IN ('EN_CAJA', 'APLICADO') THEN coalesce(v_cuenta, cuenta_id) ELSE cuenta_id END,
    movimiento_id = v_mov,
    caja_por = CASE WHEN v_etapa IN ('EN_CAJA', 'APLICADO') THEN coalesce(caja_por, p.validado_por, p.capturado_por) ELSE caja_por END,
    caja_at = CASE WHEN v_etapa IN ('EN_CAJA', 'APLICADO') THEN coalesce(caja_at, p.validado_at, now()) ELSE caja_at END,
    caja_notas = CASE WHEN v_etapa IN ('EN_CAJA', 'APLICADO') THEN coalesce(caja_notas, 'Validado en Cobranza ' || p.folio) ELSE caja_notas END,
    destino = CASE WHEN v_etapa = 'APLICADO' THEN CASE WHEN v_hay_aplic THEN 'REMISION' ELSE 'OTRO' END ELSE NULL END,
    aplicado_por = CASE WHEN v_etapa = 'APLICADO' THEN coalesce(aplicado_por, auth.uid(), p.validado_por) ELSE NULL END,
    aplicado_at = CASE WHEN v_etapa = 'APLICADO' THEN coalesce(aplicado_at, now()) ELSE NULL END,
    aplicado_notas = CASE WHEN v_etapa = 'APLICADO' THEN coalesce(aplicado_notas, 'Aplicado en Cobranza ' || p.folio) ELSE NULL END,
    motivo_rechazo = CASE WHEN v_etapa = 'RECHAZADO' THEN coalesce(nullif(btrim(coalesce(p.motivo_reversion, '')), ''), 'Pago revertido en Cobranza') ELSE NULL END,
    rechazado_por = CASE WHEN v_etapa = 'RECHAZADO' THEN coalesce(rechazado_por, p.revertido_por, auth.uid()) ELSE NULL END,
    rechazado_at = CASE WHEN v_etapa = 'RECHAZADO' THEN coalesce(rechazado_at, p.revertido_at, now()) ELSE NULL END
  WHERE id = f.id
    AND (etapa IS DISTINCT FROM v_etapa OR movimiento_id IS DISTINCT FROM v_mov OR cuenta_id IS DISTINCT FROM v_cuenta);

  -- La marca vale solo mientras se sincroniza: no queda abierta para el resto de la transacción.
  PERFORM set_config('kit.espejo_cobranza', '', true);
END;
$$;

REVOKE ALL ON FUNCTION public.flujo_confirmar_caja(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_confirmar_caja(uuid, uuid, text) TO authenticated;
REVOKE ALL ON FUNCTION public.flujo_rechazar(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_rechazar(uuid, text) TO authenticated;
REVOKE ALL ON FUNCTION public._espejo_flujo_sincronizar(uuid) FROM PUBLIC, anon, authenticated;

-- ── 2. El candado ───────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._candado_movimientos_solo_flujo()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_libres text[] := ARRAY['tiene_factura', 'factura_folio', 'factura_uuid', 'factura_rfc', 'updated_at', 'monto_mxn'];
BEGIN
  -- SQL editor / mantenimiento: sin usuario de sesión.
  IF auth.uid() IS NULL THEN RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END; END IF;
  -- Las funciones del flujo abren el candado dentro de su propia transacción.
  IF coalesce(current_setting('kit.flujo_escribe', true), '') = 'on' THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  -- Campos de factura que mantiene el expediente de documentos.
  IF TG_OP = 'UPDATE' AND (to_jsonb(NEW) - v_libres) = (to_jsonb(OLD) - v_libres) THEN RETURN NEW; END IF;
  RAISE EXCEPTION 'Control Financiero es solo de consulta: los ingresos y egresos se registran, corrigen y rechazan en el Flujo de dinero. / 财务管控仅供查询：收入和支出请在资金流转中登记、更正和驳回。'
    USING ERRCODE = '42501';
END;
$$;
REVOKE ALL ON FUNCTION public._candado_movimientos_solo_flujo() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS aaa_candado_solo_flujo ON public.movimientos_financieros;
CREATE TRIGGER aaa_candado_solo_flujo BEFORE INSERT OR UPDATE OR DELETE ON public.movimientos_financieros
  FOR EACH ROW EXECUTE FUNCTION public._candado_movimientos_solo_flujo();

DO $postflight$
BEGIN
  IF position('flujo_escribe' in pg_get_functiondef('public.flujo_confirmar_caja(uuid,uuid,text)'::regprocedure)) = 0
     OR position('cuenta de banco' in pg_get_functiondef('public.flujo_confirmar_caja(uuid,uuid,text)'::regprocedure)) = 0
     OR position('cxc_abono_id' in pg_get_functiondef('public.flujo_confirmar_caja(uuid,uuid,text)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'flujo_confirmar_caja no quedó completa.';
  END IF;
  IF position('flujo_escribe' in pg_get_functiondef('public.flujo_rechazar(uuid,text)'::regprocedure)) = 0
     OR position('flujo_escribe' in pg_get_functiondef('public._espejo_flujo_sincronizar(uuid)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'Las funciones del flujo no quedaron con la llave del candado.';
  END IF;
  IF has_function_privilege('anon', 'public.flujo_confirmar_caja(uuid,uuid,text)', 'execute')
     OR has_function_privilege('anon', 'public.flujo_rechazar(uuid,text)', 'execute') THEN
    RAISE EXCEPTION 'Las funciones del flujo no deben estar abiertas a anon.';
  END IF;
END $postflight$;

-- ── Verificación (solo lectura) ─────────────────────────────────────────────
-- 1) SELECT tgname FROM pg_trigger WHERE tgname = 'aaa_candado_solo_flujo';
-- 2) Un usuario intentando INSERT/UPDATE/DELETE directo en movimientos_financieros recibe el aviso.

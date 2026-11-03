-- ============================================================================
-- Cobranza y Flujo de dinero son el mismo flujo (2026-11-03)
--
-- Pedido de Martín/Polo: «cuando registran en Cobranza es como si estuvieran
-- en Flujo de dinero». Hasta hoy el flujo creaba el pago de Cobranza al
-- aplicarlo (flujo → cobranza), pero un pago registrado directo en Cobranza no
-- aparecía en el flujo ni en Control Financiero.
--
-- Qué hace: cada pago de Cobranza (cobranza_pagos) tiene su renglón en
-- flujo_dinero, ligado por flujo_dinero.cobranza_pago_id, y se mantiene solo:
--
--   Cobranza                              Flujo de dinero
--   ─────────────────────────────────     ──────────────────────────────────
--   registrado                         →  RECIBIDO
--   validado (Finanzas)                →  EN_CAJA   (+ movimiento confirmado en
--                                                    Control Financiero)
--   validado y todo aplicado           →  APLICADO
--   revertido                          →  RECHAZADO (+ movimiento cancelado)
--
-- · Se hace con triggers sobre cobranza_pagos / cobranza_aplicaciones /
--   cobranza_saldos_favor: no se tocan las funciones de Cobranza ni del flujo,
--   así que cualquier camino (registrar, validar, aplicar, revertir) queda
--   cubierto.
-- · Los pagos que nacen del propio flujo (flujo_aplicar) NO se espejean: ya
--   tienen su renglón (nota «Flujo de dinero FD-…»). Sin duplicados.
-- · El movimiento de Control Financiero se crea al validar, en la caja de
--   efectivo (efectivo) o el banco (transferencia/depósito) de MXN. Si
--   cuenta_destino coincide con el nombre de una cuenta, se usa esa. Si no hay
--   una cuenta única, el renglón del flujo existe igual y el movimiento no se
--   inventa.
-- · Un renglón espejo solo cambia de etapa desde Cobranza: el flujo no puede
--   «confirmar caja», «aplicar» ni «rechazar» un pago que vive en Cobranza (lo
--   frena un trigger con un mensaje claro). Así no se duplica dinero.
-- · Datos de prueba (es_prueba) no se espejean.
-- · NO hay relleno de pagos anteriores: los que ya existen en Cobranza no
--   generan movimientos nuevos en Control Financiero (cambiaría saldos).
--
-- Idempotente. Para el SQL editor de Supabase; NO usar `supabase db push`.
-- Para revertir: DROP TRIGGER trg_espejo_flujo_pago ON public.cobranza_pagos;
--   DROP TRIGGER trg_espejo_flujo_aplic ON public.cobranza_aplicaciones;
--   DROP TRIGGER trg_espejo_flujo_saldo ON public.cobranza_saldos_favor;
--   DROP TRIGGER trg_flujo_espejo_guarda ON public.flujo_dinero;
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := '{}';
BEGIN
  IF to_regclass('public.flujo_dinero') IS NULL THEN _faltan := _faltan || 'tabla flujo_dinero'::text; END IF;
  IF to_regclass('public.cobranza_pagos') IS NULL THEN _faltan := _faltan || 'tabla cobranza_pagos'::text; END IF;
  IF to_regclass('public.cobranza_aplicaciones') IS NULL THEN _faltan := _faltan || 'tabla cobranza_aplicaciones'::text; END IF;
  IF to_regclass('public.cobranza_saldos_favor') IS NULL THEN _faltan := _faltan || 'tabla cobranza_saldos_favor'::text; END IF;
  IF to_regclass('public.movimientos_financieros') IS NULL THEN _faltan := _faltan || 'tabla movimientos_financieros'::text; END IF;
  IF to_regclass('public.cuentas_financieras') IS NULL THEN _faltan := _faltan || 'tabla cuentas_financieras'::text; END IF;
  IF to_regprocedure('public.disponible_pago_cobranza(uuid)') IS NULL THEN _faltan := _faltan || 'función disponible_pago_cobranza'::text; END IF;
  IF to_regprocedure('public.flujo_aplicar(uuid,text,jsonb,text)') IS NULL THEN _faltan := _faltan || 'función flujo_aplicar'::text; END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ', ');
  END IF;
END;
$preflight$;

-- ── Cuenta de Control Financiero para un pago de Cobranza ───────────────────
CREATE OR REPLACE FUNCTION public._espejo_cuenta_para_pago(_cuenta_destino text, _forma text)
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid; v_n integer; v_tipo text;
BEGIN
  IF nullif(btrim(coalesce(_cuenta_destino, '')), '') IS NOT NULL THEN
    SELECT id INTO v_id FROM public.cuentas_financieras
     WHERE activo AND moneda = 'MXN' AND lower(nombre) = lower(btrim(_cuenta_destino));
    IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  END IF;
  v_tipo := CASE lower(coalesce(_forma, '')) WHEN 'efectivo' THEN 'EFECTIVO' WHEN 'transferencia' THEN 'BANCO' WHEN 'deposito' THEN 'BANCO' END;
  IF v_tipo IS NULL THEN RETURN NULL; END IF;
  SELECT count(*), min(id::text)::uuid INTO v_n, v_id FROM public.cuentas_financieras
   WHERE activo AND moneda = 'MXN' AND tipo::text = v_tipo;
  RETURN CASE WHEN v_n = 1 THEN v_id END;
END;
$$;

-- ── Sincroniza el renglón del flujo con el estado del pago ──────────────────
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
      INSERT INTO public.movimientos_financieros
        (tipo, estatus, concepto, descripcion, monto, moneda, fecha_movimiento, metodo_pago, cuenta_id, referencia,
         contraparte_tipo, cliente_id, contraparte_nombre, recibido_por, created_by, confirmado_por, confirmado_at)
      VALUES
        ('INGRESO'::public.mov_tipo, 'CONFIRMADO', 'Pago de cliente ' || f.contraparte_nombre,
         'Cobranza ' || p.folio || ' (flujo ' || f.folio || ')', p.monto, 'MXN', p.fecha, f.metodo_pago, v_cuenta, f.referencia,
         'CLIENTE'::public.contraparte_tipo, p.cliente_id, f.contraparte_nombre, f.recibido_por,
         coalesce(auth.uid(), p.validado_por, f.recibido_por), coalesce(auth.uid(), p.validado_por, f.recibido_por), now())
      RETURNING id INTO v_mov;
    END IF;
  END IF;

  -- Se revierte en Cobranza: el movimiento se cancela (no se borra).
  IF v_etapa = 'RECHAZADO' AND v_mov IS NOT NULL THEN
    UPDATE public.movimientos_financieros
       SET estatus = 'CANCELADO', cancelado_por = coalesce(auth.uid(), p.revertido_por), cancelado_at = now(),
           motivo_cancelacion = 'Pago ' || p.folio || ' revertido en Cobranza: ' || coalesce(p.motivo_reversion, '')
     WHERE id = v_mov AND estatus <> 'CANCELADO';
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

CREATE OR REPLACE FUNCTION public._espejo_flujo_trg_pago()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- Un fallo del espejo nunca debe frenar a Cobranza: se avisa en el log y el pago sigue.
  BEGIN
    PERFORM public._espejo_flujo_sincronizar(NEW.id);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'espejo flujo (pago %): %', NEW.id, SQLERRM;
  END;
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public._espejo_flujo_trg_hijo()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_pago uuid;
BEGIN
  IF TG_TABLE_NAME = 'cobranza_saldos_favor' THEN
    IF TG_OP <> 'DELETE' THEN v_pago := NEW.pago_origen_id; ELSE v_pago := OLD.pago_origen_id; END IF;
  ELSE
    IF TG_OP <> 'DELETE' THEN v_pago := NEW.pago_id; ELSE v_pago := OLD.pago_id; END IF;
  END IF;
  IF v_pago IS NOT NULL THEN
    BEGIN
      PERFORM public._espejo_flujo_sincronizar(v_pago);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'espejo flujo (pago %): %', v_pago, SQLERRM;
    END;
  END IF;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_espejo_flujo_pago ON public.cobranza_pagos;
CREATE TRIGGER trg_espejo_flujo_pago AFTER INSERT OR UPDATE OF estatus, monto ON public.cobranza_pagos
  FOR EACH ROW EXECUTE FUNCTION public._espejo_flujo_trg_pago();
DROP TRIGGER IF EXISTS trg_espejo_flujo_aplic ON public.cobranza_aplicaciones;
CREATE TRIGGER trg_espejo_flujo_aplic AFTER INSERT OR UPDATE OR DELETE ON public.cobranza_aplicaciones
  FOR EACH ROW EXECUTE FUNCTION public._espejo_flujo_trg_hijo();
DROP TRIGGER IF EXISTS trg_espejo_flujo_saldo ON public.cobranza_saldos_favor;
CREATE TRIGGER trg_espejo_flujo_saldo AFTER INSERT OR UPDATE OR DELETE ON public.cobranza_saldos_favor
  FOR EACH ROW EXECUTE FUNCTION public._espejo_flujo_trg_hijo();

-- ── Un renglón espejo solo cambia de etapa desde Cobranza ───────────────────
CREATE OR REPLACE FUNCTION public._flujo_espejo_guarda()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF OLD.cobranza_pago_id IS NOT NULL
     AND NEW.etapa IS DISTINCT FROM OLD.etapa
     AND coalesce(current_setting('kit.espejo_cobranza', true), '') <> 'on' THEN
    RAISE EXCEPTION 'Este movimiento viene de Cobranza (pago %): se valida, aplica o revierte allá y aquí se refleja solo. / 此笔款项来自催收模块，请在催收中验证、核销或撤销。', OLD.folio;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_flujo_espejo_guarda ON public.flujo_dinero;
CREATE TRIGGER trg_flujo_espejo_guarda BEFORE UPDATE ON public.flujo_dinero
  FOR EACH ROW EXECUTE FUNCTION public._flujo_espejo_guarda();

REVOKE ALL ON FUNCTION public._espejo_cuenta_para_pago(text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._espejo_flujo_sincronizar(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._espejo_flujo_trg_pago() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._espejo_flujo_trg_hijo() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._flujo_espejo_guarda() FROM PUBLIC, anon, authenticated;

-- ── Verificación (solo lectura) ─────────────────────────────────────────────
-- 1) Triggers: SELECT tgname FROM pg_trigger WHERE tgname LIKE 'trg_%espejo%';
-- 2) Un pago nuevo de Cobranza aparece en v_flujo_dinero con su etapa.

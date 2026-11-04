-- ============================================================================
-- Lo que se registra en el Flujo de dinero se ve de inmediato en Cobranza y en
-- Control Financiero (2026-11-04)
--
-- Hasta ahora un pago de cliente registrado en el flujo aparecía en Cobranza hasta
-- que se aplicaba. Ahora Cobranza lo refleja desde el primer paso, por un solo
-- proceso (un trigger sobre flujo_dinero):
--
--   Flujo                   Cobranza (pago «Flujo de dinero FD-…»)      Control Financiero
--   Recibido                pago REGISTRADO (cliente, monto, fecha)     —
--   En caja                 pago VALIDADO (cuenta y quién lo validó)    ingreso confirmado (ya era así)
--   Aplicado                se usa ese mismo pago: aplicaciones/saldo    —
--   Rechazado               pago REVERTIDO con el motivo                el ingreso se cancela (ya era así)
--
--  · flujo_aplicar reutiliza el pago que ya existe (si no hubiera, lo crea como antes).
--  · Esos pagos solo se confirman, aplican o rechazan desde el flujo: Cobranza los
--    muestra, pero validar / revertir / aplicar allá se bloquea con un mensaje claro
--    (solo un pago que nació en Cobranza se maneja en Cobranza).
--  · La guarda del espejo (Cobranza → Flujo) ya no bloquea la etapa de los renglones
--    que nacieron en el flujo.
--  · Los renglones de abonos de Crédito, los históricos conectados y los de prueba de
--    otros orígenes no se tocan.
--
-- Idempotente. Para el SQL editor de Supabase; NO usar `supabase db push`.
-- Para revertir: DROP TRIGGER trg_flujo_a_cobranza ON flujo_dinero; y volver a la
-- definición de flujo_aplicar de 20261012000001 y de _flujo_espejo_guarda de 20261103000003.
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := '{}';
BEGIN
  IF to_regclass('public.flujo_dinero') IS NULL THEN _faltan := _faltan || 'tabla flujo_dinero'::text; END IF;
  IF to_regclass('public.cobranza_pagos') IS NULL THEN _faltan := _faltan || 'tabla cobranza_pagos'::text; END IF;
  IF to_regprocedure('public._siguiente_folio_compras(text,boolean)') IS NULL THEN _faltan := _faltan || 'función _siguiente_folio_compras'::text; END IF;
  IF to_regprocedure('public._flujo_espejo_guarda()') IS NULL THEN _faltan := _faltan || 'función _flujo_espejo_guarda (20261103000003)'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='flujo_dinero' AND column_name='cxc_abono_id') THEN
    _faltan := _faltan || 'columna flujo_dinero.cxc_abono_id (20261103000003)'::text;
  END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ', ');
  END IF;
END;
$preflight$;

-- ── 1. flujo_aplicar: usa el pago que ya existe en Cobranza ─────────────────
CREATE OR REPLACE FUNCTION public.flujo_aplicar(_id uuid, _destino text, _aplicaciones jsonb DEFAULT '[]'::jsonb, _notas text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  f public.flujo_dinero%ROWTYPE;
  v_cta text;
  v_pago uuid;
  v_pfolio text;
  it jsonb;
  r public.remisiones_refacciones%ROWTYPE;
  v_total numeric := 0;
  v_rem numeric;
  v_n integer := 0;
  v_saldo_folio text;
  v_notas text := nullif(btrim(coalesce(_notas, '')), '');
BEGIN
  IF NOT public.flujo_cap('aplica') THEN RAISE EXCEPTION 'No tienes asignada la etapa de aplicación'; END IF;
  SELECT * INTO f FROM public.flujo_dinero WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el movimiento'; END IF;
  PERFORM public.exigir_dato_prueba(f.es_prueba, 'el movimiento ' || f.folio);
  IF f.etapa <> 'EN_CAJA' THEN RAISE EXCEPTION '% no está pendiente de aplicar (etapa: %)', f.folio, f.etapa; END IF;
  IF auth.uid() IN (f.recibido_por, f.caja_por) THEN
    RAISE EXCEPTION 'Quien recibió o metió el dinero a caja no puede aplicarlo: lo hace una tercera persona';
  END IF;
  IF NOT ((f.tipo = 'PAGO_CLIENTE' AND _destino IN ('REMISION', 'OTRO'))
       OR (f.tipo = 'REEMBOLSO' AND _destino IN ('REEMBOLSO_PROVEEDOR', 'REEMBOLSO_EMPLEADO', 'OTRO'))
       OR (f.tipo = 'SALIDA' AND _destino IN ('GASTO', 'PAGO_PROVEEDOR', 'OTRO'))) THEN
    RAISE EXCEPTION 'El destino % no corresponde a un movimiento de tipo %', _destino, f.tipo;
  END IF;

  IF f.tipo = 'PAGO_CLIENTE' THEN
    IF _destino = 'REMISION' AND jsonb_array_length(coalesce(_aplicaciones, '[]'::jsonb)) = 0 THEN
      RAISE EXCEPTION 'Elige al menos una remisión a la que se abona';
    END IF;
    IF _destino = 'OTRO' THEN _aplicaciones := '[]'::jsonb; END IF;
    SELECT coalesce(sum(round((e.value->>'monto')::numeric, 2)), 0) INTO v_total
      FROM jsonb_array_elements(coalesce(_aplicaciones, '[]'::jsonb)) e;
    IF v_total > f.monto THEN
      RAISE EXCEPTION 'Se quieren aplicar % y el pago % sólo tiene %',
        to_char(v_total, 'FM999,999,990.00'), f.folio, to_char(f.monto, 'FM999,999,990.00');
    END IF;

    -- El pago ya existe en Cobranza desde que se registró en el flujo (y quedó validado al entrar a caja).
    v_pago := f.cobranza_pago_id;
    IF v_pago IS NOT NULL THEN
      SELECT folio INTO v_pfolio FROM public.cobranza_pagos WHERE id = v_pago;
    ELSE
      SELECT nombre INTO v_cta FROM public.cuentas_financieras WHERE id = f.cuenta_id;
      v_pfolio := public._siguiente_folio_compras('CP', f.es_prueba);
      PERFORM set_config('kit.flujo_sincroniza', 'on', true);
      INSERT INTO public.cobranza_pagos (folio, cliente_id, fecha, monto, forma, cuenta_destino, referencia, notas, estatus,
                                         conciliado, capturado_por, validado_por, validado_at, es_prueba)
      VALUES (v_pfolio, f.cliente_id, f.fecha, f.monto,
              CASE lower(f.metodo_pago::text) WHEN 'efectivo' THEN 'efectivo' WHEN 'deposito' THEN 'deposito' ELSE 'transferencia' END,
              v_cta, f.referencia,
              'Flujo de dinero ' || f.folio, 'validado', true, f.recibido_por, f.caja_por, f.caja_at, f.es_prueba)
      RETURNING id INTO v_pago;
    END IF;
    PERFORM set_config('kit.flujo_sincroniza', 'on', true);

    FOR it IN SELECT value FROM jsonb_array_elements(coalesce(_aplicaciones, '[]'::jsonb)) LOOP
      r := public._validar_destino_cobro((it->>'remision_id')::uuid, f.cliente_id, f.es_prueba, round((it->>'monto')::numeric, 2));
      INSERT INTO public.cobranza_aplicaciones (tipo, pago_id, remision_id, monto, notas, created_by, es_prueba)
      VALUES ('pago', v_pago, r.id, round((it->>'monto')::numeric, 2), v_notas, auth.uid(), f.es_prueba);
      INSERT INTO public.remision_refaccion_eventos (remision_id, area, accion, detalle, usuario_id)
      VALUES (r.id, 'finanzas', 'pago_aplicado',
              'Se aplicaron ' || to_char(round((it->>'monto')::numeric, 2), 'FM999,999,990.00') || ' del pago ' || v_pfolio
                || ' (flujo ' || f.folio || ').', auth.uid());
      PERFORM public.cobranza_sincronizar_remision(r.id);
      v_n := v_n + 1;
    END LOOP;

    v_rem := public.disponible_pago_cobranza(v_pago);
    IF v_rem > 0 THEN
      v_saldo_folio := public._siguiente_folio_compras('SF', f.es_prueba);
      INSERT INTO public.cobranza_saldos_favor (folio, cliente_id, origen, monto, pago_origen_id, notas, created_by, es_prueba)
      VALUES (v_saldo_folio, f.cliente_id,
              CASE WHEN v_n > 0 THEN 'pago_en_exceso' ELSE 'pago_anticipado' END,
              v_rem, v_pago, 'Remanente del pago ' || v_pfolio || ' (flujo ' || f.folio || ')', auth.uid(), f.es_prueba);
    END IF;
  END IF;

  PERFORM set_config('kit.flujo_sincroniza', '', true);
  UPDATE public.flujo_dinero
     SET etapa = 'APLICADO', destino = _destino, aplicado_por = auth.uid(), aplicado_at = now(),
         aplicado_notas = v_notas, cobranza_pago_id = v_pago
   WHERE id = f.id;
  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_aplicar', 'flujo_dinero', f.id, f.folio,
    jsonb_build_object('destino', _destino, 'aplicaciones', _aplicaciones, 'pago_cobranza', v_pfolio, 'saldo_favor', v_saldo_folio), f.es_prueba);
  RETURN jsonb_build_object('aplicadas', v_n, 'pago', v_pfolio, 'saldo_favor', v_saldo_folio);
END;
$$;
REVOKE ALL ON FUNCTION public.flujo_aplicar(uuid, text, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_aplicar(uuid, text, jsonb, text) TO authenticated;

-- ── 2. El flujo alimenta a Cobranza en cada etapa ───────────────────────────
CREATE OR REPLACE FUNCTION public._flujo_a_cobranza()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_pago uuid;
  v_folio text;
  v_cta text;
BEGIN
  IF NEW.tipo <> 'PAGO_CLIENTE' OR NEW.cliente_id IS NULL OR NEW.cxc_abono_id IS NOT NULL THEN RETURN NULL; END IF;

  IF TG_OP = 'INSERT' THEN
    -- Solo lo que nace en el flujo (recibido, sin pago ligado): lo demás ya tiene su origen.
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
    UPDATE public.flujo_dinero SET cobranza_pago_id = v_pago WHERE id = NEW.id;
    RETURN NULL;
  END IF;

  -- UPDATE de etapa: el pago de Cobranza sigue al flujo.
  IF NEW.cobranza_pago_id IS NULL OR NEW.etapa IS NOT DISTINCT FROM OLD.etapa THEN RETURN NULL; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.cobranza_pagos WHERE id = NEW.cobranza_pago_id AND notas LIKE 'Flujo de dinero %') THEN
    RETURN NULL;   -- nació en Cobranza: lo sigue el espejo de Cobranza → Flujo
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
DROP TRIGGER IF EXISTS trg_flujo_a_cobranza ON public.flujo_dinero;
CREATE TRIGGER trg_flujo_a_cobranza AFTER INSERT OR UPDATE OF etapa ON public.flujo_dinero
  FOR EACH ROW EXECUTE FUNCTION public._flujo_a_cobranza();

-- ── 3. Cobranza solo muestra esos pagos: no se validan/revierten/aplican allá ──
CREATE OR REPLACE FUNCTION public._cobranza_pago_del_flujo_guarda()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_pago uuid; v_notas text;
BEGIN
  IF coalesce(current_setting('kit.flujo_sincroniza', true), '') = 'on' THEN RETURN NEW; END IF;
  IF TG_TABLE_NAME = 'cobranza_pagos' THEN
    IF NEW.estatus IS NOT DISTINCT FROM OLD.estatus THEN RETURN NEW; END IF;
    v_notas := OLD.notas;
  ELSE
    IF NEW.pago_id IS NULL THEN RETURN NEW; END IF;
    SELECT notas INTO v_notas FROM public.cobranza_pagos WHERE id = NEW.pago_id;
  END IF;
  IF coalesce(v_notas, '') LIKE 'Flujo de dinero %' THEN
    RAISE EXCEPTION 'Este pago viene del Flujo de dinero (%): se confirma en caja, se aplica o se rechaza allá y aquí se refleja solo. / 此笔款项来自资金流模块，请在资金流中确认、核销或拒绝。',
      replace(v_notas, 'Flujo de dinero ', '');
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public._cobranza_pago_del_flujo_guarda() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_cobranza_pago_flujo_guarda ON public.cobranza_pagos;
CREATE TRIGGER trg_cobranza_pago_flujo_guarda BEFORE UPDATE ON public.cobranza_pagos
  FOR EACH ROW EXECUTE FUNCTION public._cobranza_pago_del_flujo_guarda();
DROP TRIGGER IF EXISTS trg_cobranza_aplic_flujo_guarda ON public.cobranza_aplicaciones;
CREATE TRIGGER trg_cobranza_aplic_flujo_guarda BEFORE INSERT ON public.cobranza_aplicaciones
  FOR EACH ROW EXECUTE FUNCTION public._cobranza_pago_del_flujo_guarda();

-- ── 4. La guarda del espejo: solo bloquea lo que nació en Cobranza ──────────
CREATE OR REPLACE FUNCTION public._flujo_espejo_guarda()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.etapa IS DISTINCT FROM OLD.etapa AND coalesce(current_setting('kit.espejo_cobranza', true), '') <> 'on' THEN
    IF OLD.cobranza_pago_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.cobranza_pagos p WHERE p.id = OLD.cobranza_pago_id AND p.notas LIKE 'Flujo de dinero %') THEN
      RAISE EXCEPTION 'Este movimiento viene de Cobranza (pago %): se valida, aplica o revierte allá y aquí se refleja solo. / 此笔款项来自催收模块，请在催收中验证、核销或撤销。', OLD.folio;
    END IF;
    IF OLD.cxc_abono_id IS NOT NULL AND NOT (OLD.etapa = 'RECIBIDO' AND NEW.etapa = 'APLICADO') THEN
      RAISE EXCEPTION 'Este movimiento es un abono de Crédito (%): solo se confirma en caja; ya está aplicado a la cuenta por cobrar. / 此笔为信贷还款：只需在出纳确认，已核销到应收账款。', OLD.folio;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DO $postflight$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_flujo_a_cobranza' AND tgenabled = 'O') THEN
    RAISE EXCEPTION 'Falta el trigger del flujo a Cobranza.';
  END IF;
  IF position('v_pago := f.cobranza_pago_id' in pg_get_functiondef('public.flujo_aplicar(uuid,text,jsonb,text)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'flujo_aplicar no quedó reutilizando el pago.';
  END IF;
  IF has_function_privilege('anon', 'public.flujo_aplicar(uuid,text,jsonb,text)', 'execute') THEN
    RAISE EXCEPTION 'flujo_aplicar no debe estar abierta a anon.';
  END IF;
END $postflight$;

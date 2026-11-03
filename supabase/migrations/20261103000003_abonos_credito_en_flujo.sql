-- ============================================================================
-- Los abonos de Crédito pasan por el mismo Flujo de dinero (2026-11-03)
--
-- Hasta hoy un abono a una cuenta por cobrar (cxc_abonos) bajaba el saldo de la
-- CxC y ahí se quedaba: no pasaba por Caja ni aparecía en Control Financiero.
-- Ahora cada abono nace como un renglón del flujo, igual que un pago de cliente:
--
--   Crédito: se registra el abono        →  flujo RECIBIDO  (falta caja)
--   Caja lo confirma contra la cuenta    →  flujo APLICADO  (+ ingreso confirmado
--     (otra persona, no quien lo recibió)    en Control Financiero, y el abono
--                                            guarda su movimiento_id)
--
-- El abono ya bajó el saldo de la CxC al capturarse, por eso al confirmar caja
-- el renglón queda APLICADO de una vez: no hay paso «aplicar» (no se duplica el
-- pago en Cobranza). Un abono tampoco se rechaza en el flujo: ya está aplicado
-- a la cuenta por cobrar.
--
-- · Solo se espejean abonos en MXN de clientes reales (el flujo recibe pagos de
--   cliente en pesos; los de prueba no entran).
-- · Un fallo del espejo nunca frena el abono (se avisa en el log y sigue).
-- · NO hay relleno de abonos anteriores (cambiaría saldos de Control Financiero).
-- · flujo_confirmar_caja se redefine con la versión de producción (regla de
--   cuenta por método incluida) + el caso del abono.
--
-- Idempotente. Para el SQL editor de Supabase; NO usar `supabase db push`.
-- Para revertir: DROP TRIGGER trg_espejo_flujo_abono ON public.cxc_abonos;
--   y volver a la definición de flujo_confirmar_caja de 20261028000001.
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := '{}';
BEGIN
  IF to_regclass('public.flujo_dinero') IS NULL THEN _faltan := _faltan || 'tabla flujo_dinero'::text; END IF;
  IF to_regclass('public.cxc_abonos') IS NULL THEN _faltan := _faltan || 'tabla cxc_abonos'::text; END IF;
  IF to_regclass('public.cuentas_por_cobrar') IS NULL THEN _faltan := _faltan || 'tabla cuentas_por_cobrar'::text; END IF;
  IF to_regclass('public.movimientos_financieros') IS NULL THEN _faltan := _faltan || 'tabla movimientos_financieros'::text; END IF;
  IF to_regprocedure('public.flujo_confirmar_caja(uuid,uuid,text)') IS NULL THEN _faltan := _faltan || 'función flujo_confirmar_caja'::text; END IF;
  IF to_regprocedure('public._flujo_espejo_guarda()') IS NULL THEN _faltan := _faltan || 'función _flujo_espejo_guarda (20261103000002)'::text; END IF;
  IF to_regprocedure('public.flujo_cap(text,uuid)') IS NULL THEN _faltan := _faltan || 'función flujo_cap'::text; END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ', ');
  END IF;
END;
$preflight$;

-- ── Enlace del renglón del flujo con su abono ───────────────────────────────
ALTER TABLE public.flujo_dinero ADD COLUMN IF NOT EXISTS cxc_abono_id uuid;
DO $fk$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'flujo_dinero_cxc_abono_id_fkey') THEN
    ALTER TABLE public.flujo_dinero
      ADD CONSTRAINT flujo_dinero_cxc_abono_id_fkey FOREIGN KEY (cxc_abono_id) REFERENCES public.cxc_abonos(id) ON DELETE SET NULL;
  END IF;
END
$fk$;
CREATE UNIQUE INDEX IF NOT EXISTS uq_flujo_dinero_cxc_abono ON public.flujo_dinero (cxc_abono_id) WHERE cxc_abono_id IS NOT NULL;

-- La vista fija sus columnas al crearse: se recrea (mismas columnas y orden) y se
-- le agrega al final cxc_abono_id para que la pantalla del flujo lo vea.
CREATE OR REPLACE VIEW public.v_flujo_dinero
WITH (security_invoker = true) AS
SELECT f.id, f.folio, f.tipo, f.etapa, f.monto, f.moneda, f.tipo_cambio, f.metodo_pago, f.fecha,
       f.contraparte_nombre, f.cliente_id, f.concepto, f.referencia, f.es_prueba,
       f.recibido_por, f.recibido_at, f.cuenta_id, f.caja_por, f.caja_at, f.caja_notas, f.movimiento_id,
       f.destino, f.aplicado_por, f.aplicado_at, f.aplicado_notas, f.cobranza_pago_id,
       f.rechazado_por, f.rechazado_at, f.motivo_rechazo, f.created_at,
       public.flujo_nombre(f.recibido_por) AS recibido_por_nombre,
       public.flujo_nombre(f.caja_por)     AS caja_por_nombre,
       public.flujo_nombre(f.aplicado_por) AS aplicado_por_nombre,
       f.cxc_abono_id
  FROM public.flujo_dinero f;
GRANT SELECT ON public.v_flujo_dinero TO authenticated;

-- ── Cada abono crea su renglón en el flujo ──────────────────────────────────
CREATE OR REPLACE FUNCTION public._espejo_flujo_abono()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  x public.cuentas_por_cobrar%ROWTYPE;
  cli public.clientes%ROWTYPE;
  v_quien uuid;
  v_m text;
  v_metodo public.metodo_pago;
BEGIN
  BEGIN
    SELECT * INTO x FROM public.cuentas_por_cobrar WHERE id = NEW.cxc_id;
    IF NOT FOUND OR coalesce(x.moneda, 'MXN') <> 'MXN' THEN RETURN NULL; END IF;
    SELECT * INTO cli FROM public.clientes WHERE id = x.cliente_id;
    IF NOT FOUND OR cli.es_prueba THEN RETURN NULL; END IF;
    v_quien := coalesce(NEW.created_by, x.created_by);
    IF v_quien IS NULL THEN RETURN NULL; END IF;

    v_m := lower(translate(coalesce(NEW.metodo_pago, ''), 'áéíóúÁÉÍÓÚ', 'aeiouAEIOU'));
    v_metodo := (CASE
      WHEN v_m LIKE '%efectivo%' THEN 'EFECTIVO'
      WHEN v_m LIKE '%transfer%' OR v_m LIKE '%spei%' THEN 'TRANSFERENCIA'
      WHEN v_m LIKE '%deposito%' THEN 'DEPOSITO'
      WHEN v_m LIKE '%cheque%' THEN 'CHEQUE'
      WHEN v_m LIKE '%tarjeta%' THEN 'TARJETA'
      ELSE 'OTRO' END)::public.metodo_pago;

    PERFORM set_config('kit.espejo_cobranza', 'on', true);
    INSERT INTO public.flujo_dinero (tipo, etapa, monto, moneda, metodo_pago, fecha, contraparte_nombre, cliente_id,
                                     concepto, referencia, es_prueba, recibido_por, recibido_at, cxc_abono_id)
    VALUES ('PAGO_CLIENTE', 'RECIBIDO', NEW.monto, 'MXN', v_metodo, NEW.fecha_abono,
            coalesce(cli.nombre_comercial, cli.razon_social, cli.codigo_erp, 'Cliente'), x.cliente_id,
            'Abono a crédito ' || coalesce(x.folio, ''),
            coalesce(nullif(btrim(coalesce(NEW.referencia, '')), ''), x.folio), false, v_quien, NEW.created_at, NEW.id);
    PERFORM set_config('kit.espejo_cobranza', '', true);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'espejo flujo (abono %): %', NEW.id, SQLERRM;
  END;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_espejo_flujo_abono ON public.cxc_abonos;
CREATE TRIGGER trg_espejo_flujo_abono AFTER INSERT ON public.cxc_abonos
  FOR EACH ROW EXECUTE FUNCTION public._espejo_flujo_abono();

-- ── Caja confirma: si es un abono de Crédito, queda APLICADO y enlazado ─────
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

-- ── Guarda: un abono solo avanza por Caja ───────────────────────────────────
CREATE OR REPLACE FUNCTION public._flujo_espejo_guarda()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.etapa IS DISTINCT FROM OLD.etapa AND coalesce(current_setting('kit.espejo_cobranza', true), '') <> 'on' THEN
    IF OLD.cobranza_pago_id IS NOT NULL THEN
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
  IF position('cxc_abono_id' in pg_get_functiondef('public.flujo_confirmar_caja(uuid,uuid,text)'::regprocedure)) = 0
     OR position('cuenta de banco' in pg_get_functiondef('public.flujo_confirmar_caja(uuid,uuid,text)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'flujo_confirmar_caja no quedó con el caso de abono y la regla de cuenta.';
  END IF;
  IF has_function_privilege('anon', 'public.flujo_confirmar_caja(uuid,uuid,text)', 'execute') THEN
    RAISE EXCEPTION 'flujo_confirmar_caja no debe estar abierta a anon.';
  END IF;
END $postflight$;

REVOKE ALL ON FUNCTION public._espejo_flujo_abono() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._flujo_espejo_guarda() FROM PUBLIC, anon, authenticated;

-- ── Verificación (solo lectura) ─────────────────────────────────────────────
-- 1) SELECT tgname FROM pg_trigger WHERE tgname = 'trg_espejo_flujo_abono';
-- 2) Registra un abono en Crédito: aparece en Flujo de dinero como «Recibido».

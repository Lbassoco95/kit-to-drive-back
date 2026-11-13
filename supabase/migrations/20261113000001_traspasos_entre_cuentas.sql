-- ============================================================================
-- Traspasos entre cuentas, compra y venta de dólares (2026-11-13)
--
-- Petición de Finanzas: mover dinero entre cuentas sin capturar a mano un egreso
-- en una cuenta y un ingreso en la otra. Un traspaso es UNA operación que nace
-- las dos patas juntas en el libro mayor (movimientos_financieros) o ninguna.
--
-- Reglas acordadas:
--   · Misma aprobación que el flujo: captura quien tiene la etapa «recibe»; la
--     confirma otra persona con la etapa «caja» (quien capturó solo confirma lo
--     suyo si tiene «autoaplica»). Las patas del libro nacen al CONFIRMAR.
--   · MXN↔MXN (o USD↔USD) es traspaso. MXN↔USD es COMPRA_USD (sale MXN, entra USD)
--     o VENTA_USD (sale USD, entra MXN) y exige el tipo de cambio pactado
--     (pesos por dólar), que queda guardado.
--   · Sobregiro: no se permite. La cuenta de origen debe tener saldo suficiente al
--     capturar y otra vez al confirmar.
--   · Comisiones: NO van en el traspaso; se capturan aparte, como egreso, al cierre
--     de mes contra el estado de cuenta.
--   · Control Financiero sigue de solo consulta: las patas se escriben con la llave
--     `kit.flujo_escribe` igual que el resto del flujo.
--   · Las patas llevan `traspaso_id` para excluirlas de los totales de ingresos y
--     egresos (no son ni ganancia ni gasto). v_saldos_cuentas no cambia: suma por cuenta.
--   · Lo confirmado solo se deshace con «revertir» (administrador, con motivo): cancela
--     las dos patas. Nada se borra.
--
-- Idempotente. Para el SQL editor de Supabase; NO usar `supabase db push`.
-- Para revertir: DROP las funciones traspaso_*, ALTER TABLE movimientos_financieros
-- DROP COLUMN traspaso_id y DROP TABLE traspasos_cuentas (solo si no hay traspasos).
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := '{}';
BEGIN
  IF to_regclass('public.movimientos_financieros') IS NULL THEN _faltan := _faltan || 'tabla movimientos_financieros'::text; END IF;
  IF to_regclass('public.cuentas_financieras') IS NULL THEN _faltan := _faltan || 'tabla cuentas_financieras'::text; END IF;
  IF to_regprocedure('public.flujo_cap(text,uuid)') IS NULL THEN _faltan := _faltan || 'función flujo_cap'::text; END IF;
  IF to_regprocedure('public.flujo_es_admin(uuid)') IS NULL THEN _faltan := _faltan || 'función flujo_es_admin'::text; END IF;
  IF to_regprocedure('public._candado_movimientos_solo_flujo()') IS NULL THEN _faltan := _faltan || 'candado (20261103000004)'::text; END IF;
  IF to_regprocedure('public.registrar_bitacora_compras(text,text,text,uuid,text,jsonb,boolean)') IS NULL THEN _faltan := _faltan || 'función registrar_bitacora_compras'::text; END IF;
  IF to_regprocedure('public.exigir_dato_prueba(boolean,text)') IS NULL THEN _faltan := _faltan || 'función exigir_dato_prueba'::text; END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ', ');
  END IF;
END;
$preflight$;

-- ── 1. Tabla ────────────────────────────────────────────────────────────────
CREATE SEQUENCE IF NOT EXISTS public.seq_folio_traspaso START 1;

CREATE TABLE IF NOT EXISTS public.traspasos_cuentas (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  folio             text NOT NULL UNIQUE DEFAULT ('TR-' || lpad(nextval('public.seq_folio_traspaso')::text, 6, '0')),
  estatus           text NOT NULL DEFAULT 'SOLICITADO' CHECK (estatus IN ('SOLICITADO', 'CONFIRMADO', 'RECHAZADO', 'REVERTIDO')),
  operacion         text NOT NULL CHECK (operacion IN ('TRASPASO', 'COMPRA_USD', 'VENTA_USD')),
  cuenta_origen_id  uuid NOT NULL REFERENCES public.cuentas_financieras(id),
  cuenta_destino_id uuid NOT NULL REFERENCES public.cuentas_financieras(id),
  moneda_origen     text NOT NULL,
  moneda_destino    text NOT NULL,
  monto_origen      numeric(18, 2) NOT NULL CHECK (monto_origen > 0),
  monto_destino     numeric(18, 2) NOT NULL CHECK (monto_destino > 0),
  tipo_cambio       numeric(12, 4),               -- pesos por dólar, solo en compra/venta de dólares
  fecha             date NOT NULL DEFAULT CURRENT_DATE,
  concepto          text,
  referencia        text,
  es_prueba         boolean NOT NULL DEFAULT false,
  creado_por        uuid NOT NULL REFERENCES auth.users(id),
  creado_at         timestamptz NOT NULL DEFAULT now(),
  confirmado_por    uuid REFERENCES auth.users(id),
  confirmado_at     timestamptz,
  caja_notas        text,
  rechazado_por     uuid REFERENCES auth.users(id),
  rechazado_at      timestamptz,
  motivo_rechazo    text,
  revertido_por     uuid REFERENCES auth.users(id),
  revertido_at      timestamptz,
  motivo_reversion  text,
  mov_egreso_id     uuid REFERENCES public.movimientos_financieros(id),
  mov_ingreso_id    uuid REFERENCES public.movimientos_financieros(id),
  CONSTRAINT traspaso_cuentas_distintas CHECK (cuenta_origen_id <> cuenta_destino_id),
  CONSTRAINT traspaso_monedas CHECK (moneda_origen IN ('MXN', 'USD') AND moneda_destino IN ('MXN', 'USD')),
  CONSTRAINT traspaso_operacion_moneda CHECK (
    (operacion = 'TRASPASO'   AND moneda_origen = moneda_destino AND tipo_cambio IS NULL AND monto_origen = monto_destino) OR
    (operacion = 'COMPRA_USD' AND moneda_origen = 'MXN' AND moneda_destino = 'USD' AND tipo_cambio > 0) OR
    (operacion = 'VENTA_USD'  AND moneda_origen = 'USD' AND moneda_destino = 'MXN' AND tipo_cambio > 0)
  ),
  CONSTRAINT traspaso_rechazo_motivo CHECK (estatus <> 'RECHAZADO' OR nullif(btrim(coalesce(motivo_rechazo, '')), '') IS NOT NULL),
  CONSTRAINT traspaso_reversion_motivo CHECK (estatus <> 'REVERTIDO' OR nullif(btrim(coalesce(motivo_reversion, '')), '') IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS idx_traspasos_estatus ON public.traspasos_cuentas (estatus, creado_at DESC);
CREATE INDEX IF NOT EXISTS idx_traspasos_origen  ON public.traspasos_cuentas (cuenta_origen_id);
CREATE INDEX IF NOT EXISTS idx_traspasos_destino ON public.traspasos_cuentas (cuenta_destino_id);

ALTER TABLE public.traspasos_cuentas ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.traspasos_cuentas FROM PUBLIC, anon, authenticated;
-- La tabla no se lee ni escribe directo: todo pasa por las funciones traspaso_*.

CREATE OR REPLACE FUNCTION public.traspaso_sin_borrar()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'Los traspasos no se borran: se rechazan o se revierten con motivo.';
END;
$$;
DROP TRIGGER IF EXISTS trg_traspaso_sin_borrar ON public.traspasos_cuentas;
CREATE TRIGGER trg_traspaso_sin_borrar BEFORE DELETE ON public.traspasos_cuentas
  FOR EACH ROW EXECUTE FUNCTION public.traspaso_sin_borrar();
REVOKE ALL ON FUNCTION public.traspaso_sin_borrar() FROM PUBLIC, anon, authenticated;

-- Las patas del libro apuntan a su traspaso (para excluirlas de ingresos/egresos reales).
ALTER TABLE public.movimientos_financieros ADD COLUMN IF NOT EXISTS traspaso_id uuid REFERENCES public.traspasos_cuentas(id);
CREATE INDEX IF NOT EXISTS idx_mov_traspaso ON public.movimientos_financieros (traspaso_id) WHERE traspaso_id IS NOT NULL;

-- ── 2. Saldo vigente de una cuenta (confirmado) ─────────────────────────────
CREATE OR REPLACE FUNCTION public._saldo_cuenta(_cuenta uuid)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT c.saldo_inicial + coalesce(sum(CASE WHEN m.tipo = 'INGRESO' THEN m.monto ELSE -m.monto END), 0)
    FROM public.cuentas_financieras c
    LEFT JOIN public.movimientos_financieros m ON m.cuenta_id = c.id AND m.estatus = 'CONFIRMADO'
   WHERE c.id = _cuenta
   GROUP BY c.id, c.saldo_inicial
$$;
REVOKE ALL ON FUNCTION public._saldo_cuenta(uuid) FROM PUBLIC, anon, authenticated;

-- ── 3. Cuentas con saldo, para el formulario ────────────────────────────────
CREATE OR REPLACE FUNCTION public.traspaso_cuentas()
RETURNS TABLE (id uuid, nombre text, tipo text, moneda text, empresa text, institucion text, ultimos4 text, saldo numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT (public.flujo_cap('recibe') OR public.flujo_cap('caja') OR public.flujo_es_admin()) THEN
    RAISE EXCEPTION 'No tienes asignada una etapa del flujo de dinero';
  END IF;
  RETURN QUERY
    SELECT c.id, c.nombre, c.tipo::text, c.moneda, c.empresa, i.nombre, c.ultimos4, public._saldo_cuenta(c.id)
      FROM public.cuentas_financieras c LEFT JOIN public.instituciones_financieras i ON i.id = c.institucion_id
     WHERE c.activo
     ORDER BY c.empresa NULLS LAST, c.orden, c.nombre;
END;
$$;
REVOKE ALL ON FUNCTION public.traspaso_cuentas() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.traspaso_cuentas() TO authenticated;

-- ── 4. Solicitar (captura) ──────────────────────────────────────────────────
-- _monto es lo que SALE de la cuenta de origen. Con monedas distintas, _tipo_cambio son
-- pesos por dólar y el monto destino se calcula (compra: MXN / TC; venta: USD * TC).
CREATE OR REPLACE FUNCTION public.traspaso_solicitar(
  _origen uuid, _destino uuid, _monto numeric, _tipo_cambio numeric DEFAULT NULL,
  _fecha date DEFAULT NULL, _concepto text DEFAULT NULL, _referencia text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  o public.cuentas_financieras%ROWTYPE;
  d public.cuentas_financieras%ROWTYPE;
  v_prueba boolean := public.es_usuario_prueba(auth.uid());
  v_oper text;
  v_destino numeric;
  v_tc numeric;
  t public.traspasos_cuentas%ROWTYPE;
BEGIN
  IF NOT public.flujo_cap('recibe') THEN RAISE EXCEPTION 'No tienes asignada la etapa de captura (recibe) del flujo de dinero'; END IF;
  IF _origen IS NULL OR _destino IS NULL THEN RAISE EXCEPTION 'Elige la cuenta de origen y la de destino'; END IF;
  IF _origen = _destino THEN RAISE EXCEPTION 'La cuenta de origen y la de destino deben ser distintas'; END IF;
  IF _monto IS NULL OR _monto <= 0 THEN RAISE EXCEPTION 'El monto debe ser mayor a cero'; END IF;
  IF round(_monto, 2) <> _monto THEN RAISE EXCEPTION 'El monto admite máximo dos decimales'; END IF;
  SELECT * INTO o FROM public.cuentas_financieras WHERE id = _origen AND activo;
  IF NOT FOUND THEN RAISE EXCEPTION 'La cuenta de origen no existe o está inactiva'; END IF;
  SELECT * INTO d FROM public.cuentas_financieras WHERE id = _destino AND activo;
  IF NOT FOUND THEN RAISE EXCEPTION 'La cuenta de destino no existe o está inactiva'; END IF;
  IF o.moneda NOT IN ('MXN', 'USD') OR d.moneda NOT IN ('MXN', 'USD') THEN
    RAISE EXCEPTION 'Solo se traspasa entre cuentas en pesos (MXN) o dólares (USD)';
  END IF;

  IF o.moneda = d.moneda THEN
    IF _tipo_cambio IS NOT NULL THEN RAISE EXCEPTION 'Entre cuentas de la misma moneda no hay tipo de cambio'; END IF;
    v_oper := 'TRASPASO'; v_destino := _monto; v_tc := NULL;
  ELSE
    IF _tipo_cambio IS NULL OR _tipo_cambio <= 0 THEN
      RAISE EXCEPTION 'Captura el tipo de cambio pactado (pesos por dólar) de la % de dólares', CASE WHEN o.moneda = 'MXN' THEN 'compra' ELSE 'venta' END;
    END IF;
    v_tc := round(_tipo_cambio, 4);
    IF o.moneda = 'MXN' THEN v_oper := 'COMPRA_USD'; v_destino := round(_monto / v_tc, 2);
    ELSE v_oper := 'VENTA_USD'; v_destino := round(_monto * v_tc, 2);
    END IF;
    IF v_destino <= 0 THEN RAISE EXCEPTION 'Con ese monto y tipo de cambio el monto destino sale en cero'; END IF;
  END IF;

  IF NOT v_prueba AND public._saldo_cuenta(o.id) < _monto THEN
    RAISE EXCEPTION 'Saldo insuficiente en «%»: tiene % % y se quieren traspasar % %. No se permite sobregiro.',
      o.nombre, to_char(public._saldo_cuenta(o.id), 'FM999,999,999,990.00'), o.moneda, to_char(_monto, 'FM999,999,999,990.00'), o.moneda;
  END IF;

  INSERT INTO public.traspasos_cuentas
    (operacion, cuenta_origen_id, cuenta_destino_id, moneda_origen, moneda_destino, monto_origen, monto_destino,
     tipo_cambio, fecha, concepto, referencia, es_prueba, creado_por)
  VALUES (v_oper, o.id, d.id, o.moneda, d.moneda, _monto, v_destino, v_tc, coalesce(_fecha, CURRENT_DATE),
          nullif(btrim(coalesce(_concepto, '')), ''), nullif(btrim(coalesce(_referencia, '')), ''), v_prueba, auth.uid())
  RETURNING * INTO t;

  PERFORM public.registrar_bitacora_compras('cobranza', 'traspaso_solicitar', 'traspasos_cuentas', t.id, t.folio,
    jsonb_build_object('operacion', t.operacion, 'origen', o.nombre, 'destino', d.nombre,
                       'monto_origen', t.monto_origen, 'monto_destino', t.monto_destino, 'tipo_cambio', t.tipo_cambio), t.es_prueba);
  RETURN jsonb_build_object('id', t.id, 'folio', t.folio, 'operacion', t.operacion, 'monto_destino', t.monto_destino);
END;
$$;
REVOKE ALL ON FUNCTION public.traspaso_solicitar(uuid, uuid, numeric, numeric, date, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.traspaso_solicitar(uuid, uuid, numeric, numeric, date, text, text) TO authenticated;

-- ── 5. Confirmar (caja): nacen las dos patas ────────────────────────────────
CREATE OR REPLACE FUNCTION public.traspaso_confirmar(_id uuid, _notas text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  t public.traspasos_cuentas%ROWTYPE;
  o public.cuentas_financieras%ROWTYPE;
  d public.cuentas_financieras%ROWTYPE;
  v_egreso uuid;
  v_ingreso uuid;
  v_nombre text;
BEGIN
  IF NOT public.flujo_cap('caja') THEN RAISE EXCEPTION 'No tienes asignada la etapa de caja'; END IF;
  SELECT * INTO t FROM public.traspasos_cuentas WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el traspaso'; END IF;
  PERFORM public.exigir_dato_prueba(t.es_prueba, 'el traspaso ' || t.folio);
  IF t.estatus <> 'SOLICITADO' THEN RAISE EXCEPTION '% no está pendiente de confirmar (estatus: %)', t.folio, t.estatus; END IF;
  IF t.creado_por = auth.uid() AND NOT public.flujo_cap('autoaplica') THEN
    RAISE EXCEPTION 'Quien capturó el traspaso no lo confirma: lo hace otra persona de caja';
  END IF;

  -- Se bloquean las dos cuentas (en orden fijo) para que el saldo no cambie entre la revisión y el movimiento.
  PERFORM 1 FROM public.cuentas_financieras WHERE id IN (t.cuenta_origen_id, t.cuenta_destino_id) ORDER BY id FOR UPDATE;
  SELECT * INTO o FROM public.cuentas_financieras WHERE id = t.cuenta_origen_id;
  SELECT * INTO d FROM public.cuentas_financieras WHERE id = t.cuenta_destino_id;
  IF NOT o.activo OR NOT d.activo THEN RAISE EXCEPTION 'Una de las cuentas del traspaso ya está inactiva'; END IF;
  IF o.moneda <> t.moneda_origen OR d.moneda <> t.moneda_destino THEN
    RAISE EXCEPTION 'Cambió la moneda de una de las cuentas: rechaza este traspaso y captura otro';
  END IF;

  IF NOT t.es_prueba THEN
    IF public._saldo_cuenta(o.id) < t.monto_origen THEN
      RAISE EXCEPTION 'Saldo insuficiente en «%»: tiene % % y el traspaso % pide % %. No se permite sobregiro.',
        o.nombre, to_char(public._saldo_cuenta(o.id), 'FM999,999,999,990.00'), o.moneda, t.folio, to_char(t.monto_origen, 'FM999,999,999,990.00'), o.moneda;
    END IF;
    v_nombre := CASE t.operacion WHEN 'COMPRA_USD' THEN 'Compra de dólares' WHEN 'VENTA_USD' THEN 'Venta de dólares' ELSE 'Traspaso entre cuentas' END;

    PERFORM set_config('kit.flujo_escribe', 'on', true);
    INSERT INTO public.movimientos_financieros
      (tipo, estatus, concepto, categoria, descripcion, monto, moneda, tipo_cambio, fecha_movimiento, metodo_pago, cuenta_id, referencia,
       contraparte_tipo, contraparte_nombre, created_by, confirmado_por, confirmado_at, traspaso_id)
    VALUES
      ('EGRESO', 'CONFIRMADO', coalesce(t.concepto, v_nombre || ' a «' || d.nombre || '»'), 'Traspaso entre cuentas',
       t.folio || ' · ' || v_nombre || CASE WHEN t.tipo_cambio IS NOT NULL THEN ' a TC ' || t.tipo_cambio ELSE '' END,
       t.monto_origen, t.moneda_origen, CASE WHEN t.moneda_origen = 'USD' THEN t.tipo_cambio END, t.fecha,
       CASE WHEN o.tipo::text = 'EFECTIVO' THEN 'EFECTIVO'::public.metodo_pago ELSE 'TRANSFERENCIA'::public.metodo_pago END,
       o.id, t.referencia, 'OTRO', v_nombre, t.creado_por, auth.uid(), now(), t.id)
    RETURNING id INTO v_egreso;
    INSERT INTO public.movimientos_financieros
      (tipo, estatus, concepto, categoria, descripcion, monto, moneda, tipo_cambio, fecha_movimiento, metodo_pago, cuenta_id, referencia,
       contraparte_tipo, contraparte_nombre, created_by, confirmado_por, confirmado_at, traspaso_id)
    VALUES
      ('INGRESO', 'CONFIRMADO', coalesce(t.concepto, v_nombre || ' desde «' || o.nombre || '»'), 'Traspaso entre cuentas',
       t.folio || ' · ' || v_nombre || CASE WHEN t.tipo_cambio IS NOT NULL THEN ' a TC ' || t.tipo_cambio ELSE '' END,
       t.monto_destino, t.moneda_destino, CASE WHEN t.moneda_destino = 'USD' THEN t.tipo_cambio END, t.fecha,
       CASE WHEN d.tipo::text = 'EFECTIVO' THEN 'EFECTIVO'::public.metodo_pago ELSE 'TRANSFERENCIA'::public.metodo_pago END,
       d.id, t.referencia, 'OTRO', v_nombre, t.creado_por, auth.uid(), now(), t.id)
    RETURNING id INTO v_ingreso;
    PERFORM set_config('kit.flujo_escribe', '', true);
  END IF;

  UPDATE public.traspasos_cuentas
     SET estatus = 'CONFIRMADO', confirmado_por = auth.uid(), confirmado_at = now(),
         caja_notas = nullif(btrim(coalesce(_notas, '')), ''), mov_egreso_id = v_egreso, mov_ingreso_id = v_ingreso
   WHERE id = t.id;
  PERFORM public.registrar_bitacora_compras('cobranza', 'traspaso_confirmar', 'traspasos_cuentas', t.id, t.folio,
    jsonb_build_object('mov_egreso', v_egreso, 'mov_ingreso', v_ingreso), t.es_prueba);
  RETURN jsonb_build_object('id', t.id, 'folio', t.folio, 'mov_egreso_id', v_egreso, 'mov_ingreso_id', v_ingreso);
END;
$$;
REVOKE ALL ON FUNCTION public.traspaso_confirmar(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.traspaso_confirmar(uuid, text) TO authenticated;

-- ── 6. Rechazar (antes de confirmar) ────────────────────────────────────────
-- Lo rechaza caja o un administrador; quien lo capturó también puede retirarlo.
CREATE OR REPLACE FUNCTION public.traspaso_rechazar(_id uuid, _motivo text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE t public.traspasos_cuentas%ROWTYPE;
BEGIN
  IF length(btrim(coalesce(_motivo, ''))) < 3 THEN RAISE EXCEPTION 'El motivo del rechazo es obligatorio'; END IF;
  SELECT * INTO t FROM public.traspasos_cuentas WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el traspaso'; END IF;
  PERFORM public.exigir_dato_prueba(t.es_prueba, 'el traspaso ' || t.folio);
  IF t.estatus <> 'SOLICITADO' THEN RAISE EXCEPTION '% ya no se puede rechazar (estatus: %)', t.folio, t.estatus; END IF;
  IF NOT (public.flujo_cap('caja') OR public.flujo_es_admin() OR t.creado_por = auth.uid()) THEN
    RAISE EXCEPTION 'No tienes permiso para rechazar este traspaso';
  END IF;
  UPDATE public.traspasos_cuentas
     SET estatus = 'RECHAZADO', rechazado_por = auth.uid(), rechazado_at = now(), motivo_rechazo = btrim(_motivo)
   WHERE id = t.id;
  PERFORM public.registrar_bitacora_compras('cobranza', 'traspaso_rechazar', 'traspasos_cuentas', t.id, t.folio,
    jsonb_build_object('motivo', _motivo), t.es_prueba);
END;
$$;
REVOKE ALL ON FUNCTION public.traspaso_rechazar(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.traspaso_rechazar(uuid, text) TO authenticated;

-- ── 7. Revertir (ya confirmado): administrador, con motivo ──────────────────
CREATE OR REPLACE FUNCTION public.traspaso_revertir(_id uuid, _motivo text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  t public.traspasos_cuentas%ROWTYPE;
  d public.cuentas_financieras%ROWTYPE;
BEGIN
  IF NOT public.flujo_es_admin() THEN RAISE EXCEPTION 'Solo un administrador revierte un traspaso confirmado'; END IF;
  IF length(btrim(coalesce(_motivo, ''))) < 3 THEN RAISE EXCEPTION 'El motivo de la reversión es obligatorio'; END IF;
  SELECT * INTO t FROM public.traspasos_cuentas WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el traspaso'; END IF;
  PERFORM public.exigir_dato_prueba(t.es_prueba, 'el traspaso ' || t.folio);
  IF t.estatus <> 'CONFIRMADO' THEN RAISE EXCEPTION '% no está confirmado (estatus: %)', t.folio, t.estatus; END IF;

  PERFORM 1 FROM public.cuentas_financieras WHERE id IN (t.cuenta_origen_id, t.cuenta_destino_id) ORDER BY id FOR UPDATE;
  SELECT * INTO d FROM public.cuentas_financieras WHERE id = t.cuenta_destino_id;
  -- Revertir saca el dinero de la cuenta destino: tampoco puede dejarla en negativo.
  IF NOT t.es_prueba AND public._saldo_cuenta(d.id) < t.monto_destino THEN
    RAISE EXCEPTION 'No se puede revertir %: «%» ya no tiene % % para devolver. No se permite sobregiro.',
      t.folio, d.nombre, to_char(t.monto_destino, 'FM999,999,999,990.00'), d.moneda;
  END IF;

  IF NOT t.es_prueba THEN
    PERFORM set_config('kit.flujo_escribe', 'on', true);
    UPDATE public.movimientos_financieros
       SET estatus = 'CANCELADO', cancelado_por = auth.uid(), cancelado_at = now(),
           motivo_cancelacion = 'Traspaso ' || t.folio || ' revertido: ' || btrim(_motivo)
     WHERE traspaso_id = t.id AND estatus <> 'CANCELADO';
    PERFORM set_config('kit.flujo_escribe', '', true);
  END IF;
  UPDATE public.traspasos_cuentas
     SET estatus = 'REVERTIDO', revertido_por = auth.uid(), revertido_at = now(), motivo_reversion = btrim(_motivo)
   WHERE id = t.id;
  PERFORM public.registrar_bitacora_compras('cobranza', 'traspaso_revertir', 'traspasos_cuentas', t.id, t.folio,
    jsonb_build_object('motivo', _motivo), t.es_prueba);
END;
$$;
REVOKE ALL ON FUNCTION public.traspaso_revertir(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.traspaso_revertir(uuid, text) TO authenticated;

-- ── 8. Listar ───────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.traspaso_listar(_limite integer DEFAULT 200)
RETURNS TABLE (
  id uuid, folio text, estatus text, operacion text,
  cuenta_origen_id uuid, cuenta_origen text, cuenta_destino_id uuid, cuenta_destino text,
  moneda_origen text, moneda_destino text, monto_origen numeric, monto_destino numeric, tipo_cambio numeric,
  fecha date, concepto text, referencia text, es_prueba boolean,
  creado_por uuid, creado_por_nombre text, creado_at timestamptz,
  confirmado_por_nombre text, confirmado_at timestamptz, caja_notas text,
  motivo_rechazo text, motivo_reversion text
) LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT (public.flujo_cap('recibe') OR public.flujo_cap('caja') OR public.flujo_es_admin()) THEN
    RAISE EXCEPTION 'No tienes asignada una etapa del flujo de dinero';
  END IF;
  RETURN QUERY
    SELECT t.id, t.folio, t.estatus, t.operacion,
           t.cuenta_origen_id, co.nombre, t.cuenta_destino_id, cd.nombre,
           t.moneda_origen, t.moneda_destino, t.monto_origen, t.monto_destino, t.tipo_cambio,
           t.fecha, t.concepto, t.referencia, t.es_prueba,
           t.creado_por, public.flujo_nombre(t.creado_por), t.creado_at,
           public.flujo_nombre(t.confirmado_por), t.confirmado_at, t.caja_notas,
           t.motivo_rechazo, t.motivo_reversion
      FROM public.traspasos_cuentas t
      JOIN public.cuentas_financieras co ON co.id = t.cuenta_origen_id
      JOIN public.cuentas_financieras cd ON cd.id = t.cuenta_destino_id
     WHERE (public.es_usuario_prueba(auth.uid()) AND t.es_prueba) OR (NOT public.es_usuario_prueba(auth.uid()) AND NOT t.es_prueba)
     ORDER BY t.creado_at DESC
     LIMIT greatest(1, least(coalesce(_limite, 200), 1000));
END;
$$;
REVOKE ALL ON FUNCTION public.traspaso_listar(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.traspaso_listar(integer) TO authenticated;

DO $postflight$
BEGIN
  IF to_regclass('public.traspasos_cuentas') IS NULL
     OR NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='movimientos_financieros' AND column_name='traspaso_id') THEN
    RAISE EXCEPTION 'Traspasos: no quedó la tabla o la columna traspaso_id.';
  END IF;
  IF position('flujo_escribe' in pg_get_functiondef('public.traspaso_confirmar(uuid,text)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'traspaso_confirmar no quedó con la llave del candado.';
  END IF;
  IF has_function_privilege('anon', 'public.traspaso_confirmar(uuid,text)', 'execute')
     OR has_function_privilege('anon', 'public.traspaso_solicitar(uuid,uuid,numeric,numeric,date,text,text)', 'execute')
     OR has_table_privilege('authenticated', 'public.traspasos_cuentas', 'select') THEN
    RAISE EXCEPTION 'Los traspasos no deben estar abiertos a anon ni a lectura directa.';
  END IF;
END $postflight$;

-- ── Verificación (solo lectura) ─────────────────────────────────────────────
-- 1) SELECT count(*) FROM public.traspasos_cuentas;
-- 2) Cada traspaso CONFIRMADO tiene dos movimientos CONFIRMADO con su traspaso_id y el mismo monto_mxn:
--    SELECT t.folio FROM public.traspasos_cuentas t WHERE t.estatus = 'CONFIRMADO' AND NOT t.es_prueba
--       AND (SELECT count(*) FROM public.movimientos_financieros m WHERE m.traspaso_id = t.id AND m.estatus = 'CONFIRMADO') <> 2;
--    (debe regresar 0 filas)

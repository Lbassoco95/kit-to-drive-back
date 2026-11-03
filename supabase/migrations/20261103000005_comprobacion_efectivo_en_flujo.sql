-- ============================================================================
-- La comprobación de efectivo vive en el Flujo de dinero (2026-11-03)
--
-- Control Financiero ya es solo de consulta (20261103000004), así que la
-- comprobación del efectivo que se entrega a un intermediario se hace aquí:
--
--  · Al registrar una SALIDA en efectivo se puede indicar el intermediario que
--    lo va a gastar: el renglón queda «por comprobar» y, cuando Caja lo registra,
--    el egreso de Control Financiero sale como «vía intermediario» (igual que
--    antes lo marcaba su regla de comprobación).
--  · flujo_comprobar(id, monto comprobado, monto devuelto, notas): quien lleva
--    caja o aplica (o un administrador del flujo) comprueba lo gastado y lo que
--    regresó de cambio. Comprobado + devuelto no puede pasar de lo entregado.
--    La comprobación se copia al movimiento de Control Financiero, que la muestra
--    y la quita de «por comprobar».
--  · Como antes, el cambio devuelto solo se registra (no genera un ingreso).
--
-- flujo_recibir cambia de firma (agrega _intermediario con valor por omisión):
-- se elimina la versión de 10 parámetros para que la llamada no sea ambigua.
-- flujo_confirmar_caja se redefine (idéntica + vía/intermediario del egreso).
--
-- Idempotente. Para el SQL editor de Supabase; NO usar `supabase db push`.
-- Para revertir: DROP FUNCTION flujo_comprobar(uuid, numeric, numeric, text); y volver a
--   flujo_recibir (10 parámetros) y flujo_confirmar_caja de 20261103000004.
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := '{}';
BEGIN
  IF to_regclass('public.flujo_dinero') IS NULL THEN _faltan := _faltan || 'tabla flujo_dinero'::text; END IF;
  IF to_regclass('public.movimientos_financieros') IS NULL THEN _faltan := _faltan || 'tabla movimientos_financieros'::text; END IF;
  IF to_regprocedure('public.flujo_confirmar_caja(uuid,uuid,text)') IS NULL THEN _faltan := _faltan || 'función flujo_confirmar_caja'::text; END IF;
  IF to_regprocedure('public.flujo_es_admin(uuid)') IS NULL THEN _faltan := _faltan || 'función flujo_es_admin'::text; END IF;
  IF to_regprocedure('public.flujo_cap(text,uuid)') IS NULL THEN _faltan := _faltan || 'función flujo_cap'::text; END IF;
  IF to_regprocedure('public._candado_movimientos_solo_flujo()') IS NULL THEN _faltan := _faltan || 'candado (20261103000004)'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='movimientos_financieros' AND column_name='intermediario_nombre') THEN
    _faltan := _faltan || 'columna movimientos_financieros.intermediario_nombre'::text;
  END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ', ');
  END IF;
END;
$preflight$;

-- ── 1. Columnas de comprobación en el flujo ─────────────────────────────────
ALTER TABLE public.flujo_dinero
  ADD COLUMN IF NOT EXISTS requiere_comprobacion boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS intermediario_nombre text,
  ADD COLUMN IF NOT EXISTS comprobado boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS monto_comprobado numeric(18, 2),
  ADD COLUMN IF NOT EXISTS monto_devuelto numeric(18, 2),
  ADD COLUMN IF NOT EXISTS comprobado_por uuid,
  ADD COLUMN IF NOT EXISTS comprobado_at timestamptz,
  ADD COLUMN IF NOT EXISTS comprobacion_notas text;

DO $chk$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'flujo_comprobacion_montos') THEN
    ALTER TABLE public.flujo_dinero ADD CONSTRAINT flujo_comprobacion_montos CHECK (
      (monto_comprobado IS NULL OR monto_comprobado >= 0) AND (monto_devuelto IS NULL OR monto_devuelto >= 0)
      AND (NOT requiere_comprobacion OR intermediario_nombre IS NOT NULL));
  END IF;
END
$chk$;

-- La vista fija sus columnas: se recrea (mismo orden) y se agregan las nuevas al final.
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
       f.cxc_abono_id,
       f.requiere_comprobacion, f.intermediario_nombre, f.comprobado, f.monto_comprobado, f.monto_devuelto,
       f.comprobado_por, f.comprobado_at, f.comprobacion_notas,
       public.flujo_nombre(f.comprobado_por) AS comprobado_por_nombre
  FROM public.flujo_dinero f;
GRANT SELECT ON public.v_flujo_dinero TO authenticated;

-- ── 2. Registrar con intermediario ──────────────────────────────────────────
DROP FUNCTION IF EXISTS public.flujo_recibir(text, numeric, text, text, date, text, uuid, text, text, numeric);
CREATE OR REPLACE FUNCTION public.flujo_recibir(
  _tipo text, _monto numeric, _moneda text, _metodo_pago text, _fecha date, _contraparte_nombre text,
  _cliente_id uuid DEFAULT NULL, _concepto text DEFAULT NULL, _referencia text DEFAULT NULL, _tipo_cambio numeric DEFAULT NULL,
  _intermediario text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cli public.clientes%ROWTYPE;
  v_prueba boolean := public.es_usuario_prueba(auth.uid());
  v_id uuid;
  v_folio text;
  v_inter text := nullif(btrim(coalesce(_intermediario, '')), '');
BEGIN
  IF NOT public.flujo_cap('recibe') THEN RAISE EXCEPTION 'No tienes asignada la etapa de recepción'; END IF;
  IF _tipo NOT IN ('PAGO_CLIENTE', 'REEMBOLSO', 'SALIDA') THEN RAISE EXCEPTION 'Tipo inválido: %', _tipo; END IF;
  IF _monto IS NULL OR _monto <= 0 THEN RAISE EXCEPTION 'El monto debe ser mayor a cero'; END IF;
  IF nullif(btrim(coalesce(_contraparte_nombre, '')), '') IS NULL THEN RAISE EXCEPTION 'Indica quién entregó o recibe el dinero'; END IF;
  IF _metodo_pago <> 'EFECTIVO' AND nullif(btrim(coalesce(_referencia, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Captura la referencia o folio del movimiento';
  END IF;
  IF _tipo <> 'PAGO_CLIENTE' AND nullif(btrim(coalesce(_concepto, '')), '') IS NULL THEN
    RAISE EXCEPTION 'El concepto es obligatorio';
  END IF;
  IF v_inter IS NOT NULL AND NOT (_tipo = 'SALIDA' AND _metodo_pago = 'EFECTIVO') THEN
    RAISE EXCEPTION 'El intermediario solo aplica a una salida de dinero en efectivo';
  END IF;
  IF _tipo = 'PAGO_CLIENTE' THEN
    IF _moneda <> 'MXN' THEN RAISE EXCEPTION 'Los pagos de cliente a remisiones se reciben en MXN'; END IF;
    IF _metodo_pago NOT IN ('EFECTIVO', 'TRANSFERENCIA', 'DEPOSITO') THEN
      RAISE EXCEPTION 'Un pago de cliente se recibe en efectivo, transferencia o depósito';
    END IF;
    SELECT * INTO v_cli FROM public.clientes WHERE id = _cliente_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Elige el cliente que pagó'; END IF;
    PERFORM public.exigir_dato_prueba(v_cli.es_prueba, 'el cliente ' || coalesce(v_cli.nombre_comercial, ''));
    v_prueba := v_cli.es_prueba;
  END IF;

  INSERT INTO public.flujo_dinero (tipo, monto, moneda, tipo_cambio, metodo_pago, fecha, contraparte_nombre, cliente_id,
                                   concepto, referencia, es_prueba, recibido_por, requiere_comprobacion, intermediario_nombre)
  VALUES (_tipo, round(_monto, 2), coalesce(_moneda, 'MXN'), CASE WHEN coalesce(_moneda, 'MXN') = 'MXN' THEN NULL ELSE _tipo_cambio END,
          _metodo_pago::public.metodo_pago, _fecha, btrim(_contraparte_nombre), CASE WHEN _tipo = 'PAGO_CLIENTE' THEN _cliente_id END,
          nullif(btrim(coalesce(_concepto, '')), ''), nullif(btrim(coalesce(_referencia, '')), ''), v_prueba, auth.uid(),
          v_inter IS NOT NULL, v_inter)
  RETURNING id, folio INTO v_id, v_folio;

  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_recibir', 'flujo_dinero', v_id, v_folio,
    jsonb_build_object('tipo', _tipo, 'monto', _monto, 'moneda', _moneda, 'intermediario', v_inter), v_prueba);
  RETURN jsonb_build_object('id', v_id, 'folio', v_folio);
END;
$$;
REVOKE ALL ON FUNCTION public.flujo_recibir(text, numeric, text, text, date, text, uuid, text, text, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_recibir(text, numeric, text, text, date, text, uuid, text, text, numeric, text) TO authenticated;

-- ── 3. Caja: el egreso sale «vía intermediario» cuando hay comprobación ─────
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

-- ── 4. Comprobar el efectivo ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.flujo_comprobar(
  _id uuid, _monto_comprobado numeric, _monto_devuelto numeric DEFAULT 0, _notas text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  f public.flujo_dinero%ROWTYPE;
  v_dev numeric := round(coalesce(_monto_devuelto, 0), 2);
  v_comp numeric := round(_monto_comprobado, 2);
BEGIN
  IF NOT (public.flujo_es_admin() OR public.flujo_cap('caja') OR public.flujo_cap('aplica')) THEN
    RAISE EXCEPTION 'Solo Caja, Aplicación o un administrador del flujo comprueban el efectivo';
  END IF;
  SELECT * INTO f FROM public.flujo_dinero WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el movimiento'; END IF;
  PERFORM public.exigir_dato_prueba(f.es_prueba, 'el movimiento ' || f.folio);
  IF NOT f.requiere_comprobacion THEN RAISE EXCEPTION '% no requiere comprobación', f.folio; END IF;
  IF f.comprobado THEN RAISE EXCEPTION '% ya está comprobado', f.folio; END IF;
  IF f.etapa NOT IN ('EN_CAJA', 'APLICADO') THEN
    RAISE EXCEPTION '% se comprueba cuando el dinero ya salió de caja (etapa: %)', f.folio, f.etapa;
  END IF;
  IF v_comp IS NULL OR v_comp < 0 THEN RAISE EXCEPTION 'Captura lo comprobado (0 o más)'; END IF;
  IF v_dev < 0 THEN RAISE EXCEPTION 'El cambio devuelto no puede ser negativo'; END IF;
  IF v_comp + v_dev > f.monto THEN
    RAISE EXCEPTION 'Lo comprobado (%) más el cambio devuelto (%) supera lo entregado (%)',
      to_char(v_comp, 'FM999,999,990.00'), to_char(v_dev, 'FM999,999,990.00'), to_char(f.monto, 'FM999,999,990.00');
  END IF;

  UPDATE public.flujo_dinero
     SET comprobado = true, monto_comprobado = v_comp, monto_devuelto = v_dev,
         comprobado_por = auth.uid(), comprobado_at = now(),
         comprobacion_notas = nullif(btrim(coalesce(_notas, '')), '')
   WHERE id = f.id;

  IF f.movimiento_id IS NOT NULL THEN
    PERFORM set_config('kit.flujo_escribe', 'on', true);
    UPDATE public.movimientos_financieros
       SET comprobado = true, monto_comprobado = v_comp, monto_devuelto = v_dev,
           comprobado_por = auth.uid(), comprobado_at = now()
     WHERE id = f.movimiento_id;
    PERFORM set_config('kit.flujo_escribe', '', true);
  END IF;

  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_comprobar', 'flujo_dinero', f.id, f.folio,
    jsonb_build_object('comprobado', v_comp, 'devuelto', v_dev, 'sin_comprobar', f.monto - v_comp - v_dev), f.es_prueba);
  RETURN jsonb_build_object('folio', f.folio, 'sin_comprobar', f.monto - v_comp - v_dev);
END;
$$;
REVOKE ALL ON FUNCTION public.flujo_comprobar(uuid, numeric, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_comprobar(uuid, numeric, numeric, text) TO authenticated;

REVOKE ALL ON FUNCTION public.flujo_confirmar_caja(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_confirmar_caja(uuid, uuid, text) TO authenticated;

DO $postflight$
BEGIN
  IF position('mov_via' in pg_get_functiondef('public.flujo_confirmar_caja(uuid,uuid,text)'::regprocedure)) = 0
     OR position('flujo_escribe' in pg_get_functiondef('public.flujo_confirmar_caja(uuid,uuid,text)'::regprocedure)) = 0
     OR position('cxc_abono_id' in pg_get_functiondef('public.flujo_confirmar_caja(uuid,uuid,text)'::regprocedure)) = 0
     OR position('cuenta de banco' in pg_get_functiondef('public.flujo_confirmar_caja(uuid,uuid,text)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'flujo_confirmar_caja no quedó completa.';
  END IF;
  IF has_function_privilege('anon', 'public.flujo_comprobar(uuid,numeric,numeric,text)', 'execute')
     OR has_function_privilege('anon', 'public.flujo_recibir(text,numeric,text,text,date,text,uuid,text,text,numeric,text)', 'execute')
     OR has_function_privilege('anon', 'public.flujo_confirmar_caja(uuid,uuid,text)', 'execute') THEN
    RAISE EXCEPTION 'Las funciones del flujo no deben estar abiertas a anon.';
  END IF;
END $postflight$;

-- ── Verificación (solo lectura) ─────────────────────────────────────────────
-- 1) SELECT to_regprocedure('public.flujo_comprobar(uuid,numeric,numeric,text)') IS NOT NULL;
-- 2) Registra una salida en efectivo con intermediario, ponla en caja y compruébala desde el flujo.

-- ============================================================================
-- El cambio devuelto en una comprobación suma a la caja (2026-11-03)
--
-- Antes (20261103000005) el cambio devuelto solo se registraba como dato. Ahora,
-- al comprobar con cambio devuelto > 0:
--   · nace un renglón del flujo, tipo REEMBOLSO, ya APLICADO (destino «Reembolso
--     de empleado / comprobación»), en EFECTIVO, en la misma caja de la que salió
--     el dinero y con la misma moneda; concepto «Cambio devuelto de FD-…»;
--   · si el dinero es real, se crea el ingreso confirmado en Control Financiero y
--     el saldo de esa caja sube por el cambio;
--   · todo dentro de la misma transacción de flujo_comprobar (si algo falla, no
--     se comprueba nada).
-- Los datos de prueba solo generan el renglón del flujo, sin ingreso (igual que
-- Caja). La respuesta de la función agrega `cambio_folio`.
--
-- Solo redefine flujo_comprobar (idéntica a la de 20261103000005 + el cambio).
-- Idempotente. Para el SQL editor de Supabase; NO usar `supabase db push`.
-- Para revertir: volver a la definición de flujo_comprobar de 20261103000005.
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := '{}';
BEGIN
  IF to_regprocedure('public.flujo_comprobar(uuid,numeric,numeric,text)') IS NULL THEN _faltan := _faltan || 'función flujo_comprobar (20261103000005)'::text; END IF;
  IF to_regprocedure('public._candado_movimientos_solo_flujo()') IS NULL THEN _faltan := _faltan || 'candado (20261103000004)'::text; END IF;
  IF to_regclass('public.movimientos_financieros') IS NULL THEN _faltan := _faltan || 'tabla movimientos_financieros'::text; END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ', ');
  END IF;
END;
$preflight$;

CREATE OR REPLACE FUNCTION public.flujo_comprobar(
  _id uuid, _monto_comprobado numeric, _monto_devuelto numeric DEFAULT 0, _notas text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  f public.flujo_dinero%ROWTYPE;
  v_dev numeric := round(coalesce(_monto_devuelto, 0), 2);
  v_comp numeric := round(_monto_comprobado, 2);
  v_hoy date := (now() AT TIME ZONE 'America/Mexico_City')::date;
  v_mov uuid;
  v_cambio public.flujo_dinero%ROWTYPE;
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

  -- El cambio devuelto regresa a la caja de la que salió: nace en el flujo como un
  -- reembolso ya aplicado (comprobación) y su ingreso suma al saldo de esa caja.
  IF v_dev > 0 THEN
    v_mov := NULL;
    IF NOT f.es_prueba AND f.cuenta_id IS NOT NULL THEN
      PERFORM set_config('kit.flujo_escribe', 'on', true);
      INSERT INTO public.movimientos_financieros
        (tipo, estatus, concepto, descripcion, monto, moneda, tipo_cambio, fecha_movimiento, metodo_pago, cuenta_id, referencia,
         contraparte_tipo, contraparte_nombre, recibido_por, created_by, confirmado_por, confirmado_at)
      VALUES
        ('INGRESO'::public.mov_tipo, 'CONFIRMADO', 'Cambio devuelto de ' || f.folio,
         'Comprobación de ' || f.folio || ' (cambio devuelto por ' || coalesce(f.intermediario_nombre, '—') || ')',
         v_dev, f.moneda, f.tipo_cambio, v_hoy, 'EFECTIVO', f.cuenta_id, f.folio,
         'OTRO'::public.contraparte_tipo, coalesce(f.intermediario_nombre, 'Intermediario'), auth.uid(), auth.uid(), auth.uid(), now())
      RETURNING id INTO v_mov;
      PERFORM set_config('kit.flujo_escribe', '', true);
    END IF;
    INSERT INTO public.flujo_dinero
      (tipo, etapa, monto, moneda, tipo_cambio, metodo_pago, fecha, contraparte_nombre, concepto, referencia, es_prueba,
       recibido_por, recibido_at, cuenta_id, caja_por, caja_at, caja_notas, movimiento_id,
       destino, aplicado_por, aplicado_at, aplicado_notas)
    VALUES
      ('REEMBOLSO', 'APLICADO', v_dev, f.moneda, f.tipo_cambio, 'EFECTIVO', v_hoy,
       coalesce(f.intermediario_nombre, 'Intermediario'), 'Cambio devuelto de ' || f.folio, f.folio, f.es_prueba,
       auth.uid(), now(), f.cuenta_id, auth.uid(), now(), 'Cambio de la comprobación de ' || f.folio, v_mov,
       'REEMBOLSO_EMPLEADO', auth.uid(), now(), 'Comprobación de ' || f.folio)
    RETURNING * INTO v_cambio;
  END IF;

  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_comprobar', 'flujo_dinero', f.id, f.folio,
    jsonb_build_object('comprobado', v_comp, 'devuelto', v_dev, 'sin_comprobar', f.monto - v_comp - v_dev,
                       'cambio_flujo', v_cambio.folio, 'cambio_movimiento', v_mov), f.es_prueba);
  RETURN jsonb_build_object('folio', f.folio, 'sin_comprobar', f.monto - v_comp - v_dev, 'cambio_folio', v_cambio.folio);
END;
$$;

REVOKE ALL ON FUNCTION public.flujo_comprobar(uuid, numeric, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_comprobar(uuid, numeric, numeric, text) TO authenticated;

DO $postflight$
BEGIN
  IF position('cambio_folio' in pg_get_functiondef('public.flujo_comprobar(uuid,numeric,numeric,text)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'flujo_comprobar no quedó con el registro del cambio.';
  END IF;
  IF has_function_privilege('anon', 'public.flujo_comprobar(uuid,numeric,numeric,text)', 'execute') THEN
    RAISE EXCEPTION 'flujo_comprobar no debe estar abierta a anon.';
  END IF;
END $postflight$;

-- ── Verificación (solo lectura) ─────────────────────────────────────────────
-- Comprueba una salida con cambio: aparece un «Reembolso recibido» aplicado en el flujo y el
-- saldo de la caja sube por el cambio.

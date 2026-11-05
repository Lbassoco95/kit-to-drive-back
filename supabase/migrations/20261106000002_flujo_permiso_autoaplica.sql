-- ============================================================================
-- Flujo de dinero: permiso «autorizar mis propios movimientos» (2026-11-06)
--
-- Los permisos del flujo ya son POR USUARIO (registrar, caja, aplicar), no por rol del sistema:
-- un administrador del flujo se los asigna a cada persona. Esta migración agrega un cuarto
-- permiso, también por usuario: `autoaplica`.
--
--  · No da una etapa nueva: solo levanta la separación de funciones para esa persona, que
--    entonces puede confirmar en caja y/o aplicar lo que ella misma registró (o metió a caja).
--    Sigue necesitando el permiso de la etapa (caja / aplica).
--  · Lo asigna un administrador del flujo (flujo_asignar_capacidad(…, 'autoaplica', true)).
--  · Todo movimiento donde se usó queda marcado `autoautorizado` (se ve en la lista) y en bitácora.
--
-- Solo agrega: sin este permiso todo sigue exactamente igual.
-- Idempotente. Para el SQL editor de Supabase; NO usar `supabase db push`.
-- Para revertir: quitar el permiso a todos y volver a flujo_confirmar_caja / flujo_aplicar de 20261105000001.
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := '{}';
BEGIN
  IF to_regclass('public.flujo_capacidades') IS NULL THEN _faltan := _faltan || 'tabla flujo_capacidades'::text; END IF;
  IF to_regprocedure('public.flujo_asignar_capacidad(uuid,text,boolean)') IS NULL THEN _faltan := _faltan || 'flujo_asignar_capacidad'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='flujo_dinero' AND column_name='cuenta_prevista_id') THEN
    _faltan := _faltan || 'flujo_dinero.cuenta_prevista_id (20261105000001)'::text;
  END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ', ');
  END IF;
END;
$preflight$;

-- ── 1. El permiso y la marca ────────────────────────────────────────────────
ALTER TABLE public.flujo_capacidades ADD COLUMN IF NOT EXISTS autoaplica boolean NOT NULL DEFAULT false;
ALTER TABLE public.flujo_dinero ADD COLUMN IF NOT EXISTS autoautorizado boolean NOT NULL DEFAULT false;

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
       public.flujo_nombre(f.comprobado_por) AS comprobado_por_nombre,
       public.flujo_resumen_aplicacion(f.cobranza_pago_id, f.cxc_abono_id) AS aplicacion,
       f.categoria, f.descripcion, f.contraparte_tipo, f.proveedor_id, f.empleado_id, f.via, f.intermediario_id,
       f.factura_folio, f.factura_uuid, f.factura_rfc, f.remision_id, f.cuenta_prevista_id, f.quien_recibio,
       f.autoautorizado
  FROM public.flujo_dinero f;
GRANT SELECT ON public.v_flujo_dinero TO authenticated;

-- ── 2. Consultar y asignar permisos (ahora con autoaplica) ──────────────────
CREATE OR REPLACE FUNCTION public.flujo_cap(_cap text, _uid uuid DEFAULT auth.uid())
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT _uid IS NOT NULL AND public.usuario_activo(_uid)
     AND coalesce((SELECT CASE _cap WHEN 'recibe' THEN c.recibe WHEN 'caja' THEN c.caja WHEN 'aplica' THEN c.aplica
                                    WHEN 'autoaplica' THEN c.autoaplica END
                     FROM public.flujo_capacidades c WHERE c.user_id = _uid), false)
$$;

CREATE OR REPLACE FUNCTION public.flujo_mis_capacidades()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT jsonb_build_object('recibe', public.flujo_cap('recibe'), 'caja', public.flujo_cap('caja'), 'aplica', public.flujo_cap('aplica'),
                            'autoaplica', public.flujo_cap('autoaplica'))
$$;

DROP FUNCTION IF EXISTS public.flujo_listar_capacidades();
CREATE OR REPLACE FUNCTION public.flujo_listar_capacidades()
RETURNS TABLE (user_id uuid, nombre text, recibe boolean, caja boolean, aplica boolean, autoaplica boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.flujo_es_admin() THEN RAISE EXCEPTION 'Sólo un administrador ve quién hace cada etapa'; END IF;
  RETURN QUERY
    SELECT p.id, coalesce(nullif(btrim(p.nombre_completo), ''), p.id::text),
           coalesce(c.recibe, false), coalesce(c.caja, false), coalesce(c.aplica, false), coalesce(c.autoaplica, false)
      FROM public.profiles p
      LEFT JOIN public.flujo_capacidades c ON c.user_id = p.id
     WHERE public.usuario_activo(p.id)
     ORDER BY 2;
END;
$$;
REVOKE ALL ON FUNCTION public.flujo_listar_capacidades() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_listar_capacidades() TO authenticated;

CREATE OR REPLACE FUNCTION public.flujo_asignar_capacidad(_user_id uuid, _capacidad text, _valor boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.flujo_es_admin() THEN RAISE EXCEPTION 'Sólo un administrador asigna las etapas del flujo de dinero'; END IF;
  IF _capacidad NOT IN ('recibe', 'caja', 'aplica', 'autoaplica') THEN RAISE EXCEPTION 'Capacidad inválida: %', _capacidad; END IF;
  INSERT INTO public.flujo_capacidades (user_id) VALUES (_user_id) ON CONFLICT (user_id) DO NOTHING;
  EXECUTE format('UPDATE public.flujo_capacidades SET %I = $1, updated_by = $2, updated_at = now() WHERE user_id = $3', _capacidad)
    USING coalesce(_valor, false), auth.uid(), _user_id;
  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_asignar_capacidad', 'flujo_capacidades', NULL, NULL,
    jsonb_build_object('usuario', _user_id, 'capacidad', _capacidad, 'valor', _valor), public.es_usuario_prueba(auth.uid()));
END;
$$;
REVOKE ALL ON FUNCTION public.flujo_asignar_capacidad(uuid, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_asignar_capacidad(uuid, text, boolean) TO authenticated;

-- ── 3. Caja y aplicación respetan el permiso ────────────────────────────────
CREATE OR REPLACE FUNCTION public.flujo_confirmar_caja(_id uuid, _cuenta_id uuid, _notas text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  f public.flujo_dinero%ROWTYPE;
  c public.cuentas_financieras%ROWTYPE;
  v_mov uuid;
  v_auto boolean := false;
BEGIN
  IF NOT public.flujo_cap('caja') THEN RAISE EXCEPTION 'No tienes asignada la etapa de caja'; END IF;
  SELECT * INTO f FROM public.flujo_dinero WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el movimiento'; END IF;
  PERFORM public.exigir_dato_prueba(f.es_prueba, 'el movimiento ' || f.folio);
  IF f.etapa <> 'RECIBIDO' THEN RAISE EXCEPTION '% no está pendiente de caja (etapa: %)', f.folio, f.etapa; END IF;
  v_auto := (f.recibido_por = auth.uid());
  IF v_auto AND NOT public.flujo_cap('autoaplica') THEN
    RAISE EXCEPTION 'Quien recibió el dinero no puede registrarlo en caja: lo hace otra persona (o un administrador te da el permiso de autorizar tus propios movimientos)';
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
    (tipo, estatus, concepto, categoria, descripcion, monto, moneda, tipo_cambio, fecha_movimiento, metodo_pago, cuenta_id, referencia,
     contraparte_tipo, cliente_id, proveedor_id, empleado_id, contraparte_nombre, recibido_por, created_by, confirmado_por, confirmado_at,
     via, intermediario_id, intermediario_nombre, factura_folio, factura_uuid, factura_rfc, remision_id)
  VALUES
    (CASE WHEN f.tipo = 'SALIDA' THEN 'EGRESO'::public.mov_tipo ELSE 'INGRESO'::public.mov_tipo END, 'CONFIRMADO',
     coalesce(f.concepto, 'Pago de cliente ' || f.contraparte_nombre), f.categoria,
     coalesce(f.descripcion, 'Flujo de dinero ' || f.folio),
     f.monto, f.moneda, f.tipo_cambio, f.fecha, f.metodo_pago, c.id, f.referencia,
     coalesce(f.contraparte_tipo::public.contraparte_tipo,
              CASE WHEN f.cliente_id IS NULL THEN 'OTRO'::public.contraparte_tipo ELSE 'CLIENTE'::public.contraparte_tipo END),
     f.cliente_id, f.proveedor_id, f.empleado_id, f.contraparte_nombre, coalesce(f.quien_recibio, f.recibido_por), auth.uid(), auth.uid(), now(),
     CASE WHEN f.requiere_comprobacion OR f.via = 'INTERMEDIARIO' THEN 'INTERMEDIARIO'::public.mov_via ELSE 'DIRECTO'::public.mov_via END,
     f.intermediario_id,
     CASE WHEN f.requiere_comprobacion OR f.via = 'INTERMEDIARIO' THEN f.intermediario_nombre END,
     f.factura_folio, f.factura_uuid, f.factura_rfc, f.remision_id)
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
  IF v_auto THEN
    UPDATE public.flujo_dinero SET autoautorizado = true WHERE id = f.id;
  END IF;
  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_caja', 'flujo_dinero', f.id, f.folio,
    jsonb_build_object('cuenta', c.nombre, 'movimiento_id', v_mov), f.es_prueba);
END;
$$;
REVOKE ALL ON FUNCTION public.flujo_confirmar_caja(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_confirmar_caja(uuid, uuid, text) TO authenticated;

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
  v_auto boolean := false;
BEGIN
  IF NOT public.flujo_cap('aplica') THEN RAISE EXCEPTION 'No tienes asignada la etapa de aplicación'; END IF;
  SELECT * INTO f FROM public.flujo_dinero WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el movimiento'; END IF;
  PERFORM public.exigir_dato_prueba(f.es_prueba, 'el movimiento ' || f.folio);
  IF f.etapa <> 'EN_CAJA' THEN RAISE EXCEPTION '% no está pendiente de aplicar (etapa: %)', f.folio, f.etapa; END IF;
  v_auto := (auth.uid() IN (f.recibido_por, f.caja_por));
  IF v_auto AND NOT public.flujo_cap('autoaplica') THEN
    RAISE EXCEPTION 'Quien recibió o metió el dinero a caja no puede aplicarlo: lo hace una tercera persona (o un administrador te da el permiso de autorizar tus propios movimientos)';
  END IF;
  IF NOT ((f.tipo = 'PAGO_CLIENTE' AND _destino IN ('REMISION', 'OTRO'))
       OR (f.tipo = 'REEMBOLSO' AND _destino IN ('REEMBOLSO_PROVEEDOR', 'REEMBOLSO_EMPLEADO', 'OTRO'))
       OR (f.tipo = 'INGRESO' AND _destino = 'OTRO')
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
  IF v_auto THEN
    UPDATE public.flujo_dinero SET autoautorizado = true WHERE id = f.id;
  END IF;
  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_aplicar', 'flujo_dinero', f.id, f.folio,
    jsonb_build_object('destino', _destino, 'aplicaciones', _aplicaciones, 'pago_cobranza', v_pfolio, 'saldo_favor', v_saldo_folio), f.es_prueba);
  RETURN jsonb_build_object('aplicadas', v_n, 'pago', v_pfolio, 'saldo_favor', v_saldo_folio);
END;
$$;
REVOKE ALL ON FUNCTION public.flujo_aplicar(uuid, text, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_aplicar(uuid, text, jsonb, text) TO authenticated;

DO $postflight$
BEGIN
  IF position('autoaplica' in pg_get_functiondef('public.flujo_confirmar_caja(uuid,uuid,text)'::regprocedure)) = 0
     OR position('autoaplica' in pg_get_functiondef('public.flujo_aplicar(uuid,text,jsonb,text)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'Caja o aplicación no quedaron respetando el permiso.';
  END IF;
  IF has_function_privilege('anon', 'public.flujo_listar_capacidades()', 'execute') THEN
    RAISE EXCEPTION 'flujo_listar_capacidades no debe estar abierta a anon.';
  END IF;
END $postflight$;

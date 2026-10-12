-- ============================================================================
-- Flujo de dinero en tres etapas (Control Financiero)
--
--   1. RECEPCIÓN  (capacidad `recibe`): quien recibe el dinero lo registra.
--   2. CAJA       (capacidad `caja`):   quien lleva la caja confirma que entró
--                                       (o salió) el efectivo. Aquí nace el
--                                       movimiento CONFIRMADO del libro mayor.
--   3. APLICACIÓN (capacidad `aplica`): asigna el dinero. Pago de cliente →
--                                       cobranza (abona a remisiones; el sobrante
--                                       queda como saldo a favor). Reembolso o
--                                       salida → se clasifica.
--
-- Separación de funciones (la hace cumplir la base, no la pantalla):
--   · quien recibió no registra su propia caja;
--   · quien recibió o metió el dinero a caja no lo aplica.
-- Las capacidades las asigna un administrador, por usuario.
--
-- Todo el acceso de escritura es por RPC; las tablas no se escriben directo.
-- Idempotente. Depende de: movimientos_financieros, cuentas_financieras,
-- cobranza_* (20261006000003), profiles, clientes.
-- ============================================================================

-- ── 1. Capacidades por usuario ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.flujo_capacidades (
  user_id    uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  recibe     boolean NOT NULL DEFAULT false,
  caja       boolean NOT NULL DEFAULT false,
  aplica     boolean NOT NULL DEFAULT false,
  updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- ── 2. El flujo ────────────────────────────────────────────────────────────
CREATE SEQUENCE IF NOT EXISTS public.seq_folio_flujo_dinero START 1;

CREATE TABLE IF NOT EXISTS public.flujo_dinero (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  folio              text NOT NULL UNIQUE
                       DEFAULT ('FD-' || lpad(nextval('public.seq_folio_flujo_dinero')::text, 6, '0')),
  tipo               text NOT NULL CHECK (tipo IN ('PAGO_CLIENTE', 'REEMBOLSO', 'SALIDA')),
  etapa              text NOT NULL DEFAULT 'RECIBIDO' CHECK (etapa IN ('RECIBIDO', 'EN_CAJA', 'APLICADO', 'RECHAZADO')),
  monto              numeric(18, 2) NOT NULL CHECK (monto > 0),
  moneda             text NOT NULL DEFAULT 'MXN',
  tipo_cambio        numeric(12, 4),
  metodo_pago        public.metodo_pago NOT NULL,
  fecha              date NOT NULL,
  contraparte_nombre text NOT NULL,
  cliente_id         uuid REFERENCES public.clientes(id),
  concepto           text,
  referencia         text,
  es_prueba          boolean NOT NULL DEFAULT false,
  -- etapa 1
  recibido_por       uuid NOT NULL REFERENCES auth.users(id),
  recibido_at        timestamptz NOT NULL DEFAULT now(),
  -- etapa 2
  cuenta_id          uuid REFERENCES public.cuentas_financieras(id),
  caja_por           uuid REFERENCES auth.users(id),
  caja_at            timestamptz,
  caja_notas         text,
  movimiento_id      uuid REFERENCES public.movimientos_financieros(id),
  -- etapa 3
  destino            text CHECK (destino IN ('REMISION', 'REEMBOLSO_PROVEEDOR', 'REEMBOLSO_EMPLEADO', 'GASTO', 'PAGO_PROVEEDOR', 'OTRO')),
  aplicado_por       uuid REFERENCES auth.users(id),
  aplicado_at        timestamptz,
  aplicado_notas     text,
  cobranza_pago_id   uuid REFERENCES public.cobranza_pagos(id),
  -- rechazo
  rechazado_por      uuid REFERENCES auth.users(id),
  rechazado_at       timestamptz,
  motivo_rechazo     text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT flujo_cliente_requerido CHECK (tipo <> 'PAGO_CLIENTE' OR cliente_id IS NOT NULL),
  CONSTRAINT flujo_tipo_cambio CHECK (moneda = 'MXN' OR (tipo_cambio IS NOT NULL AND tipo_cambio > 0)),
  CONSTRAINT flujo_rechazo_motivo CHECK (etapa <> 'RECHAZADO' OR nullif(btrim(coalesce(motivo_rechazo, '')), '') IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS idx_flujo_dinero_etapa ON public.flujo_dinero (etapa, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_flujo_dinero_cliente ON public.flujo_dinero (cliente_id) WHERE cliente_id IS NOT NULL;

ALTER TABLE public.flujo_capacidades ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.flujo_dinero ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.flujo_capacidades FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.flujo_dinero FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.flujo_capacidades TO authenticated;
GRANT SELECT ON public.flujo_dinero TO authenticated;

-- Lo recibido no se borra: se rechaza con motivo.
CREATE OR REPLACE FUNCTION public.flujo_dinero_sin_borrar()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'En el flujo de dinero nada se borra: se rechaza con motivo.';
END;
$$;
DROP TRIGGER IF EXISTS trg_flujo_dinero_sin_borrar ON public.flujo_dinero;
CREATE TRIGGER trg_flujo_dinero_sin_borrar BEFORE DELETE ON public.flujo_dinero
  FOR EACH ROW EXECUTE FUNCTION public.flujo_dinero_sin_borrar();

-- ── 3. Helpers de permiso ──────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.flujo_cap(_cap text, _uid uuid DEFAULT auth.uid())
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT _uid IS NOT NULL AND public.usuario_activo(_uid)
     AND coalesce((SELECT CASE _cap WHEN 'recibe' THEN c.recibe WHEN 'caja' THEN c.caja WHEN 'aplica' THEN c.aplica END
                     FROM public.flujo_capacidades c WHERE c.user_id = _uid), false)
$$;

-- Quién asigna etapas y ve todo el flujo: administrador de Finanzas o global.
CREATE OR REPLACE FUNCTION public.flujo_es_admin(_uid uuid DEFAULT auth.uid())
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT _uid IS NOT NULL AND public.usuario_activo(_uid)
     AND (public.es_finanzas_admin(_uid) OR public.es_admin_global(_uid))
$$;

CREATE OR REPLACE FUNCTION public.flujo_nombre(_uid uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT nullif(btrim(p.nombre_completo), '') FROM public.profiles p WHERE p.id = _uid
$$;

DROP POLICY IF EXISTS flujo_dinero_leer ON public.flujo_dinero;
CREATE POLICY flujo_dinero_leer ON public.flujo_dinero FOR SELECT TO authenticated
  USING (public.flujo_es_admin() OR public.flujo_cap('recibe') OR public.flujo_cap('caja') OR public.flujo_cap('aplica'));
DROP POLICY IF EXISTS flujo_capacidades_leer ON public.flujo_capacidades;
CREATE POLICY flujo_capacidades_leer ON public.flujo_capacidades FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.flujo_es_admin());

CREATE OR REPLACE VIEW public.v_flujo_dinero
WITH (security_invoker = true) AS
SELECT f.*,
       public.flujo_nombre(f.recibido_por)  AS recibido_por_nombre,
       public.flujo_nombre(f.caja_por)      AS caja_por_nombre,
       public.flujo_nombre(f.aplicado_por)  AS aplicado_por_nombre
  FROM public.flujo_dinero f;
GRANT SELECT ON public.v_flujo_dinero TO authenticated;

-- ── 4. Capacidades: consultar y asignar ────────────────────────────────────
CREATE OR REPLACE FUNCTION public.flujo_mis_capacidades()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT jsonb_build_object('recibe', public.flujo_cap('recibe'), 'caja', public.flujo_cap('caja'), 'aplica', public.flujo_cap('aplica'))
$$;

CREATE OR REPLACE FUNCTION public.flujo_listar_capacidades()
RETURNS TABLE (user_id uuid, nombre text, recibe boolean, caja boolean, aplica boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.flujo_es_admin() THEN RAISE EXCEPTION 'Sólo un administrador ve quién hace cada etapa'; END IF;
  RETURN QUERY
    SELECT p.id, coalesce(nullif(btrim(p.nombre_completo), ''), p.id::text),
           coalesce(c.recibe, false), coalesce(c.caja, false), coalesce(c.aplica, false)
      FROM public.profiles p
      LEFT JOIN public.flujo_capacidades c ON c.user_id = p.id
     WHERE public.usuario_activo(p.id)
     ORDER BY 2;
END;
$$;

CREATE OR REPLACE FUNCTION public.flujo_asignar_capacidad(_user_id uuid, _capacidad text, _valor boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.flujo_es_admin() THEN RAISE EXCEPTION 'Sólo un administrador asigna las etapas del flujo de dinero'; END IF;
  IF _capacidad NOT IN ('recibe', 'caja', 'aplica') THEN RAISE EXCEPTION 'Capacidad inválida: %', _capacidad; END IF;
  INSERT INTO public.flujo_capacidades (user_id) VALUES (_user_id) ON CONFLICT (user_id) DO NOTHING;
  EXECUTE format('UPDATE public.flujo_capacidades SET %I = $1, updated_by = $2, updated_at = now() WHERE user_id = $3', _capacidad)
    USING coalesce(_valor, false), auth.uid(), _user_id;
  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_asignar_capacidad', 'flujo_capacidades', NULL, NULL,
    jsonb_build_object('usuario', _user_id, 'capacidad', _capacidad, 'valor', _valor), public.es_usuario_prueba(auth.uid()));
END;
$$;

-- ── 4b. Lecturas de apoyo por capacidad ────────────────────────────────────
-- Quien recibe, lleva caja o aplica no necesariamente es de Finanzas o Compras,
-- así que no ve estas tablas por RLS. Cada función da sólo lo que su etapa
-- necesita, y sólo a quien tiene esa capacidad.
CREATE OR REPLACE FUNCTION public.flujo_cuentas()
RETURNS TABLE (id uuid, nombre text, tipo text, moneda text, orden integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT (public.flujo_cap('caja') OR public.flujo_es_admin()) THEN RAISE EXCEPTION 'No tienes asignada la etapa de caja'; END IF;
  RETURN QUERY SELECT c.id, c.nombre, c.tipo::text, c.moneda, c.orden FROM public.cuentas_financieras c WHERE c.activo ORDER BY c.orden, c.nombre;
END;
$$;

CREATE OR REPLACE FUNCTION public.flujo_clientes()
RETURNS TABLE (id uuid, nombre text, codigo text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.flujo_cap('recibe') THEN RAISE EXCEPTION 'No tienes asignada la etapa de recepción'; END IF;
  RETURN QUERY
    SELECT c.id, coalesce(c.nombre_comercial, c.razon_social, c.codigo_erp), c.codigo_erp
      FROM public.clientes c
     WHERE coalesce(c.activo, true) AND c.es_prueba = public.es_usuario_prueba(auth.uid())
     ORDER BY 2;
END;
$$;

CREATE OR REPLACE FUNCTION public.flujo_remisiones_para_aplicar(_flujo_id uuid)
RETURNS TABLE (id uuid, folio text, fecha_remision date, saldo_pendiente numeric, documento text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE f public.flujo_dinero%ROWTYPE;
BEGIN
  IF NOT public.flujo_cap('aplica') THEN RAISE EXCEPTION 'No tienes asignada la etapa de aplicación'; END IF;
  SELECT * INTO f FROM public.flujo_dinero WHERE flujo_dinero.id = _flujo_id;
  IF NOT FOUND OR f.cliente_id IS NULL THEN RETURN; END IF;
  RETURN QUERY
    SELECT v.id, v.folio, v.fecha_remision, v.saldo_pendiente, v.documento
      FROM public.v_cobranza_remisiones v
     WHERE v.cliente_id = f.cliente_id AND v.es_prueba = f.es_prueba AND v.saldo_pendiente > 0
     ORDER BY v.fecha_remision, v.folio;
END;
$$;

-- ── 5. Etapa 1: recepción ──────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.flujo_recibir(
  _tipo text, _monto numeric, _moneda text, _metodo_pago text, _fecha date, _contraparte_nombre text,
  _cliente_id uuid DEFAULT NULL, _concepto text DEFAULT NULL, _referencia text DEFAULT NULL, _tipo_cambio numeric DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cli public.clientes%ROWTYPE;
  v_prueba boolean := public.es_usuario_prueba(auth.uid());
  v_id uuid;
  v_folio text;
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
  IF _tipo = 'PAGO_CLIENTE' THEN
    -- La cobranza sólo maneja pesos y estas tres formas de pago.
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
                                   concepto, referencia, es_prueba, recibido_por)
  VALUES (_tipo, round(_monto, 2), coalesce(_moneda, 'MXN'), CASE WHEN coalesce(_moneda, 'MXN') = 'MXN' THEN NULL ELSE _tipo_cambio END,
          _metodo_pago::public.metodo_pago, _fecha, btrim(_contraparte_nombre), CASE WHEN _tipo = 'PAGO_CLIENTE' THEN _cliente_id END,
          nullif(btrim(coalesce(_concepto, '')), ''), nullif(btrim(coalesce(_referencia, '')), ''), v_prueba, auth.uid())
  RETURNING id, folio INTO v_id, v_folio;

  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_recibir', 'flujo_dinero', v_id, v_folio,
    jsonb_build_object('tipo', _tipo, 'monto', _monto, 'moneda', _moneda), v_prueba);
  RETURN jsonb_build_object('id', v_id, 'folio', v_folio);
END;
$$;

-- ── 6. Etapa 2: caja ───────────────────────────────────────────────────────
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

  -- El movimiento confirmado es lo que mueve el saldo de la caja (v_saldos_cuentas).
  -- Un flujo de PRUEBA no escribe en el libro mayor real (candado de modo prueba):
  -- recorre las tres etapas y la cobranza de prueba, pero la caja no se mueve.
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

-- ── 7. Etapa 3: aplicación ─────────────────────────────────────────────────
-- Pago de cliente → crea el pago de cobranza ya validado (caja lo confirmó) y
-- lo aplica a las remisiones indicadas; lo que sobre es saldo a favor. Usa la
-- misma regla de aplicar_pago_cobranza (_validar_destino_cobro), sin exigir
-- rol de Compras: aquí la autorización es la capacidad `aplica`.
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

    SELECT nombre INTO v_cta FROM public.cuentas_financieras WHERE id = f.cuenta_id;
    v_pfolio := public._siguiente_folio_compras('CP', f.es_prueba);
    INSERT INTO public.cobranza_pagos (folio, cliente_id, fecha, monto, forma, cuenta_destino, referencia, notas, estatus,
                                       conciliado, capturado_por, validado_por, validado_at, es_prueba)
    VALUES (v_pfolio, f.cliente_id, f.fecha, f.monto, lower(f.metodo_pago::text), v_cta, f.referencia,
            'Flujo de dinero ' || f.folio, 'validado', true, f.recibido_por, f.caja_por, f.caja_at, f.es_prueba)
    RETURNING id INTO v_pago;

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

  UPDATE public.flujo_dinero
     SET etapa = 'APLICADO', destino = _destino, aplicado_por = auth.uid(), aplicado_at = now(),
         aplicado_notas = v_notas, cobranza_pago_id = v_pago
   WHERE id = f.id;
  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_aplicar', 'flujo_dinero', f.id, f.folio,
    jsonb_build_object('destino', _destino, 'aplicaciones', _aplicaciones, 'pago_cobranza', v_pfolio, 'saldo_favor', v_saldo_folio), f.es_prueba);
  RETURN jsonb_build_object('aplicadas', v_n, 'pago', v_pfolio, 'saldo_favor', v_saldo_folio);
END;
$$;

-- ── 8. Rechazo ─────────────────────────────────────────────────────────────
-- Antes de caja lo rechaza quien lleva caja; ya en caja, quien aplica o caja.
-- Si ya había entrado a caja, el movimiento del libro mayor se cancela para
-- que el saldo cuadre.
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
    UPDATE public.movimientos_financieros
       SET estatus = 'CANCELADO', cancelado_por = auth.uid(), cancelado_at = now(),
           motivo_cancelacion = 'Rechazado en el flujo de dinero ' || f.folio || ': ' || btrim(_motivo)
     WHERE id = f.movimiento_id;
  END IF;
  UPDATE public.flujo_dinero
     SET etapa = 'RECHAZADO', motivo_rechazo = btrim(_motivo), rechazado_por = auth.uid(), rechazado_at = now()
   WHERE id = f.id;
  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_rechazar', 'flujo_dinero', f.id, f.folio,
    jsonb_build_object('motivo', _motivo, 'etapa', f.etapa), f.es_prueba);
END;
$$;

-- ── 9. Permisos: nada abierto a anon ───────────────────────────────────────
REVOKE ALL ON FUNCTION public.flujo_dinero_sin_borrar() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.flujo_cap(text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_es_admin(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_nombre(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_mis_capacidades() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_listar_capacidades() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_cuentas() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_clientes() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_remisiones_para_aplicar(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_cuentas() TO authenticated;
GRANT EXECUTE ON FUNCTION public.flujo_clientes() TO authenticated;
GRANT EXECUTE ON FUNCTION public.flujo_remisiones_para_aplicar(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.flujo_asignar_capacidad(uuid, text, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_recibir(text, numeric, text, text, date, text, uuid, text, text, numeric) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_confirmar_caja(uuid, uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_aplicar(uuid, text, jsonb, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_rechazar(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_cap(text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.flujo_es_admin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.flujo_nombre(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.flujo_mis_capacidades() TO authenticated;
GRANT EXECUTE ON FUNCTION public.flujo_listar_capacidades() TO authenticated;
GRANT EXECUTE ON FUNCTION public.flujo_asignar_capacidad(uuid, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.flujo_recibir(text, numeric, text, text, date, text, uuid, text, text, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.flujo_confirmar_caja(uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.flujo_aplicar(uuid, text, jsonb, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.flujo_rechazar(uuid, text) TO authenticated;

-- Verificación: tablas con RLS, funciones sin permiso para anon.
SELECT
  to_regclass('public.flujo_dinero') AS tabla,
  (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.flujo_dinero'::regclass) AS rls,
  has_function_privilege('anon', 'public.flujo_aplicar(uuid,text,jsonb,text)', 'execute') AS anon_aplica,
  has_table_privilege('authenticated', 'public.flujo_dinero', 'insert') AS authenticated_escribe_directo;

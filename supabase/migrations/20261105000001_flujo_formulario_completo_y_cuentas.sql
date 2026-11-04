-- ============================================================================
-- Flujo de dinero: formulario completo de ingresos y egresos, cuentas y clientes (2026-11-05)
--
-- Pedido del equipo (Martín / Polo):
--  1. El buscador de clientes del flujo no traía toda la base (PostgREST corta en 1000 y hay
--     1,786 clientes): flujo_clientes ahora se pide por tramos (_desde, _limite).
--  2. Volver al formulario completo que tenía Control Financiero para ingresos y egresos
--     (categoría, descripción, contraparte cliente/proveedor/empleado/otro, moneda y tipo de
--     cambio, vía intermediario, quién recibió, factura, remisión…), pero registrándose EN el
--     flujo: nace un renglón del flujo (tipo INGRESO o SALIDA) que sigue las tres etapas y al
--     entrar a caja crea el movimiento con TODO ese detalle (flujo_registrar_movimiento).
--  3. Elegir y dar de alta dónde entra o sale el dinero (Juoshui, Caja, Banorte…):
--     la cuenta se elige al registrar (queda como «cuenta prevista», Caja la confirma o la
--     cambia) y un administrador del flujo da de alta cuentas (flujo_crear_cuenta). Quien
--     registra ahora también ve la lista de cuentas (flujo_cuentas).
--
-- Cambios de base: tipo nuevo INGRESO en flujo_dinero (otros ingresos; los pagos de clientes
-- a remisiones siguen siendo PAGO_CLIENTE), columnas del detalle y vista. Solo agrega: nada de
-- lo existente cambia de significado.
--
-- Idempotente. Para el SQL editor de Supabase; NO usar `supabase db push`.
-- Para revertir: DROP FUNCTION flujo_registrar_movimiento / flujo_crear_cuenta y volver a las
-- definiciones de flujo_aplicar y flujo_confirmar_caja de 20261104000001 / 20261104000002.
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := '{}';
BEGIN
  IF to_regclass('public.flujo_dinero') IS NULL THEN _faltan := _faltan || 'tabla flujo_dinero'::text; END IF;
  IF to_regclass('public.cuentas_financieras') IS NULL THEN _faltan := _faltan || 'tabla cuentas_financieras'::text; END IF;
  IF to_regprocedure('public.flujo_resumen_aplicacion(uuid,uuid)') IS NULL THEN _faltan := _faltan || 'función flujo_resumen_aplicacion (20261103000008)'::text; END IF;
  IF position($q$estatus = 'PENDIENTE'$q$ in coalesce(pg_get_functiondef(to_regprocedure('public.flujo_confirmar_caja(uuid,uuid,text)')), '')) = 0 THEN
    _faltan := _faltan || 'flujo_confirmar_caja «por confirmar» (20261104000002)'::text;
  END IF;
  IF position('v_pago := f.cobranza_pago_id' in coalesce(pg_get_functiondef(to_regprocedure('public.flujo_aplicar(uuid,text,jsonb,text)')), '')) = 0 THEN
    _faltan := _faltan || 'flujo_aplicar (20261104000001)'::text;
  END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ', ');
  END IF;
END;
$preflight$;

-- ── 1. Tipo INGRESO y columnas del detalle ──────────────────────────────────
ALTER TABLE public.flujo_dinero DROP CONSTRAINT IF EXISTS flujo_dinero_tipo_check;
ALTER TABLE public.flujo_dinero ADD CONSTRAINT flujo_dinero_tipo_check
  CHECK (tipo IN ('PAGO_CLIENTE', 'REEMBOLSO', 'SALIDA', 'INGRESO'));

ALTER TABLE public.flujo_dinero
  ADD COLUMN IF NOT EXISTS categoria text,
  ADD COLUMN IF NOT EXISTS descripcion text,
  ADD COLUMN IF NOT EXISTS contraparte_tipo text CHECK (contraparte_tipo IS NULL OR contraparte_tipo IN ('CLIENTE', 'PROVEEDOR', 'EMPLEADO', 'OTRO')),
  ADD COLUMN IF NOT EXISTS proveedor_id uuid REFERENCES public.proveedores(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS empleado_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS via text CHECK (via IS NULL OR via IN ('DIRECTO', 'INTERMEDIARIO')),
  ADD COLUMN IF NOT EXISTS intermediario_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS factura_folio text,
  ADD COLUMN IF NOT EXISTS factura_uuid text,
  ADD COLUMN IF NOT EXISTS factura_rfc text,
  ADD COLUMN IF NOT EXISTS remision_id uuid REFERENCES public.remisiones(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS cuenta_prevista_id uuid REFERENCES public.cuentas_financieras(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS quien_recibio uuid REFERENCES public.profiles(id) ON DELETE SET NULL;

-- La vista fija sus columnas: se recrea (mismo orden) y lo nuevo va al final.
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
       f.factura_folio, f.factura_uuid, f.factura_rfc, f.remision_id, f.cuenta_prevista_id, f.quien_recibio
  FROM public.flujo_dinero f;
GRANT SELECT ON public.v_flujo_dinero TO authenticated;

-- ── 2. Registrar un ingreso o egreso con el formulario completo ─────────────
CREATE OR REPLACE FUNCTION public.flujo_registrar_movimiento(_datos jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_tipo text;
  v_monto numeric;
  v_moneda text := coalesce(nullif(btrim(coalesce(_datos->>'moneda', '')), ''), 'MXN');
  v_tc numeric := nullif(_datos->>'tipo_cambio', '')::numeric;
  v_metodo text := coalesce(nullif(_datos->>'metodo_pago', ''), 'EFECTIVO');
  v_fecha date := coalesce(nullif(_datos->>'fecha_movimiento', '')::date, (now() AT TIME ZONE 'America/Mexico_City')::date);
  v_contra text := coalesce(nullif(_datos->>'contraparte_tipo', ''), 'OTRO');
  v_nombre text := nullif(btrim(coalesce(_datos->>'contraparte_nombre', '')), '');
  v_concepto text := nullif(btrim(coalesce(_datos->>'concepto', '')), '');
  v_cli uuid := nullif(_datos->>'cliente_id', '')::uuid;
  v_prov uuid := nullif(_datos->>'proveedor_id', '')::uuid;
  v_emp uuid := nullif(_datos->>'empleado_id', '')::uuid;
  v_via text := coalesce(nullif(_datos->>'via', ''), 'DIRECTO');
  v_inter_id uuid := nullif(_datos->>'intermediario_id', '')::uuid;
  v_inter text := nullif(btrim(coalesce(_datos->>'intermediario_nombre', '')), '');
  v_cuenta uuid := nullif(_datos->>'cuenta_id', '')::uuid;
  v_cta public.cuentas_financieras%ROWTYPE;
  v_prueba boolean := public.es_usuario_prueba(auth.uid());
  v_cl public.clientes%ROWTYPE;
  v_id uuid;
  v_folio text;
BEGIN
  IF NOT (public.flujo_cap('recibe') OR public.flujo_es_admin()) THEN
    RAISE EXCEPTION 'No tienes asignada la etapa de recepción';
  END IF;
  v_tipo := CASE upper(coalesce(_datos->>'tipo', '')) WHEN 'INGRESO' THEN 'INGRESO' WHEN 'EGRESO' THEN 'SALIDA' WHEN 'SALIDA' THEN 'SALIDA' END;
  IF v_tipo IS NULL THEN RAISE EXCEPTION 'Indica si es un ingreso o un egreso'; END IF;
  v_monto := round(nullif(_datos->>'monto', '')::numeric, 2);
  IF v_monto IS NULL OR v_monto <= 0 THEN RAISE EXCEPTION 'El monto debe ser mayor a cero'; END IF;
  IF v_concepto IS NULL THEN RAISE EXCEPTION 'El concepto es obligatorio'; END IF;
  IF v_nombre IS NULL THEN RAISE EXCEPTION 'Indica quién entregó o recibe el dinero'; END IF;
  IF v_contra NOT IN ('CLIENTE', 'PROVEEDOR', 'EMPLEADO', 'OTRO') THEN RAISE EXCEPTION 'Contraparte inválida'; END IF;
  IF v_contra = 'CLIENTE' AND v_cli IS NULL THEN RAISE EXCEPTION 'Elige el cliente'; END IF;
  IF v_contra = 'PROVEEDOR' AND v_prov IS NULL THEN RAISE EXCEPTION 'Elige el proveedor'; END IF;
  IF v_contra = 'EMPLEADO' AND v_emp IS NULL THEN RAISE EXCEPTION 'Elige al empleado'; END IF;
  IF v_metodo NOT IN ('EFECTIVO', 'TRANSFERENCIA', 'CHEQUE', 'TARJETA', 'DEPOSITO', 'COMPENSACION', 'OTRO') THEN
    RAISE EXCEPTION 'Forma de pago inválida: %', v_metodo;
  END IF;
  IF v_moneda <> 'MXN' AND (v_tc IS NULL OR v_tc <= 0) THEN RAISE EXCEPTION 'Captura el tipo de cambio para %', v_moneda; END IF;
  IF v_via NOT IN ('DIRECTO', 'INTERMEDIARIO') THEN RAISE EXCEPTION 'Vía inválida'; END IF;
  IF v_via = 'INTERMEDIARIO' THEN
    IF v_inter_id IS NOT NULL AND v_inter IS NULL THEN v_inter := public.flujo_nombre(v_inter_id); END IF;
    IF v_inter IS NULL THEN RAISE EXCEPTION 'Indica quién lleva o trae el dinero'; END IF;
  ELSE
    v_inter_id := NULL; v_inter := NULL;
  END IF;
  IF v_cuenta IS NOT NULL THEN
    SELECT * INTO v_cta FROM public.cuentas_financieras WHERE id = v_cuenta AND activo;
    IF NOT FOUND THEN RAISE EXCEPTION 'La caja o cuenta elegida no existe o está inactiva'; END IF;
    IF v_cta.moneda <> v_moneda THEN
      RAISE EXCEPTION '«%» maneja % y el movimiento está en %', v_cta.nombre, v_cta.moneda, v_moneda;
    END IF;
  END IF;
  IF v_cli IS NOT NULL THEN
    SELECT * INTO v_cl FROM public.clientes WHERE id = v_cli;
    IF NOT FOUND THEN RAISE EXCEPTION 'El cliente no existe'; END IF;
    PERFORM public.exigir_dato_prueba(v_cl.es_prueba, 'el cliente ' || coalesce(v_cl.nombre_comercial, ''));
    v_prueba := v_cl.es_prueba;
  END IF;

  INSERT INTO public.flujo_dinero
    (tipo, monto, moneda, tipo_cambio, metodo_pago, fecha, contraparte_nombre, cliente_id, concepto, referencia, es_prueba,
     recibido_por, requiere_comprobacion, intermediario_nombre, categoria, descripcion, contraparte_tipo, proveedor_id, empleado_id,
     via, intermediario_id, factura_folio, factura_uuid, factura_rfc, remision_id, cuenta_prevista_id, quien_recibio)
  VALUES
    (v_tipo, v_monto, v_moneda, CASE WHEN v_moneda = 'MXN' THEN NULL ELSE v_tc END, v_metodo::public.metodo_pago, v_fecha, v_nombre,
     CASE WHEN v_contra = 'CLIENTE' THEN v_cli END, v_concepto, nullif(btrim(coalesce(_datos->>'referencia', '')), ''), v_prueba,
     auth.uid(), (v_tipo = 'SALIDA' AND v_metodo = 'EFECTIVO' AND v_via = 'INTERMEDIARIO'), v_inter,
     nullif(btrim(coalesce(_datos->>'categoria', '')), ''), nullif(btrim(coalesce(_datos->>'descripcion', '')), ''), v_contra,
     CASE WHEN v_contra = 'PROVEEDOR' THEN v_prov END, CASE WHEN v_contra = 'EMPLEADO' THEN v_emp END,
     v_via, v_inter_id, nullif(btrim(coalesce(_datos->>'factura_folio', '')), ''), nullif(btrim(coalesce(_datos->>'factura_uuid', '')), ''),
     nullif(btrim(coalesce(_datos->>'factura_rfc', '')), ''), nullif(_datos->>'remision_id', '')::uuid, v_cuenta,
     nullif(_datos->>'recibido_por', '')::uuid)
  RETURNING id, folio INTO v_id, v_folio;

  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_registrar_movimiento', 'flujo_dinero', v_id, v_folio,
    jsonb_build_object('tipo', v_tipo, 'monto', v_monto, 'moneda', v_moneda, 'cuenta_prevista', v_cuenta), v_prueba);
  RETURN jsonb_build_object('id', v_id, 'folio', v_folio);
END;
$$;
REVOKE ALL ON FUNCTION public.flujo_registrar_movimiento(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_registrar_movimiento(jsonb) TO authenticated;

-- ── 3. Dónde entra o sale el dinero: ver y dar de alta cuentas ──────────────
CREATE OR REPLACE FUNCTION public.flujo_cuentas()
RETURNS TABLE (id uuid, nombre text, tipo text, moneda text, orden integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT (public.flujo_cap('caja') OR public.flujo_cap('recibe') OR public.flujo_es_admin()) THEN
    RAISE EXCEPTION 'No tienes asignada la etapa de caja';
  END IF;
  RETURN QUERY SELECT c.id, c.nombre, c.tipo::text, c.moneda, c.orden FROM public.cuentas_financieras c WHERE c.activo ORDER BY c.orden, c.nombre;
END;
$$;

CREATE OR REPLACE FUNCTION public.flujo_crear_cuenta(_nombre text, _tipo text, _moneda text DEFAULT 'MXN', _banco text DEFAULT NULL, _numero text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_nombre text := nullif(btrim(coalesce(_nombre, '')), '');
  v_moneda text := upper(coalesce(nullif(btrim(coalesce(_moneda, '')), ''), 'MXN'));
  v_id uuid;
BEGIN
  IF NOT public.flujo_es_admin() THEN RAISE EXCEPTION 'Solo un administrador del flujo da de alta cajas o cuentas'; END IF;
  IF v_nombre IS NULL THEN RAISE EXCEPTION 'Captura el nombre de la caja o cuenta (ej. Banorte, Caja, Juoshui)'; END IF;
  IF upper(coalesce(_tipo, '')) NOT IN ('EFECTIVO', 'BANCO') THEN RAISE EXCEPTION 'Indica si es una caja de efectivo o una cuenta de banco'; END IF;
  IF v_moneda NOT IN ('MXN', 'USD', 'CNY', 'EUR') THEN RAISE EXCEPTION 'Moneda no válida: %', v_moneda; END IF;
  IF EXISTS (SELECT 1 FROM public.cuentas_financieras WHERE lower(nombre) = lower(v_nombre) AND moneda = v_moneda) THEN
    RAISE EXCEPTION 'Ya existe «%» en %', v_nombre, v_moneda;
  END IF;
  INSERT INTO public.cuentas_financieras (nombre, tipo, moneda, banco, numero_cuenta, orden)
  VALUES (v_nombre, upper(_tipo)::public.cuenta_tipo, v_moneda, nullif(btrim(coalesce(_banco, '')), ''), nullif(btrim(coalesce(_numero, '')), ''),
          coalesce((SELECT max(orden) FROM public.cuentas_financieras), 0) + 1)
  RETURNING id INTO v_id;
  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_crear_cuenta', 'cuentas_financieras', v_id, v_nombre,
    jsonb_build_object('tipo', _tipo, 'moneda', v_moneda), false);
  RETURN jsonb_build_object('id', v_id, 'nombre', v_nombre);
END;
$$;
REVOKE ALL ON FUNCTION public.flujo_crear_cuenta(text, text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_crear_cuenta(text, text, text, text, text) TO authenticated;

-- ── 4. Clientes del flujo por tramos (toda la base, no solo los primeros 1000) ──
DROP FUNCTION IF EXISTS public.flujo_clientes();
CREATE OR REPLACE FUNCTION public.flujo_clientes(_desde integer DEFAULT 0, _limite integer DEFAULT 1000)
RETURNS TABLE (id uuid, nombre text, codigo text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT (public.flujo_cap('recibe') OR public.flujo_es_admin()) THEN RAISE EXCEPTION 'No tienes asignada la etapa de recepción'; END IF;
  RETURN QUERY
    SELECT c.id, coalesce(c.nombre_comercial, c.razon_social, c.codigo_erp), c.codigo_erp
      FROM public.clientes c
     WHERE coalesce(c.activo, true) AND c.es_prueba = public.es_usuario_prueba(auth.uid())
     ORDER BY 2, c.id
     OFFSET greatest(coalesce(_desde, 0), 0) LIMIT least(greatest(coalesce(_limite, 1000), 1), 1000);
END;
$$;
REVOKE ALL ON FUNCTION public.flujo_clientes(integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_clientes(integer, integer) TO authenticated;

-- Categorías del formulario: quien registra en el flujo no necesariamente lee las tablas de Finanzas.
CREATE OR REPLACE FUNCTION public.flujo_categorias(_tipo text)
RETURNS TABLE (nombre text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT (public.flujo_cap('recibe') OR public.flujo_cap('caja') OR public.flujo_es_admin()) THEN
    RAISE EXCEPTION 'No tienes asignada la etapa de recepción';
  END IF;
  RETURN QUERY SELECT c.nombre FROM public.categorias_financieras c
   WHERE c.activo AND c.tipo::text = upper(coalesce(_tipo, '')) ORDER BY c.orden, c.nombre;
END;
$$;
REVOKE ALL ON FUNCTION public.flujo_categorias(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_categorias(text) TO authenticated;

-- ── 5. Aplicar: un INGRESO se aplica a «Otro» ───────────────────────────────

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
  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_aplicar', 'flujo_dinero', f.id, f.folio,
    jsonb_build_object('destino', _destino, 'aplicaciones', _aplicaciones, 'pago_cobranza', v_pfolio, 'saldo_favor', v_saldo_folio), f.es_prueba);
  RETURN jsonb_build_object('aplicadas', v_n, 'pago', v_pfolio, 'saldo_favor', v_saldo_folio);
END;
$$;
REVOKE ALL ON FUNCTION public.flujo_aplicar(uuid, text, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_aplicar(uuid, text, jsonb, text) TO authenticated;

-- ── 6. Caja: al confirmar copia todo el detalle del formulario ───────────────
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
  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_caja', 'flujo_dinero', f.id, f.folio,
    jsonb_build_object('cuenta', c.nombre, 'movimiento_id', v_mov), f.es_prueba);
END;
$$;
REVOKE ALL ON FUNCTION public.flujo_confirmar_caja(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_confirmar_caja(uuid, uuid, text) TO authenticated;

DO $postflight$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='v_flujo_dinero' AND column_name='cuenta_prevista_id') THEN
    RAISE EXCEPTION 'v_flujo_dinero no quedó con las columnas nuevas.';
  END IF;
  IF has_function_privilege('anon', 'public.flujo_registrar_movimiento(jsonb)', 'execute')
     OR has_function_privilege('anon', 'public.flujo_crear_cuenta(text,text,text,text,text)', 'execute')
     OR has_function_privilege('anon', 'public.flujo_clientes(integer,integer)', 'execute') THEN
    RAISE EXCEPTION 'Las funciones del flujo no deben estar abiertas a anon.';
  END IF;
  IF position('f.quien_recibio' in pg_get_functiondef('public.flujo_confirmar_caja(uuid,uuid,text)'::regprocedure)) = 0
     OR position($q$'INGRESO' AND _destino$q$ in pg_get_functiondef('public.flujo_aplicar(uuid,text,jsonb,text)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'Faltan los cambios de caja o de aplicar.';
  END IF;
END $postflight$;

-- ============================================================================
-- Bancos por empresa y búsqueda de remisiones al aplicar (PROPUESTA, sin aplicar)
--
-- Criterio de Polo (2026-10-27):
--  1. Los bancos activos se cargan por empresa del grupo; Caja elige la cuenta de la
--     empresa que corresponde al movimiento.
--  2. Al aplicar un pago se busca entre las remisiones pendientes de cobro.
--
--  · empresas_grupo (nombre y razón social) y empresa_id/ultimos4 en cuentas_financieras;
--    solo los últimos 4 dígitos (nunca el número completo); las cuentas no se borran, se desactivan;
--    alta y edición solo por RPC del administrador financiero, con bitácora (antes y después).
--  · La empresa del movimiento la captura Recibe (la que recibe el dinero); Caja solo ve y
--    elige cuentas activas de esa empresa, del tipo que pide el método y de la moneda del movimiento.
--  · Migración sin pérdida: las cuentas actuales no se tocan (mismos ids, historial y saldos);
--    sin empresa asignada siguen funcionando hasta que se les asigne una (null → empresa).
--    Una cuenta con movimientos ya no cambia de empresa, tipo ni moneda.
--  · Saldos por cuenta y por empresa solo con movimientos CONFIRMADOS por Caja; lo recibido
--    sin confirmar se muestra aparte, «en tránsito», también por empresa.
--  · flujo_buscar_remisiones: filtros (folio, cliente, vendedor, fechas, monto) y paginación;
--    solo confirmadas, no canceladas, con saldo; prueba y real no se mezclan.
--  · flujo_cambiar_cliente: quien aplica corrige el cliente del pago con motivo; queda en el historial.
--
-- Depende de 20261030000001 (unificación). Idempotente.
-- Para el SQL editor de Supabase; NO usar `supabase db push`.
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.flujo_dinero_eventos') IS NULL THEN _faltan := _faltan || 'flujo_dinero_eventos (20261030000001)'::text; END IF;
  IF to_regprocedure('public.movimiento_cancelar(uuid,text)') IS NULL THEN _faltan := _faltan || 'movimiento_cancelar (20261030000001)'::text; END IF;
  IF to_regprocedure('public.estado_cobro_remision_refaccion(uuid)') IS NULL THEN _faltan := _faltan || 'estado_cobro_remision_refaccion'::text; END IF;
  IF to_regprocedure('public._validar_destino_cobro(uuid,uuid,boolean,numeric)') IS NULL THEN _faltan := _faltan || '_validar_destino_cobro'::text; END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ', ');
  END IF;
END $preflight$;

-- ── 1. Empresas del grupo ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.empresas_grupo (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre       text NOT NULL CHECK (length(btrim(nombre)) >= 2),
  razon_social text NOT NULL CHECK (length(btrim(razon_social)) >= 2),
  activo       boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  created_by   uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_at   timestamptz NOT NULL DEFAULT now(),
  updated_by   uuid REFERENCES auth.users(id) ON DELETE SET NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_empresas_grupo_nombre ON public.empresas_grupo (lower(btrim(nombre)));
ALTER TABLE public.empresas_grupo ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.empresas_grupo FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.empresas_grupo TO authenticated;
GRANT ALL ON public.empresas_grupo TO service_role;
DROP POLICY IF EXISTS empresas_grupo_leer ON public.empresas_grupo;
CREATE POLICY empresas_grupo_leer ON public.empresas_grupo FOR SELECT TO authenticated
  USING (public.es_finanzas(auth.uid()) OR public.flujo_es_admin() OR public.flujo_cap('recibe') OR public.flujo_cap('caja') OR public.flujo_cap('aplica'));

-- Bitácora del catálogo (empresas y cuentas): quién, qué cambió, antes y después. No se edita ni se borra.
CREATE TABLE IF NOT EXISTS public.catalogo_bancos_bitacora (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entidad    text NOT NULL CHECK (entidad IN ('EMPRESA', 'CUENTA')),
  entidad_id uuid NOT NULL,
  accion     text NOT NULL CHECK (accion IN ('ALTA', 'EDICION', 'ACTIVACION', 'DESACTIVACION', 'ASIGNACION_EMPRESA')),
  antes      jsonb,
  despues    jsonb,
  motivo     text,
  usuario_id uuid,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX IF NOT EXISTS idx_catalogo_bancos_bitacora ON public.catalogo_bancos_bitacora (entidad, entidad_id, created_at);
CREATE OR REPLACE FUNCTION public.catalogo_bancos_bitacora_inmutable()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'La bitácora de bancos y empresas no se edita ni se borra.'; END;
$$;
DROP TRIGGER IF EXISTS trg_catalogo_bancos_bitacora_inmutable ON public.catalogo_bancos_bitacora;
CREATE TRIGGER trg_catalogo_bancos_bitacora_inmutable BEFORE UPDATE OR DELETE ON public.catalogo_bancos_bitacora
  FOR EACH ROW EXECUTE FUNCTION public.catalogo_bancos_bitacora_inmutable();
ALTER TABLE public.catalogo_bancos_bitacora ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.catalogo_bancos_bitacora FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.catalogo_bancos_bitacora TO authenticated;
GRANT ALL ON public.catalogo_bancos_bitacora TO service_role;
DROP POLICY IF EXISTS catalogo_bancos_bitacora_leer ON public.catalogo_bancos_bitacora;
CREATE POLICY catalogo_bancos_bitacora_leer ON public.catalogo_bancos_bitacora FOR SELECT TO authenticated
  USING (public.es_finanzas_admin(auth.uid()));

-- ── 2. Cuentas: empresa y últimos 4 dígitos; no se borran ──────────────────
ALTER TABLE public.cuentas_financieras
  ADD COLUMN IF NOT EXISTS empresa_id uuid REFERENCES public.empresas_grupo(id),
  ADD COLUMN IF NOT EXISTS ultimos4   text;
DO $c$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'cuentas_ultimos4_formato') THEN
    ALTER TABLE public.cuentas_financieras ADD CONSTRAINT cuentas_ultimos4_formato
      CHECK (ultimos4 IS NULL OR (ultimos4 ~ '^[0-9]{4}$' AND tipo = 'BANCO'));
  END IF;
  -- Nunca se guarda el número de cuenta completo (hoy la columna está vacía en las tres cuentas).
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'cuentas_sin_numero_completo') THEN
    ALTER TABLE public.cuentas_financieras ADD CONSTRAINT cuentas_sin_numero_completo CHECK (numero_cuenta IS NULL);
  END IF;
END $c$;
CREATE INDEX IF NOT EXISTS idx_cuentas_empresa ON public.cuentas_financieras (empresa_id) WHERE empresa_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS ux_cuentas_empresa_nombre ON public.cuentas_financieras (empresa_id, lower(btrim(nombre))) WHERE empresa_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS ux_cuentas_banco_ultimos4 ON public.cuentas_financieras (empresa_id, lower(btrim(banco)), ultimos4)
  WHERE empresa_id IS NOT NULL AND ultimos4 IS NOT NULL;

DROP POLICY IF EXISTS cuentas_write ON public.cuentas_financieras;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.cuentas_financieras FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.cuenta_catalogo_guardia()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_mov boolean;
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Una cuenta no se borra: se desactiva (administrador financiero).';
  END IF;
  SELECT EXISTS (SELECT 1 FROM public.movimientos_financieros WHERE cuenta_id = OLD.id) INTO v_mov;
  IF v_mov AND (NEW.moneda IS DISTINCT FROM OLD.moneda OR NEW.tipo IS DISTINCT FROM OLD.tipo
                OR (OLD.empresa_id IS NOT NULL AND NEW.empresa_id IS DISTINCT FROM OLD.empresa_id)) THEN
    RAISE EXCEPTION 'La cuenta «%» ya tiene movimientos: no cambia de empresa, tipo ni moneda (crea otra cuenta y desactiva esta).', OLD.nombre;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS a_cuenta_catalogo_guardia ON public.cuentas_financieras;
CREATE TRIGGER a_cuenta_catalogo_guardia BEFORE UPDATE OR DELETE ON public.cuentas_financieras
  FOR EACH ROW EXECUTE FUNCTION public.cuenta_catalogo_guardia();

CREATE OR REPLACE FUNCTION public.empresa_guardar(_id uuid, _nombre text, _razon_social text, _activo boolean DEFAULT true, _motivo text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE e public.empresas_grupo%ROWTYPE; v_id uuid; v_accion text;
BEGIN
  IF NOT (public.es_finanzas_admin(auth.uid()) AND public.usuario_activo(auth.uid())) THEN
    RAISE EXCEPTION 'Sólo el administrador financiero o un administrador da de alta y edita empresas';
  END IF;
  IF length(btrim(coalesce(_nombre, ''))) < 2 THEN RAISE EXCEPTION 'El nombre de la empresa es obligatorio'; END IF;
  IF length(btrim(coalesce(_razon_social, ''))) < 2 THEN RAISE EXCEPTION 'La razón social es obligatoria'; END IF;
  IF _id IS NULL THEN
    INSERT INTO public.empresas_grupo (nombre, razon_social, activo, created_by, updated_by)
    VALUES (btrim(_nombre), btrim(_razon_social), coalesce(_activo, true), auth.uid(), auth.uid()) RETURNING id INTO v_id;
    INSERT INTO public.catalogo_bancos_bitacora (entidad, entidad_id, accion, despues, motivo, usuario_id)
    SELECT 'EMPRESA', v_id, 'ALTA', to_jsonb(x) - 'created_at' - 'updated_at', nullif(btrim(coalesce(_motivo, '')), ''), auth.uid() FROM public.empresas_grupo x WHERE x.id = v_id;
    RETURN v_id;
  END IF;
  SELECT * INTO e FROM public.empresas_grupo WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe la empresa'; END IF;
  IF NOT coalesce(_activo, e.activo) AND e.activo THEN
    IF length(btrim(coalesce(_motivo, ''))) < 5 THEN RAISE EXCEPTION 'El motivo de la desactivación es obligatorio (mínimo 5 caracteres)'; END IF;
    IF EXISTS (SELECT 1 FROM public.cuentas_financieras WHERE empresa_id = e.id AND activo) THEN
      RAISE EXCEPTION 'La empresa «%» todavía tiene cuentas activas: desactívalas primero', e.nombre;
    END IF;
  END IF;
  v_accion := CASE WHEN e.activo AND NOT coalesce(_activo, e.activo) THEN 'DESACTIVACION'
                   WHEN NOT e.activo AND coalesce(_activo, e.activo) THEN 'ACTIVACION' ELSE 'EDICION' END;
  UPDATE public.empresas_grupo SET nombre = btrim(_nombre), razon_social = btrim(_razon_social), activo = coalesce(_activo, activo),
         updated_at = now(), updated_by = auth.uid() WHERE id = e.id;
  INSERT INTO public.catalogo_bancos_bitacora (entidad, entidad_id, accion, antes, despues, motivo, usuario_id)
  SELECT 'EMPRESA', e.id, v_accion, to_jsonb(e) - 'created_at' - 'updated_at', to_jsonb(x) - 'created_at' - 'updated_at',
         nullif(btrim(coalesce(_motivo, '')), ''), auth.uid() FROM public.empresas_grupo x WHERE x.id = e.id;
  RETURN e.id;
END;
$$;

-- Alta y edición de cuentas. Solo los últimos 4 dígitos. _saldo_inicial solo cuenta al dar de alta.
CREATE OR REPLACE FUNCTION public.cuenta_guardar(
  _id uuid, _empresa_id uuid, _nombre text, _banco text, _tipo text, _moneda text, _ultimos4 text,
  _activo boolean DEFAULT true, _orden integer DEFAULT NULL, _saldo_inicial numeric DEFAULT 0, _motivo text DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE c public.cuentas_financieras%ROWTYPE; v_id uuid; v_accion text; v_ult text := nullif(btrim(coalesce(_ultimos4, '')), '');
BEGIN
  IF NOT (public.es_finanzas_admin(auth.uid()) AND public.usuario_activo(auth.uid())) THEN
    RAISE EXCEPTION 'Sólo el administrador financiero o un administrador da de alta y edita cuentas';
  END IF;
  IF length(btrim(coalesce(_nombre, ''))) < 2 THEN RAISE EXCEPTION 'El nombre de la cuenta es obligatorio'; END IF;
  IF _tipo NOT IN ('EFECTIVO', 'BANCO') THEN RAISE EXCEPTION 'El tipo de cuenta es efectivo o banco'; END IF;
  IF nullif(btrim(coalesce(_moneda, '')), '') IS NULL THEN RAISE EXCEPTION 'Indica la moneda'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.empresas_grupo WHERE id = _empresa_id) THEN RAISE EXCEPTION 'Elige la empresa de la cuenta'; END IF;
  IF _tipo = 'BANCO' THEN
    IF nullif(btrim(coalesce(_banco, '')), '') IS NULL THEN RAISE EXCEPTION 'Indica el banco'; END IF;
    IF v_ult IS NULL OR v_ult !~ '^[0-9]{4}$' THEN RAISE EXCEPTION 'Captura solo los últimos 4 dígitos de la cuenta (nunca el número completo)'; END IF;
  ELSIF v_ult IS NOT NULL THEN
    RAISE EXCEPTION 'Una caja de efectivo no lleva número de cuenta';
  END IF;

  IF _id IS NULL THEN
    IF NOT EXISTS (SELECT 1 FROM public.empresas_grupo WHERE id = _empresa_id AND activo) THEN RAISE EXCEPTION 'La empresa está desactivada'; END IF;
    PERFORM set_config('kit.cuenta_admin', 'on', true);
    INSERT INTO public.cuentas_financieras (nombre, tipo, moneda, banco, saldo_inicial, activo, orden, empresa_id, ultimos4)
    VALUES (btrim(_nombre), _tipo::public.cuenta_tipo, upper(btrim(_moneda)), CASE WHEN _tipo = 'BANCO' THEN btrim(_banco) END,
            coalesce(_saldo_inicial, 0), coalesce(_activo, true),
            coalesce(_orden, (SELECT coalesce(max(orden), 0) + 1 FROM public.cuentas_financieras)), _empresa_id, v_ult)
    RETURNING id INTO v_id;
    PERFORM set_config('kit.cuenta_admin', 'off', true);
    INSERT INTO public.catalogo_bancos_bitacora (entidad, entidad_id, accion, despues, motivo, usuario_id)
    SELECT 'CUENTA', v_id, 'ALTA', to_jsonb(x) - 'created_at' - 'updated_at', nullif(btrim(coalesce(_motivo, '')), ''), auth.uid()
      FROM public.cuentas_financieras x WHERE x.id = v_id;
    RETURN v_id;
  END IF;

  SELECT * INTO c FROM public.cuentas_financieras WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe la cuenta'; END IF;
  IF c.activo AND NOT coalesce(_activo, c.activo) AND length(btrim(coalesce(_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'El motivo de la desactivación es obligatorio (mínimo 5 caracteres)';
  END IF;
  IF coalesce(_activo, c.activo) AND NOT EXISTS (SELECT 1 FROM public.empresas_grupo WHERE id = _empresa_id AND activo) THEN
    RAISE EXCEPTION 'La empresa está desactivada: no se pueden tener cuentas activas en ella';
  END IF;
  v_accion := CASE WHEN c.activo AND NOT coalesce(_activo, c.activo) THEN 'DESACTIVACION'
                   WHEN NOT c.activo AND coalesce(_activo, c.activo) THEN 'ACTIVACION'
                   WHEN c.empresa_id IS NULL AND _empresa_id IS NOT NULL THEN 'ASIGNACION_EMPRESA' ELSE 'EDICION' END;
  UPDATE public.cuentas_financieras SET
         nombre = btrim(_nombre), tipo = _tipo::public.cuenta_tipo, moneda = upper(btrim(_moneda)),
         banco = CASE WHEN _tipo = 'BANCO' THEN btrim(_banco) END, ultimos4 = v_ult, empresa_id = _empresa_id,
         activo = coalesce(_activo, activo), orden = coalesce(_orden, orden), updated_at = now()
   WHERE id = c.id;
  INSERT INTO public.catalogo_bancos_bitacora (entidad, entidad_id, accion, antes, despues, motivo, usuario_id)
  SELECT 'CUENTA', c.id, v_accion, to_jsonb(c) - 'created_at' - 'updated_at', to_jsonb(x) - 'created_at' - 'updated_at',
         nullif(btrim(coalesce(_motivo, '')), ''), auth.uid() FROM public.cuentas_financieras x WHERE x.id = c.id;
  RETURN c.id;
END;
$$;

-- ── 3. La empresa del movimiento: la captura Recibe; Caja solo ve cuentas de esa empresa ──
ALTER TABLE public.flujo_dinero ADD COLUMN IF NOT EXISTS empresa_id uuid REFERENCES public.empresas_grupo(id);
CREATE INDEX IF NOT EXISTS idx_flujo_empresa ON public.flujo_dinero (empresa_id) WHERE empresa_id IS NOT NULL;

ALTER TABLE public.flujo_dinero_eventos DROP CONSTRAINT IF EXISTS flujo_dinero_eventos_accion_check;
ALTER TABLE public.flujo_dinero_eventos ADD CONSTRAINT flujo_dinero_eventos_accion_check
  CHECK (accion IN ('RECIBIDO', 'CAJA_CONFIRMADA', 'APLICADO', 'RECHAZADO', 'APLICACION_REVERTIDA', 'PAGO_REVERTIDO', 'LIBRO_CANCELADO', 'CLIENTE_CAMBIADO'));

CREATE OR REPLACE FUNCTION public.flujo_empresas()
RETURNS TABLE (id uuid, nombre text, razon_social text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT (public.flujo_es_admin() OR public.es_finanzas(auth.uid()) OR public.flujo_cap('recibe') OR public.flujo_cap('caja') OR public.flujo_cap('aplica')) THEN
    RAISE EXCEPTION 'No tienes asignada ninguna etapa del flujo de dinero';
  END IF;
  RETURN QUERY SELECT e.id, e.nombre, e.razon_social FROM public.empresas_grupo e WHERE e.activo ORDER BY e.nombre;
END;
$$;

-- Cuentas que Caja puede elegir para un movimiento: activas, de su empresa, del tipo que pide el método y de su moneda.
DROP FUNCTION IF EXISTS public.flujo_cuentas();
CREATE OR REPLACE FUNCTION public.flujo_cuentas(_flujo_id uuid DEFAULT NULL)
RETURNS TABLE (id uuid, nombre text, tipo text, moneda text, orden integer, banco text, ultimos4 text, empresa_id uuid, empresa_nombre text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE f public.flujo_dinero%ROWTYPE;
BEGIN
  IF NOT (public.flujo_cap('caja') OR public.flujo_es_admin()) THEN RAISE EXCEPTION 'No tienes asignada la etapa de caja'; END IF;
  IF _flujo_id IS NOT NULL THEN
    SELECT * INTO f FROM public.flujo_dinero WHERE flujo_dinero.id = _flujo_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'No existe el movimiento'; END IF;
  END IF;
  RETURN QUERY
    SELECT c.id, c.nombre, c.tipo::text, c.moneda, c.orden, c.banco, c.ultimos4, c.empresa_id, e.nombre
      FROM public.cuentas_financieras c LEFT JOIN public.empresas_grupo e ON e.id = c.empresa_id
     WHERE c.activo
       AND (_flujo_id IS NULL OR (
             c.moneda = f.moneda
         AND (f.empresa_id IS NULL OR c.empresa_id = f.empresa_id)
         AND (CASE WHEN f.metodo_pago = 'EFECTIVO' THEN c.tipo = 'EFECTIVO'
                   WHEN f.metodo_pago IN ('TRANSFERENCIA', 'DEPOSITO') THEN c.tipo = 'BANCO' ELSE true END)))
     ORDER BY e.nombre NULLS LAST, c.orden, c.nombre;
END;
$$;

DROP FUNCTION IF EXISTS public.flujo_recibir(text, numeric, text, text, date, text, uuid, text, text, numeric, text, jsonb);

CREATE OR REPLACE FUNCTION public.flujo_recibir(
  _tipo text, _monto numeric, _moneda text, _metodo_pago text, _fecha date, _contraparte_nombre text,
  _cliente_id uuid DEFAULT NULL, _concepto text DEFAULT NULL, _referencia text DEFAULT NULL, _tipo_cambio numeric DEFAULT NULL,
  _evidencia_path text DEFAULT NULL, _datos jsonb DEFAULT '{}'::jsonb, _empresa_id uuid DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cli public.clientes%ROWTYPE;
  v_prueba boolean := public.es_usuario_prueba(auth.uid());
  v_id uuid; v_folio text;
  v_permitidos text[] := ARRAY['categoria', 'descripcion', 'proveedor_id', 'empleado_id', 'contraparte_tipo', 'via',
    'intermediario_id', 'intermediario_nombre', 'requiere_comprobacion', 'factura_folio', 'factura_uuid', 'factura_rfc',
    'remision_id', 'oportunidad_id', 'contenedor_id'];
  v_extra text[];
BEGIN
  IF NOT public.flujo_cap('recibe') THEN RAISE EXCEPTION 'No tienes asignada la etapa de recepción'; END IF;
  IF _tipo NOT IN ('PAGO_CLIENTE', 'REEMBOLSO', 'SALIDA') THEN RAISE EXCEPTION 'Tipo inválido: %', _tipo; END IF;
  IF _monto IS NULL OR _monto <= 0 THEN RAISE EXCEPTION 'El monto debe ser mayor a cero'; END IF;
  IF nullif(btrim(coalesce(_contraparte_nombre, '')), '') IS NULL THEN RAISE EXCEPTION 'Indica quién entregó o recibe el dinero'; END IF;
  IF nullif(btrim(coalesce(_evidencia_path, '')), '') IS NULL OR length(btrim(_evidencia_path)) < 3 THEN
    RAISE EXCEPTION 'Adjunta la evidencia: imagen o PDF de la transferencia, o el vale de efectivo. Sin evidencia no se registra.';
  END IF;
  IF _metodo_pago <> 'EFECTIVO' AND nullif(btrim(coalesce(_referencia, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Captura la referencia o folio del movimiento';
  END IF;
  IF _tipo <> 'PAGO_CLIENTE' AND nullif(btrim(coalesce(_concepto, '')), '') IS NULL THEN
    RAISE EXCEPTION 'El concepto es obligatorio';
  END IF;
  -- Empresa del grupo que recibe el dinero: obligatoria en cuanto hay empresas activas (de ella salen las cuentas de Caja).
  IF EXISTS (SELECT 1 FROM public.empresas_grupo WHERE activo) THEN
    IF _empresa_id IS NULL THEN RAISE EXCEPTION 'Elige la empresa del grupo que recibe el dinero'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.empresas_grupo WHERE id = _empresa_id AND activo) THEN RAISE EXCEPTION 'La empresa elegida no existe o está desactivada'; END IF;
  ELSE
    _empresa_id := NULL;
  END IF;
  SELECT array_agg(k) INTO v_extra FROM jsonb_object_keys(coalesce(_datos, '{}'::jsonb)) k WHERE k <> ALL (v_permitidos);
  IF v_extra IS NOT NULL THEN RAISE EXCEPTION 'Datos no permitidos en el movimiento: %', array_to_string(v_extra, ', '); END IF;
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
                                   concepto, referencia, es_prueba, recibido_por, evidencia_path, evidencia_tipo, datos_libro, empresa_id)
  VALUES (_tipo, round(_monto, 2), coalesce(_moneda, 'MXN'), CASE WHEN coalesce(_moneda, 'MXN') = 'MXN' THEN NULL ELSE _tipo_cambio END,
          _metodo_pago::public.metodo_pago, _fecha, btrim(_contraparte_nombre), CASE WHEN _tipo = 'PAGO_CLIENTE' THEN _cliente_id END,
          nullif(btrim(coalesce(_concepto, '')), ''), nullif(btrim(coalesce(_referencia, '')), ''), v_prueba, auth.uid(),
          btrim(_evidencia_path),
          CASE _metodo_pago WHEN 'EFECTIVO' THEN 'vale_efectivo' WHEN 'TRANSFERENCIA' THEN 'transferencia' WHEN 'DEPOSITO' THEN 'deposito' ELSE 'otro' END,
          coalesce(_datos, '{}'::jsonb), _empresa_id)
  RETURNING id, folio INTO v_id, v_folio;

  PERFORM public._flujo_evento(v_id, 'RECIBIDO', NULL, 'RECIBIDO', NULL, jsonb_build_object('tipo', _tipo, 'monto', _monto, 'empresa_id', _empresa_id));
  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_recibir', 'flujo_dinero', v_id, v_folio,
    jsonb_build_object('tipo', _tipo, 'monto', _monto, 'moneda', _moneda), v_prueba);
  RETURN jsonb_build_object('id', v_id, 'folio', v_folio);
END;
$$;

CREATE OR REPLACE FUNCTION public.flujo_confirmar_caja(_id uuid, _cuenta_id uuid, _notas text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  f public.flujo_dinero%ROWTYPE;
  c public.cuentas_financieras%ROWTYPE;
  v_mov uuid;
  d jsonb;
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
  -- La cuenta debe ser de la empresa del movimiento (los movimientos anteriores, sin empresa, aceptan cualquier cuenta).
  IF f.empresa_id IS NOT NULL AND c.empresa_id IS DISTINCT FROM f.empresa_id THEN
    RAISE EXCEPTION 'La cuenta «%» es de %; este movimiento es de %. Elige una cuenta de esa empresa.',
      c.nombre, coalesce((SELECT nombre FROM public.empresas_grupo WHERE id = c.empresa_id), 'ninguna empresa'),
      (SELECT nombre FROM public.empresas_grupo WHERE id = f.empresa_id);
  END IF;

  IF f.metodo_pago = 'EFECTIVO' AND c.tipo <> 'EFECTIVO' THEN
    RAISE EXCEPTION 'El efectivo solo se registra en una caja de efectivo; «%» es una cuenta de banco. / 现金只能登记在现金账户；“%”是银行账户。', c.nombre, c.nombre;
  END IF;
  IF f.metodo_pago IN ('TRANSFERENCIA', 'DEPOSITO') AND c.tipo <> 'BANCO' THEN
    RAISE EXCEPTION 'La transferencia y el depósito solo se registran en una cuenta de banco; «%» es una caja de efectivo. / 转账和存款只能登记在银行账户；“%”是现金账户。', c.nombre, c.nombre;
  END IF;

  -- Único lugar donde nace un movimiento del libro. Un flujo de PRUEBA no escribe en el libro real.
  IF NOT f.es_prueba THEN
    d := coalesce(f.datos_libro, '{}'::jsonb);
    PERFORM set_config('kit.libro_via_flujo', 'on', true);
    INSERT INTO public.movimientos_financieros
      (tipo, estatus, concepto, descripcion, monto, moneda, tipo_cambio, fecha_movimiento, metodo_pago, cuenta_id, referencia,
       contraparte_tipo, cliente_id, contraparte_nombre, recibido_por, created_by, confirmado_por, confirmado_at,
       origen, flujo_id, categoria, proveedor_id, empleado_id, via, intermediario_id, intermediario_nombre,
       requiere_comprobacion, factura_folio, factura_uuid, factura_rfc, remision_id, oportunidad_id, contenedor_id)
    VALUES
      (CASE WHEN f.tipo = 'SALIDA' THEN 'EGRESO'::public.mov_tipo ELSE 'INGRESO'::public.mov_tipo END, 'CONFIRMADO',
       coalesce(f.concepto, 'Pago de cliente ' || f.contraparte_nombre),
       'Flujo de dinero ' || f.folio || coalesce(' · ' || nullif(d->>'descripcion', ''), ''),
       f.monto, f.moneda, f.tipo_cambio, f.fecha, f.metodo_pago, c.id, f.referencia,
       coalesce(nullif(d->>'contraparte_tipo', '')::public.contraparte_tipo,
                CASE WHEN f.cliente_id IS NULL THEN 'OTRO'::public.contraparte_tipo ELSE 'CLIENTE'::public.contraparte_tipo END),
       f.cliente_id, f.contraparte_nombre, f.recibido_por, auth.uid(), auth.uid(), now(),
       'FLUJO', f.id, nullif(d->>'categoria', ''), nullif(d->>'proveedor_id', '')::uuid, nullif(d->>'empleado_id', '')::uuid,
       coalesce(nullif(d->>'via', '')::public.mov_via, 'DIRECTO'::public.mov_via),
       nullif(d->>'intermediario_id', '')::uuid, nullif(d->>'intermediario_nombre', ''),
       coalesce((d->>'requiere_comprobacion')::boolean, false),
       nullif(d->>'factura_folio', ''), nullif(d->>'factura_uuid', ''), nullif(d->>'factura_rfc', ''),
       nullif(d->>'remision_id', '')::uuid, nullif(d->>'oportunidad_id', '')::uuid, nullif(d->>'contenedor_id', '')::uuid)
    RETURNING id INTO v_mov;
    PERFORM set_config('kit.libro_via_flujo', 'off', true);

    -- La evidencia de Recibe queda en el expediente del movimiento.
    IF f.evidencia_path IS NOT NULL THEN
      INSERT INTO public.movimiento_adjuntos (movimiento_id, tipo_documento, nombre_archivo, storage_path, subido_por, notas)
      VALUES (v_mov, CASE WHEN f.metodo_pago = 'EFECTIVO' THEN 'VALE_EFECTIVO' ELSE 'COMPROBANTE_PAGO' END::public.adjunto_tipo,
              coalesce(nullif(regexp_replace(f.evidencia_path, '^.*/', ''), ''), 'evidencia'), f.evidencia_path, f.recibido_por,
              'Evidencia capturada en Recibe (' || f.folio || ')');
    END IF;
  END IF;

  UPDATE public.flujo_dinero
     SET etapa = 'EN_CAJA', cuenta_id = c.id, caja_por = auth.uid(), caja_at = now(),
         caja_notas = nullif(btrim(coalesce(_notas, '')), ''), movimiento_id = v_mov
   WHERE id = f.id;
  PERFORM public._flujo_evento(f.id, 'CAJA_CONFIRMADA', 'RECIBIDO', 'EN_CAJA', _notas,
    jsonb_build_object('cuenta', c.nombre, 'movimiento_id', v_mov));
  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_caja', 'flujo_dinero', f.id, f.folio,
    jsonb_build_object('cuenta', c.nombre, 'movimiento_id', v_mov), f.es_prueba);
END;
$$;
-- ── 4. Saldos por cuenta y por empresa (solo lo confirmado por Caja); en tránsito aparte ──
CREATE OR REPLACE VIEW public.v_saldos_cuentas AS
SELECT c.id, c.nombre, c.tipo, c.moneda, c.activo, c.orden, c.saldo_inicial,
       COALESCE(sum(CASE WHEN m.tipo = 'INGRESO' THEN m.monto END), 0::numeric) AS total_ingresos,
       COALESCE(sum(CASE WHEN m.tipo = 'EGRESO' THEN m.monto END), 0::numeric) AS total_egresos,
       c.saldo_inicial + COALESCE(sum(CASE WHEN m.tipo = 'INGRESO' THEN m.monto ELSE -m.monto END), 0::numeric) AS saldo_actual,
       c.empresa_id, e.nombre AS empresa_nombre, c.banco, c.ultimos4
  FROM public.cuentas_financieras c
  LEFT JOIN public.empresas_grupo e ON e.id = c.empresa_id
  LEFT JOIN public.movimientos_financieros m ON m.cuenta_id = c.id AND m.estatus = 'CONFIRMADO'
 GROUP BY c.id, e.nombre;
ALTER VIEW public.v_saldos_cuentas SET (security_invoker = true);

CREATE OR REPLACE VIEW public.v_saldos_por_empresa WITH (security_invoker = true) AS
SELECT s.empresa_id, coalesce(s.empresa_nombre, 'Sin empresa asignada') AS empresa_nombre, s.moneda,
       count(*)::integer AS cuentas, sum(s.saldo_actual) AS saldo_actual,
       sum(s.total_ingresos) AS total_ingresos, sum(s.total_egresos) AS total_egresos
  FROM public.v_saldos_cuentas s WHERE s.activo OR s.saldo_actual <> 0
 GROUP BY s.empresa_id, s.empresa_nombre, s.moneda;
GRANT SELECT ON public.v_saldos_por_empresa TO authenticated;

DROP VIEW IF EXISTS public.v_flujo_en_transito;
CREATE VIEW public.v_flujo_en_transito WITH (security_invoker = true) AS
SELECT f.empresa_id, coalesce(e.nombre, 'Sin empresa asignada') AS empresa_nombre, f.moneda,
       CASE WHEN f.tipo = 'SALIDA' THEN 'EGRESO' ELSE 'INGRESO' END AS tipo,
       count(*)::integer AS movimientos, sum(f.monto) AS monto
  FROM public.flujo_dinero f LEFT JOIN public.empresas_grupo e ON e.id = f.empresa_id
 WHERE f.etapa = 'RECIBIDO'
 GROUP BY f.empresa_id, e.nombre, f.moneda, CASE WHEN f.tipo = 'SALIDA' THEN 'EGRESO' ELSE 'INGRESO' END;
GRANT SELECT ON public.v_flujo_en_transito TO authenticated;

DROP VIEW IF EXISTS public.v_flujo_dinero CASCADE;
CREATE VIEW public.v_flujo_dinero WITH (security_invoker = true) AS
SELECT f.*,
       public.flujo_nombre(f.recibido_por)  AS recibido_por_nombre,
       public.flujo_nombre(f.caja_por)      AS caja_por_nombre,
       public.flujo_nombre(f.aplicado_por)  AS aplicado_por_nombre,
       public.flujo_nombre(f.rechazado_por) AS rechazado_por_nombre,
       public.flujo_nombre(f.revertido_por) AS revertido_por_nombre,
       (SELECT e.nombre FROM public.empresas_grupo e WHERE e.id = f.empresa_id) AS empresa_nombre
  FROM public.flujo_dinero f;
GRANT SELECT ON public.v_flujo_dinero TO authenticated;
-- v_flujo_dinero_eventos y v_flujo_en_transito dependían de la vista anterior: se recrean.
CREATE OR REPLACE VIEW public.v_flujo_dinero_eventos WITH (security_invoker = true) AS
SELECT e.id, e.flujo_id, f.folio, e.accion, e.de_etapa, e.a_etapa, e.usuario_id, public.flujo_nombre(e.usuario_id) AS usuario_nombre,
       e.motivo, e.detalle, e.es_prueba, e.created_at
  FROM public.flujo_dinero_eventos e JOIN public.flujo_dinero f ON f.id = e.flujo_id;
GRANT SELECT ON public.v_flujo_dinero_eventos TO authenticated;

-- ── 5. Búsqueda de remisiones al aplicar ───────────────────────────────────
-- Remisiones confirmadas (no cotización), no canceladas y con saldo; prueba y real no se mezclan.
-- Por omisión, las del cliente del pago, de la más antigua a la más reciente.
CREATE OR REPLACE FUNCTION public.flujo_buscar_remisiones(
  _flujo_id uuid, _todos_clientes boolean DEFAULT false, _folio text DEFAULT NULL, _cliente text DEFAULT NULL,
  _vendedor text DEFAULT NULL, _desde date DEFAULT NULL, _hasta date DEFAULT NULL,
  _monto_min numeric DEFAULT NULL, _monto_max numeric DEFAULT NULL, _limite integer DEFAULT 20, _desplazamiento integer DEFAULT 0
) RETURNS TABLE (
  id uuid, folio text, cliente_id uuid, cliente text, codigo_cliente text, vendedor_id uuid, vendedor text, fecha_remision date,
  total numeric, cobrado numeric, saldo_pendiente numeric, antiguedad_dias integer, es_del_cliente boolean, sugerida boolean, total_filas bigint
) LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE f public.flujo_dinero%ROWTYPE;
BEGIN
  IF NOT public.flujo_cap('aplica') THEN RAISE EXCEPTION 'No tienes asignada la etapa de aplicación'; END IF;
  SELECT * INTO f FROM public.flujo_dinero WHERE flujo_dinero.id = _flujo_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el movimiento'; END IF;
  PERFORM public.exigir_dato_prueba(f.es_prueba, 'el movimiento ' || f.folio);
  IF auth.uid() IN (f.recibido_por, f.caja_por) THEN
    RAISE EXCEPTION 'Quien recibió o metió el dinero a caja no lo aplica: lo hace una tercera persona';
  END IF;
  IF f.tipo <> 'PAGO_CLIENTE' THEN RAISE EXCEPTION '% no es un pago de cliente: no se aplica a remisiones', f.folio; END IF;
  RETURN QUERY
    WITH cand AS (
      SELECT r.id, r.folio, r.cliente_id, r.vendedor_id, r.nombre_vendedor, r.fecha_remision
        FROM public.remisiones_refacciones r
       WHERE r.es_prueba = f.es_prueba AND r.etapa <> 'cancelada' AND NOT r.abierta
         AND (coalesce(_todos_clientes, false) OR r.cliente_id = f.cliente_id)
         AND (nullif(btrim(coalesce(_folio, '')), '') IS NULL OR r.folio ILIKE '%' || btrim(_folio) || '%')
         AND (nullif(btrim(coalesce(_vendedor, '')), '') IS NULL OR coalesce(r.nombre_vendedor, '') ILIKE '%' || btrim(_vendedor) || '%')
         AND (_desde IS NULL OR r.fecha_remision >= _desde) AND (_hasta IS NULL OR r.fecha_remision <= _hasta)
    ), det AS (
      SELECT c.id, c.folio, c.cliente_id, coalesce(cl.nombre_comercial, cl.razon_social, cl.codigo_erp) AS cliente, cl.codigo_erp AS codigo_cliente,
             c.vendedor_id, c.nombre_vendedor AS vendedor, c.fecha_remision, e.total, e.cobrado_neto AS cobrado, e.saldo_pendiente
        FROM cand c
        JOIN public.clientes cl ON cl.id = c.cliente_id
        CROSS JOIN LATERAL public.estado_cobro_remision_refaccion(c.id) e
       WHERE e.saldo_pendiente > 0
         AND (nullif(btrim(coalesce(_cliente, '')), '') IS NULL
              OR coalesce(cl.nombre_comercial, '') ILIKE '%' || btrim(_cliente) || '%'
              OR coalesce(cl.razon_social, '') ILIKE '%' || btrim(_cliente) || '%'
              OR coalesce(cl.codigo_erp, '') ILIKE '%' || btrim(_cliente) || '%')
         AND (_monto_min IS NULL OR e.saldo_pendiente >= _monto_min) AND (_monto_max IS NULL OR e.saldo_pendiente <= _monto_max)
    )
    SELECT d.id, d.folio, d.cliente_id, d.cliente, d.codigo_cliente, d.vendedor_id, d.vendedor, d.fecha_remision,
           d.total, d.cobrado, d.saldo_pendiente, (current_date - d.fecha_remision)::integer,
           (d.cliente_id = f.cliente_id), (d.cliente_id = f.cliente_id AND d.saldo_pendiente = f.monto), count(*) OVER ()
      FROM det d
     ORDER BY d.fecha_remision, d.folio
     LIMIT greatest(least(coalesce(_limite, 20), 100), 1) OFFSET greatest(coalesce(_desplazamiento, 0), 0);
END;
$$;

-- Cuentas por cobrar abiertas del cliente del pago (destino «Abonar a crédito»): solo datos reales y en pesos.
CREATE OR REPLACE FUNCTION public.flujo_cxc_cliente(_flujo_id uuid)
RETURNS TABLE (id uuid, folio text, concepto text, fecha_emision date, fecha_vencimiento date, monto numeric, saldo numeric, estatus text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE f public.flujo_dinero%ROWTYPE;
BEGIN
  IF NOT public.flujo_cap('aplica') THEN RAISE EXCEPTION 'No tienes asignada la etapa de aplicación'; END IF;
  SELECT * INTO f FROM public.flujo_dinero WHERE flujo_dinero.id = _flujo_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el movimiento'; END IF;
  PERFORM public.exigir_dato_prueba(f.es_prueba, 'el movimiento ' || f.folio);
  IF f.es_prueba OR f.tipo <> 'PAGO_CLIENTE' OR f.cliente_id IS NULL THEN RETURN; END IF;
  RETURN QUERY
    SELECT c.id, c.folio, c.concepto, c.fecha_emision, c.fecha_vencimiento, c.monto, c.saldo, c.estatus::text
      FROM public.cuentas_por_cobrar c
     WHERE c.cliente_id = f.cliente_id AND c.moneda = 'MXN' AND c.estatus IN ('ABIERTA', 'PARCIAL') AND c.saldo > 0
     ORDER BY c.fecha_vencimiento NULLS LAST, c.fecha_emision;
END;
$$;
REVOKE ALL ON FUNCTION public.flujo_cxc_cliente(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_cxc_cliente(uuid) TO authenticated;

-- Cambiar el cliente de un pago capturado por error: lo hace quien aplica (no quien recibió ni confirmó),
-- con motivo obligatorio y huella en el historial. Con el parámetro `flujo_cambio_cliente_exige_admin` encendido,
-- además lo debe hacer un administrador (segunda persona).
INSERT INTO public.compras_parametros (clave, valor, descripcion)
VALUES ('flujo_cambio_cliente_exige_admin', 'false'::jsonb,
        'Si es true, corregir el cliente de un pago en la etapa Aplica lo hace un administrador (segunda persona). Apagado: lo hace quien aplica, con motivo y huella.')
ON CONFLICT (clave) DO NOTHING;

ALTER TABLE public.flujo_dinero_eventos DROP CONSTRAINT IF EXISTS flujo_dinero_eventos_accion_check;
ALTER TABLE public.flujo_dinero_eventos ADD CONSTRAINT flujo_dinero_eventos_accion_check
  CHECK (accion IN ('RECIBIDO', 'CAJA_CONFIRMADA', 'APLICADO', 'RECHAZADO', 'APLICACION_REVERTIDA', 'PAGO_REVERTIDO', 'LIBRO_CANCELADO', 'CLIENTE_CAMBIADO'));

CREATE OR REPLACE FUNCTION public.flujo_cambiar_cliente(_flujo_id uuid, _cliente_id uuid, _motivo text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE f public.flujo_dinero%ROWTYPE; nuevo public.clientes%ROWTYPE; viejo public.clientes%ROWTYPE;
BEGIN
  SELECT * INTO f FROM public.flujo_dinero WHERE id = _flujo_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el movimiento'; END IF;
  PERFORM public.exigir_dato_prueba(f.es_prueba, 'el movimiento ' || f.folio);
  IF coalesce(public.compras_parametro('flujo_cambio_cliente_exige_admin') = 'true'::jsonb, false) THEN
    IF NOT public.flujo_es_admin() THEN RAISE EXCEPTION 'El cambio de cliente lo hace un administrador (segunda persona)'; END IF;
  ELSIF NOT public.flujo_cap('aplica') THEN
    RAISE EXCEPTION 'No tienes asignada la etapa de aplicación';
  END IF;
  IF auth.uid() IN (f.recibido_por, f.caja_por) THEN
    RAISE EXCEPTION 'Quien recibió o metió el dinero a caja no corrige el cliente: lo hace otra persona';
  END IF;
  IF f.tipo <> 'PAGO_CLIENTE' THEN RAISE EXCEPTION '% no es un pago de cliente', f.folio; END IF;
  IF f.etapa <> 'EN_CAJA' THEN RAISE EXCEPTION '% no está pendiente de aplicar (etapa: %)', f.folio, f.etapa; END IF;
  IF length(btrim(coalesce(_motivo, ''))) < 5 THEN RAISE EXCEPTION 'El motivo del cambio de cliente es obligatorio (mínimo 5 caracteres)'; END IF;
  IF _cliente_id IS NOT DISTINCT FROM f.cliente_id THEN RAISE EXCEPTION 'Ese ya es el cliente del pago'; END IF;
  SELECT * INTO nuevo FROM public.clientes WHERE id = _cliente_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Elige el cliente correcto'; END IF;
  IF nuevo.es_prueba <> f.es_prueba THEN
    RAISE EXCEPTION 'No se mezclan datos de prueba con reales: el cliente elegido es %', CASE WHEN nuevo.es_prueba THEN 'de prueba' ELSE 'real' END;
  END IF;
  SELECT * INTO viejo FROM public.clientes WHERE id = f.cliente_id;

  UPDATE public.flujo_dinero SET cliente_id = nuevo.id WHERE id = f.id;
  IF f.movimiento_id IS NOT NULL THEN
    PERFORM set_config('kit.libro_admin', 'on', true);
    UPDATE public.movimientos_financieros SET cliente_id = nuevo.id WHERE id = f.movimiento_id;
    PERFORM set_config('kit.libro_admin', 'off', true);
  END IF;
  PERFORM public._flujo_evento(f.id, 'CLIENTE_CAMBIADO', 'EN_CAJA', 'EN_CAJA', _motivo,
    jsonb_build_object('de', jsonb_build_object('id', viejo.id, 'nombre', coalesce(viejo.nombre_comercial, viejo.razon_social), 'codigo', viejo.codigo_erp),
                       'a', jsonb_build_object('id', nuevo.id, 'nombre', coalesce(nuevo.nombre_comercial, nuevo.razon_social), 'codigo', nuevo.codigo_erp)));
  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_cambiar_cliente', 'flujo_dinero', f.id, f.folio,
    jsonb_build_object('motivo', btrim(_motivo), 'de', viejo.id, 'a', nuevo.id), f.es_prueba);
END;
$$;

-- ── 6. Permisos ────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.catalogo_bancos_bitacora_inmutable() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cuenta_catalogo_guardia() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.empresa_guardar(uuid, text, text, boolean, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cuenta_guardar(uuid, uuid, text, text, text, text, text, boolean, integer, numeric, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_empresas() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_cuentas(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_recibir(text, numeric, text, text, date, text, uuid, text, text, numeric, text, jsonb, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_confirmar_caja(uuid, uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_buscar_remisiones(uuid, boolean, text, text, text, date, date, numeric, numeric, integer, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_cambiar_cliente(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.empresa_guardar(uuid, text, text, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cuenta_guardar(uuid, uuid, text, text, text, text, text, boolean, integer, numeric, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.flujo_empresas() TO authenticated;
GRANT EXECUTE ON FUNCTION public.flujo_cuentas(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.flujo_recibir(text, numeric, text, text, date, text, uuid, text, text, numeric, text, jsonb, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.flujo_confirmar_caja(uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.flujo_buscar_remisiones(uuid, boolean, text, text, text, date, date, numeric, numeric, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.flujo_cambiar_cliente(uuid, uuid, text) TO authenticated;

-- ── 6b. Evidencia del flujo: quien recibe, lleva caja o aplica sube y ve la carpeta flujo/ ───
-- (el bucket evidencias-compras solo dejaba a quienes leen Compras e inventario).
DO $$
BEGIN
  DROP POLICY IF EXISTS evidencias_flujo_select ON storage.objects;
  CREATE POLICY evidencias_flujo_select ON storage.objects FOR SELECT TO authenticated
    USING (bucket_id = 'evidencias-compras' AND (name LIKE 'flujo/%' OR name LIKE 'prueba/flujo/%')
           AND (public.flujo_es_admin() OR public.es_finanzas(auth.uid()) OR public.flujo_cap('recibe') OR public.flujo_cap('caja') OR public.flujo_cap('aplica')));
  DROP POLICY IF EXISTS evidencias_flujo_insert ON storage.objects;
  CREATE POLICY evidencias_flujo_insert ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'evidencias-compras' AND (name LIKE 'flujo/%' OR name LIKE 'prueba/flujo/%')
           AND (public.flujo_es_admin() OR public.flujo_cap('recibe')));
EXCEPTION
  WHEN insufficient_privilege OR undefined_table THEN
    RAISE NOTICE 'PENDIENTE MANUAL: crea en Storage las políticas de evidencias-compras para la carpeta flujo/ (ver el documento de diseño).';
END $$;

-- ── 7. Postflight ──────────────────────────────────────────────────────────
DO $postflight$
BEGIN
  IF has_table_privilege('authenticated', 'public.cuentas_financieras', 'INSERT')
     OR has_table_privilege('authenticated', 'public.cuentas_financieras', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.cuentas_financieras', 'DELETE') THEN
    RAISE EXCEPTION 'Las cuentas siguen abiertas a escritura directa.';
  END IF;
  IF to_regprocedure('public.flujo_recibir(text,numeric,text,text,date,text,uuid,text,text,numeric,text,jsonb)') IS NOT NULL THEN
    RAISE EXCEPTION 'Quedó la versión anterior de flujo_recibir (sin empresa).';
  END IF;
  IF to_regprocedure('public.flujo_cuentas()') IS NOT NULL THEN RAISE EXCEPTION 'Quedó flujo_cuentas() sin filtro por movimiento.'; END IF;
  IF has_function_privilege('anon', 'public.flujo_buscar_remisiones(uuid,boolean,text,text,text,date,date,numeric,numeric,integer,integer)', 'execute') THEN
    RAISE EXCEPTION 'flujo_buscar_remisiones no debe estar abierta a anon.';
  END IF;
END $postflight$;

SELECT (SELECT count(*) FROM public.empresas_grupo) AS empresas,
       (SELECT count(*) FROM public.cuentas_financieras WHERE empresa_id IS NULL) AS cuentas_sin_empresa,
       (SELECT count(*) FROM public.cuentas_financieras) AS cuentas;

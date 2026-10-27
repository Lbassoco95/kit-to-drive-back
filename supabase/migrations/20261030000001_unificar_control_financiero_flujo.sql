-- ============================================================================
-- Unificar Control financiero y Flujo de dinero (PROPUESTA, sin aplicar)
--
-- Criterio de Polo (2026-10-27): todo movimiento de dinero sigue Recibe → Caja →
-- Aplica. El libro solo se alimenta cuando Caja confirma. No hay otra puerta.
-- Diseño: docs/unificacion-control-financiero-flujo.md
--
--  1. Flujo: evidencia obligatoria, datos del libro, destinos CXC y SALDO_FAVOR,
--     etapa REVERTIDO e historial inmutable (flujo_dinero_eventos).
--  2. Libro: columnas origen y flujo_id; solo Caja inserta; nada se borra; el
--     monto/cuenta no se editan; corrección solo por RPC con motivo (administrador
--     financiero): cancelar, ajustar (no monetario) y comprobar.
--  3. Abonos a cuentas por cobrar: solo nacen del flujo; el saldo de la CxC no se
--     reescribe a mano; un abono se revierte, no se borra.
--  4. Cobranza: se cierran registrar/validar/aplicar pago directos.
--  5. Cuentas: el saldo inicial solo cambia por RPC con motivo.
--  6. Reversa coherente desde Cobranza (y desde el flujo): la aplicación vuelve a
--     «En caja, por aplicar»; un pago revertido cancela el movimiento del libro.
--  7. Vistas: v_movimientos_financieros con origen y estado del flujo,
--     v_flujo_dinero, v_flujo_dinero_eventos y v_flujo_en_transito.
--
-- Sin pérdida: solo agrega columnas y tablas; nada se elimina ni se reescribe.
-- Depende de 20261012000001 (flujo) y 20261028000001 (regla de cuenta por método).
-- Idempotente. Para el SQL editor de Supabase; NO usar `supabase db push`.
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.flujo_dinero') IS NULL THEN _faltan := _faltan || 'flujo_dinero'::text; END IF;
  IF to_regclass('public.movimientos_financieros') IS NULL THEN _faltan := _faltan || 'movimientos_financieros'::text; END IF;
  IF to_regclass('public.cxc_abonos') IS NULL THEN _faltan := _faltan || 'cxc_abonos'::text; END IF;
  IF to_regclass('public.cobranza_pagos') IS NULL THEN _faltan := _faltan || 'cobranza_pagos'::text; END IF;
  IF to_regprocedure('public.flujo_cap(text,uuid)') IS NULL THEN _faltan := _faltan || 'flujo_cap'::text; END IF;
  IF to_regprocedure('public.flujo_es_admin(uuid)') IS NULL THEN _faltan := _faltan || 'flujo_es_admin'::text; END IF;
  IF to_regprocedure('public.es_finanzas_admin(uuid)') IS NULL THEN _faltan := _faltan || 'es_finanzas_admin'::text; END IF;
  IF to_regprocedure('public._validar_destino_cobro(uuid,uuid,boolean,numeric)') IS NULL THEN _faltan := _faltan || '_validar_destino_cobro'::text; END IF;
  IF position('cuenta de banco' in pg_get_functiondef('public.flujo_confirmar_caja(uuid,uuid,text)'::regprocedure)) = 0 THEN
    _faltan := _faltan || 'regla de cuenta por método (20261028000001)'::text;
  END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ', ');
  END IF;
END $preflight$;

-- ── 1. Flujo: evidencia, datos del libro, etapa REVERTIDO, destinos ────────
ALTER TABLE public.flujo_dinero
  ADD COLUMN IF NOT EXISTS evidencia_path  text,
  ADD COLUMN IF NOT EXISTS evidencia_tipo  text,
  ADD COLUMN IF NOT EXISTS datos_libro     jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS reversa_motivo  text,
  ADD COLUMN IF NOT EXISTS revertido_por   uuid REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS revertido_at    timestamptz;

DO $checks$
DECLARE c record;
BEGIN
  FOR c IN SELECT conname, pg_get_constraintdef(oid) d FROM pg_constraint
            WHERE conrelid = 'public.flujo_dinero'::regclass AND contype = 'c'
              AND (pg_get_constraintdef(oid) LIKE '%RECIBIDO%' OR pg_get_constraintdef(oid) LIKE '%REEMBOLSO_PROVEEDOR%')
              AND conname NOT IN ('flujo_etapa_con_reversa', 'flujo_destino_ampliado')
  LOOP
    EXECUTE format('ALTER TABLE public.flujo_dinero DROP CONSTRAINT %I', c.conname);
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'flujo_etapa_con_reversa') THEN
    ALTER TABLE public.flujo_dinero ADD CONSTRAINT flujo_etapa_con_reversa
      CHECK (etapa IN ('RECIBIDO', 'EN_CAJA', 'APLICADO', 'RECHAZADO', 'REVERTIDO'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'flujo_destino_ampliado') THEN
    ALTER TABLE public.flujo_dinero ADD CONSTRAINT flujo_destino_ampliado
      CHECK (destino IS NULL OR destino IN ('REMISION', 'CXC', 'SALDO_FAVOR', 'REEMBOLSO_PROVEEDOR', 'REEMBOLSO_EMPLEADO', 'GASTO', 'PAGO_PROVEEDOR', 'OTRO'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'flujo_reversa_motivo') THEN
    ALTER TABLE public.flujo_dinero ADD CONSTRAINT flujo_reversa_motivo
      CHECK (etapa <> 'REVERTIDO' OR nullif(btrim(coalesce(reversa_motivo, '')), '') IS NOT NULL);
  END IF;
END $checks$;

-- Historial inmutable: cada paso del flujo (quién, cuándo, de qué etapa a cuál, motivo).
CREATE TABLE IF NOT EXISTS public.flujo_dinero_eventos (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  flujo_id   uuid NOT NULL REFERENCES public.flujo_dinero(id),
  accion     text NOT NULL CHECK (accion IN ('RECIBIDO', 'CAJA_CONFIRMADA', 'APLICADO', 'RECHAZADO',
                                              'APLICACION_REVERTIDA', 'PAGO_REVERTIDO', 'LIBRO_CANCELADO')),
  de_etapa   text,
  a_etapa    text,
  usuario_id uuid,
  motivo     text,
  detalle    jsonb NOT NULL DEFAULT '{}'::jsonb,
  es_prueba  boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()   -- ordena aun dentro de una misma transacción
);
CREATE INDEX IF NOT EXISTS idx_flujo_eventos_flujo ON public.flujo_dinero_eventos (flujo_id, created_at);

CREATE OR REPLACE FUNCTION public.flujo_eventos_inmutable()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'El historial del flujo de dinero no se edita ni se borra.';
END;
$$;
DROP TRIGGER IF EXISTS trg_flujo_eventos_inmutable ON public.flujo_dinero_eventos;
CREATE TRIGGER trg_flujo_eventos_inmutable BEFORE UPDATE OR DELETE ON public.flujo_dinero_eventos
  FOR EACH ROW EXECUTE FUNCTION public.flujo_eventos_inmutable();

ALTER TABLE public.flujo_dinero_eventos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.flujo_dinero_eventos FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.flujo_dinero_eventos TO authenticated;
GRANT ALL ON public.flujo_dinero_eventos TO service_role;

CREATE OR REPLACE FUNCTION public._flujo_evento(_flujo uuid, _accion text, _de text, _a text, _motivo text DEFAULT NULL, _detalle jsonb DEFAULT '{}'::jsonb)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  INSERT INTO public.flujo_dinero_eventos (flujo_id, accion, de_etapa, a_etapa, usuario_id, motivo, detalle, es_prueba)
  SELECT f.id, _accion, _de, _a, auth.uid(), nullif(btrim(coalesce(_motivo, '')), ''), coalesce(_detalle, '{}'::jsonb), f.es_prueba
    FROM public.flujo_dinero f WHERE f.id = _flujo
$$;

-- Historial de lo que ya existía (los pasos quedan reconstruidos de las columnas del flujo).
INSERT INTO public.flujo_dinero_eventos (flujo_id, accion, de_etapa, a_etapa, usuario_id, detalle, es_prueba, created_at)
SELECT f.id, 'RECIBIDO', NULL, 'RECIBIDO', f.recibido_por, jsonb_build_object('reconstruido', true), f.es_prueba, f.recibido_at
  FROM public.flujo_dinero f WHERE NOT EXISTS (SELECT 1 FROM public.flujo_dinero_eventos e WHERE e.flujo_id = f.id AND e.accion = 'RECIBIDO');
INSERT INTO public.flujo_dinero_eventos (flujo_id, accion, de_etapa, a_etapa, usuario_id, detalle, es_prueba, created_at)
SELECT f.id, 'CAJA_CONFIRMADA', 'RECIBIDO', 'EN_CAJA', f.caja_por, jsonb_build_object('reconstruido', true), f.es_prueba, f.caja_at
  FROM public.flujo_dinero f WHERE f.caja_at IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.flujo_dinero_eventos e WHERE e.flujo_id = f.id AND e.accion = 'CAJA_CONFIRMADA');
INSERT INTO public.flujo_dinero_eventos (flujo_id, accion, de_etapa, a_etapa, usuario_id, detalle, es_prueba, created_at)
SELECT f.id, 'APLICADO', 'EN_CAJA', 'APLICADO', f.aplicado_por, jsonb_build_object('reconstruido', true, 'destino', f.destino), f.es_prueba, f.aplicado_at
  FROM public.flujo_dinero f WHERE f.aplicado_at IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.flujo_dinero_eventos e WHERE e.flujo_id = f.id AND e.accion = 'APLICADO');
INSERT INTO public.flujo_dinero_eventos (flujo_id, accion, de_etapa, a_etapa, usuario_id, motivo, detalle, es_prueba, created_at)
SELECT f.id, 'RECHAZADO', NULL, 'RECHAZADO', f.rechazado_por, f.motivo_rechazo, jsonb_build_object('reconstruido', true), f.es_prueba, f.rechazado_at
  FROM public.flujo_dinero f WHERE f.rechazado_at IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.flujo_dinero_eventos e WHERE e.flujo_id = f.id AND e.accion = 'RECHAZADO');

-- ── 2. Libro: origen, solo Caja inserta, nada se borra, sin editar montos ───
ALTER TABLE public.movimientos_financieros
  ADD COLUMN IF NOT EXISTS origen   text NOT NULL DEFAULT 'HISTORICO_DIRECTO',
  ADD COLUMN IF NOT EXISTS flujo_id uuid REFERENCES public.flujo_dinero(id);
ALTER TABLE public.movimientos_financieros ALTER COLUMN origen DROP DEFAULT;
DO $c$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'movimientos_origen_check') THEN
    ALTER TABLE public.movimientos_financieros ADD CONSTRAINT movimientos_origen_check
      CHECK (origen IN ('FLUJO', 'HISTORICO_DIRECTO', 'CONTRA_MOVIMIENTO'));
  END IF;
END $c$;
CREATE INDEX IF NOT EXISTS idx_movimientos_flujo ON public.movimientos_financieros (flujo_id) WHERE flujo_id IS NOT NULL;

-- Lo que ya vino del flujo queda ligado (si hubiera).
SELECT set_config('kit.libro_admin', 'on', true);
UPDATE public.movimientos_financieros m SET origen = 'FLUJO', flujo_id = f.id
  FROM public.flujo_dinero f WHERE f.movimiento_id = m.id AND m.origen <> 'FLUJO';
SELECT set_config('kit.libro_admin', 'off', true);

CREATE OR REPLACE FUNCTION public.libro_guardia()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF coalesce(current_setting('kit.libro_via_flujo', true), '') <> 'on' OR NEW.origen NOT IN ('FLUJO', 'CONTRA_MOVIMIENTO') THEN
      RAISE EXCEPTION 'El libro solo recibe dinero cuando Caja lo confirma en el flujo de dinero (Control financiero → Mi bandeja → «Recibí dinero»). No hay otra forma de registrar un movimiento.';
    END IF;
    RETURN NEW;
  END IF;
  IF TG_OP = 'DELETE' THEN
    IF coalesce(current_setting('kit.reiniciando_prueba', true), '') = 'si' THEN RETURN OLD; END IF;
    RAISE EXCEPTION 'En el libro nada se borra: el movimiento se cancela con motivo (administrador financiero).';
  END IF;
  -- UPDATE: monto, cuenta, tipo, fecha, método, origen y estatus solo cambian por las funciones internas.
  IF coalesce(current_setting('kit.libro_admin', true), '') <> 'on'
     AND (NEW.tipo, NEW.monto, NEW.moneda, NEW.tipo_cambio, NEW.cuenta_id, NEW.fecha_movimiento, NEW.metodo_pago,
          NEW.origen, NEW.flujo_id, NEW.estatus, NEW.cliente_id)
         IS DISTINCT FROM
         (OLD.tipo, OLD.monto, OLD.moneda, OLD.tipo_cambio, OLD.cuenta_id, OLD.fecha_movimiento, OLD.metodo_pago,
          OLD.origen, OLD.flujo_id, OLD.estatus, OLD.cliente_id) THEN
    RAISE EXCEPTION 'Un movimiento del libro no se edita en monto, cuenta, fecha, método ni estatus: se cancela con motivo y el dinero se registra otra vez por el flujo.';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS a_libro_guardia ON public.movimientos_financieros;
CREATE TRIGGER a_libro_guardia BEFORE INSERT OR UPDATE OR DELETE ON public.movimientos_financieros
  FOR EACH ROW EXECUTE FUNCTION public.libro_guardia();

DROP POLICY IF EXISTS movimientos_insert ON public.movimientos_financieros;
DROP POLICY IF EXISTS movimientos_update_admin ON public.movimientos_financieros;
DROP POLICY IF EXISTS movimientos_update_propio ON public.movimientos_financieros;
DROP POLICY IF EXISTS movimientos_delete ON public.movimientos_financieros;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.movimientos_financieros FROM PUBLIC, anon, authenticated;

-- ── 3. Abonos a cuentas por cobrar: solo del flujo ─────────────────────────
ALTER TABLE public.cxc_abonos
  ADD COLUMN IF NOT EXISTS origen           text NOT NULL DEFAULT 'HISTORICO_DIRECTO',
  ADD COLUMN IF NOT EXISTS flujo_id         uuid REFERENCES public.flujo_dinero(id),
  ADD COLUMN IF NOT EXISTS revertido_at     timestamptz,
  ADD COLUMN IF NOT EXISTS revertido_por    uuid REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS motivo_reversion text;
DO $c$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'cxc_abonos_origen_check') THEN
    ALTER TABLE public.cxc_abonos ADD CONSTRAINT cxc_abonos_origen_check CHECK (origen IN ('FLUJO', 'HISTORICO_DIRECTO'));
  END IF;
END $c$;

CREATE OR REPLACE FUNCTION public.cxc_guardia()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_TABLE_NAME = 'cxc_abonos' THEN
    IF coalesce(current_setting('kit.cxc_interno', true), '') <> 'on' THEN
      RAISE EXCEPTION 'Los abonos a cuentas por cobrar nacen solo del flujo de dinero (Control financiero → Mi bandeja): Recibe, Caja y Aplica con destino «Cuenta por cobrar».';
    END IF;
    IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'Un abono no se borra: se revierte con motivo.'; END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  -- cuentas_por_cobrar: monto y saldo solo cambian por el flujo; la cancelación sí es directa.
  IF coalesce(current_setting('kit.cxc_interno', true), '') = 'on' THEN RETURN NEW; END IF;
  IF (NEW.monto, NEW.saldo) IS DISTINCT FROM (OLD.monto, OLD.saldo)
     OR (NEW.estatus IS DISTINCT FROM OLD.estatus AND NOT (NEW.estatus = 'CANCELADA' AND OLD.estatus IN ('ABIERTA', 'PARCIAL'))) THEN
    RAISE EXCEPTION 'El monto y el saldo de una cuenta por cobrar no se editan: se mueven con los abonos del flujo de dinero.';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS a_cxc_abonos_guardia ON public.cxc_abonos;
CREATE TRIGGER a_cxc_abonos_guardia BEFORE INSERT OR UPDATE OR DELETE ON public.cxc_abonos
  FOR EACH ROW EXECUTE FUNCTION public.cxc_guardia();
DROP TRIGGER IF EXISTS a_cxc_guardia ON public.cuentas_por_cobrar;
CREATE TRIGGER a_cxc_guardia BEFORE UPDATE ON public.cuentas_por_cobrar
  FOR EACH ROW EXECUTE FUNCTION public.cxc_guardia();

DROP POLICY IF EXISTS cxc_abonos_insert ON public.cxc_abonos;
DROP POLICY IF EXISTS cxc_abonos_delete ON public.cxc_abonos;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.cxc_abonos FROM PUBLIC, anon, authenticated;

-- Revertir un abono: lo marca y devuelve el saldo a la cuenta por cobrar (sin borrar nada).
CREATE OR REPLACE FUNCTION public._cxc_revertir_abono(_abono uuid, _motivo text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a public.cxc_abonos%ROWTYPE; c public.cuentas_por_cobrar%ROWTYPE; v_saldo numeric;
BEGIN
  SELECT * INTO a FROM public.cxc_abonos WHERE id = _abono FOR UPDATE;
  IF NOT FOUND OR a.revertido_at IS NOT NULL THEN RETURN; END IF;
  SELECT * INTO c FROM public.cuentas_por_cobrar WHERE id = a.cxc_id FOR UPDATE;
  PERFORM set_config('kit.cxc_interno', 'on', true);
  UPDATE public.cxc_abonos SET revertido_at = now(), revertido_por = auth.uid(), motivo_reversion = btrim(_motivo) WHERE id = a.id;
  v_saldo := round(c.saldo + a.monto, 2);
  UPDATE public.cuentas_por_cobrar
     SET saldo = v_saldo,
         estatus = CASE WHEN c.estatus = 'CANCELADA' THEN c.estatus WHEN v_saldo >= c.monto THEN 'ABIERTA' ELSE 'PARCIAL' END
   WHERE id = c.id;
  PERFORM set_config('kit.cxc_interno', 'off', true);
END;
$$;

-- ── 4. Cobranza: se cierran los pagos directos ─────────────────────────────
ALTER TABLE public.cobranza_pagos
  ADD COLUMN IF NOT EXISTS origen   text NOT NULL DEFAULT 'HISTORICO_DIRECTO',
  ADD COLUMN IF NOT EXISTS flujo_id uuid REFERENCES public.flujo_dinero(id);
ALTER TABLE public.cobranza_saldos_favor ADD COLUMN IF NOT EXISTS flujo_id uuid REFERENCES public.flujo_dinero(id);
DO $c$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'cobranza_pagos_origen_check') THEN
    ALTER TABLE public.cobranza_pagos ADD CONSTRAINT cobranza_pagos_origen_check CHECK (origen IN ('FLUJO', 'HISTORICO_DIRECTO'));
  END IF;
END $c$;
-- Defensa en profundidad: las tablas de cobranza solo se escriben por las funciones del flujo y de reversa.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.cobranza_pagos, public.cobranza_aplicaciones, public.cobranza_saldos_favor FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.registrar_pago_cobranza(jsonb) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.validar_pago_cobranza(uuid, boolean, text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.aplicar_pago_cobranza(uuid, jsonb, boolean, text) FROM PUBLIC, anon, authenticated;

-- ── 5. Cuentas: el saldo inicial solo cambia con motivo ────────────────────
CREATE OR REPLACE FUNCTION public.cuenta_guardia()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.saldo_inicial IS DISTINCT FROM OLD.saldo_inicial AND coalesce(current_setting('kit.cuenta_admin', true), '') <> 'on' THEN
    RAISE EXCEPTION 'El saldo inicial de una cuenta no se edita directo: usa «Ajustar saldo inicial» con motivo (administrador financiero).';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS a_cuenta_guardia ON public.cuentas_financieras;
CREATE TRIGGER a_cuenta_guardia BEFORE UPDATE ON public.cuentas_financieras
  FOR EACH ROW EXECUTE FUNCTION public.cuenta_guardia();

CREATE OR REPLACE FUNCTION public.cuenta_ajustar_saldo_inicial(_cuenta_id uuid, _nuevo numeric, _motivo text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE c public.cuentas_financieras%ROWTYPE;
BEGIN
  IF NOT (public.es_finanzas_admin(auth.uid()) AND public.usuario_activo(auth.uid())) THEN
    RAISE EXCEPTION 'Sólo el administrador financiero ajusta el saldo inicial';
  END IF;
  IF length(btrim(coalesce(_motivo, ''))) < 5 THEN RAISE EXCEPTION 'El motivo es obligatorio (mínimo 5 caracteres)'; END IF;
  SELECT * INTO c FROM public.cuentas_financieras WHERE id = _cuenta_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe la cuenta'; END IF;
  PERFORM set_config('kit.cuenta_admin', 'on', true);
  UPDATE public.cuentas_financieras SET saldo_inicial = _nuevo WHERE id = c.id;
  PERFORM set_config('kit.cuenta_admin', 'off', true);
  PERFORM public.registrar_bitacora_compras('cobranza', 'ajustar_saldo_inicial', 'cuentas_financieras', c.id, c.nombre,
    jsonb_build_object('de', c.saldo_inicial, 'a', _nuevo, 'motivo', btrim(_motivo)), false);
END;
$$;

-- ── 6. Flujo: recibir (con evidencia), caja (libro con origen), aplicar, rechazar ─
DROP FUNCTION IF EXISTS public.flujo_recibir(text, numeric, text, text, date, text, uuid, text, text, numeric);
DROP FUNCTION IF EXISTS public.flujo_recibir(text, numeric, text, text, date, text, uuid, text, text, numeric, text, text, jsonb);
CREATE OR REPLACE FUNCTION public.flujo_recibir(
  _tipo text, _monto numeric, _moneda text, _metodo_pago text, _fecha date, _contraparte_nombre text,
  _cliente_id uuid DEFAULT NULL, _concepto text DEFAULT NULL, _referencia text DEFAULT NULL, _tipo_cambio numeric DEFAULT NULL,
  _evidencia_path text DEFAULT NULL, _datos jsonb DEFAULT '{}'::jsonb
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
                                   concepto, referencia, es_prueba, recibido_por, evidencia_path, evidencia_tipo, datos_libro)
  VALUES (_tipo, round(_monto, 2), coalesce(_moneda, 'MXN'), CASE WHEN coalesce(_moneda, 'MXN') = 'MXN' THEN NULL ELSE _tipo_cambio END,
          _metodo_pago::public.metodo_pago, _fecha, btrim(_contraparte_nombre), CASE WHEN _tipo = 'PAGO_CLIENTE' THEN _cliente_id END,
          nullif(btrim(coalesce(_concepto, '')), ''), nullif(btrim(coalesce(_referencia, '')), ''), v_prueba, auth.uid(),
          btrim(_evidencia_path),
          CASE _metodo_pago WHEN 'EFECTIVO' THEN 'vale_efectivo' WHEN 'TRANSFERENCIA' THEN 'transferencia' WHEN 'DEPOSITO' THEN 'deposito' ELSE 'otro' END,
          coalesce(_datos, '{}'::jsonb))
  RETURNING id, folio INTO v_id, v_folio;

  PERFORM public._flujo_evento(v_id, 'RECIBIDO', NULL, 'RECIBIDO', NULL, jsonb_build_object('tipo', _tipo, 'monto', _monto));
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

DROP FUNCTION IF EXISTS public.flujo_aplicar(uuid, text, jsonb, text);
CREATE OR REPLACE FUNCTION public.flujo_aplicar(_id uuid, _destino text, _aplicaciones jsonb DEFAULT '[]'::jsonb, _notas text DEFAULT NULL, _extra jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  f public.flujo_dinero%ROWTYPE;
  v_cta text; v_pago uuid; v_pfolio text; it jsonb;
  r public.remisiones_refacciones%ROWTYPE; cx public.cuentas_por_cobrar%ROWTYPE;
  v_total numeric := 0; v_rem numeric; v_n integer := 0; v_saldo_folio text;
  v_notas text := nullif(btrim(coalesce(_notas, '')), '');
  v_monto numeric;
BEGIN
  IF NOT public.flujo_cap('aplica') THEN RAISE EXCEPTION 'No tienes asignada la etapa de aplicación'; END IF;
  SELECT * INTO f FROM public.flujo_dinero WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el movimiento'; END IF;
  PERFORM public.exigir_dato_prueba(f.es_prueba, 'el movimiento ' || f.folio);
  IF f.etapa <> 'EN_CAJA' THEN RAISE EXCEPTION '% no está pendiente de aplicar (etapa: %)', f.folio, f.etapa; END IF;
  IF auth.uid() IN (f.recibido_por, f.caja_por) THEN
    RAISE EXCEPTION 'Quien recibió o metió el dinero a caja no puede aplicarlo: lo hace una tercera persona';
  END IF;
  IF NOT ((f.tipo = 'PAGO_CLIENTE' AND _destino IN ('REMISION', 'CXC', 'SALDO_FAVOR', 'OTRO'))
       OR (f.tipo = 'REEMBOLSO' AND _destino IN ('REEMBOLSO_PROVEEDOR', 'REEMBOLSO_EMPLEADO', 'OTRO'))
       OR (f.tipo = 'SALIDA' AND _destino IN ('GASTO', 'PAGO_PROVEEDOR', 'OTRO'))) THEN
    RAISE EXCEPTION 'El destino % no corresponde a un movimiento de tipo %', _destino, f.tipo;
  END IF;

  IF f.tipo = 'PAGO_CLIENTE' THEN
    IF _destino IN ('SALDO_FAVOR', 'OTRO') THEN _aplicaciones := '[]'::jsonb; END IF;
    IF _destino IN ('REMISION', 'CXC') AND jsonb_array_length(coalesce(_aplicaciones, '[]'::jsonb)) = 0 THEN
      IF _destino = 'REMISION' THEN RAISE EXCEPTION 'Elige al menos una remisión a la que se abona'; END IF;
      RAISE EXCEPTION 'Elige al menos una cuenta por cobrar a la que se abona';
    END IF;
    SELECT coalesce(sum(round((e.value->>'monto')::numeric, 2)), 0) INTO v_total
      FROM jsonb_array_elements(coalesce(_aplicaciones, '[]'::jsonb)) e;
    IF v_total > f.monto THEN
      RAISE EXCEPTION 'Se quieren aplicar % y el pago % sólo tiene %',
        to_char(v_total, 'FM999,999,990.00'), f.folio, to_char(f.monto, 'FM999,999,990.00');
    END IF;

    IF _destino = 'CXC' THEN
      IF f.es_prueba THEN RAISE EXCEPTION 'Las cuentas por cobrar no tienen modo prueba: este movimiento es de prueba'; END IF;
      PERFORM set_config('kit.cxc_interno', 'on', true);
      FOR it IN SELECT value FROM jsonb_array_elements(_aplicaciones) LOOP
        v_monto := round((it->>'monto')::numeric, 2);
        SELECT * INTO cx FROM public.cuentas_por_cobrar WHERE id = (it->>'cxc_id')::uuid FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'No existe la cuenta por cobrar'; END IF;
        IF cx.cliente_id <> f.cliente_id THEN RAISE EXCEPTION 'La cuenta por cobrar % es de otro cliente', coalesce(cx.folio, cx.concepto); END IF;
        IF cx.moneda <> 'MXN' THEN RAISE EXCEPTION 'La cuenta por cobrar % no está en pesos', coalesce(cx.folio, cx.concepto); END IF;
        IF cx.estatus NOT IN ('ABIERTA', 'PARCIAL') THEN RAISE EXCEPTION 'La cuenta por cobrar % está %', coalesce(cx.folio, cx.concepto), lower(cx.estatus); END IF;
        IF v_monto <= 0 OR v_monto > cx.saldo THEN
          RAISE EXCEPTION 'A % le quedan % por cobrar y se quieren abonar %', coalesce(cx.folio, cx.concepto),
            to_char(cx.saldo, 'FM999,999,990.00'), to_char(v_monto, 'FM999,999,990.00');
        END IF;
        INSERT INTO public.cxc_abonos (cxc_id, monto, fecha_abono, metodo_pago, referencia, movimiento_id, notas, created_by, origen, flujo_id)
        VALUES (cx.id, v_monto, f.fecha, f.metodo_pago::text, f.referencia, f.movimiento_id,
                'Flujo de dinero ' || f.folio || coalesce(' · ' || v_notas, ''), auth.uid(), 'FLUJO', f.id);
        v_n := v_n + 1;
      END LOOP;
      PERFORM set_config('kit.cxc_interno', 'off', true);
      v_rem := f.monto - v_total;
      IF v_rem > 0 THEN
        v_saldo_folio := public._siguiente_folio_compras('SF', f.es_prueba);
        INSERT INTO public.cobranza_saldos_favor (folio, cliente_id, origen, monto, notas, created_by, es_prueba, flujo_id)
        VALUES (v_saldo_folio, f.cliente_id, 'pago_en_exceso', v_rem, 'Remanente del flujo ' || f.folio, auth.uid(), f.es_prueba, f.id);
      END IF;
    ELSE
      SELECT nombre INTO v_cta FROM public.cuentas_financieras WHERE id = f.cuenta_id;
      v_pfolio := public._siguiente_folio_compras('CP', f.es_prueba);
      INSERT INTO public.cobranza_pagos (folio, cliente_id, fecha, monto, forma, cuenta_destino, referencia, notas, estatus,
                                         conciliado, capturado_por, validado_por, validado_at, es_prueba, evidencia_path, evidencia_tipo, origen, flujo_id)
      VALUES (v_pfolio, f.cliente_id, f.fecha, f.monto, lower(f.metodo_pago::text), v_cta, f.referencia,
              'Flujo de dinero ' || f.folio, 'validado', true, f.recibido_por, f.caja_por, f.caja_at, f.es_prueba,
              f.evidencia_path, f.evidencia_tipo, 'FLUJO', f.id)
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
        INSERT INTO public.cobranza_saldos_favor (folio, cliente_id, origen, monto, pago_origen_id, notas, created_by, es_prueba, flujo_id)
        VALUES (v_saldo_folio, f.cliente_id,
                CASE WHEN v_n > 0 THEN 'pago_en_exceso' ELSE 'pago_anticipado' END,
                v_rem, v_pago, 'Remanente del pago ' || v_pfolio || ' (flujo ' || f.folio || ')', auth.uid(), f.es_prueba, f.id);
      END IF;
    END IF;
  ELSIF f.movimiento_id IS NOT NULL AND coalesce(_extra, '{}'::jsonb) <> '{}'::jsonb THEN
    -- Reembolso o salida: Aplica clasifica el movimiento del libro (no cambia monto ni cuenta).
    UPDATE public.movimientos_financieros
       SET categoria = coalesce(nullif(_extra->>'categoria', ''), categoria),
           proveedor_id = coalesce(nullif(_extra->>'proveedor_id', '')::uuid, proveedor_id),
           empleado_id = coalesce(nullif(_extra->>'empleado_id', '')::uuid, empleado_id),
           contraparte_tipo = CASE _destino WHEN 'REEMBOLSO_PROVEEDOR' THEN 'PROVEEDOR'::public.contraparte_tipo
                                            WHEN 'PAGO_PROVEEDOR' THEN 'PROVEEDOR'::public.contraparte_tipo
                                            WHEN 'REEMBOLSO_EMPLEADO' THEN 'EMPLEADO'::public.contraparte_tipo
                                            ELSE contraparte_tipo END
     WHERE id = f.movimiento_id;
  END IF;

  UPDATE public.flujo_dinero
     SET etapa = 'APLICADO', destino = _destino, aplicado_por = auth.uid(), aplicado_at = now(),
         aplicado_notas = v_notas, cobranza_pago_id = v_pago
   WHERE id = f.id;
  PERFORM public._flujo_evento(f.id, 'APLICADO', 'EN_CAJA', 'APLICADO', v_notas,
    jsonb_build_object('destino', _destino, 'aplicaciones', _aplicaciones, 'pago_cobranza', v_pfolio, 'saldo_favor', v_saldo_folio));
  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_aplicar', 'flujo_dinero', f.id, f.folio,
    jsonb_build_object('destino', _destino, 'aplicaciones', _aplicaciones, 'pago_cobranza', v_pfolio, 'saldo_favor', v_saldo_folio), f.es_prueba);
  RETURN jsonb_build_object('aplicadas', v_n, 'pago', v_pfolio, 'saldo_favor', v_saldo_folio);
END;
$$;

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
    PERFORM set_config('kit.libro_admin', 'on', true);
    UPDATE public.movimientos_financieros
       SET estatus = 'CANCELADO', cancelado_por = auth.uid(), cancelado_at = now(),
           motivo_cancelacion = 'Rechazado en el flujo de dinero ' || f.folio || ': ' || btrim(_motivo)
     WHERE id = f.movimiento_id;
    PERFORM set_config('kit.libro_admin', 'off', true);
  END IF;
  UPDATE public.flujo_dinero
     SET etapa = 'RECHAZADO', motivo_rechazo = btrim(_motivo), rechazado_por = auth.uid(), rechazado_at = now()
   WHERE id = f.id;
  PERFORM public._flujo_evento(f.id, 'RECHAZADO', f.etapa, 'RECHAZADO', _motivo, jsonb_build_object('movimiento_id', f.movimiento_id));
  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_rechazar', 'flujo_dinero', f.id, f.folio,
    jsonb_build_object('motivo', _motivo, 'etapa', f.etapa), f.es_prueba);
END;
$$;

-- ── 7. Reversa coherente ───────────────────────────────────────────────────
-- Núcleo (sin permisos: lo llaman las funciones públicas que sí los revisan).
-- _anular_dinero = false → «En caja, por aplicar» (el dinero sigue en caja; el libro no cambia).
-- _anular_dinero = true  → REVERTIDO y el movimiento del libro se cancela con motivo.
CREATE OR REPLACE FUNCTION public._flujo_revertir(_flujo uuid, _motivo text, _anular_dinero boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  f public.flujo_dinero%ROWTYPE; p public.cobranza_pagos%ROWTYPE; a record; s record; ab record;
  v_motivo text := btrim(_motivo); v_pfolio text;
BEGIN
  SELECT * INTO f FROM public.flujo_dinero WHERE id = _flujo FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el movimiento del flujo'; END IF;
  IF f.etapa <> 'APLICADO' THEN RAISE EXCEPTION '% no está aplicado (etapa: %): no hay nada que revertir', f.folio, f.etapa; END IF;
  PERFORM public.exigir_dato_prueba(f.es_prueba, 'el movimiento ' || f.folio);

  -- Pago de cobranza del flujo (remisión, saldo a favor u otro).
  IF f.cobranza_pago_id IS NOT NULL THEN
    SELECT * INTO p FROM public.cobranza_pagos WHERE id = f.cobranza_pago_id FOR UPDATE;
    v_pfolio := p.folio;
    FOR s IN SELECT * FROM public.cobranza_saldos_favor WHERE pago_origen_id = p.id AND cancelado_at IS NULL LOOP
      IF EXISTS (SELECT 1 FROM public.cobranza_aplicaciones WHERE saldo_favor_id = s.id AND revertida_at IS NULL) THEN
        RAISE EXCEPTION 'El remanente de % ya se usó como saldo a favor (%). Revierte primero ese uso.', p.folio, s.folio;
      END IF;
      UPDATE public.cobranza_saldos_favor SET cancelado_at = now(), cancelado_por = auth.uid(),
             motivo_cancelacion = 'Reversión del flujo ' || f.folio || ': ' || v_motivo WHERE id = s.id;
    END LOOP;
    FOR a IN SELECT * FROM public.cobranza_aplicaciones WHERE pago_id = p.id AND revertida_at IS NULL LOOP
      UPDATE public.cobranza_aplicaciones SET revertida_at = now(), revertida_por = auth.uid(), motivo_reversion = v_motivo WHERE id = a.id;
      INSERT INTO public.remision_refaccion_eventos (remision_id, area, accion, detalle, usuario_id)
      VALUES (a.remision_id, 'finanzas', 'pago_revertido',
              'Se revirtió lo aplicado del pago ' || p.folio || ' (flujo ' || f.folio || ', ' || to_char(a.monto, 'FM999,999,990.00') || '). ' || v_motivo, auth.uid());
      PERFORM public.cobranza_sincronizar_remision(a.remision_id);
    END LOOP;
    UPDATE public.cobranza_pagos SET estatus = 'revertido', revertido_por = auth.uid(), revertido_at = now(), motivo_reversion = v_motivo WHERE id = p.id;
  END IF;

  -- Abonos a cuentas por cobrar del flujo.
  FOR ab IN SELECT id FROM public.cxc_abonos WHERE flujo_id = f.id AND revertido_at IS NULL LOOP
    PERFORM public._cxc_revertir_abono(ab.id, 'Reversión del flujo ' || f.folio || ': ' || v_motivo);
  END LOOP;
  -- Remanente a saldo a favor de un cobro a CxC.
  FOR s IN SELECT * FROM public.cobranza_saldos_favor WHERE flujo_id = f.id AND pago_origen_id IS NULL AND cancelado_at IS NULL LOOP
    IF EXISTS (SELECT 1 FROM public.cobranza_aplicaciones WHERE saldo_favor_id = s.id AND revertida_at IS NULL) THEN
      RAISE EXCEPTION 'El remanente de % ya se usó como saldo a favor (%). Revierte primero ese uso.', f.folio, s.folio;
    END IF;
    UPDATE public.cobranza_saldos_favor SET cancelado_at = now(), cancelado_por = auth.uid(),
           motivo_cancelacion = 'Reversión del flujo ' || f.folio || ': ' || v_motivo WHERE id = s.id;
  END LOOP;

  IF _anular_dinero THEN
    IF f.movimiento_id IS NOT NULL THEN
      PERFORM set_config('kit.libro_admin', 'on', true);
      UPDATE public.movimientos_financieros
         SET estatus = 'CANCELADO', cancelado_por = auth.uid(), cancelado_at = now(),
             motivo_cancelacion = 'Pago revertido desde Cobranza (' || f.folio || '): ' || v_motivo
       WHERE id = f.movimiento_id AND estatus <> 'CANCELADO';
      PERFORM set_config('kit.libro_admin', 'off', true);
      PERFORM public._flujo_evento(f.id, 'LIBRO_CANCELADO', 'APLICADO', 'REVERTIDO', v_motivo, jsonb_build_object('movimiento_id', f.movimiento_id));
    END IF;
    UPDATE public.flujo_dinero
       SET etapa = 'REVERTIDO', reversa_motivo = v_motivo, revertido_por = auth.uid(), revertido_at = now()
     WHERE id = f.id;
    PERFORM public._flujo_evento(f.id, 'PAGO_REVERTIDO', 'APLICADO', 'REVERTIDO', v_motivo, jsonb_build_object('pago_cobranza', v_pfolio));
  ELSE
    UPDATE public.flujo_dinero
       SET etapa = 'EN_CAJA', destino = NULL, aplicado_por = NULL, aplicado_at = NULL, aplicado_notas = NULL,
           cobranza_pago_id = NULL, reversa_motivo = v_motivo
     WHERE id = f.id;
    PERFORM public._flujo_evento(f.id, 'APLICACION_REVERTIDA', 'APLICADO', 'EN_CAJA', v_motivo,
      jsonb_build_object('pago_cobranza', v_pfolio, 'destino_anterior', f.destino, 'aplico', f.aplicado_por));
  END IF;
  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_revertir', 'flujo_dinero', f.id, f.folio,
    jsonb_build_object('motivo', v_motivo, 'anular_dinero', _anular_dinero, 'pago_cobranza', v_pfolio), f.es_prueba);
END;
$$;

CREATE OR REPLACE FUNCTION public.flujo_revertir(_id uuid, _motivo text, _anular_dinero boolean DEFAULT false)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT (public.puede_compras_inventario(auth.uid()) OR public.puede_finanzas_cobranza(auth.uid())) THEN
    RAISE EXCEPTION 'Sólo Compras o Finanzas revierten lo aplicado';
  END IF;
  IF length(btrim(coalesce(_motivo, ''))) < 5 THEN RAISE EXCEPTION 'El motivo de la reversión es obligatorio (mínimo 5 caracteres)'; END IF;
  PERFORM public._flujo_revertir(_id, _motivo, coalesce(_anular_dinero, false));
END;
$$;

-- Cobranza: si el pago o la aplicación vienen del flujo, la reversa deja el flujo coherente.
CREATE OR REPLACE FUNCTION public.revertir_pago_cobranza(_pago_id uuid, _motivo text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE p public.cobranza_pagos%ROWTYPE; a record; s record; v_flujo uuid;
BEGIN
  IF NOT (public.puede_compras_inventario(auth.uid()) OR public.puede_finanzas_cobranza(auth.uid())) THEN
    RAISE EXCEPTION 'Sólo Compras o Finanzas revierten pagos';
  END IF;
  IF nullif(trim(_motivo), '') IS NULL OR char_length(trim(_motivo)) < 5 THEN
    RAISE EXCEPTION 'El motivo de la reversión es obligatorio';
  END IF;
  SELECT * INTO p FROM public.cobranza_pagos WHERE id = _pago_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el pago'; END IF;
  PERFORM public.exigir_dato_prueba(p.es_prueba, 'el pago ' || p.folio);
  IF p.estatus = 'revertido' THEN RAISE EXCEPTION 'El pago % ya está revertido', p.folio; END IF;

  SELECT id INTO v_flujo FROM public.flujo_dinero WHERE cobranza_pago_id = p.id AND etapa = 'APLICADO';
  IF v_flujo IS NOT NULL THEN
    -- Revertir el pago = el dinero no es válido: el flujo queda REVERTIDO y el libro cancela el movimiento.
    PERFORM public._flujo_revertir(v_flujo, _motivo, true);
    RETURN;
  END IF;

  FOR s IN SELECT * FROM public.cobranza_saldos_favor WHERE pago_origen_id = _pago_id AND cancelado_at IS NULL LOOP
    IF EXISTS (SELECT 1 FROM public.cobranza_aplicaciones WHERE saldo_favor_id = s.id AND revertida_at IS NULL) THEN
      RAISE EXCEPTION 'El remanente de % ya se usó como saldo a favor (%). Revierte primero ese uso.', p.folio, s.folio;
    END IF;
    UPDATE public.cobranza_saldos_favor SET cancelado_at = now(), cancelado_por = auth.uid(),
           motivo_cancelacion = 'Reversión del pago ' || p.folio || ': ' || trim(_motivo)
     WHERE id = s.id;
  END LOOP;
  FOR a IN SELECT * FROM public.cobranza_aplicaciones WHERE pago_id = _pago_id AND revertida_at IS NULL LOOP
    UPDATE public.cobranza_aplicaciones SET revertida_at = now(), revertida_por = auth.uid(), motivo_reversion = trim(_motivo)
     WHERE id = a.id;
    INSERT INTO public.remision_refaccion_eventos (remision_id, area, accion, detalle, usuario_id)
    VALUES (a.remision_id, 'finanzas', 'pago_revertido',
            'Se revirtió lo aplicado del pago ' || p.folio || ' (' || to_char(a.monto, 'FM999,999,990.00') || '). ' || trim(_motivo), auth.uid());
    PERFORM public.cobranza_sincronizar_remision(a.remision_id);
  END LOOP;
  UPDATE public.cobranza_pagos SET estatus = 'revertido', revertido_por = auth.uid(), revertido_at = now(),
         motivo_reversion = trim(_motivo)
   WHERE id = _pago_id;
  PERFORM public.registrar_bitacora_compras('cobranza', 'revertir_pago', 'cobranza_pagos', p.id, p.folio,
    jsonb_build_object('motivo', _motivo, 'monto', p.monto), p.es_prueba);
END;
$$;

CREATE OR REPLACE FUNCTION public.revertir_aplicacion_cobranza(_aplicacion_id uuid, _motivo text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a public.cobranza_aplicaciones%ROWTYPE; v_flujo uuid;
BEGIN
  IF NOT (public.puede_compras_inventario(auth.uid()) OR public.puede_finanzas_cobranza(auth.uid())) THEN
    RAISE EXCEPTION 'Sólo Compras o Finanzas revierten aplicaciones';
  END IF;
  IF nullif(trim(_motivo), '') IS NULL OR char_length(trim(_motivo)) < 5 THEN
    RAISE EXCEPTION 'El motivo de la reversión es obligatorio';
  END IF;
  SELECT * INTO a FROM public.cobranza_aplicaciones WHERE id = _aplicacion_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe la aplicación'; END IF;
  PERFORM public.exigir_dato_prueba(a.es_prueba, 'la aplicación');
  IF a.revertida_at IS NOT NULL THEN RAISE EXCEPTION 'Ya estaba revertida'; END IF;

  IF a.pago_id IS NOT NULL THEN
    SELECT id INTO v_flujo FROM public.flujo_dinero WHERE cobranza_pago_id = a.pago_id AND etapa = 'APLICADO';
    IF v_flujo IS NOT NULL THEN
      -- Revertir lo aplicado de un pago del flujo: regresa a «En caja, por aplicar» (se deshace toda la aplicación).
      PERFORM public._flujo_revertir(v_flujo, _motivo, false);
      RETURN;
    END IF;
  END IF;

  UPDATE public.cobranza_aplicaciones SET revertida_at = now(), revertida_por = auth.uid(), motivo_reversion = trim(_motivo)
   WHERE id = _aplicacion_id;
  INSERT INTO public.remision_refaccion_eventos (remision_id, area, accion, detalle, usuario_id)
  VALUES (a.remision_id, 'finanzas', 'aplicacion_revertida',
          'Se revirtió una aplicación de ' || to_char(a.monto, 'FM999,999,990.00') || '. ' || trim(_motivo), auth.uid());
  PERFORM public.cobranza_sincronizar_remision(a.remision_id);
  PERFORM public.registrar_bitacora_compras('cobranza', 'revertir_aplicacion', 'cobranza_aplicaciones', a.id, NULL,
    jsonb_build_object('motivo', _motivo, 'monto', a.monto, 'remision_id', a.remision_id), a.es_prueba);
END;
$$;

-- ── 8. Corrección del libro (solo administrador financiero, con motivo) ────
CREATE OR REPLACE FUNCTION public.movimiento_cancelar(_id uuid, _motivo text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE m public.movimientos_financieros%ROWTYPE; f public.flujo_dinero%ROWTYPE;
BEGIN
  IF NOT (public.es_finanzas_admin(auth.uid()) AND public.usuario_activo(auth.uid())) THEN
    RAISE EXCEPTION 'Sólo el administrador financiero cancela un movimiento del libro';
  END IF;
  IF length(btrim(coalesce(_motivo, ''))) < 5 THEN RAISE EXCEPTION 'El motivo es obligatorio (mínimo 5 caracteres)'; END IF;
  SELECT * INTO m FROM public.movimientos_financieros WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el movimiento'; END IF;
  IF m.estatus = 'CANCELADO' THEN RAISE EXCEPTION '% ya está cancelado', m.folio; END IF;
  IF m.flujo_id IS NOT NULL THEN
    SELECT * INTO f FROM public.flujo_dinero WHERE id = m.flujo_id FOR UPDATE;
    IF f.etapa = 'APLICADO' THEN
      RAISE EXCEPTION '% ya está aplicado (%): revierte primero lo aplicado en Cobranza o en el flujo', m.folio, f.folio;
    END IF;
    IF f.caja_por = auth.uid() THEN
      RAISE EXCEPTION 'Quien confirmó este movimiento en caja no lo cancela: lo hace otro administrador financiero';
    END IF;
  END IF;
  PERFORM set_config('kit.libro_admin', 'on', true);
  UPDATE public.movimientos_financieros
     SET estatus = 'CANCELADO', cancelado_por = auth.uid(), cancelado_at = now(), motivo_cancelacion = btrim(_motivo)
   WHERE id = m.id;
  PERFORM set_config('kit.libro_admin', 'off', true);
  IF m.flujo_id IS NOT NULL AND f.etapa = 'EN_CAJA' THEN
    UPDATE public.flujo_dinero SET etapa = 'REVERTIDO', reversa_motivo = btrim(_motivo), revertido_por = auth.uid(), revertido_at = now() WHERE id = f.id;
    PERFORM public._flujo_evento(f.id, 'LIBRO_CANCELADO', 'EN_CAJA', 'REVERTIDO', _motivo, jsonb_build_object('movimiento_id', m.id));
  END IF;
  PERFORM public.registrar_bitacora_compras('cobranza', 'cancelar_movimiento', 'movimientos_financieros', m.id, m.folio,
    jsonb_build_object('motivo', btrim(_motivo)), false);
END;
$$;

CREATE OR REPLACE FUNCTION public.movimiento_ajustar(_id uuid, _cambios jsonb, _motivo text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  m public.movimientos_financieros%ROWTYPE;
  v_permitidos text[] := ARRAY['concepto', 'categoria', 'descripcion', 'contraparte_nombre', 'proveedor_id', 'empleado_id',
    'oportunidad_id', 'contenedor_id', 'remision_id', 'intermediario_nombre', 'factura_folio', 'factura_uuid', 'factura_rfc'];
  v_extra text[];
BEGIN
  IF NOT (public.es_finanzas_admin(auth.uid()) AND public.usuario_activo(auth.uid())) THEN
    RAISE EXCEPTION 'Sólo el administrador financiero ajusta un movimiento del libro';
  END IF;
  IF length(btrim(coalesce(_motivo, ''))) < 5 THEN RAISE EXCEPTION 'El motivo es obligatorio (mínimo 5 caracteres)'; END IF;
  SELECT array_agg(k) INTO v_extra FROM jsonb_object_keys(coalesce(_cambios, '{}'::jsonb)) k WHERE k <> ALL (v_permitidos);
  IF v_extra IS NOT NULL THEN
    RAISE EXCEPTION 'No se ajusta % (monto, cuenta, fecha y método no se editan: cancela y registra otra vez por el flujo)', array_to_string(v_extra, ', ');
  END IF;
  SELECT * INTO m FROM public.movimientos_financieros WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el movimiento'; END IF;
  IF m.estatus = 'CANCELADO' THEN RAISE EXCEPTION '% está cancelado', m.folio; END IF;
  UPDATE public.movimientos_financieros SET
    concepto = CASE WHEN _cambios ? 'concepto' THEN coalesce(nullif(btrim(_cambios->>'concepto'), ''), concepto) ELSE concepto END,
    categoria = CASE WHEN _cambios ? 'categoria' THEN nullif(btrim(_cambios->>'categoria'), '') ELSE categoria END,
    descripcion = CASE WHEN _cambios ? 'descripcion' THEN nullif(btrim(_cambios->>'descripcion'), '') ELSE descripcion END,
    contraparte_nombre = CASE WHEN _cambios ? 'contraparte_nombre' THEN coalesce(nullif(btrim(_cambios->>'contraparte_nombre'), ''), contraparte_nombre) ELSE contraparte_nombre END,
    proveedor_id = CASE WHEN _cambios ? 'proveedor_id' THEN nullif(_cambios->>'proveedor_id', '')::uuid ELSE proveedor_id END,
    empleado_id = CASE WHEN _cambios ? 'empleado_id' THEN nullif(_cambios->>'empleado_id', '')::uuid ELSE empleado_id END,
    oportunidad_id = CASE WHEN _cambios ? 'oportunidad_id' THEN nullif(_cambios->>'oportunidad_id', '')::uuid ELSE oportunidad_id END,
    contenedor_id = CASE WHEN _cambios ? 'contenedor_id' THEN nullif(_cambios->>'contenedor_id', '')::uuid ELSE contenedor_id END,
    remision_id = CASE WHEN _cambios ? 'remision_id' THEN nullif(_cambios->>'remision_id', '')::uuid ELSE remision_id END,
    intermediario_nombre = CASE WHEN _cambios ? 'intermediario_nombre' THEN nullif(btrim(_cambios->>'intermediario_nombre'), '') ELSE intermediario_nombre END,
    factura_folio = CASE WHEN _cambios ? 'factura_folio' THEN nullif(btrim(_cambios->>'factura_folio'), '') ELSE factura_folio END,
    factura_uuid = CASE WHEN _cambios ? 'factura_uuid' THEN nullif(btrim(_cambios->>'factura_uuid'), '') ELSE factura_uuid END,
    factura_rfc = CASE WHEN _cambios ? 'factura_rfc' THEN nullif(btrim(_cambios->>'factura_rfc'), '') ELSE factura_rfc END
  WHERE id = m.id;
  INSERT INTO public.movimiento_bitacora (movimiento_id, accion, usuario_id, detalle)
  VALUES (m.id, 'AJUSTADO', auth.uid(), jsonb_build_object('motivo', btrim(_motivo), 'cambios', _cambios));
  PERFORM public.registrar_bitacora_compras('cobranza', 'ajustar_movimiento', 'movimientos_financieros', m.id, m.folio,
    jsonb_build_object('motivo', btrim(_motivo), 'cambios', _cambios), false);
END;
$$;

CREATE OR REPLACE FUNCTION public.movimiento_comprobar(_id uuid, _monto_comprobado numeric, _monto_devuelto numeric DEFAULT 0)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE m public.movimientos_financieros%ROWTYPE;
BEGIN
  IF NOT (public.es_finanzas(auth.uid()) AND public.usuario_activo(auth.uid())) THEN
    RAISE EXCEPTION 'Sólo Finanzas comprueba un egreso';
  END IF;
  SELECT * INTO m FROM public.movimientos_financieros WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el movimiento'; END IF;
  IF m.estatus <> 'CONFIRMADO' THEN RAISE EXCEPTION '% no está confirmado por Caja', m.folio; END IF;
  IF NOT m.requiere_comprobacion THEN RAISE EXCEPTION '% no requiere comprobación', m.folio; END IF;
  IF m.comprobado THEN RAISE EXCEPTION '% ya está comprobado', m.folio; END IF;
  IF _monto_comprobado IS NULL OR _monto_comprobado < 0 OR coalesce(_monto_devuelto, 0) < 0
     OR _monto_comprobado + coalesce(_monto_devuelto, 0) > m.monto THEN
    RAISE EXCEPTION 'Lo comprobado más lo devuelto no puede superar lo entregado (%)', to_char(m.monto, 'FM999,999,990.00');
  END IF;
  UPDATE public.movimientos_financieros
     SET comprobado = true, monto_comprobado = _monto_comprobado, monto_devuelto = coalesce(_monto_devuelto, 0),
         comprobado_por = auth.uid(), comprobado_at = now()
   WHERE id = m.id;
END;
$$;

-- ── 9. Vistas: estado del flujo, historial, en tránsito ────────────────────
DROP VIEW IF EXISTS public.v_flujo_dinero CASCADE;
CREATE VIEW public.v_flujo_dinero WITH (security_invoker = true) AS
SELECT f.*,
       public.flujo_nombre(f.recibido_por)  AS recibido_por_nombre,
       public.flujo_nombre(f.caja_por)      AS caja_por_nombre,
       public.flujo_nombre(f.aplicado_por)  AS aplicado_por_nombre,
       public.flujo_nombre(f.rechazado_por) AS rechazado_por_nombre,
       public.flujo_nombre(f.revertido_por) AS revertido_por_nombre
  FROM public.flujo_dinero f;
GRANT SELECT ON public.v_flujo_dinero TO authenticated;

CREATE OR REPLACE VIEW public.v_flujo_dinero_eventos WITH (security_invoker = true) AS
SELECT e.id, e.flujo_id, f.folio, e.accion, e.de_etapa, e.a_etapa, e.usuario_id, public.flujo_nombre(e.usuario_id) AS usuario_nombre,
       e.motivo, e.detalle, e.es_prueba, e.created_at
  FROM public.flujo_dinero_eventos e JOIN public.flujo_dinero f ON f.id = e.flujo_id;
GRANT SELECT ON public.v_flujo_dinero_eventos TO authenticated;

-- Lo recibido y aún no confirmado por Caja (no está en saldos ni totales).
CREATE OR REPLACE VIEW public.v_flujo_en_transito WITH (security_invoker = true) AS
SELECT f.moneda, CASE WHEN f.tipo = 'SALIDA' THEN 'EGRESO' ELSE 'INGRESO' END AS tipo,
       count(*)::integer AS movimientos, sum(f.monto) AS monto
  FROM public.flujo_dinero f WHERE f.etapa = 'RECIBIDO' GROUP BY f.moneda, CASE WHEN f.tipo = 'SALIDA' THEN 'EGRESO' ELSE 'INGRESO' END;
GRANT SELECT ON public.v_flujo_en_transito TO authenticated;

DROP POLICY IF EXISTS flujo_eventos_leer ON public.flujo_dinero_eventos;
CREATE POLICY flujo_eventos_leer ON public.flujo_dinero_eventos FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.flujo_dinero f WHERE f.id = flujo_id));

-- Lectura del flujo: prueba y real no se mezclan; Finanzas consulta todo; cada etapa ve el flujo.
DROP POLICY IF EXISTS flujo_dinero_leer ON public.flujo_dinero;
CREATE POLICY flujo_dinero_leer ON public.flujo_dinero FOR SELECT TO authenticated
  USING (
    es_prueba = public.es_usuario_prueba(auth.uid())
    AND (
      public.flujo_es_admin()
      OR public.es_finanzas(auth.uid())
      OR public.flujo_cap('recibe')
      OR public.flujo_cap('caja')
      OR public.flujo_cap('aplica')
    )
  );

-- Libro: origen y estado del flujo (columnas nuevas al final de la vista; se conservan las existentes).
DO $v$
DECLARE v_def text; v_inv boolean;
BEGIN
  v_def := pg_get_viewdef('public.v_movimientos_financieros'::regclass, true);
  IF v_def LIKE '%flujo_folio%' THEN RETURN; END IF;
  v_inv := coalesce((SELECT 'security_invoker=true' = ANY (reloptions) FROM pg_class WHERE oid = 'public.v_movimientos_financieros'::regclass), false);
  v_def := rtrim(v_def, E'; \n');
  IF position(E'\n   FROM movimientos_financieros m' IN v_def) = 0 THEN
    RAISE EXCEPTION 'La vista v_movimientos_financieros no tiene la forma esperada; no se modificó.';
  END IF;
  v_def := replace(v_def, E'\n   FROM movimientos_financieros m',
    E',\n    m.origen AS origen,\n    m.flujo_id AS flujo_id,\n    fl.folio AS flujo_folio,\n    fl.etapa AS flujo_etapa\n   FROM movimientos_financieros m');
  v_def := v_def || E'\n     LEFT JOIN flujo_dinero fl ON fl.id = m.flujo_id';
  EXECUTE 'CREATE OR REPLACE VIEW public.v_movimientos_financieros AS ' || v_def;
  IF v_inv THEN EXECUTE 'ALTER VIEW public.v_movimientos_financieros SET (security_invoker = true)'; END IF;
END $v$;

-- ── 10. Permisos ───────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.libro_guardia() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cxc_guardia() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cuenta_guardia() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.flujo_eventos_inmutable() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._flujo_evento(uuid, text, text, text, text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._flujo_revertir(uuid, text, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._cxc_revertir_abono(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.flujo_recibir(text, numeric, text, text, date, text, uuid, text, text, numeric, text, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_confirmar_caja(uuid, uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_aplicar(uuid, text, jsonb, text, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_rechazar(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_revertir(uuid, text, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.revertir_pago_cobranza(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.revertir_aplicacion_cobranza(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.movimiento_cancelar(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.movimiento_ajustar(uuid, jsonb, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.movimiento_comprobar(uuid, numeric, numeric) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cuenta_ajustar_saldo_inicial(uuid, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_recibir(text, numeric, text, text, date, text, uuid, text, text, numeric, text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.flujo_confirmar_caja(uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.flujo_aplicar(uuid, text, jsonb, text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.flujo_rechazar(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.flujo_revertir(uuid, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.revertir_pago_cobranza(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.revertir_aplicacion_cobranza(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.movimiento_cancelar(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.movimiento_ajustar(uuid, jsonb, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.movimiento_comprobar(uuid, numeric, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cuenta_ajustar_saldo_inicial(uuid, numeric, text) TO authenticated;

-- ── 11. Postflight ─────────────────────────────────────────────────────────
DO $postflight$
BEGIN
  IF has_table_privilege('authenticated', 'public.movimientos_financieros', 'INSERT')
     OR has_table_privilege('authenticated', 'public.movimientos_financieros', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.movimientos_financieros', 'DELETE') THEN
    RAISE EXCEPTION 'El libro sigue abierto a escritura directa.';
  END IF;
  IF has_table_privilege('authenticated', 'public.cxc_abonos', 'INSERT') THEN RAISE EXCEPTION 'cxc_abonos sigue abierta a INSERT.'; END IF;
  IF has_function_privilege('authenticated', 'public.registrar_pago_cobranza(jsonb)', 'execute') THEN
    RAISE EXCEPTION 'registrar_pago_cobranza sigue abierta.';
  END IF;
  IF has_function_privilege('anon', 'public.flujo_aplicar(uuid,text,jsonb,text,jsonb)', 'execute') THEN
    RAISE EXCEPTION 'flujo_aplicar no debe estar abierta a anon.';
  END IF;
  IF to_regprocedure('public.flujo_recibir(text,numeric,text,text,date,text,uuid,text,text,numeric)') IS NOT NULL THEN
    RAISE EXCEPTION 'Quedó la versión anterior de flujo_recibir (sin evidencia).';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'v_movimientos_financieros' AND column_name = 'flujo_folio') THEN
    RAISE EXCEPTION 'v_movimientos_financieros no trae el origen del flujo.';
  END IF;
END $postflight$;

SELECT (SELECT count(*) FROM public.movimientos_financieros WHERE origen = 'HISTORICO_DIRECTO') AS libro_historicos,
       (SELECT count(*) FROM public.movimientos_financieros WHERE origen = 'FLUJO') AS libro_del_flujo,
       (SELECT count(*) FROM public.flujo_dinero_eventos) AS eventos,
       has_table_privilege('authenticated', 'public.movimientos_financieros', 'INSERT') AS libro_abierto;

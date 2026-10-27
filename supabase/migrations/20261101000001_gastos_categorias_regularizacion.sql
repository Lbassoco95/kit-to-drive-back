-- ============================================================================
-- Gastos en dos etapas, categorías, cuentas por prueba/real, monedas, históricos y regularización
-- (PROPUESTA, sin aplicar) — decisiones de Polo del 27 oct 2026.
--
--  1. Gastos: Jair captura (perfil captura_gasto) y Luna confirma (confirma_gasto). Si sale de caja en efectivo,
--     Luna AUTORIZA y Leti (caja) registra la ENTREGA; el libro se mueve al entregar. Transferencia: Luna confirma
--     y sale del banco. Saldo suficiente: se bloquea al confirmar/entregar. Rechazo con motivo; quien capturó corrige.
--  2. Perfiles captura_gasto y confirma_gasto, asignables desde el diálogo de permisos (sin SQL).
--  3. Regla para toda persona: no cancela ni ajusta un movimiento que ella capturó (ni que confirmó/entregó).
--  4. Categorías: ámbito (nacional/internacional), no suman en totales las de cambio de divisa y reclasificación;
--     alta/renombre/desactivación por RPC con bitácora; nunca borrado. Nuevas: Proveedor internacional, Flete
--     internacional, Mantenimiento de oficina, Mantenimiento de vehículos; «Mantenimiento» queda inactiva.
--  5. es_prueba en empresas, cuentas y categorías (prueba y real no se mezclan). Catálogo de monedas por parámetro.
--  6. Históricos: marca de origen REGULARIZACION; resolver históricos (confirmar/cancelar con motivo y bitácora),
--     regularizar un movimiento (p. ej. entrada de USD), reclasificar la cuenta de un movimiento con contra-movimientos
--     (sin tocar el original) y regularizar un pago de cobranza directo. Conciliación: marca simple (quién y cuándo).
--
-- Sin pérdida: no cambia montos ni estatus de nada existente. Depende de 20261031000001. Idempotente.
-- Para el SQL editor de Supabase; NO usar `supabase db push`.
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.empresas_grupo') IS NULL THEN _faltan := _faltan || 'empresas_grupo (20261031000001)'::text; END IF;
  IF to_regprocedure('public.flujo_cuentas(uuid)') IS NULL THEN _faltan := _faltan || 'flujo_cuentas(uuid) (20261031000001)'::text; END IF;
  IF to_regprocedure('public.flujo_recibir(text,numeric,text,text,date,text,uuid,text,text,numeric,text,jsonb,uuid)') IS NULL THEN _faltan := _faltan || 'flujo_recibir con empresa'::text; END IF;
  IF to_regprocedure('public.movimiento_cancelar(uuid,text)') IS NULL THEN _faltan := _faltan || 'movimiento_cancelar (20261030000001)'::text; END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ', ');
  END IF;
END $preflight$;

-- ── 1. Monedas: catálogo extensible por parámetro ──────────────────────────
INSERT INTO public.compras_parametros (clave, valor, descripcion)
VALUES ('monedas_permitidas', '["MXN", "USD"]'::jsonb, 'Monedas que aceptan cuentas, gastos e ingresos del flujo de dinero. Para agregar una, súmala a esta lista.')
ON CONFLICT (clave) DO NOTHING;

CREATE OR REPLACE FUNCTION public.moneda_permitida(_moneda text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce(public.compras_parametro('monedas_permitidas') @> to_jsonb(upper(btrim(coalesce(_moneda, '')))), false)
$$;
REVOKE ALL ON FUNCTION public.moneda_permitida(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.moneda_permitida(text) TO authenticated;

-- ── 2. es_prueba en empresas, cuentas y categorías ─────────────────────────
ALTER TABLE public.empresas_grupo ADD COLUMN IF NOT EXISTS es_prueba boolean NOT NULL DEFAULT false;
ALTER TABLE public.cuentas_financieras ADD COLUMN IF NOT EXISTS es_prueba boolean NOT NULL DEFAULT false;
ALTER TABLE public.categorias_financieras
  ADD COLUMN IF NOT EXISTS es_prueba      boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS ambito         text NOT NULL DEFAULT 'NACIONAL',
  ADD COLUMN IF NOT EXISTS afecta_totales boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS captura        boolean NOT NULL DEFAULT true;
DO $c$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'categorias_ambito_check') THEN
    ALTER TABLE public.categorias_financieras ADD CONSTRAINT categorias_ambito_check CHECK (ambito IN ('NACIONAL', 'INTERNACIONAL'));
  END IF;
END $c$;
ALTER TABLE public.categorias_financieras DROP CONSTRAINT IF EXISTS categorias_financieras_tipo_nombre_key;
CREATE UNIQUE INDEX IF NOT EXISTS ux_categorias_tipo_nombre_prueba ON public.categorias_financieras (tipo, lower(btrim(nombre)), es_prueba);

-- Empresas, cuentas y categorías: cada quien ve solo lo de su modalidad (real o prueba).
DO $p$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['empresas_grupo', 'cuentas_financieras', 'categorias_financieras'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS modo_prueba_lectura ON public.%I', t);
    EXECUTE format('CREATE POLICY modo_prueba_lectura ON public.%I AS RESTRICTIVE FOR SELECT TO authenticated USING (es_prueba = public.es_usuario_prueba(auth.uid()))', t);
  END LOOP;
END $p$;

-- ── 3. Categorías: nuevas, inactivas y las que no suman en totales ─────────
INSERT INTO public.categorias_financieras (tipo, nombre, orden, ambito, captura, afecta_totales)
SELECT x.tipo::public.mov_tipo, x.nombre, x.orden, x.ambito, x.captura, x.afecta
  FROM (VALUES
    ('EGRESO', 'Proveedor internacional', 11, 'INTERNACIONAL', true, true),
    ('EGRESO', 'Flete internacional', 12, 'INTERNACIONAL', true, true),
    ('EGRESO', 'Mantenimiento de oficina', 13, 'NACIONAL', true, true),
    ('EGRESO', 'Mantenimiento de vehículos', 14, 'NACIONAL', true, true),
    ('EGRESO', 'Cambio de divisa', 90, 'NACIONAL', false, false),
    ('INGRESO', 'Cambio de divisa', 90, 'NACIONAL', false, false),
    ('EGRESO', 'Reclasificación entre cuentas', 91, 'NACIONAL', false, false),
    ('INGRESO', 'Reclasificación entre cuentas', 91, 'NACIONAL', false, false)
  ) AS x(tipo, nombre, orden, ambito, captura, afecta)
 WHERE NOT EXISTS (SELECT 1 FROM public.categorias_financieras c WHERE c.tipo = x.tipo::public.mov_tipo AND lower(btrim(c.nombre)) = lower(x.nombre) AND NOT c.es_prueba);
UPDATE public.categorias_financieras SET activo = false WHERE tipo = 'EGRESO' AND nombre = 'Mantenimiento' AND NOT es_prueba AND activo;

-- Copia de prueba (propias de las cuentas de prueba).
INSERT INTO public.categorias_financieras (tipo, nombre, orden, activo, es_prueba, ambito, afecta_totales, captura)
SELECT tipo, nombre, orden, activo, true, ambito, afecta_totales, captura FROM public.categorias_financieras r
 WHERE NOT r.es_prueba
   AND NOT EXISTS (SELECT 1 FROM public.categorias_financieras p WHERE p.es_prueba AND p.tipo = r.tipo AND lower(btrim(p.nombre)) = lower(btrim(r.nombre)));

-- ── 4. Bitácora del catálogo: también categorías ───────────────────────────
ALTER TABLE public.catalogo_bancos_bitacora DROP CONSTRAINT IF EXISTS catalogo_bancos_bitacora_entidad_check;
ALTER TABLE public.catalogo_bancos_bitacora ADD CONSTRAINT catalogo_bancos_bitacora_entidad_check CHECK (entidad IN ('EMPRESA', 'CUENTA', 'CATEGORIA'));

CREATE OR REPLACE FUNCTION public.categoria_guardar(_id uuid, _tipo text, _nombre text, _ambito text DEFAULT 'NACIONAL', _activo boolean DEFAULT true, _motivo text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE c public.categorias_financieras%ROWTYPE; v_id uuid; v_accion text; v_prueba boolean := public.es_usuario_prueba(auth.uid());
BEGIN
  IF NOT (public.es_finanzas_admin(auth.uid()) AND public.usuario_activo(auth.uid())) THEN
    RAISE EXCEPTION 'Sólo el administrador financiero o un administrador da de alta y edita categorías';
  END IF;
  IF length(btrim(coalesce(_nombre, ''))) < 3 THEN RAISE EXCEPTION 'El nombre de la categoría es obligatorio'; END IF;
  IF _tipo NOT IN ('INGRESO', 'EGRESO') THEN RAISE EXCEPTION 'El tipo es ingreso o egreso'; END IF;
  IF coalesce(_ambito, 'NACIONAL') NOT IN ('NACIONAL', 'INTERNACIONAL') THEN RAISE EXCEPTION 'El ámbito es nacional o internacional'; END IF;
  IF _id IS NULL THEN
    INSERT INTO public.categorias_financieras (tipo, nombre, ambito, activo, es_prueba, orden)
    VALUES (_tipo::public.mov_tipo, btrim(_nombre), coalesce(_ambito, 'NACIONAL'), coalesce(_activo, true), v_prueba,
            (SELECT coalesce(max(orden), 0) + 1 FROM public.categorias_financieras WHERE tipo = _tipo::public.mov_tipo AND orden < 90))
    RETURNING id INTO v_id;
    INSERT INTO public.catalogo_bancos_bitacora (entidad, entidad_id, accion, despues, motivo, usuario_id)
    SELECT 'CATEGORIA', v_id, 'ALTA', to_jsonb(x), nullif(btrim(coalesce(_motivo, '')), ''), auth.uid() FROM public.categorias_financieras x WHERE x.id = v_id;
    RETURN v_id;
  END IF;
  SELECT * INTO c FROM public.categorias_financieras WHERE id = _id AND es_prueba = v_prueba FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe la categoría'; END IF;
  IF NOT c.captura THEN RAISE EXCEPTION 'La categoría «%» es del sistema (no se edita)', c.nombre; END IF;
  IF (btrim(_nombre) IS DISTINCT FROM c.nombre OR _tipo <> c.tipo::text) AND length(btrim(coalesce(_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'Cambiar el nombre o el tipo exige motivo (mínimo 5 caracteres). Los movimientos anteriores conservan el nombre con el que se capturaron.';
  END IF;
  IF c.activo AND NOT coalesce(_activo, c.activo) AND length(btrim(coalesce(_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'El motivo de la desactivación es obligatorio (mínimo 5 caracteres)';
  END IF;
  v_accion := CASE WHEN c.activo AND NOT coalesce(_activo, c.activo) THEN 'DESACTIVACION'
                   WHEN NOT c.activo AND coalesce(_activo, c.activo) THEN 'ACTIVACION' ELSE 'EDICION' END;
  UPDATE public.categorias_financieras SET nombre = btrim(_nombre), tipo = _tipo::public.mov_tipo,
         ambito = coalesce(_ambito, ambito), activo = coalesce(_activo, activo) WHERE id = c.id;
  INSERT INTO public.catalogo_bancos_bitacora (entidad, entidad_id, accion, antes, despues, motivo, usuario_id)
  SELECT 'CATEGORIA', c.id, v_accion, to_jsonb(c), to_jsonb(x), nullif(btrim(coalesce(_motivo, '')), ''), auth.uid() FROM public.categorias_financieras x WHERE x.id = c.id;
  RETURN c.id;
END;
$$;
DROP POLICY IF EXISTS categorias_write ON public.categorias_financieras;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.categorias_financieras FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.categoria_guardar(uuid, text, text, text, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.categoria_guardar(uuid, text, text, text, boolean, text) TO authenticated;

-- ── 5. Cuentas y empresas de PRUEBA (propias; no son datos reales) ─────────
INSERT INTO public.empresas_grupo (nombre, razon_social, es_prueba)
SELECT 'Empresa de prueba', 'EMPRESA DE PRUEBA SA DE CV', true WHERE NOT EXISTS (SELECT 1 FROM public.empresas_grupo WHERE es_prueba);
INSERT INTO public.cuentas_financieras (nombre, tipo, moneda, banco, ultimos4, saldo_inicial, activo, orden, empresa_id, es_prueba)
SELECT x.nombre, x.tipo::public.cuenta_tipo, x.moneda, x.banco, x.ult, 100000, true, x.orden, e.id, true
  FROM (VALUES ('Caja prueba MXN', 'EFECTIVO', 'MXN', NULL, NULL, 101), ('Caja prueba USD', 'EFECTIVO', 'USD', NULL, NULL, 102),
               ('Banco prueba MXN', 'BANCO', 'MXN', 'Banco de prueba', '0001', 103), ('Banco prueba USD', 'BANCO', 'USD', 'Banco de prueba', '0002', 104)) AS x(nombre, tipo, moneda, banco, ult, orden)
  CROSS JOIN (SELECT id FROM public.empresas_grupo WHERE es_prueba LIMIT 1) e
 WHERE NOT EXISTS (SELECT 1 FROM public.cuentas_financieras c WHERE c.es_prueba AND c.nombre = x.nombre);

-- ── 6. Perfiles de gastos: captura_gasto y confirma_gasto ──────────────────
ALTER TABLE public.flujo_capacidades
  ADD COLUMN IF NOT EXISTS captura_gasto boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS confirma_gasto boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.flujo_cap(_cap text, _uid uuid DEFAULT auth.uid())
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT _uid IS NOT NULL AND public.usuario_activo(_uid)
     AND coalesce((SELECT CASE _cap WHEN 'recibe' THEN c.recibe WHEN 'caja' THEN c.caja WHEN 'aplica' THEN c.aplica
                                    WHEN 'captura_gasto' THEN c.captura_gasto WHEN 'confirma_gasto' THEN c.confirma_gasto END
                     FROM public.flujo_capacidades c WHERE c.user_id = _uid), false)
$$;

-- ¿Tiene alguna etapa del flujo (ingresos o gastos)?
CREATE OR REPLACE FUNCTION public.flujo_alguna_etapa(_uid uuid DEFAULT auth.uid())
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.flujo_cap('recibe', _uid) OR public.flujo_cap('caja', _uid) OR public.flujo_cap('aplica', _uid)
      OR public.flujo_cap('captura_gasto', _uid) OR public.flujo_cap('confirma_gasto', _uid)
$$;
REVOKE ALL ON FUNCTION public.flujo_alguna_etapa(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_alguna_etapa(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.flujo_mis_capacidades()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT jsonb_build_object('recibe', public.flujo_cap('recibe'), 'caja', public.flujo_cap('caja'), 'aplica', public.flujo_cap('aplica'),
                            'captura_gasto', public.flujo_cap('captura_gasto'), 'confirma_gasto', public.flujo_cap('confirma_gasto'))
$$;

DROP FUNCTION IF EXISTS public.flujo_listar_capacidades();
CREATE OR REPLACE FUNCTION public.flujo_listar_capacidades()
RETURNS TABLE (user_id uuid, nombre text, recibe boolean, caja boolean, aplica boolean, captura_gasto boolean, confirma_gasto boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.flujo_es_admin() THEN RAISE EXCEPTION 'Sólo un administrador ve quién hace cada etapa'; END IF;
  RETURN QUERY
    SELECT p.id, coalesce(nullif(btrim(p.nombre_completo), ''), p.id::text),
           coalesce(c.recibe, false), coalesce(c.caja, false), coalesce(c.aplica, false),
           coalesce(c.captura_gasto, false), coalesce(c.confirma_gasto, false)
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
  IF _capacidad NOT IN ('recibe', 'caja', 'aplica', 'captura_gasto', 'confirma_gasto') THEN RAISE EXCEPTION 'Capacidad inválida: %', _capacidad; END IF;
  INSERT INTO public.flujo_capacidades (user_id) VALUES (_user_id) ON CONFLICT (user_id) DO NOTHING;
  EXECUTE format('UPDATE public.flujo_capacidades SET %I = $1, updated_by = $2, updated_at = now() WHERE user_id = $3', _capacidad)
    USING coalesce(_valor, false), auth.uid(), _user_id;
  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_asignar_capacidad', 'flujo_capacidades', NULL, NULL,
    jsonb_build_object('usuario', _user_id, 'capacidad', _capacidad, 'valor', _valor), public.es_usuario_prueba(auth.uid()));
END;
$$;

-- Lectura: quien tiene alguna etapa ve el flujo de su modalidad; Finanzas y administración, todo (de su modalidad).
DROP POLICY IF EXISTS flujo_dinero_leer ON public.flujo_dinero;
CREATE POLICY flujo_dinero_leer ON public.flujo_dinero FOR SELECT TO authenticated
  USING (es_prueba = public.es_usuario_prueba(auth.uid())
         AND (public.flujo_es_admin() OR public.es_finanzas(auth.uid()) OR public.flujo_alguna_etapa()));
DROP POLICY IF EXISTS empresas_grupo_leer ON public.empresas_grupo;
CREATE POLICY empresas_grupo_leer ON public.empresas_grupo FOR SELECT TO authenticated
  USING (public.es_finanzas(auth.uid()) OR public.flujo_es_admin() OR public.flujo_alguna_etapa());

-- ── 7. Flujo: columnas y etapas de gasto ───────────────────────────────────
ALTER TABLE public.flujo_dinero
  ADD COLUMN IF NOT EXISTS categoria          text,
  ADD COLUMN IF NOT EXISTS cuenta_propuesta_id uuid REFERENCES public.cuentas_financieras(id),
  ADD COLUMN IF NOT EXISTS autorizado_por     uuid REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS autorizado_at      timestamptz;

DO $checks$
DECLARE c record;
BEGIN
  FOR c IN SELECT conname FROM pg_constraint
            WHERE conrelid = 'public.flujo_dinero'::regclass AND contype = 'c' AND conname = 'flujo_etapa_con_reversa'
  LOOP
    EXECUTE format('ALTER TABLE public.flujo_dinero DROP CONSTRAINT %I', c.conname);
  END LOOP;
  ALTER TABLE public.flujo_dinero ADD CONSTRAINT flujo_etapa_con_reversa
    CHECK (etapa IN ('RECIBIDO', 'AUTORIZADO', 'EN_CAJA', 'APLICADO', 'RECHAZADO', 'REVERTIDO'));
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'flujo_gasto_categoria') THEN
    ALTER TABLE public.flujo_dinero ADD CONSTRAINT flujo_gasto_categoria
      CHECK (tipo <> 'SALIDA' OR nullif(btrim(coalesce(categoria, '')), '') IS NOT NULL);
  END IF;
END $checks$;

ALTER TABLE public.flujo_dinero_eventos DROP CONSTRAINT IF EXISTS flujo_dinero_eventos_accion_check;
ALTER TABLE public.flujo_dinero_eventos ADD CONSTRAINT flujo_dinero_eventos_accion_check
  CHECK (accion IN ('RECIBIDO', 'CAJA_CONFIRMADA', 'APLICADO', 'RECHAZADO', 'APLICACION_REVERTIDA', 'PAGO_REVERTIDO', 'LIBRO_CANCELADO',
                    'CLIENTE_CAMBIADO', 'GASTO_AUTORIZADO', 'GASTO_CORREGIDO'));

-- ── 8. Libro: origen REGULARIZACION, no suma en totales, conciliado, enlaces ─
ALTER TABLE public.movimientos_financieros
  ADD COLUMN IF NOT EXISTS afecta_totales       boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS conciliado           boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS conciliado_por       uuid REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS conciliado_at        timestamptz,
  ADD COLUMN IF NOT EXISTS regulariza_pago_id   uuid REFERENCES public.cobranza_pagos(id),
  ADD COLUMN IF NOT EXISTS reclasifica_mov_id   uuid REFERENCES public.movimientos_financieros(id),
  ADD COLUMN IF NOT EXISTS reclasificado_at     timestamptz,
  ADD COLUMN IF NOT EXISTS regularizacion_motivo text;
ALTER TABLE public.movimientos_financieros DROP CONSTRAINT IF EXISTS movimientos_origen_check;
ALTER TABLE public.movimientos_financieros ADD CONSTRAINT movimientos_origen_check
  CHECK (origen IN ('FLUJO', 'HISTORICO_DIRECTO', 'CONTRA_MOVIMIENTO', 'REGULARIZACION'));
CREATE UNIQUE INDEX IF NOT EXISTS ux_movimientos_regulariza_pago ON public.movimientos_financieros (regulariza_pago_id) WHERE regulariza_pago_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.libro_guardia()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF coalesce(current_setting('kit.libro_via_flujo', true), '') <> 'on' OR NEW.origen NOT IN ('FLUJO', 'CONTRA_MOVIMIENTO', 'REGULARIZACION') THEN
      RAISE EXCEPTION 'El libro solo recibe dinero cuando se confirma en el flujo de dinero (Flujo de dinero → Recibe / Gastos). No hay otra forma de registrar un movimiento.';
    END IF;
    RETURN NEW;
  END IF;
  IF TG_OP = 'DELETE' THEN
    IF coalesce(current_setting('kit.reiniciando_prueba', true), '') = 'si' THEN RETURN OLD; END IF;
    RAISE EXCEPTION 'En el libro nada se borra: el movimiento se cancela con motivo (administrador financiero).';
  END IF;
  IF coalesce(current_setting('kit.libro_admin', true), '') <> 'on'
     AND (NEW.tipo, NEW.monto, NEW.moneda, NEW.tipo_cambio, NEW.cuenta_id, NEW.fecha_movimiento, NEW.metodo_pago,
          NEW.origen, NEW.flujo_id, NEW.estatus, NEW.cliente_id, NEW.afecta_totales)
         IS DISTINCT FROM
         (OLD.tipo, OLD.monto, OLD.moneda, OLD.tipo_cambio, OLD.cuenta_id, OLD.fecha_movimiento, OLD.metodo_pago,
          OLD.origen, OLD.flujo_id, OLD.estatus, OLD.cliente_id, OLD.afecta_totales) THEN
    RAISE EXCEPTION 'Un movimiento del libro no se edita en monto, cuenta, fecha, método ni estatus: se cancela con motivo y el dinero se registra otra vez por el flujo.';
  END IF;
  RETURN NEW;
END;
$$;

-- Vista del libro: nuevas columnas al final.
DO $v$
DECLARE v_def text; v_inv boolean;
BEGIN
  v_def := pg_get_viewdef('public.v_movimientos_financieros'::regclass, true);
  IF v_def LIKE '%afecta_totales%' THEN RETURN; END IF;
  v_inv := coalesce((SELECT 'security_invoker=true' = ANY (reloptions) FROM pg_class WHERE oid = 'public.v_movimientos_financieros'::regclass), false);
  v_def := rtrim(v_def, E'; \n');
  IF position(E'\n   FROM movimientos_financieros m' IN v_def) = 0 THEN
    RAISE EXCEPTION 'La vista v_movimientos_financieros no tiene la forma esperada; no se modificó.';
  END IF;
  v_def := replace(v_def, E'\n   FROM movimientos_financieros m',
    E',\n    m.afecta_totales AS afecta_totales,\n    m.conciliado AS conciliado,\n    m.conciliado_at AS conciliado_at,\n    public.flujo_nombre(m.conciliado_por) AS conciliado_por_nombre,\n    m.regularizacion_motivo AS regularizacion_motivo\n   FROM movimientos_financieros m');
  EXECUTE 'CREATE OR REPLACE VIEW public.v_movimientos_financieros AS ' || v_def;
  IF v_inv THEN EXECUTE 'ALTER VIEW public.v_movimientos_financieros SET (security_invoker = true)'; END IF;
END $v$;

-- Saldos por cuenta: cada quien ve las de su modalidad (real o prueba).
CREATE OR REPLACE VIEW public.v_saldos_cuentas AS
SELECT c.id, c.nombre, c.tipo, c.moneda, c.activo, c.orden, c.saldo_inicial,
       COALESCE(sum(CASE WHEN m.tipo = 'INGRESO' THEN m.monto END), 0::numeric) AS total_ingresos,
       COALESCE(sum(CASE WHEN m.tipo = 'EGRESO' THEN m.monto END), 0::numeric) AS total_egresos,
       c.saldo_inicial + COALESCE(sum(CASE WHEN m.tipo = 'INGRESO' THEN m.monto ELSE -m.monto END), 0::numeric) AS saldo_actual,
       c.empresa_id, e.nombre AS empresa_nombre, c.banco, c.ultimos4, c.es_prueba
  FROM public.cuentas_financieras c
  LEFT JOIN public.empresas_grupo e ON e.id = c.empresa_id
  LEFT JOIN public.movimientos_financieros m ON m.cuenta_id = c.id AND m.estatus = 'CONFIRMADO'
 WHERE c.es_prueba = public.es_usuario_prueba(auth.uid())
 GROUP BY c.id, e.nombre;
ALTER VIEW public.v_saldos_cuentas SET (security_invoker = true);

-- ── 9. Saldo de una cuenta (real: libro confirmado; prueba: flujo de prueba) ─
CREATE OR REPLACE FUNCTION public._cuenta_saldo(_cuenta uuid)
RETURNS numeric LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE c public.cuentas_financieras%ROWTYPE; v numeric;
BEGIN
  SELECT * INTO c FROM public.cuentas_financieras WHERE id = _cuenta;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF NOT c.es_prueba THEN
    SELECT c.saldo_inicial + coalesce(sum(CASE WHEN m.tipo = 'INGRESO' THEN m.monto ELSE -m.monto END), 0) INTO v
      FROM public.movimientos_financieros m WHERE m.cuenta_id = c.id AND m.estatus = 'CONFIRMADO';
  ELSE
    -- Una cuenta de prueba no escribe en el libro real: su saldo sale de los flujos de prueba.
    SELECT c.saldo_inicial + coalesce(sum(CASE WHEN f.tipo = 'SALIDA' THEN -f.monto ELSE f.monto END), 0) INTO v
      FROM public.flujo_dinero f WHERE f.cuenta_id = c.id AND f.es_prueba
       AND ((f.tipo = 'SALIDA' AND f.etapa = 'APLICADO') OR (f.tipo <> 'SALIDA' AND f.etapa IN ('EN_CAJA', 'APLICADO')));
  END IF;
  RETURN v;
END;
$$;
REVOKE ALL ON FUNCTION public._cuenta_saldo(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.flujo_saldo_cuenta(_cuenta_id uuid)
RETURNS numeric LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT (public.flujo_es_admin() OR public.flujo_cap('captura_gasto') OR public.flujo_cap('confirma_gasto') OR public.flujo_cap('caja')) THEN
    RAISE EXCEPTION 'No tienes asignada ninguna etapa que consulte saldos';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.cuentas_financieras WHERE id = _cuenta_id AND es_prueba = public.es_usuario_prueba(auth.uid())) THEN
    RAISE EXCEPTION 'No existe la cuenta';
  END IF;
  RETURN public._cuenta_saldo(_cuenta_id);
END;
$$;

-- Reglas de la cuenta para un movimiento: activa, de la modalidad, empresa, moneda y método (mensajes en español y chino).
CREATE OR REPLACE FUNCTION public._cuenta_valida_para(_cuenta uuid, _prueba boolean, _empresa uuid, _moneda text, _metodo text)
RETURNS public.cuentas_financieras LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE c public.cuentas_financieras%ROWTYPE;
BEGIN
  SELECT * INTO c FROM public.cuentas_financieras WHERE id = _cuenta AND activo AND es_prueba = _prueba;
  IF NOT FOUND THEN RAISE EXCEPTION 'Elige una caja o cuenta válida y activa'; END IF;
  IF c.moneda <> _moneda THEN RAISE EXCEPTION '«%» maneja % y el movimiento está en %', c.nombre, c.moneda, _moneda; END IF;
  IF _empresa IS NOT NULL AND c.empresa_id IS DISTINCT FROM _empresa THEN
    RAISE EXCEPTION 'La cuenta «%» es de %; este movimiento es de %. Elige una cuenta de esa empresa.',
      c.nombre, coalesce((SELECT nombre FROM public.empresas_grupo WHERE id = c.empresa_id), 'ninguna empresa'),
      (SELECT nombre FROM public.empresas_grupo WHERE id = _empresa);
  END IF;
  IF _metodo = 'EFECTIVO' AND c.tipo <> 'EFECTIVO' THEN
    RAISE EXCEPTION 'El efectivo solo se registra en una caja de efectivo; «%» es una cuenta de banco. / 现金只能登记在现金账户；“%”是银行账户。', c.nombre, c.nombre;
  END IF;
  IF _metodo IN ('TRANSFERENCIA', 'DEPOSITO') AND c.tipo <> 'BANCO' THEN
    RAISE EXCEPTION 'La transferencia y el depósito solo se registran en una cuenta de banco; «%» es una caja de efectivo. / 转账和存款只能登记在银行账户；“%”是现金账户。', c.nombre, c.nombre;
  END IF;
  RETURN c;
END;
$$;
REVOKE ALL ON FUNCTION public._cuenta_valida_para(uuid, boolean, uuid, text, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exigir_saldo(_cuenta uuid, _monto numeric)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v numeric := public._cuenta_saldo(_cuenta); c public.cuentas_financieras%ROWTYPE;
BEGIN
  IF v < _monto THEN
    SELECT * INTO c FROM public.cuentas_financieras WHERE id = _cuenta;
    RAISE EXCEPTION 'Saldo insuficiente en «%»: tiene % % y el gasto es de % (faltan %). No se puede confirmar. / 账户“%”余额不足。',
      c.nombre, to_char(v, 'FM999,999,990.00'), c.moneda, to_char(_monto, 'FM999,999,990.00'), to_char(_monto - v, 'FM999,999,990.00'), c.nombre;
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public._exigir_saldo(uuid, numeric) FROM PUBLIC, anon, authenticated;

-- Validación común del gasto (captura y corrección).
CREATE OR REPLACE FUNCTION public._gasto_validar(_prueba boolean, _monto numeric, _moneda text, _metodo text, _tc numeric, _referencia text,
  _evidencia text, _concepto text, _beneficiario text, _categoria text, _empresa uuid, _cuenta uuid)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE cat public.categorias_financieras%ROWTYPE;
BEGIN
  IF _monto IS NULL OR _monto <= 0 THEN RAISE EXCEPTION 'El monto debe ser mayor a cero'; END IF;
  IF NOT public.moneda_permitida(_moneda) THEN RAISE EXCEPTION 'La moneda % no está permitida', _moneda; END IF;
  IF _moneda <> 'MXN' AND (_tc IS NULL OR _tc <= 0) THEN RAISE EXCEPTION 'Captura el tipo de cambio de % a MXN', _moneda; END IF;
  IF nullif(btrim(coalesce(_beneficiario, '')), '') IS NULL THEN RAISE EXCEPTION 'Indica el proveedor o beneficiario'; END IF;
  IF nullif(btrim(coalesce(_concepto, '')), '') IS NULL THEN RAISE EXCEPTION 'El concepto es obligatorio'; END IF;
  IF nullif(btrim(coalesce(_evidencia, '')), '') IS NULL OR length(btrim(_evidencia)) < 3 THEN
    RAISE EXCEPTION 'Adjunta la evidencia del gasto: factura o comprobante. Sin evidencia no se registra.';
  END IF;
  IF _metodo <> 'EFECTIVO' AND nullif(btrim(coalesce(_referencia, '')), '') IS NULL THEN RAISE EXCEPTION 'Captura la referencia o folio del movimiento'; END IF;
  SELECT * INTO cat FROM public.categorias_financieras
   WHERE tipo = 'EGRESO' AND lower(btrim(nombre)) = lower(btrim(coalesce(_categoria, ''))) AND es_prueba = _prueba AND activo AND captura;
  IF NOT FOUND THEN RAISE EXCEPTION 'Elige una categoría de egreso activa'; END IF;
  IF cat.ambito = 'INTERNACIONAL' AND _moneda = 'MXN' THEN
    RAISE EXCEPTION 'La categoría «%» es internacional: opera en USD u otra moneda distinta de MXN, con una cuenta en esa moneda.', cat.nombre;
  END IF;
  IF EXISTS (SELECT 1 FROM public.empresas_grupo WHERE activo AND es_prueba = _prueba) THEN
    IF _empresa IS NULL THEN RAISE EXCEPTION 'Elige la empresa del grupo de la que sale el dinero'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.empresas_grupo WHERE id = _empresa AND activo AND es_prueba = _prueba) THEN
      RAISE EXCEPTION 'La empresa elegida no existe o está desactivada';
    END IF;
  END IF;
  PERFORM public._cuenta_valida_para(_cuenta, _prueba, _empresa, _moneda, _metodo);
END;
$$;
REVOKE ALL ON FUNCTION public._gasto_validar(boolean, numeric, text, text, numeric, text, text, text, text, text, uuid, uuid) FROM PUBLIC, anon, authenticated;

-- Libro: inserta el movimiento confirmado de un flujo (un solo lugar; lo usan Caja y los gastos).
CREATE OR REPLACE FUNCTION public._flujo_libro_insertar(f public.flujo_dinero, c public.cuentas_financieras)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE d jsonb; v_mov uuid;
BEGIN
  IF f.es_prueba THEN RETURN NULL; END IF;   -- un flujo de PRUEBA no escribe en el libro real
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
  RETURN v_mov;
END;
$$;
REVOKE ALL ON FUNCTION public._flujo_libro_insertar(public.flujo_dinero, public.cuentas_financieras) FROM PUBLIC, anon, authenticated;

-- ── 10. Gastos ─────────────────────────────────────────────────────────────
-- Cuentas que quien captura puede proponer: de la empresa, del tipo que pide el método y de la moneda.
CREATE OR REPLACE FUNCTION public.flujo_cuentas_gasto(_empresa_id uuid, _metodo text, _moneda text)
RETURNS TABLE (id uuid, nombre text, tipo text, moneda text, orden integer, banco text, ultimos4 text, empresa_id uuid, empresa_nombre text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT (public.flujo_cap('captura_gasto') OR public.flujo_cap('confirma_gasto') OR public.flujo_es_admin()) THEN
    RAISE EXCEPTION 'No tienes asignada la captura ni la confirmación de gastos';
  END IF;
  RETURN QUERY
    SELECT c.id, c.nombre, c.tipo::text, c.moneda, c.orden, c.banco, c.ultimos4, c.empresa_id, e.nombre
      FROM public.cuentas_financieras c LEFT JOIN public.empresas_grupo e ON e.id = c.empresa_id
     WHERE c.activo AND c.es_prueba = public.es_usuario_prueba(auth.uid())
       AND (_moneda IS NULL OR c.moneda = _moneda)
       AND (_empresa_id IS NULL OR c.empresa_id = _empresa_id)
       AND (CASE WHEN _metodo = 'EFECTIVO' THEN c.tipo = 'EFECTIVO'
                 WHEN _metodo IN ('TRANSFERENCIA', 'DEPOSITO') THEN c.tipo = 'BANCO' ELSE true END)
     ORDER BY e.nombre NULLS LAST, c.orden, c.nombre;
END;
$$;

CREATE OR REPLACE FUNCTION public.flujo_categorias_gasto()
RETURNS TABLE (id uuid, nombre text, ambito text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT (public.flujo_cap('captura_gasto') OR public.flujo_cap('confirma_gasto') OR public.flujo_es_admin()) THEN
    RAISE EXCEPTION 'No tienes asignada la captura ni la confirmación de gastos';
  END IF;
  RETURN QUERY SELECT c.id, c.nombre, c.ambito FROM public.categorias_financieras c
   WHERE c.tipo = 'EGRESO' AND c.activo AND c.captura AND c.es_prueba = public.es_usuario_prueba(auth.uid()) ORDER BY c.orden, c.nombre;
END;
$$;

CREATE OR REPLACE FUNCTION public.flujo_capturar_gasto(
  _monto numeric, _moneda text, _metodo_pago text, _fecha date, _beneficiario text, _categoria text, _concepto text,
  _referencia text, _tipo_cambio numeric, _evidencia_path text, _empresa_id uuid, _cuenta_id uuid, _datos jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_prueba boolean := public.es_usuario_prueba(auth.uid());
  v_id uuid; v_folio text; v_extra text[]; v_datos jsonb := coalesce(_datos, '{}'::jsonb);
  v_permitidos text[] := ARRAY['descripcion', 'proveedor_id', 'empleado_id', 'contraparte_tipo', 'requiere_comprobacion',
    'factura_folio', 'factura_uuid', 'factura_rfc', 'oportunidad_id', 'contenedor_id'];
BEGIN
  IF NOT public.flujo_cap('captura_gasto') THEN RAISE EXCEPTION 'No tienes asignada la captura de gastos'; END IF;
  SELECT array_agg(k) INTO v_extra FROM jsonb_object_keys(v_datos) k WHERE k <> ALL (v_permitidos);
  IF v_extra IS NOT NULL THEN RAISE EXCEPTION 'Datos no permitidos en el gasto: %', array_to_string(v_extra, ', '); END IF;
  PERFORM public._gasto_validar(v_prueba, _monto, coalesce(_moneda, 'MXN'), _metodo_pago, _tipo_cambio, _referencia, _evidencia_path,
                                _concepto, _beneficiario, _categoria, _empresa_id, _cuenta_id);
  IF _metodo_pago = 'EFECTIVO' AND NOT (v_datos ? 'requiere_comprobacion') THEN
    v_datos := v_datos || jsonb_build_object('requiere_comprobacion', true);   -- el efectivo se comprueba después
  END IF;
  INSERT INTO public.flujo_dinero (tipo, monto, moneda, tipo_cambio, metodo_pago, fecha, contraparte_nombre, concepto, referencia, es_prueba,
                                   recibido_por, evidencia_path, evidencia_tipo, datos_libro, empresa_id, categoria, cuenta_propuesta_id)
  VALUES ('SALIDA', round(_monto, 2), coalesce(_moneda, 'MXN'), CASE WHEN coalesce(_moneda, 'MXN') = 'MXN' THEN NULL ELSE _tipo_cambio END,
          _metodo_pago::public.metodo_pago, _fecha, btrim(_beneficiario), btrim(_concepto), nullif(btrim(coalesce(_referencia, '')), ''),
          v_prueba, auth.uid(), btrim(_evidencia_path),
          CASE _metodo_pago WHEN 'EFECTIVO' THEN 'vale_efectivo' WHEN 'TRANSFERENCIA' THEN 'transferencia' WHEN 'DEPOSITO' THEN 'deposito' ELSE 'otro' END,
          v_datos || jsonb_build_object('categoria', btrim(_categoria)), _empresa_id, btrim(_categoria), _cuenta_id)
  RETURNING id, folio INTO v_id, v_folio;
  PERFORM public._flujo_evento(v_id, 'RECIBIDO', NULL, 'RECIBIDO', NULL, jsonb_build_object('tipo', 'SALIDA', 'monto', _monto, 'categoria', _categoria));
  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_capturar_gasto', 'flujo_dinero', v_id, v_folio,
    jsonb_build_object('monto', _monto, 'moneda', _moneda, 'categoria', _categoria), v_prueba);
  RETURN jsonb_build_object('id', v_id, 'folio', v_folio);
END;
$$;

-- Quien capturó corrige un gasto rechazado y lo reenvía a confirmación.
CREATE OR REPLACE FUNCTION public.flujo_corregir_gasto(_id uuid, _cambios jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  f public.flujo_dinero%ROWTYPE; n public.flujo_dinero%ROWTYPE;
  v_permitidos text[] := ARRAY['monto', 'moneda', 'tipo_cambio', 'metodo_pago', 'fecha', 'beneficiario', 'categoria', 'concepto', 'referencia',
    'evidencia_path', 'empresa_id', 'cuenta_id'];
  v_extra text[];
BEGIN
  IF NOT public.flujo_cap('captura_gasto') THEN RAISE EXCEPTION 'No tienes asignada la captura de gastos'; END IF;
  SELECT * INTO f FROM public.flujo_dinero WHERE id = _id FOR UPDATE;
  IF NOT FOUND OR f.tipo <> 'SALIDA' THEN RAISE EXCEPTION 'No existe el gasto'; END IF;
  PERFORM public.exigir_dato_prueba(f.es_prueba, 'el gasto ' || f.folio);
  IF f.recibido_por <> auth.uid() THEN RAISE EXCEPTION 'Solo quien capturó el gasto lo corrige'; END IF;
  IF f.etapa <> 'RECHAZADO' THEN RAISE EXCEPTION '% no está rechazado (etapa: %): solo se corrige lo rechazado', f.folio, f.etapa; END IF;
  SELECT array_agg(k) INTO v_extra FROM jsonb_object_keys(coalesce(_cambios, '{}'::jsonb)) k WHERE k <> ALL (v_permitidos);
  IF v_extra IS NOT NULL THEN RAISE EXCEPTION 'No se corrige: %', array_to_string(v_extra, ', '); END IF;
  n := f;
  IF _cambios ? 'monto' THEN n.monto := round((_cambios->>'monto')::numeric, 2); END IF;
  IF _cambios ? 'moneda' THEN n.moneda := _cambios->>'moneda'; END IF;
  IF _cambios ? 'tipo_cambio' THEN n.tipo_cambio := nullif(_cambios->>'tipo_cambio', '')::numeric; END IF;
  IF _cambios ? 'metodo_pago' THEN n.metodo_pago := (_cambios->>'metodo_pago')::public.metodo_pago; END IF;
  IF _cambios ? 'fecha' THEN n.fecha := (_cambios->>'fecha')::date; END IF;
  IF _cambios ? 'beneficiario' THEN n.contraparte_nombre := btrim(_cambios->>'beneficiario'); END IF;
  IF _cambios ? 'categoria' THEN n.categoria := btrim(_cambios->>'categoria'); END IF;
  IF _cambios ? 'concepto' THEN n.concepto := btrim(_cambios->>'concepto'); END IF;
  IF _cambios ? 'referencia' THEN n.referencia := nullif(btrim(_cambios->>'referencia'), ''); END IF;
  IF _cambios ? 'evidencia_path' THEN n.evidencia_path := btrim(_cambios->>'evidencia_path'); END IF;
  IF _cambios ? 'empresa_id' THEN n.empresa_id := nullif(_cambios->>'empresa_id', '')::uuid; END IF;
  IF _cambios ? 'cuenta_id' THEN n.cuenta_propuesta_id := nullif(_cambios->>'cuenta_id', '')::uuid; END IF;
  IF n.moneda = 'MXN' THEN n.tipo_cambio := NULL; END IF;
  PERFORM public._gasto_validar(n.es_prueba, n.monto, n.moneda, n.metodo_pago::text, n.tipo_cambio, n.referencia, n.evidencia_path,
                                n.concepto, n.contraparte_nombre, n.categoria, n.empresa_id, n.cuenta_propuesta_id);
  UPDATE public.flujo_dinero
     SET monto = n.monto, moneda = n.moneda, tipo_cambio = n.tipo_cambio, metodo_pago = n.metodo_pago, fecha = n.fecha,
         contraparte_nombre = n.contraparte_nombre, categoria = n.categoria, concepto = n.concepto, referencia = n.referencia,
         evidencia_path = n.evidencia_path, empresa_id = n.empresa_id, cuenta_propuesta_id = n.cuenta_propuesta_id,
         evidencia_tipo = CASE n.metodo_pago::text WHEN 'EFECTIVO' THEN 'vale_efectivo' WHEN 'TRANSFERENCIA' THEN 'transferencia' WHEN 'DEPOSITO' THEN 'deposito' ELSE 'otro' END,
         datos_libro = datos_libro || jsonb_build_object('categoria', n.categoria),
         etapa = 'RECIBIDO', motivo_rechazo = NULL, rechazado_por = NULL, rechazado_at = NULL
   WHERE id = f.id;
  PERFORM public._flujo_evento(f.id, 'GASTO_CORREGIDO', 'RECHAZADO', 'RECIBIDO', NULL, jsonb_build_object('motivo_rechazo_anterior', f.motivo_rechazo));
  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_corregir_gasto', 'flujo_dinero', f.id, f.folio, _cambios, f.es_prueba);
END;
$$;

-- Luna confirma. Efectivo: autoriza y queda por entregar (Leti). Banco: confirma y entra al libro.
CREATE OR REPLACE FUNCTION public.flujo_confirmar_gasto(_id uuid, _cuenta_id uuid DEFAULT NULL, _notas text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE f public.flujo_dinero%ROWTYPE; c public.cuentas_financieras%ROWTYPE; v_mov uuid;
BEGIN
  IF NOT public.flujo_cap('confirma_gasto') THEN RAISE EXCEPTION 'No tienes asignada la confirmación de gastos'; END IF;
  SELECT * INTO f FROM public.flujo_dinero WHERE id = _id FOR UPDATE;
  IF NOT FOUND OR f.tipo <> 'SALIDA' THEN RAISE EXCEPTION 'No existe el gasto'; END IF;
  PERFORM public.exigir_dato_prueba(f.es_prueba, 'el gasto ' || f.folio);
  IF f.etapa <> 'RECIBIDO' THEN RAISE EXCEPTION '% no está por confirmar (etapa: %)', f.folio, f.etapa; END IF;
  IF f.recibido_por = auth.uid() THEN RAISE EXCEPTION 'Quien capturó el gasto no lo confirma: lo hace otra persona'; END IF;
  c := public._cuenta_valida_para(coalesce(_cuenta_id, f.cuenta_propuesta_id), f.es_prueba, f.empresa_id, f.moneda, f.metodo_pago::text);
  PERFORM public._exigir_saldo(c.id, f.monto);
  IF f.metodo_pago = 'EFECTIVO' THEN
    UPDATE public.flujo_dinero SET etapa = 'AUTORIZADO', autorizado_por = auth.uid(), autorizado_at = now(), cuenta_propuesta_id = c.id,
           caja_notas = nullif(btrim(coalesce(_notas, '')), '') WHERE id = f.id;
    PERFORM public._flujo_evento(f.id, 'GASTO_AUTORIZADO', 'RECIBIDO', 'AUTORIZADO', _notas, jsonb_build_object('cuenta', c.nombre));
    PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_autorizar_gasto', 'flujo_dinero', f.id, f.folio, jsonb_build_object('cuenta', c.nombre), f.es_prueba);
    RETURN jsonb_build_object('etapa', 'AUTORIZADO', 'movimiento_id', NULL);
  END IF;
  v_mov := public._flujo_libro_insertar(f, c);
  UPDATE public.flujo_dinero SET etapa = 'APLICADO', cuenta_id = c.id, caja_por = auth.uid(), caja_at = now(), destino = 'GASTO',
         aplicado_por = auth.uid(), aplicado_at = now(), movimiento_id = v_mov, caja_notas = nullif(btrim(coalesce(_notas, '')), '') WHERE id = f.id;
  PERFORM public._flujo_evento(f.id, 'CAJA_CONFIRMADA', 'RECIBIDO', 'APLICADO', _notas, jsonb_build_object('cuenta', c.nombre, 'movimiento_id', v_mov));
  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_confirmar_gasto', 'flujo_dinero', f.id, f.folio,
    jsonb_build_object('cuenta', c.nombre, 'movimiento_id', v_mov), f.es_prueba);
  RETURN jsonb_build_object('etapa', 'APLICADO', 'movimiento_id', v_mov);
END;
$$;

-- Leti registra la entrega del efectivo: el libro se mueve aquí.
CREATE OR REPLACE FUNCTION public.flujo_entregar_gasto(_id uuid, _notas text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE f public.flujo_dinero%ROWTYPE; c public.cuentas_financieras%ROWTYPE; v_mov uuid;
BEGIN
  IF NOT public.flujo_cap('caja') THEN RAISE EXCEPTION 'No tienes asignada la etapa de caja'; END IF;
  SELECT * INTO f FROM public.flujo_dinero WHERE id = _id FOR UPDATE;
  IF NOT FOUND OR f.tipo <> 'SALIDA' THEN RAISE EXCEPTION 'No existe el gasto'; END IF;
  PERFORM public.exigir_dato_prueba(f.es_prueba, 'el gasto ' || f.folio);
  IF f.etapa <> 'AUTORIZADO' THEN RAISE EXCEPTION '% no está por entregar (etapa: %)', f.folio, f.etapa; END IF;
  IF auth.uid() IN (f.recibido_por, f.autorizado_por) THEN
    RAISE EXCEPTION 'Quien capturó o autorizó el gasto no registra su entrega: lo hace la persona de caja';
  END IF;
  c := public._cuenta_valida_para(f.cuenta_propuesta_id, f.es_prueba, f.empresa_id, f.moneda, f.metodo_pago::text);
  PERFORM public._exigir_saldo(c.id, f.monto);
  v_mov := public._flujo_libro_insertar(f, c);
  UPDATE public.flujo_dinero SET etapa = 'APLICADO', cuenta_id = c.id, caja_por = auth.uid(), caja_at = now(), destino = 'GASTO',
         aplicado_por = auth.uid(), aplicado_at = now(), movimiento_id = v_mov, caja_notas = coalesce(nullif(btrim(coalesce(_notas, '')), ''), caja_notas) WHERE id = f.id;
  PERFORM public._flujo_evento(f.id, 'CAJA_CONFIRMADA', 'AUTORIZADO', 'APLICADO', _notas, jsonb_build_object('cuenta', c.nombre, 'movimiento_id', v_mov, 'entrega', true));
  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_entregar_gasto', 'flujo_dinero', f.id, f.folio,
    jsonb_build_object('cuenta', c.nombre, 'movimiento_id', v_mov), f.es_prueba);
  RETURN v_mov;
END;
$$;

CREATE OR REPLACE FUNCTION public.flujo_rechazar_gasto(_id uuid, _motivo text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE f public.flujo_dinero%ROWTYPE;
BEGIN
  IF length(btrim(coalesce(_motivo, ''))) < 3 THEN RAISE EXCEPTION 'El motivo del rechazo es obligatorio'; END IF;
  SELECT * INTO f FROM public.flujo_dinero WHERE id = _id FOR UPDATE;
  IF NOT FOUND OR f.tipo <> 'SALIDA' THEN RAISE EXCEPTION 'No existe el gasto'; END IF;
  PERFORM public.exigir_dato_prueba(f.es_prueba, 'el gasto ' || f.folio);
  IF NOT ((f.etapa = 'RECIBIDO' AND public.flujo_cap('confirma_gasto'))
       OR (f.etapa = 'AUTORIZADO' AND (public.flujo_cap('caja') OR public.flujo_cap('confirma_gasto')))) THEN
    RAISE EXCEPTION 'No puedes rechazar este gasto (etapa: %)', f.etapa;
  END IF;
  IF f.recibido_por = auth.uid() THEN RAISE EXCEPTION 'Quien capturó el gasto no lo rechaza: lo cancela con otra persona o lo corrige'; END IF;
  UPDATE public.flujo_dinero SET etapa = 'RECHAZADO', motivo_rechazo = btrim(_motivo), rechazado_por = auth.uid(), rechazado_at = now() WHERE id = f.id;
  PERFORM public._flujo_evento(f.id, 'RECHAZADO', f.etapa, 'RECHAZADO', _motivo, '{}'::jsonb);
  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_rechazar_gasto', 'flujo_dinero', f.id, f.folio, jsonb_build_object('motivo', _motivo, 'etapa', f.etapa), f.es_prueba);
END;
$$;

-- ── 11. Regla para toda persona: no cancela ni ajusta lo que capturó o confirmó ─
CREATE OR REPLACE FUNCTION public._libro_no_es_mio(_mov public.movimientos_financieros)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE f public.flujo_dinero%ROWTYPE;
BEGIN
  IF auth.uid() IN (_mov.created_by, _mov.confirmado_por) THEN
    RAISE EXCEPTION 'No se cancela ni se ajusta un movimiento que tú capturaste o confirmaste: lo hace otro administrador financiero.';
  END IF;
  IF _mov.flujo_id IS NOT NULL THEN
    SELECT * INTO f FROM public.flujo_dinero WHERE id = _mov.flujo_id;
    IF auth.uid() IN (f.recibido_por, f.caja_por, f.autorizado_por, f.aplicado_por) THEN
      RAISE EXCEPTION 'No se cancela ni se ajusta un movimiento en cuyo flujo (%) participaste: lo hace otro administrador financiero.', f.folio;
    END IF;
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public._libro_no_es_mio(public.movimientos_financieros) FROM PUBLIC, anon, authenticated;

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
  PERFORM public._libro_no_es_mio(m);
  IF m.flujo_id IS NOT NULL THEN
    SELECT * INTO f FROM public.flujo_dinero WHERE id = m.flujo_id FOR UPDATE;
    IF f.etapa = 'APLICADO' AND f.tipo <> 'SALIDA' THEN
      RAISE EXCEPTION '% ya está aplicado (%): revierte primero lo aplicado en Cobranza o en el flujo', m.folio, f.folio;
    END IF;
  END IF;
  PERFORM set_config('kit.libro_admin', 'on', true);
  UPDATE public.movimientos_financieros
     SET estatus = 'CANCELADO', cancelado_por = auth.uid(), cancelado_at = now(), motivo_cancelacion = btrim(_motivo)
   WHERE id = m.id;
  PERFORM set_config('kit.libro_admin', 'off', true);
  IF m.flujo_id IS NOT NULL AND (f.etapa = 'EN_CAJA' OR (f.tipo = 'SALIDA' AND f.etapa = 'APLICADO')) THEN
    UPDATE public.flujo_dinero SET etapa = 'REVERTIDO', reversa_motivo = btrim(_motivo), revertido_por = auth.uid(), revertido_at = now() WHERE id = f.id;
    PERFORM public._flujo_evento(f.id, 'LIBRO_CANCELADO', f.etapa, 'REVERTIDO', _motivo, jsonb_build_object('movimiento_id', m.id));
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
  PERFORM public._libro_no_es_mio(m);
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
  IF _tipo = 'SALIDA' THEN RAISE EXCEPTION 'Los gastos y salidas se capturan en la pestaña Gastos (perfil de captura de gastos).'; END IF;
  IF NOT public.moneda_permitida(coalesce(_moneda, 'MXN')) THEN RAISE EXCEPTION 'La moneda % no está permitida', _moneda; END IF;
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
  IF EXISTS (SELECT 1 FROM public.empresas_grupo WHERE activo AND es_prueba = public.es_usuario_prueba(auth.uid())) THEN
    IF _empresa_id IS NULL THEN RAISE EXCEPTION 'Elige la empresa del grupo que recibe el dinero'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.empresas_grupo WHERE id = _empresa_id AND activo AND es_prueba = public.es_usuario_prueba(auth.uid())) THEN RAISE EXCEPTION 'La empresa elegida no existe o está desactivada'; END IF;
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
  IF f.tipo = 'SALIDA' THEN RAISE EXCEPTION '% es un gasto: lo confirma quien tiene la confirmación de gastos (y, si es efectivo, Caja registra la entrega)', f.folio; END IF;
  IF f.etapa <> 'RECIBIDO' THEN RAISE EXCEPTION '% no está pendiente de caja (etapa: %)', f.folio, f.etapa; END IF;
  IF f.recibido_por = auth.uid() THEN
    RAISE EXCEPTION 'Quien recibió el dinero no puede registrarlo en caja: lo hace otra persona';
  END IF;
  SELECT * INTO c FROM public.cuentas_financieras WHERE id = _cuenta_id AND activo AND es_prueba = f.es_prueba;
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
  IF f.tipo = 'SALIDA' THEN RAISE EXCEPTION '% es un gasto: no se aplica, se confirma', f.folio; END IF;
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
  IF f.tipo = 'SALIDA' THEN RAISE EXCEPTION '% es un gasto: se rechaza desde la confirmación de gastos', f.folio; END IF;
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
CREATE OR REPLACE FUNCTION public.flujo_empresas()
RETURNS TABLE (id uuid, nombre text, razon_social text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT (public.flujo_es_admin() OR public.es_finanzas(auth.uid()) OR public.flujo_alguna_etapa()) THEN
    RAISE EXCEPTION 'No tienes asignada ninguna etapa del flujo de dinero';
  END IF;
  RETURN QUERY SELECT e.id, e.nombre, e.razon_social FROM public.empresas_grupo e
   WHERE e.activo AND e.es_prueba = public.es_usuario_prueba(auth.uid()) ORDER BY e.nombre;
END;
$$;

DROP FUNCTION IF EXISTS public.flujo_cuentas(uuid);
CREATE OR REPLACE FUNCTION public.flujo_cuentas(_flujo_id uuid DEFAULT NULL)
RETURNS TABLE (id uuid, nombre text, tipo text, moneda text, orden integer, banco text, ultimos4 text, empresa_id uuid, empresa_nombre text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE f public.flujo_dinero%ROWTYPE; v_prueba boolean := public.es_usuario_prueba(auth.uid());
BEGIN
  IF NOT (public.flujo_cap('caja') OR public.flujo_cap('confirma_gasto') OR public.flujo_es_admin()) THEN
    RAISE EXCEPTION 'No tienes asignada la etapa de caja ni la confirmación de gastos';
  END IF;
  IF _flujo_id IS NOT NULL THEN
    SELECT * INTO f FROM public.flujo_dinero WHERE flujo_dinero.id = _flujo_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'No existe el movimiento'; END IF;
    v_prueba := f.es_prueba;
  END IF;
  RETURN QUERY
    SELECT c.id, c.nombre, c.tipo::text, c.moneda, c.orden, c.banco, c.ultimos4, c.empresa_id, e.nombre
      FROM public.cuentas_financieras c LEFT JOIN public.empresas_grupo e ON e.id = c.empresa_id
     WHERE c.activo AND c.es_prueba = v_prueba
       AND (_flujo_id IS NULL OR (
             c.moneda = f.moneda
         AND (f.empresa_id IS NULL OR c.empresa_id = f.empresa_id)
         AND (CASE WHEN f.metodo_pago = 'EFECTIVO' THEN c.tipo = 'EFECTIVO'
                   WHEN f.metodo_pago IN ('TRANSFERENCIA', 'DEPOSITO') THEN c.tipo = 'BANCO' ELSE true END)))
     ORDER BY e.nombre NULLS LAST, c.orden, c.nombre;
END;
$$;

CREATE OR REPLACE FUNCTION public.empresa_guardar(_id uuid, _nombre text, _razon_social text, _activo boolean DEFAULT true, _motivo text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE e public.empresas_grupo%ROWTYPE; v_id uuid; v_accion text; v_prueba boolean := public.es_usuario_prueba(auth.uid());
BEGIN
  IF NOT (public.es_finanzas_admin(auth.uid()) AND public.usuario_activo(auth.uid())) THEN
    RAISE EXCEPTION 'Sólo el administrador financiero o un administrador da de alta y edita empresas';
  END IF;
  IF length(btrim(coalesce(_nombre, ''))) < 2 THEN RAISE EXCEPTION 'El nombre de la empresa es obligatorio'; END IF;
  IF length(btrim(coalesce(_razon_social, ''))) < 2 THEN RAISE EXCEPTION 'La razón social es obligatoria'; END IF;
  IF _id IS NULL THEN
    INSERT INTO public.empresas_grupo (nombre, razon_social, activo, created_by, updated_by, es_prueba)
    VALUES (btrim(_nombre), btrim(_razon_social), coalesce(_activo, true), auth.uid(), auth.uid(), v_prueba) RETURNING id INTO v_id;
    INSERT INTO public.catalogo_bancos_bitacora (entidad, entidad_id, accion, despues, motivo, usuario_id)
    SELECT 'EMPRESA', v_id, 'ALTA', to_jsonb(x) - 'created_at' - 'updated_at', nullif(btrim(coalesce(_motivo, '')), ''), auth.uid() FROM public.empresas_grupo x WHERE x.id = v_id;
    RETURN v_id;
  END IF;
  SELECT * INTO e FROM public.empresas_grupo WHERE id = _id AND es_prueba = v_prueba FOR UPDATE;
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
CREATE OR REPLACE FUNCTION public.cuenta_guardar(
  _id uuid, _empresa_id uuid, _nombre text, _banco text, _tipo text, _moneda text, _ultimos4 text,
  _activo boolean DEFAULT true, _orden integer DEFAULT NULL, _saldo_inicial numeric DEFAULT 0, _motivo text DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE c public.cuentas_financieras%ROWTYPE; v_id uuid; v_accion text; v_prueba boolean := public.es_usuario_prueba(auth.uid()); v_ult text := nullif(btrim(coalesce(_ultimos4, '')), '');
BEGIN
  IF NOT (public.es_finanzas_admin(auth.uid()) AND public.usuario_activo(auth.uid())) THEN
    RAISE EXCEPTION 'Sólo el administrador financiero o un administrador da de alta y edita cuentas';
  END IF;
  IF length(btrim(coalesce(_nombre, ''))) < 2 THEN RAISE EXCEPTION 'El nombre de la cuenta es obligatorio'; END IF;
  IF _tipo NOT IN ('EFECTIVO', 'BANCO') THEN RAISE EXCEPTION 'El tipo de cuenta es efectivo o banco'; END IF;
  IF nullif(btrim(coalesce(_moneda, '')), '') IS NULL THEN RAISE EXCEPTION 'Indica la moneda'; END IF;
  IF NOT public.moneda_permitida(_moneda) THEN RAISE EXCEPTION 'La moneda % no está permitida (hoy: MXN y USD; se amplía en el parámetro monedas_permitidas)', _moneda; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.empresas_grupo WHERE id = _empresa_id AND es_prueba = v_prueba) THEN RAISE EXCEPTION 'Elige la empresa de la cuenta'; END IF;
  IF _tipo = 'BANCO' THEN
    IF nullif(btrim(coalesce(_banco, '')), '') IS NULL THEN RAISE EXCEPTION 'Indica el banco'; END IF;
    IF v_ult IS NULL OR v_ult !~ '^[0-9]{4}$' THEN RAISE EXCEPTION 'Captura solo los últimos 4 dígitos de la cuenta (nunca el número completo)'; END IF;
  ELSIF v_ult IS NOT NULL THEN
    RAISE EXCEPTION 'Una caja de efectivo no lleva número de cuenta';
  END IF;

  IF _id IS NULL THEN
    IF NOT EXISTS (SELECT 1 FROM public.empresas_grupo WHERE id = _empresa_id AND activo) THEN RAISE EXCEPTION 'La empresa está desactivada'; END IF;
    PERFORM set_config('kit.cuenta_admin', 'on', true);
    INSERT INTO public.cuentas_financieras (nombre, tipo, moneda, banco, saldo_inicial, activo, orden, empresa_id, ultimos4, es_prueba)
    VALUES (btrim(_nombre), _tipo::public.cuenta_tipo, upper(btrim(_moneda)), CASE WHEN _tipo = 'BANCO' THEN btrim(_banco) END,
            coalesce(_saldo_inicial, 0), coalesce(_activo, true),
            coalesce(_orden, (SELECT coalesce(max(orden), 0) + 1 FROM public.cuentas_financieras)), _empresa_id, v_ult, v_prueba)
    RETURNING id INTO v_id;
    PERFORM set_config('kit.cuenta_admin', 'off', true);
    INSERT INTO public.catalogo_bancos_bitacora (entidad, entidad_id, accion, despues, motivo, usuario_id)
    SELECT 'CUENTA', v_id, 'ALTA', to_jsonb(x) - 'created_at' - 'updated_at', nullif(btrim(coalesce(_motivo, '')), ''), auth.uid()
      FROM public.cuentas_financieras x WHERE x.id = v_id;
    RETURN v_id;
  END IF;

  SELECT * INTO c FROM public.cuentas_financieras WHERE id = _id AND es_prueba = v_prueba FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe la cuenta'; END IF;
  IF c.activo AND NOT coalesce(_activo, c.activo) AND length(btrim(coalesce(_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'El motivo de la desactivación es obligatorio (mínimo 5 caracteres)';
  END IF;
  IF c.activo AND NOT coalesce(_activo, c.activo) AND coalesce(public._cuenta_saldo(c.id), 0) <> 0 AND length(btrim(coalesce(_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'La cuenta «%» tiene saldo distinto de cero: desactivarla exige motivo (no admitirá movimientos nuevos)', c.nombre;
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
-- ── 12. Históricos y regularización (solo administrador financiero; motivo y bitácora) ─
-- Resolver un movimiento histórico (capturado directo antes de la unificación): confirmarlo (si está pendiente) o cancelarlo.
CREATE OR REPLACE FUNCTION public.movimiento_historico_resolver(_id uuid, _accion text, _cuenta_id uuid DEFAULT NULL, _motivo text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE m public.movimientos_financieros%ROWTYPE; c public.cuentas_financieras%ROWTYPE;
BEGIN
  IF NOT (public.es_finanzas_admin(auth.uid()) AND public.usuario_activo(auth.uid())) THEN
    RAISE EXCEPTION 'Sólo el administrador financiero resuelve movimientos históricos';
  END IF;
  IF _accion NOT IN ('CONFIRMAR', 'CANCELAR') THEN RAISE EXCEPTION 'La acción es CONFIRMAR o CANCELAR'; END IF;
  IF length(btrim(coalesce(_motivo, ''))) < 5 THEN RAISE EXCEPTION 'El motivo es obligatorio (mínimo 5 caracteres)'; END IF;
  SELECT * INTO m FROM public.movimientos_financieros WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el movimiento'; END IF;
  IF m.origen <> 'HISTORICO_DIRECTO' THEN
    RAISE EXCEPTION '% no es un movimiento histórico (origen %): se corrige con cancelar/ajustar o con la reversa del flujo', m.folio, m.origen;
  END IF;
  PERFORM public._libro_no_es_mio(m);
  IF _accion = 'CANCELAR' THEN
    PERFORM public.movimiento_cancelar(m.id, _motivo);
  ELSE
    IF m.estatus <> 'PENDIENTE' THEN RAISE EXCEPTION '% no está pendiente (estatus: %)', m.folio, m.estatus; END IF;
    c := public._cuenta_valida_para(_cuenta_id, false, NULL, m.moneda, m.metodo_pago::text);
    IF m.tipo = 'EGRESO' THEN PERFORM public._exigir_saldo(c.id, m.monto); END IF;
    PERFORM set_config('kit.libro_admin', 'on', true);
    UPDATE public.movimientos_financieros SET estatus = 'CONFIRMADO', cuenta_id = c.id, confirmado_por = auth.uid(), confirmado_at = now() WHERE id = m.id;
    PERFORM set_config('kit.libro_admin', 'off', true);
  END IF;
  INSERT INTO public.movimiento_bitacora (movimiento_id, accion, usuario_id, detalle)
  VALUES (m.id, 'RESOLVER_HISTORICO', auth.uid(), jsonb_build_object('accion', _accion, 'motivo', btrim(_motivo), 'cuenta_id', _cuenta_id));
  PERFORM public.registrar_bitacora_compras('cobranza', 'resolver_historico_' || lower(_accion), 'movimientos_financieros', m.id, m.folio,
    jsonb_build_object('motivo', btrim(_motivo)), false);
END;
$$;

-- Regularizar: registrar un movimiento real que quedó fuera (p. ej. la entrada de USD que respalda un pago). Fecha y cuenta reales.
CREATE OR REPLACE FUNCTION public.movimiento_regularizar(
  _tipo text, _monto numeric, _moneda text, _tipo_cambio numeric, _fecha date, _cuenta_id uuid, _metodo_pago text,
  _concepto text, _categoria text, _contraparte text, _referencia text, _motivo text, _evidencia_path text DEFAULT NULL, _afecta_totales boolean DEFAULT true
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE c public.cuentas_financieras%ROWTYPE; v_mov uuid;
BEGIN
  IF NOT (public.es_finanzas_admin(auth.uid()) AND public.usuario_activo(auth.uid())) THEN
    RAISE EXCEPTION 'Sólo el administrador financiero regulariza movimientos';
  END IF;
  IF length(btrim(coalesce(_motivo, ''))) < 10 THEN RAISE EXCEPTION 'El motivo de la regularización es obligatorio (mínimo 10 caracteres)'; END IF;
  IF _tipo NOT IN ('INGRESO', 'EGRESO') THEN RAISE EXCEPTION 'El tipo es INGRESO o EGRESO'; END IF;
  IF _monto IS NULL OR _monto <= 0 THEN RAISE EXCEPTION 'El monto debe ser mayor a cero'; END IF;
  IF NOT public.moneda_permitida(_moneda) THEN RAISE EXCEPTION 'La moneda % no está permitida', _moneda; END IF;
  IF _moneda <> 'MXN' AND (_tipo_cambio IS NULL OR _tipo_cambio <= 0) THEN RAISE EXCEPTION 'Captura el tipo de cambio de % a MXN', _moneda; END IF;
  IF _fecha IS NULL OR _fecha > current_date THEN RAISE EXCEPTION 'La fecha real del movimiento es obligatoria y no puede ser futura'; END IF;
  IF nullif(btrim(coalesce(_concepto, '')), '') IS NULL OR nullif(btrim(coalesce(_contraparte, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Concepto y contraparte son obligatorios';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.categorias_financieras WHERE tipo = _tipo::public.mov_tipo AND nombre = _categoria AND NOT es_prueba) THEN
    RAISE EXCEPTION 'La categoría % no existe para %', _categoria, _tipo;
  END IF;
  c := public._cuenta_valida_para(_cuenta_id, false, NULL, _moneda, _metodo_pago);
  IF _tipo = 'EGRESO' THEN PERFORM public._exigir_saldo(c.id, _monto); END IF;
  PERFORM set_config('kit.libro_via_flujo', 'on', true);
  INSERT INTO public.movimientos_financieros
    (tipo, estatus, concepto, descripcion, monto, moneda, tipo_cambio, fecha_movimiento, metodo_pago, cuenta_id, referencia,
     contraparte_tipo, contraparte_nombre, created_by, confirmado_por, confirmado_at, origen, categoria, afecta_totales, regularizacion_motivo)
  VALUES (_tipo::public.mov_tipo, 'CONFIRMADO', btrim(_concepto), 'Regularización: ' || btrim(_motivo), round(_monto, 2), _moneda,
          CASE WHEN _moneda = 'MXN' THEN NULL ELSE _tipo_cambio END, _fecha, _metodo_pago::public.metodo_pago, c.id,
          nullif(btrim(coalesce(_referencia, '')), ''), 'OTRO'::public.contraparte_tipo, btrim(_contraparte), auth.uid(), auth.uid(), now(),
          'REGULARIZACION', _categoria, coalesce(_afecta_totales, true), btrim(_motivo))
  RETURNING id INTO v_mov;
  PERFORM set_config('kit.libro_via_flujo', 'off', true);
  IF nullif(btrim(coalesce(_evidencia_path, '')), '') IS NOT NULL THEN
    INSERT INTO public.movimiento_adjuntos (movimiento_id, tipo_documento, nombre_archivo, storage_path, subido_por, notas)
    VALUES (v_mov, 'COMPROBANTE_PAGO'::public.adjunto_tipo, coalesce(nullif(regexp_replace(_evidencia_path, '^.*/', ''), ''), 'evidencia'), btrim(_evidencia_path), auth.uid(), 'Sustento de la regularización');
  END IF;
  INSERT INTO public.movimiento_bitacora (movimiento_id, accion, usuario_id, detalle)
  VALUES (v_mov, 'REGULARIZADO', auth.uid(), jsonb_build_object('motivo', btrim(_motivo), 'fecha_real', _fecha));
  PERFORM public.registrar_bitacora_compras('cobranza', 'regularizar_movimiento', 'movimientos_financieros', v_mov, NULL,
    jsonb_build_object('motivo', btrim(_motivo), 'monto', _monto, 'moneda', _moneda, 'tipo', _tipo), false);
  RETURN v_mov;
END;
$$;

-- Reclasificar la cuenta de un movimiento sin tocar el original: dos contra-movimientos que no suman en totales.
CREATE OR REPLACE FUNCTION public.movimiento_reclasificar_cuenta(_mov_id uuid, _cuenta_destino uuid, _motivo text, _fecha date DEFAULT current_date)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE m public.movimientos_financieros%ROWTYPE; c public.cuentas_financieras%ROWTYPE; v_a uuid; v_b uuid; v_cat text := 'Reclasificación entre cuentas';
BEGIN
  IF NOT (public.es_finanzas_admin(auth.uid()) AND public.usuario_activo(auth.uid())) THEN
    RAISE EXCEPTION 'Sólo el administrador financiero reclasifica la cuenta de un movimiento';
  END IF;
  IF length(btrim(coalesce(_motivo, ''))) < 10 THEN RAISE EXCEPTION 'El motivo es obligatorio (mínimo 10 caracteres)'; END IF;
  IF _fecha IS NULL OR _fecha > current_date THEN RAISE EXCEPTION 'La fecha no puede ser futura'; END IF;
  SELECT * INTO m FROM public.movimientos_financieros WHERE id = _mov_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el movimiento'; END IF;
  IF m.estatus <> 'CONFIRMADO' THEN RAISE EXCEPTION '% no está confirmado', m.folio; END IF;
  IF m.origen = 'CONTRA_MOVIMIENTO' OR m.reclasificado_at IS NOT NULL THEN RAISE EXCEPTION '% ya es una reclasificación o ya fue reclasificado', m.folio; END IF;
  PERFORM public._libro_no_es_mio(m);
  IF _cuenta_destino = m.cuenta_id THEN RAISE EXCEPTION 'Elige una cuenta distinta de la actual'; END IF;
  c := public._cuenta_valida_para(_cuenta_destino, false, NULL, m.moneda, m.metodo_pago::text);
  -- Lo que salió de la cuenta equivocada vuelve a ella y sale de la correcta (o al revés si fue un ingreso).
  IF m.tipo = 'EGRESO' THEN PERFORM public._exigir_saldo(c.id, m.monto); ELSE PERFORM public._exigir_saldo(m.cuenta_id, m.monto); END IF;
  PERFORM set_config('kit.libro_via_flujo', 'on', true);
  INSERT INTO public.movimientos_financieros
    (tipo, estatus, concepto, descripcion, monto, moneda, tipo_cambio, fecha_movimiento, metodo_pago, cuenta_id, referencia,
     contraparte_tipo, contraparte_nombre, created_by, confirmado_por, confirmado_at, origen, categoria, afecta_totales, reclasifica_mov_id, regularizacion_motivo)
  VALUES (CASE WHEN m.tipo = 'EGRESO' THEN 'INGRESO' ELSE 'EGRESO' END::public.mov_tipo, 'CONFIRMADO',
          'Reclasificación de cuenta de ' || m.folio || ' (sale de la cuenta equivocada)', btrim(_motivo), m.monto, m.moneda, m.tipo_cambio, _fecha, m.metodo_pago, m.cuenta_id,
          m.referencia, 'OTRO'::public.contraparte_tipo, m.contraparte_nombre, auth.uid(), auth.uid(), now(), 'CONTRA_MOVIMIENTO', v_cat, false, m.id, btrim(_motivo))
  RETURNING id INTO v_a;
  INSERT INTO public.movimientos_financieros
    (tipo, estatus, concepto, descripcion, monto, moneda, tipo_cambio, fecha_movimiento, metodo_pago, cuenta_id, referencia,
     contraparte_tipo, contraparte_nombre, created_by, confirmado_por, confirmado_at, origen, categoria, afecta_totales, reclasifica_mov_id, regularizacion_motivo)
  VALUES (m.tipo, 'CONFIRMADO', 'Reclasificación de cuenta de ' || m.folio || ' (cuenta correcta)', btrim(_motivo), m.monto, m.moneda, m.tipo_cambio, _fecha, m.metodo_pago, c.id,
          m.referencia, 'OTRO'::public.contraparte_tipo, m.contraparte_nombre, auth.uid(), auth.uid(), now(), 'CONTRA_MOVIMIENTO', v_cat, false, m.id, btrim(_motivo))
  RETURNING id INTO v_b;
  PERFORM set_config('kit.libro_via_flujo', 'off', true);
  UPDATE public.movimientos_financieros SET reclasificado_at = now() WHERE id = m.id;
  INSERT INTO public.movimiento_bitacora (movimiento_id, accion, usuario_id, detalle)
  VALUES (m.id, 'RECLASIFICADO', auth.uid(), jsonb_build_object('motivo', btrim(_motivo), 'a_cuenta', c.nombre, 'contra_1', v_a, 'contra_2', v_b));
  PERFORM public.registrar_bitacora_compras('cobranza', 'reclasificar_cuenta', 'movimientos_financieros', m.id, m.folio,
    jsonb_build_object('motivo', btrim(_motivo), 'a_cuenta', c.nombre), false);
  RETURN jsonb_build_object('contra_origen', v_a, 'contra_destino', v_b);
END;
$$;

-- Pago de cobranza cobrado y validado FUERA del flujo (p. ej. CP-00001): movimiento histórico del libro con cuenta y fecha reales.
CREATE OR REPLACE FUNCTION public.cobranza_pago_regularizar(_pago_id uuid, _cuenta_id uuid, _fecha date, _motivo text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE p public.cobranza_pagos%ROWTYPE; c public.cuentas_financieras%ROWTYPE; v_mov uuid; v_metodo text; v_cli text;
BEGIN
  IF NOT (public.es_finanzas_admin(auth.uid()) AND public.usuario_activo(auth.uid())) THEN
    RAISE EXCEPTION 'Sólo el administrador financiero regulariza pagos de cobranza';
  END IF;
  IF length(btrim(coalesce(_motivo, ''))) < 10 THEN RAISE EXCEPTION 'El motivo es obligatorio (mínimo 10 caracteres)'; END IF;
  IF _fecha IS NULL OR _fecha > current_date THEN RAISE EXCEPTION 'La fecha real del cobro es obligatoria y no puede ser futura'; END IF;
  SELECT * INTO p FROM public.cobranza_pagos WHERE id = _pago_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el pago'; END IF;
  IF p.es_prueba THEN RAISE EXCEPTION '% es un pago de prueba: no se regulariza en el libro real', p.folio; END IF;
  IF p.estatus <> 'validado' THEN RAISE EXCEPTION '% no está validado (estatus: %)', p.folio, p.estatus; END IF;
  IF p.origen <> 'HISTORICO_DIRECTO' OR p.flujo_id IS NOT NULL THEN RAISE EXCEPTION '% ya pasó por el flujo de dinero', p.folio; END IF;
  IF EXISTS (SELECT 1 FROM public.movimientos_financieros WHERE regulariza_pago_id = p.id) THEN RAISE EXCEPTION '% ya fue regularizado', p.folio; END IF;
  v_metodo := CASE p.forma WHEN 'efectivo' THEN 'EFECTIVO' WHEN 'transferencia' THEN 'TRANSFERENCIA' WHEN 'deposito' THEN 'DEPOSITO'
                           ELSE NULL END;
  IF v_metodo IS NULL THEN RAISE EXCEPTION 'La forma de pago % no se puede regularizar automáticamente', p.forma; END IF;
  c := public._cuenta_valida_para(_cuenta_id, false, NULL, 'MXN', v_metodo);
  SELECT coalesce(nombre_comercial, razon_social, codigo_erp) INTO v_cli FROM public.clientes WHERE id = p.cliente_id;
  PERFORM set_config('kit.libro_via_flujo', 'on', true);
  INSERT INTO public.movimientos_financieros
    (tipo, estatus, concepto, descripcion, monto, moneda, fecha_movimiento, metodo_pago, cuenta_id, referencia,
     contraparte_tipo, cliente_id, contraparte_nombre, created_by, confirmado_por, confirmado_at, origen, categoria, regulariza_pago_id, regularizacion_motivo)
  VALUES ('INGRESO', 'CONFIRMADO', 'Pago de cliente ' || coalesce(v_cli, '') || ' (cobranza ' || p.folio || ')', 'Regularización: ' || btrim(_motivo),
          p.monto, 'MXN', _fecha, v_metodo::public.metodo_pago, c.id, p.referencia, 'CLIENTE'::public.contraparte_tipo, p.cliente_id,
          coalesce(v_cli, 'Cliente'), auth.uid(), auth.uid(), now(), 'REGULARIZACION', 'Venta de refacciones', p.id, btrim(_motivo))
  RETURNING id INTO v_mov;
  PERFORM set_config('kit.libro_via_flujo', 'off', true);
  IF p.evidencia_path IS NOT NULL THEN
    INSERT INTO public.movimiento_adjuntos (movimiento_id, tipo_documento, nombre_archivo, storage_path, subido_por, notas)
    VALUES (v_mov, CASE WHEN v_metodo = 'EFECTIVO' THEN 'VALE_EFECTIVO' ELSE 'COMPROBANTE_PAGO' END::public.adjunto_tipo,
            coalesce(nullif(regexp_replace(p.evidencia_path, '^.*/', ''), ''), 'evidencia'), p.evidencia_path, auth.uid(), 'Evidencia del pago ' || p.folio);
  END IF;
  INSERT INTO public.movimiento_bitacora (movimiento_id, accion, usuario_id, detalle)
  VALUES (v_mov, 'REGULARIZADO', auth.uid(), jsonb_build_object('pago', p.folio, 'motivo', btrim(_motivo), 'fecha_real', _fecha));
  PERFORM public.registrar_bitacora_compras('cobranza', 'regularizar_pago_cobranza', 'cobranza_pagos', p.id, p.folio,
    jsonb_build_object('motivo', btrim(_motivo), 'movimiento_id', v_mov, 'cuenta', c.nombre), false);
  RETURN v_mov;
END;
$$;

-- Conciliación: marca simple (quién y cuándo). Sin conciliación bancaria automática.
CREATE OR REPLACE FUNCTION public.movimiento_conciliar(_ids uuid[], _conciliado boolean DEFAULT true)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n integer;
BEGIN
  IF NOT (public.es_finanzas(auth.uid()) AND public.usuario_activo(auth.uid())) THEN
    RAISE EXCEPTION 'Sólo Finanzas concilia movimientos';
  END IF;
  UPDATE public.movimientos_financieros
     SET conciliado = coalesce(_conciliado, true),
         conciliado_por = CASE WHEN coalesce(_conciliado, true) THEN auth.uid() END,
         conciliado_at = CASE WHEN coalesce(_conciliado, true) THEN now() END
   WHERE id = ANY (_ids) AND estatus = 'CONFIRMADO';
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM public.registrar_bitacora_compras('cobranza', 'conciliar_movimientos', 'movimientos_financieros', NULL, NULL,
    jsonb_build_object('movimientos', n, 'conciliado', coalesce(_conciliado, true)), false);
  RETURN n;
END;
$$;

-- ── 13. Evidencia de gastos en Storage ─────────────────────────────────────
DO $$
BEGIN
  DROP POLICY IF EXISTS evidencias_flujo_select ON storage.objects;
  CREATE POLICY evidencias_flujo_select ON storage.objects FOR SELECT TO authenticated
    USING (bucket_id = 'evidencias-compras' AND (name LIKE 'flujo/%' OR name LIKE 'prueba/flujo/%')
           AND (public.flujo_es_admin() OR public.es_finanzas(auth.uid()) OR public.flujo_alguna_etapa()));
  DROP POLICY IF EXISTS evidencias_flujo_insert ON storage.objects;
  CREATE POLICY evidencias_flujo_insert ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'evidencias-compras' AND (name LIKE 'flujo/%' OR name LIKE 'prueba/flujo/%')
           AND (public.flujo_es_admin() OR public.flujo_cap('recibe') OR public.flujo_cap('captura_gasto')));
EXCEPTION
  WHEN insufficient_privilege OR undefined_table THEN
    RAISE NOTICE 'PENDIENTE MANUAL: crea en Storage las políticas de evidencias-compras para la carpeta flujo/ (ver el documento de diseño).';
END $$;

-- ── 14. Permisos ───────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.flujo_alguna_etapa(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_saldo_cuenta(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_cuentas_gasto(uuid, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_categorias_gasto() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_capturar_gasto(numeric, text, text, date, text, text, text, text, numeric, text, uuid, uuid, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_corregir_gasto(uuid, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_confirmar_gasto(uuid, uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_entregar_gasto(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_rechazar_gasto(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_cuentas(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_listar_capacidades() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public._libro_no_es_mio(public.movimientos_financieros) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._flujo_libro_insertar(public.flujo_dinero, public.cuentas_financieras) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.movimiento_historico_resolver(uuid, text, uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.movimiento_regularizar(text, numeric, text, numeric, date, uuid, text, text, text, text, text, text, text, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.movimiento_reclasificar_cuenta(uuid, uuid, text, date) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cobranza_pago_regularizar(uuid, uuid, date, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.movimiento_conciliar(uuid[], boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_saldo_cuenta(uuid), public.flujo_cuentas_gasto(uuid, text, text), public.flujo_categorias_gasto(),
  public.flujo_capturar_gasto(numeric, text, text, date, text, text, text, text, numeric, text, uuid, uuid, jsonb),
  public.flujo_corregir_gasto(uuid, jsonb), public.flujo_confirmar_gasto(uuid, uuid, text), public.flujo_entregar_gasto(uuid, text),
  public.flujo_rechazar_gasto(uuid, text), public.flujo_cuentas(uuid), public.flujo_listar_capacidades(),
  public.movimiento_historico_resolver(uuid, text, uuid, text),
  public.movimiento_regularizar(text, numeric, text, numeric, date, uuid, text, text, text, text, text, text, text, boolean),
  public.movimiento_reclasificar_cuenta(uuid, uuid, text, date), public.cobranza_pago_regularizar(uuid, uuid, date, text),
  public.movimiento_conciliar(uuid[], boolean) TO authenticated;

-- ── 15. Postflight ─────────────────────────────────────────────────────────
DO $postflight$
BEGIN
  IF has_table_privilege('authenticated', 'public.categorias_financieras', 'INSERT') OR has_table_privilege('authenticated', 'public.categorias_financieras', 'UPDATE') THEN
    RAISE EXCEPTION 'Las categorías siguen abiertas a escritura directa.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.categorias_financieras WHERE nombre = 'Proveedor internacional' AND NOT es_prueba) THEN
    RAISE EXCEPTION 'No quedó la categoría Proveedor internacional.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.categorias_financieras WHERE nombre = 'Mantenimiento' AND activo AND NOT es_prueba) THEN
    RAISE EXCEPTION '«Mantenimiento» debía quedar inactiva.';
  END IF;
  IF has_function_privilege('anon', 'public.flujo_confirmar_gasto(uuid,uuid,text)', 'execute') THEN RAISE EXCEPTION 'flujo_confirmar_gasto abierta a anon.'; END IF;
END $postflight$;

SELECT (SELECT count(*) FROM public.categorias_financieras WHERE NOT es_prueba AND activo) AS categorias_reales_activas,
       (SELECT count(*) FROM public.cuentas_financieras WHERE es_prueba) AS cuentas_de_prueba,
       (SELECT count(*) FROM public.movimientos_financieros) AS movimientos;

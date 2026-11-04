-- ============================================================================
-- Flujo de dinero: cuentas por empresa y banco (catálogo de instituciones de México)
-- (2026-11-06)
--
-- Pedido del equipo: una sección donde se den de alta las cuentas bancarias con el NOMBRE
-- DE LA EMPRESA, el BANCO (de la lista de instituciones de México: bancos y fintech) y los
-- ÚLTIMOS 4 DÍGITOS, para que al registrar un ingreso o egreso en el flujo se elija en qué
-- banco / cuenta entró o salió el dinero.
--
--  · instituciones_financieras: catálogo de bancos y fintech de México (lo pueden ampliar los
--    administradores del flujo; sembrado con la lista de participantes del SPEI conocida).
--  · cuentas_financieras: agrega empresa, institución y últimos 4 dígitos. El nombre que se ve
--    al elegir cuenta es «Empresa · Banco ••1234» (o el alias que se capture).
--  · flujo_cuentas(_todas): ahora trae empresa, institución y últimos 4 (y, para administradores,
--    también las inactivas).
--  · flujo_crear_cuenta_empresa / flujo_editar_cuenta / flujo_desactivar_cuenta /
--    flujo_agregar_institucion / flujo_instituciones: la sección de cuentas.
--
-- Solo agrega: las cuentas que ya existen (Caja chica, Caja dólares, Banco principal) siguen
-- igual, sin empresa hasta que un administrador se la asigne.
--
-- Idempotente. Para el SQL editor de Supabase; NO usar `supabase db push`.
-- Para revertir: DROP de las funciones nuevas y volver a flujo_cuentas() de 20261105000001.
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := '{}';
BEGIN
  IF to_regclass('public.cuentas_financieras') IS NULL THEN _faltan := _faltan || 'tabla cuentas_financieras'::text; END IF;
  IF to_regprocedure('public.flujo_crear_cuenta(text,text,text,text,text)') IS NULL THEN _faltan := _faltan || 'flujo_crear_cuenta (20261105000001)'::text; END IF;
  IF to_regprocedure('public.flujo_es_admin(uuid)') IS NULL THEN _faltan := _faltan || 'flujo_es_admin'::text; END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ', ');
  END IF;
END;
$preflight$;

-- ── 1. Catálogo de instituciones ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.instituciones_financieras (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre     text NOT NULL,
  tipo       text NOT NULL DEFAULT 'BANCO' CHECK (tipo IN ('BANCO', 'FINTECH', 'OTRO')),
  activo     boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_instituciones_financieras_nombre ON public.instituciones_financieras (lower(nombre));
ALTER TABLE public.instituciones_financieras ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS instituciones_select ON public.instituciones_financieras;
CREATE POLICY instituciones_select ON public.instituciones_financieras FOR SELECT TO authenticated USING (true);
REVOKE ALL ON public.instituciones_financieras FROM anon;
GRANT SELECT ON public.instituciones_financieras TO authenticated;

INSERT INTO public.instituciones_financieras (nombre, tipo) VALUES
  ('BBVA México', 'BANCO'), ('Santander', 'BANCO'), ('Banorte', 'BANCO'), ('HSBC México', 'BANCO'), ('Citibanamex', 'BANCO'),
  ('Scotiabank', 'BANCO'), ('Inbursa', 'BANCO'), ('BanRegio', 'BANCO'), ('Banco del Bajío', 'BANCO'), ('Afirme', 'BANCO'),
  ('Banco Azteca', 'BANCO'), ('BanCoppel', 'BANCO'), ('Banca Mifel', 'BANCO'), ('Banco Multiva', 'BANCO'), ('Banco Ve por Más', 'BANCO'),
  ('Banco Base', 'BANCO'), ('Banco Invex', 'BANCO'), ('Banco Actinver', 'BANCO'), ('Banco Compartamos', 'BANCO'), ('Banco Covalto', 'BANCO'),
  ('Banco Sabadell', 'BANCO'), ('Banco Autofin', 'BANCO'), ('Banco Forjadores', 'BANCO'), ('Banco Inmobiliario Mexicano', 'BANCO'),
  ('Banco PagaTodo', 'BANCO'), ('Banco Bancrea', 'BANCO'), ('Bankaool', 'BANCO'), ('Bansí', 'BANCO'), ('Consubanco', 'BANCO'),
  ('CIBanco', 'BANCO'), ('Intercam Banco', 'BANCO'), ('Banco Monex', 'BANCO'), ('ABC Capital', 'BANCO'), ('Banco S3 Caceis', 'BANCO'),
  ('Fundación Dondé Banco', 'BANCO'), ('Banco Ahorro Famsa', 'BANCO'), ('Banco KEB Hana México', 'BANCO'), ('Shinhan de México', 'BANCO'),
  ('ICBC México', 'BANCO'), ('Bank of China México', 'BANCO'), ('Bank of America México', 'BANCO'), ('JP Morgan', 'BANCO'),
  ('Deutsche Bank México', 'BANCO'), ('MUFG Bank México', 'BANCO'), ('Mizuho Bank México', 'BANCO'), ('Bancomext', 'BANCO'),
  ('Banobras', 'BANCO'), ('Nacional Financiera', 'BANCO'), ('Banjército', 'BANCO'), ('Hipotecaria Federal', 'BANCO'),
  ('Albo', 'FINTECH'), ('Arcus Fi', 'FINTECH'), ('Bineo', 'FINTECH'), ('Bitso', 'FINTECH'), ('Cuenca', 'FINTECH'),
  ('Dock Pagos', 'FINTECH'), ('Fondeadora', 'FINTECH'), ('Hey Banco', 'FINTECH'), ('Kapital', 'FINTECH'), ('Klar', 'FINTECH'),
  ('Mercado Pago', 'FINTECH'), ('Nu México', 'FINTECH'), ('Plata', 'FINTECH'), ('Revolut', 'FINTECH'),
  ('STP (Sistema de Transferencias y Pagos)', 'FINTECH'), ('Spin by OXXO', 'FINTECH'), ('Stori', 'FINTECH'), ('Ualá', 'FINTECH'),
  ('Vector Casa de Bolsa', 'OTRO'), ('Finamex Casa de Bolsa', 'OTRO'), ('Kuspit Casa de Bolsa', 'OTRO'), ('Juoshui', 'OTRO')
ON CONFLICT DO NOTHING;

-- ── 2. Empresa, institución y últimos 4 dígitos en las cuentas ──────────────
ALTER TABLE public.cuentas_financieras
  ADD COLUMN IF NOT EXISTS empresa text,
  ADD COLUMN IF NOT EXISTS institucion_id uuid REFERENCES public.instituciones_financieras(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS ultimos4 text CHECK (ultimos4 IS NULL OR ultimos4 ~ '^[0-9]{4}$');

-- ── 3. Ver las cuentas (con empresa y banco) ────────────────────────────────
DROP FUNCTION IF EXISTS public.flujo_cuentas();
CREATE OR REPLACE FUNCTION public.flujo_cuentas(_todas boolean DEFAULT false)
RETURNS TABLE (id uuid, nombre text, tipo text, moneda text, orden integer, empresa text, institucion text, ultimos4 text, activo boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT (public.flujo_cap('caja') OR public.flujo_cap('recibe') OR public.flujo_es_admin()) THEN
    RAISE EXCEPTION 'No tienes asignada la etapa de caja';
  END IF;
  RETURN QUERY
    SELECT c.id, c.nombre, c.tipo::text, c.moneda, c.orden, c.empresa, i.nombre, c.ultimos4, c.activo
      FROM public.cuentas_financieras c LEFT JOIN public.instituciones_financieras i ON i.id = c.institucion_id
     WHERE c.activo OR (coalesce(_todas, false) AND public.flujo_es_admin())
     ORDER BY c.empresa NULLS LAST, c.orden, c.nombre;
END;
$$;
REVOKE ALL ON FUNCTION public.flujo_cuentas(boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_cuentas(boolean) TO authenticated;

CREATE OR REPLACE FUNCTION public.flujo_instituciones()
RETURNS TABLE (id uuid, nombre text, tipo text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT (public.flujo_cap('caja') OR public.flujo_cap('recibe') OR public.flujo_cap('aplica') OR public.flujo_es_admin()) THEN
    RAISE EXCEPTION 'No tienes asignada una etapa del flujo';
  END IF;
  RETURN QUERY SELECT i.id, i.nombre, i.tipo FROM public.instituciones_financieras i WHERE i.activo ORDER BY i.tipo, i.nombre;
END;
$$;
REVOKE ALL ON FUNCTION public.flujo_instituciones() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_instituciones() TO authenticated;

-- ── 4. Dar de alta, editar y desactivar ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.flujo_agregar_institucion(_nombre text, _tipo text DEFAULT 'BANCO')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_nombre text := nullif(btrim(coalesce(_nombre, '')), ''); v_id uuid;
BEGIN
  IF NOT public.flujo_es_admin() THEN RAISE EXCEPTION 'Solo un administrador del flujo agrega instituciones'; END IF;
  IF v_nombre IS NULL THEN RAISE EXCEPTION 'Captura el nombre del banco o fintech'; END IF;
  IF upper(coalesce(_tipo, '')) NOT IN ('BANCO', 'FINTECH', 'OTRO') THEN RAISE EXCEPTION 'Tipo de institución no válido'; END IF;
  IF EXISTS (SELECT 1 FROM public.instituciones_financieras WHERE lower(nombre) = lower(v_nombre)) THEN
    RAISE EXCEPTION '«%» ya está en la lista', v_nombre;
  END IF;
  INSERT INTO public.instituciones_financieras (nombre, tipo) VALUES (v_nombre, upper(_tipo)) RETURNING id INTO v_id;
  RETURN jsonb_build_object('id', v_id, 'nombre', v_nombre);
END;
$$;
REVOKE ALL ON FUNCTION public.flujo_agregar_institucion(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_agregar_institucion(text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.flujo_crear_cuenta_empresa(
  _empresa text, _tipo text, _institucion_id uuid DEFAULT NULL, _ultimos4 text DEFAULT NULL, _moneda text DEFAULT 'MXN', _alias text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_empresa text := nullif(btrim(coalesce(_empresa, '')), '');
  v_tipo text := upper(coalesce(_tipo, ''));
  v_moneda text := upper(coalesce(nullif(btrim(coalesce(_moneda, '')), ''), 'MXN'));
  v_u4 text := nullif(btrim(coalesce(_ultimos4, '')), '');
  v_alias text := nullif(btrim(coalesce(_alias, '')), '');
  v_inst text;
  v_nombre text;
  v_id uuid;
BEGIN
  IF NOT public.flujo_es_admin() THEN RAISE EXCEPTION 'Solo un administrador del flujo da de alta cuentas'; END IF;
  IF v_empresa IS NULL THEN RAISE EXCEPTION 'Captura el nombre de la empresa'; END IF;
  IF v_tipo NOT IN ('BANCO', 'EFECTIVO') THEN RAISE EXCEPTION 'Indica si es una cuenta de banco o una caja de efectivo'; END IF;
  IF v_moneda NOT IN ('MXN', 'USD', 'CNY', 'EUR') THEN RAISE EXCEPTION 'Moneda no válida: %', v_moneda; END IF;
  IF v_tipo = 'BANCO' THEN
    SELECT nombre INTO v_inst FROM public.instituciones_financieras WHERE id = _institucion_id AND activo;
    IF v_inst IS NULL THEN RAISE EXCEPTION 'Elige el banco de la lista'; END IF;
    IF v_u4 IS NULL OR v_u4 !~ '^[0-9]{4}$' THEN RAISE EXCEPTION 'Captura los últimos 4 dígitos de la cuenta (solo números)'; END IF;
    IF EXISTS (SELECT 1 FROM public.cuentas_financieras WHERE lower(empresa) = lower(v_empresa) AND institucion_id = _institucion_id AND ultimos4 = v_u4 AND moneda = v_moneda) THEN
      RAISE EXCEPTION 'Esa cuenta ya está dada de alta (% · % ••%)', v_empresa, v_inst, v_u4;
    END IF;
    v_nombre := coalesce(v_alias, v_empresa || ' · ' || v_inst || ' ••' || v_u4);
  ELSE
    v_inst := NULL; v_u4 := NULL;
    v_nombre := coalesce(v_alias, v_empresa || ' · Caja');
  END IF;
  IF EXISTS (SELECT 1 FROM public.cuentas_financieras WHERE lower(nombre) = lower(v_nombre) AND moneda = v_moneda) THEN
    RAISE EXCEPTION 'Ya existe «%» en %', v_nombre, v_moneda;
  END IF;
  INSERT INTO public.cuentas_financieras (nombre, tipo, moneda, banco, numero_cuenta, empresa, institucion_id, ultimos4, orden)
  VALUES (v_nombre, v_tipo::public.cuenta_tipo, v_moneda, v_inst, v_u4, v_empresa, CASE WHEN v_tipo = 'BANCO' THEN _institucion_id END, v_u4,
          coalesce((SELECT max(orden) FROM public.cuentas_financieras), 0) + 1)
  RETURNING id INTO v_id;
  PERFORM public.registrar_bitacora_compras('cobranza', 'flujo_crear_cuenta_empresa', 'cuentas_financieras', v_id, v_nombre,
    jsonb_build_object('empresa', v_empresa, 'tipo', v_tipo, 'moneda', v_moneda), false);
  RETURN jsonb_build_object('id', v_id, 'nombre', v_nombre);
END;
$$;
REVOKE ALL ON FUNCTION public.flujo_crear_cuenta_empresa(text, text, uuid, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_crear_cuenta_empresa(text, text, uuid, text, text, text) TO authenticated;

-- Editar: asigna empresa / banco / últimos 4 / nombre a una cuenta (por ejemplo, a las que ya existían).
CREATE OR REPLACE FUNCTION public.flujo_editar_cuenta(
  _id uuid, _empresa text DEFAULT NULL, _institucion_id uuid DEFAULT NULL, _ultimos4 text DEFAULT NULL, _nombre text DEFAULT NULL
)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  c public.cuentas_financieras%ROWTYPE;
  v_empresa text := nullif(btrim(coalesce(_empresa, '')), '');
  v_u4 text := nullif(btrim(coalesce(_ultimos4, '')), '');
  v_nombre text := nullif(btrim(coalesce(_nombre, '')), '');
  v_inst text;
BEGIN
  IF NOT public.flujo_es_admin() THEN RAISE EXCEPTION 'Solo un administrador del flujo edita cuentas'; END IF;
  SELECT * INTO c FROM public.cuentas_financieras WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe la cuenta'; END IF;
  IF v_u4 IS NOT NULL AND v_u4 !~ '^[0-9]{4}$' THEN RAISE EXCEPTION 'Los últimos 4 dígitos son solo números'; END IF;
  IF _institucion_id IS NOT NULL THEN
    SELECT nombre INTO v_inst FROM public.instituciones_financieras WHERE id = _institucion_id AND activo;
    IF v_inst IS NULL THEN RAISE EXCEPTION 'Elige el banco de la lista'; END IF;
  END IF;
  IF v_nombre IS NOT NULL AND EXISTS (SELECT 1 FROM public.cuentas_financieras WHERE lower(nombre) = lower(v_nombre) AND moneda = c.moneda AND id <> c.id) THEN
    RAISE EXCEPTION 'Ya existe «%» en %', v_nombre, c.moneda;
  END IF;
  UPDATE public.cuentas_financieras
     SET empresa = coalesce(v_empresa, empresa),
         institucion_id = coalesce(_institucion_id, institucion_id),
         banco = coalesce(v_inst, banco),
         ultimos4 = coalesce(v_u4, ultimos4),
         numero_cuenta = coalesce(v_u4, numero_cuenta),
         nombre = coalesce(v_nombre, nombre)
   WHERE id = c.id;
END;
$$;
REVOKE ALL ON FUNCTION public.flujo_editar_cuenta(uuid, text, uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_editar_cuenta(uuid, text, uuid, text, text) TO authenticated;

-- Desactivar (no se borra: su historial se conserva). No se desactiva con movimientos del flujo todavía abiertos.
CREATE OR REPLACE FUNCTION public.flujo_desactivar_cuenta(_id uuid, _activo boolean DEFAULT false)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.flujo_es_admin() THEN RAISE EXCEPTION 'Solo un administrador del flujo desactiva cuentas'; END IF;
  IF NOT coalesce(_activo, false) AND EXISTS (
       SELECT 1 FROM public.flujo_dinero f WHERE f.etapa IN ('RECIBIDO', 'EN_CAJA') AND (f.cuenta_id = _id OR f.cuenta_prevista_id = _id)) THEN
    RAISE EXCEPTION 'Esa cuenta tiene movimientos del flujo pendientes: ciérralos o recházalos antes de desactivarla';
  END IF;
  UPDATE public.cuentas_financieras SET activo = coalesce(_activo, false) WHERE id = _id;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe la cuenta'; END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.flujo_desactivar_cuenta(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_desactivar_cuenta(uuid, boolean) TO authenticated;

DO $postflight$
BEGIN
  IF (SELECT count(*) FROM public.instituciones_financieras) < 50 THEN RAISE EXCEPTION 'El catálogo de instituciones no quedó sembrado.'; END IF;
  IF has_function_privilege('anon', 'public.flujo_cuentas(boolean)', 'execute')
     OR has_function_privilege('anon', 'public.flujo_crear_cuenta_empresa(text,text,uuid,text,text,text)', 'execute')
     OR has_function_privilege('anon', 'public.flujo_desactivar_cuenta(uuid,boolean)', 'execute') THEN
    RAISE EXCEPTION 'Las funciones de cuentas no deben estar abiertas a anon.';
  END IF;
END $postflight$;

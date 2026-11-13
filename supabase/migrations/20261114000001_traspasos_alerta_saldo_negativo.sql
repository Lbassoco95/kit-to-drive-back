-- ============================================================================
-- Alerta de saldo negativo en cuentas y cajas (2026-11-14)
--
-- Finanzas aceptó que una cuenta (por ejemplo, Caja chica) aparezca en negativo
-- mientras falta registrar un movimiento; lo que piden es que, si una cuenta sigue
-- en negativo MÁS DE 3 DÍAS, se avise a Finanzas, Administración y superadmins para
-- que validen ese saldo.
--
--   · «Desde cuándo» se calcula del propio libro mayor (movimientos CONFIRMADOS por
--     fecha_movimiento): es el primer día de la racha actual en que el saldo al cierre
--     del día fue menor a cero. No depende de cuándo se corra esta migración.
--   · «Más de 3 días» = han pasado más de 3 días desde ese primer día negativo.
--   · Se avisa por la campana (tabla notificaciones). Mientras nadie valide, se repite
--     cada 3 días. Al validar (con una nota) se dejan de mandar avisos de esa racha; si
--     la cuenta vuelve a cero o positivo la alerta se cierra, y una racha nueva es otra alerta.
--   · Quién recibe y quién valida: Finanzas (roles finanzas y admin_financiero),
--     Administración (área administracion) y superadmins. Usuarios inactivos y de prueba no.
--   · Se revisa cada hora con pg_cron si la base lo tiene y, además, cada vez que alguien
--     autorizado abre Traspasos o Control Financiero (la revisión es idempotente).
--   · Un saldo negativo NO bloquea nada: solo el traspaso sigue sin permitir sobregiro.
--
-- Idempotente. Para el SQL editor de Supabase; NO usar `supabase db push`.
-- Para revertir: DROP las funciones saldo_negativo_* y _saldo_negativo_*, quitar el trabajo
-- de pg_cron `saldos_negativos_revisar` y DROP TABLE cuentas_saldo_alertas.
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := '{}';
BEGIN
  IF to_regclass('public.cuentas_financieras') IS NULL THEN _faltan := _faltan || 'tabla cuentas_financieras'::text; END IF;
  IF to_regclass('public.notificaciones') IS NULL THEN _faltan := _faltan || 'tabla notificaciones (20261007000001)'::text; END IF;
  IF to_regclass('public.super_admins') IS NULL THEN _faltan := _faltan || 'tabla super_admins (20261016000001)'::text; END IF;
  IF to_regprocedure('public._saldo_cuenta(uuid)') IS NULL THEN _faltan := _faltan || 'función _saldo_cuenta (20261113000001)'::text; END IF;
  IF to_regprocedure('public.flujo_cap(text,uuid)') IS NULL THEN _faltan := _faltan || 'función flujo_cap'::text; END IF;
  IF to_regprocedure('public.flujo_es_admin(uuid)') IS NULL THEN _faltan := _faltan || 'función flujo_es_admin'::text; END IF;
  IF to_regprocedure('public.registrar_bitacora_compras(text,text,text,uuid,text,jsonb,boolean)') IS NULL THEN _faltan := _faltan || 'función registrar_bitacora_compras'::text; END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ', ');
  END IF;
END;
$preflight$;

-- ── 1. Alertas (una abierta por cuenta; el historial queda) ─────────────────
CREATE TABLE IF NOT EXISTS public.cuentas_saldo_alertas (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cuenta_id               uuid NOT NULL REFERENCES public.cuentas_financieras(id),
  negativo_desde          date NOT NULL,
  saldo_al_detectar       numeric(18, 2) NOT NULL,
  creada_at               timestamptz NOT NULL DEFAULT now(),
  ultimo_aviso_at         timestamptz,
  avisos                  integer NOT NULL DEFAULT 0,
  validado_por            uuid REFERENCES auth.users(id),
  validado_at             timestamptz,
  validado_nota           text,
  resuelta_at             timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_saldo_alerta_abierta ON public.cuentas_saldo_alertas (cuenta_id) WHERE resuelta_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_saldo_alerta_cuenta ON public.cuentas_saldo_alertas (cuenta_id, creada_at DESC);

ALTER TABLE public.cuentas_saldo_alertas ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.cuentas_saldo_alertas FROM PUBLIC, anon, authenticated;
-- Cerrada: se lee y se escribe solo por las funciones saldo_negativo_*.

-- ── 2. Desde cuándo está en negativo (del libro mayor) ──────────────────────
-- NULL si la cuenta hoy no está en negativo.
CREATE OR REPLACE FUNCTION public._saldo_negativo_desde(_cuenta uuid)
RETURNS date LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_inicial numeric;
  v_creada  date;
  v_hoy     numeric;
  v_ultimo_ok date;
  v_desde   date;
BEGIN
  SELECT saldo_inicial, created_at::date INTO v_inicial, v_creada FROM public.cuentas_financieras WHERE id = _cuenta;
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_hoy := public._saldo_cuenta(_cuenta);
  IF v_hoy IS NULL OR v_hoy >= 0 THEN RETURN NULL; END IF;

  WITH dias AS (
    SELECT m.fecha_movimiento AS dia,
           sum(CASE WHEN m.tipo = 'INGRESO' THEN m.monto ELSE -m.monto END) AS neto
      FROM public.movimientos_financieros m
     WHERE m.cuenta_id = _cuenta AND m.estatus = 'CONFIRMADO' AND m.fecha_movimiento <= CURRENT_DATE
     GROUP BY m.fecha_movimiento
  ), acum AS (
    SELECT dia, v_inicial + sum(neto) OVER (ORDER BY dia) AS saldo FROM dias
  )
  SELECT (SELECT max(dia) FROM acum WHERE saldo >= 0),
         NULL::date
    INTO v_ultimo_ok, v_desde;

  IF v_ultimo_ok IS NOT NULL THEN
    -- Primer día con movimientos después del último cierre sin negativo.
    SELECT min(m.fecha_movimiento) INTO v_desde
      FROM public.movimientos_financieros m
     WHERE m.cuenta_id = _cuenta AND m.estatus = 'CONFIRMADO' AND m.fecha_movimiento > v_ultimo_ok AND m.fecha_movimiento <= CURRENT_DATE;
  ELSIF v_inicial >= 0 THEN
    SELECT min(m.fecha_movimiento) INTO v_desde
      FROM public.movimientos_financieros m
     WHERE m.cuenta_id = _cuenta AND m.estatus = 'CONFIRMADO' AND m.fecha_movimiento <= CURRENT_DATE;
  ELSE
    -- Nunca estuvo en cero o positivo: negativa desde que existe (o desde su primer movimiento, lo que sea anterior).
    SELECT least(v_creada, coalesce(min(m.fecha_movimiento), v_creada)) INTO v_desde
      FROM public.movimientos_financieros m
     WHERE m.cuenta_id = _cuenta AND m.estatus = 'CONFIRMADO' AND m.fecha_movimiento <= CURRENT_DATE;
  END IF;
  RETURN coalesce(v_desde, CURRENT_DATE);
END;
$$;
REVOKE ALL ON FUNCTION public._saldo_negativo_desde(uuid) FROM PUBLIC, anon, authenticated;

-- ── 3. A quién se avisa y quién valida ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public._saldo_negativo_destinatario(_uid uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT _uid IS NOT NULL
     AND public.usuario_activo(_uid)
     AND NOT public.es_usuario_prueba(_uid)
     AND (   public.has_role(_uid, 'finanzas'::public.app_role)
          OR public.has_role(_uid, 'admin_financiero'::public.app_role)
          OR EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = _uid AND r.area = 'administracion')
          OR EXISTS (SELECT 1 FROM public.super_admins s WHERE s.user_id = _uid))
$$;
REVOKE ALL ON FUNCTION public._saldo_negativo_destinatario(uuid) FROM PUBLIC, anon, authenticated;

-- Quien puede ver y validar las alertas: los destinatarios, y quien opera el flujo (caja/captura) o lo administra.
CREATE OR REPLACE FUNCTION public._saldo_negativo_puede_ver(_uid uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public._saldo_negativo_destinatario(_uid)
      OR (_uid IS NOT NULL AND public.usuario_activo(_uid)
          AND (public.flujo_cap('recibe', _uid) OR public.flujo_cap('caja', _uid) OR public.flujo_es_admin(_uid)))
$$;
REVOKE ALL ON FUNCTION public._saldo_negativo_puede_ver(uuid) FROM PUBLIC, anon, authenticated;

-- ── 4. Revisión: abre, avisa y cierra alertas ───────────────────────────────
-- Sin usuario de sesión (pg_cron, SQL editor) revisa sin más; con sesión exige poder ver las alertas.
CREATE OR REPLACE FUNCTION public.saldo_negativo_revisar(_dias integer DEFAULT 3)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  c record;
  a public.cuentas_saldo_alertas%ROWTYPE;
  v_desde date;
  v_saldo numeric;
  v_dias integer;
  v_abiertas integer := 0;
  v_avisadas integer := 0;
  v_cerradas integer := 0;
  v_dest uuid;
  v_hay boolean;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public._saldo_negativo_puede_ver(auth.uid()) THEN
    RAISE EXCEPTION 'No tienes permiso para revisar los saldos de las cuentas';
  END IF;
  _dias := greatest(coalesce(_dias, 3), 0);

  FOR c IN SELECT id, nombre, moneda FROM public.cuentas_financieras WHERE activo ORDER BY nombre LOOP
    v_desde := public._saldo_negativo_desde(c.id);
    SELECT * INTO a FROM public.cuentas_saldo_alertas WHERE cuenta_id = c.id AND resuelta_at IS NULL FOR UPDATE;
    v_hay := FOUND;

    IF v_desde IS NULL THEN
      IF v_hay THEN
        UPDATE public.cuentas_saldo_alertas SET resuelta_at = now() WHERE id = a.id;
        v_cerradas := v_cerradas + 1;
      END IF;
      CONTINUE;
    END IF;

    v_saldo := public._saldo_cuenta(c.id);
    IF NOT v_hay THEN
      INSERT INTO public.cuentas_saldo_alertas (cuenta_id, negativo_desde, saldo_al_detectar)
      VALUES (c.id, v_desde, v_saldo) RETURNING * INTO a;
      v_abiertas := v_abiertas + 1;
    ELSIF a.negativo_desde <> v_desde THEN
      UPDATE public.cuentas_saldo_alertas SET negativo_desde = v_desde WHERE id = a.id RETURNING * INTO a;
    END IF;

    v_dias := CURRENT_DATE - a.negativo_desde;
    IF v_dias > _dias AND a.validado_at IS NULL
       AND (a.ultimo_aviso_at IS NULL OR a.ultimo_aviso_at <= now() - interval '3 days') THEN
      FOR v_dest IN SELECT p.id FROM public.profiles p WHERE public._saldo_negativo_destinatario(p.id) LOOP
        INSERT INTO public.notificaciones (usuario_destino, tipo, titulo, cuerpo, enlace, nombre_creador)
        VALUES (v_dest, 'saldo_negativo',
                'Saldo negativo en ' || c.nombre,
                'La cuenta «' || c.nombre || '» lleva ' || v_dias || ' días en saldo negativo (' ||
                  to_char(v_saldo, 'FM999,999,999,990.00') || ' ' || c.moneda || ', desde el ' || to_char(a.negativo_desde, 'DD/MM/YYYY') ||
                  '). Revisa si falta registrar un movimiento y valida el saldo.',
                '/finanzas/traspasos?cuenta=' || c.id, 'Control Financiero');
      END LOOP;
      UPDATE public.cuentas_saldo_alertas SET ultimo_aviso_at = now(), avisos = avisos + 1 WHERE id = a.id;
      v_avisadas := v_avisadas + 1;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('abiertas', v_abiertas, 'avisadas', v_avisadas, 'cerradas', v_cerradas);
END;
$$;
REVOKE ALL ON FUNCTION public.saldo_negativo_revisar(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.saldo_negativo_revisar(integer) TO authenticated;

-- ── 5. Consultar las alertas abiertas ───────────────────────────────────────
CREATE OR REPLACE FUNCTION public.saldo_negativo_alertas()
RETURNS TABLE (
  cuenta_id uuid, cuenta text, moneda text, saldo numeric, negativo_desde date, dias integer,
  requiere_validar boolean, avisos integer, ultimo_aviso_at timestamptz,
  validado_at timestamptz, validado_por_nombre text, validado_nota text
) LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public._saldo_negativo_puede_ver(auth.uid()) THEN
    RAISE EXCEPTION 'No tienes permiso para ver las alertas de saldo';
  END IF;
  RETURN QUERY
    SELECT a.cuenta_id, c.nombre, c.moneda, public._saldo_cuenta(a.cuenta_id), a.negativo_desde,
           (CURRENT_DATE - a.negativo_desde)::integer,
           ((CURRENT_DATE - a.negativo_desde) > 3 AND a.validado_at IS NULL),
           a.avisos, a.ultimo_aviso_at, a.validado_at, public.flujo_nombre(a.validado_por), a.validado_nota
      FROM public.cuentas_saldo_alertas a
      JOIN public.cuentas_financieras c ON c.id = a.cuenta_id
     WHERE a.resuelta_at IS NULL AND c.activo
     ORDER BY a.negativo_desde, c.nombre;
END;
$$;
REVOKE ALL ON FUNCTION public.saldo_negativo_alertas() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.saldo_negativo_alertas() TO authenticated;

-- ── 6. Validar el saldo (con nota) ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.saldo_negativo_validar(_cuenta uuid, _nota text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  a public.cuentas_saldo_alertas%ROWTYPE;
  v_nombre text;
BEGIN
  IF NOT public._saldo_negativo_destinatario(auth.uid()) AND NOT public.flujo_es_admin() THEN
    RAISE EXCEPTION 'Solo Finanzas, Administración o un superadmin valida un saldo negativo';
  END IF;
  IF length(btrim(coalesce(_nota, ''))) < 5 THEN
    RAISE EXCEPTION 'Escribe una nota que explique el saldo (por ejemplo, qué movimiento falta registrar)';
  END IF;
  SELECT * INTO a FROM public.cuentas_saldo_alertas WHERE cuenta_id = _cuenta AND resuelta_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Esa cuenta no tiene una alerta de saldo negativo abierta'; END IF;
  SELECT nombre INTO v_nombre FROM public.cuentas_financieras WHERE id = _cuenta;
  UPDATE public.cuentas_saldo_alertas
     SET validado_por = auth.uid(), validado_at = now(), validado_nota = btrim(_nota)
   WHERE id = a.id;
  PERFORM public.registrar_bitacora_compras('cobranza', 'saldo_negativo_validar', 'cuentas_saldo_alertas', a.id, v_nombre,
    jsonb_build_object('cuenta', v_nombre, 'negativo_desde', a.negativo_desde, 'nota', btrim(_nota)), false);
END;
$$;
REVOKE ALL ON FUNCTION public.saldo_negativo_validar(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.saldo_negativo_validar(uuid, text) TO authenticated;

-- ── 7. Revisión automática cada hora (si la base tiene pg_cron) ─────────────
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'saldos_negativos_revisar';
    PERFORM cron.schedule('saldos_negativos_revisar', '17 * * * *', 'SELECT public.saldo_negativo_revisar(3)');
  ELSE
    RAISE NOTICE 'pg_cron no disponible; las alertas se revisan al abrir Traspasos o Control Financiero.';
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'No se pudo programar pg_cron (%); las alertas se revisan al abrir Traspasos o Control Financiero.', SQLERRM;
END;
$cron$;

DO $postflight$
BEGIN
  IF to_regclass('public.cuentas_saldo_alertas') IS NULL THEN RAISE EXCEPTION 'No quedó la tabla cuentas_saldo_alertas.'; END IF;
  IF has_table_privilege('authenticated', 'public.cuentas_saldo_alertas', 'select')
     OR has_function_privilege('anon', 'public.saldo_negativo_revisar(integer)', 'execute')
     OR has_function_privilege('anon', 'public.saldo_negativo_validar(uuid,text)', 'execute') THEN
    RAISE EXCEPTION 'Las alertas de saldo no deben estar abiertas a anon ni a lectura directa.';
  END IF;
END $postflight$;

-- ── Verificación (solo lectura) ─────────────────────────────────────────────
-- 1) SELECT * FROM public.saldo_negativo_alertas();          -- con sesión de Finanzas/Administración
-- 2) SELECT jobname, schedule FROM cron.job WHERE jobname = 'saldos_negativos_revisar';   -- si hay pg_cron

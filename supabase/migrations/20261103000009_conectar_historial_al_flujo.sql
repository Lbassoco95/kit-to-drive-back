-- ============================================================================
-- Conecta al flujo lo que existía antes de la conexión, SIN crear dinero nuevo
-- (2026-11-03)
--
-- La conciliación (20261103000008) mostró siete elementos anteriores al espejo.
-- Aquí se conectan cinco; ninguno crea ni cambia un movimiento de Control
-- Financiero, así que los saldos no se mueven:
--
--  · CP-00002 y CP-00003 (pagos de Cobranza REVERTIDOS): su renglón del flujo se
--    crea ya RECHAZADO con el motivo de la reversión (no hay movimiento que cancelar).
--  · ING-000007, ING-000008 e ING-000009 (ingresos confirmados el 2026-11-03 desde
--    Control Financiero, antes del candado): cada uno recibe su renglón en el flujo
--    como pago de cliente ya APLICADO, ligado al movimiento que YA existe
--    (`movimiento_id`). Es historia: queda trazable desde el flujo.
--
-- NO se conectan (siguen señalados en la conciliación, a decidir con Finanzas):
--  · CP-00001 ($3,000, validado, en Caja chica) y el abono de $9,602 de CxC-000002:
--    ningún movimiento de Control Financiero los cubre. Conectarlos exigiría
--    crear su ingreso (dinero nuevo) o dejar un renglón en caja sin movimiento.
--
-- Idempotente. Para el SQL editor de Supabase; NO usar `supabase db push`.
-- Para revertir: DELETE de esos renglones del flujo (solo desde el SQL editor).
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := '{}';
BEGIN
  IF to_regclass('public.flujo_dinero') IS NULL THEN _faltan := _faltan || 'tabla flujo_dinero'::text; END IF;
  IF to_regclass('public.movimientos_financieros') IS NULL THEN _faltan := _faltan || 'tabla movimientos_financieros'::text; END IF;
  IF to_regprocedure('public._espejo_flujo_sincronizar(uuid)') IS NULL THEN _faltan := _faltan || 'función _espejo_flujo_sincronizar (20261103000002)'::text; END IF;
  IF to_regprocedure('public.flujo_conciliacion()') IS NULL THEN _faltan := _faltan || 'función flujo_conciliacion (20261103000008)'::text; END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ', ');
  END IF;
END;
$preflight$;

-- ── Renglón del flujo para un movimiento que ya existe (sin tocar el movimiento) ──
CREATE OR REPLACE FUNCTION public._conectar_movimiento_al_flujo(_mov uuid)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  m public.movimientos_financieros%ROWTYPE;
  v_id uuid;
  v_quien uuid;
  v_nota text := 'Movimiento anterior al flujo de dinero: conectado sin crear dinero nuevo';
BEGIN
  SELECT * INTO m FROM public.movimientos_financieros WHERE id = _mov;
  IF NOT FOUND OR m.estatus <> 'CONFIRMADO' THEN RETURN NULL; END IF;
  IF EXISTS (SELECT 1 FROM public.flujo_dinero WHERE movimiento_id = m.id) THEN RETURN NULL; END IF;
  v_quien := coalesce(m.recibido_por, m.created_by, m.confirmado_por);
  IF v_quien IS NULL THEN RETURN NULL; END IF;

  INSERT INTO public.flujo_dinero
    (tipo, etapa, monto, moneda, tipo_cambio, metodo_pago, fecha, contraparte_nombre, cliente_id, concepto, referencia, es_prueba,
     recibido_por, recibido_at, cuenta_id, caja_por, caja_at, caja_notas, movimiento_id,
     destino, aplicado_por, aplicado_at, aplicado_notas)
  VALUES
    (CASE WHEN m.tipo = 'EGRESO' THEN 'SALIDA'
          WHEN m.cliente_id IS NOT NULL THEN 'PAGO_CLIENTE' ELSE 'REEMBOLSO' END,
     'APLICADO', m.monto, m.moneda, m.tipo_cambio, m.metodo_pago, m.fecha_movimiento::date,
     coalesce(nullif(btrim(m.contraparte_nombre), ''), 'Sin nombre'),
     CASE WHEN m.tipo = 'EGRESO' THEN NULL ELSE m.cliente_id END,
     m.concepto, m.referencia, false,
     v_quien, m.created_at, m.cuenta_id, coalesce(m.confirmado_por, v_quien), coalesce(m.confirmado_at, m.created_at), v_nota, m.id,
     'OTRO', coalesce(m.confirmado_por, v_quien), coalesce(m.confirmado_at, m.created_at), v_nota)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public._conectar_movimiento_al_flujo(uuid) FROM PUBLIC, anon, authenticated;

-- ── Conectar ────────────────────────────────────────────────────────────────
DO $conectar$
DECLARE
  p record;
  m record;
  v_id uuid;
  v_pagos integer := 0;
  v_movs integer := 0;
BEGIN
  -- Pagos de Cobranza revertidos, reales, que no nacieron del flujo y no tienen renglón.
  FOR p IN
    SELECT id, folio FROM public.cobranza_pagos
     WHERE estatus = 'revertido' AND NOT es_prueba AND coalesce(notas, '') NOT LIKE 'Flujo de dinero %'
       AND NOT EXISTS (SELECT 1 FROM public.flujo_dinero f WHERE f.cobranza_pago_id = cobranza_pagos.id)
     ORDER BY folio
  LOOP
    PERFORM public._espejo_flujo_sincronizar(p.id);
    IF EXISTS (SELECT 1 FROM public.flujo_dinero f WHERE f.cobranza_pago_id = p.id) THEN
      v_pagos := v_pagos + 1;
      RAISE NOTICE 'Pago % conectado al flujo (rechazado, sin movimiento)', p.folio;
    END IF;
  END LOOP;

  -- Ingresos de hoy creados desde Control Financiero antes del candado.
  FOR m IN
    SELECT id, folio FROM public.movimientos_financieros
     WHERE folio IN ('ING-000007', 'ING-000008', 'ING-000009') ORDER BY folio
  LOOP
    v_id := public._conectar_movimiento_al_flujo(m.id);
    IF v_id IS NOT NULL THEN
      v_movs := v_movs + 1;
      RAISE NOTICE 'Movimiento % conectado al flujo', m.folio;
    END IF;
  END LOOP;

  RAISE NOTICE 'Conectados: % pago(s) revertido(s) y % movimiento(s)', v_pagos, v_movs;
END
$conectar$;

DO $postflight$
BEGIN
  IF EXISTS (SELECT 1 FROM public.movimientos_financieros m
              WHERE m.folio IN ('ING-000007', 'ING-000008', 'ING-000009') AND m.estatus = 'CONFIRMADO'
                AND NOT EXISTS (SELECT 1 FROM public.flujo_dinero f WHERE f.movimiento_id = m.id)) THEN
    RAISE EXCEPTION 'Quedaron movimientos sin conectar al flujo.';
  END IF;
END $postflight$;

-- ── Verificación (solo lectura) ─────────────────────────────────────────────
-- Como administrador del flujo: SELECT public.flujo_conciliacion();
-- Deben quedar solo CP-00001 (pago sin flujo) y el abono de CxC-000002.

-- Pruebas de 20261103000009_conectar_historial_al_flujo.sql (requiere pruebas_pendientes_martin).
\set ON_ERROR_STOP 1
SET client_min_messages = warning;
\echo 'H1. Un movimiento anterior al flujo se conecta sin crear dinero y sin tocar el movimiento'
BEGIN;
SELECT set_config('request.jwt.claim.sub', '', true);
INSERT INTO public.movimientos_financieros (id, tipo, estatus, concepto, monto, moneda, fecha_movimiento, metodo_pago, cuenta_id, contraparte_tipo, cliente_id, contraparte_nombre, created_by, confirmado_por, confirmado_at, categoria)
VALUES ('33333333-3333-3333-3333-333333333333', 'INGRESO', 'CONFIRMADO', 'X100', 1234.50, 'MXN', current_date, 'TRANSFERENCIA',
        (SELECT id FROM public.cuentas_financieras WHERE nombre = 'Banco principal'), 'CLIENTE', public._m_cli(), 'Cliente MM',
        '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', now(), 'Venta de refacciones');
DO $$ DECLARE
  antes_movs integer := (SELECT count(*) FROM public.movimientos_financieros);
  antes_saldo numeric := (SELECT coalesce(sum(monto), 0) FROM public.movimientos_financieros);
  v uuid; f public.flujo_dinero%ROWTYPE; mov_antes jsonb;
BEGIN
  mov_antes := (SELECT to_jsonb(m) - 'updated_at' FROM public.movimientos_financieros m WHERE id = '33333333-3333-3333-3333-333333333333');
  v := public._conectar_movimiento_al_flujo('33333333-3333-3333-3333-333333333333');
  ASSERT v IS NOT NULL, 'se creó el renglón';
  SELECT * INTO f FROM public.flujo_dinero WHERE id = v;
  ASSERT f.tipo = 'PAGO_CLIENTE' AND f.etapa = 'APLICADO' AND f.monto = 1234.50 AND f.destino = 'OTRO'
     AND f.movimiento_id = '33333333-3333-3333-3333-333333333333' AND f.cliente_id = public._m_cli(), format('%s', to_jsonb(f));
  ASSERT (SELECT count(*) FROM public.movimientos_financieros) = antes_movs, 'no se crearon movimientos';
  ASSERT (SELECT coalesce(sum(monto), 0) FROM public.movimientos_financieros) = antes_saldo, 'los saldos no se movieron';
  ASSERT (SELECT to_jsonb(m) - 'updated_at' FROM public.movimientos_financieros m WHERE id = '33333333-3333-3333-3333-333333333333') = mov_antes, 'el movimiento no cambió';
  -- Idempotente.
  ASSERT public._conectar_movimiento_al_flujo('33333333-3333-3333-3333-333333333333') IS NULL, 'no se duplica';
  -- Ya no aparece en la conciliación como «movimiento sin flujo».
  ASSERT NOT EXISTS (SELECT 1 FROM public.movimientos_financieros m WHERE m.id = '33333333-3333-3333-3333-333333333333'
                       AND NOT EXISTS (SELECT 1 FROM public.flujo_dinero x WHERE x.movimiento_id = m.id)), 'conectado';
END $$;
ROLLBACK;

\echo 'H2. Un pago revertido anterior al espejo queda RECHAZADO en el flujo, sin movimiento'
BEGIN;
SELECT set_config('request.jwt.claim.sub', '', true);
ALTER TABLE public.cobranza_pagos DISABLE TRIGGER trg_espejo_flujo_pago;
INSERT INTO public.cobranza_pagos (folio, cliente_id, fecha, monto, forma, estatus, capturado_por, validado_por, validado_at, revertido_por, revertido_at, motivo_reversion)
VALUES ('CP-HIST-1', public._m_cli(), current_date, 500, 'deposito', 'revertido', '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', now(), '00000000-0000-0000-0000-0000000000b1', now(), 'Prueba de historia');
ALTER TABLE public.cobranza_pagos ENABLE TRIGGER trg_espejo_flujo_pago;
DO $$ DECLARE f public.flujo_dinero%ROWTYPE; antes integer := (SELECT count(*) FROM public.movimientos_financieros); BEGIN
  PERFORM public._espejo_flujo_sincronizar((SELECT id FROM public.cobranza_pagos WHERE folio = 'CP-HIST-1'));
  SELECT * INTO f FROM public.flujo_dinero WHERE cobranza_pago_id = (SELECT id FROM public.cobranza_pagos WHERE folio = 'CP-HIST-1');
  ASSERT FOUND AND f.etapa = 'RECHAZADO' AND f.motivo_rechazo = 'Prueba de historia' AND f.movimiento_id IS NULL, format('%s', to_jsonb(f));
  ASSERT (SELECT count(*) FROM public.movimientos_financieros) = antes, 'no crea movimientos';
END $$;
ROLLBACK;
\echo 'OK: conectar historial'

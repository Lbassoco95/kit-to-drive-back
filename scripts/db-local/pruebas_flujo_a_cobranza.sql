-- Pruebas de 20261104000001_flujo_alimenta_cobranza.sql (requiere pruebas_flujo_dinero.sql: usuarios y ayudantes _t_*).
\set ON_ERROR_STOP 1
SET client_min_messages = warning;
CREATE TABLE IF NOT EXISTS public._fc_ids (clave text PRIMARY KEY, id uuid);
GRANT SELECT, INSERT ON public._fc_ids TO authenticated;
DELETE FROM public._fc_ids;

\echo 'FC1. Registrar en el flujo crea de inmediato el pago REGISTRADO en Cobranza'
BEGIN;
SELECT public._t_como('prueba.compras@dazon.demo');
DO $$ DECLARE v jsonb; p public.cobranza_pagos%ROWTYPE; f public.flujo_dinero%ROWTYPE; BEGIN
  v := public.flujo_recibir('PAGO_CLIENTE', 700, 'MXN', 'EFECTIVO', current_date, 'Juan Pérez', public._t_cli('TST-C02'));
  INSERT INTO public._fc_ids VALUES ('f1', (v->>'id')::uuid);
  SELECT * INTO f FROM public.flujo_dinero WHERE id = (v->>'id')::uuid;
  ASSERT f.cobranza_pago_id IS NOT NULL, 'el flujo quedó ligado a su pago';
  SELECT * INTO p FROM public.cobranza_pagos WHERE id = f.cobranza_pago_id;
  ASSERT p.estatus = 'registrado' AND p.monto = 700 AND p.cliente_id = public._t_cli('TST-C02') AND p.notas = 'Flujo de dinero ' || f.folio, format('%s', to_jsonb(p));
  ASSERT p.es_prueba = f.es_prueba, 'misma marca de prueba';
END $$;
RESET ROLE;
-- Cobranza no puede validarlo ni revertirlo por su cuenta (el trigger actúa sobre cualquier rol).
DO $$ DECLARE p public.cobranza_pagos%ROWTYPE; BEGIN
  SELECT p2.* INTO p FROM public.cobranza_pagos p2 JOIN public.flujo_dinero f ON f.cobranza_pago_id = p2.id WHERE f.id = (SELECT id FROM public._fc_ids WHERE clave = 'f1');
  BEGIN UPDATE public.cobranza_pagos SET estatus = 'validado' WHERE id = p.id; RAISE EXCEPTION 'debió bloquear';
  EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM LIKE '%viene del Flujo de dinero%', SQLERRM; END;
  BEGIN INSERT INTO public.cobranza_aplicaciones (tipo, pago_id, remision_id, monto, created_by, es_prueba)
          SELECT 'pago', p.id, r.id, 1, auth.uid(), true FROM public.remisiones_refacciones r LIMIT 1;
        RAISE EXCEPTION 'debió bloquear';
  EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM LIKE '%viene del Flujo de dinero%', SQLERRM; END;
END $$;
COMMIT;

\echo 'FC2. Entrar a caja valida el pago; aplicar usa ese mismo pago (no crea otro)'
BEGIN;
SELECT public._t_como('prueba.almacen@dazon.demo');
SELECT public.flujo_confirmar_caja((SELECT id FROM public._fc_ids WHERE clave = 'f1'), (SELECT id FROM public._t_cuenta_mxn()));
RESET ROLE;
DO $$ DECLARE p public.cobranza_pagos%ROWTYPE; BEGIN
  SELECT p2.* INTO p FROM public.cobranza_pagos p2 JOIN public.flujo_dinero f ON f.cobranza_pago_id = p2.id WHERE f.id = (SELECT id FROM public._fc_ids WHERE clave = 'f1');
  ASSERT p.estatus = 'validado' AND p.conciliado AND p.cuenta_destino IS NOT NULL AND p.validado_por IS NOT NULL, format('%s', to_jsonb(p));
  INSERT INTO public._fc_ids VALUES ('p1', p.id);
END $$;
SELECT public._t_como('prueba.finanzas@dazon.demo');
SELECT public.flujo_aplicar((SELECT id FROM public._fc_ids WHERE clave = 'f1'), 'OTRO', '[]', 'Anticipo');
RESET ROLE;
DO $$ DECLARE f public.flujo_dinero%ROWTYPE; BEGIN
  SELECT * INTO f FROM public.flujo_dinero WHERE id = (SELECT id FROM public._fc_ids WHERE clave = 'f1');
  ASSERT f.etapa = 'APLICADO' AND f.cobranza_pago_id = (SELECT id FROM public._fc_ids WHERE clave = 'p1'), 'sigue el mismo pago';
  ASSERT (SELECT count(*) FROM public.cobranza_pagos WHERE notas = 'Flujo de dinero ' || f.folio) = 1, 'un solo pago en Cobranza';
  ASSERT (SELECT coalesce(sum(monto), 0) FROM public.cobranza_saldos_favor WHERE pago_origen_id = f.cobranza_pago_id) = 700, 'el anticipo quedó como saldo a favor';
END $$;
COMMIT;

\echo 'FC3. Rechazar en el flujo revierte el pago en Cobranza'
BEGIN;
SELECT public._t_como('prueba.compras@dazon.demo');
DO $$ DECLARE v jsonb; BEGIN
  v := public.flujo_recibir('PAGO_CLIENTE', 300, 'MXN', 'EFECTIVO', current_date, 'Juan Pérez', public._t_cli('TST-C02'));
  INSERT INTO public._fc_ids VALUES ('f2', (v->>'id')::uuid);
END $$;
RESET ROLE;
SELECT public._t_como('prueba.almacen@dazon.demo');
SELECT public.flujo_rechazar((SELECT id FROM public._fc_ids WHERE clave = 'f2'), 'Cliente se arrepintió');
RESET ROLE;
DO $$ DECLARE p public.cobranza_pagos%ROWTYPE; BEGIN
  SELECT p2.* INTO p FROM public.cobranza_pagos p2 JOIN public.flujo_dinero f ON f.cobranza_pago_id = p2.id WHERE f.id = (SELECT id FROM public._fc_ids WHERE clave = 'f2');
  ASSERT p.estatus = 'revertido' AND p.motivo_reversion LIKE '%Cliente se arrepintió%', format('%s', to_jsonb(p));
END $$;
COMMIT;

\echo 'FC4. Un pago que nace en Cobranza sigue manejándose en Cobranza (el espejo no cambia)'
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.flujo_dinero WHERE cobranza_pago_id IS NOT NULL AND cxc_abono_id IS NOT NULL) = 0, 'sin cruces';
END $$;
\echo 'OK: flujo → Cobranza'

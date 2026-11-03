-- ============================================================================
-- Pruebas de 20261103000008_flujo_aplicacion_y_conciliacion.sql
-- Requiere antes pruebas_pendientes_martin.sql y pruebas_abono_flujo.sql.
-- ============================================================================
\set ON_ERROR_STOP 1
SET client_min_messages = warning;
CREATE TABLE IF NOT EXISTS public._p_ids (clave text PRIMARY KEY, id uuid);
GRANT SELECT, INSERT ON public._p_ids TO authenticated;
DELETE FROM public._p_ids;

\echo 'P1. Pago aplicado en Cobranza: el flujo muestra lo aplicado, el saldo a favor y a qué remisión'
BEGIN;
SELECT public._m_como('vendedor.a@mm.test');
DO $$ DECLARE v jsonb; BEGIN
  v := public.crear_remision_refacciones(public._m_cli(), 'APL1', NULL,
    jsonb_build_array(jsonb_build_object('producto_id', public._m_prod('MM-ART-1'), 'cantidad', 3)),
    '{"tipo_envio":"recoge","tipo_pago":"credito"}'::jsonb);
  INSERT INTO public._p_ids VALUES ('rem', (v->>'id')::uuid);
END $$;
RESET ROLE;
SELECT public._m_surtir((SELECT id FROM public._p_ids WHERE clave = 'rem'));
SELECT public._m_como('martin.real@ejemplo.mx');
DO $$ DECLARE v jsonb; BEGIN
  v := public.registrar_pago_cobranza(jsonb_build_object('cliente_id', public._m_cli(), 'monto', 500, 'forma', 'efectivo', 'evidencia_path', 'x/v.pdf'));
  INSERT INTO public._p_ids VALUES ('pago', (v->>'id')::uuid);
END $$;
RESET ROLE;
SELECT public._m_como('finanzas.real@ejemplo.mx');
SELECT public.validar_pago_cobranza((SELECT id FROM public._p_ids WHERE clave = 'pago'), true, NULL);
DO $$ DECLARE a jsonb; e text; BEGIN
  SELECT aplicacion, etapa INTO a, e FROM public.v_flujo_dinero WHERE cobranza_pago_id = (SELECT id FROM public._p_ids WHERE clave = 'pago');
  ASSERT e = 'EN_CAJA' AND (a->>'aplicado')::numeric = 0 AND (a->>'saldo_favor')::numeric = 0, format('antes de aplicar: %s %s', e, a);
END $$;
RESET ROLE;
SELECT public._m_como('martin.real@ejemplo.mx');
SELECT public.aplicar_pago_cobranza((SELECT id FROM public._p_ids WHERE clave = 'pago'),
  jsonb_build_array(jsonb_build_object('remision_id', (SELECT id FROM public._p_ids WHERE clave = 'rem'), 'monto', 300)));
RESET ROLE;
SELECT public._m_como('finanzas.real@ejemplo.mx');
DO $$ DECLARE a jsonb; e text; BEGIN
  SELECT aplicacion, etapa INTO a, e FROM public.v_flujo_dinero WHERE cobranza_pago_id = (SELECT id FROM public._p_ids WHERE clave = 'pago');
  ASSERT e = 'APLICADO', format('etapa %s', e);
  ASSERT (a->>'aplicado')::numeric = 300 AND (a->>'saldo_favor')::numeric = 200, format('montos %s', a);
  ASSERT jsonb_array_length(a->'destinos') = 1 AND a->'destinos'->0->>'folio' LIKE 'RF-%' AND (a->'destinos'->0->>'monto')::numeric = 300, format('destinos %s', a);
END $$;
RESET ROLE;
COMMIT;

\echo 'P2. Revertir la aplicación en Cobranza: el flujo vuelve a mostrar lo aplicado al día'
BEGIN;
SELECT public._m_como('martin.real@ejemplo.mx');
SELECT public.revertir_aplicacion_cobranza((SELECT id FROM public.cobranza_aplicaciones WHERE pago_id = (SELECT id FROM public._p_ids WHERE clave = 'pago') AND revertida_at IS NULL LIMIT 1), 'Aplicada por error en la prueba');
RESET ROLE;
SELECT public._m_como('finanzas.real@ejemplo.mx');
DO $$ DECLARE a jsonb; BEGIN
  SELECT aplicacion INTO a FROM public.v_flujo_dinero WHERE cobranza_pago_id = (SELECT id FROM public._p_ids WHERE clave = 'pago');
  ASSERT (a->>'aplicado')::numeric = 0 AND jsonb_array_length(a->'destinos') = 0, format('tras revertir %s', a);
END $$;
RESET ROLE;
COMMIT;

\echo 'P3. Abono de Crédito: el flujo muestra la cuenta por cobrar a la que se aplicó'
BEGIN;
SELECT public._m_como('finanzas.real@ejemplo.mx');
DO $$ DECLARE a jsonb; BEGIN
  SELECT aplicacion INTO a FROM public.v_flujo_dinero WHERE cxc_abono_id IS NOT NULL ORDER BY created_at LIMIT 1;
  ASSERT a IS NOT NULL AND (a->>'aplicado')::numeric > 0 AND jsonb_array_length(a->'destinos') = 1, format('abono %s', a);
END $$;
RESET ROLE;
-- Quien no lleva el flujo no ve el resumen.
SELECT public._m_como('vendedor.a@mm.test');
DO $$ BEGIN ASSERT public.flujo_resumen_aplicacion((SELECT id FROM public._p_ids WHERE clave = 'pago')) IS NULL, 'sin permisos de flujo no se ve'; END $$;
RESET ROLE;
COMMIT;

\echo 'P4. Conciliación: solo administradores; detecta lo que no está conectado'
BEGIN;
SELECT public._m_como('finanzas.real@ejemplo.mx');
DO $$ BEGIN PERFORM public._m_falla($q$SELECT public.flujo_conciliacion()$q$, 'Solo un administrador'); END $$;
RESET ROLE;
-- Un pago «anterior al espejo»: se inserta con el trigger apagado.
ALTER TABLE public.cobranza_pagos DISABLE TRIGGER trg_espejo_flujo_pago;
INSERT INTO public.cobranza_pagos (folio, cliente_id, fecha, monto, forma, estatus, capturado_por)
VALUES ('CP-LEGADO-1', public._m_cli(), current_date, 77, 'efectivo', 'registrado', '00000000-0000-0000-0000-0000000000b1');
ALTER TABLE public.cobranza_pagos ENABLE TRIGGER trg_espejo_flujo_pago;
SELECT public._m_como('global@mm.test');
DO $$ DECLARE r jsonb; BEGIN
  r := public.flujo_conciliacion();
  ASSERT (r->>'total')::int >= 1, format('%s', r);
  ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'problemas') x WHERE x->>'tipo' = 'pago_cobranza_sin_flujo' AND x->>'folio' = 'CP-LEGADO-1'), 'detecta el pago sin flujo';
  ASSERT NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'problemas') x WHERE x->>'tipo' = 'etapa_desfasada'), 'los espejos están en su etapa';
END $$;
RESET ROLE;
ROLLBACK;
\echo 'OK: aplicación y conciliación'

-- Pruebas de 20261106000003_flujo_corregir.sql
-- Requiere pruebas_pendientes_martin.sql, pruebas_abono_flujo.sql y pruebas_autoaplica.sql (usuarios reales, caja de Finanzas, admin global@mm.test).
\set ON_ERROR_STOP 1
SET client_min_messages = warning;
DROP TABLE IF EXISTS public._co_ids; CREATE TABLE public._co_ids (clave text PRIMARY KEY, id uuid);
GRANT SELECT, INSERT ON public._co_ids TO authenticated;

\echo 'CO1. Quien registró corrige su pago mientras está Recibido: se propaga a Control Financiero y a Cobranza'
BEGIN;
SELECT set_config('kit.t_cli2', public._m_cli()::text, true);
SELECT public._m_como('martin.real@ejemplo.mx');
DO $$ DECLARE v jsonb; BEGIN
  v := public.flujo_registrar_movimiento(jsonb_build_object('tipo', 'INGRESO', 'concepto', 'Abono', 'monto', 500, 'metodo_pago', 'TRANSFERENCIA',
    'referencia', 'SPEI-1', 'contraparte_tipo', 'CLIENTE', 'cliente_id', current_setting('kit.t_cli2'), 'contraparte_nombre', 'Cliente MM'));
  INSERT INTO public._co_ids VALUES ('f1', (v->>'id')::uuid);
END $$;
DO $$ DECLARE r jsonb; BEGIN
  PERFORM public._m_falla(format($q$SELECT public.flujo_corregir(%L, '{"monto": 800}'::jsonb, '')$q$, (SELECT id FROM public._co_ids WHERE clave = 'f1')), 'motivo');
  PERFORM public._m_falla(format($q$SELECT public.flujo_corregir(%L, '{"monto": 500}'::jsonb, 'sin cambios')$q$, (SELECT id FROM public._co_ids WHERE clave = 'f1')), 'ningún cambio');
  PERFORM public._m_falla(format($q$SELECT public.flujo_corregir(%L, '{"monto": 0}'::jsonb, 'cero')$q$, (SELECT id FROM public._co_ids WHERE clave = 'f1')), 'mayor a cero');
  r := public.flujo_corregir((SELECT id FROM public._co_ids WHERE clave = 'f1'),
    jsonb_build_object('monto', 800, 'concepto', 'Abono corregido', 'categoria', 'Venta de refacciones', 'referencia', 'SPEI-2'), 'Capturé mal el monto');
  ASSERT r->>'pago_nuevo' IS NOT NULL, 'nació un pago nuevo en Cobranza';
END $$;
RESET ROLE;
DO $$ DECLARE f public.flujo_dinero%ROWTYPE; m public.movimientos_financieros%ROWTYPE; BEGIN
  SELECT * INTO f FROM public.flujo_dinero WHERE id = (SELECT id FROM public._co_ids WHERE clave = 'f1');
  ASSERT f.monto = 800 AND f.concepto = 'Abono corregido' AND f.referencia = 'SPEI-2' AND f.corregido_at IS NOT NULL AND f.correccion_motivo = 'Capturé mal el monto', format('%s', to_jsonb(f));
  SELECT * INTO m FROM public.movimientos_financieros WHERE id = f.movimiento_id;
  ASSERT m.monto = 800 AND m.estatus = 'PENDIENTE' AND m.categoria = 'Venta de refacciones' AND m.concepto = 'Abono corregido', 'el ingreso por confirmar se corrigió';
  ASSERT (SELECT monto || estatus FROM public.cobranza_pagos WHERE id = f.cobranza_pago_id) = '800.00registrado', 'pago nuevo con el monto bueno';
  ASSERT (SELECT count(*) FROM public.cobranza_pagos WHERE notas = 'Flujo de dinero ' || f.folio AND estatus = 'revertido') = 1, 'el pago anterior quedó revertido';
  ASSERT (SELECT count(*) FROM public.cobranza_pagos WHERE notas = 'Flujo de dinero ' || f.folio AND estatus = 'registrado') = 1, 'un solo pago vigente';
  ASSERT EXISTS (SELECT 1 FROM public.bitacora_compras_inventario WHERE accion = 'flujo_corregir' AND entidad_id = f.id), 'bitácora con antes y después';
END $$;
COMMIT;

\echo 'CO2. Otra persona no corrige lo ajeno; tras caja, el dueño ya no; un administrador sí (lo descriptivo, no el dinero)'
BEGIN;
SELECT set_config('kit.t_caja', (SELECT id::text FROM public.cuentas_financieras WHERE tipo::text = 'BANCO' AND moneda = 'MXN' AND activo ORDER BY nombre LIMIT 1), true);
SELECT public._m_como('finanzas.real@ejemplo.mx');
DO $$ BEGIN
  PERFORM public._m_falla(format($q$SELECT public.flujo_corregir(%L, '{"concepto": "x"}'::jsonb, 'intento ajeno')$q$, (SELECT id FROM public._co_ids WHERE clave = 'f1')), 'Solo quien lo registró');
END $$;
SELECT public.flujo_confirmar_caja((SELECT id FROM public._co_ids WHERE clave = 'f1'), current_setting('kit.t_caja')::uuid);
RESET ROLE;
SELECT public._m_como('martin.real@ejemplo.mx');
DO $$ BEGIN
  PERFORM public._m_falla(format($q$SELECT public.flujo_corregir(%L, '{"concepto": "x"}'::jsonb, 'ya en caja')$q$, (SELECT id FROM public._co_ids WHERE clave = 'f1')), 'Solo quien lo registró');
END $$;
RESET ROLE;
SELECT public._m_como('global@mm.test');
DO $$ BEGIN
  PERFORM public._m_falla(format($q$SELECT public.flujo_corregir(%L, '{"fecha_movimiento": "2026-01-01"}'::jsonb, 'cambiar fecha')$q$, (SELECT id FROM public._co_ids WHERE clave = 'f1')), 'ya entró a caja');
  PERFORM public.flujo_corregir((SELECT id FROM public._co_ids WHERE clave = 'f1'), '{"concepto": "Abono octubre", "factura_folio": "F-9"}'::jsonb, 'Aclarar concepto');
END $$;
RESET ROLE;
DO $$ DECLARE f public.flujo_dinero%ROWTYPE; BEGIN
  SELECT * INTO f FROM public.flujo_dinero WHERE id = (SELECT id FROM public._co_ids WHERE clave = 'f1');
  ASSERT f.monto = 800 AND f.concepto = 'Abono octubre' AND f.factura_folio = 'F-9', 'se corrigió lo descriptivo';
  ASSERT (SELECT concepto || factura_folio || estatus::text FROM public.movimientos_financieros WHERE id = f.movimiento_id) = 'Abono octubreF-9CONFIRMADO', 'el movimiento confirmado también';
END $$;
COMMIT;

\echo 'CO3. Un egreso se corrige; un movimiento rechazado no'
BEGIN;
SELECT public._m_como('martin.real@ejemplo.mx');
DO $$ DECLARE v jsonb; BEGIN
  v := public.flujo_registrar_movimiento(jsonb_build_object('tipo', 'EGRESO', 'concepto', 'Papelería', 'monto', 80, 'metodo_pago', 'EFECTIVO', 'contraparte_nombre', 'Papelería Z'));
  INSERT INTO public._co_ids VALUES ('e1', (v->>'id')::uuid);
  PERFORM public.flujo_corregir((v->>'id')::uuid, '{"monto": 95, "contraparte_nombre": "Papelería Y"}'::jsonb, 'Precio real');
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT monto FROM public.flujo_dinero WHERE id = (SELECT id FROM public._co_ids WHERE clave = 'e1')) = 95, 'egreso corregido';
  ASSERT (SELECT m.monto FROM public.movimientos_financieros m JOIN public.flujo_dinero f ON f.movimiento_id = m.id WHERE f.id = (SELECT id FROM public._co_ids WHERE clave = 'e1')) = 95, 'el egreso por confirmar también';
END $$;
SELECT public._m_como('finanzas.real@ejemplo.mx');
SELECT public.flujo_rechazar((SELECT id FROM public._co_ids WHERE clave = 'e1'), 'No procede');
RESET ROLE;
SELECT public._m_como('global@mm.test');
DO $$ BEGIN
  PERFORM public._m_falla(format($q$SELECT public.flujo_corregir(%L, '{"monto": 10}'::jsonb, 'ya rechazado')$q$, (SELECT id FROM public._co_ids WHERE clave = 'e1')), 'rechazado');
END $$;
RESET ROLE;
COMMIT;
\echo 'CO4. Después de caja, un administrador corrige el monto: se ajusta el movimiento confirmado y el pago de Cobranza'
BEGIN;
SELECT public._m_como('global@mm.test');
DO $$ DECLARE r jsonb; f public.flujo_dinero%ROWTYPE; BEGIN
  r := public.flujo_corregir((SELECT id FROM public._co_ids WHERE clave = 'f1'), '{"monto": 850}'::jsonb, 'Faltaban 50 pesos');
  ASSERT r->>'pago_nuevo' IS NOT NULL, 'nació el pago nuevo';
END $$;
RESET ROLE;
DO $$ DECLARE f public.flujo_dinero%ROWTYPE; BEGIN
  SELECT * INTO f FROM public.flujo_dinero WHERE id = (SELECT id FROM public._co_ids WHERE clave = 'f1');
  ASSERT f.monto = 850 AND f.etapa = 'EN_CAJA', 'el flujo con el monto nuevo';
  ASSERT (SELECT monto || estatus::text FROM public.movimientos_financieros WHERE id = f.movimiento_id) = '850.00CONFIRMADO', 'el movimiento confirmado también';
  ASSERT (SELECT monto || estatus FROM public.cobranza_pagos WHERE id = f.cobranza_pago_id) = '850.00validado', 'pago nuevo validado con el monto bueno';
  ASSERT (SELECT count(*) FROM public.cobranza_pagos WHERE notas = 'Flujo de dinero ' || f.folio AND estatus = 'validado') = 1, 'un solo pago vigente';
END $$;
SELECT public._m_como('martin.real@ejemplo.mx');
DO $$ BEGIN
  PERFORM public._m_falla(format($q$SELECT public.flujo_corregir(%L, '{"monto": 10}'::jsonb, 'no soy admin')$q$, (SELECT id FROM public._co_ids WHERE clave = 'f1')), 'Solo quien lo registró');
END $$;
RESET ROLE;
COMMIT;

\echo 'CO5. Un egreso ya aplicado se corrige de monto; un pago aplicado no (primero se revierte la aplicación)'
BEGIN;
SELECT set_config('kit.t_efec', (SELECT id::text FROM public.cuentas_financieras WHERE tipo::text = 'EFECTIVO' AND moneda = 'MXN' AND activo ORDER BY nombre LIMIT 1), true);
SELECT set_config('kit.t_banco', (SELECT id::text FROM public.cuentas_financieras WHERE tipo::text = 'BANCO' AND moneda = 'MXN' AND activo ORDER BY nombre LIMIT 1), true);
SELECT set_config('kit.t_cli2', public._m_cli()::text, true);
SELECT public._m_como('martin.real@ejemplo.mx');
DO $$ DECLARE v jsonb; BEGIN
  v := public.flujo_registrar_movimiento(jsonb_build_object('tipo', 'EGRESO', 'concepto', 'Gasto', 'monto', 200, 'metodo_pago', 'EFECTIVO', 'contraparte_nombre', 'Taller'));
  INSERT INTO public._co_ids VALUES ('e2', (v->>'id')::uuid);
  v := public.flujo_registrar_movimiento(jsonb_build_object('tipo', 'INGRESO', 'concepto', 'Anticipo', 'monto', 300, 'metodo_pago', 'TRANSFERENCIA', 'referencia', 'SPEI-5',
    'contraparte_tipo', 'CLIENTE', 'cliente_id', current_setting('kit.t_cli2'), 'contraparte_nombre', 'Cliente MM'));
  INSERT INTO public._co_ids VALUES ('p2', (v->>'id')::uuid);
END $$;
RESET ROLE;
SELECT public._m_como('finanzas.real@ejemplo.mx');
SELECT public.flujo_confirmar_caja((SELECT id FROM public._co_ids WHERE clave = 'e2'), current_setting('kit.t_efec')::uuid);
SELECT public.flujo_confirmar_caja((SELECT id FROM public._co_ids WHERE clave = 'p2'), current_setting('kit.t_banco')::uuid);
RESET ROLE;
SELECT public._m_como('martin.real@ejemplo.mx');
SELECT public.flujo_aplicar((SELECT id FROM public._co_ids WHERE clave = 'e2'), 'GASTO', '[]', NULL);
SELECT public.flujo_aplicar((SELECT id FROM public._co_ids WHERE clave = 'p2'), 'OTRO', '[]', 'Saldo a favor');
RESET ROLE;
SELECT public._m_como('global@mm.test');
DO $$ BEGIN
  PERFORM public.flujo_corregir((SELECT id FROM public._co_ids WHERE clave = 'e2'), '{"monto": 250}'::jsonb, 'Ticket real');
  PERFORM public._m_falla(format($q$SELECT public.flujo_corregir(%L, '{"monto": 350}'::jsonb, 'ya aplicado')$q$, (SELECT id FROM public._co_ids WHERE clave = 'p2')), 'ya está aplicado');
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT m.monto FROM public.movimientos_financieros m JOIN public.flujo_dinero f ON f.movimiento_id = m.id WHERE f.id = (SELECT id FROM public._co_ids WHERE clave = 'e2')) = 250, 'el egreso aplicado quedó con el monto nuevo';
  ASSERT (SELECT monto FROM public.flujo_dinero WHERE id = (SELECT id FROM public._co_ids WHERE clave = 'p2')) = 300, 'el pago aplicado no cambió';
END $$;
COMMIT;
\echo 'OK: corregir'

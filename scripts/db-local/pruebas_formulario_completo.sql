-- Pruebas de 20261105000001_flujo_formulario_completo_y_cuentas.sql
-- Requiere pruebas_pendientes_martin.sql y pruebas_abono_flujo.sql (usuarios reales, caja de Finanzas, admin global).
\set ON_ERROR_STOP 1
SET client_min_messages = warning;
CREATE TABLE IF NOT EXISTS public._fm_ids (clave text PRIMARY KEY, id uuid);
GRANT SELECT, INSERT ON public._fm_ids TO authenticated;
DELETE FROM public._fm_ids;

\echo 'FM1. Ingreso con el formulario completo: nace en el flujo y al entrar a caja el movimiento conserva todo el detalle'
BEGIN;
SELECT set_config('kit.t_banco', (SELECT id::text FROM public.cuentas_financieras WHERE tipo::text = 'BANCO' AND moneda = 'MXN' AND activo ORDER BY nombre LIMIT 1), true),
       set_config('kit.t_prov', (SELECT id::text FROM public.proveedores LIMIT 1), true);
SELECT public._m_como('martin.real@ejemplo.mx');
DO $$ DECLARE v jsonb; BEGIN
  v := public.flujo_registrar_movimiento(jsonb_build_object(
    'tipo', 'INGRESO', 'concepto', 'Venta de contado', 'categoria', 'Venta de refacciones', 'descripcion', 'Detalle largo',
    'monto', '1500.50', 'moneda', 'MXN', 'fecha_movimiento', current_date::text, 'metodo_pago', 'TRANSFERENCIA',
    'cuenta_id', current_setting('kit.t_banco'),
    'referencia', 'REF-77', 'contraparte_tipo', 'CLIENTE', 'cliente_id', public._m_cli()::text, 'contraparte_nombre', 'Cliente MM',
    'via', 'INTERMEDIARIO', 'intermediario_nombre', 'Chofer Juan', 'factura_folio', 'F-123', 'factura_uuid', 'UUID-1', 'factura_rfc', 'XAXX010101000'));
  INSERT INTO public._fm_ids VALUES ('f1', (v->>'id')::uuid);
END $$;
RESET ROLE;
DO $$ DECLARE f public.flujo_dinero%ROWTYPE; BEGIN
  SELECT * INTO f FROM public.flujo_dinero WHERE id = (SELECT id FROM public._fm_ids WHERE clave = 'f1');
  ASSERT f.tipo = 'INGRESO' AND f.etapa = 'RECIBIDO' AND f.monto = 1500.50 AND f.categoria = 'Venta de refacciones' AND f.cuenta_prevista_id IS NOT NULL
     AND f.via = 'INTERMEDIARIO' AND f.factura_folio = 'F-123' AND f.cliente_id = public._m_cli() AND NOT f.requiere_comprobacion, format('%s', to_jsonb(f));
  ASSERT f.cobranza_pago_id IS NULL, 'un ingreso general no crea pago en Cobranza';
END $$;
COMMIT;
BEGIN;
SELECT public._m_como('finanzas.real@ejemplo.mx');
SELECT public.flujo_confirmar_caja((SELECT id FROM public._fm_ids WHERE clave = 'f1'),
  (SELECT cuenta_prevista_id FROM public.flujo_dinero WHERE id = (SELECT id FROM public._fm_ids WHERE clave = 'f1')));
RESET ROLE;
DO $$ DECLARE m public.movimientos_financieros%ROWTYPE; BEGIN
  SELECT m2.* INTO m FROM public.movimientos_financieros m2 JOIN public.flujo_dinero f ON f.movimiento_id = m2.id WHERE f.id = (SELECT id FROM public._fm_ids WHERE clave = 'f1');
  ASSERT m.tipo = 'INGRESO' AND m.estatus = 'CONFIRMADO' AND m.categoria = 'Venta de refacciones' AND m.descripcion = 'Detalle largo'
     AND m.contraparte_tipo::text = 'CLIENTE' AND m.cliente_id = public._m_cli() AND m.via::text = 'INTERMEDIARIO' AND m.intermediario_nombre = 'Chofer Juan'
     AND m.factura_folio = 'F-123' AND m.factura_rfc = 'XAXX010101000' AND m.cuenta_id IS NOT NULL, format('%s', to_jsonb(m));
END $$;
COMMIT;

\echo 'FM2. Egreso en efectivo con intermediario queda por comprobar; moneda extranjera pide tipo de cambio'
BEGIN;
INSERT INTO public.proveedores (nombre_comercial) VALUES ('Proveedor de prueba FM');
SELECT set_config('kit.t_prov', (SELECT id::text FROM public.proveedores WHERE nombre_comercial = 'Proveedor de prueba FM'), true);
SELECT public._m_como('martin.real@ejemplo.mx');
DO $$ DECLARE v jsonb; f public.flujo_dinero%ROWTYPE; BEGIN
  v := public.flujo_registrar_movimiento(jsonb_build_object('tipo', 'EGRESO', 'concepto', 'Compra de material', 'monto', 300, 'metodo_pago', 'EFECTIVO',
    'contraparte_tipo', 'PROVEEDOR', 'proveedor_id', current_setting('kit.t_prov'), 'contraparte_nombre', 'Proveedor X',
    'via', 'INTERMEDIARIO', 'intermediario_nombre', 'Chofer Luis'));
  SELECT * INTO f FROM public.flujo_dinero WHERE id = (v->>'id')::uuid;
  ASSERT f.tipo = 'SALIDA' AND f.requiere_comprobacion AND f.intermediario_nombre = 'Chofer Luis' AND f.proveedor_id IS NOT NULL, format('%s', to_jsonb(f));
  PERFORM public._m_falla($q$SELECT public.flujo_registrar_movimiento('{"tipo":"INGRESO","concepto":"x","monto":10,"moneda":"USD","contraparte_nombre":"x"}'::jsonb)$q$, 'tipo de cambio');
  PERFORM public._m_falla($q$SELECT public.flujo_registrar_movimiento('{"tipo":"INGRESO","concepto":"x","monto":0,"contraparte_nombre":"x"}'::jsonb)$q$, 'mayor a cero');
  PERFORM public._m_falla($q$SELECT public.flujo_registrar_movimiento('{"tipo":"INGRESO","monto":10,"contraparte_nombre":"x"}'::jsonb)$q$, 'concepto');
  PERFORM public._m_falla($q$SELECT public.flujo_registrar_movimiento('{"tipo":"INGRESO","concepto":"x","monto":10,"contraparte_tipo":"CLIENTE","contraparte_nombre":"x"}'::jsonb)$q$, 'Elige el cliente');
END $$;
RESET ROLE;
COMMIT;

\echo 'FM3. Dar de alta una caja o cuenta: solo administradores; quien registra la ve'
BEGIN;
SELECT public._m_como('martin.real@ejemplo.mx');
SELECT public._m_falla($q$SELECT public.flujo_crear_cuenta('Juoshui', 'BANCO')$q$, 'administrador');
DO $$ BEGIN ASSERT (SELECT count(*) FROM public.flujo_cuentas()) >= 1, 'quien registra ve las cuentas'; END $$;
RESET ROLE;
SELECT public._m_como('global@mm.test');
SELECT public.flujo_crear_cuenta('Juoshui', 'BANCO', 'MXN', 'Juoshui', '0001');
SELECT public.flujo_crear_cuenta('Banorte', 'banco');
SELECT public._m_falla($q$SELECT public.flujo_crear_cuenta('juoshui', 'BANCO')$q$, 'Ya existe');
SELECT public._m_falla($q$SELECT public.flujo_crear_cuenta('', 'BANCO')$q$, 'nombre');
SELECT public._m_falla($q$SELECT public.flujo_crear_cuenta('Zeta', 'CRIPTO')$q$, 'efectivo o una cuenta de banco');
RESET ROLE;
DO $$ BEGIN
  ASSERT EXISTS (SELECT 1 FROM public.cuentas_financieras WHERE nombre = 'Juoshui' AND tipo::text = 'BANCO' AND banco = 'Juoshui'), 'cuenta creada';
  ASSERT EXISTS (SELECT 1 FROM public.cuentas_financieras WHERE nombre = 'Banorte' AND tipo::text = 'BANCO'), 'segunda cuenta';
END $$;
COMMIT;

\echo 'FM3b. Las categorías del formulario las ve quien registra'
BEGIN;
SELECT public._m_como('martin.real@ejemplo.mx');
DO $$ BEGIN ASSERT (SELECT count(*) FROM public.flujo_categorias('INGRESO')) >= 1, 'categorías de ingreso'; ASSERT (SELECT count(*) FROM public.flujo_categorias('EGRESO')) >= 1, 'categorías de egreso'; END $$;
RESET ROLE;
COMMIT;

\echo 'FM4. Los clientes del flujo se piden por tramos y salen todos'
BEGIN;
SELECT public._m_como('martin.real@ejemplo.mx');
DO $$ DECLARE total integer; a integer; b integer; BEGIN
  SELECT count(*) INTO total FROM public.flujo_clientes(0, 1000);
  SELECT count(*) INTO a FROM public.flujo_clientes(0, 1);
  ASSERT total >= 1 AND a = 1, 'límite';
  IF total > 1 THEN
    SELECT count(*) INTO b FROM public.flujo_clientes(1, 1000);
    ASSERT b = total - 1, 'desde';
    ASSERT (SELECT id FROM public.flujo_clientes(0, 1)) <> (SELECT id FROM public.flujo_clientes(1, 1)), 'tramos distintos';
  END IF;
  ASSERT (SELECT count(*) FROM public.flujo_clientes()) = total, 'sin argumentos sigue funcionando';
END $$;
RESET ROLE;
COMMIT;
\echo 'OK: formulario completo'

-- ============================================================================
-- Pruebas de 20261103000007_cancelar_remision_regresa_inventario.sql
-- Requiere antes pruebas_pendientes_martin.sql (usuarios y ayudantes).
-- Uso:
--   1) psql -f este archivo con :fase=0  → crea una remisión cancelada con el comportamiento VIEJO
--      (antes de aplicar la migración 7), para probar el relleno.
--   2) aplicar la migración 7
--   3) psql -f este archivo con :fase=1  → comprueba el relleno y el comportamiento nuevo.
-- ============================================================================
\set ON_ERROR_STOP 1
SET client_min_messages = warning;
CREATE TABLE IF NOT EXISTS public._i_ids (clave text PRIMARY KEY, id uuid, n integer);
GRANT SELECT, INSERT ON public._i_ids TO authenticated;

\if :fase0
\echo 'I0. Remisión cancelada con el comportamiento viejo (queda con piezas surtidas)'
DELETE FROM public._i_ids;
BEGIN;
UPDATE public.almacen_refacciones_productos SET stock = 100 WHERE codigo_nuevo = 'MM-ART-1';
SELECT public._m_como('vendedor.a@mm.test');
DO $$ DECLARE v jsonb; BEGIN
  v := public.crear_remision_refacciones(public._m_cli(), 'VIEJA', NULL,
    jsonb_build_array(jsonb_build_object('producto_id', public._m_prod('MM-ART-1'), 'cantidad', 6)),
    '{"tipo_envio":"recoge","tipo_pago":"anticipado"}'::jsonb);
  INSERT INTO public._i_ids VALUES ('vieja', (v->>'id')::uuid, 6);
END $$;
RESET ROLE;
SELECT public._m_surtir((SELECT id FROM public._i_ids WHERE clave = 'vieja'));
SELECT public._m_como('vendedor.a@mm.test');
SELECT public.cancelar_remision_refacciones((SELECT id FROM public._i_ids WHERE clave = 'vieja'), 'Cancelada con el comportamiento viejo');
RESET ROLE;
DO $$ BEGIN
  ASSERT public._m_stock('MM-ART-1') = 94, 'con el comportamiento viejo las 6 piezas siguen fuera';
  ASSERT (SELECT sum(cantidad_surtida) FROM public.remision_refaccion_items WHERE remision_id = (SELECT id FROM public._i_ids WHERE clave = 'vieja')) = 6, 'sigue con piezas surtidas';
END $$;
COMMIT;
\else
\echo 'I1. El relleno regresó al inventario las piezas de la remisión ya cancelada'
DO $$ BEGIN
  ASSERT public._m_stock('MM-ART-1') = 100, format('el relleno regresa las 6 piezas (stock %s)', public._m_stock('MM-ART-1'));
  ASSERT (SELECT coalesce(sum(cantidad_surtida), 0) FROM public.remision_refaccion_items WHERE remision_id = (SELECT id FROM public._i_ids WHERE clave = 'vieja')) = 0, 'sin piezas surtidas';
  ASSERT EXISTS (SELECT 1 FROM public.almacen_refacciones_movimientos m WHERE m.documento_tipo = 'devolucion' AND m.cantidad = 6 AND m.documento_folio = (SELECT folio FROM public.remisiones_refacciones WHERE id = (SELECT id FROM public._i_ids WHERE clave = 'vieja'))), 'devolución en el kárdex';
  ASSERT (SELECT count(*) FROM public.remision_refaccion_eventos WHERE remision_id = (SELECT id FROM public._i_ids WHERE clave = 'vieja') AND accion = 'correccion') >= 1, 'evento de corrección';
END $$;

\echo 'I2. Cancelar ahora regresa lo surtido, solo una vez, y lo apartado se suelta sin mover inventario'
BEGIN;
SELECT public._m_como('vendedor.a@mm.test');
DO $$ DECLARE v jsonb; BEGIN
  v := public.crear_remision_refacciones(public._m_cli(), 'NUEVA1', NULL,
    jsonb_build_array(jsonb_build_object('producto_id', public._m_prod('MM-ART-1'), 'cantidad', 5),
                      jsonb_build_object('producto_id', public._m_prod('MM-ART-2'), 'cantidad', 3)),
    '{"tipo_envio":"recoge","tipo_pago":"anticipado"}'::jsonb);
  INSERT INTO public._i_ids VALUES ('n1', (v->>'id')::uuid, 8);
  v := public.crear_remision_refacciones(public._m_cli(), 'NUEVA2', NULL,
    jsonb_build_array(jsonb_build_object('producto_id', public._m_prod('MM-ART-1'), 'cantidad', 4)),
    '{"tipo_envio":"recoge","tipo_pago":"anticipado"}'::jsonb);
  INSERT INTO public._i_ids VALUES ('n2', (v->>'id')::uuid, 4);
END $$;
RESET ROLE;
-- NUEVA1 se surte; NUEVA2 solo queda apartada.
SELECT public._m_surtir((SELECT id FROM public._i_ids WHERE clave = 'n1'));
DO $$ BEGIN
  ASSERT public._m_stock('MM-ART-1') = 95 AND public._m_stock('MM-ART-2') = 97, 'salieron 5 y 3';
END $$;
SELECT public._m_como('vendedor.a@mm.test');
SELECT public.cancelar_remision_refacciones((SELECT id FROM public._i_ids WHERE clave = 'n1'), 'Cliente ya no la quiere');
RESET ROLE;
DO $$ DECLARE rid uuid := (SELECT id FROM public._i_ids WHERE clave = 'n1'); BEGIN
  ASSERT public._m_stock('MM-ART-1') = 100 AND public._m_stock('MM-ART-2') = 100, 'regresaron las 8 piezas';
  ASSERT (SELECT etapa FROM public.remisiones_refacciones WHERE id = rid) = 'cancelada';
  ASSERT (SELECT bool_and(estatus = 'cancelada' AND cantidad_surtida = 0 AND cantidad_bloqueada = 0) FROM public.remision_refaccion_items WHERE remision_id = rid), 'partidas canceladas y en cero';
  ASSERT (SELECT count(*) FROM public.almacen_refacciones_movimientos WHERE documento_tipo = 'devolucion' AND documento_id = rid) = 2, 'una devolución por partida';
  ASSERT EXISTS (SELECT 1 FROM public.remision_refaccion_eventos WHERE remision_id = rid AND accion = 'cancelar_remision' AND detalle LIKE '%Regresaron 8 pieza(s)%'), 'el evento dice cuántas regresaron';
  ASSERT EXISTS (SELECT 1 FROM public.remision_refaccion_correcciones WHERE remision_id = rid AND motivo = 'Cliente ya no la quiere'), 'la corrección guarda el motivo';
END $$;
SELECT public._m_como('vendedor.a@mm.test');
DO $$ BEGIN
  PERFORM public._m_falla(format($q$SELECT public.cancelar_remision_refacciones(%L, 'otra vez')$q$, (SELECT id FROM public._i_ids WHERE clave = 'n1')), 'ya está cancelada');
END $$;
SELECT public.cancelar_remision_refacciones((SELECT id FROM public._i_ids WHERE clave = 'n2'), 'Se cancela el apartado');
RESET ROLE;
DO $$ BEGIN
  ASSERT public._m_stock('MM-ART-1') = 100, 'cancelar solo apartado no mueve el inventario';
  ASSERT NOT EXISTS (SELECT 1 FROM public.almacen_refacciones_movimientos WHERE documento_id = (SELECT id FROM public._i_ids WHERE clave = 'n2')), 'sin movimientos';
  ASSERT public.stock_bloqueado_producto(public._m_prod('MM-ART-1')) = 0, 'lo apartado quedó suelto';
END $$;
ROLLBACK;

\echo 'I3. Una remisión cancelada o corregida no se elimina (su historial es inmutable) y el aviso lo explica'
BEGIN;
SELECT public._m_como('admin.comercial@mm.test');
DO $$ BEGIN
  PERFORM public._m_falla(format($q$SELECT public.eliminar_remision_refacciones(%L, 'intento sobre una cancelada')$q$, (SELECT id FROM public._i_ids WHERE clave = 'vieja')), 'historial no se borra');
END $$;
ROLLBACK;
\echo 'OK: cancelación e inventario'
\endif

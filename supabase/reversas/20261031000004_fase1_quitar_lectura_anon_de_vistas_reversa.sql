-- ============================================================================
-- REVERSA: devuelve a anon sus permisos sobre las 16 vistas, como estaban el 25 oct 2026 (después del punto 1)
--
-- Fase 1 de seguridad de la base de producción (docs/seguridad/). Reversa del punto 4.
-- ============================================================================
-- ============================================================================
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON public.v_almacen_refacciones TO anon;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON public.v_almacen_refacciones_movimientos TO anon;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON public.v_clientes_credito TO anon;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON public.v_cobranza_pagos TO anon;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON public.v_cobranza_remisiones TO anon;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON public.v_cobranza_saldos_favor TO anon;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON public.v_compra_refacciones_contenedor TO anon;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON public.v_estado_cuenta_cliente TO anon;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON public.v_flujo_dinero TO anon;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON public.v_movimientos_financieros TO anon;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON public.v_remision_refaccion_ordenes TO anon;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON public.v_reporte_pagos TO anon;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON public.v_reporte_pipeline TO anon;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON public.v_reporte_produccion TO anon;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON public.v_reporte_remisiones TO anon;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON public.v_saldos_cuentas TO anon;

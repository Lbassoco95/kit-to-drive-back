-- ============================================================================
-- REVERSA de la unificación (20261030000001) y de bancos por empresa (20261031000001).
-- Devuelve las puertas al estado anterior: políticas y privilegios del libro, abonos, cuentas y cobranza,
-- y las funciones registrar/validar/aplicar_pago_cobranza. NO borra tablas ni columnas nuevas (no pierden datos);
-- las funciones nuevas del flujo se quedan (no estorban). Para restaurar DATOS, usa el respaldo
-- (schema respaldo_20261027), tabla por tabla, solo si hace falta.
-- Para el SQL editor de Supabase. Idempotente.
-- ============================================================================
BEGIN;

-- 1. Guardias (triggers) de las dos migraciones.
DROP TRIGGER IF EXISTS a_libro_guardia ON public.movimientos_financieros;
DROP TRIGGER IF EXISTS a_cxc_abonos_guardia ON public.cxc_abonos;
DROP TRIGGER IF EXISTS a_cxc_guardia ON public.cuentas_por_cobrar;
DROP TRIGGER IF EXISTS a_cuenta_guardia ON public.cuentas_financieras;
DROP TRIGGER IF EXISTS a_cuenta_catalogo_guardia ON public.cuentas_financieras;

-- 2. Restricción de la cuenta sin número completo (la anterior no existía).
ALTER TABLE public.cuentas_financieras DROP CONSTRAINT IF EXISTS cuentas_sin_numero_completo;

-- 3. Privilegios y políticas anteriores.
GRANT INSERT, UPDATE, DELETE ON public.movimientos_financieros, public.cuentas_financieras, public.cxc_abonos,
  public.cobranza_pagos, public.cobranza_aplicaciones, public.cobranza_saldos_favor TO authenticated;

DROP POLICY IF EXISTS movimientos_insert ON public.movimientos_financieros;
CREATE POLICY movimientos_insert ON public.movimientos_financieros FOR INSERT TO authenticated
  WITH CHECK (es_finanzas(auth.uid()) AND (created_by = auth.uid()));
DROP POLICY IF EXISTS movimientos_update_admin ON public.movimientos_financieros;
CREATE POLICY movimientos_update_admin ON public.movimientos_financieros FOR UPDATE TO authenticated
  USING (es_finanzas_admin(auth.uid())) WITH CHECK (es_finanzas_admin(auth.uid()));
DROP POLICY IF EXISTS movimientos_update_propio ON public.movimientos_financieros;
CREATE POLICY movimientos_update_propio ON public.movimientos_financieros FOR UPDATE TO authenticated
  USING (has_role(auth.uid(), 'finanzas'::app_role) AND created_by = auth.uid() AND estatus = ANY (ARRAY['BORRADOR'::mov_estatus, 'PENDIENTE'::mov_estatus]))
  WITH CHECK (has_role(auth.uid(), 'finanzas'::app_role) AND created_by = auth.uid() AND estatus = ANY (ARRAY['BORRADOR'::mov_estatus, 'PENDIENTE'::mov_estatus]));
DROP POLICY IF EXISTS movimientos_delete ON public.movimientos_financieros;
CREATE POLICY movimientos_delete ON public.movimientos_financieros FOR DELETE TO authenticated USING (es_finanzas_admin(auth.uid()));

DROP POLICY IF EXISTS cuentas_write ON public.cuentas_financieras;
CREATE POLICY cuentas_write ON public.cuentas_financieras FOR ALL TO authenticated
  USING (es_finanzas_admin(auth.uid())) WITH CHECK (es_finanzas_admin(auth.uid()));

DROP POLICY IF EXISTS cxc_abonos_insert ON public.cxc_abonos;
CREATE POLICY cxc_abonos_insert ON public.cxc_abonos FOR INSERT TO authenticated
  WITH CHECK (es_finanzas(auth.uid()) AND created_by = auth.uid());
DROP POLICY IF EXISTS cxc_abonos_delete ON public.cxc_abonos;
CREATE POLICY cxc_abonos_delete ON public.cxc_abonos FOR DELETE TO authenticated USING (es_finanzas_admin(auth.uid()));

-- 4. Funciones de cobranza que la unificación cerró.
GRANT EXECUTE ON FUNCTION public.registrar_pago_cobranza(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.validar_pago_cobranza(uuid, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.aplicar_pago_cobranza(uuid, jsonb, boolean, text) TO authenticated;

COMMIT;

SELECT (SELECT count(*) FROM pg_policies WHERE tablename = 'movimientos_financieros' AND cmd IN ('INSERT', 'UPDATE', 'DELETE')) AS politicas_libro,
       has_table_privilege('authenticated', 'public.movimientos_financieros', 'INSERT') AS libro_escribe,
       has_function_privilege('authenticated', 'public.registrar_pago_cobranza(jsonb)', 'execute') AS registrar_abierto;

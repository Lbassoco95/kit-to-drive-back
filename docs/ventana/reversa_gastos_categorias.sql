-- REVERSA de la migración 20261101000001 (gastos, categorías, es_prueba, históricos). No borra datos ni columnas.
-- Cierra las funciones nuevas, devuelve la escritura de categorías al administrador y reactiva «Mantenimiento».
-- Las tablas/columnas nuevas quedan (inofensivas). Para restaurar datos, usar el respaldo (schema respaldo_20261027).
BEGIN;
REVOKE EXECUTE ON FUNCTION public.flujo_capturar_gasto(numeric, text, text, date, text, text, text, text, numeric, text, uuid, uuid, jsonb),
  public.flujo_confirmar_gasto(uuid, uuid, text), public.flujo_entregar_gasto(uuid, text), public.flujo_rechazar_gasto(uuid, text),
  public.flujo_corregir_gasto(uuid, jsonb) FROM authenticated;
GRANT INSERT, UPDATE, DELETE ON public.categorias_financieras TO authenticated;
DROP POLICY IF EXISTS categorias_write ON public.categorias_financieras;
CREATE POLICY categorias_write ON public.categorias_financieras FOR ALL TO authenticated
  USING (es_finanzas_admin(auth.uid())) WITH CHECK (es_finanzas_admin(auth.uid()));
UPDATE public.categorias_financieras SET activo = true WHERE tipo = 'EGRESO' AND nombre = 'Mantenimiento' AND NOT es_prueba;
COMMIT;

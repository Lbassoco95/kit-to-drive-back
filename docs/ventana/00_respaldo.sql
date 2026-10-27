-- Paso 0 · Respaldo antes de cualquier migración (solo lectura sobre lo existente; crea un schema aparte).
-- Para el SQL editor de Supabase. Se puede correr una sola vez; si el schema ya existe, falla a propósito (no pisa un respaldo).
CREATE SCHEMA respaldo_20261027;
CREATE TABLE respaldo_20261027.movimientos_financieros AS SELECT * FROM public.movimientos_financieros;
CREATE TABLE respaldo_20261027.cuentas_financieras     AS SELECT * FROM public.cuentas_financieras;
CREATE TABLE respaldo_20261027.cobranza_pagos          AS SELECT * FROM public.cobranza_pagos;
CREATE TABLE respaldo_20261027.cxc_abonos              AS SELECT * FROM public.cxc_abonos;
CREATE TABLE respaldo_20261027.flujo_dinero            AS SELECT * FROM public.flujo_dinero;
-- Para que el respaldo no quede expuesto a la API: sin acceso para los roles de la app.
REVOKE ALL ON SCHEMA respaldo_20261027 FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL TABLES IN SCHEMA respaldo_20261027 FROM PUBLIC, anon, authenticated;

-- Verificación: cada par de conteos debe ser igual (al día de hoy: 4 · 3 · 6 · 1 · 9).
SELECT 'movimientos_financieros' t, (SELECT count(*) FROM public.movimientos_financieros) vivo, (SELECT count(*) FROM respaldo_20261027.movimientos_financieros) respaldo
UNION ALL SELECT 'cuentas_financieras', (SELECT count(*) FROM public.cuentas_financieras), (SELECT count(*) FROM respaldo_20261027.cuentas_financieras)
UNION ALL SELECT 'cobranza_pagos', (SELECT count(*) FROM public.cobranza_pagos), (SELECT count(*) FROM respaldo_20261027.cobranza_pagos)
UNION ALL SELECT 'cxc_abonos', (SELECT count(*) FROM public.cxc_abonos), (SELECT count(*) FROM respaldo_20261027.cxc_abonos)
UNION ALL SELECT 'flujo_dinero', (SELECT count(*) FROM public.flujo_dinero), (SELECT count(*) FROM respaldo_20261027.flujo_dinero);

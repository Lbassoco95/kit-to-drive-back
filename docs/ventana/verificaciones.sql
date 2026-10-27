-- Verificaciones de solo lectura de la ventana (las corro yo con la conexión de lectura; Polo puede pegarlas también).
-- V1 · estado base (antes y después de cada paso: los 5 conteos y el saldo por cuenta NO deben cambiar).
SELECT (SELECT count(*) FROM movimientos_financieros) mov, (SELECT count(*) FROM cuentas_financieras) cuentas,
       (SELECT count(*) FROM cobranza_pagos) pagos, (SELECT count(*) FROM cxc_abonos) abonos, (SELECT count(*) FROM flujo_dinero) flujos;
SELECT nombre, saldo_actual FROM v_saldos_cuentas ORDER BY orden;          -- Caja chica 48,050 al día de hoy
-- V2 · tras la migración 20261030000001 (unificación)
SELECT count(*) FILTER (WHERE origen IS NULL) AS sin_origen, count(*) FILTER (WHERE origen = 'HISTORICO_DIRECTO') AS historicos, count(*) FILTER (WHERE origen = 'FLUJO') AS del_flujo FROM movimientos_financieros;
SELECT has_table_privilege('authenticated', 'public.movimientos_financieros', 'INSERT') AS libro_escribe,   -- debe ser false
       has_function_privilege('authenticated', 'public.registrar_pago_cobranza(jsonb)', 'execute') AS registrar_abierto,  -- false
       to_regprocedure('public.flujo_revertir(uuid,text,boolean)') IS NOT NULL AS tiene_revertir;       -- true
-- V3 · tras la migración 20261031000001 (bancos por empresa y búsqueda)
SELECT (SELECT count(*) FROM empresas_grupo) empresas, (SELECT count(*) FROM cuentas_financieras WHERE empresa_id IS NULL) cuentas_sin_empresa;
SELECT to_regprocedure('public.flujo_recibir(text,numeric,text,text,date,text,uuid,text,text,numeric,text,jsonb,uuid)') IS NOT NULL AS recibir_con_empresa,
       to_regprocedure('public.flujo_buscar_remisiones(uuid,boolean,text,text,text,date,date,numeric,numeric,integer,integer)') IS NOT NULL AS busqueda;
SELECT policyname FROM pg_policies WHERE schemaname = 'storage' AND policyname LIKE 'evidencias_flujo%';
-- V4 · tras asignar empresas a las 3 cuentas (desde la pestaña «Cuentas bancarias»)
SELECT c.nombre, e.nombre AS empresa, c.tipo, c.banco, c.ultimos4, s.saldo_actual FROM cuentas_financieras c LEFT JOIN empresas_grupo e ON e.id = c.empresa_id JOIN v_saldos_cuentas s ON s.id = c.id ORDER BY c.orden;
SELECT entidad, accion, count(*) FROM catalogo_bancos_bitacora GROUP BY 1, 2;

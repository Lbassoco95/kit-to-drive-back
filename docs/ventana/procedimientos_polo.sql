-- ============================================================================
-- PROCEDIMIENTOS PARA CORRER EN LA VENTANA (los ejecuta Polo; yo no ejecuto nada en producción)
-- Se corren en el SQL editor de Supabase, en este orden, DESPUÉS de las migraciones, el respaldo y el despliegue.
-- Cada bloque es una transacción: si algo falla, no queda nada a medias.
-- El SQL editor no tiene sesión de usuario: cada bloque «actúa como» un administrador con set_config (queda su nombre en la bitácora).
--   · Para empresas, cuentas, categorías y permisos: actúa Polo (administrador).
--   · Para cancelar/resolver/reclasificar: NO puede actuar quien capturó el movimiento (regla de toda persona).
--       ING-000004 lo capturó Martin, ING-000005 lo capturó Polo, EGR-000004 lo capturó Martin → actúa Jair (administrador financiero).
-- ============================================================================

-- ── P1 · Perfiles (también se pueden asignar desde «Flujo de dinero → Permisos del flujo», sin SQL) ──────────────
BEGIN;
SELECT set_config('request.jwt.claim.sub', (SELECT id::text FROM auth.users WHERE email = 'leo.bassoco@yoltik.mx'), true);
-- Luna: se le quitan Recibe, Caja y Aplica; queda solo con confirmación de gastos.
SELECT public.flujo_asignar_capacidad(id, 'recibe', false), public.flujo_asignar_capacidad(id, 'caja', false), public.flujo_asignar_capacidad(id, 'aplica', false),
       public.flujo_asignar_capacidad(id, 'confirma_gasto', true) FROM auth.users WHERE email = 'zdwaicoco@gmail.com';
-- Jair: recibe ingresos (ya lo tiene) y captura gastos. Leti: caja (ya la tiene; también registra la entrega de efectivo de gastos).
SELECT public.flujo_asignar_capacidad(id, 'captura_gasto', true) FROM auth.users WHERE email = 'jair.sanchez@dazon.mx';
-- Martin: aplica (ya la tiene).
SELECT p.nombre, c.recibe, c.caja, c.aplica, c.captura_gasto, c.confirma_gasto
  FROM public.flujo_listar_capacidades() c JOIN (SELECT id, coalesce(nombre_completo, email) AS nombre FROM public.profiles) p ON p.id = c.user_id
 WHERE c.recibe OR c.caja OR c.aplica OR c.captura_gasto OR c.confirma_gasto ORDER BY 1;
COMMIT;

-- ── P2 · Carga de empresas y cuentas reales (completar los <datos> que dé Polo; NO se inventa nada) ─────────────
-- Las tres cuentas actuales conservan id, historial y saldo; solo se les asigna empresa (y banco y últimos 4 si son de banco).
BEGIN;
SELECT set_config('request.jwt.claim.sub', (SELECT id::text FROM auth.users WHERE email = 'leo.bassoco@yoltik.mx'), true);
SELECT public.empresa_guardar(NULL, '<NOMBRE EMPRESA 1>', '<RAZÓN SOCIAL 1>');
-- SELECT public.empresa_guardar(NULL, '<NOMBRE EMPRESA 2>', '<RAZÓN SOCIAL 2>');   -- repetir por empresa
-- Asignar las 3 cuentas existentes (por nombre) a su empresa:
SELECT public.cuenta_guardar(c.id, (SELECT id FROM public.empresas_grupo WHERE nombre = '<NOMBRE EMPRESA 1>' AND NOT es_prueba),
       c.nombre, NULL, 'EFECTIVO', c.moneda, NULL, true, NULL, 0, 'Asignación de empresa a la cuenta existente')
  FROM public.cuentas_financieras c WHERE c.nombre IN ('Caja chica', 'Caja dólares') AND NOT c.es_prueba;
SELECT public.cuenta_guardar(c.id, (SELECT id FROM public.empresas_grupo WHERE nombre = '<NOMBRE EMPRESA 1>' AND NOT es_prueba),
       c.nombre, '<BANCO>', 'BANCO', c.moneda, '<ÚLTIMOS 4>', true, NULL, 0, 'Asignación de empresa, banco y últimos 4 a la cuenta existente')
  FROM public.cuentas_financieras c WHERE c.nombre = 'Banco principal' AND NOT c.es_prueba;
-- Cuentas nuevas (banco en USD, banco en pesos adicional, cajas de otra empresa…). Los últimos 4 dígitos, nunca el número completo:
SELECT public.cuenta_guardar(NULL, (SELECT id FROM public.empresas_grupo WHERE nombre = '<NOMBRE EMPRESA 1>' AND NOT es_prueba),
       '<NOMBRE CUENTA, p. ej. Banco USD>', '<BANCO>', 'BANCO', 'USD', '<ÚLTIMOS 4 DE LA CUENTA NUEVA>', true, NULL, 0, 'Alta de cuenta');
-- Verificación: los saldos no cambiaron.
SELECT c.nombre, e.nombre AS empresa, c.tipo, c.moneda, c.banco, c.ultimos4, s.saldo_actual
  FROM public.cuentas_financieras c LEFT JOIN public.empresas_grupo e ON e.id = c.empresa_id JOIN public.v_saldos_cuentas s ON s.id = c.id
 WHERE NOT c.es_prueba ORDER BY c.orden;
COMMIT;

-- ── P3 · Cancelar ING-000005 (duplicado de ING-000006 / FD-000009) e ING-000004 (DEMO) ──────────────────────────
BEGIN;
SELECT set_config('request.jwt.claim.sub', (SELECT id::text FROM auth.users WHERE email = 'jair.sanchez@dazon.mx'), true);
SELECT public.movimiento_historico_resolver((SELECT id FROM public.movimientos_financieros WHERE folio = 'ING-000005'), 'CANCELAR', NULL,
       'duplicado de ING-000006 / FD-000009');
SELECT public.movimiento_historico_resolver((SELECT id FROM public.movimientos_financieros WHERE folio = 'ING-000004'), 'CANCELAR', NULL,
       'movimiento de demostración (DEMO), no es dinero real');   -- ← Polo: confirma o cambia este motivo antes de correr
SELECT folio, estatus, monto, motivo_cancelacion FROM public.movimientos_financieros WHERE folio IN ('ING-000004', 'ING-000005', 'ING-000006') ORDER BY folio;
COMMIT;

-- ── P4 · Regularizar EGR-000004 (8,664.41 USD pagados por transferencia): entrada de USD + reclasificación a un banco en USD ──
-- Requiere P2 (la cuenta de banco en USD ya dada de alta). Datos que da Polo: banco/últimos 4 (P2), origen de los dólares, monto y fecha reales, tipo de cambio.
-- Paso 1: la entrada de USD que respalda el pago, con fecha y cuenta reales. _afecta_totales = false si es saldo inicial (no es ingreso del periodo);
--         true si es un ingreso real del periodo.
BEGIN;
SELECT set_config('request.jwt.claim.sub', (SELECT id::text FROM auth.users WHERE email = 'jair.sanchez@dazon.mx'), true);
SELECT public.movimiento_regularizar(
  'INGRESO', <MONTO USD>, 'USD', <TIPO DE CAMBIO>, '<AAAA-MM-DD>',
  (SELECT id FROM public.cuentas_financieras WHERE nombre = '<NOMBRE CUENTA BANCO USD>' AND NOT es_prueba), 'TRANSFERENCIA',
  '<CONCEPTO, p. ej. Entrada de USD que respalda el pago del contenedor>', 'Otro ingreso', '<ORIGEN DE LOS DÓLARES / CONTRAPARTE>', '<REFERENCIA>',
  '<MOTIVO (mín. 10 caracteres): regulariza la entrada de dólares que respalda EGR-000004>', NULL, false);
-- Paso 2: el pago salió del banco en USD, no de la caja de efectivo: dos contra-movimientos (no tocan EGR-000004 ni suman en totales).
SELECT public.movimiento_reclasificar_cuenta((SELECT id FROM public.movimientos_financieros WHERE folio = 'EGR-000004'),
  (SELECT id FROM public.cuentas_financieras WHERE nombre = '<NOMBRE CUENTA BANCO USD>' AND NOT es_prueba),
  'EGR-000004 se pagó por transferencia desde el banco en USD; estaba registrado por error en Caja dólares (efectivo)');
-- Verificación: Caja dólares en 0 (ya no negativa), el banco en USD refleja entrada − pago, y EGR-000004 sigue intacto.
SELECT c.nombre, s.saldo_actual FROM public.cuentas_financieras c JOIN public.v_saldos_cuentas s ON s.id = c.id WHERE c.moneda = 'USD' AND NOT c.es_prueba;
SELECT folio, estatus, monto, moneda, tipo_cambio, origen, cuenta_id FROM public.movimientos_financieros WHERE folio = 'EGR-000004';
COMMIT;

-- ── P5 · Regularizar CP-00001 (3,000 cobrados y validados fuera del flujo) ─────────────────────────────────────
-- Datos que da Polo: cuenta (de efectivo, si se cobró en efectivo) y fecha real del cobro.
BEGIN;
SELECT set_config('request.jwt.claim.sub', (SELECT id::text FROM auth.users WHERE email = 'jair.sanchez@dazon.mx'), true);
SELECT public.cobranza_pago_regularizar((SELECT id FROM public.cobranza_pagos WHERE folio = 'CP-00001'),
  (SELECT id FROM public.cuentas_financieras WHERE nombre = '<NOMBRE CUENTA>' AND NOT es_prueba), '<AAAA-MM-DD>',
  'Cobrado y validado en cobranza antes del flujo de dinero; se regulariza con la cuenta y la fecha reales');
SELECT folio, estatus, monto, fecha_movimiento, origen, regularizacion_motivo FROM public.movimientos_financieros WHERE regulariza_pago_id IS NOT NULL;
COMMIT;

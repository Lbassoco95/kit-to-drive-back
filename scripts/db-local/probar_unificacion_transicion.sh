#!/usr/bin/env bash
# Actualización: una base CON datos anteriores a la unificación recibe la migración.
# Comprueba que nada se pierde, que lo directo queda marcado como histórico y que repetirla no rompe.
#   PGHOST=127.0.0.1 PGUSER=postgres scripts/db-local/probar_unificacion_transicion.sh
set -euo pipefail
RAIZ="$(cd "$(dirname "$0")/../.." && pwd)"
DB="${1:-kit_pruebas_transicion}"
export PGUSER="${PGUSER:-postgres}"
MIG="$RAIZ/supabase/migrations/20261030000001_unificar_control_financiero_flujo.sql"

SOLO_HASTA=20261028000001_flujo_regla_cuenta_por_metodo "$RAIZ/scripts/db-local/aplicar_migraciones.sh" "$DB"

psql -X -q -v ON_ERROR_STOP=1 -d "$DB" <<'SQL'
-- Datos de antes: movimiento directo, pago de cobranza directo, abono directo, y un flujo con su libro.
INSERT INTO auth.users (id, email, raw_app_meta_data) VALUES
  ('00000000-0000-0000-0000-0000000000c1', 'recibe.real@ejemplo.mx', '{"created_via_admin": "true"}'),
  ('00000000-0000-0000-0000-0000000000c2', 'caja.real@ejemplo.mx', '{"created_via_admin": "true"}');
INSERT INTO public.clientes (id, nombre_comercial, razon_social, codigo_erp, es_prueba)
  VALUES ('00000000-0000-0000-0000-0000000000d1', 'Cliente Histórico', 'HIST SA', 'HIST-1', false);
INSERT INTO public.movimientos_financieros (id, tipo, estatus, concepto, monto, moneda, fecha_movimiento, metodo_pago, contraparte_tipo, contraparte_nombre, cuenta_id)
  SELECT '00000000-0000-0000-0000-0000000000e1', 'INGRESO', 'CONFIRMADO', 'DEMO directo', 45000, 'MXN', current_date, 'EFECTIVO', 'OTRO', 'Demo', id
    FROM public.cuentas_financieras WHERE moneda = 'MXN' AND tipo = 'EFECTIVO' LIMIT 1;
INSERT INTO public.movimientos_financieros (id, tipo, estatus, concepto, monto, moneda, fecha_movimiento, metodo_pago, contraparte_tipo, contraparte_nombre, cuenta_id, cliente_id)
  SELECT '00000000-0000-0000-0000-0000000000e2', 'INGRESO', 'CONFIRMADO', 'Del flujo', 300, 'MXN', current_date, 'EFECTIVO', 'CLIENTE', 'Cliente', id, '00000000-0000-0000-0000-0000000000d1'
    FROM public.cuentas_financieras WHERE moneda = 'MXN' AND tipo = 'EFECTIVO' LIMIT 1;
INSERT INTO public.cobranza_pagos (folio, cliente_id, fecha, monto, forma, estatus, es_prueba)
  VALUES ('CP-HIST-1', '00000000-0000-0000-0000-0000000000d1', current_date, 3000, 'transferencia', 'validado', false);
INSERT INTO public.cuentas_por_cobrar (id, cliente_id, concepto, monto, saldo, moneda, fecha_emision, fecha_vencimiento, estatus)
  VALUES ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000d1', 'CxC histórica', 5000, 5000, 'MXN', current_date, current_date + 30, 'ABIERTA');
INSERT INTO public.cxc_abonos (cxc_id, monto, fecha_abono, metodo_pago) VALUES ('00000000-0000-0000-0000-0000000000f1', 1000, current_date, 'TRANSFERENCIA');
INSERT INTO public.flujo_dinero (id, tipo, etapa, monto, moneda, metodo_pago, fecha, contraparte_nombre, cliente_id, recibido_por, caja_por, caja_at, movimiento_id, cuenta_id)
  SELECT '00000000-0000-0000-0000-0000000000a9', 'PAGO_CLIENTE', 'EN_CAJA', 300, 'MXN', 'EFECTIVO', current_date, 'Cliente', '00000000-0000-0000-0000-0000000000d1',
         '00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000c2', now(), '00000000-0000-0000-0000-0000000000e2', id
    FROM public.cuentas_financieras WHERE moneda = 'MXN' AND tipo = 'EFECTIVO' LIMIT 1;
INSERT INTO public.flujo_dinero (tipo, etapa, monto, moneda, metodo_pago, fecha, contraparte_nombre, recibido_por, motivo_rechazo, rechazado_por, rechazado_at, concepto)
  VALUES ('REEMBOLSO', 'RECHAZADO', 50, 'MXN', 'EFECTIVO', current_date, 'Prov', '00000000-0000-0000-0000-0000000000c1', 'No llegó', '00000000-0000-0000-0000-0000000000c2', now(), 'Devolución');
SQL

antes=$(psql -X -At -d "$DB" -c "select (select count(*) from movimientos_financieros)||'/'||(select count(*) from cobranza_pagos)||'/'||(select count(*) from cxc_abonos)||'/'||(select count(*) from cuentas_por_cobrar)||'/'||(select count(*) from flujo_dinero)||'/'||(select sum(monto) from movimientos_financieros)")

psql -X -q -v ON_ERROR_STOP=1 --single-transaction -d "$DB" -f "$MIG" >/dev/null
psql -X -q -v ON_ERROR_STOP=1 --single-transaction -d "$DB" -f "$MIG" >/dev/null   # repetirla no rompe

despues=$(psql -X -At -d "$DB" -c "select (select count(*) from movimientos_financieros)||'/'||(select count(*) from cobranza_pagos)||'/'||(select count(*) from cxc_abonos)||'/'||(select count(*) from cuentas_por_cobrar)||'/'||(select count(*) from flujo_dinero)||'/'||(select sum(monto) from movimientos_financieros)")
[ "$antes" = "$despues" ] || { echo "FALLA: se perdieron o se agregaron filas ($antes → $despues)"; exit 1; }

psql -X -q -v ON_ERROR_STOP=1 -d "$DB" <<'SQL'
DO $$ BEGIN
  ASSERT (SELECT origen FROM public.movimientos_financieros WHERE id = '00000000-0000-0000-0000-0000000000e1') = 'HISTORICO_DIRECTO', 'el movimiento directo queda como histórico';
  ASSERT (SELECT origen || '/' || (flujo_id = '00000000-0000-0000-0000-0000000000a9')::text FROM public.movimientos_financieros WHERE id = '00000000-0000-0000-0000-0000000000e2') = 'FLUJO/true', 'el libro del flujo queda ligado a su folio';
  ASSERT (SELECT origen FROM public.cobranza_pagos WHERE folio = 'CP-HIST-1') = 'HISTORICO_DIRECTO', 'el pago directo queda como histórico';
  ASSERT (SELECT origen FROM public.cxc_abonos LIMIT 1) = 'HISTORICO_DIRECTO', 'el abono directo queda como histórico';
  ASSERT (SELECT saldo FROM public.cuentas_por_cobrar WHERE id = '00000000-0000-0000-0000-0000000000f1') = 4000, 'el saldo de la cuenta por cobrar no cambió';
  -- El historial de lo que ya existía se reconstruye una sola vez (aun corriendo la migración dos veces).
  ASSERT (SELECT count(*) FROM public.flujo_dinero_eventos WHERE flujo_id = '00000000-0000-0000-0000-0000000000a9') = 2, 'historial reconstruido: recibido y en caja';
  ASSERT (SELECT count(*) FROM public.flujo_dinero_eventos WHERE accion = 'RECHAZADO') = 1, 'el rechazo anterior queda en el historial';
  ASSERT (SELECT count(*) FROM public.v_movimientos_financieros WHERE origen = 'HISTORICO_DIRECTO') = 1, 'la vista del libro muestra el origen';
  ASSERT (SELECT flujo_folio FROM public.v_movimientos_financieros WHERE id = '00000000-0000-0000-0000-0000000000e2') LIKE 'FD-%', 'y el folio del flujo';
  ASSERT (SELECT adjuntos_count FROM public.v_movimientos_financieros LIMIT 1) IS NOT NULL, 'la vista conserva sus columnas anteriores';
  ASSERT (SELECT count(*) FROM public.v_flujo_dinero) = 2, 'el flujo anterior sigue visible';
END $$;
SQL
echo "OK: transición (sin pérdida, histórico marcado, repetible)"

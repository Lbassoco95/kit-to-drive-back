#!/usr/bin/env bash
# Base vacía → todas las migraciones → pruebas de gastos, categorías, cuentas por prueba/real, históricos y regularización.
#   PGHOST=127.0.0.1 PGUSER=postgres scripts/db-local/probar_gastos.sh
set -euo pipefail
RAIZ="$(cd "$(dirname "$0")/../.." && pwd)"
DB="${1:-kit_pruebas_gastos}"
export PGUSER="${PGUSER:-postgres}"
"$RAIZ/scripts/db-local/aplicar_migraciones.sh" "$DB"
psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f "$RAIZ/scripts/db-local/pruebas_gastos.sql"

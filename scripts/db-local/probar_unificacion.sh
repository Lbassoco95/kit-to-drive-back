#!/usr/bin/env bash
# Base vacía → todas las migraciones → pruebas de la unificación de Control financiero y flujo de dinero.
#   PGHOST=127.0.0.1 PGUSER=postgres scripts/db-local/probar_unificacion.sh
set -euo pipefail
RAIZ="$(cd "$(dirname "$0")/../.." && pwd)"
DB="${1:-kit_pruebas_unificacion}"
export PGUSER="${PGUSER:-postgres}"
"$RAIZ/scripts/db-local/aplicar_migraciones.sh" "$DB"
psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f "$RAIZ/scripts/db-local/pruebas_unificacion.sql"

#!/usr/bin/env bash
# Base vacía → todas las migraciones → pruebas de bancos por empresa y búsqueda de remisiones.
#   PGHOST=127.0.0.1 PGUSER=postgres scripts/db-local/probar_bancos_busqueda.sh
set -euo pipefail
RAIZ="$(cd "$(dirname "$0")/../.." && pwd)"
DB="${1:-kit_pruebas_bancos}"
export PGUSER="${PGUSER:-postgres}"
"$RAIZ/scripts/db-local/aplicar_migraciones.sh" "$DB"
psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f "$RAIZ/scripts/db-local/pruebas_bancos_busqueda.sql"

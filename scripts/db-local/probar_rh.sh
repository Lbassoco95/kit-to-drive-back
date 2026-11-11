#!/usr/bin/env bash
# Base vacía → todas las migraciones → pruebas del módulo de RH.
#   PGHOST=/tmp/pgd PGPORT=5433 scripts/db-local/probar_rh.sh
set -euo pipefail
RAIZ="$(cd "$(dirname "$0")/../.." && pwd)"
DB="${1:-kit_pruebas_rh}"
export PGUSER="${PGUSER:-postgres}"
"$RAIZ/scripts/db-local/aplicar_migraciones.sh" "$DB" || true   # tres migraciones viejas dependen de datos de producción
psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f "$RAIZ/scripts/db-local/pruebas_rh.sql"

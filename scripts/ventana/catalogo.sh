#!/usr/bin/env bash
# Conteos de permisos/funciones/políticas (consultas/02). SOLO LECTURA.
set -euo pipefail
AQUI="$(cd "$(dirname "$0")/../.." && pwd)"
export PGOPTIONS="-c default_transaction_read_only=on"
psql -X -x -v ON_ERROR_STOP=1 -f "$AQUI/docs/seguridad/consultas/02-conteos-linea-base.sql" | tee "ventana-logs/catalogo-$(date -u +%Y%m%dT%H%M%SZ).txt"

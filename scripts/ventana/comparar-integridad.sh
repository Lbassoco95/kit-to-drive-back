#!/usr/bin/env bash
# Compara la base con una foto (tabla|filas|huella). Imprime SOLO las tablas que cambiaron. Vacío = la información se mantuvo.
set -euo pipefail
ANTES="${1:?uso: comparar-integridad.sh <antes.txt>}"
AQUI="$(cd "$(dirname "$0")/../.." && pwd)"
export PGOPTIONS="-c default_transaction_read_only=on"
python3 "$AQUI/docs/seguridad/integridad/generar-comparacion.py" "$ANTES" | psql -X -q -At -F ' | ' -v ON_ERROR_STOP=1 > /tmp/comparacion.$$ 
if [ -s /tmp/comparacion.$$ ]; then
  echo "DIFERENCIAS (tabla | filas antes | filas ahora | qué):"; grep -vE '^(BEGIN|COMMIT|ROLLBACK)$' /tmp/comparacion.$$ || true
  rm -f /tmp/comparacion.$$; exit 2
fi
rm -f /tmp/comparacion.$$
echo "CERO diferencias: la información se mantuvo igual (93 tablas)."

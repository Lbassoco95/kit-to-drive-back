#!/usr/bin/env bash
# Foto de integridad: tabla|filas|huella (sin filas de datos). SOLO LECTURA (forzada con default_transaction_read_only).
set -euo pipefail
SALIDA="${1:?uso: foto-integridad.sh <salida.txt>}"
AQUI="$(cd "$(dirname "$0")/../.." && pwd)"
export PGOPTIONS="-c default_transaction_read_only=on"
psql -X -At -v ON_ERROR_STOP=1 -f "$AQUI/docs/seguridad/consultas/05-integridad-tablas.sql" > "$SALIDA.bruto"
# psql -At imprime una sola fila: tablas|filas|vacias|sin_pk|huella_global|<detalle: una línea tabla|filas|huella por tabla>
python3 - "$SALIDA" <<'PY'
import sys
bruto = open(sys.argv[1] + '.bruto', encoding='utf-8').read().rstrip('\n').split('\n')
cab = bruto[0].split('|', 5)
lineas = [cab[5]] + [l for l in bruto[1:] if l.strip()]
open(sys.argv[1], 'w', encoding='utf-8').write('\n'.join(lineas) + '\n')
print('tablas=%s filas=%s vacias=%s sin_pk=%s huella_global=%s' % tuple(cab[:5]))
PY
rm -f "$SALIDA.bruto"
echo "Guardado en $SALIDA ($(wc -l < "$SALIDA") líneas). Solo conteos y hashes."

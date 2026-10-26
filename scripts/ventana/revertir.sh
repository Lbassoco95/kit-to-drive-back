#!/usr/bin/env bash
# Aplica la REVERSA de un archivo en UNA transacción y marca el registro como revertida (no borra el renglón).
#   uso: scripts/ventana/revertir.sh <nombre-sin-.sql> <fase 1|2> <fecha AAAA-MM-DD>
set -euo pipefail
N="${1:?nombre de la migración sin .sql}"; FASE="${2:?fase}"; FECHA="${3:?fecha}"
AQUI="$(cd "$(dirname "$0")/../.." && pwd)"
ARCH="$AQUI/supabase/reversas/${N}_reversa.sql"; [ -f "$ARCH" ] || { echo "No existe $ARCH"; exit 1; }
REF="${VENTANA_PROYECTO_REF:-dmhzhyeivvuliumcgsmm}"
case "${PGUSER:-}${PGHOST:-}" in *"$REF"*) ;; *) echo "STOP: la conexión no es del proyecto $REF"; exit 1;; esac
mkdir -p ventana-logs; LOG="ventana-logs/revertir-$N-$(date -u +%Y%m%dT%H%M%SZ).log"
echo "Se va a REVERTIR en $REF: $N"; read -r -p "Escribe la referencia del proyecto para continuar: " R; [ "$R" = "$REF" ] || { echo "No coincide. Cancelado."; exit 1; }
psql -X -v ON_ERROR_STOP=1 --single-transaction -f "$ARCH" \
  -c "UPDATE public.migraciones_aplicadas SET estado = 'superado', notas = 'REVERTIDA en la ventana del $FECHA (Fase $FASE)' WHERE script = '$N'" \
  2>&1 | tee "$LOG"
echo "Reversa aplicada. Registro en $LOG. Repite catalogo.sh y comparar-integridad.sh: debe volver a la línea base."

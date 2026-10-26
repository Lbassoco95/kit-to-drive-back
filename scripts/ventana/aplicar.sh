#!/usr/bin/env bash
# Aplica UN archivo de migración, tal cual está en el repo, en UNA transacción, y lo registra en migraciones_aplicadas
# (todo atómico: si algo falla, no queda nada a medias, ni el registro).
#   uso: scripts/ventana/aplicar.sh <nombre-sin-.sql> <fase 1|2> <fecha AAAA-MM-DD>
set -euo pipefail
N="${1:?nombre de la migración sin .sql}"; FASE="${2:?fase}"; FECHA="${3:?fecha}"
AQUI="$(cd "$(dirname "$0")/../.." && pwd)"
ARCH="$AQUI/supabase/migrations/$N.sql"; [ -f "$ARCH" ] || { echo "No existe $ARCH"; exit 1; }
REF="${VENTANA_PROYECTO_REF:-dmhzhyeivvuliumcgsmm}"
case "${PGUSER:-}${PGHOST:-}" in *"$REF"*) ;; *) echo "STOP: la conexión no es del proyecto $REF (corre: source scripts/ventana/conectar.sh)"; exit 1;; esac
mkdir -p ventana-logs; LOG="ventana-logs/aplicar-$N-$(date -u +%Y%m%dT%H%M%SZ).log"
echo "Se va a APLICAR en $REF: $N"; read -r -p "Escribe la referencia del proyecto para continuar: " R; [ "$R" = "$REF" ] || { echo "No coincide. Cancelado."; exit 1; }
psql -X -v ON_ERROR_STOP=1 --single-transaction -f "$ARCH" \
  -c "INSERT INTO public.migraciones_aplicadas (script, estado, notas) VALUES ('$N', 'aplicado', 'Fase $FASE, ventana del $FECHA') ON CONFLICT (script) DO UPDATE SET estado = 'aplicado', aplicada_at = now(), notas = EXCLUDED.notas" \
  2>&1 | tee "$LOG"
echo "Listo. Registro en $LOG. Ahora: catalogo.sh, comparar-integridad.sh y los recorridos."

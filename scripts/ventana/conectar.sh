#!/usr/bin/env bash
# Se usa con:  source scripts/ventana/conectar.sh
# Pide la contraseña SIN eco, fija PGHOST/PGUSER/…, y comprueba que el destino es PRODUCCIÓN. No imprime ni guarda la contraseña.
REF="${VENTANA_PROYECTO_REF:-dmhzhyeivvuliumcgsmm}"
echo "Proyecto esperado: $REF  (producción = kit-to-drive; QA es qszllskpizvpnzcytqpj y NO se toca)"
if [ -z "${PGHOST:-}" ] || [ -z "${PGUSER:-}" ]; then
  echo "Falta PGHOST o PGUSER. Cópialos del botón Connect del proyecto (Session pooler):"
  echo "  export PGHOST=<host>  PGPORT=5432  PGUSER=postgres.$REF  PGDATABASE=postgres  PGSSLMODE=require"
  return 1 2>/dev/null || exit 1
fi
case "$PGUSER$PGHOST" in
  *"$REF"*) ;;
  *) echo "STOP: ni PGUSER ni PGHOST contienen la referencia $REF. No es producción. No sigas."; return 1 2>/dev/null || exit 1 ;;
esac
case "$PGUSER$PGHOST" in
  *qszllskpizvpnzcytqpj*) echo "STOP: es QA."; return 1 2>/dev/null || exit 1 ;;
esac
if [ -z "${PGPASSWORD:-}" ]; then read -rs -p "Contraseña de la base (no se muestra): " PGPASSWORD; echo; export PGPASSWORD; fi
export PGDATABASE="${PGDATABASE:-postgres}" PGSSLMODE="${PGSSLMODE:-prefer}" PGCONNECT_TIMEOUT=15
mkdir -p ventana-logs
# Comprobación de que es producción: tablas y cifras que solo tiene esa base.
psql -X -At -v ON_ERROR_STOP=1 -c "select 'base='||current_database()||' zz_lista_oct='||(select count(*) from public.zz_lista_oct)||' super_admins='||(select count(*) from public.super_admins)||' registro='||(select count(*) from public.migraciones_aplicadas)" || { echo "No se pudo conectar."; return 1 2>/dev/null || exit 1; }
echo "Esperado en producción (26 oct): zz_lista_oct=2219 super_admins=2. Si no coincide: DETENTE."

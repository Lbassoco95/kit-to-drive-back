# Scripts de la ventana (producción)

Los corre **Polo en su terminal**. **Ninguno guarda ni pide contraseñas por chat**: la contraseña de la base se escribe una sola vez, sin eco, y vive solo en esa terminal.
Registran lo que hacen en `ventana-logs/` (carpeta local, no se versiona). Ver `docs/seguridad/RUNBOOK-CONSOLIDADO-VENTANAS.md`.

| Script | Para qué | ¿Escribe en la base? |
|---|---|---|
| `conectar.sh` (con `source`) | Pide la contraseña, fija la conexión y **comprueba que es producción** | No |
| `foto-integridad.sh <salida.txt>` | Foto de las 93 tablas (conteo y huella) | **No** (solo lectura forzada) |
| `comparar-integridad.sh <antes.txt>` | Compara la base con una foto; imprime solo lo que cambió | **No** |
| `catalogo.sh` | Conteos de permisos/funciones/políticas (`consultas/02`) | **No** |
| `aplicar.sh <archivo> <fase> <fecha>` | Aplica UN archivo en UNA transacción y lo registra | **Sí** |
| `revertir.sh <archivo> <fase> <fecha>` | Aplica su reversa en una transacción y marca el registro | **Sí** |

Uso típico:
```bash
source scripts/ventana/conectar.sh                       # una vez por terminal
scripts/ventana/aplicar.sh 20261031000001_fase1_quitar_truncate_trigger_references 1 2026-10-27
scripts/ventana/catalogo.sh
scripts/ventana/comparar-integridad.sh docs/seguridad/integridad/antes-tablas.txt
```
Variables: `VENTANA_PROYECTO_REF` (por defecto la de producción `dmhzhyeivvuliumcgsmm`; solo se cambia para probar en una base local).

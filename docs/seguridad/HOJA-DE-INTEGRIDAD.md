# Hoja de integridad — cómo comprobar que la información se mantuvo

**Regla:** una migración de **solo permisos** debe dejar **CERO diferencias** en las 93 tablas, en Auth y en Storage. Esta hoja se usa después de **cada** paso. Las consultas son de **solo lectura**; los scripts fuerzan `default_transaction_read_only = on`.

Referencia (la foto de antes): `docs/seguridad/integridad/antes-tablas.txt` (93 tablas, **huella global `f14b7f9d221eb9465000913f8aaf5f36`**, 20,610 filas) y `integridad/antes-auth-storage.txt`. Explicación completa: `INTEGRIDAD-ANTES.md`.

## 1. Por cada paso, en este orden

| # | Qué | Comando (terminal de Polo, ya con `source scripts/ventana/conectar.sh`) | Resultado correcto |
|---|---|---|---|
| 1 | **Comparar las 93 tablas** con la foto de antes | `scripts/ventana/comparar-integridad.sh docs/seguridad/integridad/antes-tablas.txt` | **«CERO diferencias: la información se mantuvo igual (93 tablas).»** (código de salida 0). Si imprime una tabla, **hay diferencia: se detiene** (§2) |
| 2 | **Auth y Storage** | `PGOPTIONS='-c default_transaction_read_only=on' psql -X -x -f docs/seguridad/consultas/06-integridad-auth-storage.sql` y comparar con `integridad/antes-auth-storage.txt` | `auth.users` total 26, bloqueados 0; huellas de `auth.users` y de contraseñas **iguales**; Storage: 72 objetos / 107,052,615 bytes y huellas iguales. Sesiones y tokens **pueden** variar (uso normal) |
| 3 | **Catálogo** (permisos, políticas, funciones) | `scripts/ventana/catalogo.sh` | Cambia **solo** lo previsto en el runbook para ese paso |
| 4 | **Foto nueva** (opcional, para el informe) | `scripts/ventana/foto-integridad.sh ventana-logs/despues-paso-<n>.txt` | `tablas=93 filas=20610 …` |

**Claude repite 1, 2 y 3** por su canal de solo lectura y compara; si Claude y Polo ven lo mismo, se sigue.

## 2. Si hay una diferencia

La salida indica **tabla**, **filas antes / ahora** y **qué** (`cambió el número de filas` o `cambió el contenido`). Entonces:
1. **No se sigue.** No se aplica el siguiente paso.
2. Claude consulta, solo lectura, **la fecha y hora de creación o de edición** de las filas que cambiaron (columnas `created_at`/`updated_at` cuando existen) y las compara con la hora a la que se aplicó el paso (`ventana-logs/`).
3. Si **todas** las filas nuevas o editadas son **posteriores** al paso y de **una operación normal** de un usuario (por ejemplo, alguien creó una remisión), se **documenta con esas fechas** en `INTEGRIDAD-RESULTADO-FASE-<n>.md` y se actualiza la foto de referencia **desde ese punto**.
4. Si **no** se puede demostrar, o la diferencia es de **contenido** en una tabla que nadie debía tocar, o **desaparecen** filas: **se revierte el paso** (§4.2 del runbook) y se reporta.
5. **Nunca** se da por buena una diferencia sin evidencia.

## 3. Qué detecta y qué no

- **Detecta:** cualquier cambio en cualquier columna de cualquier fila de las 93 tablas de `public`, filas nuevas o borradas.
- **No detecta:** cambios de estructura (lo cubre el catálogo); lo que hay *dentro* de los archivos de Storage (se compara nombre, tamaño y `eTag`); las tablas de `bkp` (8, no se tocan).
- Las migraciones **no escriben datos** (comprobado por pruebas automáticas); la comparación es la **prueba independiente** de eso.

## 4. Cómo funciona por dentro (para quien quiera revisarlo)

- La huella de cada tabla es el `md5` de todas sus filas en texto, ordenadas por la llave primaria (las 93 tienen). Una tabla vacía se marca `vacia`.
- `generar-comparacion.py` construye una consulta que une «lo que hay hoy» con «la foto» y devuelve solo lo distinto. Se **probó contra producción** el 26 oct (resultado vacío) y contra una base local donde se cambió una fila (la detectó).
- Por el canal de Claude, la misma consulta se pega en el MCP de solo lectura (`python3 docs/seguridad/integridad/generar-comparacion.py docs/seguridad/integridad/antes-tablas.txt`).

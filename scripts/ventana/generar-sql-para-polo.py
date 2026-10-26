#!/usr/bin/env python3
"""Genera docs/seguridad/SQL-PARA-POLO.md juntando las consultas de docs/seguridad/consultas/ en el orden de la ventana.
Uso (desde la raíz del repo):  python3 scripts/ventana/generar-sql-para-polo.py
Cada bloque queda envuelto en `begin read only; … rollback;`. No se ejecuta nada."""
import re, subprocess, pathlib
RAIZ = pathlib.Path(__file__).resolve().parents[2]
C = RAIZ / 'docs/seguridad/consultas'

def leer(nombre): return (C / nombre).read_text(encoding='utf-8')

def envolver(sql):
    sql = sql.strip()
    if re.search(r'^\s*begin read only;', sql, re.M | re.I): return sql
    return 'begin read only;\n' + sql + '\nrollback;'

def sin_comentarios_iniciales(sql):
    lineas = sql.splitlines()
    while lineas and (lineas[0].startswith('--') or not lineas[0].strip()): lineas.pop(0)
    return '\n'.join(lineas)

def bloques_07():
    partes = re.split(r'^-- ─── ', leer('07-historial-migraciones.sql'), flags=re.M)[1:]
    return [('-- ─── ' + p).strip() for p in partes]

def titulo_bloque(b): return re.match(r'-- ─── (B\d\.[^─\n]*)', b).group(1).strip()

comparar = subprocess.run(['python3', str(RAIZ / 'docs/seguridad/integridad/generar-comparacion.py'),
                           str(RAIZ / 'docs/seguridad/integridad/antes-tablas.txt')],
                          capture_output=True, text=True, check=True).stdout.strip()
b07 = bloques_07()
def cod(sql): return '```sql\n' + sql.strip() + '\n```'

doc = f"""# SQL de solo lectura para Polo — todo en un solo documento

**Estado: NADA APLICADO.** Generado por `scripts/ventana/generar-sql-para-polo.py` a partir de `docs/seguridad/consultas/` (si cambia una consulta, se regenera este archivo).

## Reglas de este modo de trabajo

1. **Claude no usa el conector de Supabase de claude.ai para nada, ni para leer.** Esto se repite en cada reporte.
2. Claude **no ve producción**. Polo corre cada bloque en el **SQL Editor** de Supabase y **pega el resultado** en la sesión.
3. Todo bloque es de **solo lectura**: va envuelto en `begin read only; … rollback;`. Si alguna instrucción intentara escribir, Postgres la rechaza.
4. Solo se piden **conteos, huellas (md5) y catálogo**. Ningún bloque devuelve filas con datos de personas, correos, contraseñas ni el texto de migraciones. **Si un resultado trae algo que parezca un dato personal o un secreto, no lo pegues** y avísame.
5. No hay nada que escribir en ninguna base. Los bloques no crean tablas ni funciones.
6. **Todo SQL que se le pide a Polo va pegado completo en el chat**, en un bloque propio, con una línea de «resultado esperado». Este archivo es el respaldo en el repo, no la forma de entregarlo.

## Cómo correr un bloque (una vez por bloque)

1. Abre el proyecto **`kit-to-drive`** (ref `dmhzhyeivvuliumcgsmm`) — **no** `kit-to-drive-db-qa`. El primer bloque (0) lo comprueba: debe decir `zz_lista_oct = 2219` y `super_admins = 2` (a la fecha del 26 oct; si cambiaron por actividad, dilo).
2. SQL Editor → *New query* → pega **un solo bloque** completo (de `begin read only;` a `rollback;`) → *Run*.
3. Copia el resultado (botón *Copy as Markdown* o *Copy as CSV* de la cuadrícula) y pégalo en la sesión, **con el nombre del bloque** (por ejemplo «A2»).
4. **Si el editor solo muestra «Success. No rows returned»** (puede mostrar únicamente la última instrucción, que es `rollback;`): borra la última línea `rollback;` y vuelve a correr. Sigue siendo de solo lectura (la transacción está marcada `read only`, así que no puede escribir) y se cierra sola al terminar la sesión del editor. Dímelo y reescribo los bloques como una sola instrucción. *No he podido probar el editor de Supabase desde aquí; los bloques sí los probé en una réplica local de PostgreSQL 16 con la misma estructura.*

## Orden

| Bloque | Qué mide | Qué me devuelves |
|---|---|---|
| 0 | Salud previa y comprobación de que es producción | 1 fila |
| A1 | ¿Cambió algo desde la foto del 25 oct? | solo las tablas distintas (o vacío) |
| A2 | **Foto fresca antes de la ventana** (compacta) | 1 fila con una celda larga: pégala entera |
| A3 | Auth y Storage (conteos y huellas) | ~15 filas |
| B1–B3 | Historial de migraciones, solo lo que afecta a la Fase 1 y 2 | 1 tabla de 34 filas + 2 pequeñas |
| C | Puente de Patio (constancia) | 1 fila |
| D1 | Conteos de permisos (línea base del catálogo) | 1 fila ancha |
| D2 | Errores de las últimas 24 h (Logs Explorer) | 2 tablas pequeñas |

Corre A1–A3 y 0 **el día de la ventana, antes de empezar** (y los de A y D1 otra vez después de cada paso, según el runbook). B, C y D se pueden correr hoy.

---

## 0. Salud previa y comprobación de producción

{cod(leer('09-salud-previa.sql').split(chr(10),2)[2] if False else sin_comentarios_iniciales(leer('09-salud-previa.sql')))}

Esperado: `base` = `postgres`; `zz_lista_oct` = 2219 y `super_admins` = 2; `transaccion_mas_larga` de segundos; `bloqueos_esperando` = 0.

---

## A. Foto de integridad

### A1. Comparación con la foto del 25 oct (`integridad/antes-tablas.txt`)

Devuelve **solo** las tablas cuyo conteo o huella no coincide. **Resultado vacío = la información se mantuvo igual.** Cada fila distinta se explica con la fecha/hora de creación de sus filas (la pido después).

{cod(comparar)}

### A2. Foto fresca antes de la ventana (formato compacto)

Una fila: `medido_en`, `tablas`, `filas_total`, `huella_global` y `detalle_compacto` (`tabla|filas|huella12;…`). **Pega la fila entera**; yo la guardo como `integridad/antes-ventana-fase-1.txt` y de ahí salen las comparaciones de después de cada paso (`generar-comparacion.py` acepta este formato).

{cod(sin_comentarios_iniciales(leer('05b-foto-compacta.sql')))}

### A3. Auth y Storage

Se compara con `integridad/antes-auth-storage.txt` (referencia del 25 oct: `auth.users` 26, 0 bloqueados; `identities` 28; `storage.objects` 72).

{cod(envolver(sin_comentarios_iniciales(leer('06-integridad-auth-storage.sql'))))}

---

## B. Historial de migraciones (solo lo que afecta a aplicar la Fase 1 y la Fase 2)

Qué respondo con esto: **quién y cuándo** aplicó cada migración (`created_by`, si la versión de Supabase lo guarda), si **algo de la Fase 1/2 ya figura** en el registro, y si el historial anterior ya cambió **permisos, `search_path` o `TRUNCATE`** (lo que la Fase 1 toca). Ningún bloque devuelve texto de sentencias.

### {titulo_bloque(b07[0])}

{cod(b07[0].split(chr(10),1)[1])}

### {titulo_bloque(b07[1])}

{cod(b07[1].split(chr(10),1)[1])}

### {titulo_bloque(b07[2])}

{cod(b07[2].split(chr(10),1)[1])}

---

## C. Puente de Patio (constancia)

Polo ya confirmó que no existe. Esto lo deja por escrito (no muestra ningún valor). Esperado: `NULL`, `0`, `0` o `1`, `0`.

{cod(sin_comentarios_iniciales(leer('08-puente-patio-estado.sql')))}

---

## D. Otras mediciones pendientes de la Parte A

### D1. Conteos de permisos (línea base del catálogo)

Es la medición que se repite idéntica antes y después de cada paso. Referencia del 25 oct en `LINEA-BASE-2026-10-25.md`.

{cod(envolver(sin_comentarios_iniciales(leer('02-conteos-linea-base.sql'))))}

### D2. Errores de las últimas 24 h (línea base)

**No son para el SQL Editor.** Van en *Dashboard → Logs → Logs Explorer* (rango *Last 24 hours*). Solo cuentan, no muestran mensajes ni datos. *Sintaxis de Logs Explorer no probada desde aquí; si falla, dime qué error da.*

```sql
-- API: respuestas con error, por código
select r.status_code as codigo, count(*) as total
from edge_logs
cross join unnest(metadata) as m
cross join unnest(m.response) as r
where r.status_code >= 400
group by 1 order by 1
```

```sql
-- Postgres: errores graves, por severidad
select p.error_severity as severidad, count(*) as total
from postgres_logs
cross join unnest(metadata) as m
cross join unnest(m.parsed) as p
where p.error_severity in ('ERROR', 'FATAL', 'PANIC')
group by 1 order by 1
```

### D3. Lo que no se mide con SQL y solo puede dar Polo

- «Respaldo del *fecha y hora*» (Database → Backups): del mismo día o del anterior. **Sin esto no empieza la ventana.**
- Nombre de la **persona de pruebas** y confirmación de que estará toda la ventana.
- **Fecha** de la ventana (sábado o domingo, o entre semana después de las 19:00 CDMX).

---

## Qué hago con cada resultado

- **A1 vacío** y **A3 igual a la referencia** → la información sigue como el 25 oct; la ventana puede empezar.
- **A1 con filas** → no empiezo hasta explicarlas: te pido (con un bloque de solo lectura) la fecha/hora de creación o edición de esas filas, sin contenido.
- **B** → completo `HISTORIAL-MIGRACIONES-HALLAZGO.md` y confirmo si algo del historial choca con las migraciones de la Fase 1/2.
- **D1** → lo comparo con la línea base; la Fase 1 debe partir de esos números.
"""
(RAIZ / 'docs/seguridad/SQL-PARA-POLO.md').write_text(doc, encoding='utf-8')
print('SQL-PARA-POLO.md generado', len(doc), 'caracteres')

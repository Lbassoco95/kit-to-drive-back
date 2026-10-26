#!/usr/bin/env python3
"""Genera docs/seguridad/RUNBOOK-FINAL-FASE-1.md juntando los bloques SQL de docs/seguridad/consultas/.
Uso (desde la raíz del repo):  python3 scripts/ventana/generar-runbook-final.py   · No ejecuta nada."""
import re, subprocess, pathlib, hashlib
RAIZ = pathlib.Path(__file__).resolve().parents[2]
C = RAIZ / 'docs/seguridad/consultas'
def leer(n): return (C / n).read_text(encoding='utf-8')
def sin_com(sql):
    l = sql.strip().splitlines()
    while l and (l[0].startswith('--') or not l[0].strip()): l.pop(0)
    return '\n'.join(l)
def envolver(sql):
    sql = sql.strip()
    return sql if re.search(r'^\s*begin read only;', sql, re.M | re.I) else 'begin read only;\n' + sql + '\nrollback;'
def cod(sql, lang='sql'): return f'```{lang}\n{sql.strip()}\n```'
A1 = subprocess.run(['python3', str(RAIZ / 'docs/seguridad/integridad/generar-comparacion.py'),
                     str(RAIZ / 'docs/seguridad/integridad/antes-tablas.txt')], capture_output=True, text=True, check=True).stdout.strip()
B0 = sin_com(leer('09-salud-previa.sql'))
A2 = sin_com(leer('05b-foto-compacta.sql'))
A3 = envolver(sin_com(leer('06-integridad-auth-storage.sql')))
V = sin_com(leer('10-verificacion-paso.sql'))
def h(p): return hashlib.sha256((RAIZ / p).read_bytes()).hexdigest()[:16]
MIG = ['20261031000001_fase1_quitar_truncate_trigger_references', '20261031000002_fase1_cerrar_funciones_de_trigger',
       '20261031000003_fase1_fijar_search_path', '20261031000004_fase1_quitar_lectura_anon_de_vistas',
       '20261031000005_fase1_quitar_escritura_anon_de_tablas', '20261031000006_fase1_lo_nuevo_nace_cerrado']
M = {i + 1: n for i, n in enumerate(MIG)}
ORDEN = [1, 2, 4, 5, 6, 3]
sumas = '\n'.join(f'{h("supabase/migrations/" + M[i] + ".sql")}  supabase/migrations/{M[i]}.sql' for i in range(1, 7)) + '\n' + \
        '\n'.join(f'{h("supabase/reversas/" + M[i] + "_reversa.sql")}  supabase/reversas/{M[i]}_reversa.sql' for i in range(1, 7))
def aplicar(n):
    return f"""```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \\
  -f supabase/migrations/{M[n]}.sql \\
  -c "INSERT INTO public.migraciones_aplicadas (script, estado, notas) VALUES ('{M[n]}', 'aplicado', 'Fase 1, ventana del $FECHA') ON CONFLICT (script) DO UPDATE SET estado='aplicado', aplicada_at=now(), notas=EXCLUDED.notas" \\
  2>&1 | tee "ventana-logs/aplicar-M{n}.log"
```"""
def revertir(n):
    return f"""```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \\
  -f supabase/reversas/{M[n]}_reversa.sql \\
  -c "UPDATE public.migraciones_aplicadas SET estado='superado', notas='REVERTIDA en la ventana del $FECHA (Fase 1)' WHERE script='{M[n]}'" \\
  2>&1 | tee "ventana-logs/revertir-M{n}.log"
```"""

PASOS = [  # (paso, M, titulo, salida esperada del script, recorridos, minutos)
    (1, 1, 'Quitar TRUNCATE, TRIGGER y REFERENCES a `anon` y `authenticated`', 'una línea con cuatro ceros: `0 | 0 | 0 | 0`', '1, 2, 3, 5, 6', 35),
    (2, 2, 'Cerrar las funciones de trigger a quien no debe llamarlas', 'el aviso «Funciones de trigger cerradas: 53» y `0 | 0 | t | t`', '1, 2, 3, 5, 6 (incluye el **alta de usuario**)', 35),
    (3, 4, 'Quitar la lectura de `anon` en 16 vistas', 'el aviso «Vistas cerradas a anon: 16» y `0 | 18`', '1, 6, 7', 30),
    (4, 5, 'Quitar INSERT, UPDATE y DELETE de `anon` en las tablas', 'un solo valor: `0`', '1, 6, 8', 30),
    (5, 6, 'Que lo que se cree en el futuro nazca cerrado', '`t | t | t`', '1, 6', 15),
    (6, 3, 'Fijar el `search_path` de 14 funciones (**al final y sola**)', 'el aviso «Funciones con search_path fijado: 14» y `0`. Si aparece «No existe …: se omite», **detente**', '**todos, del 1 al 11**', 40),
]
ESP = {  # tras cada migración: tablas_anon_escribe, trunc_auth, trunc_anon, con_trigger, con_references, vistas_anon_lee, funciones_anon, secdef_auth, sin_search_path, politicas, registros, filas
    'Antes (preparación)': (81, 82, 82, 103, 103, 16, 2, 208, 14, 301, 90, 'F'),
    'Tras el paso 1 (M1)': (81, 0, 0, 0, 0, 16, 2, 208, 14, 301, 91, 'F+1'),
    'Tras el paso 2 (M2)': (81, 0, 0, 0, 0, 16, 0, 178, 14, 301, 92, 'F+2'),
    'Tras el paso 3 (M4)': (81, 0, 0, 0, 0, 0, 0, 178, 14, 301, 93, 'F+3'),
    'Tras el paso 4 (M5)': (0, 0, 0, 0, 0, 0, 0, 178, 14, 301, 94, 'F+4'),
    'Tras el paso 5 (M6)': (0, 0, 0, 0, 0, 0, 0, 178, 14, 301, 95, 'F+5'),
    'Tras el paso 6 (M3)': (0, 0, 0, 0, 0, 0, 0, 178, 0, 301, 96, 'F+6'),
}
ESP_REV = {
    'Tras revertir M3': (0, 0, 0, 0, 0, 0, 0, 178, 14, 301, 96, 'F+6'),
    'Tras revertir M6': (0, 0, 0, 0, 0, 0, 0, 178, 14, 301, 96, 'F+6'),
    'Tras revertir M5': (81, 0, 0, 0, 0, 0, 0, 178, 14, 301, 96, 'F+6'),
    'Tras revertir M4': (81, 0, 0, 0, 0, 16, 0, 178, 14, 301, 96, 'F+6'),
    'Tras revertir M2': (81, 0, 0, 0, 0, 16, 2, 208, 14, 301, 96, 'F+6'),
    'Tras revertir M1': (81, 82, 82, 103, 103, 16, 2, 208, 14, 301, 96, 'F+6'),
}
COLS = '| Momento | `tablas_anon_escribe` | `truncate_authenticated` | `truncate_anon` | `con_trigger` | `con_references` | `vistas_anon_lee` | `funciones_anon` | `secdef_authenticated` | `sin_search_path` | `politicas` | `registros_migraciones` | `filas_totales` |\n|---|' + '---|' * 12
def tabla(d): return COLS + '\n' + '\n'.join('| ' + k + ' | ' + ' | '.join(str(x) for x in v) + ' |' for k, v in d.items())
pasos_txt = ''
for paso, n, titulo, salida, rec, mins in PASOS:
    pasos_txt += f"""
### Paso {paso} — migración M{n}: {titulo}

*Archivo:* `supabase/migrations/{M[n]}.sql` · *Estimado:* {mins} min · *Recorridos obligatorios de la hoja de pruebas:* {rec}.

**Aplicar** (es lo mismo que hace `scripts/ventana/aplicar.sh {M[n]} 1 $FECHA`, que además te pide escribir la referencia del proyecto antes de seguir; usa el script si prefieres la red de seguridad):

{aplicar(n)}

**Esperado en pantalla:** termina sin la palabra `ERROR` y muestra {salida}. Si hay `ERROR`, no quedó nada aplicado (es una sola transacción): pasa el texto a Claude y **no repitas**.
"""
doc = f"""# Runbook final de la Fase 1 (solo permisos) — ventana del **`<fecha>`**

**Estado: NADA APLICADO.** Generado por `scripts/ventana/generar-runbook-final.py` (no lo edites a mano; cambia el script y vuelve a generarlo). **Claude no usa el conector de Supabase de claude.ai para nada, ni para leer.** Claude no ve producción: tú corres el SQL y pegas el resultado en la sesión, y Claude compara y dice «sigue» o «detente».

**Solo se corre con tu frase, escrita en la sesión:** «Autorizo Fase 1 en producción, ventana del `<fecha>`». Sin ella, nada de la sección 5 en adelante se ejecuta.

## 0. Campos por llenar (los escribe Polo; Claude no los inventa)

| Dato | Valor |
|---|---|
| Fecha de la ventana | `<por llenar>` |
| Respaldo (fecha y hora, Database → Backups) | `<por llenar>` |
| Persona de pruebas | `<por llenar>` |
| Cuentas por rol (una por cada rol de `HOJA-DE-PRUEBAS-POR-ROL.md`, **sin contraseñas aquí**) | `<por llenar>` |
| Persona dueña de la cuenta que aplicó las migraciones anteriores | **pendiente de Polo** (no bloquea la ventana) |

## 1. Quién corre qué y dónde

| Qué | Quién | Dónde |
|---|---|---|
| Escribir la frase de autorización y la fecha del respaldo | Polo | Esta sesión |
| Conectar a producción (la contraseña la escribe Polo, sin que se vea) | Polo | Su terminal |
| Aplicar cada migración y, si hace falta, su reversa | Polo | Su terminal (`psql`) |
| Correr los bloques de verificación (0, V, A1, A2, A3, D2) | Polo | SQL Editor de Supabase (D2: Logs Explorer) |
| Pegar los resultados | Polo | Esta sesión |
| Comparar con los valores esperados y decir «sigue» o «detente» | Claude | Esta sesión |
| Ejecutar los recorridos de la hoja de pruebas y anotar «Después» | Persona de pruebas | Su hoja impresa (`HOJA-DE-PRUEBAS-POR-ROL.md`) |
| Aplicar o revertir **algo** en producción | **Code, por el conector de escritura, solo dentro de la ventana y con la frase con fecha** (ver «Cómo aplica Code por el conector»); Polo habilita y quita el conector. Fuera de ventana nada se aplica | — |

## 2. Horario propuesto: martes 27 de octubre de 2026, 19:00 a 00:00 (CDMX)

La ventana de 19:00–00:00 (5 h) **cabe con 40 minutos de colchón** si la preparación dura 30 min (lo pesado se deja hecho durante el día, antes de las 19:00) y el paso 5 (permisos por defecto, que no cambia nada de lo existente) dura 15 min. Con los tiempos completos anteriores (45 min de preparación y 30 en el paso 5) el total sería 4 h 50 min: **cabe, pero con solo 10 minutos de colchón**, y no lo recomiendo.

| Hora | Qué |
|---|---|
| 19:00–19:30 | Preparación y verificación previa (§3, §4) |
| 19:30–20:05 | Paso 1 (M1) |
| 20:05–20:40 | Paso 2 (M2) |
| 20:40–21:10 | Paso 3 (M4) |
| 21:10–21:40 | Paso 4 (M5) |
| 21:40–21:55 | Paso 5 (M6) |
| 21:55–22:35 | Paso 6 (M3, `search_path`), **solo si empieza a más tardar a las 22:15** |
| 22:35–23:20 | Cierre: bloques finales, registro de resultado |
| 23:20–00:00 | Colchón |

*Son estimaciones, no mediciones: la aplicación de cada archivo tarda segundos; el tiempo lo ponen la persona de pruebas y las verificaciones.* **Qué se recorta si no cabe** (en este orden): 1) los recorridos de los pasos 3, 4 y 5 se reducen a los obligatorios de la hoja (1 y 6; 7 y 8 solo en los pasos que los piden); 2) el paso 6 (M3) **pasa a otra ventana**: ya está diseñado para ir al final y solo, y es seguro dejar la Fase 1 en el paso 5.

## 3. Lista previa (marca cada casilla; sin todas, no se empieza)

☐ Frase «Autorizo Fase 1 en producción, ventana del `<fecha>`» escrita en la sesión, con fecha, y la hora de inicio dentro de la ventana permitida.
☐ **Respaldo** del mismo día o del anterior, y la fecha y hora escritas en la sesión.
☐ **Persona de pruebas** presente toda la ventana, con **una cuenta por cada rol** de la hoja (las contraseñas las maneja ella, nunca en el chat).
☐ **Aviso al equipo de Dazon** (el lunes 26 y al empezar): «Martes 27 de octubre, de 19:00 a 00:00, hacemos un ajuste de seguridad de la base. No debería notarse; si algo falla o se ve lento, avisen a Polo. Por favor eviten capturar remisiones o movimientos durante ese rato.»
☐ **Terminal lista** en la carpeta del repo, en la rama revisada y mezclada. Comprueba que están las doce piezas y que no cambiaron. **Esto va en la TERMINAL, nunca en el SQL Editor.** En Linux:
```bash
sha256sum supabase/migrations/2026103100000*.sql supabase/reversas/2026103100000*_reversa.sql | cut -c1-16,65-
```
En Mac (no trae `sha256sum`):
```bash
shasum -a 256 supabase/migrations/2026103100000*.sql supabase/reversas/2026103100000*_reversa.sql | cut -c1-16,65-
```
**Esto de abajo NO se ejecuta en ningún lado: es lo que debe imprimir** (los primeros 16 caracteres de cada línea deben coincidir):
```text
{sumas}
```
☐ **Conexión a producción:** `source scripts/ventana/conectar.sh` (pide la contraseña sin mostrarla y se detiene si no es producción). Después: `export FECHA=<AAAA-MM-DD>` y `mkdir -p ventana-logs`.
☐ **Canal de reversa listo:** la misma terminal, los 6 archivos de `supabase/reversas/` presentes (arriba) y esta hoja abierta en la sección 8. La reversa se aplica en orden **inverso**: 3, 6, 5, 4, 2, 1.
☐ **Bloques de la §4 corridos y pegados** (0, V, A1, A3 y, si la foto del A2 trae diferencias, A2). Claude los lee: todo **verde**, o diferencias **explicadas**.
☐ D2 (§10) de línea base, pegado.
☐ Es producción, no QA: el bloque 0 dice `zz_lista_oct = 2219` y `super_admins = 2`.

## 4. Bloques de verificación (se corren en el SQL Editor de Supabase, proyecto `kit-to-drive`)

**Dónde corre cada cosa:** los bloques marcados `sql` van en el **SQL Editor de Supabase**; los marcados `bash`, en la **terminal**; los marcados `text` son el resultado esperado y **no se ejecutan**. **Cómo:** pega **un bloque completo** y dale *Run*. Todos son de solo lectura (`begin read only; … rollback;`). **Si el editor solo muestra «Success. No rows returned»** (puede mostrar solo la última instrucción), borra las dos líneas de los extremos, `begin read only;` y `rollback;`, y corre solo el `select`. No borres solo el `rollback;`. No he podido probar el editor de Supabase; los bloques sí los probé en una réplica local de PostgreSQL 16.

### Bloque 0 — ¿Es producción y está tranquila?

**Esperado:** `base` = `postgres`, `zz_lista_oct` = 2219, `super_admins` = 2, `bloqueos_esperando` = 0, `transaccion_mas_larga` de segundos.

{cod(B0)}

### Bloque V — Verificación del paso (una fila)

**Esperado:** los valores de la tabla de la §6 para ese momento. Además: `tablas` = 93, `auth_conserva_alta` y `auth_conserva_candado` = `true` **siempre**. `triggers_authenticated` y las tres `defaults_…`: **anótalas antes del paso 1**; `triggers_authenticated` debe quedar en 0 tras el paso 2, y las tres `defaults_…` en `true, true, true` tras el paso 5.

{cod(V)}

### Bloque A1 — ¿Cambió alguna tabla respecto a la foto del 25 oct?

**Este bloque compara con la foto del 25 oct.** Con el uso normal de Dazon habrá diferencias en tablas de **actividad** (esperadas, pero se explican con la hora de sus filas). **El día de la ventana la referencia es la foto A2 de esa mañana, no la del 25 oct:** Claude te manda en el chat este mismo bloque ya generado con esa foto, y ese es el que se repite después de cada paso. **Esperado con la foto de esa mañana, antes del paso 1: ninguna fila. Después de cada paso, antes de que la persona de pruebas entre al sistema: exactamente una fila**, la de `migraciones_aplicadas` (`cambió el número de filas`, de 90 a 90 + los pasos hechos). Cualquier otra tabla en la lista: **detente**.

{cod(A1)}

### Bloque A2 — Foto fresca de las 93 tablas (para guardar)

**Esperado el 25–26 oct (por la mañana):** `tablas` = 93, `filas_total` = 20610, `huella_global` = `f14b7f9d221eb9465000913f8aaf5f36`; **el día de la ventana puede ser distinta por uso normal** (A1 dice qué tablas) y esa foto de la mañana pasa a ser la referencia. Pégalo en la sesión como se indicó: los valores sueltos en un bloque y `detalle_compacto` completo en otro, con `huella_del_detalle` para comprobar que se pegó completo. **Esperado después de un paso:** distinta solo por `migraciones_aplicadas` (más filas); A1 dice cuál.

{cod(A2)}

### Bloque A3 — Auth y Storage

**Esperado antes del paso 1** (y después de cada paso, **antes** de los recorridos): `auth.users` 26 (0 bloqueados, huellas `1ac193c5…` y `b5ce83d1…`), `auth.identities` 28 (`b7e8b61f…`), `auth.mfa_factors` 0, `storage.buckets` 9 (`002c2d12…`), `storage.objects total` 72 (107052615 bytes, `e47ebdcc…`), `[evidencias-compras]` 7 y `[remisiones-docs]` 65. **Informativos** (cambian con el uso normal): `auth.sessions` 21, `auth.refresh_tokens` 118 (21 no revocados; los 2 tokens nuevos del 26 oct fueron una renovación normal de sesión: se emite uno y se revoca el anterior). **Después de los recorridos** pueden cambiar sesiones y tokens (la persona de pruebas entra con sus cuentas): es esperado, pero **usuarios, identidades, contraseñas y Storage no deben cambiar**.

{cod(A3)}

## 5. Los pasos (en este orden: M1, M2, M4, M5, M6 y, por último y solo, M3)

Correspondencia con la **hoja de pruebas**, que numera por orden de ejecución: paso 1 = M1, paso 2 = M2, paso 3 = M4, paso 4 = M5, paso 5 = M6, paso 6 = M3.
{pasos_txt}
### Rutina de cada paso (siempre igual)

1. **Aplicar** el comando del paso (terminal). Leer lo que muestra y compararlo con «Esperado en pantalla».
2. **Bloque V** (SQL Editor) y compararlo con la fila de la §6. Pegar en la sesión.
3. **Bloque A1 generado con la foto A2 de la mañana** (debe dar solo `migraciones_aplicadas`) y **A3**. Pegar en la sesión. **Todavía nadie entra al sistema.**
4. Claude dice «verde, sigue a los recorridos» o «detente».
5. La **persona de pruebas** hace los recorridos obligatorios de ese paso y anota «Después» en su hoja. Cualquier falla que antes pasaba: **detente**.
6. **Bloque A1 otra vez**: ahora pueden aparecer tablas de **actividad** (historial de conexiones, bitácoras, notificaciones) por las pruebas; se aceptan **solo con la hora de creación de sus filas dentro del rato de pruebas** (Claude te pide un bloque de solo lectura para comprobarlo). Datos de negocio que cambian sin explicación: **detente**.
7. Claude dice «sigue con el paso siguiente» y se anota la hora de fin.

## 6. Valores esperados del bloque V

`registros_migraciones` y `filas_totales` suben **de uno en uno** porque cada migración se anota en `migraciones_aplicadas` (**no es un cambio de datos**). **`F` es el `filas_totales` que da el bloque V en la mañana de la ventana** (era 20,610 el 25 oct y a las 09:30 del 26 oct, y 20,613 a las 11:36 del 26 oct por uso normal de Dazon): `F+1` es F más uno, y así hasta `F+6`. Los valores salen del ensayo local en el orden de la ventana (aplicar, medir, revertir, medir) y de la medición de producción del 26 oct.

{tabla(ESP)}

## 7. Después de los seis pasos (cierre)

1. Bloque V (la fila «Tras el paso 6»), A1, A3 y D2 final, todos pegados.
2. Claude escribe `INTEGRIDAD-RESULTADO-FASE-1.md` con el veredicto «la información se mantuvo: sí/no» y lo explicado.
3. `unset PGPASSWORD PGHOST PGUSER` y cerrar la terminal. Avisar al equipo de Dazon.
4. Esa noche y al día siguiente por la mañana: repetir V, A1, A3 y D2. **Fase 2 no se abre** si algo subió o cambió sin explicación (`RUNBOOK-CONSOLIDADO-VENTANAS.md` §5 y §6).

## 8. Reversa (orden inverso: M3, M6, M5, M4, M2, M1)

Se revierte **el paso que falló y los anteriores**, en el orden inverso al aplicado (si falló M5, se revierte M5 y luego M4, M2, M1... según lo que ya se aplicó, siempre del último al primero). Cada reversa es una transacción y marca el renglón de `migraciones_aplicadas` como `superado` (**no se borra**: por eso `registros_migraciones` y `filas_totales` **no bajan**). La reversa de M4 devuelve a `anon` los permisos tal como estaban el 25 oct, incluido `MAINTAIN` (permiso de PostgreSQL 17, que no existe en mi réplica local: **esa línea no la pude ensayar**; el resto de las reversas sí se ensayó completo).

{chr(10).join(f'**Revertir M{n}**' + chr(10) + chr(10) + revertir(n) + chr(10) for n in [3, 6, 5, 4, 2, 1])}
**Después de cada reversa:** bloque V, que debe dar los valores de esta tabla (la primera columna de cada fila es lo que se acaba de revertir; los valores suponen que se aplicaron los seis pasos: si solo se aplicaron algunos, el valor esperado es el de la fila de la §6 del paso anterior al que revertiste); y al final de **todas**, A1 (la única diferencia, `migraciones_aplicadas`, con seis renglones más).

{tabla(ESP_REV)}

## 9. Tiempos y qué hacer

| Situación | Qué se hace |
|---|---|
| Un paso lleva **más de 1,5×** su estimado sin conclusión (p. ej. 53 min en uno de 35) | **Pausa.** Claude resume qué falta; Polo decide: terminar la prueba o revertir el paso |
| El comando de `psql` **no termina** (más de 2 min) o se corta la conexión | `psql` deshace la transacción solo. **No repitas todavía:** corre el bloque V y la consulta del registro (`select script, estado from public.migraciones_aplicadas where script like '202610310%';`, dentro de `begin read only; … rollback;`) para ver en qué estado quedó |
| Son las **13:15** y el paso 6 (M3) no ha empezado | **M3 pasa a otra ventana.** Se cierra con lo ya aplicado |
| Son las **14:15** con un paso a medias | Se **revierte** ese paso y se cierra con V, A1 y A3. **Nunca se deja un paso sin verificar** |
| Falta la persona de pruebas | **Se detiene.** No se avanza sin recorridos |

## 10. Bloque D2 — errores del día (Logs Explorer, no el SQL Editor)

Se corre **al empezar** (línea base de las últimas 24 h) y **al terminar**. **La sintaxis de Logs Explorer no está probada desde aquí.** Va en *Dashboard → Logs → Logs Explorer*, rango *Last 24 hours*. **Esperado:** el conteo de errores 401, 403 y 5xx al final **no sube** respecto al del inicio (los 400 y 404 sueltos son normales). **Si falla la sintaxis:** copia el mensaje de error y pásalo a Claude; mientras tanto usa *Dashboard → Reports → API* (gráficas de errores 4xx y 5xx de las últimas 24 h) y anota los números a ojo; no se bloquea la ventana por esto, pero **sin ninguna de las dos medidas no se declara «los errores no subieron»**.

```sql
select r.status_code as codigo, count(*) as total
from edge_logs
cross join unnest(metadata) as m
cross join unnest(m.response) as r
where r.status_code >= 400
group by 1 order by 1
```

```sql
select p.error_severity as severidad, count(*) as total
from postgres_logs
cross join unnest(metadata) as m
cross join unnest(m.parsed) as p
where p.error_severity in ('ERROR', 'FATAL', 'PANIC')
group by 1 order by 1
```

### D2 por `query_logs` (probado el 26 oct con el conector de lectura)

`query_logs` usa **ClickHouse** sobre la tabla `logs` (no la sintaxis de Logs Explorer de arriba). **Funciona**: se corre por Code, sin que Polo pegue nada. Ventana: las últimas 24 h por omisión. Fuentes disponibles: `edge_logs`, `postgrest_logs`, `postgres_logs`, `auth_logs`, `auth_audit_logs`, `storage_logs`, `realtime_logs`, `function_edge_logs`, `function_logs`, entre otras. Solo se piden conteos.

```sql
select log_attributes['response.status_code'] as codigo, count() as total
from logs
where source = 'edge_logs' and toUInt32OrZero(log_attributes['response.status_code']) >= 400
group by codigo order by codigo
```

```sql
select log_attributes['parsed.error_severity'] as severidad, count() as total
from logs
where source = 'postgres_logs' and log_attributes['parsed.error_severity'] in ('ERROR', 'FATAL', 'PANIC')
group by severidad order by severidad
```

**Línea base del 26 oct (últimas 24 h):** API `400` = 2 y `401` = 4 (sin 403 ni 5xx); Postgres `ERROR` = 6. **Esperado en la ventana:** no suben los 401, 403 ni 5xx ni los errores de Postgres respecto a lo medido al empezar. La ventana de `query_logs` es de 24 h como máximo: se corre al empezar y al terminar.

## 11. Cuándo detenerse y revertir

**Detente** (y revierte ese paso y los anteriores, en orden inverso) si, tras cualquier paso:
- falla un recorrido que antes pasaba;
- un usuario legítimo pierde una acción que tenía;
- aumentan los errores 401, 403 o 5xx contra la línea base;
- **cualquier conteo o huella cambia sin explicación demostrada** (distinto de `migraciones_aplicadas` y de la actividad de las pruebas);
- el bloque V no coincide con la tabla de la §6;
- el alta de usuarios falla (recorrido 3) o `auth_conserva_alta` / `auth_conserva_candado` dejan de ser `true`.

Un `REVOKE` que falle por dependencia: **no uses `CASCADE`**; detente y reporta. Se reporta qué pasó, qué se revirtió y en qué estado quedó.
"""
doc = doc.rstrip('\n') + '\n\n' + (RAIZ / 'docs/seguridad/COMO-APLICA-CODE-POR-EL-CONECTOR.md').read_text(encoding='utf-8').split('\n\n',1)[1]
(RAIZ / 'docs/seguridad/RUNBOOK-FINAL-FASE-1.md').write_text(doc, encoding='utf-8')
print('RUNBOOK-FINAL-FASE-1.md generado:', len(doc), 'caracteres')

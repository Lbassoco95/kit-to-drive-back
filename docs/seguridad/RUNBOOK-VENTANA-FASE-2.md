# Ventana de la Fase 2 en producción — guion

> **Mecanismo, orden de la Fase 1 e integridad de la información: ver `RUNBOOK-CONSOLIDADO-VENTANAS.md`.** Allí también están los scripts de correo y de contraseña con sus frases. Se aplica con `psql` en una transacción por archivo, no con `supabase db push` ni con `apply_migration`.

**Estado: NADA SE HA APLICADO EN PRODUCCIÓN.** Este guion se usa **solo cuando Polo escriba en la sesión de trabajo con Claude, con fecha:**

| Frase | Autoriza |
|---|---|
| «**Autorizo Fase 2 en producción, ventana del `<fecha>`**» | Las 5 migraciones y el despliegue de las Edge Functions (§3 y §4) |
| «**Autorizo desactivar cuentas demo inactivas, ventana del `<fecha>`**» | El bloque 1 del script de cuentas demo inactivas (§6). `edgar` solo con confirmación expresa de Polo |
| Frase aparte, **con las cuentas nombradas** | Forzar el cambio de contraseña de `finanzas`, `lee` y `marco` (§6). Hasta entonces: no hacer nada |
| «**Publica el cambio de contraseña filtrada**» (o la que Polo use) | Mezclar el PR del front y desplegar `complete-password-change` (§5) |

Sin la frase exacta y con fecha, **no se aplica nada**. Si la hora real no está dentro de la ventana permitida, tampoco.

## 1. Ventana

- **Permitida:** sábados y domingos, o entre semana **después de las 19:00 (hora de la Ciudad de México)**. Nunca durante el uso normal de Dazon.
- **Propuesta:** sábado **31 de octubre de 2026**, 10:00 a 15:00 (calendario fijado por Polo), **si la Fase 1 (lunes 26) y el Paquete 1 (jueves 29) salieron limpios**. La observación entre ellas es de días, no de una semana: los criterios de salida limpia se revisan igual. Si alguna ventana anterior se mueve, la Fase 2 se mueve con ella.
- **Una fase por ventana.** No se junta con la Fase 1.
- Avisar a los administradores (uno de ellos en China) al empezar y al terminar.

## 2. Antes de empezar (todo en verde)

1. ☐ **La Fase 1 está aplicada y observada** (`REPORTE-FASE-1.md`). Si no: **detenerse**. Si el diagnóstico (`supabase/diagnostico_esquema.sql`) muestra las seis `20261031…` como `FALTA`, no se sigue.
2. ☐ **Respaldo de Supabase** del día o del anterior, con fecha anotada. *(Pendiente de confirmar por Polo.)*
3. ☐ **Esquema guardado** fuera del repo (`RESPALDO-Y-REVERSA.md`).
4. ☐ **Huellas de producción iguales a la línea base** (`FASE-2-LINEA-BASE-Y-RECORRIDOS.md` §1): `md5(prosrc)` de las 11 funciones y la lista de triggers y políticas de `profiles`, `user_roles` y `super_admins`. **Si algo no coincide: detenerse**; alguien cambió producción desde el 26 oct.
5. ☐ **Línea base repetida:** `consultas/02-conteos-linea-base.sql` y comparar con la Fase 1 terminada. Cifra que no cuadra y no se explica: detenerse.
6. ☐ **Recorridos de pantalla** (Fase 1 y U1–U14) hechos una vez **antes**, con cuentas de prueba, y anotados.
7. ☐ **Dos super admins activos** y alguien que pueda entrar con uno durante la ventana. **No se modifican.**
8. ☐ **Un administrador global** con acceso a Usuarios para revertir desde la pantalla si hace falta, y **alguien con acceso al panel de Supabase**.
9. ☐ **Avisar a las personas** de los cambios de comportamiento (`FASE-2-CAMBIOS-Y-REVERSAS.md` §4): los admins de área ya no crean ni modifican administradores.
10. ☐ **Rama del PR de la Fase 2 revisada y mezclada por una persona** (Claude no hace merge).

## 3. Migraciones (una a la vez, en este orden)

Mecanismo: **Code aplica por el conector de escritura (solo dentro de la ventana y con la frase con fecha), con `execute_sql`, un archivo por llamada dentro de `begin; … commit;` y el registro en `migraciones_aplicadas` en la misma llamada** (ver «Cómo aplica Code por el conector»). **Nunca `apply_migration`.** Si no hay conector, el respaldo es pegar el archivo completo en el SQL Editor (una transacción).

| Orden | Archivo | Verificación esperada (la trae el propio script) | Si falla |
|---|---|---|---|
| 1 | `20261107000001_fase2_perfiles_campos_protegidos.sql` | `1, true` | reversa 1 |
| 2 | `20261107000002_fase2_roles_rango_y_super_admins.sql` | `1, true, true` | reversa 2 |
| 3 | `20261107000003_fase2_profiles_politica_por_area.sql` | `0` y quedan `admin de area actualiza profiles, profiles_update_propio` | reversa 3 |
| 4 | `20261107000004_fase2_cxc_vencidas_solo_quien_ve_al_cliente.sql` | `false, false` | reversa 4 |
| 5 | `20261107000005_fase2_super_admins_rastro.sql` | `1, true` | reversa 5 (opcional) |

Después de **cada una:**
1. Comparar la verificación con la tabla.
2. `consultas/02-conteos-linea-base.sql`: debe cambiar **solo** lo que dice `FASE-2-LINEA-BASE-Y-RECORRIDOS.md` §1 (funciones +2, security definer ejecutables −2, políticas −1).
3. **Recorridos por rol.** Obligatorios tras el cambio 1: **U1, U2, U9, U10** (editar, activar, cambiar su nombre, alta). Tras el 2: **U3 a U8**. Tras el 4: **U12 y U13** (la remisión a un cliente moroso debe bloquearse).
4. Registros de la API (`edge_logs`) y de la compuerta: ningún `5xx` ni `42501` nuevo que no esté en la línea base.
5. Registrar: `INSERT INTO public.migraciones_aplicadas (script, estado, notas) VALUES ('<archivo sin .sql>', 'aplicado', 'Fase 2, ventana del <fecha>');`
6. Solo entonces la siguiente.

## 4. Edge Functions (después de las migraciones)

Flujo manual `deploy-edge-functions.yml` (Actions → *Run workflow*), **una función a la vez**, en este orden:
1. `admin-update-user` → comprobar **U1, U3, U4, U5, U7, U8, U14**.
2. `admin-create-user` → **U6, U10**.
3. `admin-reset-user-password` → **U11**.
`seed-demo-users` no se despliega a menos que Polo lo pida (sigue apagada).

**Comprobación del rastro (obligatoria):** tras la primera edición exitosa debe haber un renglón nuevo en `bridge_bitacora` con `accion = 'usuario.editar'`, el actor y la correlación. **Si no aparece o la función contesta 503, detenerse y revertir** (el rastro es obligatorio).

## 5. Contraseña filtrada (aparte, otro momento)

1. Mezclar el PR del front [kit-to-drive#74](https://github.com/Lbassoco95/kit-to-drive/pull/74) y esperar el despliegue en Vercel.
2. Desplegar `complete-password-change` (flujo manual).
3. Hacer las 5 pruebas de `CONTRASENAS-FILTRADAS.md` §3 con cuentas de prueba, **antes** de activar nada.
4. **Solo entonces, Polo activa la protección en el panel de Supabase.** No se activa por API ni desde Claude.

## 6. Cuentas demo (con sus propias frases)

Solo **dentro de la ventana**, **en producción** (nunca QA), en el SQL Editor, una transacción, comprobando la verificación.

| Script | Antes | Verificación | Reversa |
|---|---|---|---|
| `supabase/operaciones/fase2-desactivar-cuentas-demo-inactivas.sql` (bloque 1) | Las 5 cuentas con perfil inactivo (el script lo comprueba y aborta si no) | `bloqueadas = 5` | `…_reversa.sql` |
| `…forzar-cambio-password-demo-activas.sql` | Polo dijo quiénes son las 3 cuentas | `3 y 3` | `…_reversa.sql` |

Después del bloqueo: confirmar que **`finanzas`, `lee` y `marco` siguen entrando** (el script no los toca).

## 7. Cuándo detenerse y revertir

Detener y aplicar la **reversa de esa pieza** (y de las anteriores si hace falta, en orden inverso) si, tras cualquier cambio:
- falla un recorrido por rol que antes pasaba;
- un usuario legítimo pierde una acción que tenía (p. ej. un administrador global no puede editar a un usuario normal);
- aumentan los `401/403/5xx` respecto a la línea base;
- la medición posterior no coincide con la prevista;
- una remisión a un cliente con cartera vencida deja de bloquearse (U12) o un vendedor no puede crear una remisión normal (U13);
- el rastro no aparece (§4).
`REVOKE`/`DROP` que falle por dependencia: **no** insistir con `CASCADE`; detenerse y reportar.

**Reversa de todo, en orden:** funciones (volver a desplegar la versión anterior) → migraciones `…05` a `…01` → scripts de cuentas demo (sus reversas). Comprobar con `02-conteos-linea-base.sql` que se recuperó la línea base.

## 8. Después de la ventana

1. Repetir la línea base completa y guardarla como `REPORTE-FASE-2.md`: por cada pieza, qué cambió, conteos antes y después, recorridos por rol, reversa probada, y lo que falló o se pospuso.
2. Avisar a los administradores.
3. Observación antes de la Fase 3 (la duración la fija Polo).
4. **No se hace en esta ventana:** rendimiento y políticas duplicadas (Fase 3), auditoría central (Fase 4), rotación de la llave `anon`, protección de ramas, limpieza del historial de git, contraseñas filtradas (§5, aparte).

## 9. Lo que solo puede hacer Polo

- Escribir las frases de autorización.
- Confirmar quién es `finanzas` y si `test-scan` es una persona. Ya confirmado: `edgar` es un exempleado (se bloquea con su script), `marco` y `lee` son personas reales (marco queda como está; lee migra a su correo real).
- Activar la protección de contraseñas filtradas en el panel (después de §5).
- Activar el segundo factor con Peter (cuenta `qq.com`).
- ~~Decidir la opción A/B de `asignar_super_admin`~~ **Decidido: A en la Fase 2 y B después** (migración `20261110000001`, lista y sin aplicar). Las cuentas de `yoltik.mx` (Carmen y JC) son administradores legítimos: deben entrar y cambiar su contraseña esta semana; si no, se prepara su bloqueo temporal.

## Cómo aplica Code por el conector

**Regla vigente (26 oct, Polo):** Code aplica por el conector de Supabase **solo dentro de una ventana y solo con la frase de autorización con fecha** escrita por Polo en la sesión. Fuera de ventana, el conector es **solo lectura** (conteos, huellas y catálogo; nunca filas con datos personales). Esto sustituye la prohibición anterior de usar el conector, **solo para este caso**. Seguido valen: no tocar QA, no borrar usuarios ni datos, no iniciar sesión en cuentas, ningún secreto en chat, archivos ni reportes.

### Los dos conectores (solo producción, sin secretos en la URL)

La referencia del proyecto va **en la URL**: el conector no puede ver ningún otro proyecto, QA incluido. La autenticación es el inicio de sesión de Polo en el navegador (OAuth); no hay contraseña ni token en la URL.

| Nombre | URL | Cuándo está habilitado |
|---|---|---|
| `supabase-prod-lectura` | `https://mcp.supabase.com/mcp?project_ref=dmhzhyeivvuliumcgsmm&read_only=true&features=database,development,debugging` | Siempre (solo lectura) |
| `supabase-prod-escritura` | `https://mcp.supabase.com/mcp?project_ref=dmhzhyeivvuliumcgsmm&features=database,development` | **Solo dentro de la ventana**: se agrega después de la frase y se quita al terminar el último paso |

`features` limita los grupos de herramientas (verificado por Polo en la documentación de Supabase): `database` trae `execute_sql` y **también `apply_migration`** (ambas están en el mismo grupo y **no se pueden separar por URL**); `development` trae `get_project_url`; `debugging` (solo en lectura) trae `query_logs`. Si el cliente no reconoce las comas en `features`, se usa `%2C` (`features=database%2Cdevelopment`). La URL **debe llevar `project_ref=dmhzhyeivvuliumcgsmm`**: fija el proyecto y no existe argumento para cambiarlo.

**`apply_migration` queda prohibida por regla, no por URL.** Polo la rechaza siempre: si aparece una solicitud de `apply_migration`, se rechaza. **Antes de cada llamada Code dice qué herramienta va a usar** (siempre `execute_sql` para aplicar y revertir; `get_project_url` y, en lectura, `query_logs`).

**Vía principal: conector personalizado en claude.ai (no requiere el CLI `claude`)**

Polo no tiene instalado el CLI `claude`; su vía es **claude.ai → Configuración → Conectores → Agregar conector personalizado**. Se agrega uno por cada fila de la tabla de arriba:

1. **Nombre:** `supabase-prod-lectura` (o `supabase-prod-escritura`).
2. **URL del servidor MCP remoto:** la de la tabla, completa y sin espacios.
3. No hay campos de secretos que llenar. Al agregarlo, claude.ai pide iniciar sesión en Supabase en el navegador (OAuth); **Polo elige la organización dueña de `kit-to-drive`** y autoriza.
4. En los permisos de herramientas del conector, dejar **«Pedir aprobación»** en todas (en el de escritura, `execute_sql` siempre con aprobación manual). `apply_migration` se rechaza siempre.
5. Para **quitarlo**: Configuración → Conectores → el conector → **Desconectar / Eliminar**. Confirmar que ya no aparece en la lista.

> ⚠️ **Un conector agregado en claude.ai queda disponible en TODA la cuenta de Polo (todas sus sesiones), no solo en esta.** Por eso: el conector de **lectura** se agrega antes y puede quedarse (solo lee y está fijado a producción); el de **escritura se agrega SOLO dentro de la ventana, después de la frase, y se quita en cuanto termina el último paso** (y los bloques finales se pegaron), **no al día siguiente**. Mientras exista, cualquier sesión de Polo podría proponer una escritura en producción; la aprobación manual de cada llamada es la última barrera, no la primera. Si la ventana se interrumpe, se quita y se vuelve a agregar al retomar.

**Alternativa: CLI `claude` en terminal** (solo si Polo lo instala; no es la vía prevista). **No se usa `--scope project`**: guardaría la configuración del conector en el repo (`.mcp.json`); se usa el alcance **local**.

```bash
claude mcp add --transport http --scope local supabase-prod-lectura "https://mcp.supabase.com/mcp?project_ref=dmhzhyeivvuliumcgsmm&read_only=true&features=database,development,debugging"
claude mcp add --transport http --scope local supabase-prod-escritura "https://mcp.supabase.com/mcp?project_ref=dmhzhyeivvuliumcgsmm&features=database,development"
claude mcp remove supabase-prod-escritura --scope local
claude mcp list
```

**Esperado:** `list` muestra el de lectura siempre y el de escritura solo durante la ventana.

### Cuando Polo avise que agregó el conector de lectura

Antes de cualquier ventana, Code hace dos comprobaciones y pega el resultado: (1) **confirma que no puede escribir** (la prueba es una consulta de solo lectura permitida y un intento de escritura inofensivo que debe ser rechazado por el modo solo lectura; si la escritura se acepta, se avisa a Polo de inmediato y se quita el conector); (2) **prueba `query_logs`** para el bloque D2 y dice si funciona.

### Condiciones de cada llamada

- **Aprobación manual de cada llamada** (permiso «preguntar» para `execute_sql` en el conector de escritura). Nada se aprueba por adelantado.
- **Antes de cada escritura**, Code llama a `get_project_url` y pega el resultado. Debe decir `https://dmhzhyeivvuliumcgsmm.supabase.co`. Si dice `qszllskpizvpnzcytqpj` (QA) o cualquier otra cosa: **detenerse**. **Además confirma la identidad con el bloque 0** (`zz_lista_oct = 2219`, `super_admins = 2`), también antes de cada escritura: `project_ref` fija el proyecto, pero el bloque 0 lo comprueba por los datos.
- **Antes de cada llamada, Code dice qué herramienta va a usar.** Aplicar y revertir es siempre `execute_sql`; **nunca `apply_migration`**.
- Se aplica con **`execute_sql`, un archivo por llamada, dentro de `begin; … commit;`**, con el `INSERT` en `migraciones_aplicadas` **en la misma llamada**. **No se usa `apply_migration`.**
- Antes de cada llamada Code pega la huella (`sha256`) del archivo que va a enviar; Polo la compara con la que ya verificó en su terminal.
- **Después de cada paso** Code pega en el chat los resultados de **V, A1 y A3** y **espera el «sigue» de Polo** antes del siguiente.
- **La primera escritura de la ventana es M1** (de la Fase 1 o del Paquete 1, según la ventana). Si no se comporta como una sola transacción (queda algo a medias tras un error) o si V no coincide con lo esperado: **detenerse y revertir** con la reversa del paso.
- **Antes de M3 de la Fase 1 (`fijar_search_path`), Code corre `show search_path;`** (con `execute_sql`, solo lectura) y pega el resultado: debe incluir `public`. Si no, se detiene.
- Las reversas se aplican por el mismo camino, una por llamada, con su propia aprobación.

### Momento exacto, durante la ventana

| # | Quién | Qué | Cuándo |
|---|---|---|---|
| 1 | Polo | Escribe la frase con fecha | Al abrir la ventana, ya con respaldo y persona de pruebas |
| 2 | Polo | **Agrega** `supabase-prod-escritura` en claude.ai (y verifica que el general esté desconectado) | Justo después de la frase |
| 3 | Code | `get_project_url`, bloque 0 y V, A1 y A3 «antes» por lectura | Antes de la primera escritura |
| 4 | Code | Aplica un paso, pega V, A1 y A3 | Cada paso; espera «sigue» |
| 5 | Polo | **Quita** (Desconectar/Eliminar) `supabase-prod-escritura` | En cuanto se aplica el último paso y se pegan los bloques finales, **o** a la hora de cierre de la ventana, lo que ocurra primero |
| 6 | Code | Confirma por lectura que ya no puede escribir | Después de quitarlo |

Si la ventana se interrumpe (algo falla y se pausa), Polo quita el conector de escritura y lo vuelve a agregar al retomar.

### Qué hacer con el conector general de claude.ai en la sesión

**Recomendación: desconectarlo** (claude.ai → Configuración → Conectores → Supabase → Desconectar) antes de la primera ventana, y trabajar solo con los dos conectores de arriba. El general ve **todos** los proyectos y organizaciones de la cuenta, QA entre ellos, y expone herramientas que no hacen falta y que son riesgosas (crear/pausar/restaurar proyectos, ramas, desplegar funciones). Además, con el general la comprobación `get_project_url` no protege: ahí el proyecto se le pasa a la herramienta como argumento, y un error de identificador llegaría a otro proyecto. Con el conector acotado por URL no existe ese argumento. Si no se puede desconectar, dejar **en «Nunca»** todas sus herramientas de escritura y de administración, y **no usarlo** para nada.

### Verificación del conector de lectura (26 oct, hecha por Code)

| Prueba | Resultado |
|---|---|
| `get_project_url` | `https://dmhzhyeivvuliumcgsmm.supabase.co` (producción) |
| Bloque 0 por lectura | `zz_lista_oct = 2219`, `super_admins = 2`, registro = 90, `transaction_read_only = on` |
| Escritura inocua (`UPDATE … WHERE false`, ninguna fila) | **Rechazada**: `25006: cannot execute UPDATE in a read-only transaction` |
| `query_logs` | **Funciona** (ver abajo) |

### D2 por `query_logs` (probado el 26 oct: funciona)

`query_logs` usa **ClickHouse** sobre la tabla `logs`. Code corre D2 por ahí, sin que Polo pegue nada, al empezar y al terminar cada ventana (la ventana máxima es de 24 h). Solo se piden conteos.

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

**Línea base del 26 oct (últimas 24 h):** API `400` = 2 y `401` = 4 (sin 403 ni 5xx); Postgres `ERROR` = 6. **Esperado:** no suben los 401, 403 ni 5xx ni los errores de Postgres. Si en una ventana falla o no coincide con el Logs Explorer, Polo corre D2 como alternativa (`RUNBOOK-FINAL-FASE-1.md` §10).

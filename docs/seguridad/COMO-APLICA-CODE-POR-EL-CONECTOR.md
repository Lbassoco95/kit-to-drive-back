# Cómo aplica Code por el conector (producción)

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


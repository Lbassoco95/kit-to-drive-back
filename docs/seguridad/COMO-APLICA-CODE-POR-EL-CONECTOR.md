# Cómo aplica Code por el conector (producción)

## Cómo aplica Code por el conector

**Regla vigente (26 oct, Polo):** Code aplica por el conector de Supabase **solo dentro de una ventana y solo con la frase de autorización con fecha** escrita por Polo en la sesión. Fuera de ventana, el conector es **solo lectura** (conteos, huellas y catálogo; nunca filas con datos personales). Esto sustituye la prohibición anterior de usar el conector, **solo para este caso**. Seguido valen: no tocar QA, no borrar usuarios ni datos, no iniciar sesión en cuentas, ningún secreto en chat, archivos ni reportes.

### Los dos conectores (solo producción, sin secretos en la URL)

La referencia del proyecto va **en la URL**: el conector no puede ver ningún otro proyecto, QA incluido. La autenticación es el inicio de sesión de Polo en el navegador (OAuth); no hay contraseña ni token en la URL.

| Nombre | URL | Cuándo está habilitado |
|---|---|---|
| `supabase-prod-lectura` | `https://mcp.supabase.com/mcp?project_ref=dmhzhyeivvuliumcgsmm&read_only=true&features=database` | Siempre (solo lectura) |
| `supabase-prod-escritura` | `https://mcp.supabase.com/mcp?project_ref=dmhzhyeivvuliumcgsmm&features=database` | **Solo dentro de la ventana**, de que Polo escribe la frase a que cierra la ventana |

`features=database` deja solo las herramientas de base de datos (entre ellas `execute_sql`); no se publican las de proyectos, ramas ni funciones. **Verifica estos parámetros contra la documentación vigente de Supabase antes de la primera ventana** (no pude consultarla desde mi entorno al escribir esto); lo que no cambia es la regla: la URL **debe llevar `project_ref=dmhzhyeivvuliumcgsmm`**.

**Agregar y quitar (Claude Code en terminal)**

```bash
claude mcp add --transport http supabase-prod-lectura "https://mcp.supabase.com/mcp?project_ref=dmhzhyeivvuliumcgsmm&read_only=true&features=database"
claude mcp add --transport http supabase-prod-escritura "https://mcp.supabase.com/mcp?project_ref=dmhzhyeivvuliumcgsmm&features=database"
claude mcp remove supabase-prod-escritura
claude mcp list
```

**Esperado:** `list` muestra `supabase-prod-lectura` siempre y `supabase-prod-escritura` solo durante la ventana. En una sesión en la nube, el mismo par de URL se agrega como conector personalizado en claude.ai (**Configuración → Conectores → Agregar conector personalizado**) y se quita con **Desconectar**; Polo elige la ruta que corresponda a la sesión.

### Condiciones de cada llamada

- **Aprobación manual de cada llamada** (permiso «preguntar» para `execute_sql` en el conector de escritura). Nada se aprueba por adelantado.
- **Antes de cada escritura**, Code llama a `get_project_url` y pega el resultado. Debe decir `https://dmhzhyeivvuliumcgsmm.supabase.co`. Si dice `qszllskpizvpnzcytqpj` (QA) o cualquier otra cosa: **detenerse**.
- Se aplica con **`execute_sql`, un archivo por llamada, dentro de `begin; … commit;`**, con el `INSERT` en `migraciones_aplicadas` **en la misma llamada**. **No se usa `apply_migration`.**
- Antes de cada llamada Code pega la huella (`sha256`) del archivo que va a enviar; Polo la compara con la que ya verificó en su terminal.
- **Después de cada paso** Code pega en el chat los resultados de **V, A1 y A3** y **espera el «sigue» de Polo** antes del siguiente.
- **La primera escritura de la ventana es M1** (de la Fase 1 o del Paquete 1, según la ventana). Si no se comporta como una sola transacción (queda algo a medias tras un error) o si V no coincide con lo esperado: **detenerse y revertir** con la reversa del paso.
- Las reversas se aplican por el mismo camino, una por llamada, con su propia aprobación.

### Momento exacto, durante la ventana

| # | Quién | Qué | Cuándo |
|---|---|---|---|
| 1 | Polo | Escribe la frase con fecha | Al abrir la ventana, ya con respaldo y persona de pruebas |
| 2 | Polo | **Habilita** `supabase-prod-escritura` (y verifica que el general de claude.ai esté desconectado) | Justo después de la frase |
| 3 | Code | `get_project_url` + V, A1 y A3 «antes» por lectura | Antes de la primera escritura |
| 4 | Code | Aplica un paso, pega V, A1 y A3 | Cada paso; espera «sigue» |
| 5 | Polo | **Deshabilita** (quita) `supabase-prod-escritura` | En cuanto se aplica el último paso y se pegan los bloques finales, **o** a la hora de cierre de la ventana, lo que ocurra primero |
| 6 | Code | Confirma por lectura que ya no puede escribir | Después de quitarlo |

Si la ventana se interrumpe (algo falla y se pausa), Polo quita el conector de escritura hasta que se retome.

### Qué hacer con el conector general de claude.ai en la sesión

**Recomendación: desconectarlo** (claude.ai → Configuración → Conectores → Supabase → Desconectar) antes de la primera ventana, y trabajar solo con los dos conectores de arriba. El general ve **todos** los proyectos y organizaciones de la cuenta, QA entre ellos, y expone herramientas que no hacen falta y que son riesgosas (crear/pausar/restaurar proyectos, ramas, desplegar funciones). Además, con el general la comprobación `get_project_url` no protege: ahí el proyecto se le pasa a la herramienta como argumento, y un error de identificador llegaría a otro proyecto. Con el conector acotado por URL no existe ese argumento. Si no se puede desconectar, dejar **en «Nunca»** todas sus herramientas de escritura y de administración, y **no usarlo** para nada.


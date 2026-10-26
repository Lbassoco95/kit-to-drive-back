# Ventana del Paquete 1 (permisos del vendedor) — guion

**Estado: NADA APLICADO.** Propuesta: **jueves 29 de octubre de 2026, de 19:00 a 22:00 (CDMX)**. Frase (la escribe Polo, con fecha, en la sesión): «Autorizo paquete 1 (permisos de vendedor) en producción, ventana del `<fecha>`». Claude no usa el conector de Supabase de claude.ai (ni para leer) ni aplica nada: Polo corre los comandos y pega los resultados.

## 1. Antes de abrir la ventana (todo en verde)

☐ Frase con fecha, y hora dentro de la ventana permitida (entre semana, después de las 19:00).
☐ **La Fase 1 salió limpia:** los bloques V, A1 y A3 del `docs/seguridad/RUNBOOK-FINAL-FASE-1.md` repetidos **el miércoles 28 y el jueves 29 antes de empezar**, sin diferencias inexplicadas. *Claude vuelve a pegar esos bloques en el chat el día de la ventana.*
☐ **Respaldo** del mismo día o del anterior (fecha y hora escritas en la sesión).
☐ **Front publicado o no, da igual:** funciona en cualquier orden (si la RPC no existe, usa lo que ya leía). Aun así, el orden recomendado es **migraciones primero, front después**.
☐ **Persona de pruebas** y **cuentas**: un vendedor **sin clientes asignados**, **otro** vendedor, un supervisor de Comercial, un administrativo de Comercial y Dirección. Las contraseñas las maneja ella; nunca en el chat.
☐ **Dos clientes de prueba sin vendedor** creados antes por un supervisor, con nombre «ZZ PRUEBA P1 sin asignar A» y «… B» (se desactivan al final; **no se borran**).
☐ Terminal lista: las 6 piezas del paquete (`supabase/migrations/2026110300000*.sql` y sus reversas) presentes; `source scripts/ventana/conectar.sh`; `export FECHA=2026-10-29`; `mkdir -p ventana-logs`.
☐ Aviso al equipo de Dazon (el día anterior y al empezar).

## 2. Pasos (en este orden) y tiempos

*Estimaciones, no mediciones.* **Total previsto: 2 h 15 min** (preparación 30 min, M1 25, M2 35, M3 25, cierre 20) más colchón hasta las 22:00.

| Paso | Archivo | Qué cambia | Recorridos (§5) | Estimado |
|---|---|---|---|---|
| M1 | `20261103000001_paquete1_catalogo_basico_clientes` | Función `catalogo_clientes_basico()` (catálogo de 6 columnas) | R1–R5 | 25 min |
| M2 | `20261103000002_paquete1_cliente_nuevo_a_nombre_del_vendedor` | Cliente nuevo del vendedor a su nombre; la remisión solo a un cliente que ya ve (2 triggers, 3 funciones) | R6–R8 | 35 min |
| M3 | `20261103000003_paquete1_remisiones_refacciones_solo_del_vendedor` | `puede_leer_remision_refaccion` ya no incluye todo Comercial | R9–R11 | 25 min |

### Paso M1

```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/migrations/20261103000001_paquete1_catalogo_basico_clientes.sql \
  -c "INSERT INTO public.migraciones_aplicadas (script, estado, notas) VALUES ('20261103000001_paquete1_catalogo_basico_clientes', 'aplicado', 'Paquete 1, ventana del $FECHA') ON CONFLICT (script) DO UPDATE SET estado='aplicado', aplicada_at=now(), notas=EXCLUDED.notas" \
  2>&1 | tee "ventana-logs/aplicar-P1-M1.log"
```

**Esperado en pantalla:** sin la palabra `ERROR`, y una fila `funcion_definer_con_search_path` = `1`, `authenticated_ejecuta` = `t`, `anon_ejecuta` = `f`, `columnas_que_devuelve` = `6`.

### Paso M2

```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/migrations/20261103000002_paquete1_cliente_nuevo_a_nombre_del_vendedor.sql \
  -c "INSERT INTO public.migraciones_aplicadas (script, estado, notas) VALUES ('20261103000002_paquete1_cliente_nuevo_a_nombre_del_vendedor', 'aplicado', 'Paquete 1, ventana del $FECHA') ON CONFLICT (script) DO UPDATE SET estado='aplicado', aplicada_at=now(), notas=EXCLUDED.notas" \
  2>&1 | tee "ventana-logs/aplicar-P1-M2.log"
```

**Esperado en pantalla:** sin `ERROR`, y una fila `funciones_nuevas` = `3`, `triggers_nuevos` = `2`, `ejecutables_por_anon_o_authenticated` = `0`.

### Momento exacto: mezclar el PR #8 de la compuerta (después de verificar M1 y M2, antes de las pruebas)

**Mezclar el PR #8 de `kit-to-drive-front` (base `main`) despliega en producción en Vercel.** No se mezcla antes de la ventana. Se hace **una vez verificados M1 y M2 (bloque de la §3 igual a la §4) y antes de que la persona de pruebas haga R1–R8**. Después de mezclar: esperar a que Vercel marque el despliegue como *Ready* y anotar el commit; si la compuerta falla, se revierte el commit de la mezcla en `main` (el front cae solo a la ficha, no se pierde nada). El M3 se aplica después, con R9–R11.

### Paso M3

```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/migrations/20261103000003_paquete1_remisiones_refacciones_solo_del_vendedor.sql \
  -c "INSERT INTO public.migraciones_aplicadas (script, estado, notas) VALUES ('20261103000003_paquete1_remisiones_refacciones_solo_del_vendedor', 'aplicado', 'Paquete 1, ventana del $FECHA') ON CONFLICT (script) DO UPDATE SET estado='aplicado', aplicada_at=now(), notas=EXCLUDED.notas" \
  2>&1 | tee "ventana-logs/aplicar-P1-M3.log"
```

**Esperado en pantalla:** sin `ERROR`, y una fila `sin_comercial_en_la_lista` = `t`, `con_administrativo` = `t`.

Si hay `ERROR`, no quedó nada aplicado (una sola transacción): pasa el texto a Claude y **no repitas**. *El comando termina en `| tee`, así que su código de salida no avisa de un error: lee la pantalla.*

## 3. Verificación después de cada paso (SQL Editor, solo lectura)

**Esperado:** las columnas de la tabla de la §4 para ese momento. Si el editor solo muestra «Success. No rows returned», borra las dos líneas de los extremos (`begin read only;` y `rollback;`) y corre solo el `select`. **Anota los valores de `triggers`, `clientes`, `clientes_sin_vendedor` y `registros_migraciones` ANTES del paso M1.**

```sql
-- Verificación del PAQUETE 1 después de cada migración (y después de cada reversa). SOLO LECTURA. Una fila.
begin read only;
select
 (select count(*) from pg_policies where schemaname = 'public') as politicas,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prokind in ('f', 'p')) as funciones,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind in ('f', 'p') and p.prosecdef and has_function_privilege('authenticated', p.oid, 'EXECUTE')) as secdef_authenticated,
 (select count(*) from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and not t.tgisinternal) as triggers,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'catalogo_clientes_basico' and p.prosecdef
     and exists (select 1 from unnest(p.proconfig) x where x like 'search_path=%')) as catalogo_definer_con_search_path,
 coalesce((select has_function_privilege('authenticated', p.oid, 'EXECUTE') from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'catalogo_clientes_basico'), false) as catalogo_authenticated_ejecuta,
 coalesce((select has_function_privilege('anon', p.oid, 'EXECUTE') from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'catalogo_clientes_basico'), false) as catalogo_anon_ejecuta,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('es_vendedor_comercial', 'clientes_asignar_vendedor_al_crear', 'remisiones_validar_cliente_visible')) as funciones_alta_cliente,
 (select count(*) from pg_trigger where not tgisinternal and tgname in ('trg_clientes_asignar_vendedor', 'trg_remisiones_validar_cliente')) as triggers_alta_cliente,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('es_vendedor_comercial', 'clientes_asignar_vendedor_al_crear', 'remisiones_validar_cliente_visible')
     and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('authenticated', p.oid, 'EXECUTE'))) as alta_cliente_ejecutables,
 pg_get_functiondef('public.puede_leer_remision_refaccion(uuid,uuid)'::regprocedure) ilike '%es_administrativo_comercial%' as refacciones_con_administrativo,
 pg_get_functiondef('public.puede_leer_remision_refaccion(uuid,uuid)'::regprocedure) !~ $q$'almacen_logistica', 'comercial'$q$ as refacciones_sin_comercial,
 (select count(*) from public.clientes) as clientes,
 (select count(*) from public.clientes where vendedor_id is null) as clientes_sin_vendedor,
 (select count(*) from public.migraciones_aplicadas) as registros_migraciones;
rollback;
```

Además, después de cada paso se repiten, **antes** de que la persona de pruebas entre al sistema, los bloques **V** (permisos), **A1** (con la foto de integridad de esa mañana) y **A3** (Auth y Storage) del runbook de la Fase 1. **No deben cambiar** salvo `registros_migraciones` y `filas_totales` (+1 por paso) y, **solo en el bloque V del runbook de la Fase 1, `secdef_authenticated` (+1 desde M1: 178 → 179)**, porque el catálogo es una función que `authenticated` ejecuta a propósito. *El paquete 1 no cambia ningún dato por sí mismo; los únicos datos que pueden cambiar son los que cree la persona de pruebas.*

## 4. Valores esperados

(`T0` = `triggers` antes; `C` = `clientes`; `S` = `clientes_sin_vendedor`; `R0` = `registros_migraciones`, **96** si la Fase 1 quedó completa. Salen del ensayo local: funciones 268 → 272, triggers +2, SECDEF ejecutables +1, políticas 301.)

| Momento | `politicas` | `funciones` | `secdef_authenticated` | `triggers` | `catalogo_definer_con_search_path` | `catalogo_authenticated_ejecuta` | `catalogo_anon_ejecuta` | `funciones_alta_cliente` | `triggers_alta_cliente` | `alta_cliente_ejecutables` | `refacciones_con_administrativo` | `refacciones_sin_comercial` | `clientes` | `clientes_sin_vendedor` | `registros_migraciones` |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Antes | 301 | 268 | 178 | T0 | 0 | false | false | 0 | 0 | 0 | false | false | C | S | R0 |
| Tras M1 | 301 | **269** | **179** | T0 | **1** | **true** | false | 0 | 0 | 0 | false | false | C | S | R0+1 |
| Tras M2 | 301 | **272** | 179 | **T0+2** | 1 | true | false | **3** | **2** | 0 | false | false | C (+ los que cree la persona de pruebas) | S (sin cambio: **no** se asigna al usar) | R0+2 |
| Tras M3 | 301 | 272 | 179 | T0+2 | 1 | true | false | 3 | 2 | 0 | **true** | **true** | igual | igual | R0+3 |

## 5. Recorridos de la persona de pruebas (cada uno con su cuenta; anota «Antes» y «Después»)

| # | Después de | Cuenta | Qué hace | Debe pasar |
|---|---|---|---|---|
| R1 | M1 | Vendedor sin clientes | **CRM → Oportunidades → Nueva** | El selector lista clientes (ya no «No hay clientes en el catálogo»); puede elegir uno y guardar |
| R2 | M1 | Vendedor | Abre **Clientes** y busca un cliente de **otro** vendedor | **No** aparece. Sigue viendo solo los suyos (si no tiene, «0 de 0»: es lo esperado) |
| R3 | M1 | Vendedor | Crea una **ruta con una parada** y una **actividad** eligiendo un cliente del catálogo | Funciona |
| R4 | M1 | Vendedor | Abre el **detalle** de una oportunidad cuyo cliente no es suyo | Muestra nombre y código; **sin** crédito, saldo ni documentos; sin errores |
| R5 | M1 | Supervisor | Recorre CRM (listas, detalle, check-in de una parada) | **Igual que antes** (ve todo, ficha completa; el check-in conserva las coordenadas del cliente) |
| R6 | M2 | Vendedor | Crea el cliente «ZZ PRUEBA P1 alta <su nombre>» | Queda **a su nombre** y lo ve en Clientes |
| R7 | M2 | Vendedor | Crea una oportunidad con «ZZ PRUEBA P1 sin asignar A» | Funciona y el cliente **sigue sin asignar** (el vendedor no lo ve en Clientes; un supervisor lo ve sin vendedor) |
| R8 | M2 | Vendedor con un cliente propio | Captura una remisión de motocarro normal | Funciona (y no puede elegir un cliente que no ve) |
| R9 | M3 | Vendedor y **otro** vendedor | **Remisiones** y **Remisiones de refacciones** | Cada uno ve **solo las suyas**, de los dos tipos |
| R10 | M3 | Administrativo, Supervisor, Dirección | Los mismos listados | Ven **todas** (como antes) |
| R11 | M3 | Vendedor | **Entregas**, y crea una remisión de refacciones normal | Solo lo suyo; ve la que acaba de crear |

**Cualquier falla de un recorrido que antes pasaba (R5, R8, R10 y R11, por ejemplo) detiene la ventana.**

## 6. Reversa (orden inverso: M3, M2, M1)

Cada reversa es una transacción y marca el renglón de `migraciones_aplicadas` como `superado` (no se borra). La de M2 **no deshace** los clientes que ya quedaron a nombre de un vendedor al crearse (son datos). **Antes de revertir M1** conviene que el front siga funcionando: lo hace (si la RPC no existe, usa lo que ya leía).

**Revertir M3**

```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/reversas/20261103000003_paquete1_remisiones_refacciones_solo_del_vendedor_reversa.sql \
  -c "UPDATE public.migraciones_aplicadas SET estado='superado', notas='REVERTIDA en la ventana del $FECHA (Paquete 1)' WHERE script='20261103000003_paquete1_remisiones_refacciones_solo_del_vendedor'" \
  2>&1 | tee "ventana-logs/revertir-P1-M3.log"
```

**Revertir M2**

```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/reversas/20261103000002_paquete1_cliente_nuevo_a_nombre_del_vendedor_reversa.sql \
  -c "UPDATE public.migraciones_aplicadas SET estado='superado', notas='REVERTIDA en la ventana del $FECHA (Paquete 1)' WHERE script='20261103000002_paquete1_cliente_nuevo_a_nombre_del_vendedor'" \
  2>&1 | tee "ventana-logs/revertir-P1-M2.log"
```

**Revertir M1**

```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/reversas/20261103000001_paquete1_catalogo_basico_clientes_reversa.sql \
  -c "UPDATE public.migraciones_aplicadas SET estado='superado', notas='REVERTIDA en la ventana del $FECHA (Paquete 1)' WHERE script='20261103000001_paquete1_catalogo_basico_clientes'" \
  2>&1 | tee "ventana-logs/revertir-P1-M1.log"
```

**Después de cada reversa:** el bloque de la §3 debe dar la fila «Antes» de la §4 (con `registros_migraciones` sin bajar), salvo lo que ya se haya revertido: M1 revertido deja `catalogo_*` en 0/false y `secdef_authenticated` en 178; M2 revertido deja funciones 269 (o 268 si M1 también) y triggers T0. *Las tres reversas se ensayaron exactas en la réplica.*

## 7. Cuándo detenerse y revertir

Detente (y revierte ese paso y los anteriores, en orden inverso) si: falla un recorrido que antes pasaba; un usuario legítimo pierde algo que tenía; suben los 401, 403 o 5xx contra la línea base (bloque D2 del runbook de la Fase 1, al empezar y al terminar); cualquier conteo o huella de los bloques V, A1 o A3 cambia sin explicación (distinto de `migraciones_aplicadas`, de `secdef_authenticated` +1 y de lo que cree la persona de pruebas); el bloque de la §3 no coincide con la §4. **Son las 21:30 y un paso sigue a medias: se revierte ese paso.**

## 8. Después de la ventana

1. Los bloques de la §3, V, A1, A3 y D2 final, pegados. 2. Los clientes «ZZ PRUEBA P1…» se **desactivan** (no se borran) por un supervisor. 3. Claude escribe `docs/mejoras/RESULTADO-PAQUETE-1.md` con lo medido. 4. **Martin devuelve el nivel a los vendedores subidos a supervisor y asigna clientes** (D6); hasta entonces el vendedor no ve clientes en Clientes. 5. Observación hasta la ventana de la Fase 2 (sábado 31 de octubre, 10:00–15:00).

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


# Ventana del Paquete 1 (permisos del vendedor) — secuencia final · martes 27 de octubre de 2026

**Estado: preparado, NADA APLICADO.** Ventana propuesta: **martes 27 de octubre de 2026, de 19:00 a 00:00 (CDMX)**, con **todo el paquete** (base, compuerta y front) en una sola ventana, y **sin mezclar nada de la Fase 2 ni de los Paquetes 2 y 3**.
Frase (la escribe Polo, en la sesión): **«Autorizo paquete 1 (permisos de vendedor) en producción, ventana del 2026-10-27»**.
Hasta esa frase: el conector de escritura `supabase-prod-escritura` **no está agregado** y Code solo lee.

**Reglas de la ventana (las de siempre):** Code aplica por `execute_sql` del conector de escritura, **un archivo por llamada**, dentro de `begin; … commit;` con su registro en `migraciones_aplicadas` en la misma llamada; **nunca** `apply_migration`; Polo aprueba cada llamada; antes de **cada** escritura, `get_project_url` (debe decir `dmhzhyeivvuliumcgsmm`) y el bloque 0 (`zz_lista_oct = 2219`, `super_admins = 2`); no se toca QA ni se borra nada; Code **no inicia sesión** en ninguna cuenta. **Code no mezcla PR**: lo hace Polo.

## 1. Qué cambia (resumen)

| Pieza | Qué hace | Archivo |
|---|---|---|
| **M1** | Función de solo lectura `catalogo_clientes_basico()`: de todos los clientes devuelve **solo id, código, folio, nombre comercial y activo** (sin teléfono, crédito, saldo, documentos ni cartera). Comercial y Dirección la ejecutan; Finanzas, Almacén, Compras y Fábrica reciben 42501; el usuario de prueba ve solo clientes de prueba | `20261103000001_paquete1_catalogo_basico_clientes` |
| **M2** | El cliente que crea un vendedor queda a su nombre; el vendedor solo captura una remisión a un cliente que **ya ve** (2 triggers, 3 funciones) | `20261103000002_paquete1_cliente_nuevo_a_nombre_del_vendedor` |
| **M3** | El vendedor ve solo **sus** remisiones de refacciones (administrativos, supervisores, Dirección y Almacén conservan lo que ven) | `20261103000003_paquete1_remisiones_refacciones_solo_del_vendedor` |
| **Compuerta** (`kit-to-drive-front` #8) | Agrega `catalogo_clientes_basico` a la lista de permitidos | PR #8 → `main` |
| **Front** (`kit-to-drive` #76) | El CRM elige cliente del catálogo básico; texto de «Clientes» para el vendedor sin clientes (D8) | PR #76 → `main` (desde `main`; **sin la Fase 2**; sustituye al #75, cerrado) |

**La regla del vendedor sobre el crédito** (decidida el 26 oct): ve el crédito de **sus propios** clientes (los suyos y los de sus propias remisiones). **No se toca ninguna política de `clientes` ni de cartera.** **R8 (el vendedor puede además editar el límite de crédito de sus clientes) queda fuera, como paquete aparte.**

## 2. Archivos y huellas (sha256 completo)

| Archivo | sha256 |
|---|---|
| M1 `supabase/migrations/20261103000001_paquete1_catalogo_basico_clientes.sql` | `505aa5d1d16119f8f23f1206142d6c3f31f110954ae085a974484d1cc6620f1a` |
| M2 `…20261103000002_paquete1_cliente_nuevo_a_nombre_del_vendedor.sql` | `ee3d928dd0b2f7559a5ea31b06f4ed18f3a4662da07913cdf12b4c465eac0b70` |
| M3 `…20261103000003_paquete1_remisiones_refacciones_solo_del_vendedor.sql` | `86f9d7fd7bbfa1106c705924e13b9f54fc04de7e31df8166492e00f23b2a3e80` |
| Reversa M1 `supabase/reversas/…0001…_reversa.sql` (**sin cambio**: borra la función por nombre) | `f7d77fef6684075932ea9273c69f1c628a766e823251ab0d9f41c140f3010147` |
| Reversa M2 | `6a76c7118189b04d3143f710b0ac3b1e4f37ca19e7bf85a38a4090a06b10da06` |
| Reversa M3 | `2fd2be7d2903bfd01a2e982015180a9edaab0234baa5a839fa4cdf221dd2c30e` |

Antes de cada llamada Code pega la huella del archivo y la de la llamada completa (con `begin;`, el registro y `commit;`).

## 3. Antes de las 19:00 (lo que debe estar listo)

☐ **Respaldo del mismo día** (fecha y hora escritas en la sesión) — *Polo*.
☐ **Aviso a Dazon** al empezar — *Polo*.
☐ **Persona de pruebas** presente toda la ventana, con **una cuenta real de vendedor** (de preferencia **sin clientes asignados**, como hoy), **otro vendedor**, un **supervisor** de Comercial, un **administrativo** de Comercial y **Dirección**. Las contraseñas las maneja ella; nunca en el chat. *Las cuentas `prueba.*` NO sirven para esto: están en modo prueba y no ven datos reales (solo comprueban que la función responde por rol).* — *Polo*.
☐ **Dos clientes de prueba sin vendedor**, «ZZ PRUEBA P1 sin asignar A» y «B», creados por un supervisor; se **desactivan** al final, no se borran — *Polo / supervisor*.
☐ **PR #8** (compuerta) y **PR #76** (front) revisados y listos para mezclar, **sin mezclar**. Mezclar cualquiera **despliega en producción (Vercel, `main`)**.
☐ **No** mezclar el PR #74 del front ni nada de la Fase 2.
☐ Polo escribe la frase y **agrega `supabase-prod-escritura`**; Code lo verifica con `get_project_url` + bloque 0.

## 4. Secuencia (en este orden)

*Los tiempos son estimaciones, no mediciones; la Fase 1 completa tomó unas 2 horas por 6 pasos.*

| # | Hora aprox. | Qué | Quién | Debe pasar | Detener si |
|---|---|---|---|---|---|
| 0 | 19:00 | Frase, conector de escritura, `get_project_url`, bloque 0, **foto previa** (V, A1, A3, bloque P1V de la §6 y línea base D2 con `query_logs`) | Polo / Code | Todo igual a la foto del día anterior salvo la actividad normal | Algo que no se explica |
| 1 | 19:30 | **M1** (una llamada) | Code (Polo aprueba) | La verificación del archivo da 1 / true / false / **5** | Un error: no quedó nada (una transacción) |
| 2 | +15 min | **V, A1, A3 + bloque P1V** tras M1 | Code | Ver §6, fila «Tras M1» | Cualquier otro cambio |
| 3 | +15 min | **M2** | Code (Polo aprueba) | La verificación da 3 funciones, 2 triggers y 0 ejecutables | Error o cambio en `clientes` / `clientes_sin_vendedor` |
| 4 | +15 min | **V, A1, A3 + P1V** tras M2 | Code | Fila «Tras M2» | Cualquier otro cambio |
| 5 | +15 min | **M3** | Code (Polo aprueba) | La verificación da `sin_comercial_en_la_lista` y `con_administrativo` = true | Error o cambio en datos |
| 6 | +15 min | **V, A1, A3 + P1V** tras M3 | Code | Fila «Tras M3» | Cualquier otro cambio |
| 7 | ~21:00 | **Mezclar el PR #8** (compuerta). Esperar *Ready* en Vercel (`kit-to-drive-api`) y anotar el commit | Polo / Code lee Vercel | Despliegue *Ready*; `/health` responde | Despliegue fallido: revertir el commit de la mezcla |
| 8 | +10 min | **Mezclar el PR #76** (front). Esperar *Ready* en Vercel (`kit-to-drive`) y anotar el commit | Polo / Code lee Vercel | Despliegue *Ready* | Despliegue fallido: revertir el commit de la mezcla |
| 9 | ~21:20 | **Recorridos con el vendedor real** (§7) y los de supervisor, administrativo y Dirección | Persona de pruebas | Todo lo de §7 | Falla de un recorrido que antes pasaba |
| 10 | 22:30 | **Cierre:** V, A1, A3, P1V y D2 final; desactivar los dos «ZZ PRUEBA P1» | Code / supervisor | Estado final de la §6 | — |
| 11 | al terminar | **Polo quita `supabase-prod-escritura`** | Polo | — | — |

**Reglas de tiempo:** **no se empieza ningún paso nuevo (migración o mezcla) después de las 22:45**; un paso a medias se revierte; los recorridos deben terminar antes de las 00:00. **Cada paso deja la base consistente**: si el tiempo se acaba entre pasos, se queda en el último verificado (el front funciona en cualquier orden).

## 5. Verificación (solo lectura)

*Code la corre por el conector de lectura; el bloque va completo y se pega en el chat.*

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

Además, después de **cada** paso, antes de que la persona de pruebas entre: los bloques **V** (permisos), **A1** (huella de las 92 tablas, comparada con la foto previa del mismo día) y **A3** (Auth y Storage) del `docs/seguridad/RUNBOOK-FINAL-FASE-1.md`. **No deben cambiar**, salvo `registros_migraciones` y `filas_totales` (+1 por paso) y, en V, `secdef_authenticated` (+1 desde M1: 178 → 179), porque el catálogo es una función que `authenticated` ejecuta a propósito. La huella de datos cambia solo por la actividad normal (por ejemplo `historial_conexiones`) y por lo que cree la persona de pruebas (clientes «ZZ PRUEBA», oportunidades, remisión de prueba); Code explica cada diferencia contra esa lista.

## 6. Valores esperados

Medidos en producción el 27 oct 2026, 08:48 CDMX, y en la réplica con la Fase 1 completa: `T0` = 240 triggers, `R0` = 96 registros, `C` = 1,786 clientes, `S` = 1,786 sin vendedor. **Se vuelven a medir al empezar la ventana.**

| Momento | `politicas` | `funciones` | `secdef_authenticated` | `triggers` | `catalogo_definer_con_search_path` | `catalogo_authenticated_ejecuta` | `catalogo_anon_ejecuta` | `funciones_alta_cliente` | `triggers_alta_cliente` | `alta_cliente_ejecutables` | `refacciones_con_administrativo` | `refacciones_sin_comercial` | `clientes` | `clientes_sin_vendedor` | `registros_migraciones` |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Antes | 301 | 268 | 178 | 240 | 0 | false | false | 0 | 0 | 0 | false | false | 1,786 | 1,786 | 96 |
| Tras M1 | 301 | **269** | **179** | 240 | **1** | **true** | false | 0 | 0 | 0 | false | false | 1,786 | 1,786 | 97 |
| Tras M2 | 301 | **272** | 179 | **242** | 1 | true | false | **3** | **2** | 0 | false | false | 1,786 (+ los que cree la persona de pruebas) | 1,786 (**no** se asigna al usar) | 98 |
| Tras M3 | 301 | 272 | 179 | 242 | 1 | true | false | 3 | 2 | 0 | **true** | **true** | igual | igual | 99 |

Con M1, la verificación del propio archivo da `columnas_que_devuelve = 5`. Todo lo demás de V, igual: 0 tablas y 0 vistas de anon, 18 vistas de authenticated, 0 funciones de anon, 301 políticas, 0 funciones sin `search_path`.

## 7. Lista para la persona que prueba como vendedor real

*Cada recorrido con **su** cuenta; anota «Antes» (puedes hacerlo ya, antes de la ventana) y «Después». Todo se hace tras publicar el front (paso 8). **Si algo que antes funcionaba deja de funcionar, avisa de inmediato: detiene la ventana.***

**A. Elegir cliente en el CRM (lo que cambia)**
| # | Qué haces | Debe pasar | No debe pasar |
|---|---|---|---|
| V1 | **CRM → Oportunidades → Nueva**: abre el selector de cliente | Lista **todos los clientes** («CÓDIGO · Nombre»), **se puede buscar por nombre y por código**; eliges uno y guardas | «No hay clientes en el catálogo»; que falte la última parte de la lista (son más de 1,700); que aparezca teléfono, RFC o domicilio |
| V2 | **CRM → Rutas**: crea una ruta con una parada, eligiendo un cliente que **no es tuyo** | Funciona | Error de permisos |
| V3 | **CRM → Actividades**: crea una actividad con un cliente que no es tuyo; ábrela y complétala | Funciona; estado y municipio solo se precargan si ves la ficha de ese cliente | Error de permisos |
| V4 | **Detalle de una oportunidad** cuyo cliente no es tuyo | Muestra **nombre y código**; **sin** crédito, saldo, documentos ni datos fiscales; sin errores | «Sin cliente»; datos de crédito o documentos |
| V5 | **CRM → Tracker** | Nombres y códigos de los clientes visibles; sin celdas vacías | Nombres vacíos |
| V6 | **Check-in** de una parada de ruta cuyo cliente no es tuyo | No exige distancia ni «sobrescribe» ubicación; sin errores | Que cambie la ubicación guardada de ese cliente |

**B. Clientes: qué ves y qué no (la regla del crédito)**
| # | Qué haces | Debe pasar | No debe pasar |
|---|---|---|---|
| V7 | **Clientes** (la lista) | **Solo los tuyos** (y los de tus propias remisiones). Si no tienes ninguno: **«Aún no tienes clientes asignados; pídele a tu supervisor que te los asigne»** | Clientes de otro vendedor; clientes sin asignar; «0 de 0» sin el texto nuevo |
| V8 | Abre la ficha de **un cliente tuyo** (o de una de tus remisiones) | Ves ficha, **crédito, saldo y documentos de ese cliente**, y su cartera | — |
| V9 | Busca con el **buscador global** el nombre de un cliente que **no** es tuyo | **No** aparece (el buscador global sigue siendo solo de tus clientes, D10) | Que aparezca su ficha |
| V10 | Crea un cliente «ZZ PRUEBA P1 alta <tu nombre>» | Queda **a tu nombre** y lo ves en Clientes | Que quede sin vendedor |
| V11 | Crea una oportunidad con «ZZ PRUEBA P1 sin asignar A» | Funciona, y el cliente **sigue sin asignar**: **no** lo ves en Clientes | Que se te asigne al usarlo |

**C. Remisiones**
| # | Qué haces | Debe pasar | No debe pasar |
|---|---|---|---|
| V12 | **Remisiones**: captura una remisión de motocarro a **un cliente tuyo** | Funciona; en el selector solo puedes elegir clientes que ves | Elegir un cliente que no ves |
| V13 | **Remisiones de refacciones**: abre la lista | **Solo las tuyas** | Las de otro vendedor |
| V14 | **Entregas** | Solo lo tuyo (motocarros y refacciones) | Entregas de otro vendedor |
| V15 | Crea una remisión de refacciones normal | Funciona y la ves en tu lista | Error o que no aparezca |
| V16 | **Otro vendedor** repite V13 y V14 | Cada uno ve **solo las suyas** | Que se mezclen |

**D. Los demás roles: no cambia nada**
| # | Cuenta | Qué haces | Debe pasar |
|---|---|---|---|
| S1 | **Supervisor** de Comercial | CRM completo (listas, detalle, check-in) y Clientes | **Igual que antes**: ve todo y ficha completa; el check-in conserva las coordenadas |
| S2 | **Administrativo** de Comercial | Remisiones, remisiones de refacciones, Clientes | Ve **todas**, como antes |
| S3 | **Dirección** | Clientes, remisiones, remisiones de refacciones | Ve **todo**, como antes |

**Qué NO mires hoy** (no es parte del paquete): el **límite de crédito** que el vendedor puede editar (R8, paquete aparte) y los clientes **sin asignar** de Martin (D6: Martin los asigna después).

**Qué reportar de cada recorrido:** «pasó» o «no pasó» y, si no, una captura de la pantalla y la hora. Cualquier mensaje de «permission denied», «42501» o «Sin acceso al catálogo» para un vendedor **detiene la ventana**.

## 8. Reversa (orden inverso)

Cada reversa va en **una llamada** `execute_sql` con `begin; … commit;`, aprobada por Polo, y marca el renglón de `migraciones_aplicadas` como `superado` (no se borra). **Frente y compuerta se revierten primero**, con el commit de reversión de la mezcla en `main` (Vercel redespliega; el front cae a leer la ficha, como hoy).

1. Front (PR #76) → revertir el commit de la mezcla; esperar *Ready*.
2. Compuerta (PR #8) → revertir el commit de la mezcla; esperar *Ready*.
3. **M3** → `supabase/reversas/20261103000003_paquete1_remisiones_refacciones_solo_del_vendedor_reversa.sql` + `UPDATE public.migraciones_aplicadas SET estado='superado', notas='REVERTIDA en la ventana del 2026-10-27 (Paquete 1)' WHERE script='20261103000003_paquete1_remisiones_refacciones_solo_del_vendedor'`.
4. **M2** → `…0002…_reversa.sql` (no deshace los clientes que ya quedaron a nombre de un vendedor: son datos; un supervisor puede reasignarlos) + el mismo `UPDATE` con su script.
5. **M1** → `…0001…_reversa.sql` + el mismo `UPDATE` con su script.

Tras cada reversa el bloque P1V debe dar la fila anterior de la §6 (con `registros_migraciones` sin bajar). **Las tres reversas se ensayaron exactas en la réplica con la Fase 1 completa** (huella del catálogo antes = tras la reversa: `762bf1003d58d0e026a48e0d6e8f784e`).

## 9. Cuándo detenerse

Detente (y revierte ese paso y los anteriores) si: falla un recorrido que antes pasaba (S1–S3 o V12–V16); un usuario legítimo pierde algo que tenía; suben los 401, 403 o 5xx contra la línea base D2; cualquier conteo o huella de V, A1 o A3 cambia sin explicación (distinto de `migraciones_aplicadas`, de `secdef_authenticated` +1 y de lo que cree la persona de pruebas); el bloque P1V no coincide con la §6; un despliegue de Vercel falla.

## 10. Después de la ventana

1. V, A1, A3, P1V y D2 final, pegados. 2. Los clientes «ZZ PRUEBA P1…» se **desactivan** (no se borran). 3. Code escribe `docs/mejoras/RESULTADO-PAQUETE-1.md` con lo medido. 4. **Martin** devuelve el nivel a los vendedores subidos a supervisor y **asigna clientes** (D6); hasta entonces el vendedor ve su lista de Clientes vacía con el texto nuevo. 5. **R8** (límite de crédito editable por el vendedor) pasa a su paquete aparte. 6. Observación hasta la ventana de la Fase 2.

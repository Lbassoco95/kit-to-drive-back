# Ventana del Paquete 1 (permisos del vendedor) — guion

**Estado: NADA APLICADO.** Propuesta: **martes 3 de noviembre de 2026, de 19:00 a 21:30 (CDMX)**. Frase (la escribe Polo, con fecha, en la sesión): «Autorizo paquete 1 (permisos de vendedor) en producción, ventana del `<fecha>`». Claude no usa el conector de Supabase de claude.ai (ni para leer) ni aplica nada: Polo corre los comandos y pega los resultados.

## 1. Antes de abrir la ventana (todo en verde)

☐ Frase con fecha, y hora dentro de la ventana permitida (entre semana, después de las 19:00).
☐ **La Fase 1 salió limpia:** los bloques V, A1 y A3 del `docs/seguridad/RUNBOOK-FINAL-FASE-1.md` repetidos **el domingo y el lunes**, sin diferencias inexplicadas. *Claude vuelve a pegar esos bloques en el chat el día de la ventana.*
☐ **Respaldo** del mismo día o del anterior (fecha y hora escritas en la sesión).
☐ **Diagnóstico de la causa corrido** (`DIAGNOSTICO-VENDEDOR.md` §4) y pegado: se confirma que hay clientes sin vendedor y que Carlos no tiene ninguno asignado.
☐ **Persona de pruebas** y **cuentas**: un vendedor sin clientes asignados (como Carlos), **otro** vendedor, un supervisor de Comercial, un administrativo de Comercial y Dirección. Las contraseñas las maneja ella; nunca en el chat.
☐ **Dos clientes de prueba sin vendedor** creados antes por un supervisor, con nombre «ZZ PRUEBA P1 sin asignar A» y «… B» (se desactivan al final; **no se borran**).
☐ Terminal lista en la rama revisada: las 6 piezas del paquete (`supabase/migrations/2026110300000*.sql` y sus reversas) presentes; `source scripts/ventana/conectar.sh`; `export FECHA=<AAAA-MM-DD>`; `mkdir -p ventana-logs`.
☐ Aviso al equipo de Dazon (el día anterior y al empezar).

## 2. Pasos (en este orden) y tiempos

*Estimaciones, no mediciones.* **Total previsto: 2 h 15 min** (preparación 30 min, M1 25, M2 35, M3 25, cierre 20) más colchón hasta las 21:30.

| Paso | Archivo | Qué cambia | Recorridos (§5) | Estimado |
|---|---|---|---|---|
| M1 | `20261103000001_paquete1_clientes_sin_asignar_visibles` | La política `leer clientes` agrega «sin vendedor» | R1–R3 | 25 min |
| M2 | `20261103000002_paquete1_crm_cliente_visible_y_asignacion` | 4 funciones y 7 triggers (alta de cliente y CRM) | R4–R7 | 35 min |
| M3 | `20261103000003_paquete1_remisiones_refacciones_solo_del_vendedor` | `puede_leer_remision_refaccion` ya no incluye todo Comercial | R8–R11 | 25 min |

### Paso M1

```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/migrations/20261103000001_paquete1_clientes_sin_asignar_visibles.sql \
  -c "INSERT INTO public.migraciones_aplicadas (script, estado, notas) VALUES ('20261103000001_paquete1_clientes_sin_asignar_visibles', 'aplicado', 'Paquete 1, ventana del $FECHA') ON CONFLICT (script) DO UPDATE SET estado='aplicado', aplicada_at=now(), notas=EXCLUDED.notas" \
  2>&1 | tee "ventana-logs/aplicar-P1-M1.log"
```

**Esperado en pantalla:** sin la palabra `ERROR`, y una fila `politica_con_sin_asignar` = `1`, `politicas_public` = `301`.

### Paso M2

```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/migrations/20261103000002_paquete1_crm_cliente_visible_y_asignacion.sql \
  -c "INSERT INTO public.migraciones_aplicadas (script, estado, notas) VALUES ('20261103000002_paquete1_crm_cliente_visible_y_asignacion', 'aplicado', 'Paquete 1, ventana del $FECHA') ON CONFLICT (script) DO UPDATE SET estado='aplicado', aplicada_at=now(), notas=EXCLUDED.notas" \
  2>&1 | tee "ventana-logs/aplicar-P1-M2.log"
```

**Esperado en pantalla:** sin `ERROR`, y una fila `funciones_nuevas` = `4`, `triggers_nuevos` = `7`, `ejecutables_por_anon_o_authenticated` = `0`.

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
 (select count(*) from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and not t.tgisinternal) as triggers,
 (select count(*) from pg_policies where schemaname = 'public' and tablename = 'clientes' and policyname = 'leer clientes' and qual ilike '%vendedor_id IS NULL%') as clientes_sin_asignar_visibles,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'
    and p.proname in ('es_vendedor_comercial', 'clientes_asignar_vendedor_al_crear', 'crm_validar_cliente_visible', 'crm_asignar_cliente_al_usar')) as funciones_paquete1,
 (select count(*) from pg_trigger where not tgisinternal and tgname in ('trg_clientes_asignar_vendedor', 'trg_crm_a_validar_cliente', 'trg_crm_b_asignar_cliente')) as triggers_paquete1,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'
    and p.proname in ('es_vendedor_comercial', 'clientes_asignar_vendedor_al_crear', 'crm_validar_cliente_visible', 'crm_asignar_cliente_al_usar')
    and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('authenticated', p.oid, 'EXECUTE'))) as paquete1_ejecutables,
 pg_get_functiondef('public.puede_leer_remision_refaccion(uuid,uuid)'::regprocedure) ilike '%es_administrativo_comercial%' as refacciones_con_administrativo,
 pg_get_functiondef('public.puede_leer_remision_refaccion(uuid,uuid)'::regprocedure) !~ $q$'almacen_logistica', 'comercial'$q$ as refacciones_sin_comercial,
 (select count(*) from public.clientes) as clientes,
 (select count(*) from public.clientes where vendedor_id is null) as clientes_sin_vendedor,
 (select count(*) from public.migraciones_aplicadas) as registros_migraciones;
rollback;
```

Además, después de cada paso se repiten, **antes** de que la persona de pruebas entre al sistema, los bloques **V** (permisos), **A1** (con la foto de integridad de esa mañana) y **A3** (Auth y Storage) del runbook de la Fase 1, que **no deben cambiar** salvo `registros_migraciones` y `filas_totales` (+1 por paso). *El paquete 1 no cambia ningún dato por sí mismo; los únicos datos que pueden cambiar son los que cree la persona de pruebas.*

## 4. Valores esperados

(`T0` = `triggers` antes; `C` = `clientes`; `S` = `clientes_sin_vendedor`; `R0` = `registros_migraciones`, **96** si la Fase 1 quedó completa. Los valores salen del ensayo local: funciones 268 → 272, triggers +7, políticas 301.)

| Momento | `politicas` | `funciones` | `triggers` | `clientes_sin_asignar_visibles` | `funciones_paquete1` | `triggers_paquete1` | `paquete1_ejecutables` | `refacciones_con_administrativo` | `refacciones_sin_comercial` | `clientes` | `clientes_sin_vendedor` | `registros_migraciones` |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Antes | 301 | 268 | T0 | 0 | 0 | 0 | 0 | false | false | C | S | R0 |
| Tras M1 | 301 | 268 | T0 | **1** | 0 | 0 | 0 | false | false | C | S | R0+1 |
| Tras M2 | 301 | **272** | **T0+7** | 1 | **4** | **7** | 0 | false | false | C (+ los que cree la persona de pruebas) | S (−, si se usaron clientes sin asignar) | R0+2 |
| Tras M3 | 301 | 272 | T0+7 | 1 | 4 | 7 | 0 | **true** | **true** | igual | igual | R0+3 |

## 5. Recorridos de la persona de pruebas (cada uno con su cuenta; anota «Antes» y «Después»)

| # | Después de | Cuenta | Qué hace | Debe pasar |
|---|---|---|---|---|
| R1 | M1 | Vendedor sin clientes | Abre **Clientes** | Ya no dice «0 de 0»: ve la lista de clientes sin vendedor |
| R2 | M1 | Vendedor | **CRM → Oportunidades → Nueva** | El selector de clientes lista clientes (ya no «No hay clientes en el catálogo») |
| R3 | M1 | Vendedor | Busca un cliente que sepa que es de **otro** vendedor | **No** lo ve |
| R4 | M2 | Vendedor | Crea el cliente «ZZ PRUEBA P1 alta <su nombre>» | Queda **a su nombre** |
| R5 | M2 | Vendedor | Crea una oportunidad con «ZZ PRUEBA P1 sin asignar A» | El cliente queda **a su nombre**; el **otro** vendedor ya no lo ve |
| R6 | M2 | Vendedor | Crea una actividad con «… sin asignar B»; luego una ruta con una parada con ese cliente | Funciona; el cliente queda a su nombre |
| R7 | M2 | Supervisor | Crea una oportunidad con un cliente sin asignar | Funciona; el cliente **sigue sin asignar** |
| R8 | M3 | Vendedor y **otro** vendedor | Abren **Remisiones** y **Remisiones de refacciones** | Cada uno ve **solo las suyas**, de los dos tipos |
| R9 | M3 | Administrativo, Supervisor, Dirección | Los mismos listados | Ven **todas** (como antes) |
| R10 | M3 | Vendedor | Abre **Entregas** | Solo lo suyo |
| R11 | M3 | Vendedor | Crea una remisión de motocarro y una de refacciones normales, y las abre | Funciona; ve la que acaba de crear |

**Cualquier falla de un recorrido que antes pasaba (R9–R11, por ejemplo) detiene la ventana.**

## 6. Reversa (orden inverso: M3, M2, M1)

Cada reversa es una transacción y marca el renglón de `migraciones_aplicadas` como `superado` (no se borra). **No deshace** las asignaciones de cliente que los triggers ya hicieron (son datos): quedan anotadas en `clientes_bitacora` con `tipo_cambio = 'asignacion_automatica'`.

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
  -f supabase/reversas/20261103000002_paquete1_crm_cliente_visible_y_asignacion_reversa.sql \
  -c "UPDATE public.migraciones_aplicadas SET estado='superado', notas='REVERTIDA en la ventana del $FECHA (Paquete 1)' WHERE script='20261103000002_paquete1_crm_cliente_visible_y_asignacion'" \
  2>&1 | tee "ventana-logs/revertir-P1-M2.log"
```

**Revertir M1**

```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/reversas/20261103000001_paquete1_clientes_sin_asignar_visibles_reversa.sql \
  -c "UPDATE public.migraciones_aplicadas SET estado='superado', notas='REVERTIDA en la ventana del $FECHA (Paquete 1)' WHERE script='20261103000001_paquete1_clientes_sin_asignar_visibles'" \
  2>&1 | tee "ventana-logs/revertir-P1-M1.log"
```

**Después de cada reversa:** el bloque de la §3 debe dar la fila «Antes» de la §4 (con `registros_migraciones` sin bajar), salvo que M1 revertido deja `clientes_sin_asignar_visibles` = 0 y M2 revertido deja funciones 268 y triggers T0. *La reversa de M3 restaura la versión anterior de la función; las de M1 y M2 se ensayaron exactas en la réplica.*

## 7. Cuándo detenerse y revertir

Detente (y revierte ese paso y los anteriores, en orden inverso) si: falla un recorrido que antes pasaba; un usuario legítimo pierde algo que tenía; suben los 401, 403 o 5xx contra la línea base (bloque D2 del runbook de la Fase 1, al empezar y al terminar); cualquier conteo o huella de los bloques V, A1 o A3 cambia sin explicación (distinto de `migraciones_aplicadas` y de lo que cree la persona de pruebas); el bloque de la §3 no coincide con la §4. **Son las 21:00 y un paso sigue a medias: se revierte ese paso.**

## 8. Después de la ventana

1. Los bloques de la §3, V, A1, A3 y D2 final, pegados. 2. Los clientes «ZZ PRUEBA P1…» se **desactivan** (no se borran) por un supervisor. 3. Claude escribe `docs/mejoras/RESULTADO-PAQUETE-1.md` con lo medido. 4. Una noche y un día de observación antes de la ventana de la Fase 2.

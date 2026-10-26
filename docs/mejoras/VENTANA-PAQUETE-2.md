# Ventana del Paquete 2 (reportes y buscadores, solo lectura) — guion

**Estado: NADA APLICADO.** Fecha **por fijar** (después de la Fase 2 y de que la Fase 2 haya salido limpia). Frase (la escribe Polo, con fecha): «Autorizo paquete 2 (reportes y buscadores) en producción, ventana del `<fecha>`». Mecanismo: Code aplica con `execute_sql` por el conector de escritura **solo dentro de la ventana** (ver «Cómo aplica Code por el conector» en `docs/seguridad/COMO-APLICA-CODE-POR-EL-CONECTOR.md`); nunca `apply_migration`. Las órdenes de abajo son el respaldo manual (psql) y la referencia de qué se aplica.

**Qué cambia:** 3 funciones nuevas, todas de **solo lectura** (STABLE, sin INSERT/UPDATE/DELETE): `reporte_ventas_refacciones` (SECURITY INVOKER: el vendedor solo ve sus ventas por la RLS del Paquete 1), `kardex_refacciones_multi` y `resumen_rotacion_refacciones_filtrado` (DEFINER con la misma puerta que las originales; el vendedor **no** entra). Ninguna tabla, política ni trigger. Las funciones originales (`kardex_refaccion`, `resumen_rotacion_refacciones`) **no se tocan**. Ensayo: `docs/mejoras/ensayo/resultado-paquetes-2-3.json` (103/103 chequeos en verde).

**Depende de:** Paquete 1 (la visibilidad del vendedor en remisiones de refacciones) y de la Fase 2. **El front de este paquete (pantalla de ventas, kárdex y rotación con buscador, filtros de Entregas, fecha programada) todavía no está escrito**; los recorridos de la §5 lo necesitan. Las funciones solas no cambian nada que el usuario vea hasta que el front las llame.

## 1. Antes de abrir la ventana

☐ Frase con fecha; ventana permitida (entre semana después de las 19:00, o fin de semana).
☐ **Fase 2 y Paquete 1 limpios:** bloques V, A1, A3 y D2 repetidos el día anterior y al empezar, sin diferencias inexplicadas.
☐ **Respaldo** del mismo día o del anterior (fecha y hora escritas en la sesión).
☐ Cuentas de la persona de pruebas: un vendedor, otro vendedor, un supervisor y un administrativo de Comercial, Dirección, compras/inventario y almacén.
☐ Dos remisiones de refacciones de prueba creadas antes por vendedores distintos, con fechas en el mes en curso.
☐ El **front del Paquete 2** listo para mezclar dentro de la ventana (después de las migraciones verificadas) y la **compuerta** con las 3 RPC nuevas en `RPCS`.

## 2. Pasos y tiempos (estimaciones, no mediciones: 1 h 30 min en total)

| Paso | Archivo | Qué cambia | Estimado |
|---|---|---|---|
| M1 | `20261108000001_paquete2_reporte_ventas_refacciones` | `reporte_ventas_refacciones` | 20 min |
| M2 | `20261108000002_paquete2_kardex_varios_articulos` | `kardex_refacciones_multi` | 20 min |
| M3 | `20261108000003_paquete2_rotacion_filtrada` | `resumen_rotacion_refacciones_filtrado` | 20 min |

### Paso M1
```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/migrations/20261108000001_paquete2_reporte_ventas_refacciones.sql \
  -c "INSERT INTO public.migraciones_aplicadas (script, estado, notas) VALUES ('20261108000001_paquete2_reporte_ventas_refacciones', 'aplicado', 'Paquete 2, ventana del $FECHA') ON CONFLICT (script) DO UPDATE SET estado='aplicado', aplicada_at=now(), notas=EXCLUDED.notas" \
  2>&1 | tee "ventana-logs/aplicar-P2-M1.log"
```

**Esperado:** sin `ERROR`; fila `funcion_invoker` = 1, `authenticated_ejecuta` = true, `anon_ejecuta` = false.

### Paso M2
```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/migrations/20261108000002_paquete2_kardex_varios_articulos.sql \
  -c "INSERT INTO public.migraciones_aplicadas (script, estado, notas) VALUES ('20261108000002_paquete2_kardex_varios_articulos', 'aplicado', 'Paquete 2, ventana del $FECHA') ON CONFLICT (script) DO UPDATE SET estado='aplicado', aplicada_at=now(), notas=EXCLUDED.notas" \
  2>&1 | tee "ventana-logs/aplicar-P2-M2.log"
```

**Esperado:** sin `ERROR`; fila `funcion_definer_con_search_path` = 1, `authenticated_ejecuta` = true, `anon_ejecuta` = false.

### Paso M3
```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/migrations/20261108000003_paquete2_rotacion_filtrada.sql \
  -c "INSERT INTO public.migraciones_aplicadas (script, estado, notas) VALUES ('20261108000003_paquete2_rotacion_filtrada', 'aplicado', 'Paquete 2, ventana del $FECHA') ON CONFLICT (script) DO UPDATE SET estado='aplicado', aplicada_at=now(), notas=EXCLUDED.notas" \
  2>&1 | tee "ventana-logs/aplicar-P2-M3.log"
```

**Esperado:** sin `ERROR`; `funcion_definer_con_search_path` = 1, `authenticated_ejecuta` = true, `anon_ejecuta` = false, `original_sigue` = 1.

Si hay `ERROR`, no quedó nada aplicado (una sola transacción): se detiene y se reporta, no se repite. *El comando termina en `| tee`: su código de salida no avisa de un error; se lee la pantalla.*

## 3. Verificación después de cada paso (solo lectura; la corre Code por el conector de lectura)

**Esperado:** la fila de la tabla de la §4 para ese momento. Antes de M1 se anota `registros_migraciones` (R).

```sql
-- Verificación del PAQUETE 2 después de cada migración (y después de cada reversa). SOLO LECTURA. Una fila.
begin read only;
select
 (select count(*) from pg_policies where schemaname = 'public') as politicas,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prokind in ('f', 'p')) as funciones,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind in ('f', 'p') and p.prosecdef and has_function_privilege('authenticated', p.oid, 'EXECUTE')) as secdef_authenticated,
 (select count(*) from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and not t.tgisinternal) as triggers,
 (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r') as tablas,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('reporte_ventas_refacciones', 'kardex_refacciones_multi', 'resumen_rotacion_refacciones_filtrado')) as funciones_p2,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'reporte_ventas_refacciones' and not p.prosecdef) as reporte_es_invoker,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('reporte_ventas_refacciones', 'kardex_refacciones_multi', 'resumen_rotacion_refacciones_filtrado')
     and has_function_privilege('anon', p.oid, 'EXECUTE')) as p2_ejecutables_por_anon,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('reporte_ventas_refacciones', 'kardex_refacciones_multi', 'resumen_rotacion_refacciones_filtrado')
     and has_function_privilege('authenticated', p.oid, 'EXECUTE')) as p2_ejecutables_por_authenticated,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('cliente_tiene_cxc_vencidas', 'cxc_vencidas_resumen') and not p.prosecdef) as cartera_sigue_invoker,
 (select count(*) from public.migraciones_aplicadas) as registros_migraciones;
rollback;
```

Después de cada paso también V, A1, A3 y D2 (Code los pega; **no deben cambiar** salvo `registros_migraciones` y `filas_totales` +1 por paso y `secdef_authenticated` +1 con M2 y +1 con M3).

## 4. Valores esperados (salen del ensayo local; `R` = `registros_migraciones` antes)

| Momento | `funciones` | `secdef_authenticated` | `politicas` | `triggers` | `tablas` | `funciones_p2` | `reporte_es_invoker` | `p2_ejecutables_por_anon` | `p2_ejecutables_por_authenticated` | `cartera_sigue_invoker` | `registros_migraciones` |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Antes | 274 | 177 | 300 | 247 | 93 | 0 | 0 | 0 | 0 | 2 | R |
| Tras M1 | 275 | 177 | 300 | 247 | 93 | 1 | 1 | 0 | 1 | 2 | R+1 |
| Tras M2 | 276 | 178 | 300 | 247 | 93 | 2 | 1 | 0 | 2 | 2 | R+2 |
| Tras M3 | 277 | 179 | 300 | 247 | 93 | 3 | 1 | 0 | 3 | 2 | R+3 |

(Los valores de «Antes» suponen Fase 1, Paquete 1 y Fase 2 aplicados, con la 5.ª de la Fase 2 incluida. `triggers` es el de la réplica: en producción es **tu línea base T0** y debe quedar igual.)

## 5. Recorridos (cada uno con su cuenta; requieren el front del Paquete 2)

| # | Cuenta | Qué hace | Debe pasar |
|---|---|---|---|
| S1 | Vendedor | Reporte de ventas del mes, y luego filtrando por **otro vendedor** | Ve **solo las suyas**; filtrar por otro vendedor no muestra nada ajeno |
| S2 | Otro vendedor | Reporte de ventas | Ve solo las suyas (distintas de S1) |
| S3 | Supervisor y administrativo de Comercial | Reporte de ventas, filtros de almacén, ítem y vendedor | Ven **todas**; los filtros reducen las filas; los totales coinciden con lo que ven en Remisiones de refacciones |
| S4 | Vendedor | Entra a Kárdex y a Rotación | **No** entra (sin acceso) |
| S5 | Compras/inventario o almacén | Kárdex con **varios artículos** y filtro de almacén; Rotación con filtro de artículo y almacén | Funciona; con un solo artículo el kárdex da lo mismo que antes |
| S6 | Todos los roles | Entregas y la fecha programada en la remisión de refacciones | Sin cambios para quien ya entraba; el vendedor ve solo lo suyo |

**Cualquier falla de un recorrido que antes pasaba detiene la ventana.**

## 6. Reversa (orden inverso: M3, M2, M1)

Cada reversa borra solo la función que creó y marca el renglón de `migraciones_aplicadas` como `superado`. **Antes de revertir** el front debe volver a la versión anterior (o los reportes nuevos quedarían sin función). No hay datos que restituir: el paquete no escribe nada.

**Revertir M3**
```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/reversas/20261108000003_paquete2_rotacion_filtrada_reversa.sql \
  -c "UPDATE public.migraciones_aplicadas SET estado='superado', notas='REVERTIDA en la ventana del $FECHA (Paquete 2)' WHERE script='20261108000003_paquete2_rotacion_filtrada'" \
  2>&1 | tee "ventana-logs/revertir-P2-M3.log"
```
**Revertir M2**
```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/reversas/20261108000002_paquete2_kardex_varios_articulos_reversa.sql \
  -c "UPDATE public.migraciones_aplicadas SET estado='superado', notas='REVERTIDA en la ventana del $FECHA (Paquete 2)' WHERE script='20261108000002_paquete2_kardex_varios_articulos'" \
  2>&1 | tee "ventana-logs/revertir-P2-M2.log"
```
**Revertir M1**
```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/reversas/20261108000001_paquete2_reporte_ventas_refacciones_reversa.sql \
  -c "UPDATE public.migraciones_aplicadas SET estado='superado', notas='REVERTIDA en la ventana del $FECHA (Paquete 2)' WHERE script='20261108000001_paquete2_reporte_ventas_refacciones'" \
  2>&1 | tee "ventana-logs/revertir-P2-M1.log"
```

**Después de cada reversa:** la verificación de la §3 debe dar la fila «Antes» (o la del paso anterior) de la §4. *Las tres reversas se ensayaron exactas en la réplica.*

## 7. Cuándo detenerse y revertir

Falla un recorrido que antes pasaba; el vendedor ve ventas de otro; el vendedor entra a Kárdex o Rotación; suben los 401/403/5xx o los errores de Postgres contra la línea base (D2); algún conteo o huella de V, A1 o A3 cambia sin explicación; la verificación de la §3 no coincide con la §4.

## 8. Después de la ventana

V, A1, A3, D2 finales pegados; Code escribe `docs/mejoras/RESULTADO-PAQUETE-2.md`; observación antes de la ventana del Paquete 3.

# Ventana del Paquete 3 (eliminar remisión y fecha de remisión) — guion

**Estado: NADA APLICADO.** Fecha **por fijar** (al final: después de la Fase 2 y del Paquete 2). Frase (la escribe Polo, con fecha): «Autorizo paquete 3 (eliminación y fecha de remisión) en producción, ventana del `<fecha>`». **Esta ventana cubre solo la eliminación y la fecha; el crédito (D-C1) espera a Martin y se hará con su propia frase.** Mecanismo: Code aplica con `execute_sql` por el conector de escritura solo dentro de la ventana; nunca `apply_migration`.

**Qué cambia**
- **M1** `modo_prueba_global`: una fila en `compras_parametros` (clave `modo_prueba_global`, **nace APAGADO**: Dirección o un super admin lo enciende cuando lo necesite), 2 funciones (`modo_prueba_global_activo`, `fijar_modo_prueba_global`) y un trigger que impide cambiar esa fila de otro modo. Solo Dirección o super admin lo cambian.
- **M2** `eliminar_remision`: función atómica (solo super admin, modo prueba **encendido**, folio escrito —sin espacios de más— y motivo ≥ 10). **Rechaza** si hay comprobante de pago (motocarros; `remisiones.pagado` ya **no** cuenta: vale true en las 93 remisiones por su valor por omisión), pago (refacciones), cuenta por cobrar, movimiento financiero o factura, **solicitud de firma**, entrega confirmada, cobranza, correcciones o inventario surtido (esas se cancelan, no se eliminan). Bloquea unidades y partidas **antes** de verificar (carreras), guarda la copia (remisión, partidas, **fila completa de cada unidad**, bitácora, órdenes, eventos y **avisos**), libera las unidades y comprueba que no queden filas con llave foránea. **Se cierran los dos DELETE directos** de `remisiones` y el privilegio DELETE de `authenticated` en `remisiones` y `remisiones_refacciones`. **No se cierran, a propósito:** las políticas DELETE de `motocarros` y `remision_items` (la edición de remisiones borra partidas con ellas), `service_role` y `reiniciar_datos_prueba_compras` (**excepción documentada**: solo borra filas `es_prueba`). **Si falta una columna que la función usa, la migración ABORTA** con un mensaje claro (en una base construida solo con las migraciones, `remisiones.comprobante_pago_url` viene del script suelto `fix_remisiones_columns.sql`, que irá a una migración propia más adelante).
- **M3** fecha: tabla `remision_fecha_cambios` (RLS, solo lectura), función `cambiar_fecha_remision` (solo Dirección y administrativos de Comercial, con motivo; no se mueve ningún vencimiento; se avisa a administración) y un trigger que impide cambiar `fecha_remision` por cualquier otra vía (**cambia lo que hoy hace la pantalla de edición de la remisión: el front debe dejar de enviarla**).

**Decisiones de Polo aplicadas:** D-A1 A, D-A2 A, D-B1 A, D-B2 A, D-B3 A, y la regla «una remisión de refacciones que ya surtió inventario se cancela, no se elimina» (acordada). **Pendiente de Polo:** D-A3 (qué dato es «factura»: el paquete rechaza `movimientos_financieros.tiene_factura/factura_uuid/factura_folio` **y además cualquier movimiento financiero** ligado, así que no depende de la confirmación) y D-C1 (crédito, espera a Martin). Ensayo: `docs/mejoras/ensayo/resultado-paquetes-2-3.json` (125/125 chequeos en verde, con la regla real de producción: `pagado = true` en todas las remisiones, y dos sesiones simultáneas para las carreras).

**Ramas listas, sin mezclar:** front `claude/paquete-3-front` (kit-to-drive, commit `d499851`) y compuerta `claude/paquete-3-compuerta` (kit-to-drive-front). Se mezclan **inmediatamente después de verificar M3** (la compuerta primero, luego el front); cada mezcla despliega en Vercel.

**Depende de:** Fase 2 (cartera vencida INVOKER; este paquete no la toca) y del **front del Paquete 3** (botón «Eliminar» solo para super admin con modo prueba, «Cambiar fecha» con motivo, interruptor para Dirección), que **todavía no está escrito**. La compuerta necesita `eliminar_remision`, `cambiar_fecha_remision`, `modo_prueba_global_activo`, `fijar_modo_prueba_global` en `RPCS` y `remision_fecha_cambios` en `TABLAS`.

## 1. Antes de abrir la ventana

☐ Frase con fecha; ventana permitida. ☐ Paquete 2 y Fase 2 limpios (V, A1, A3, D2 el día anterior y al empezar). ☐ **Respaldo** del día o del anterior (fecha y hora escritas). ☐ **El front del Paquete 3 listo para mezclar** (rama sin mezclar), para desplegarlo justo después de verificar M3. ☐ **El interruptor nace apagado:** Dirección lo enciende solo durante los recorridos y lo deja **apagado** al terminar. ☐ Cuentas: **super admin**, Dirección **sin** ser super admin, administrativo de Comercial, administrador de Comercial, un vendedor, un supervisor. ☐ Datos de prueba creados antes: una remisión de motocarros **sin pagos ni entregas** con 2 unidades asignadas; una con pago; una de refacciones sin surtir; una de refacciones surtida (todas con el prefijo «ZZ PRUEBA P3»). ☐ **Aviso a Dazon:** «durante la ventana la pantalla de remisiones puede pedir recargar; la fecha de la remisión solo la cambia Dirección o un administrativo».

## 2. Pasos y tiempos (estimación: 1 h 45 min)

| Paso | Archivo | Estimado |
|---|---|---|
| M1 | `20261109000001_paquete3_modo_prueba_global` | 25 min |
| M2 | `20261109000002_paquete3_eliminar_remision` | 35 min |
| M3 | `20261109000003_paquete3_fecha_de_remision` | 35 min |

### Paso M1
```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/migrations/20261109000001_paquete3_modo_prueba_global.sql \
  -c "INSERT INTO public.migraciones_aplicadas (script, estado, notas) VALUES ('20261109000001_paquete3_modo_prueba_global', 'aplicado', 'Paquete 3, ventana del $FECHA') ON CONFLICT (script) DO UPDATE SET estado='aplicado', aplicada_at=now(), notas=EXCLUDED.notas" \
  2>&1 | tee "ventana-logs/aplicar-P3-M1.log"
```

**Esperado:** sin `ERROR`; fila `valor_inicial` = `false`, `trigger_proteccion` = 1, `funciones_definer_con_search_path` = 2, `anon_ejecuta` = false.

### Paso M2
```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/migrations/20261109000002_paquete3_eliminar_remision.sql \
  -c "INSERT INTO public.migraciones_aplicadas (script, estado, notas) VALUES ('20261109000002_paquete3_eliminar_remision', 'aplicado', 'Paquete 3, ventana del $FECHA') ON CONFLICT (script) DO UPDATE SET estado='aplicado', aplicada_at=now(), notas=EXCLUDED.notas" \
  2>&1 | tee "ventana-logs/aplicar-P3-M2.log"
```

**Esperado:** sin `ERROR`; `funcion_definer_con_search_path` = 1, `anon_ejecuta` = false, `politicas_delete_remisiones` = **0**, `authenticated_puede_delete_remisiones` = false, `authenticated_puede_delete_refacciones` = false.

### Paso M3
```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/migrations/20261109000003_paquete3_fecha_de_remision.sql \
  -c "INSERT INTO public.migraciones_aplicadas (script, estado, notas) VALUES ('20261109000003_paquete3_fecha_de_remision', 'aplicado', 'Paquete 3, ventana del $FECHA') ON CONFLICT (script) DO UPDATE SET estado='aplicado', aplicada_at=now(), notas=EXCLUDED.notas" \
  2>&1 | tee "ventana-logs/aplicar-P3-M3.log"
```

**Esperado:** sin `ERROR`; `tabla_con_rls` = true, `politicas_tabla` = 1, `triggers_fecha` = 2, `funcion_definer_con_search_path` = 1, `anon_ejecuta` = false, `anon_lee_tabla` = false.

Si hay `ERROR`, no quedó nada aplicado (una sola transacción). *`| tee` oculta el código de salida: se lee la pantalla.*

### Momento exacto: mezclar el front del Paquete 3 (inmediatamente después de verificar M3)
Orden fijado por Polo: **M1 → verificar → M2 → verificar → M3 → verificar → front**. El front (y su compuerta, si va aparte) se mezcla **justo después de verificar M3**, no antes: mezclar **despliega en producción en Vercel**; se espera «Ready» y se anota el commit. Si falla, se revierte el commit de la mezcla. **Mientras no se despliega el front, la pantalla anterior convive con las migraciones:** desde M2 el botón «Eliminar» de la pantalla anterior (borrado directo) falla con «permission denied», y desde M3 la edición normal falla **solo si el usuario cambia la fecha** (reenviar la misma fecha no estorba). Por eso la ventana avisa a Dazon y el tiempo entre M2 y el despliegue del front debe ser corto. Los recorridos T1–T8 se hacen **después** del despliegue.

## 3. Verificación después de cada paso (solo lectura; la corre Code)

```sql
-- Verificación del PAQUETE 3 después de cada migración (y después de cada reversa). SOLO LECTURA. Una fila.
begin read only;
select
 (select count(*) from pg_policies where schemaname = 'public') as politicas,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prokind in ('f', 'p')) as funciones,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind in ('f', 'p') and p.prosecdef and has_function_privilege('authenticated', p.oid, 'EXECUTE')) as secdef_authenticated,
 (select count(*) from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and not t.tgisinternal) as triggers,
 (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r') as tablas,
 (select valor::text from public.compras_parametros where clave = 'modo_prueba_global') as modo_prueba_global,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('modo_prueba_global_activo', 'fijar_modo_prueba_global', 'proteger_modo_prueba_global',
         'eliminar_remision', 'cambiar_fecha_remision', 'remision_fecha_solo_por_funcion')) as funciones_p3,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('modo_prueba_global_activo', 'fijar_modo_prueba_global', 'proteger_modo_prueba_global',
         'eliminar_remision', 'cambiar_fecha_remision', 'remision_fecha_solo_por_funcion') and has_function_privilege('anon', p.oid, 'EXECUTE')) as p3_ejecutables_por_anon,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('proteger_modo_prueba_global', 'remision_fecha_solo_por_funcion') and has_function_privilege('authenticated', p.oid, 'EXECUTE')) as funciones_de_trigger_ejecutables,
 (select count(*) from pg_policies where schemaname = 'public' and tablename = 'remisiones' and cmd = 'DELETE') as politicas_delete_remisiones,
 has_table_privilege('authenticated', 'public.remisiones', 'DELETE') as authenticated_puede_delete_remisiones,
 (to_regclass('public.remision_fecha_cambios') is not null) as existe_tabla_fechas,
 (select count(*) from pg_trigger where tgname in ('trg_proteger_modo_prueba_global', 'trg_remisiones_fecha_solo_funcion', 'trg_remisiones_refacciones_fecha_solo_funcion') and not tgisinternal) as triggers_p3,
 (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('cliente_tiene_cxc_vencidas', 'cxc_vencidas_resumen') and not p.prosecdef) as cartera_sigue_invoker,
 (select count(*) from public.migraciones_aplicadas) as registros_migraciones;
rollback;
```

## 4. Valores esperados (ensayo local; `R` = `registros_migraciones` antes)

| Momento | `funciones` | `secdef_authenticated` | `politicas` | `triggers` | `tablas` | `modo_prueba_global` | `funciones_p3` | `politicas_delete_remisiones` | `existe_tabla_fechas` | `triggers_p3` | `registros_migraciones` |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Antes | 278 | 179 | 300 | 247 | 93 | (nulo) | 0 | 2 | false | 0 | R |
| Tras M1 | 281 | 181 | 300 | 248 | 93 | false | 3 | 2 | false | 1 | R+1 |
| Tras M2 | 282 | 182 | 298 | 248 | 93 | false | 4 | **0** | false | 1 | R+2 |
| Tras M3 | 284 | 183 | 299 | 250 | 94 | false | 6 | 0 | true | 3 | R+3 |

Siempre: `p3_ejecutables_por_anon` = 0, `funciones_de_trigger_ejecutables` = 0, `cartera_sigue_invoker` = 2, `authenticated_puede_delete_remisiones` = false desde M2. (Los valores de «Antes» suponen el Paquete 2 aplicado; sin él, restar 4 funciones y 2 SECDEF.) Los recorridos de la §5 se hacen **después** de desplegar el front.

## 5. Recorridos (cada uno con su cuenta; requieren el front del Paquete 3)

| # | Cuenta | Qué hace | Debe pasar |
|---|---|---|---|
| T1 | Dirección | Con el interruptor **apagado** (como nace) comprueba que no aparece «Eliminar»; lo **enciende** (con motivo) para el resto de los recorridos y, al final, lo **apaga** de nuevo | Cada cambio queda en bitácora; apagado no hay «Eliminar» ni la función elimina |
| T2 | Vendedor, supervisor, administrativo | Intentan apagar el interruptor | No pueden |
| T3 | Super admin | Con el interruptor **encendido**, elimina la remisión de motocarros de prueba **sin comprobante de pago** (escribe el folio y el motivo) | Se elimina; las 2 unidades quedan libres; hay copia en `bitacora_eliminaciones`; no quedan filas huérfanas |
| T4 | Super admin | Intenta eliminar la de **pago**, una con cuenta por cobrar o entrega confirmada, y una de refacciones surtida | Se rechaza cada una con su motivo («se cancela, no se elimina») |
| T5 | Administrador de Comercial y Dirección no super admin | Intentan eliminar | No pueden (y el borrado directo ya no existe para nadie) |
| T6 | Dirección y administrativo de Comercial | Cambian la fecha de una remisión de motocarros y de una de refacciones sin surtir, con motivo | Se cambia; queda el historial; administración recibe el aviso; ningún vencimiento se mueve |
| T7 | Dirección | Cambia la fecha de una remisión de refacciones **ya surtida** | Se rechaza |
| T8 | Vendedor, supervisor | Cambian la fecha; y **editan otros campos** de su remisión | La fecha no (mensaje claro); lo demás sí funciona como antes |

**Cualquier falla de un recorrido que antes pasaba detiene la ventana** (en especial la edición normal de remisiones, T8).

## 6. Reversa (orden inverso: M3, M2, M1)

La de **M3 borra la tabla `remision_fecha_cambios`** (exportar antes el historial si ya se usó; los avisos creados se quedan). La de **M2 restituye los dos DELETE directos y el privilegio**; lo ya eliminado (con su copia en `bitacora_eliminaciones`) no vuelve: son datos. La de M1 borra la fila del interruptor. **Antes de revertir** el front debe volver a la versión anterior.

**Revertir M3**
```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/reversas/20261109000003_paquete3_fecha_de_remision_reversa.sql \
  -c "UPDATE public.migraciones_aplicadas SET estado='superado', notas='REVERTIDA en la ventana del $FECHA (Paquete 3)' WHERE script='20261109000003_paquete3_fecha_de_remision'" \
  2>&1 | tee "ventana-logs/revertir-P3-M3.log"
```
**Revertir M2**
```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/reversas/20261109000002_paquete3_eliminar_remision_reversa.sql \
  -c "UPDATE public.migraciones_aplicadas SET estado='superado', notas='REVERTIDA en la ventana del $FECHA (Paquete 3)' WHERE script='20261109000002_paquete3_eliminar_remision'" \
  2>&1 | tee "ventana-logs/revertir-P3-M2.log"
```
**Revertir M1**
```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -f supabase/reversas/20261109000001_paquete3_modo_prueba_global_reversa.sql \
  -c "UPDATE public.migraciones_aplicadas SET estado='superado', notas='REVERTIDA en la ventana del $FECHA (Paquete 3)' WHERE script='20261109000001_paquete3_modo_prueba_global'" \
  2>&1 | tee "ventana-logs/revertir-P3-M1.log"
```

**Después de cada reversa:** la verificación debe dar la fila anterior de la §4. Si se revierte, el front se revierte **primero** (o a la vez). *Las tres reversas se ensayaron exactas en la réplica.*

## 7. Cuándo detenerse y revertir

Falla un recorrido que antes pasaba (sobre todo editar una remisión); alguien que no es super admin logra eliminar; se elimina algo con pago, cobranza, factura o entrega; queda una fila huérfana; suben los 401/403/5xx o los errores de Postgres (D2); cambia sin explicación algo de V, A1 o A3; la §3 no coincide con la §4.

## 8. Después de la ventana

V, A1, A3, D2 finales pegados; los datos «ZZ PRUEBA P3» que sobren se **cancelan** (no se borran fuera del flujo); `docs/mejoras/RESULTADO-PAQUETE-3.md`; El interruptor global se deja **apagado** (así nace); Dirección lo enciende solo cuando necesite eliminar remisiones de prueba.

# Orden de las ventanas y choques con la Fase 2 (PR #14 y PR #74)

## 1. ¿El orden es correcto?

**Sí.** Fase 1 (lun 26 oct, 19:00–00:00) → **Paquete 1** (jue 29 oct, 19:00–22:00) → Fase 2 (sáb 31 oct, 10:00–15:00) → Paquete 2 → Paquete 3, cada uno en su ventana y **ninguno el mismo día que otra fase o paquete**.

| Paso | Por qué va ahí | Condición |
|---|---|---|
| Fase 1 | Cierra permisos amplios (TRUNCATE, `anon`, defaults). Todo lo nuevo nace cerrado | — |
| **Paquete 1** | Es independiente de la Fase 2 (ver §2) y corrige el síntoma de los vendedores cuanto antes | Fase 1 limpia: V, A1 y A3 el martes 27, el miércoles 28 y el jueves 29 antes de empezar, sin diferencias inexplicadas; se prueba contra la réplica **con la Fase 1 ya aplicada** (hecho) |
| Fase 2 | Cambia perfiles, roles, super admins y las funciones de cartera | Se **rehízo su ensayo con el Paquete 1 aplicado** (§3) |
| Paquete 2 | Solo lectura; lee con las reglas de visibilidad ya corregidas (P1) y los perfiles protegidos (Fase 2) | Después de la Fase 2 |
| **Paquete 3** | Usa `cliente_tiene_cxc_vencidas` y `cxc_vencidas_resumen`, que la Fase 2 pasa a `SECURITY INVOKER`: con INVOKER un vendedor **solo ve la cartera de los clientes que ve** | **Al final**, probado contra la versión de la Fase 2, y **sin volver a crear esas funciones como `SECURITY DEFINER`** |

## 2. Qué toca cada cosa del PR #14 y qué toca el Paquete 1

| Objeto que cambia la Fase 2 | ¿Lo toca el Paquete 1? |
|---|---|
| `profiles` (trigger `proteger_perfil_fase2`, política `profiles_update_admin`) | **No** |
| `user_roles` / `impedir_escalada_rol()` | **No** |
| `super_admins` / `rastro_lista_super_admins()` | **No** |
| `cliente_tiene_cxc_vencidas(uuid)`, `cxc_vencidas_resumen(uuid)` | **No** |
| Edge Functions `admin-*`, `complete-password-change`, `seed-demo-users` | **No** |
| Front PR #74 (contraseña filtrada, mensajes) | **No** (solo comparten `src/test/contrato-back.json`, ver abajo) |

`tests/paquete-1.test.ts` falla si alguna migración del Paquete 1 menciona esos objetos.

**Archivos en común** (solo de registro, sin choque de objetos): `supabase/diagnostico_esquema.sql` y `contrato/funciones.json` en el back; `src/test/contrato-back.json` en el front. Ambos paquetes **agregan renglones al final**, así que el segundo que se mezcle tendrá un conflicto mecánico de texto: se resuelve conservando las dos listas (y `npm run contrato` regenera el JSON). Probado: el commit del Paquete 1 se aplica limpio sobre la rama de la Fase 2; sobre la rama de la Fase 1 sola, el conflicto aparece en `diagnostico_esquema.sql`.

## 3. Ensayo de la Fase 2 rehecho con el Paquete 1 aplicado

`ensayar-fase-2.py` sobre la réplica con Fase 1 + Paquete 1 (y, para comparar, sin Paquete 1). Las cinco migraciones se aplican y se revierten exactas; reaplicar no cambia nada; la reversa total restaura todo.

| Momento | Funciones (sin P1 → **con P1**) | SECDEF ejecutables por `authenticated` (sin P1 → **con P1**) | Políticas |
|---|---|---|---|
| Antes de la Fase 2 | 268 → **272** | 178 → **179** | 301 → 301 |
| Tras la 1.ª (perfiles) | 269 → **273** | 178 → **179** | 301 → 301 |
| Tras la 2.ª (roles) | 269 → **273** | 178 → **179** | 301 → 301 |
| Tras la 3.ª (política de profiles) | 269 → **273** | 178 → **179** | **300** → **300** |
| Tras la 4.ª (cartera INVOKER) | 269 → **273** | **176** → **177** | 300 → 300 |
| Tras la 5.ª (rastro) | 270 → **274** | 176 → **177** | 300 → 300 |

**Valores esperados de la Fase 2 si va después del Paquete 1 (rehecho con el Paquete 1 final):** funciones **272 → 273 → 274** (en lugar de 268 → 269 → 270), SECDEF ejecutables por `authenticated` **179 → 177** (en lugar de 178 → 176; la diferencia es `catalogo_clientes_basico`) y políticas **301 → 300**. Las funciones SECURITY DEFINER totales son 243 antes de la Fase 2 (240 sin P1). Resultado del ensayo: las cinco migraciones aplican y revierten exactas, reaplicar no cambia nada, y la reversa total restaura todo (`reversa_total_restaura_exacto = true`).

## 4. Qué choca con el Paquete 2 y el Paquete 3

Ver `PAQUETE-2-REPORTES-Y-BUSCADORES.md` y `PAQUETE-3-CREDITO-FECHA-ELIMINAR.md` (§«Choques»). Resumen: el Paquete 2 no toca ningún objeto de la Fase 2 (solo agrega lectura). El Paquete 3 **sí depende de la Fase 2** (cartera vencida) y además **cambia permisos de `DELETE` de remisiones** (los de administradores y administradores de Comercial) y la restricción `tipo_pago`: nada de eso lo toca la Fase 2.

## 5. Paquetes 2 y 3 ensayados con Fase 1 + Paquete 1 + Fase 2 aplicados (26 oct)

`ensayo/ensayar-paquetes-2-3.py` sobre una copia de la réplica con las tres fases anteriores: las 6 migraciones se aplican, **ninguna función que ya existía cambia** (las de la Fase 1, el Paquete 1 y la Fase 2 conservan su huella), reaplicar no cambia nada y la reversa total restaura el catálogo **exactamente** (114 de 114 chequeos en verde: `ensayo/resultado-paquetes-2-3.json`). Conteos: funciones 274 → 278 (P2) → 284 (P3); SECDEF ejecutables 177 → 179 → 183; políticas 300 → 300 → 299; triggers +3 y tablas +1 (ambos en P3).

**Choques:** el Paquete 2 depende del Paquete 1 (la visibilidad del vendedor en remisiones de refacciones) y no toca ningún objeto de la Fase 2. El Paquete 3 no vuelve a crear `cliente_tiene_cxc_vencidas` ni `cxc_vencidas_resumen` (siguen `SECURITY INVOKER`; lo verifican `tests/paquete-3.test.ts` y el ensayo) y **cierra dos políticas DELETE de `remisiones`** que ningún otro paquete usa. Archivos compartidos con otros PR: solo los de registro (`diagnostico_esquema.sql`, `contrato/funciones.json`; el `contrato-back.json` del front se actualiza con el front de cada paquete).

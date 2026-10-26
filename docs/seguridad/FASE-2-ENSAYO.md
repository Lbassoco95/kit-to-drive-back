# Fase 2 — ensayo (26 oct 2026)

Réplica local de producción (PostgreSQL 16), **datos inventados**, **nunca QA ni producción**. Ensayo completo y repetible: `ensayo/ensayar-fase-2.py` (resultado en `ensayo/resultado-ensayo-fase-2-2026-10-26.json`).

## 1. Cómo se armó

1. `construir-replica-fiel.py`: base con las migraciones del repo **sin la Fase 1 ni la Fase 2**, más lo que producción tiene y el repo no crea, las 338 políticas de producción y los permisos exactamente como el respaldo del 25 oct.
2. `ensayar-fase-2.py` aplica primero la **Fase 1** (la Fase 2 depende de ella) y toma la línea base: foto del catálogo de lo que la Fase 2 toca (triggers, políticas, funciones y permisos), conteos de la sección 2 y recorridos por rol.
3. **Por cada migración:** foto → aplica en una sola transacción → recorridos → aplica la **reversa** y compara la foto (debe ser **idéntica**) → vuelve a aplicar → aplica **otra vez** (idempotencia).
4. Al final aplica las cinco, corre los recorridos de la Fase 1 y de la Fase 2, aplica las reversas **en orden inverso** y comprueba que se recupera la línea base completa.

## 2. Resultado

| Migración | Aplica | Reversa aplica | Catálogo tras la reversa = antes | Idempotente (2 veces) | Comprobaciones de la Fase 2 que no coinciden con lo esperado |
|---|---|---|---|---|---|
| 1 perfiles protegidos | ✓ | ✓ | **idéntico** | ✓ | 62 → 8 |
| 2 roles: rango y super admins | ✓ | ✓ | **idéntico** | ✓ | 8 → 4 |
| 3 política de `profiles` por área | ✓ | ✓ | **idéntico** | ✓ | 4 → 4 |
| 4 cartera vencida | ✓ | ✓ | **idéntico** | ✓ | 4 → **0** |
| 5 rastro de super admins | ✓ | ✓ | **idéntico** | ✓ | 0 → 0 |

(La columna es lo que queda sin cumplir tras aplicar esa migración y las anteriores: la 3 y la 4 cierran lo que faltaba de C2 y C5.)

| Prueba global | Resultado |
|---|---|
| Línea base de los recorridos (Fase 2) | **62 de 324** comprobaciones **no cumplen** lo esperado (los huecos: autopromoción, edición entre áreas, super admins, cartera) |
| Tras las cinco migraciones | **0** de 324 |
| Tras aplicar las **reversas en orden inverso** | Catálogo **idéntico** a la línea base (`reversa_total_restaura_exacto: true`); conteos iguales; los 62 vuelven; los recorridos de la Fase 1 sin ningún cambio |
| Volver a aplicar las cinco | Catálogo idéntico al de la primera vez |
| Alta de usuario (`handle_new_user` con el rol de Auth) | Igual antes y después: la cuenta autorizada se crea con su perfil; la no autorizada sigue rechazada |
| Barridos de la Fase 1 (TRUNCATE, `anon`, funciones de trigger por RPC) | Sin cambio; las 2 funciones de trigger nuevas salen cerradas (`42501`) |
| `supabase/diagnostico_esquema.sql` sobre la réplica | Las 5 migraciones salen `APLICADO` |
| Pruebas del repo (`npm test`) | **127 pasan**, 3 omitidas (necesitan Postgres local) |
| `npm run deno:test` | **No se pudo correr** (el entorno no tiene Deno) |

## 3. Qué cambia en los recorridos que ya existían (Fase 1), 11 acciones, todas esperadas

| Rol | Acción | Antes | Después | Por qué |
|---|---|---|---|---|
| Admin de Comercial | Cambiar el correo del super admin | se hacía | **0 filas** | C3 |
| Admin de Comercial | Editar el nombre del super admin | se hacía | **0 filas** | C3 |
| Admin de Comercial | Editar el nombre de otra área (Finanzas) | se hacía | **0 filas** | C2 |
| Super admin | Desactivarse a sí mismo | se hacía | **rechazado** | C1 |
| 7 roles (admin de Comercial, almacén, compras, finanzas, logística, operador, ventas) | Desactivarse a sí mismo | rechazado (`P0001`) | rechazado (`42501`) | Sigue bloqueado; solo cambia el código de error |

Ninguna otra acción de los 8 roles cambió.

## 4. Lo que SÍ prueba el ensayo y lo que NO

| Prueba | No prueba |
|---|---|
| Las reglas de la base (RLS, triggers, funciones) con 12 roles y 27 acciones | **Auth** (inicio de sesión, tokens, `banned_until`) |
| Que cada migración se aplica, se revierte exacto y se puede repetir | **La API** (PostgREST, compuerta, cabeceras) |
| Que el alta de usuarios por Auth sigue funcionando | **Las Edge Functions** (se probó la lógica pura y la forma del código; no se ejecutaron) |
| Que el catálogo y los permisos no se mueven | **Las pantallas** completas |
| Los scripts de cuentas demo (guardas, aplicar, reversa) sobre datos inventados | Los datos reales de producción (26 perfiles) |
| | PostgreSQL 17 (`MAINTAIN`): el motor local es 16 |

**Se verifica en la ventana de producción:** los recorridos de pantalla U1–U14 (`FASE-2-LINEA-BASE-Y-RECORRIDOS.md` §5), el rastro en `bridge_bitacora`, el despliegue de las funciones, que `lee`, `finanzas` y `marco` sigan iniciando sesión y los conteos de la línea base.

## 5. Un error de método encontrado y corregido durante el ensayo

La primera corrida armó la réplica **con** las migraciones de la Fase 2 incluidas (el constructor solo excluía la Fase 1), así que su «línea base» ya traía la Fase 2. Se detectó porque la línea base salía casi limpia. Se corrigió el constructor para excluir toda migración posterior al 25 oct, y la prueba de cartera para llamar a la función con un cliente concreto (antes recorría la tabla de clientes, que ya filtra por usuario y escondía el hueco). Los resultados de este documento son los de la corrida corregida.

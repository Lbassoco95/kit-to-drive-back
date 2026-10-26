# Ventana de la Fase 2 en producción — guion

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
- **Propuesta:** sábado **7 de noviembre de 2026**, 10:00 a 18:00, **si la Fase 1 ya se aplicó el 31 de octubre y tuvo una semana de observación sin incidentes**. Si la Fase 1 se aplica después, la Fase 2 va **un sábado después** de que termine su semana de observación.
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

Mecanismo: pegar el archivo completo en el SQL Editor (una transacción: si falla, no queda nada a medias) o la herramienta de migraciones, que pide autorización en cada ejecución.

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
3. **Una semana de observación** antes de la Fase 3.
4. **No se hace en esta ventana:** rendimiento y políticas duplicadas (Fase 3), auditoría central (Fase 4), rotación de la llave `anon`, protección de ramas, limpieza del historial de git, contraseñas filtradas (§5, aparte).

## 9. Lo que solo puede hacer Polo

- Escribir las frases de autorización.
- Confirmar quiénes son `finanzas`, `lee`, `marco` y `edgar`.
- Activar la protección de contraseñas filtradas en el panel (después de §5).
- Activar el segundo factor con Peter (cuenta `qq.com`).
- Decidir la opción A/B de `asignar_super_admin` y qué hacer con las cuentas de `yoltik.mx` que nunca entraron.

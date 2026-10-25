# ¿Quién usa a `anon`? ¿Quién usa realtime? (Fase 0, sección 3.4)

Fecha: 25 de octubre de 2026. Esta sección responde la condición del punto 5 de la Fase 1: **quitar a `anon` la escritura de las tablas solo si ningún flujo la usa.** Conclusión: **ningún flujo la usa**, y el punto 5 se incluye. La evidencia son cuatro cosas independientes: el código de los cuatro repos, el análisis de las 39 políticas que aplican a `anon`/`public`, siete días de registros de la API de Supabase, y la prueba en la réplica.

## 1. Resultado por flujo

| Flujo | ¿Usa a `anon` para leer o escribir tablas, vistas o funciones? | Evidencia |
|---|---|---|
| **Inicio de sesión** | **No.** Usa el servicio de autenticación (`/auth/v1/token`), no las tablas. | `src/pages/Auth.tsx` usa `signInWithPassword` y `resetPasswordForEmail`. En 7 días, todo lo «sin sesión» es `auth/v1/token` (217 solicitudes) y 1 `auth/v1/recover`. |
| **Registro público con candado de 3 minutos** | **No.** No existe registro público: un administrador autoriza el correo y **la Edge Function** (con llave de servicio) lo anota en `altas_autorizadas` por 3 minutos; el candado `reject_public_signups()` lo consume al crear la cuenta. | `20261010000002_altas_autorizadas.sql`: `REVOKE ALL … FROM PUBLIC, anon, authenticated`, solo `service_role`. El front **no tiene `signUp`**; la compuerta rechaza `/auth/signup`. En los registros las escrituras a `altas_autorizadas` vienen de `SupabaseEdgeRuntime` con llave de servicio. |
| **Trigger `handle_new_user`** | **No.** Lo dispara el rol de Auth (`supabase_auth_admin`) al insertar en `auth.users`; es SECURITY DEFINER. | Tiene permiso explícito para `supabase_auth_admin` (migración `20261010000001`); la Fase 1 lo vuelve a conceder y no lo toca. El ensayo creó un usuario con ese rol antes y después: perfil creado, y un alta sin autorización sigue rechazada (`23514`). |
| **Compuerta (`kit-to-drive-api`)** | **No para tablas, RPC ni funciones.** `rest`, `rpc` y `functions` exigen sesión de usuario (`requiereSesion: true`, rol `authenticated`). Sin sesión solo pasan `auth/token`, `auth/recover` y las URL firmadas de storage. | `src/policy.ts` y `src/app.ts` del repo `kit-to-drive-front` (`origin/main` = producción `843cc92`). Presenta la llave `anon` solo en esos tres casos. |
| **Edge Functions** (`admin-create-user`, `admin-update-user`, `admin-reset-user-password`, `complete-password-change`, `firmas`, `seed-demo-users`) | **No.** Usan la llave `anon` **junto con el JWT de quien llama**, solo para `auth.getUser()`; todo el acceso a datos va con `service_role`. | Lectura de cada `index.ts` (`createClient(url, anon, { global: { headers: { Authorization } } })` solo llama `auth.getUser()`). |
| **Puente de MATI Admin** (`mati-admin-bridge`, `mati-api`, `mati-admin`) | **No.** `mati-api` llama al puente con un secreto compartido; el puente usa `service_role`. `mati-api` y `mati-admin` no hablan con la base de Kit-to-Drive. | `mati-api/src/services/kitToDriveBridge.ts`; `mati-admin-bridge/index.ts` (solo `admin.from(...)` y `admin.auth.admin…`). |
| **Políticas de storage** | **Sí, una, y es de lectura:** `ref_fotos_leer_anon` (SELECT sobre el bucket `refacciones-fotos`). Las URL firmadas (`storage/v1/object/sign/…`, 71 en un día) las valida el servicio de storage. | Son políticas sobre `storage.objects`: **la Fase 1 no toca el esquema `storage`**, así que no cambian. |
| **Vistas** (16 con lectura para `anon`) | **No.** En 7 días no hubo una sola lectura REST con rol `anon`. | Registros `edge_logs`. Además, como `anon` no puede ejecutar las funciones que usan las políticas, leer las tablas ya falla hoy (`permission denied for function has_role`). |

## 2. Registros de la API de Supabase, 7 días (18–25 oct 2026)

Solicitudes cuyo JWT de `Authorization` **no** era `authenticated`:

- **Con rol `anon`:** únicamente `POST auth/v1/token` (inicio de sesión), `POST auth/v1/recover` y `GET storage/v1/object/sign/…` (URL firmadas). **Cero** llamadas `rest/v1` (tablas, vistas, RPC) y **cero** escrituras.
- **Sin JWT** (`apikey` y `Authorization` sin formato JWT): son llaves de servicio. En todas las escrituras `rest/v1` sin sesión de usuario (`profiles`, `user_roles`, `altas_autorizadas`, `rpc/admin_clear_debe_cambiar_password`) el agente es `Deno … SupabaseEdgeRuntime` (las Edge Functions). Ninguna con `apikey` de rol `anon`.
- **`OPTIONS` directos a `rest/v1/…`** el 23–24 de octubre: son verificaciones previas del navegador; indican que ese día alguien usó el front **en modo directo** («vuelta atrás», sin `VITE_API_URL`) o una versión anterior. Ese modo, tras iniciar sesión, usa el rol `authenticated`, no `anon`: no depende de lo que quita la Fase 1.

## 3. Análisis de políticas (39 con rol `public` o `anon`)

34 de tablas, 4 de storage para `public` y 1 de storage para `anon`. De las 34 de tablas, 25 permiten escribir (INSERT/UPDATE/DELETE/ALL). **Ninguna le deja escribir a `anon`:** todas usan `auth.uid()` o funciones de rol, que para `anon` dan falso o error. La única que no usa `auth.uid()` es `crm_paradas_all` (FOR ALL, rol `public`): su condición es «existe la ruta en `crm_rutas`», y quien la frena para `anon` es la seguridad por filas de `crm_rutas`. Es una dependencia frágil —un cambio en esa otra tabla abriría la escritura de paradas—, y es justo lo que el punto 5 cierra a nivel de permisos. *(La política en sí se revisa en la fase de políticas.)*

## 4. Prueba en la réplica (antes → después de la Fase 1)

Réplica con las políticas, triggers y permisos de producción (ver `ENSAYO-FASE-1.md`), `anon` contra las 93 tablas y 18 vistas:

| Prueba como `anon` | Antes | Después |
|---|---|---|
| `DELETE` sin filtro, por tabla | 17 con `42501`; 76 «sin error, 0 filas» (frenadas por la seguridad por filas) | **93 con `42501`** |
| `INSERT … DEFAULT VALUES`, por tabla | 90 con `42501`, 2 con error de trigger, 1 por columna obligatoria; ninguna se pudo | **93 con `42501`** |
| `TRUNCATE`, por tabla | **51 se ejecutan**, 31 las frena una llave foránea, 11 con `42501` | **93 con `42501`** |
| `SELECT` de las 18 vistas | 11 se ejecutan, 7 con `42501` | **18 con `42501`** |
| Llamar funciones de trigger por RPC (53) | 2 se ejecutan (y fallan por ser de trigger), 51 con `42501` | **53 con `42501`** |

## 5. Realtime

- **Tablas publicadas:** `public.almacen_refacciones_movimientos` y `public.notificaciones` (sin cambio en la Fase 1).
- **Quién se suscribe (3 repos + `mati-app`):** una sola suscripción: `CampanaNotificaciones.tsx` (front), a `notificaciones` filtrada por usuario. **Nadie** se suscribe a `almacen_refacciones_movimientos` en ningún repo.
- **En producción esa suscripción no se usa:** `CampanaNotificaciones.tsx` solo abre el canal si `USA_API` es falso; con la compuerta (`VITE_API_URL`, el modo de producción) consulta cada **20 segundos** y la compuerta no proxea WebSockets. El recorrido «movimiento de inventario con notificación en tiempo real» es, en producción, **una consulta periódica**.
- **Registros de la API, 7 días:** **cero** conexiones a `/realtime/…`. Aun así, el sondeo interno de realtime (`list_changes`) es la 3.ª consulta que más tiempo acumula (120,062 llamadas, 653 s). *(Suposición, sin verificar: sin clientes suscritos ese sondeo podría quitarse al retirar la publicación; es de una fase posterior.)*
- **¿Queda una versión vieja del front desplegada?** Vercel conserva muchos despliegues de vista previa (`READY`) de ramas `devin/*` y `claude/*`, y los despliegues de producción anteriores siguen en la lista. **No se verificó** si son accesibles sin autenticación ni cuáles se compilaron sin `VITE_API_URL`. Las solicitudes `OPTIONS` directas del 23–24 oct sugieren que al menos una instancia en modo directo estuvo activa. *(Pendiente: revisar la protección de despliegues en Vercel y el valor de `VITE_API_URL` por entorno; no se tocó la publicación.)*

## 6. Qué demuestra y qué no

- **Demuestra:** que ni el código ni el tráfico real de 7 días usan la escritura de `anon`, y que quitarla no cambia ninguna de las 160 acciones por rol probadas, salvo cerrar `TRUNCATE`.
- **No demuestra:** que *nadie* intente usarla (puede haber llamadas directas con la llave pública anterior: la guía lista su rotación como pendiente; con la Fase 1 esas llamadas fallan con `42501` en lugar de depender solo de la seguridad por filas). Tampoco cubre tráfico anterior al 18 de octubre (la retención de registros es de 7 días).

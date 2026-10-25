# Estado de seguridad de la aplicación — 25 oct 2026

Para Polo. Solo lectura: no se cambió nada. Detalle en `HALLAZGOS-OTRAS-CAPAS.md`; lo que no se vio, en `LO-QUE-NO-SE-VERIFICO.md`.

## Respuesta corta

**La estructura está bien pensada, pero todavía no está bien cerrada.** La base y la compuerta tienen buenas defensas. Lo que falta está alrededor: quién puede publicar código, qué secretos hay en las vistas previas, y la entrada de MATI Admin. **No se encontró ninguna llave de servicio expuesta.** Hay **un punto que revisar hoy** (cuentas demo, O6).

## Por capa

| Capa | Qué ya está bien | Qué falta | Qué no se pudo verificar | Veredicto |
|---|---|---|---|---|
| **A. Repo, migraciones y compuerta** | Lista blanca (76 tablas y vistas, 106 funciones, 5 buckets, 5 funciones); sesión obligatoria; límite de 600 solicitudes por minuto; CORS por origen; sin secretos en el repo actual | `admin-update-user` deja subir de nivel a un admin de área (O1); el repo no tiene las protecciones de roles de producción (deriva) | Si hay `pg_cron` o conexión directa abierta | **Aceptable con pendientes** |
| **B. Front** | Cabeceras (HSTS, X-Frame-Options, nosniff); ninguna llave de servicio; consultas con texto del usuario limpiadas; HTML del recibo escapado | CSP con `unsafe-eval`/`unsafe-inline` (O13); token en `localStorage` (O14); error de contraseña filtrada mal manejado (O15); vistas previas sin compuerta (O3); dependencias altas (O5) | Cierre de sesión y expiración en producción | **Aceptable con pendientes** |
| **C. `mati-api`** | Cabeceras con Helmet; límites de intentos de inicio de sesión; CORS por lista; entradas validadas con esquemas estrictos en las rutas del puente; el secreto del puente no sale del servidor | Secretos de producción también en vistas previas (O4); `JWT_SECRET` y contraseñas de 1 carácter, sin segundo factor (O17); sin identificador de correlación (O16); rutas por comprobar (O18); `proxy-addr` crítica (O5) | Si todas las rutas de `workspace/*` exigen sesión | **Insuficiente** (hasta cerrar O4 y O17) |
| **D. MATI Admin** | Solo un `superadmin` activo entra a las rutas de Kit-to-Drive y cada llamada revisa token y cuenta activa; el puente impide dejar al sistema sin administrador global; la contraseña temporal nunca llega al navegador | Sin segundo factor; sesión de 8 h sin cierre remoto; contraseñas sin política (O17); un admin de MATI puede cambiar a otro admin | Cuántos super admin de MATI existen (otra base) | **Insuficiente** (la entrada tiene poder sobre producción) |
| **E. Edge functions y buckets** | JWT obligatorio en 6 de 7; el puente usa secreto en tiempo constante; `seed-demo-users` apagada; 8 de 9 buckets privados con límite y tipos | O1, O8, O12; `evidencias-compras` sin límite (O10); `refacciones-fotos` es público (O11); hay 9 buckets, no 4 | Duración de las URL firmadas | **Aceptable con pendientes** |
| **F. Vercel** | Variables sensibles ocultas; el secreto del puente solo en Producción; las vistas previas piden inicio de sesión de Vercel | Un solo equipo con 20 proyectos y una invitación pendiente de propietario (O9); secretos en Preview (O4) | Segundo factor del equipo; protección de despliegues de los demás proyectos | **Aceptable con pendientes** |
| **G. GitHub** | Pruebas automáticas en cada PR; el despliegue de funciones es solo manual | **`main` sin protección en los 3 repos** (O2); token de Supabase personal en Actions (O19); 83 ramas abiertas | Reglas tipo *ruleset*; si los flujos corren con secretos en PR externos | **Insuficiente** |
| **H. Supabase (configuración)** | Plan Pro; asesores de seguridad sin errores nuevos; llaves: pública en el front, servicio solo en servidores | — | **Toda la configuración de Auth** (confirmación de correo, MFA, redirecciones, límites); respaldos y restauración | **No evaluable; aceptable con pendientes según lo visible** |

## Orden de trabajo recomendado

### Urgente (esta semana, sin esperar la Fase 2)

1. **O6, cuentas demo:** confirmar si las contraseñas fijas del historial aún entran; si es así, rotarlas o dar de baja las 9 cuentas `@dazon.demo` (8 han iniciado sesión).
2. **O2, proteger `main`** en los 3 repos (PR, pruebas, sin push directo).
3. **O4, secretos de Preview de `mati-api`:** usar valores de prueba.
4. **O1, `admin-update-user`:** validar `area`/`nivel`. Cambio pequeño, en el código; entra en la Fase 2.

### Importante (Fase 2 en adelante)

5. Fase 2 de la base: perfiles, roles y super admins (S1, S2, S3), cerrando también O1 y O8.
6. MATI Admin: segundo factor, política de contraseñas, `JWT_SECRET` fuerte, identificador de correlación (O16, O17).
7. Dependencias (O5): primero `mati-api` y la compuerta.
8. Front: error de contraseña filtrada (O15) → después Polo activa la protección en el panel.
9. Vistas previas sin modo directo (O3), CSP más estricta (O13), CORS de las dos funciones (O12), `evidencias-compras` (O10).
10. Llevar al repo las protecciones de roles y registrar todo cambio de producción (deriva, D1–D3).
11. Equipo de Vercel: separar proyectos, revisar la invitación pendiente (O9).

## Decisiones que son de Polo

- ¿Quién es dueño de la cuenta `qq.com` de super admin? ¿Se confirma o se da de baja?
- ¿Se da de baja o se rotan las cuentas demo de Dazon?
- ¿Se exige **segundo factor** a administradores de Kit-to-Drive y MATI Admin?
- Reglas de **protección de ramas** (¿cuántas revisiones? ¿quién aprueba?).
- ¿`refacciones-fotos` sigue público?
- ¿Se separa el equipo de Vercel de Dazon del resto de proyectos?
- ¿Quién es el propietario pendiente de la invitación de Vercel?
- Rotación de la llave pública anterior (afecta a MATI Admin y funciones).

## Acciones que solo Polo puede hacer en paneles

- **Supabase → Authentication:** activar protección de contraseñas filtradas (después de O15) y revisar lo de `LO-QUE-NO-SE-VERIFICO.md` §2.
- **Supabase → Database → Backups:** anotar la fecha del último respaldo y probar una restauración.
- **GitHub → Settings → Branches / Rules:** crear las reglas de `main`.
- **Vercel → Team → Members:** revisar roles, invitación pendiente y segundo factor.
- **Fase 1:** escribir «Autorizo Fase 1 en producción, ventana del <fecha>» cuando quiera aplicarla.

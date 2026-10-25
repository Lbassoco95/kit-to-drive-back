# Lo que no se verificó (25 oct 2026)

Cada punto dice qué faltó, por qué, y qué acceso lo resolvería. Nada se supuso.

## 1. Plataformas

| Qué | Por qué no | Acceso necesario |
|---|---|---|
| Configuración de Auth de Supabase (proveedores, confirmación de correo, política de contraseñas, MFA, redirecciones, límites) | La herramienta conectada no expone esa configuración | Panel de Supabase o token de gestión de solo lectura |
| Respaldos: fecha, retención, copia externa, prueba de restauración | No visibles desde la herramienta | Panel de Supabase → Backups |
| Reglas tipo *ruleset* de GitHub, permisos de Actions, secretos en PR de ramas externas | La API conectada solo muestra la protección clásica de ramas (`protected: false`) | Acceso de administración al repo |
| Nombres de secretos de Actions | Sin acceso de administración | Idem. Solo se vio el uso en el flujo (`SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_ID`) |
| Segundo factor del equipo de Vercel; protección de los otros 17 proyectos | No se expone | Panel de Vercel |
| Variables de `mati-admin` y `mati-app` | Solo se leyeron `kit-to-drive`, `kit-to-drive-api`, `mati-api` y `mati-admin` (`mati-admin` solo tiene `VITE_API_URL`) | — |
| Conexión directa a Postgres, `pg_cron`, webhooks de base | Es configuración de red y de extensiones | Panel de Supabase |
| Historial de cambios de esquema (quién cambió las 17 políticas) | No hay registro accesible | Registro de actividad de la cuenta |

## 2. Lista exacta para mirar en el panel de Supabase

1. Authentication → Sign In / Providers: ¿está activa la confirmación de correo? ¿qué proveedores están encendidos? ¿el registro público está apagado?
2. Authentication → Policies: longitud mínima, requisitos de caracteres, protección de contraseñas filtradas.
3. Authentication → MFA: ¿disponible? ¿exigido a alguien?
4. Authentication → URL Configuration: *Site URL* y lista de redirecciones; deben ser solo las de producción.
5. Authentication → Rate Limits.
6. Project Settings → API Keys: ¿hay llaves antiguas (`anon`, `service_role`) y nuevas? ¿alguien tiene llaves de servicio fuera de los servidores?
7. Database → Backups: fecha del último, retención, ¿PITR?
8. Database → Network: restricciones de red y conexión directa.

## 3. Código y datos

| Qué | Por qué no | Qué haría falta |
|---|---|---|
| ¿Siguen vigentes las contraseñas fijas de las cuentas demo? (O6) | Comprobarlo implica iniciar sesión | Que el equipo lo pruebe en un entorno controlado, o rotarlas |
| Contraseñas de administradores de MATI y cuántos super admin tiene MATI | Está en otra base (la de MATI) y el encargo no la incluye | Acceso de lectura a esa base |
| Que todas las rutas de `mati-api/workspace/*` exijan sesión (O18) | Hay rutas que no la declaran en su archivo; puede estar en `app.ts` | Prueba automática recorriendo rutas sin token |
| Hallazgos de O1 y O8 | Leídos en código, no ejecutados contra producción (sería escribir) | Ensayo en la réplica local |
| Duración de las URL firmadas | Se piden desde el front con una duración en cada llamada; no se revisó cada una | Revisar `createSignedUrl` por pantalla |
| Políticas de storage por bucket | Revisadas solo las que ya constaban en la Fase 0 | Consulta de `pg_policies` de `storage.objects` |
| Registro de datos personales en consola/logs | `mati-api` registra el correo del admin en cada escritura (intencional, bitácora); el front y las funciones no se revisaron línea por línea | Revisión dirigida |
| Cierre de sesión y expiración reales del front | Se leyó el código, no se probó en producción | Recorrido manual con una cuenta de prueba |
| Secretos con forma no estándar en el historial | El escaneo busca formas conocidas (JWT, `sb_`, contraseñas literales) | Escáner dedicado (por ejemplo GitHub secret scanning) |

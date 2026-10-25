# Respaldo y reversa de la Fase 1 (Fase 0, sección 3.1)

Capturado el **25 de octubre de 2026** contra el proyecto Supabase `kit-to-drive` (producción, PostgreSQL 17.6), solo lectura. Ningún archivo de esta carpeta contiene datos de negocio ni de personas: solo permisos, políticas y configuración. Una prueba automática (`tests/fase1-permisos.test.ts`) lo vigila: ningún archivo de `respaldo/` puede traer correos, JWT ni llaves.

## 1. Qué se respaldó (en el repo)

| Archivo | Qué contiene | Filas |
|---|---|---|
| `respaldo/permisos-relaciones.sql` | Permisos de las 93 tablas y 18 vistas de `public` para `anon`, `authenticated` y PUBLIC, como sentencias `GRANT` listas para repetirse | 205 |
| `respaldo/permisos-funciones.sql` | Permiso de ejecución de las 268 funciones de `public` para `anon`, `authenticated` y PUBLIC | 236 |
| `respaldo/politicas-public-y-storage.sql` | Las 338 políticas de seguridad por filas (`public` y `storage`) como `CREATE POLICY` (la Fase 1 **no** las cambia) | 338 |
| `respaldo/funciones-config-y-huella.txt` | Por función: huella `md5` del cuerpo, `search_path`, si es SECURITY DEFINER y qué devuelve. Sirve para comprobar que la Fase 1 no cambió ninguna | 268 |
| `respaldo/permisos-por-defecto.txt` | Permisos por defecto de lo que se cree después (`pg_default_acl`) | 24 |
| `respaldo/rls-y-vistas.txt` | Seguridad por filas y opciones (`security_invoker`) de tablas y vistas | 111 |

Cada archivo dice en su cabecera cuándo se capturó y con qué consulta (`consultas/00-respaldo-catalogo.sql`). Para repetir la captura basta correr esa consulta de solo lectura y regenerar los archivos.

**Inventario de quién concedió cada permiso (necesario para elegir cómo revocar):** todos los permisos de tablas, vistas y funciones los otorgó `postgres`; `postgres` es dueño de las 93 tablas, 18 vistas, 9 secuencias y 268 funciones; ninguna concesión lleva `WITH GRANT OPTION` y no hay concesiones por columna. Por eso la forma segura es un `REVOKE` simple, **sin `CASCADE`**: si apareciera un permiso que dependiera de otro, el comando fallaría en lugar de arrastrarlo.

## 2. Copia lógica del esquema (sin datos), fuera del repositorio

`esquema_kit-to-drive_2026-10-25.sql` (≈ 720 KB): tipos, secuencias, 93 tablas, 268 funciones, restricciones, índices, 18 vistas, 242 triggers (240 de `public` y 2 de `auth.users`), 338 políticas, permisos y la publicación de realtime.

- **Dónde está:** en la carpeta temporal de esta sesión, `/tmp/claude-0/-home-user/3ae5d87f-ac0f-56c9-aa6f-9c7b6b4680e1/scratchpad/esquema_kit-to-drive_2026-10-25.sql`. Esa carpeta **desaparece cuando termina la sesión**: el archivo se entrega también por el chat y **hay que guardarlo en un lugar permanente** de K'awiil (por ejemplo la carpeta corporativa de respaldos) y anotar aquí la ruta final. *(Pendiente: Polo o Leo.)*
- **No va en el repo** porque contiene la lógica de negocio completa (funciones y políticas).
- **Cómo se hizo:** no hay credenciales de base de datos en esta sesión, así que no se pudo correr `pg_dump`. Se generó a partir del catálogo con consultas de solo lectura (`pg_get_functiondef`, `pg_get_viewdef`, `pg_get_triggerdef`, `pg_get_constraintdef`, etc.).
- **Prueba de que sirve:** se restauró en una base local vacía (PostgreSQL 16 con la imitación de Supabase del repo) y salió **93 tablas, 18 vistas, 268 funciones, 338 políticas y 242 triggers**, las mismas cifras que producción. Los únicos 2 errores son de la publicación de realtime, que el entorno local no tiene.
- **Límites:** no es un `pg_dump`, así que no incluye comentarios de objetos, la configuración de roles ni las extensiones propias de Supabase (`supabase_vault`, `pg_stat_statements`). Se probó restaurar en PostgreSQL 16 y no en 17.

## 3. Respaldo diario de Supabase

- **Plan:** la organización «Yoltik» está en plan **Pro** (verificado), que incluye respaldos diarios.
- **Fecha del último respaldo: pendiente de confirmar.** Las herramientas conectadas a esta sesión no exponen la lista de respaldos. **Antes de la ventana**, Polo (o quien tenga acceso) debe abrir *Supabase → proyecto kit-to-drive → Database → Backups*, anotar aquí la fecha y hora del respaldo más reciente y comprobar que sea del mismo día o del anterior: `________________`.
- Si se quiere más margen, en el mismo panel se puede pedir un respaldo adicional justo antes de empezar (Pro lo permite según el plan).

## 4. Cómo se revierte

Cada migración de `supabase/migrations/20261031…` tiene su reversa en `supabase/reversas/` con el mismo nombre más `_reversa`. Las reversas **solo conceden** (no quitan nada) y reponen **exactamente** lo que la migración quitó:

| Migración | Reversa | Cómo se generó |
|---|---|---|
| 1. TRUNCATE, TRIGGER y REFERENCES | repone esos tres permisos relación por relación (210 líneas) | Del respaldo, solo donde existían |
| 2. Funciones de trigger | repone EXECUTE a PUBLIC, `anon` y `authenticated` función por función (49 líneas) | Del respaldo de funciones |
| 3. `search_path` | `RESET search_path` en las 14 funciones | Su configuración original era «ninguna» |
| 4. Vistas de `anon` | repone los permisos de `anon` en las 16 vistas | Del respaldo, descontando lo que ya quitó el punto 1 |
| 5. Escritura de `anon` | repone INSERT, UPDATE y DELETE de `anon` en 81 tablas | Del respaldo |
| 6. Lo nuevo nace cerrado | vuelve a poner los permisos por defecto anteriores | Del respaldo de permisos por defecto |

**Orden:** si hay que deshacer varias, se aplican en orden inverso (6 → 1). Cada una también se puede deshacer sola.

**Pruebas de las reversas** (ensayo del 25 oct 2026, ver `ENSAYO-FASE-1.md`): después de aplicar cada migración se aplicó su reversa y se comparó el catálogo completo (permisos de tablas, vistas y funciones, `search_path` y permisos por defecto, con los ACL ordenados): **las 6 volvieron al estado exacto de antes**, y aplicando las seis reversas en orden inverso se recuperó la línea base completa. Un detalle que quedó resuelto en el ensayo: PostgreSQL agrega al final del ACL lo que se vuelve a conceder, así que el orden de `anon` y `authenticated` puede cambiar sin que cambie ningún permiso; la comparación lo ignora.

**Qué NO deshace una reversa:** objetos creados *después* del respaldo (una tabla nueva de esa semana no se «reabre»; queda cerrada, que es lo seguro) y, en el punto 6, los objetos que se hayan creado entre la migración y la reversa (nacieron cerrados).

**Cómo se verifica que volvió todo:** repetir la consulta `consultas/02-conteos-linea-base.sql` y compararla con `LINEA-BASE-2026-10-25.md`.

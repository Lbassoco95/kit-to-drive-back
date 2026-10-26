# Puente de Patio: qué token existió, dónde vive y qué rotar

Solo lectura, solo repos. No se consultó la base de datos. Aquí no hay valores.

## Nota de estado (corrección)
Una versión anterior de este documento decía que el puente seguía en producción hasta aplicar `20261009000002`. **Eso contradecía lo ya medido en la Fase 0:** el catálogo del 25 oct no tiene funciones `patio_*` ni la tabla `patio_bridge_secret`, y `20261009000002` falta en `migraciones_aplicadas` pese a estar aplicada (hallazgo D3). Lo coherente es: **se aplicó a mano sin registrarla y el puente ya no existe.** Falta confirmarlo con `consultas/08-puente-patio-estado.sql` en el canal de solo lectura.

## Qué es
- Puente anterior: funciones `public.patio_kit_*` (`list_users`, `overview`, `set_user_active`, `set_user_role`, `update_config`) más `public._patio_bridge_ok(text)`.
- Cada función recibía un token como primer argumento (`text`) y lo comparaba con una fila de la tabla `public.patio_bridge_secret`. Ese token es **la llave del puente**: una cadena guardada en **texto plano** en esa tabla.
- Las funciones nacieron abiertas a `anon` (permiso por defecto de PUBLIC). La única barrera era conocer el token.
- Las funciones `patio_kit_set_user_role` y `patio_kit_set_user_active` permiten cambiar roles y desactivar usuarios.

## Dónde quedó escrito
| Lugar | ¿Contiene el valor? |
|---|---|
| Migraciones del repo (113 archivos) | **No.** La creación del puente y del token **no está en el repo**. Solo aparece la tabla en `20260925193000` (un `REVOKE`) y en `20261009000002` (el `DROP`). |
| Historial remoto (`supabase_migrations.schema_migrations`, migraciones del 21 sep) | **Probable, no verificado.** Es donde se creó la tabla y se sembró el token. Se confirma con la consulta 07 una vez comprobado el canal de solo lectura. |
| Tabla `public.patio_bridge_secret` en producción | **Probablemente ya no existe** (ver la nota de estado abajo). |
| Respaldos de la base anteriores a esa fecha | Sí, por consecuencia de lo anterior. |

**Corrección de documentación:** el encabezado de `20261009000002` dice que "las definiciones originales siguen en `20260925193000`". Es falso: ese archivo no las contiene. Si hiciera falta volver atrás, la definición hay que sacarla del historial remoto, no del repo. La corrección del comentario se hace en la próxima edición de ese archivo, sin cambiar el SQL.

## ¿Se usa en otro lugar?
Se revisaron los cuatro repos que tengo clonados: `kit-to-drive`, `kit-to-drive-back`, `kit-to-drive-front` y `mati-app`, incluido el historial de git. No encontré consumidores del puente de Patio:
- Ningún código de aplicación llama a `patio_kit_*`. Las únicas apariciones son pruebas de la compuerta (`kit-to-drive-front/tests`), que verifican que esas rutas dan **403**, y las migraciones que lo cierran.
- La palabra "patio" en otros archivos es lenguaje de negocio (patio de inventario), sin relación.
- Ningún `.env.example` ni archivo de configuración nombra una variable del puente de Patio.
- El puente vigente es **otro**: la Edge Function `mati-admin-bridge`. Usa `MATI_ADMIN_BRIDGE_SECRET` (en Supabase) y `KIT_TO_DRIVE_BRIDGE_SECRET` / `KIT_TO_DRIVE_BRIDGE_URL` (en mati-api). No usa la tabla `patio_bridge_secret`.

**Lo que los repos no pueden decir:**
1. Si el valor del token de Patio se reutilizó como `MATI_ADMIN_BRIDGE_SECRET` o `KIT_TO_DRIVE_BRIDGE_SECRET`. Compararlos exigiría leer ambos valores. No lo hice y no lo haré yo.
2. Si alguien fuera de estos repos (scripts, hojas, personas) conserva el token.
3. Si el token está en el historial remoto de migraciones. Se confirma en la tarea 2.

## Qué rotar
1. **Nada urgente por el puente en sí**, si se confirma que ya no existe (ver la nota de estado).
2. **Rotar `MATI_ADMIN_BRIDGE_SECRET` y `KIT_TO_DRIVE_BRIDGE_SECRET` solo si coinciden con el token de Patio.** Polo puede comprobarlo sin mostrarlo: comparar en su terminal el hash de ambos valores. Si coinciden, se genera un valor nuevo y se pone el mismo en Supabase y en mati-api.
3. **El historial remoto seguirá guardando el token** aunque se borre la tabla. Decisión de Polo: dejar el historial como está (el token ya no sirve) o limpiar esa fila del historial. No lo hago yo.
4. Si el token se compartió fuera del equipo, tratarlo como comprometido y revisar el uso entre el 21 sep y el 9 oct (tarea 3, pendiente del canal de solo lectura).

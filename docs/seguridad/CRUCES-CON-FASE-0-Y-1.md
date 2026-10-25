# Cruces con la Fase 0 y la Fase 1 (25 oct 2026)

Solo lectura. Cada punto del apartado 4 del encargo, contestado con el código de las otras capas.

## 1. Autopromoción (`es_vendedor`, `es_administrativo` en el propio perfil) — S1

- **Pantalla o endpoint que la permite hoy:** ninguna pantalla del front ofrece cambiar esos campos *en el propio perfil*. La permite la **base**: el front escribe `profiles` por la compuerta (la lista blanca incluye `PATCH profiles`) y el trigger no protege esos dos campos. Cualquier usuario con sesión puede intentarlo con una llamada directa. Probado en la réplica (Fase 0), no en producción.
- **Flujo legítimo que escribe esos campos:** **solo una**: la Edge Function `admin-update-user` (`index.ts:49,102–106`), con llave de servicio, llamada desde Usuarios. Las demás pantallas solo **leen** `es_vendedor` (CRM: `CrmOportunidadDetail.tsx:60`, `CrmRutas.tsx:66`, `CrmOportunidades.tsx:72`, `CrmActividades.tsx:123`). `admin-create-user` y el puente `mati-admin-bridge` no los escriben desde el front.
- **Conclusión:** bloquear la escritura de esos dos campos por parte del usuario (Fase 2) **no rompe ninguna pantalla**: la función de servicio sigue funcionando.
- **Nuevo, de esta corrida:** quien sí puede fijarlos en otro usuario es un admin de área (misma función). Ver O1 y O8 en `HALLAZGOS-OTRAS-CAPAS.md`.

## 2. Cuentas por cobrar vencidas visibles a cualquier sesión — S2

- **Quién llama a `cliente_tiene_cxc_vencidas` y `cxc_vencidas_resumen`:** solo `src/lib/creditoDb.ts:134,150`. Esa librería la usan tres pantallas: **Remisiones**, **Crédito** y **Dashboard** (`grep` de `creditoDb`).
- **Con qué rol:** el código no filtra por rol al llamar. Las pantallas se muestran según el área del usuario; la función responde a cualquier sesión. La compuerta las tiene en su lista blanca de funciones (sesión obligatoria, sin chequeo de rol).
- **Efecto de cerrarlas a quien no deba:** hay que conservar el permiso para los roles que usan Remisiones (comercial y administración), Crédito y Dashboard. Primero hace falta el cuadro de roles por pantalla (`RECORRIDOS-Y-PRUEBAS-POR-ROL.md`); cerrar sin eso rompe Remisiones. Hay dos pruebas con la función simulada (`remisiones-*.test.tsx`).

## 3. Edición de perfiles ajenos por admin de otra área, incluidos super admins — S1

- **Por la base (ya conocido):** se puede cambiar nombre, correo y código de vendedor.
- **Por las Edge Functions (nuevo):** `admin-update-user` y `admin-reset-user-password` **sí comparan el área**: un admin que no es de Dirección solo toca usuarios de su área (`admin-update-user/index.ts:62–67`; `admin-reset-user-password/index.ts:55–60`). Un admin de Dirección (global) toca a cualquiera, incluidos los super admins. Quien «solo comparte el área» puede además subir de nivel (O1).
- **Por MATI Admin:** el puente permite editar a cualquiera, pero está detrás de la sesión de un administrador de MATI y solo impide **dejar al sistema sin administrador global** (`assertNoSeQuedaSinAdmin`, `mati-admin-bridge/index.ts:188–193,292–293,317`). Un administrador de MATI sí puede cambiar a un super admin o a otro administrador.
- **Qué pasa si un admin intenta cambiarse a sí mismo:** `admin-update-user` no lo impide (O1). La base sí protege el rol propio y la baja del administrador global (Fase 0).
- **Super admins hoy:** **2** (1 con correo de dominio de Dazon y **1 con correo `qq.com`**). Hay **6** usuarios con área Dirección y nivel admin. Datos de solo conteo; la cuenta `qq.com` sigue pendiente de confirmar por Polo.

## 4. Deriva producción–repo (17 políticas solo en producción, 5 solo en repo)

Qué otro proceso cambia producción fuera de las migraciones. Es una **deducción**, no un hecho confirmado:

1. **Agentes y herramientas externas.** El front tiene 83 ramas con prefijos `claude/`, `cursor/` y `devin/`, entre ellas `cursor/security-golive-fase2-171b`, `cursor/security-hardening-kti-da5a`, `cursor/endurecer-accesos-30b5` y `cursor/proteger-migraciones-5dfb`. Esas herramientas tienen acceso a Supabase (SQL o MCP) y su cambio no pasa por una migración del repo.
2. **Pegado en el SQL Editor.** La guía del equipo y el mecanismo de aplicación son «pegar el archivo en el SQL Editor» (`VENTANA-FASE-1.md` §3): un cambio hecho a mano no deja registro (`migraciones_aplicadas` está atrasado, D3).
3. **Funciones desplegadas por otra vía.** `firmas` está desplegada y **no está** en la lista del flujo `deploy-edge-functions.yml`.
4. **El repo no sabe de `impedir_escalada_rol` ni `proteger_profile_activo`** (D1): alguien las creó directo en producción.

No hay ningún otro repo que aplique migraciones: `mati-app` tiene su propia base (`supabase/config.toml`) y no toca la de Kit-to-Drive salvo por el puente. **No verificado:** registro de auditoría de cambios de esquema en Supabase (hace falta el historial de la cuenta).

## 5. Realtime (2 tablas)

- **Quién se suscribe:** un solo componente, `CampanaNotificaciones.tsx:41–42` (front), canal `notificaciones-<usuario>`, a la tabla `notificaciones`. En ningún repo (front, back, compuerta, `mati-app`, MATI Admin) hay suscripción a `almacen_refacciones_movimientos`.
- **Con qué llave:** la pública más la sesión del usuario (cliente de `supabase-js` del front).
- **En producción no corre:** solo abre el canal si no hay compuerta; con `VITE_API_URL` consulta cada 20 s y la compuerta no pasa WebSockets. En vistas previas (modo directo, O3) sí abre el canal.
- Registros de 7 días: cero conexiones a `/realtime/`.

## 6. Tablas con escritura para `anon`

Ningún flujo de ninguna capa las usa:

- **Front:** no usa nunca el rol `anon` para datos; todas las llamadas llevan la sesión del usuario. `anon` solo se usa en login, recuperación y URL firmadas (`Auth.tsx`).
- **Compuerta:** `rest`, `rpc` y `functions` exigen sesión; solo pasan `auth/token`, `auth/recover` y URL firmadas.
- **Edge Functions:** llave pública solo para `auth.getUser()`; datos con servicio.
- **`mati-api`, MATI Admin, MATI App:** hablan con su propia base; el puente usa servicio, no `anon`.
- **Registros de API (7 días):** cero llamadas `rest/v1` con rol `anon`.

## 7. ¿Hay otra forma de llegar a la base sin pasar por la compuerta?

Sí. Está listada con evidencia en `MAPA-DE-LA-APLICACION.md` §4:

1. **El front en modo directo** (vistas previas sin `VITE_API_URL`) y cualquiera con la llave pública y una sesión que llame a PostgREST directo: la compuerta no es obligatoria, **la barrera real es RLS** (O3).
2. **Edge Functions con llave de servicio** (O1).
3. **El puente de MATI Admin** con secreto compartido.
4. **SQL Editor / herramientas con token** de Supabase (deriva).
5. **No verificado:** conexión directa a Postgres (red), `pg_cron` en producción, webhooks de base.

**Nota:** esto confirma el principio de la Fase 0: la compuerta es una capa más, no la primera. RLS y permisos son los que defienden la base.

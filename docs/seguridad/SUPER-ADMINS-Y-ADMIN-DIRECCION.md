# Super admins y administradores de Dirección (Fase 2) — 26 oct 2026

Solo lectura. Se lista **tipo de cuenta, dominio del correo y estado**; los correos completos van en el archivo que se entrega aparte a Polo (no se versionan).
**Ninguna cuenta se modificó.**

## 1. Los 2 super admins

| # | Dominio del correo | Quién es | Responsable de la cuenta | Estado | Último acceso | Segundo factor |
|---|---|---|---|---|---|---|
| S1 | `dazon.mx` | Administrador de Dazon | Dazon (a confirmar por Polo con nombre) | Activa | 21 oct | **No verificado** |
| S2 | `qq.com` | **Peter**, administrador del equipo chino (decisión de Polo del 25 oct) | **Peter** | Activa | 16 oct | **No verificado**; lo activa Polo con Peter |

La cuenta `qq.com` **se conserva**. Ningún cambio de la Fase 2 la modifica.

## 2. Los 6 usuarios con área Dirección y nivel admin (C4)

| # | Tipo de cuenta | Dominio | Super admin | Activa | Último acceso | Observación |
|---|---|---|---|---|---|---|
| D1 | Administrador de Dazon | `dazon.mx` | **Sí (S1)** | Sí | 21 oct | — |
| D2 | Administrador del equipo chino | `qq.com` | **Sí (S2)** | Sí | 16 oct | — |
| D3 | Cuenta del equipo Yoltik (probablemente la de Polo; por confirmar) | `yoltik.mx` | No | Sí | 22 oct | Administrador global que no es super admin |
| D4 | Cuenta del equipo Yoltik | `yoltik.mx` | No | Sí | **nunca** | **Nunca ha iniciado sesión**; conserva «debe cambiar contraseña» |
| D5 | Cuenta del equipo Yoltik | `yoltik.mx` | No | Sí | **nunca** | **Nunca ha iniciado sesión**; conserva «debe cambiar contraseña» |
| D6 | `admin@dazon.demo` (cuenta demo) | `dazon.demo` | No | **No** | 22 sep | Administrador global inactivo con contraseña fija en el historial (ver `CUENTAS-DEMO.md`) |

**Qué debe decidir Polo con esta lista:**
- D4 y D5 son **administradores globales activos que nunca entraron**: tienen una contraseña temporal pendiente de cambiar. Si las personas ya no la necesitan, desactivarlas; si sí, que entren y la cambien.
- D6 se bloquea con el script de cuentas demo (no se borra).
- D3, D4 y D5 son administradores globales que **no** son super admin: después de la Fase 2 **no podrán modificar** a S1 ni a S2.
- ¿Cada administrador global necesita serlo? Un administrador global puede crear y cambiar a cualquiera (menos super admins). Tres cuentas de equipo más una demo es mucho poder; esta fase no cambia a ninguno.

## 3. Cómo quedan las reglas de los super admins (C3)

| Regla | Dónde vive | Se prueba |
|---|---|---|
| Solo un super admin modifica el **perfil** (nombre, correo, activo, código, función comercial) de otro super admin | Base: `trg_proteger_perfil_fase2` (cambio 1) | Ensayo: 4 acciones × 12 roles |
| Solo un super admin cambia o quita el **rol** (área, nivel) de otro super admin | Base: `impedir_escalada_rol` (cambio 2) | Ensayo |
| La lista `super_admins` no la escribe ninguna sesión de usuario | Base: permisos cerrados (`REVOKE ALL`, sin políticas), ya existía | Ensayo: escribir y borrar → nadie |
| Agregar o quitar a un super admin es una operación deliberada | Función `asignar_super_admin()` (deja renglón en `bitacora_super_admin`) | Ensayo |
| Una escritura directa a la lista (servicio o SQL Editor) también deja rastro | Base: `trg_rastro_lista_super_admins` (cambio 5) | Ensayo |
| Las Edge Functions (llave de servicio) aplican las mismas reglas **antes** de escribir | Código: `_shared/permisos.ts` | 42 pruebas (`tests/fase2-permisos-usuarios.test.ts`) |
| Restablecer la contraseña de un super admin (sería tomar la cuenta) | Código: `admin-reset-user-password` | Pruebas |

**Un super admin que se edita a sí mismo** solo puede cambiar su nombre. Para cambiarle algo a S1 hace falta S2, y al revés.

**Una decisión de Polo que cambia el diseño (no se tocó):** hoy `asignar_super_admin()` **solo** la puede ejecutar un administrador global que **no** es super admin (los dos super admins no pueden agregar ni quitar super admins). Eso va al revés de «solo un super admin modifica a otro». Se dejó como está para no romper la pantalla de Aprobaciones. Opciones:
- **A (actual):** D3–D5 gestionan la lista. Un administrador global que no es super admin puede quitar o poner super admins.
- **B:** solo un super admin gestiona la lista. Más coherente con C3; exige cambiar esa función y la pantalla.

**Decisión de Polo (26 oct 2026): A en la Fase 2 y B DESPUÉS de la Fase 2.** Quedó lista, sin aplicar: la migración `20261110000001_asignar_super_admin_solo_super_admin` (+ reversa; ensayada: `docs/seguridad/ensayo/resultado-operaciones-cuentas.json`) y el cambio de front en la rama `claude/asignar-super-admin-front` (sin mezclar). Con B, Polo (administrador global, no super admin) deja de poder asignar o quitar super admins; pueden Martin y Peter. Frase: «Autorizo asignar_super_admin opción B, ventana del `<fecha>`».

## 4. Responsables

| Cuenta | Responsable | Estado de la confirmación |
|---|---|---|
| S1 | Dazon | **Pendiente: Polo confirma nombre** |
| S2 | Peter (decisión de Polo, 25 oct) | Confirmada |
| D3 | Polo | Por confirmar por Polo |
| D4, D5 | Equipo Yoltik | **Pendiente: Polo decide** |
| D6 | Nadie (cuenta demo) | Se bloquea |

## 5. No verificado

- Segundo factor de cualquier cuenta (configuración de Auth).
- Quién usa cada cuenta de `yoltik.mx` además de lo que diga Polo.
- Los administradores de MATI Admin (viven en otra base, `admin_users`): el puente puede modificar a cualquier usuario de Kit-to-Drive con permiso propio; está fuera de esta fase (ver `HALLAZGOS-OTRAS-CAPAS.md`, O16 y O17).

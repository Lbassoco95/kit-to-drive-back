# Revisión de perfiles históricos (C6) — 26 oct 2026

**Solo lectura. No se corrigió nada.** Polo revisa esta lista; la Fase 2 no toca ningún dato de perfiles.
Los usuarios van con código (P01…P26) y solo el dominio del correo. El archivo con los correos completos se entrega aparte a Polo y no se versiona.

## 1. Qué se comparó

Contra lo que el flujo normal de alta habría dejado (`admin-create-user`, `asignar_super_admin` y la migración `20261014000002_profiles_funcion_comercial`):

| Regla del flujo normal | Cuántos la incumplen |
|---|---|
| `es_vendedor` / `es_administrativo` solo existen en **Comercial** (la función las pone en falso fuera de Comercial) | **0** |
| Nadie tiene **las dos** banderas | **0** |
| En Comercial, quien es administrativo no es vendedor (el alta pone `es_vendedor = no es_administrativo`) | **0** |
| El rol legado (`user_roles.role`) corresponde al área y nivel | **0** de 25 |
| Todo perfil tiene rol | **1** perfil sin rol (P12) |

**Conclusión: ningún perfil incumple la forma que deja el flujo normal.** Eso no prueba que no hubo autopromoción: un usuario pudo ponerse `es_administrativo` y quedar con una forma válida.

## 2. Qué hay (26 perfiles; 12 con `es_vendedor`, 2 con `es_administrativo`)

| Cód. | Cuenta (dominio) | Área / nivel | Activo | es_vendedor | es_administrativo | Alta del perfil | Rol asignado | Perfil editado por última vez | Entró alguna vez |
|---|---|---|---|---|---|---|---|---|---|
| P01 | yoltik.mx | direccion / admin | sí | no | no | 28 jun | 19 ago | 29 sep | sí |
| P02 | dazon.demo (fabrica) | fabrica / operador | no | no | no | 28 jun | 15 jul | 25 sep | sí |
| P03 | dazon.demo (logistica) | almacen_logistica / operador | no | no | no | 28 jun | 15 jul | 25 sep | sí |
| P04 | dazon.demo (ventas) | comercial / operador | no | sí | no | 28 jun | 15 jul | 14 oct | sí |
| P05 | dazon.demo (coordinador) | comercial / supervisor | no | sí | no | 28 jun | 28 jun | 14 oct | no |
| P06 | dazon.demo (admin) | direccion / admin | no | no | no | 28 jun | 15 jul | 25 sep | sí |
| P07 | dazon.mx | comercial / operador | sí | no | sí | 8 jul | 13 oct | 20 oct | sí |
| P08 | dazon.mx | fabrica / admin | sí | no | no | 8 jul | 12 oct | 12 oct | sí |
| P09 | dazon.demo (lee) | comercial / admin | sí | sí | no | 8 jul | 15 sep | 14 oct | sí |
| P10 | dazon.demo (marco) | comercial / supervisor | sí | sí | no | 8 jul | 25 sep | 14 oct | sí |
| P11 | dazon.demo (edgar) | fabrica / operador | no | no | no | 8 jul | 25 sep | 25 sep | sí |
| P12 | (sin correo en perfil) | (sin rol) / (sin rol) | sí | no | no | 13 jul | — | 25 sep | sí |
| P13 | dazon.demo (finanzas) | administracion / admin | sí | no | no | 17 jul | 25 sep | 25 sep | sí |
| P14 | dazon.mx | comercial / supervisor | sí | no | sí | 24 ago | 13 oct | 14 oct | sí |
| P15 | yoltik.mx | direccion / admin | sí | no | no | 8 sep | 8 sep | 25 sep | no |
| P16 | yoltik.mx | direccion / admin | sí | no | no | 8 sep | 8 sep | 25 sep | no |
| P17 | dazon.mx | direccion / admin | sí | no | no | 22 sep | 19 oct | 19 oct | sí |
| P18 | qq.com | direccion / admin | sí | no | no | 29 sep | 16 oct | 19 oct | sí |
| P19 | dazon.mx | comercial / supervisor | sí | sí | no | 10 oct | 21 oct | 21 oct | sí |
| P20 | dazon.mx | comercial / operador | sí | sí | no | 14 oct | 14 oct | 21 oct | sí |
| P21 | dazon.mx | comercial / operador | sí | sí | no | 14 oct | 14 oct | 21 oct | sí |
| P22 | dazon.mx | comercial / operador | sí | sí | no | 14 oct | 14 oct | 14 oct | sí |
| P23 | dazon.mx | comercial / operador | sí | sí | no | 21 oct | 21 oct | 21 oct | no |
| P24 | dazon.mx | comercial / operador | sí | sí | no | 21 oct | 21 oct | 21 oct | no |
| P25 | dazon.mx | comercial / operador | sí | sí | no | 22 oct | 22 oct | 22 oct | no |
| P26 | dazon.mx | comercial / operador | sí | sí | no | 22 oct | 22 oct | 22 oct | no |

## 3. A quién mirar (candidatos, no culpables)

| Qué | Quién | Por qué | Origen del cambio |
|---|---|---|---|
| **Tienen `es_administrativo`** (la bandera que da visibilidad de todas las remisiones de Comercial y permite reasignar vendedores; la que se podía autopromover) | **P07, P14** | Son los únicos dos. P07 es operador de Comercial. | **No se puede saber** (ver §4). Compatible con el alta normal: el rol de ambos se asignó el 13 oct, antes de la fecha de la última edición de P07 (20 oct). |
| **Editados después del 14 oct**, día en que la migración puso las banderas | P07 (20 oct), P17 y P18 (19 oct, los dos super admins), P19 a P21 (21 oct) | Una edición posterior puede ser la pantalla Usuarios (legítima) o una escritura propia. P17 y P18 coinciden con la asignación de Super admin. | No hay registro. |
| **Perfil sin rol** | P12 | Activo, sin área ni nivel. Puede ser una baja a medias. | No hay registro. |
| **Administradores de área** (pueden cambiar banderas de su área) | P08 (Fábrica), P09 (Comercial, cuenta demo `lee`), P13 (Administración, cuenta demo `finanzas`) | Dos son cuentas con correo demo. | — |
| **Administradores globales sin super admin** | P01, P15, P16, P06 | Ver `SUPER-ADMINS-Y-ADMIN-DIRECCION.md`. | — |
| **Roles asignados mucho después del alta del perfil** | 15 de 25 | Normal si se les cambió el área; no se puede distinguir de una reasignación indebida. | No hay registro. |

## 4. Si hay forma de saber el origen de un cambio: **no**

Lo que existe hoy:
- **No hay tabla de historial de cambios de perfiles ni de roles.** Solo `updated_at` (fecha, sin autor ni valor anterior).
- `bitacora_super_admin`: 258 renglones del 16 al 21 oct, pero solo registra la **actividad de los super admins**; sobre perfiles y roles únicamente tiene las asignaciones del Super admin (4 renglones: 2 asignaciones y 2 restauraciones).
- `bridge_bitacora` (puente de MATI Admin): **3 renglones**, del 9 al 10 oct. **Las Edge Functions de usuarios no dejaban rastro.** Desde la Fase 2 sí lo dejan (ver `FASE-2-CAMBIOS-Y-REVERSAS.md`).
- Los registros de la API de Supabase duran **7 días** (desde el 19 oct): no alcanzan para fechas anteriores y no guardan el cuerpo de la petición.

**Por eso la auditoría es la Fase 4.** Hasta entonces, lo único que puede aclarar un cambio es preguntarle a la persona que administró Usuarios esa semana.

## 5. Lo que Polo puede hacer con esto

1. Confirmar con los administradores de Comercial que P07 y P14 deben tener `es_administrativo`.
2. Decidir qué hacer con P12 (perfil sin rol).
3. Revisar que cada administrador de área (P08, P09, P13) deba serlo.
Nada de esto bloquea la Fase 2.

# Propuesta: cuenta `lee` — cerrar sesiones activas (sin aplicar)

**Estado: propuesta. No se aplica y no tiene frase de autorización.** Se hizo sin consultar producción hoy (esperando el MCP de solo lectura); los datos de `lee` son los de la lectura del 26 oct, 04:3x UTC.

## 1. Situación (26 oct, solo lectura)

| Dato de `lee@dazon.demo` | Valor |
|---|---|
| Perfil | **Activo**; Comercial / **admin** (administrador de área) |
| Último acceso | **13 jul 2026** |
| «Debe cambiar contraseña» | **Sí** (en el perfil y en Auth: `must_change_password = true`): nunca cambió la contraseña inicial |
| Sesiones vigentes / tokens de renovación vigentes | **0 / 0** |

**Consecuencia: cerrar sus sesiones hoy no tendría ningún efecto**, porque no tiene sesiones. Por eso el script de cambio obligatorio **no se corre** (ya está activado) y este también sería un no-op hoy.

## 2. Qué haría el cierre (si algún día tuviera sesiones)

Script `supabase/operaciones/fase2-cerrar-sesiones-lee.sql` (+ reversa), probado en una copia local con datos inventados:

| Qué cambia | Qué NO cambia |
|---|---|
| `auth.sessions.not_after` de sus sesiones vigentes pasa a «ahora» | La contraseña |
| `auth.refresh_tokens.revoked = true` de sus tokens vigentes | El perfil, el rol, el área, el correo |
| — | **Ninguna fila se borra** |
| — | Las sesiones y tokens de **otras** cuentas (probado con `marco`) |

**Efecto para la persona:** su sesión deja de poder renovarse; cuando caduque el token de acceso que ya tiene (hasta ~1 h; la duración exacta depende de la configuración de Auth: **no verificada**), la aplicación le pide **iniciar sesión otra vez**. Si ya tiene una contraseña temporal pendiente, el flujo es el normal de «debe cambiar contraseña».

**No invalida la contraseña.** Quien la conozca puede volver a iniciar sesión. Para invalidarla de verdad: «Restablecer contraseña» en Usuarios (llega por correo; ojo: si el correo `@dazon.demo` no existe, no llega y la persona queda sin acceso: por eso va **después** de migrar a su correo real).

## 3. Reversa

- El script **imprime** los ids de lo que cambió y los valores anteriores. Con esa lista, `…_reversa.sql` los restaura (probado).
- **Casi nunca hace falta:** cerrar sesiones es intencional. Solo sirve para deshacer un cierre hecho por error **antes** de que la persona vuelva a entrar.
- Si no había sesiones: el script avisa y no cambia nada (no hay nada que revertir).

## 4. Orden recomendado para `lee` (decisión de Polo)

1. Polo le pide a `lee` que **cambie su contraseña** (ya la tiene marcada).
2. Si es una persona real con otro correo: **migrar a correo real** (script aparte, espera los correos).
3. **Restablecer contraseña** desde Usuarios (llega al correo real) si Polo quiere invalidar la vieja.
4. Cerrar sesiones solo si, en ese momento, **tiene sesiones** (se comprueba justo antes).

## 5. Qué necesita

Una **frase propia** de Polo (por ejemplo: «Autorizo cerrar las sesiones de lee, ventana del `<fecha>`»); **no** está entre las cinco frases vigentes. Y la comprobación, justo antes, de cuántas sesiones tiene (si son 0, no se corre).

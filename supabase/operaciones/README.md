# Operaciones puntuales (no son migraciones)

Aquí viven scripts que **cambian datos de producción de una sola vez** (por ejemplo, cuentas demo). No están en `supabase/migrations/`
a propósito: ningún proceso los corre solos, cada uno exige la **frase de autorización de Polo** (ver `docs/seguridad/RUNBOOK-VENTANA-FASE-2.md`)
y trae su reversa y su verificación.

| Script | Qué hace | Reversa | Autorización |
|---|---|---|---|
| `fase2-desactivar-cuentas-demo-inactivas.sql` | Bloquea el inicio de sesión (Auth) de cuentas demo ya inactivas. No borra nada. | `fase2-desactivar-cuentas-demo-inactivas_reversa.sql` | «Autorizo desactivar cuentas demo inactivas, ventana del <fecha>» |
| `fase2-forzar-cambio-password-demo-activas.sql` | Marca para cambiar la contraseña en el siguiente inicio de sesión a una cuenta demo activa (por defecto `lee`; `finanzas` y `marco` solo si Polo las nombra). | `…_reversa.sql` | «Autorizo cambio de contraseña obligatorio a lee, ventana del <fecha>» |
| `fase2-migrar-correo-real-lee-marco.sql` | Cambia el correo de `lee` y `marco` (Auth, identidad y perfil) por su correo real; **los correos los pone Polo al correrlo** (no se guardan en el repo). | `…_reversa.sql` | «Autorizo migrar a correo real a lee y marco, correos: <correos>, ventana del <fecha>» |

Reglas: se corren en el SQL Editor de **producción** (nunca en QA), en una sola transacción, dentro de la ventana permitida, y se comprueba la verificación que devuelven.
No llevan contraseñas, tokens ni llaves.

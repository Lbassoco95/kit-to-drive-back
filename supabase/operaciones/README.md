# Operaciones puntuales (no son migraciones)

Aquí viven scripts que **cambian datos de producción de una sola vez** (por ejemplo, cuentas demo). No están en `supabase/migrations/`
a propósito: ningún proceso los corre solos, cada uno exige la **frase de autorización de Polo** (ver `docs/seguridad/RUNBOOK-VENTANA-FASE-2.md`)
y trae su reversa y su verificación.

| Script | Qué hace | Reversa | Autorización |
|---|---|---|---|
| `fase2-desactivar-cuentas-demo-inactivas.sql` | Bloquea el inicio de sesión (Auth) de cuentas demo ya inactivas. No borra nada. | `fase2-desactivar-cuentas-demo-inactivas_reversa.sql` | «Autorizo desactivar cuentas demo inactivas, ventana del <fecha>» |
| `fase2-forzar-cambio-password-demo-activas.sql` | Marca para cambiar la contraseña en el siguiente inicio de sesión a las 3 cuentas demo activas. | `…_reversa.sql` | Frase aparte, con las cuentas nombradas |

Reglas: se corren en el SQL Editor de **producción** (nunca en QA), en una sola transacción, dentro de la ventana permitida, y se comprueba la verificación que devuelven.
No llevan contraseñas, tokens ni llaves.

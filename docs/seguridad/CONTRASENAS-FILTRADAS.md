# Protección contra contraseñas filtradas — paso a paso para Polo

**No se activó desde Claude ni por API.** Se hace a mano en el panel de Supabase, **y no en la misma ventana que la Fase 1**: es un cambio distinto y conviene ver sus efectos por separado. El plan de la organización es **Pro** (verificado el 25 oct 2026), así que la opción está disponible.

## 1. Qué hace

Cuando alguien elige o cambia una contraseña, Supabase la compara con la lista pública de contraseñas filtradas (HaveIBeenPwned) y **la rechaza si aparece**. No afecta el inicio de sesión de quien ya tiene una contraseña.

## 2. Cómo activarla

1. Entrar a **supabase.com/dashboard** con la cuenta de la organización «Yoltik».
2. Abrir el proyecto **kit-to-drive** (no QA ni los demás).
3. Menú izquierdo → **Authentication** → **Sign In / Providers** (o **Policies**, según la versión del panel) → sección **Password security** / **Contraseñas**.
4. Activar **«Prevent use of leaked passwords»**. Se puede subir también la longitud mínima, pero **no ahora** (el front y la función piden mínimo 8).
5. Guardar. Anotar la fecha y hora aquí: `________________`.

Para desactivarla: el mismo interruptor.

## 3. Pruebas obligatorias después de activarla

Hacerlas el mismo día, con cuentas de prueba:

1. **Inicio de sesión** con una contraseña normal de un usuario existente → entra (no debe cambiar nada).
2. **Cambio de contraseña con una débil conocida** (por ejemplo `Password123!` o `Qwerty12345`) en la pantalla «cambiar contraseña» → debe **rechazarla**.
3. **Cambio con una contraseña fuerte y única** → debe aceptarla y devolver a `/auth?passwordUpdated=1`.
4. **Alta de usuario desde MATI Admin** → debe seguir funcionando: la contraseña temporal la genera el servidor (aleatoria y larga), no se teclea, así que casi no hay riesgo de que figure como filtrada; si algún día fallara por esto, el error debe verse completo en MATI Admin.
5. **Restablecer contraseña** (correo de recuperación) con una débil → debe rechazarla.

## 4. Lo que el front hace hoy con ese error — **no lo maneja bien**

Revisado en el código el 25 oct 2026 (`kit-to-drive`, `kit-to-drive-back`, `mati-app`):

- **Dónde se elige una contraseña:** `ForcePasswordChange.tsx` y `ResetPassword.tsx`, ambas por `changePassword()` de `AuthContext.tsx`, que llama a la Edge Function **`complete-password-change`**, que usa `auth.admin.updateUserById`.
- **Qué pasaría:** Supabase contesta con el código `weak_password` y un mensaje en inglés. La función lo devuelve tal cual con estado **400** (`{ error: updErr.message }`).
- **Defecto 1 (el importante):** en `changePassword()` el front hace `if (invokeErr) return new Error(invokeErr.message …)`. Cuando una Edge Function responde 400, `supabase-js` entrega `invokeErr` con el texto genérico **«Edge Function returned a non-2xx status code»** y el cuerpo real no se lee. Es decir, **el usuario vería ese texto genérico**, no «contraseña filtrada». Ya pasa hoy con el 400 de «Elige una contraseña más segura» y «password inválida»: nunca llegan a la pantalla.
- **Defecto 2:** aunque llegara, el mensaje de Supabase viene **en inglés** y la app está en español y chino (`t.auth.passwordWeak` existe pero solo se usa en la validación local).
- **MATI Admin:** no maneja `weak_password`. No elige contraseñas (la genera el servidor, y el correo la entrega), así que hoy no hace falta.
- **Qué hay que arreglar (fuera de este encargo, en el front/función):**
  1. En `complete-password-change`: si `updErr.code === 'weak_password'` devolver `{ error, codigo: 'contrasena_filtrada' }` con mensaje en español.
  2. En `AuthContext.changePassword`: al fallar la invocación, leer el cuerpo (`await invokeErr.context.json()`) y mostrar `t.auth.passwordWeak` / `t.auth.passwordLeaked` según el código.
  3. Agregar la prueba correspondiente.
  **Recomendación: hacer estos cambios y desplegarlos *antes* de activar la protección**; si no, un usuario con contraseña filtrada verá un mensaje confuso en vez de una explicación.

## 5. Si algo sale mal

Desactivar el interruptor (sección 2) y avisar; no hay efecto sobre los datos.

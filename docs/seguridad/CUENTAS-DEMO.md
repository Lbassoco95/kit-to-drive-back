# Cuentas demo `@dazon.demo` (Fase 2) — 26 oct 2026

Solo lectura y propuesta: **no se cambió nada en producción, no se inició sesión en ninguna cuenta y no se probó ninguna contraseña.**
Los valores de contraseña no aparecen en este documento ni en el repositorio.

## 0. Decisiones de Polo (26 oct 2026) y estado de cada cuenta

| Cuenta | Decisión | Qué queda listo (sin aplicar) |
|---|---|---|
| `edgar` | **Es un exempleado: se bloquea en Auth** (opción B), reversible y sin borrar datos | `supabase/operaciones/fase2-bloquear-edgar.sql` + reversa. Frase: «Autorizo bloquear la cuenta de Edgar (exempleado), ventana del `<fecha>`» |
| `marco` | **Persona real de ventas: queda como está** (opción A) | Nada. Sale de la migración de correo |
| `lee` | **Persona real de ventas: se queda; se prepara su migración a correo real** (opción A), no el bloqueo | `supabase/operaciones/fase2-migrar-correo-real-lee.sql` + reversa. Falta el correo real. Frase: «Autorizo migrar a correo real a lee, correo: `<correo>`, ventana del `<fecha>`» |
| `test-scan@test.com` (perfil activo sin área ni nivel) | **Pendiente de confirmar** que no es una persona | `supabase/operaciones/fase2-bloquear-test-scan.sql` + reversa, **solo si Polo lo confirma**. Frase: «Autorizo bloquear la cuenta test-scan, ventana del `<fecha>`» |
| `finanzas` | **Pendiente de confirmar** quién es | Nada todavía (opciones en el reporte del 26 oct: dejar, forzar cambio de contraseña, bloquear) |
| Carmen Ruvalcaba y JC Aguilar (`@yoltik.mx`, administradores de Dirección, nunca han entrado) | **Son del equipo de Yoltik y administradores legítimos.** Deben entrar esta semana y cambiar su contraseña; **si no lo hacen antes del sábado 31, se prepara su bloqueo temporal** | Al abrir la ventana de la Fase 2 se mira por lectura si ya entraron; el script de bloqueo temporal se prepara solo si hace falta |
| Polo Bassoco | Administrador global legítimo, **no super admin** | Efecto en el Paquete 3 y en `asignar_super_admin`: ver `SUPER-ADMINS-Y-ADMIN-DIRECCION.md` §3 |

Los cinco scripts del paso 1 (`admin`, `coordinador`, `fabrica`, `logistica`, `ventas`) y el de cambio obligatorio de contraseña siguen como se describen abajo, cada uno con su frase. Ensayo de los nuevos: `docs/seguridad/ensayo/ensayar-operaciones-cuentas.py` (resultado en `resultado-operaciones-cuentas.json`).

## 1. Qué hay hoy (verificado el 26 oct 2026, solo lectura)

| Cuenta | Perfil activo | Último acceso | Debe cambiar contraseña | Sesiones / renovaciones vigentes | Área y nivel | Propuesta | Decide Polo |
|---|---|---|---|---|---|---|---|
| `admin` | No | 22 sep | Sí | **3 / 3** | **Dirección / admin (administrador global)** | Bloquear en Auth (bloque 1) | No: ya lo pidió |
| `coordinador` | No | nunca | Sí | 0 / 0 | Comercial / supervisor | Bloquear en Auth (bloque 1) | No |
| `fabrica` | No | 17 jul | Sí | 0 / 0 | Fábrica / operador | Bloquear en Auth (bloque 1) | No |
| `logistica` | No | 15 jul | Sí | 0 / 0 | Almacén y logística / operador | Bloquear en Auth (bloque 1) | No |
| `ventas` | No | 17 jul | Sí | 0 / 0 | Comercial / operador | Bloquear en Auth (bloque 1) | No |
| `edgar` | No | 24 ago | Sí | 0 / 0 | Fábrica / operador | Bloquear en Auth **solo si Polo confirma que no es una persona** (bloque 2) | **Sí** |
| `finanzas` | **Sí** | 25 sep | No | 1 / 1 | **Administración / admin (admin de área)** | Nada hasta que Polo diga quién es | **Sí** |
| `lee` | **Sí** | 13 jul | Sí | 0 / 0 | **Comercial / admin (admin de área)** | Nada hasta que Polo diga quién es | **Sí** |
| `marco` | **Sí** | 13 oct | No | 2 / 2 | Comercial / supervisor | Nada hasta que Polo diga quién es | **Sí** |

Ninguna cuenta está bloqueada en Auth hoy (`banned_until` vacío en las nueve).
Los datos coinciden con la tabla que Polo verificó.

**Tres cosas que importan más que el resto:**
1. `admin@dazon.demo` es **administrador global** y tiene **3 sesiones con renovación vigente**. Su perfil inactivo ya le quita casi todo el poder (las reglas de la base exigen perfil activo), pero el inicio de sesión sigue abierto.
2. `finanzas@dazon.demo` es **administrador de Administración**, está **activa** y entró el 25 sep, el mismo día en que se quitó la contraseña fija del código. Si alguna persona real la usa, es la cuenta demo más delicada.
3. `lee@dazon.demo` es **administrador de Comercial** y está activa, sin haber cambiado nunca su contraseña inicial.

## 2. Las cuentas con contraseña fija en el historial (hallazgo O6)

**Cuáles:** las 4 de la función `seed-demo-users`: **`admin`, `fabrica`, `logistica` y `ventas`**.
**No son cuatro contraseñas, es una sola, compartida por las cuatro** (10 caracteres, con mayúsculas, minúsculas, número y símbolo).

**Dónde estuvo (solo repositorio `kit-to-drive`, front; 8 commits, del 3 may al 25 sep 2026):**

| Archivo | Qué mostraba |
|---|---|
| `src/pages/Auth.tsx` | La **pantalla de inicio de sesión** traía botones de acceso rápido con el correo y la contraseña de estas cuentas, y un texto «Contraseña demo: …» visible. Eso viajaba en el código que descarga el navegador. |
| `supabase/functions/seed-demo-users/index.ts` | La lista de cuentas con la contraseña. Hasta el 10 oct la función tuvo la contraseña fija; hoy no. |
| `usuarios_demo.sql` | Un comentario con «Contraseña para todos: …». |

Versiones anteriores de la pantalla también listaron `finanzas@dazon.demo` y `gerente@dazon.demo` con esa misma contraseña (`gerente` ya no existe en Auth). Por eso **`finanzas` entra en la duda** aunque no esté en la función.

**Reutilización:** el valor **no está en el código actual de ninguno de los cuatro repos** (`kit-to-drive`, `kit-to-drive-back`, `kit-to-drive-front`, `mati-app`) ni en sus ramas actuales: se buscó en el contenido vigente y en todo el historial. Solo vive en el historial del front.

**Si sigue vigente: no se puede saber sin iniciar sesión, y no se hizo.** Lo que sí se sabe: las cuatro cuentas conservan «debe cambiar contraseña = sí», es decir, **nadie les cambió la contraseña**. Lo más probable es que siga siendo la del historial. **Hay que tratarla como pública.**

## 3. Qué se propone (nada se aplicó)

| Paso | Script | Qué hace | Reversa | Frase de Polo |
|---|---|---|---|---|
| 1 | `supabase/operaciones/fase2-desactivar-cuentas-demo-inactivas.sql`, bloque 1 | Bloquea el inicio de sesión (Auth, `banned_until`) de `admin`, `coordinador`, `fabrica`, `logistica`, `ventas`. No borra usuarios, perfiles, roles ni historial. | `…_reversa.sql` (`banned_until = NULL`) | «Autorizo desactivar cuentas demo inactivas, ventana del <fecha>» |
| 2 | `fase2-bloquear-edgar.sql` | Lo mismo para `edgar` (exempleado confirmado por Polo). Script propio, con guardas propias. | `fase2-bloquear-edgar_reversa.sql` | «Autorizo bloquear la cuenta de Edgar (exempleado), ventana del `<fecha>`» |
| 3 | `…forzar-cambio-password-demo-activas.sql` | `finanzas`, `lee` y `marco`: marca «debe cambiar contraseña» en el siguiente inicio de sesión. No cambia contraseñas ni cierra sesiones. | `…_reversa.sql` (restaura las marcas del 26 oct) | Frase aparte, con las cuentas nombradas |

Los scripts tienen **guardas**: abortan sin cambiar nada si falta o sobra una cuenta, si alguna cuenta del paso 1 tiene el perfil activo, o si alguna ya está bloqueada. Se ensayaron en una copia local con datos inventados: guarda, aplicación, segunda aplicación (aborta), reversa y verificación.

**Qué no hace el paso 3 (límite):** obliga a cambiar la contraseña, **no la invalida**. Quien conozca la contraseña antigua podría entrar antes de que la persona la cambie. Si Polo quiere invalidarla ya, debe usar «Restablecer contraseña» en Usuarios; llega por correo, así que el correo `@dazon.demo` debe existir.

**Qué hace el bloqueo con las sesiones:** Auth rechaza renovar la sesión de una cuenta bloqueada; el token de acceso ya emitido sigue valiendo hasta que expire (la duración depende de la configuración de Auth: **no verificada**). No se borran las sesiones.

## 4. Flujo propuesto para cuentas demo nuevas (ya escrito, en el PR)

`seed-demo-users` sigue apagada en producción (responde 410). Si algún día se enciende en un laboratorio:
- **Contraseña aleatoria, distinta por cuenta, de un solo uso**: 14 caracteres generados en el servidor.
- Viaja **solo por correo**; no se acepta del cuerpo de la petición, no se devuelve y no se registra.
- La persona debe cambiarla al entrar (`must_change_password`).
- **Una cuenta que ya existe no se toca** (antes se le borraba el rol y se le reescribía el perfil).
- La pantalla de inicio de sesión ya no trae accesos rápidos.

## 5. Limpiar el historial de git: no se hace; riesgos y alternativas

| Opción | Qué implica | Riesgo |
|---|---|---|
| **A. Dejar el historial, tratar la contraseña como pública y bloquearla (recomendada)** | Pasos 1–3 de arriba. | Ninguno nuevo: la contraseña deja de servir. |
| B. Reescribir el historial (`git filter-repo` y `push --force`) | Cambia todos los identificadores de commits del front. | Rompe los clones, ramas y PR abiertos (83 ramas); obliga a reconfigurar Vercel. **No elimina la exposición**: la contraseña ya se publicó en el código descargable del navegador, y puede seguir en forks, clones y en las referencias de PR de GitHub. |
| C. Escáner de secretos de GitHub | Activar «secret scanning» y «push protection». | Detecta formas conocidas; no cubre contraseñas literales. Es complemento, no sustituto. |

**Recomendación:** A + C. B solo si Polo lo decide por razones distintas a la seguridad de esta cuenta.

## 6. Qué decide Polo

1. ¿Quiénes son `finanzas`, `lee` y `marco`? ¿Personas reales o cuentas de prueba?
2. ¿`edgar` es una persona? Si no, se bloquea (bloque 2).
3. Si `finanzas` o `lee` son personas, ¿se les restablece la contraseña ya (correo real)?
4. ¿Se activa el escáner de secretos de GitHub (opción C)?

## 7. No verificado

- Si la contraseña del historial sigue vigente (exige iniciar sesión).
- La duración del token de acceso y de la sesión (configuración de Auth).
- Si el correo `@dazon.demo` recibe mensajes (afecta el restablecimiento).

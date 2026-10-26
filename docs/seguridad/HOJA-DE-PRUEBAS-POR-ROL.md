# Hoja de pruebas por rol — para la persona de pruebas

**No necesitas saber de programación.** Esta hoja te dice qué hacer en la aplicación, qué debe pasar y dónde anotar. Se usa **antes** y **después** de cada paso de la ventana. Polo te avisa cuándo toca.

## 0. Reglas

1. **Usa solo cuentas de prueba** o las que Polo te indique. **No cambies ni borres datos reales de clientes.** Cuando haya que crear algo (una remisión, un ajuste), es **de prueba**, con un nombre que diga «PRUEBA», y se cancela o se deshace al terminar.
2. **No escribas ni compartas contraseñas** por chat. Si una cuenta no te deja entrar, avisa a Polo.
3. **Anota todo** en la hoja de registro (sección 3), aunque salga bien. Escribe la **hora**.
4. **Si algo no sale como dice «Debe pasar», NO sigas: avisa de inmediato a Polo** (y toma una captura de pantalla). **No intentes arreglarlo.** Polo decide si se revierte el paso.
5. Es normal que a veces tarde unos segundos. Si algo tarda **más de 1 minuto**, anótalo.
6. Cada paso se prueba **dos veces**: **Antes** (antes de que Polo aplique el cambio) y **Después**. Lo que sale bien Antes debe salir igual Después.

## 1. Cuentas que necesitas (las asigna Polo; sin contraseñas aquí)

| Rol | Para qué | Cuenta (la anota Polo) |
|---|---|---|
| Vendedor (dueño de un cliente) | Crear y ver remisiones | |
| Otro vendedor | Comprobar que NO ve clientes ajenos | |
| Administrativo de Comercial | Ver todas las remisiones | |
| Administrador de Comercial (de área) | Editar usuarios de su área | |
| Administrador de otra área (p. ej. Administración) | Comprobar que NO edita Comercial | |
| Finanzas | Cobranza y movimientos | |
| Compras | Cobranza (solo lectura) | |
| Almacén | Ajustar un artículo de prueba | |
| Logística | Ver entregas | |
| Operador (Fábrica) | Ver su menú | |
| Administrador global | Ver todo | |
| Super admin | Ver todo, aprobar | |
| Usuario con «debe cambiar contraseña» | Recorrido 2 | |

## 2. Los recorridos

Marca en la sección 3. «Quién»: **P** = la persona de pruebas; **A** = un administrador (Polo u otra persona con acceso a Usuarios o a MATI Admin).

### Recorridos de la Fase 1

| # | Quién | Qué hacer | Debe pasar | Si no pasa |
|---|---|---|---|---|
| **1** | P | Entra a la aplicación **con cada cuenta de la sección 1** (una por una) usando su contraseña normal. Mira el menú de la izquierda. | Entra sin error y ve el menú que le corresponde a su rol (un vendedor no ve Finanzas, por ejemplo). Es el mismo menú que **Antes**. | Avisa. Anota qué cuenta y qué mensaje salió. |
| **2** | P | Con el usuario que «debe cambiar contraseña»: entra con la contraseña temporal. | Te **obliga** a elegir una contraseña nueva. La eliges, te devuelve a la pantalla de entrada con un aviso verde, y entras con la nueva. | Avisa. |
| **3** | A | Desde **Usuarios** (o MATI Admin): da de alta a un usuario **de prueba** con un correo tuyo. | Se crea. **Llega un correo** con una contraseña temporal. Entras, te pide cambiarla. (La contraseña **nunca** se ve en pantalla.) | Avisa. **Este recorrido es obligatorio tras los pasos 1 y 2.** |
| **4** | A | Desactiva a ese usuario de prueba. | Ya no puede entrar. | Avisa. |
| **5** | A | Alta con permiso vs. sin permiso (lo prepara Polo con Claude; la persona de pruebas solo confirma que el alta **autorizada** del recorrido 3 funcionó). | Ver recorrido 3. | — |
| **6** | P (vendedor) y A | Como **vendedor**: crea una **remisión de prueba** (cliente tuyo). Como administrador: ábrela y edítala. | Se crea con **folio**, se ve, se edita y aparece en su historial. | Avisa. |
| **7** | P (finanzas o compras) | Abre **Cobranza**. | Carga la lista, sin mensaje de error. | Avisa. |
| **8** | P (almacén) | Ajusta **un artículo de prueba** (sube o baja 1). Pide a otra persona que mire la campanita de notificaciones. | El ajuste se guarda; la campanita lo muestra **en menos de 20 segundos**. | Avisa si pasa de 20 s. |
| **9** | P (finanzas) | Crea un **movimiento de prueba** y abre su historial. | Se crea y aparece en el historial. | Avisa. |
| **10** | P | Abre un **ticket de soporte**; un administrador lo responde desde MATI Admin. | Se abre, se responde, ves la respuesta. | Avisa. |
| **11** | P | Con cada rol de la sección 1: intenta **una cosa permitida** (ver su pantalla principal) y **una prohibida** (abrir una pantalla de otra área, por ejemplo Finanzas con una cuenta de Fábrica). | Lo permitido funciona; lo prohibido **no te deja** (mensaje de «sin permiso» o no aparece). Igual que **Antes**. | Avisa. |
| **12** | **Polo con Claude** | Pruebas técnicas sin sesión (que no se pueda escribir ni leer sin entrar). | Lo confirma Claude. | — |

**Qué recorridos se hacen después de cada paso de la Fase 1** (los demás, solo en el paso final):

| Después del paso | Obligatorios |
|---|---|
| 1 (TRUNCATE) | 1, 2, 3, 5, 6 |
| 2 (funciones de trigger) | **1, 2, 3, 5, 6** (incluye el alta de usuario) |
| 3 (vistas de `anon`) | 1, 6, 7 |
| 4 (escritura de `anon`) | 1, 6, 8 |
| 5 (permisos por defecto) | 1, 6 |
| 6 (`search_path`, el último) | **Todos del 1 al 11** |

### Recorridos de la Fase 2 (otra ventana)

| # | Quién | Qué hacer | Debe pasar |
|---|---|---|---|
| **U1** | A (administrador global) | Abre **Usuarios**, edita el nombre y el tipo de usuario de **un usuario de prueba** y guarda. | Se guarda («actualizado»). |
| **U2** | A (administrador global) | Activa y desactiva a ese usuario de prueba. | Se guarda. |
| **U3** | A (admin de Comercial) | Edita a un **vendedor de su área**: cambia su nombre y marca «administrativo». | Se guarda. |
| **U4** | A (admin de Comercial) | Intenta pasarlo a **Dirección / admin** o a **otra área**. | **Lo rechaza** con un mensaje; el usuario no cambia. |
| **U5** | A (admin de Comercial) | Intenta editar a un usuario de **otra área**. | **Lo rechaza.** |
| **U6** | A (admin de Comercial) | Intenta **crear un usuario de nivel admin**. | **Lo rechaza** («solo un administrador global»). |
| **U7** | A (administrador global que **no** es super admin) | Intenta editar, desactivar o restablecer la contraseña de un **super admin**. | **Lo rechaza.** |
| **U8** | A (super admin) | Edita **al otro** super admin (solo un cambio de nombre de prueba que se deshace). | Se guarda. |
| **U9** | P | Cualquier usuario abre su perfil y cambia **su nombre**. | Se guarda. |
| **U10** | A (administrador global) | Da de alta a un usuario de prueba. | Se crea y llega el correo. |
| **U11** | A (admin de área) | «Restablecer contraseña» a un usuario **de su área**. | Llega el correo al usuario. |
| **U12** | P (vendedor dueño) | Intenta crear una remisión a un **cliente con cartera vencida**. | **La aplicación la bloquea** y explica la cartera (como hoy). |
| **U13** | P (vendedor) | Crea una remisión a un cliente **sin** cartera vencida. | Se crea. |
| **U14** | Claude | Comprueba que cada edición dejó su renglón en el rastro. | Lo confirma Claude. |

## 3. Hoja de registro (imprímela; una por fase)

Marca **OK** o **FALLA**, la **hora** y una nota corta. **Antes** = antes del cambio; **Después** = tras cada paso.

| # | Antes | Paso 1 | Paso 2 | Paso 3 | Paso 4 | Paso 5 | Paso 6 | Nota (qué cuenta, qué mensaje) |
|---|---|---|---|---|---|---|---|---|
| 1 Entrar con cada rol | | | | | | | | |
| 2 Contraseña temporal | | | | | | | | |
| 3 Alta de usuario | | | | | | | | |
| 4 Baja de usuario | | | | | | | | |
| 6 Remisión de prueba | | | | | | | | |
| 7 Cobranza | | | | | | | | |
| 8 Ajuste y campanita | | | | | | | | |
| 9 Movimiento financiero | | | | | | | | |
| 10 Ticket de soporte | | | | | | | | |
| 11 Permitido / prohibido | | | | | | | | |

Hora de inicio: ________  Hora de fin: ________  Persona de pruebas: ________________  ¿Se avisó a Polo de algún FALLA? ☐ Sí ☐ No

**Al terminar:** entrégale esta hoja a Polo (foto o papel). Claude la usa para el reporte de la ventana.

# Matriz acción × rol: lo que el front espera contra lo que la base permite

*26 oct 2026, 18:30 CDMX. Hecho solo en una réplica local con usuarios y filas sintéticos. **No se tocó producción** (sobre producción solo hubo lecturas de catálogo y conteos agregados). No se inició sesión en ninguna cuenta ni se usó ninguna contraseña.*

## 1. En corto

1. **La compuerta no tiene lógica de permisos por rol: es correcto que no la tenga, y no es el lugar para ponerla.** Solo decide *qué tablas, funciones y buckets* se pueden nombrar y que haya un token con rol `authenticated` (`kit-to-drive-front/src/policy.ts`, `src/app.ts`). Con el token de **cualquier** empleado pasa cualquier llamada de la lista, y quien decide después es la base. Además, la URL de Supabase y la llave pública son públicas: un cliente puede saltarse la compuerta y hablar directo con Supabase usando su propio token. Una regla puesta solo en la compuerta o solo en el front se esquiva; **la regla tiene que vivir en la base**.
2. **«Con otro token lograron acceder a algo»: no me llegó el detalle** (qué token, qué llamada, qué vieron). Lo que sí está medido es que **hoy, con el token de cualquier vendedor, la base permite cosas que el front no ofrece** (sección 4). Pido el detalle en la sección 7 para ver si coincide con alguna.
3. **Dos huecos reales y activos hoy en producción, que la Fase 2 (aún sin aplicar) ya cierra:** (a) cualquier usuario con sesión puede marcarse a sí mismo «administrativo» y con eso leer todos los clientes y remisiones y reasignar vendedor de remisiones; (b) cualquier admin de *cualquier* área puede editar nombre, correo y código de vendedor de *cualquier* perfil, incluido el del super admin. **Se miden aquí con la Fase 2 puesta y quedan cerrados** (sección 4, filas `usr04`–`usr13`).
4. **Lo que sigue abierto aunque se aplique todo lo planeado** (Fase 1, Paquetes 1-3, Fase 2): cancelar una remisión suya por API siendo vendedor, editar/perdonar cuentas por cobrar con rol de operador de Administración, leer ficha de cliente y cartera desde Almacén, Compras o Fábrica, escribir en Dirección sin mando, y **cinco políticas de escritura que solo piden «ser yo»** (sección 5).
5. **Reglas que viven solo en el front: 9** (sección 4), cada una con opciones A/B. Solo **4** tienen hoy usuarios reales detrás; las demás son estructurales (el rol no tiene personas hoy).
6. **Propuesta de cierre de las cinco escrituras abiertas y las tres lecturas abiertas (opción A), probada en la réplica** con su reversa idéntica por huella: `propuestas/escrituras-y-lecturas-abiertas-opcion-A.sql`. **No es una migración y no se aplicó.**

## 2. Qué se midió y cómo

- **Réplica `m_matriz`** = réplica de producción del 25 oct (políticas y permisos tomados del respaldo) + las migraciones M1 y M2 de la Fase 1, que son las que están aplicadas en producción. Se comparó el catálogo de políticas con el de producción de hoy: **88 de 89 tablas con políticas idénticas**; la diferencia es solo de formato de texto en `almacen_refacciones_acceso` (misma lógica, distinto deparse entre PostgreSQL 16 y 17) y una política nueva de `storage.objects` (`firmas_storage_select_firmas`) que se agregó a la réplica.
- **Réplica «después»** = copia de la réplica de ensayo con la Fase 1 completa (M1–M6), Paquete 1, Fase 2, Paquete 2 y Paquete 3 ya aplicados. No incluye la migración de `asignar_super_admin` opción B.
- **22 roles sintéticos**: las 18 combinaciones área × nivel, más «administrativo de Comercial», **super admin**, **usuario inactivo** y **usuario sin rol**. Cada rol corre **76 acciones** (1,672 celdas por corrida) dentro de una subtransacción que se deshace, simulando `SET LOCAL ROLE authenticated` con las claims del usuario. Cada corrida termina en `ROLLBACK`.
- **Lo esperado** sale del propio código del front: se volcó `permisosDe()` de `src/lib/permissions.ts` (evaluado, no copiado a mano) a `ensayo/permisos-front-permisosDe.json`, más la regla «el operador solo trabaja con lo suyo» para Comercial.
- **Anónimo** también se corrió (rechaza las 76 acciones).
- **Controles positivos** (`abp01`–`abp03`): lo legítimo que el front hace sobre lo propio debe seguir pasando, para no dar por bueno un cierre que rompe el trabajo normal.

**Cómo leer las tablas de la sección 4.** Una letra por rol, en el orden `SA DA DS DO CA CS CV CD AA AS AO FA FS FO LA LS LO PA PS PO IN SR`.
`P` = la base lo permite y el front también · `.` = la base lo rechaza y el front también · **`!` = la base lo PERMITE y el front NO** (regla solo en el front) · `u` = el front lo ofrece y la base lo rechaza (botón que falla; no es hueco de seguridad).
Códigos: SA super admin · DA/DS/DO Dirección admin/supervisor/operador · CA/CS/CV Comercial admin/supervisor/vendedor · CD vendedor con marca «administrativo» · AA/AS/AO Administración · FA/FS/FO Fábrica · LA/LS/LO Almacén y logística · PA/PS/PO Compras · IN usuario inactivo · SR usuario sin rol.

**Límites.** Es el nivel de base de datos (RLS, permisos, triggers, funciones). No cubre pantallas ni Edge Functions (usan llave de servicio y aplican su regla en código). Las funciones de la réplica son las del respaldo del 25 oct. No se probó `eliminar_remision` (Paquete 3) porque cambia el borrado a función; en «después» el `DELETE` directo ya no existe y esas filas salen `u`. Hay roles sin personas hoy en producción; ahí el hueco es estructural. Resultados completos: `ensayo/resultado-matriz-hoy.json`, `ensayo/resultado-matriz-despues-de-lo-planeado.json`, `ensayo/resultado-matriz-hoy-con-opcion-A.json`. Reproducir: `ensayo/matriz-accion-por-rol.py <base>` y `ensayo/render-matriz.py`.

**Quién hay hoy en producción** (solo conteos por área y nivel, leídos por el conector de lectura): Comercial 9 operadores (8 activos), 4 supervisores (3 activos), 1 admin; Fábrica 2 operadores (0 activos) y 1 admin; Almacén 1 operador (inactivo); Administración 1 admin; Dirección 6 admin (5 activos). **No hay nadie** en Compras, Dirección operador/supervisor, Administración operador/supervisor, ni Almacén o Fábrica supervisor/admin (salvo el admin de Fábrica). Hay **6 cuentas inactivas** y **1 cuenta activa sin rol** (26 perfiles, 25 roles).

## 3. Resultado global

| | Hoy | Después de lo planeado |
|---|---|---|
| Celdas donde el front y la base coinciden | 1,355 | 1,377 |
| **La base permite y el front no (`!`)** | **222** | **165** |
| El front ofrece y la base rechaza (`u`) | 95 | 130 |

La Fase 2 y los Paquetes quitan 57 celdas de hueco; **quedan 165**, que son las reglas de la sección 4. El aumento de `u` viene sobre todo de Paquete 3 (borrado por función) y de Paquete 1 (vendedor ya no captura a clientes que no ve).

## 4. Matriz por dominio y reglas que viven solo en el front

Columnas (en este orden): SA DA DS DO CA CS CV CD AA AS AO FA FS FO LA LS LO PA PS PO IN SR

### Escrituras abiertas

```
id    HOY                    DESPUÉS                 acción
abi01 PP!!PP!!PP!PP!!!!!!!!! PP!!PP!!PP!PP!!!!!!!!!  Anotar en la bitácora de un cliente que no ve (clientes_bitacora)
abi02 PPPPPP!!PPPPPP!!!!!!!! PPPPPP!!PPPPPP!!!!!!!!  Comentar en la ficha de un cliente que no ve (clientes_comentarios)
abi03 PP!!PP!!PP!PP!PP!PP!!! PP!!PP!!PP!PP!PP!PP!!!  Anotar en la bitácora de una remisión ajena (remisiones_bitacora)
abi04 !!!!!!!!!!!!!!!!!!!!!! !!!!!!!!!!!!!!!!!!!!!!  Mandar un aviso a Dirección (avisos; el front nunca inserta en avisos)
abi05 PPPPPPPPPPPPPPPPPPPP!! PPPPPPPPPPPPPPPPPPPP!!  Mandar una notificación a otra persona (notificaciones)
abi06 PP..PP..uu............ PP..PP..uu............  Agregar una parada a la ruta de otro vendedor (crm_ruta_paradas)
```

### Controles positivos

```
id    HOY                    DESPUÉS                 acción
abp01 PP!!PPPPPPPPPP!!!!!!!! PP!!PPPPPPPPPP!!!!!!!!  Anotar en la bitácora de un cliente suyo
abp02 PP!!PPPPPPPPPP!!!!!!!! PP!!PPPPPPPPPP!!!!!!!!  Comentar en la ficha de un cliente suyo
abp03 PP!!PPPPPPPPPPPPPPP!!! PP!!PPPPPPPPPPPPPPP!!!  Anotar en la bitácora de una remisión suya
```

### Aprobaciones

```
id    HOY                    DESPUÉS                 acción
apr01 PP..P...P..P..P..P.... PP..P...P..P..P..P....  Leer una solicitud de su área
apr02 PP.................... PP....................  Leer una solicitud de OTRA área
apr03 ...................... ......................  Crear una solicitud (INSERT directo)
apr04 ...................... ......................  Marcar una solicitud como aprobada (UPDATE directo)
apr05 ...................... ......................  Borrar una solicitud (DELETE directo)
apr06 P..................... P.....................  Pedir una aprobación por la función solicitar_aprobacion
apr07 PP..P...P..P..P..P.... PP..P...P..P..P..P....  Resolver (rechazar) una solicitud de su área
apr08 PP.................... PP....................  Resolver (rechazar) una solicitud de OTRA área
apr09 PP.................... PP....................  Eliminar una solicitud por la función eliminar_solicitud_aprobacion
```

### Clientes

```
id    HOY                    DESPUÉS                 acción
cli01 PPPPPPPPPPPPPP!!!!!!.. PPPPPPPPPPPPPP!!!!!!..  Leer un cliente suyo
cli02 PPPPPP.!PPPPPP!!!!!!.. PPPPPP.!PPPPPP!!!!!!..  Leer el cliente de otro vendedor
cli03 PP!!PPPPPPPPPP........ PP!!PPPPPPPPPP........  Crear un cliente a su nombre
cli04 PP!!PP!!PP!PP!........ PP!!PP!!PP!PP!........  Crear un cliente a nombre de otro vendedor
cli05 PP..PPPPPPuuuu........ PP..PPPPPPuuuu........  Editar un cliente suyo
cli06 PP..PP..PP.uu......... PP..PP..PP.uu.........  Editar el cliente de otro vendedor
cli07 PP..PP!!PP............ PP..PP!!PP............  Cambiar el límite de crédito de un cliente suyo
cli08 PP..PP..PP.uu......... PP..PP..PP.uu.........  Pasar un cliente suyo a otro vendedor
cli09 PP..P...P..u.......... PP..P...P..u..........  Borrar un cliente suyo
cli10 PP..P...P..u.......... PP..P...P..u..........  Borrar el cliente de otro vendedor
```

### Cuentas por cobrar

```
id    HOY                    DESPUÉS                 acción
cxc01 PPPPPPPPPPP!!!!!!!!!.. PPPPPPPPPPP!!!!!!!!!..  Leer una cuenta por cobrar de un cliente suyo
cxc02 PPPPPP.!PPP!!!!!!!!!.. PPPPPP.!PPP!!!!!!!!!..  Leer la cuenta por cobrar de un cliente ajeno
cxc03 PP..uu..PP!........... PP..uu..PP!...........  Crear una cuenta por cobrar
cxc04 PP..uu..PP!........... PP..uu..PP!...........  Editar (perdonar saldo de) una cuenta por cobrar
cxc05 PP..u...P!............ PP..u...P!............  Borrar una cuenta por cobrar
cxc06 PP..uu..PP!........... PP..uu..PP!...........  Registrar un abono
cxc07 PP..u...P!............ PP..u...P!............  Borrar un abono
cxc08 uuuuuuuuuuu........... uuuuuuuuuuu...........  Leer la vista de crédito de clientes
```

### Lecturas abiertas

```
id    HOY                    DESPUÉS                 acción
lec01 PPPPPPPPPPPPPPPPPPPP!! PPPPPPPPPPPPPPPPPPPP!!  Leer inventario_motivos_ajuste (USING true)
lec02 PPPPPPPPPPPPPPPPPPPP!! PPPPPPPPPPPPPPPPPPPP!!  Leer inventario_reglas_modo_prueba (USING true)
lec03 PPPPPPPPPPPPPPPPPPPP!! PPPPPPPPPPPPPPPPPPPP!!  Leer inventario_unidades_venta (USING true)
```

### Remisiones

```
id    HOY                    DESPUÉS                 acción
rem01 PPPPPPPPPPPPPPPPPPP... PPPPPPPPPPPPPPPPPPP...  Leer una remisión suya
rem02 PPPPPP.!PPPPPPPPPPP... PPPPPP.!PPPPPPPPPPP...  Leer la remisión de otro vendedor
rem03 PP!!PPPPuuuuuuuuuPP... PP!!PPPPuuuuuuuuuPP...  Crear una remisión suya a un cliente suyo
rem04 PP!!PP!!uu.uu.uu.PP... PP!!PP.!uu.uu.uu.PP...  Crear una remisión a un cliente de otro vendedor  ◀ cambia
rem05 PP!!PP..uu.uu.uu.PP... PP!!PP..uu.uu.uu.PP...  Crear una remisión a nombre de otro vendedor
rem06 PP!!PPPPuuuuuuuuuPP... PP!!PPPPuuuuuuuuuPP...  Editar una remisión suya
rem07 PP!!PP..uu.uu.uu.PP... PP!!PP..uu.uu.uu.PP...  Editar la remisión de otro vendedor
rem08 PP!!PP.!uu.uu.uu.PP... PP!!PP.!uu.uu.uu.PP...  Cambiar el vendedor de una remisión suya (UPDATE directo)
rem09 PP!!PP!!uu.uu.uu.PP... PP!!PP!!uu.uu.uu.PP...  Cancelar una remisión suya (UPDATE directo a CANCELADA)
rem10 PP..P...u..u..u..u.... uu..u...u..u..u..u....  Borrar una remisión suya  ◀ cambia
rem11 PP..P...u..u..u..u.... uu..u...u..u..u..u....  Borrar la remisión de otro vendedor  ◀ cambia
rem12 PP..PP.!uu.uu.uu.uu... PP..PP.!uu.uu.uu.uu...  Asignar vendedor por la función asignar_vendedor_remision
```

### Usuarios y roles

```
id    HOY                    DESPUÉS                 acción
usr01 PPPPPPPPPPPPPPPPPPPP.! PPPPPPPPPPPPPPPPPPPP.!  Leer el perfil de otra persona
usr02 PP.................... PP....................  Leer los roles de otra persona
usr03 PP..P...!..P..P..P.... PP..P...!..P..P..P....  Editar el nombre de alguien de su área
usr04 PP..!...!..!..!..!.... PP....................  Editar el nombre de alguien de OTRA área  ◀ cambia
usr05 PP..!...!..!..!..!.... Pu....................  Editar el nombre del SUPER ADMIN  ◀ cambia
usr06 PP..P...!..P..P..P.... PP..P...!..P..P..P....  Desactivar a alguien de su área
usr07 PP.................... PP....................  Desactivar a alguien de OTRA área
usr08 PP..P...!..P..P..P.... PP..P...!..P..P..P....  Cambiar el correo (perfil) de alguien de su área
usr09 PP..!...!..!..!..!.... PP....................  Cambiar el correo (perfil) de alguien de OTRA área  ◀ cambia
usr10 PP..!...!..!..!..!.... PP....................  Cambiar el código de vendedor de otra persona  ◀ cambia
usr11 PP!!P!!!!!!P!!P!!P!!.! uu..u..!...u..u..u....  Marcarse a sí mismo «administrativo» (campo es_administrativo)  ◀ cambia
usr12 PP!!P!!!!!!P!!P!!P!!.! uu..u.!....u..u..u....  Marcarse a sí mismo «vendedor» (campo es_vendedor)  ◀ cambia
usr13 PPPPPP!!PPPPPP!!!!!!.. uuuuuu.!uuuuuu........  Autoascenso: marcarse «administrativo» y luego leer clientes ajenos  ◀ cambia
usr14 PP..P...!..P..P..P.... PP..P...!..P..P..P....  Dar rol a alguien sin rol, en su área
usr15 PP.................... PP....................  Dar rol a alguien sin rol, en OTRA área
usr16 PP.................... PP....................  Dar a alguien el rol de administrador global (Dirección/admin)
usr17 PP..P...!..P..P..P.... PP..u......u..u..u....  Subir de nivel a alguien de su área  ◀ cambia
usr18 PP.................... PP....................  Subir de nivel a alguien de OTRA área
usr19 PP.................... PP....................  Pasar a alguien de su área a Dirección/admin
usr20 PP..P...!..P..P..P.... PP..P...!..P..P..P....  Quitar el rol a alguien de su área
usr21 PP.................... PP....................  Quitar el rol a alguien de OTRA área
usr22 PP.................... PP....................  Subirse a sí mismo a Dirección/admin (para Dirección/admin no cambia nada)
usr23 ...................... ......................  Leer la tabla de super admins directamente
usr24 ...................... ......................  Insertarse como super admin (INSERT directo)
usr25 .P.................... .P....................  Asignar super admin por la función asignar_super_admin
```



### Reglas que viven solo en el front

La columna «Hoy hay» dice si existen usuarios reales en ese rol. **Recomendación** = lo que haría yo; la decisión es de Polo y de Dazon.

| # | Regla del front que la base no sostiene | Evidencia (matriz) | Hoy hay | Estado frente a lo planeado |
|---|---|---|---|---|
| **R1** | Solo un administrador cambia las marcas `es_administrativo` y `es_vendedor`. La base deja que **cada quien se las ponga a sí mismo**; con «administrativo» lee todos los clientes y remisiones y reasigna vendedor (`asignar_vendedor_remision`). | `usr11`, `usr12`, `usr13`, `rem12` | **Sí: 8 vendedores activos y todo usuario con sesión** | **Cerrado por la Fase 2, cambio 1** (sin aplicar). Fábrica/Almacén/Compras/Dirección sin marca hoy: no hay señal de uso (solo 2 marcados «administrativo», ambos de Comercial). |
| **R2** | Solo un admin de **su** área toca perfiles de **su** área. La base deja a **cualquier admin de cualquier área** editar nombre, correo y código de vendedor de **cualquier** perfil, incluido el super admin. | `usr04`, `usr05`, `usr09`, `usr10` | **Sí: 3 admins** (Comercial, Fábrica, Administración) | **Cerrado por la Fase 2, cambios 1 y 3.** El correo de perfil no se sincroniza a `auth.users` por trigger en la base, así que no es toma de cuenta por esta vía; sí es suplantación visible y cambia el código de vendedor. |
| **R3** | Cancelar una remisión es de admin (`puedeEliminar('remisiones')`, `Remisiones.tsx:1512,1733`). La base deja al **dueño de la remisión** (el vendedor) poner `CANCELADA` con un `UPDATE` directo, y soltar sus motocarros. | `rem09` | **Sí: los vendedores, dueños de sus remisiones** | Sigue abierto con todo lo planeado (el Paquete 3 solo cambia el *borrado*). |
| **R4** | Editar o perdonar saldo de una cuenta por cobrar es de supervisor o admin (`puedeEditar('credito')`). La base deja a **operadores de Administración** crearla, editarla y registrar abonos, y a **supervisores de Administración** borrar cuentas y abonos (el mapeo heredado les da el rol `admin_financiero`). | `cxc03`–`cxc07` | Solo el admin de Administración hoy | Sigue abierto. |
| **R5** | Ficha completa de cliente (RFC, crédito, documentos) y cartera son de Comercial, Fábrica y Administración. La base deja leerlas a **Almacén, Compras** y, para cartera, **Fábrica**. | `cli01`, `cli02`, `cxc01`, `cxc02` | Almacén 1 operador (inactivo); Fábrica 3 (1 activo) | Sigue abierto. |
| **R6** | Dirección sin mando (operador, supervisor) es solo lectura. La base les deja crear clientes y remisiones y editar remisiones (el mapeo heredado les da el rol `coordinador`). | `cli03`, `rem03`, `rem06` | No | Sigue abierto. Sin personas hoy. |
| **R7** | «Usuarios» no existe para Administración. La base deja al admin de Administración editar nombres y correos, desactivar y **crear, subir o quitar roles** de su área. | `usr03`, `usr06`, `usr08`, `usr14`, `usr17`, `usr20` | **Sí: 1 admin** | Parcial: la Fase 2 cierra `usr17` (subir de nivel); siguen `usr03`, `usr06`, `usr08`, `usr14` y `usr20`. |
| **R8** | **Límite de crédito.** No es regla solo del front: la pestaña «Crédito» de la ficha se muestra a quien edita el cliente (`Clientes.tsx:656-662`, sin permiso aparte) y la base lo deja. Un vendedor sube el límite de **sus** clientes. | `cli07` | **Sí: 8 vendedores** | Sigue abierto. Es la decisión de crédito D-C1 que está con Martin. |
| **R9** | Un vendedor crea clientes solo a su nombre y remisiones solo para clientes que ve. La base deja crear clientes a nombre de **otro vendedor**; las remisiones a clientes ajenos las cierra el Paquete 1 para el vendedor (no para «administrativo», por diseño). | `cli04`, `rem04` | **Sí** | `rem04` cerrado; `cli04` sigue. |

**Opciones A/B por regla** (A = pasar la regla a la base; B = dejarla como está y documentarla o corregir el front):

- **R1.** **A (recomendada):** aplicar **solo el cambio 1 de la Fase 2** (trigger de perfiles) antes del sábado, dentro de la ventana del jueves con el Paquete 1 o en una propia. Riesgo: ya probado en la réplica con reversa idéntica. **B:** esperar al sábado; mientras tanto el hueco sigue abierto 4 días más. *Es el hueco con más personas expuestas hoy.*
- **R2.** **A (recomendada):** igual que R1, el cambio 3 viaja con el 1. **B:** solo el cambio 1 (cierra el daño) y dejar la política para después.
- **R3.** **A (recomendada):** trigger `BEFORE UPDATE OF estatus` en `remisiones` que solo deja pasar a `CANCELADA` a admin de área, Dirección admin o super admin, y que ejecute la liberación de motocarros dentro de la misma regla. **B:** una función `cancelar_remision` (patrón de `eliminar_remision` del Paquete 3) y quitar el `UPDATE` directo de `estatus`; es más limpio y exige cambio de front.
- **R4.** **A:** alinear las políticas al nivel real (operador crea, supervisor edita, admin borra) usando área y nivel y no el rol heredado. **B (recomendada hasta que Dazon confirme quién puede perdonar saldo):** dejar la base como está y **bajar el front** a lo que la base permite; la decisión es de negocio, no técnica.
- **R5.** **A:** limitar la lectura completa de `clientes` a las áreas del módulo del front, y dar a Almacén y Compras solo el catálogo básico (`catalogo_clientes_basico`, Paquete 1). Antes hay que confirmar con Compras (supervisa remisiones) y Almacén qué necesitan leer. **B (recomendada hoy):** dejarlo; no hay usuarios activos en esos roles, y rehacerlo cuando se den de alta.
- **R6.** **A:** quitar a `coordinador` las políticas de escritura de `clientes` y `remisiones`. **B (recomendada):** dejarlo; no hay personas. Documentarlo antes de dar de alta a alguien de Dirección sin mando.
- **R7.** **A:** quitar la rama `admin_financiero` de `gestionar_roles` y que Dirección administre a Administración. **B:** habilitar «Usuarios» para Administración en el front limitado a su área. **Decide Polo**: hoy es 1 persona y la inconsistencia es solo que la base la deja y la pantalla no.
- **R8.** **A:** trigger que solo deje cambiar `limite_credito`, `dias_credito` y `moneda_credito` a Administración y Dirección. **B (la que ya está pendiente con Martin):** dejar que Comercial lo capture. Hasta que Martin responda D-C1 no recomiendo moverlo.
- **R9.** **A:** trigger que fuerza `vendedor_id = auth.uid()` en `INSERT` de clientes para un operador de Comercial. **B:** dejarlo (el cliente nuevo ya queda con vendedor por el Paquete 1).

## 5. Revisión precisa de las políticas abiertas

### 5.1 Escritura que solo pide «ser yo» (cinco)

Se buscaron todas las políticas de `INSERT`, `UPDATE`, `DELETE` y `ALL` en `public` y `storage` cuya condición **no menciona** rol, área, nivel, actividad ni dueño del registro (solo `auth.uid() = …` o subconsultas). **Ninguna escritura usa literalmente `true`.** Salen nueve y cuatro son legítimas (tus tareas, tus tickets, marcar tu notificación leída, tus mensajes de soporte). **Las cinco abiertas:**

| Tabla · política | Condición | Qué permite que no debería | Lo usa el front | Opciones |
|---|---|---|---|---|
| `clientes_bitacora` · «Usuarios autenticados pueden insertar en bitácora» (rol `public`) | `auth.uid() = usuario_id` | Cualquier sesión, **incluso inactiva o sin rol**, escribe en la bitácora de **cualquier** cliente, vea o no al cliente. Falsifica rastro de auditoría. | Sí (`Clientes.tsx`, `Remisiones.tsx:729`) | **A (probada):** además `usuario_operativo(auth.uid())` y que el cliente sea visible para quien escribe. **B:** solo `usuario_operativo`. |
| `clientes_comentarios` · «…insertar comentarios» (rol `public`) | `auth.uid() = usuario_id` | Igual: comentar en la ficha de cualquier cliente. | Sí (`Clientes.tsx`) | Igual que arriba. |
| `remisiones_bitacora` · «registrar cambio de remision» | `usuario_id = auth.uid()` | Igual sobre cualquier remisión; es la bitácora de lo que cambió en una remisión. | Sí (`Remisiones.tsx:1138`) | Igual que arriba. |
| `avisos` · «mandar aviso» | `creado_por = auth.uid()` | Cualquier sesión manda un aviso a **cualquier área**, con el nombre que quiera como creador. | **No inserta nunca** (solo marca vistos, `BandejaAvisos.tsx:99`); las **8 funciones** que crean avisos son `SECURITY DEFINER` | **A (recomendada, probada):** quitar la política. **B:** exigir `usuario_operativo`. |
| `notificaciones` · «mencionar usuario» | `creado_por = auth.uid()` | Cualquier sesión, incluso inactiva, manda notificaciones a cualquiera. | Sí (menciones, `lib/menciones.ts:85`) | **A (probada):** exigir `usuario_operativo`. **B:** dejarla. |

Una sexta, **`crm_ruta_paradas` · `crm_paradas_all`** (`ALL`, rol `public`), no es abierta: su condición es «puedo ver la ruta», y la ruta se ve por su propia política; en la matriz `abi06` coincide con el front.

**Prueba de la opción A** (réplica con A aplicada, mismas 76 acciones): `abi01`–`abi05` pasan a rechazar para inactivo y sin rol; `abi04` (avisos) rechaza a todos; vendedor ya no anota bitácora de un cliente que no ve; **los tres controles positivos `abp01`–`abp03` siguen pasando** para quien opera sobre lo suyo. La **reversa** deja el catálogo con la **misma huella** que antes (339 políticas, `6344dcde…`).
**Lo que A no cierra:** quien sí ve al cliente (Almacén, Compras, por R5) sigue pudiendo anotar en su bitácora; eso se cierra con R5.

### 5.2 Las tres lecturas abiertas (`USING (true)`, rol `authenticated`)

| Tabla | Filas | Columnas | Sensibilidad | Quién la lee hoy |
|---|---|---|---|---|
| `inventario_motivos_ajuste` | 6 | clave, nombre, requiere_texto, orden, activo… | Baja: catálogo de motivos | Front (`compras/comun.tsx`, `CatalogoArticulos.tsx`) |
| `inventario_unidades_venta` | 5 | clave, nombre, orden, activo… | Baja: catálogo de unidades | Front (igual) |
| `inventario_reglas_modo_prueba` | 43 | tabla, lectura, escritura, padre_tabla, columna, nota | **Media-baja:** es el mapa de qué tablas protege el modo de prueba y cómo; no hay datos de negocio | Front (`lib/dazon.ts`) |

Hoy las lee **cualquier sesión, incluidos usuarios inactivos y sin rol**. Las otras ocho tablas del mismo estilo (bitácora de color, configuración general, contenedores…) ya piden `usuario_operativo(auth.uid())`.
- **A (recomendada, probada):** las tres pasan a `USING (usuario_operativo(auth.uid()))`. Ningún usuario activo con rol deja de leerlas; inactivo y sin rol sí.
- **B:** dejarlas abiertas (son catálogos); el único costo es que `inventario_reglas_modo_prueba` muestra la estructura del modo de prueba a cualquier cuenta.

## 6. Revisión de funciones `SECURITY DEFINER`

De las funciones `SECURITY DEFINER` que `authenticated` puede llamar por RPC, **26** no mencionan directamente ninguna comprobación de identidad ni de rol en su cuerpo. Revisé las que escriben: `actualizar_compra_refacciones` y `confirmar_compras_refacciones` (revisan por `_compra_editable` → `puede_compras_inventario`), `crear_remision_refacciones` (`puede_capturar_refacciones`), `reintentar_asignar_remision` (`asignar_remision_items` revisa admin, fábrica o dueño), `decrementar/incrementar_inventario_color` (solo recalculan). **No encontré una función que escriba sin ningún control.** Quedan sin revisar a fondo `recalcular_etapa_remision_refaccion` y `generar_folio_interno_cliente` (consume un número de secuencia; no daño de datos) y las de solo lectura. La revisión de las 178 es un heurístico, **no una auditoría completa**.

## 7. Qué necesito de Polo y del equipo técnico

1. **El detalle del acceso con «otro token»**: qué cuenta o token (sin pegarlo; basta el rol de la persona), qué endpoint o pantalla, qué se vio o hizo y cuándo. Con eso busco en los registros de la API si coincide con R1–R9. Sin eso no puedo afirmar que sea alguno de estos huecos.
2. **Decidir R1/R2:** si se aplican los cambios 1 y 3 de la Fase 2 antes del sábado (recomiendo en la ventana del jueves).
3. **Decidir las cinco escrituras y tres lecturas:** A o B (recomiendo A para las ocho).
4. **R3, R4, R7:** confirmar la regla de negocio (quién cancela, quién perdona saldo, quién administra Administración).

*No se aplicó nada en producción por este trabajo.*

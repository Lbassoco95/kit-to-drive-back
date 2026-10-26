# Ensayo de la Fase 1 (Fase 0, sección 3.6)

**Resultado en una línea:** las seis migraciones se ensayaron completas, una por una, en una réplica local del esquema de producción con datos sintéticos; todas pasan, todas se revierten de forma exacta y ningún recorrido por rol cambia salvo el que debe cambiar. **Pero esto NO cumple al pie de la letra el punto 3.6**, que pide una *rama de Supabase o un proyecto duplicado*: no pude crear ninguno. Está explicado abajo y es una decisión de Polo.

## 1. Qué se pidió y qué se hizo

El encargo: ensayar en «una rama de Supabase o proyecto duplicado sin datos reales»; **si no se puede crear la copia, detenerse y reportarlo**; no ensayar en producción ni en QA. Se respetó lo último (no se tocó producción ni QA).

**Por qué no hay rama de Supabase:** una rama se construye reaplicando el *historial de migraciones* del proyecto, y el de producción es parcial (34 versiones, desde el 22 de septiembre; todo lo anterior se pegó a mano en el SQL Editor). Una rama saldría sin las tablas base (`profiles`, `user_roles`, `clientes`…) y fallaría desde la primera migración. Además genera costo por hora.
**Por qué no hay proyecto duplicado:** crear un proyecto nuevo en la organización suma a la factura y requiere confirmar el costo y la organización; eso lo decide Polo, no yo. Para llenarlo ya existe el esquema completo en `esquema_kit-to-drive_2026-10-25.sql` (ver `RESPALDO-Y-REVERSA.md`), restaurado con éxito en local.

**Lo que se hizo en su lugar (y su alcance):** una réplica en un **PostgreSQL 16 local dentro de esta sesión** (la imitación de Supabase del repo: roles `anon`, `authenticated`, `service_role`, `supabase_auth_admin`, `auth.users`, `auth.uid()`, `storage`). Sirve para probar lo que la Fase 1 cambia —permisos, triggers, políticas, valores por defecto— porque eso es comportamiento del **motor de PostgreSQL**, el mismo en Supabase. **No prueba** el servicio de autenticación (GoTrue), PostgREST, las Edge Functions, la compuerta ni las pantallas: eso queda en los recorridos de pantalla de `RECORRIDOS-Y-PRUEBAS-POR-ROL.md` y en la ventana.

**Decisión pendiente de Polo (antes del martes 27):**
- **A.** Aceptar este ensayo local más la aplicación una migración a la vez en producción, con reversa y verificación entre cada una (lo que propone `VENTANA-FASE-1.md`); o
- **B.** Autorizar un proyecto duplicado de Supabase (costo bajo, por horas) cargado con el esquema del respaldo y datos sintéticos, para repetir los recorridos de pantalla ahí, y borrarlo al terminar.
Mi recomendación es la **B** si hay tiempo antes de la ventana; si no, la A con la ventana de 8 horas.

## 2. Qué tan fiel es la réplica

`ensayo/construir-replica-fiel.py` arma la base con las migraciones del repo, le agrega lo que producción tiene y el repo no crea (8 funciones, 4 vistas, 1 tabla, 8 triggers, 5 columnas de `pagos`), le quita lo que el repo trae y producción no (3 funciones), reemplaza las políticas por las 338 de producción, deja los permisos de tablas, vistas y funciones **exactamente** como el respaldo, y copia los permisos por defecto. Resultado, con la misma consulta de conteos:

| | Producción | Réplica |
|---|---|---|
| Tablas / con seguridad por filas | 93 / 93 | 93 / 93 |
| Vistas / `security_invoker` | 18 / 18 | 18 / 18 |
| Funciones / SECURITY DEFINER / ejecutables por `authenticated` / por `anon` / sin `search_path` | 268 / 240 / 208 / 2 / 14 | 268 / 240 / 208 / 2 / 14 |
| Tablas con INSERT+UPDATE+DELETE para `anon` / TRUNCATE para `authenticated` y `anon` | 81 / 82 / 82 | 81 / 82 / 82 |
| Relaciones con TRIGGER y con REFERENCES (`anon` o `authenticated`) | 103 / 103 | 103 / 103 |
| Vistas con lectura para `anon` | 16 | 16 |
| Políticas de tablas con rol `public` / storage `public` / total de `public` | 34 / 4 / 301 | 34 / 4 / 301 |

**Diferencias que quedan:** el esquema `bkp` (8 tablas) y la publicación de realtime no están en la réplica (la Fase 1 no los toca); el motor es **PostgreSQL 16 y producción es 17**, y el permiso `MAINTAIN` (nuevo en 17) no existe aquí —las reversas se ensayan sin esa palabra—; los datos son sintéticos y mínimos (una fila en las tablas principales, 8 usuarios `…@ejemplo.test`).

## 3. Resultado por migración

Cada migración se aplicó en **una transacción** (como el SQL Editor), se midió, se aplicó su **reversa**, se comparó el catálogo completo (ACL ordenados) con la foto de antes, y se volvió a aplicar para probar que es **idempotente**.

| Migración | Aplica | Qué cambió en los conteos | Reversa restaura exacto | Idempotente |
|---|---|---|---|---|
| 1. TRUNCATE, TRIGGER, REFERENCES | sí | tablas anon truncate: 82→0, tablas authenticated truncate: 82→0, relaciones con trigger anon o auth: 103→0, relaciones con references anon o auth: 103→0 | sí | sí |
| 2. Funciones de trigger | sí | funciones ejecutables anon: 2→0, secdef ejecutables authenticated: 208→178 | sí | sí |
| 3. `search_path` (14) | sí | funciones sin search path: 14→0 | sí | sí |
| 4. Vistas de `anon` (16) | sí | vistas anon select: 16→0 | sí | sí |
| 5. Escritura de `anon` | sí | tablas anon insert update delete: 81→0 | sí | sí |
| 6. Lo nuevo nace cerrado | sí | ninguno (cambia solo lo que se cree después) | sí | sí |

Al final: las seis aplicadas → conteos de la columna «después» de `LINEA-BASE-2026-10-25.md`; las seis reversas en orden inverso → catálogo **idéntico** a la línea base; las seis aplicadas de nuevo → idéntico a la primera vez. Resultado completo en `ensayo/resultado-ensayo-2026-10-25.json`.

**Recorridos por rol** (`RECORRIDOS-Y-PRUEBAS-POR-ROL.md`): de **160** acciones (8 roles × 20), **solo 8 cambian**, y es la misma: «vaciar la bitácora de eventos» pasa de ejecutarse a `42501`. Las pruebas genéricas de TRUNCATE, funciones de trigger, vistas y escritura de `anon` pasan a `42501` en el 100 % de los objetos. El alta de usuario es idéntica.

## 4. Lo que el ensayo descubrió (y se corrigió antes de entregar)

1. **La migración 3 rompía una base armada solo con el repo.** `patch_corregir_surtido_indebido_faltante()` existe en producción y ningún script la crea; el `ALTER FUNCTION` fallaba y detenía `aplicar_migraciones.sh` y las pruebas de base. Atrapado por las pruebas opcionales del repo. Corregido: lista fija de las 14 firmas con una guarda de existencia (`to_regprocedure`). Con la corrección, la salida de las pruebas de base es idéntica a `origin/main`.
2. **El intento previo de «lo nuevo nace cerrado» no funcionaba.** `20261009000002` hizo `ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE … FROM PUBLIC, anon`, que en PostgreSQL no quita el permiso a PUBLIC. Probado en la réplica con una función nueva: **antes** `{=X/postgres,…}` y `anon_ejecuta = true`; **después de la migración 6** `{postgres=X, service_role=X}` y `false`. Es la causa de que `limpiar_entrega_programada_refaccion()` (creada después) quedara abierta a `anon`. La migración 6 usa la forma global, que sí funciona.
3. **PostgreSQL no revisa EXECUTE al disparar un trigger.** Probado con un experimento mínimo (un rol sin ningún EXECUTE inserta y se ejecutan los dos triggers, INVOKER y DEFINER) y confirmado en producción: 6 funciones de trigger (entre ellas `set_updated_at`, en 24 tablas) ya no eran ejecutables por `authenticated` y funcionan. **Esto contradice la explicación del incidente de `20261009000002` → `20261010000001`** (alta de usuarios rota por quitar EXECUTE al rol de Auth): no se pudo reproducir. Por prudencia la migración 2 vuelve a conceder explícitamente a `supabase_auth_admin` los dos triggers de `auth.users`, y **el recorrido de alta de usuarios es obligatorio en la ventana**.
4. **Defectos del propio arnés, corregidos:** la foto del catálogo salía vacía por una concatenación con tipo `"char"` (las primeras comparaciones «restaura exacto» eran vacías; ahora el ensayo se detiene si la foto sale incompleta), y el orden de los ACL daba una falsa diferencia en la reversa del punto 4.

## 5. Limpieza

Las bases locales del ensayo (`kit_prod_like`, `exp_restore`, `exp_trigger`, `kit_replica` y similares) viven solo en el PostgreSQL de esta sesión. **Se borraron al terminar** (ver el cierre del reporte final) y desaparecen de todos modos al cerrar la sesión. No salió ningún dato de producción: la réplica se construyó con estructura y definiciones; los datos son inventados.

# Ventana de la Fase 1 en producción — guion

> **Orden y mecanismo vigentes: ver `RUNBOOK-CONSOLIDADO-VENTANAS.md`.** La migración 3 (`search_path`) se aplica **al final y sola** (orden 1, 2, 4, 5, 6, 3), y se aplica con `psql` en una transacción por archivo (no con `supabase db push`: el historial de la CLI no coincide con el repo). Cada paso incluye la comparación de integridad de la información.

**Estado: NADA SE HA APLICADO EN PRODUCCIÓN.** Este guion está listo para usarse **solo cuando Polo escriba, en la misma sesión de trabajo con Claude: «Autorizo Fase 1 en producción, ventana del `<fecha>`».** Sin esa frase exacta, con fecha, no se aplica nada. Si la ventana que indique Polo no coincide con el momento de la ejecución, tampoco.

## 1. Ventana

- **Propuesta:** **lunes 26 de octubre de 2026**, de 19:00 a 00:00 (hora de la Ciudad de México). Calendario fijado por Polo: Fase 1 el lunes 26 de octubre; Paquete 1 el jueves 29 de octubre (19:00–22:00); Fase 2 el sábado 31 de octubre (10:00–15:00). Si el ensayo no queda limpio: la nueva fecha la fija Polo.
- Es fuera del uso de Dazon (después de las 19:00). Los administradores (uno de ellos en China) pueden entrar a cualquier hora: **avisarles** al empezar y al terminar.
- **Una fase o paquete por ventana.** Entre la Fase 1 y la Fase 2 quedan el Paquete 1 (jueves 29) y solo unos días de observación (calendario de Polo; antes se proponía una semana). Esta ventana es solo la Fase 1.

## 2. Antes de empezar (todo debe estar en verde)

1. ☐ **Respaldo de Supabase** del mismo día o del anterior, con fecha anotada en `RESPALDO-Y-REVERSA.md`. (Pendiente de confirmar por Polo: la herramienta de Claude no lo ve.)
2. ☐ **Esquema guardado fuera del repo** en un lugar permanente (ver `RESPALDO-Y-REVERSA.md`).
3. ☐ **Decisión A/B del ensayo** (`ENSAYO-FASE-1.md` §1) tomada por Polo. Con la opción B, los recorridos de pantalla ya pasaron en el proyecto duplicado.
4. ☐ **Diagnóstico del repo** (`supabase/diagnostico_esquema.sql`, de solo lectura) pegado en el SQL Editor de producción. Se esperan `PARCIAL` conocidos (`20261014000001`, `fix_remisiones_columns`, `20261016000001_super_admin_aprobaciones`: ver `LINEA-BASE-2026-10-25.md` §6) y **FALTA** en los seis scripts `20261031…` (aún no se aplican). Cualquier otro `FALTA` o `PARCIAL` nuevo = detenerse.
5. ☐ **Línea base repetida:** correr `consultas/02-conteos-linea-base.sql` en producción y comparar con `LINEA-BASE-2026-10-25.md`. **Si una cifra no cuadra y no se explica, detenerse y avisar antes de aplicar.**
6. ☐ **Recorridos de pantalla 1–12** (`RECORRIDOS-Y-PRUEBAS-POR-ROL.md`) hechos una vez *antes*, con cuentas de prueba, y anotados.
7. ☐ Los **dos super admins** conocidos están activos y alguien puede entrar con uno de ellos durante la ventana (`profiles.activo = true`, nivel admin, área dirección). **No se modifican.** *(Pendiente: Polo debe confirmar que la cuenta `…@qq.com` es legítima; ver `HALLAZGOS-PENDIENTES.md`.)*
8. ☐ Alguien con acceso al panel de Supabase para revertir si Claude no estuviera disponible.

## 3. Cómo se aplica (una migración a la vez)

**Mecanismo vigente del repo:** pegar el archivo completo en el SQL Editor de Supabase (corre en **una** transacción: si falla, no queda nada a medias) o, desde Claude, la herramienta de aplicar migraciones, que **pide autorización en cada ejecución**. No se despliega nada por GitHub ni por Vercel: la Fase 1 no cambia código.

Para **cada** migración, en este orden:

| Orden | Archivo | Qué cambia | Verificación esperada (la trae la propia migración) | Si falla |
|---|---|---|---|---|
| 1 | `20261031000001_fase1_quitar_truncate_trigger_references.sql` | TRUNCATE, TRIGGER, REFERENCES | `0, 0, 0, 0` | reversa 1 |
| 2 | `20261031000002_fase1_cerrar_funciones_de_trigger.sql` | EXECUTE de 53 funciones de trigger | `0, 0, true, true` y aviso «Funciones de trigger cerradas: 53» | reversa 2 |
| 3 | `20261031000003_fase1_fijar_search_path.sql` | `search_path` de 14 funciones | aviso «Funciones con search_path fijado: 14» y `0` | reversa 3 |
| 4 | `20261031000004_fase1_quitar_lectura_anon_de_vistas.sql` | `anon` sin acceso a 16 vistas | aviso «Vistas cerradas a anon: 16» y `0, 18` | reversa 4 |
| 5 | `20261031000005_fase1_quitar_escritura_anon_de_tablas.sql` | `anon` sin INSERT/UPDATE/DELETE | `0` | reversa 5 |
| 6 | `20261031000006_fase1_lo_nuevo_nace_cerrado.sql` | permisos por defecto de lo nuevo | `true, true, true` | reversa 6 |

Después de **cada una**:
1. Leer la verificación que devuelve el propio script y compararla con la tabla.
2. Correr `consultas/02-conteos-linea-base.sql`: debe cambiar **solo** lo que dice la tabla de `ENSAYO-FASE-1.md` §3.
3. **Recorridos de pantalla 1–12.** Los puntos **1, 2, 3, 5 y 6** son obligatorios después de la migración 2 (alta de usuarios) y de la 1 (todo el sistema).
4. Mirar los registros de la API (`edge_logs`) y de la compuerta: ningún `5xx` ni `42501` nuevos respecto de la línea base.
5. **Registrar la migración:** `INSERT INTO public.migraciones_aplicadas (script, estado, notas) VALUES ('20261031000001_fase1_quitar_truncate_trigger_references', 'aplicado', 'Fase 1, ventana del <fecha>');` (uno por script; la tabla ya existe en producción).
6. Solo entonces, la siguiente.

## 4. Cuándo detenerse y revertir

- Falla **cualquier** recorrido después de una migración → aplicar **esa** reversa (`supabase/reversas/…_reversa.sql`), comprobar con `02-conteos-linea-base.sql` que se recuperó la línea base, y **detenerse**.
- Aparece un `4xx`/`5xx` nuevo en la compuerta, en `mati-api` o en el puente que no estaba en la línea base → revertir y reportar.
- El número de funciones, tablas o permisos no coincide con la sección 2 del encargo (o con la línea base) y no se explica → no aplicar.
- Un `REVOKE` falla por dependencia (no se usa `CASCADE` a propósito) → **no** insistir con `CASCADE`: detenerse y reportar.

## 5. Después de la ventana

1. Repetir la **línea base completa** (conteos, asesores, consultas costosas, errores, despliegues y pruebas) y guardarla como `REPORTE-FASE-1.md`, con por cada migración: qué cambió, conteos antes y después, resultado de los recorridos por rol, reversa probada y lo que falló o se pospuso.
2. Avisar a los administradores.
3. Observación hasta el Paquete 1 (jueves 29) y la Fase 2 (sábado 31), según el calendario de Polo.
4. Si el equipo de QA o el de Dazon despliega funciones nuevas: recordar la regla nueva: toda función que el front llame o que usen las políticas necesita su `GRANT EXECUTE … TO authenticated` explícito (ver `docs/guia-del-equipo.md`). **El proyecto de QA no recibe el cambio de permisos por defecto**, así que allí una función sin GRANT sí funcionaría y en producción no.

## 6. Fuera de la Fase 1 (no se toca en esta ventana)

Perfiles, roles y super administradores; políticas y su optimización; índices; realtime; auditoría; el esquema `bkp` y `zz_lista_oct`; la rotación de la llave `anon`; y la activación de la protección contra contraseñas filtradas (la hace Polo en el panel: `CONTRASENAS-FILTRADAS.md`).

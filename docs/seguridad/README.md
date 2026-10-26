# Seguridad de la base de producción — Kit-to-Drive

Trabajo del 25 de octubre de 2026 con base en la guía de principios de datos de Yoltik. **Estado: Fase 0 entregada; Fase 1 preparada, ensayada y detenida a la espera de la autorización escrita de Polo** (`VENTANA-FASE-1.md`). **La Fase 2 (perfiles, roles, super admins y cuentas demo) está preparada y ensayada, también a la espera de autorización** (`RUNBOOK-VENTANA-FASE-2.md`; depende de la Fase 1). **No se ha aplicado nada en producción ni en QA.**

| Documento | Para qué sirve |
|---|---|
| `LINEA-BASE-2026-10-25.md` | Las cifras de hoy (permisos, asesores, consultas, errores, despliegues, pruebas) y cómo repetirlas |
| `RESPALDO-Y-REVERSA.md` | Qué se respaldó, copia lógica del esquema, respaldo diario, cómo se revierte cada migración |
| `CLASIFICACION-FUNCIONES.md` | Las 268 funciones en tres grupos y la auditoría de las RPC que llama el front |
| `USO-DE-ANON-Y-REALTIME.md` | Quién usa a `anon` y a realtime, por flujo |
| `RECORRIDOS-Y-PRUEBAS-POR-ROL.md` | Recorridos de pantalla y matriz automática permitido/rechazado por rol |
| `ENSAYO-FASE-1.md` | El ensayo de las seis migraciones (y por qué no es todavía el ensayo en Supabase) |
| `VENTANA-FASE-1.md` | Guion de la ventana: antes, durante, cuándo detenerse |
| `CONTRASENAS-FILTRADAS.md` | Paso a paso para Polo en el panel de Supabase y qué hace el front con ese error |
| `HALLAZGOS-PENDIENTES.md` | Lo que apareció y no se corrigió (incluye la autopromoción de perfiles) |
| `FASE-2-LINEA-BASE-Y-RECORRIDOS.md` | Fase 2: lo que hay hoy, qué debe poder cada rol y el resultado antes y después |
| `FASE-2-CAMBIOS-Y-REVERSAS.md` | Fase 2: qué cambia cada migración y función, riesgo y reversa; decisiones donde no se siguió la letra |
| `FASE-2-ENSAYO.md` | Fase 2: el ensayo y sus límites |
| `RUNBOOK-VENTANA-FASE-2.md` | Fase 2: guion de la ventana, frases de autorización y criterios de reversa |
| `CUENTAS-DEMO.md` | Las 9 cuentas `@dazon.demo`, la contraseña fija del historial y qué se propone |
| `SUPER-ADMINS-Y-ADMIN-DIRECCION.md` | Los 2 super admins y los 6 administradores de Dirección, con responsable |
| `REVISION-PERFILES-HISTORICOS.md` | Perfiles que no coinciden con el flujo normal de alta (solo lectura) |

Carpetas: `respaldo/` (permisos, políticas y huellas, sin datos), `consultas/` (consultas de solo lectura), `ensayo/` (scripts de la réplica y del ensayo, y su resultado). Las migraciones están en `supabase/migrations/20261031…` (Fase 1) y `20261107…` (Fase 2) y sus reversas en `supabase/reversas/`. Las operaciones de datos de una sola vez (cuentas demo) están en `supabase/operaciones/`, **fuera** de las migraciones a propósito.

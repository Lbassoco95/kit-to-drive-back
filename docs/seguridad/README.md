# Seguridad de la base de producción — Kit-to-Drive

Trabajo del 25 de octubre de 2026 con base en la guía de principios de datos de Yoltik. **Estado: Fase 0 entregada; Fase 1 preparada, ensayada y detenida a la espera de la autorización escrita de Polo** (`VENTANA-FASE-1.md`). **No se ha aplicado nada en producción ni en QA.**

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

Carpetas: `respaldo/` (permisos, políticas y huellas, sin datos), `consultas/` (consultas de solo lectura), `ensayo/` (scripts de la réplica y del ensayo, y su resultado). Las migraciones están en `supabase/migrations/20261031…` y sus reversas en `supabase/reversas/`.

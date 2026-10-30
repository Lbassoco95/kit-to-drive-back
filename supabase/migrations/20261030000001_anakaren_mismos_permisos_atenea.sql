-- ============================================================================
-- Ana Karen: los mismos permisos de remisiones que Atenea
-- Fecha: 2026-10-30
--
-- Ana Karen (ana.rivas@dazon.mx) es administrativa de ventas
-- (profiles.es_administrativo, 20261014000002): carga remisiones de motocarro
-- a nombre del vendedor correspondiente. Desde que dejó de ser vendedora
-- (es_vendedor = false) la pantalla le exige elegir a alguien del equipo, y al
-- guardar el RLS la rechazaba:
--
--     new row violates row-level security policy for table "remisiones"
--
-- La política `crear remisiones` pasa por `puede_capturar_remision()`: el
-- operador de Comercial sólo captura a su propio nombre… salvo que esté en la
-- allowlist `remisiones_asignacion_acceso` con `puede_cargar_anteriores`,
-- que es justo como Atenea captura a nombre de cualquier vendedor.
--
-- Este script la deja igual que Atenea (20260929000002 + 20261001000001 +
-- 20261001000002): misma fila de allowlist con las cuatro banderas:
--
--   · activo                    — asignación de chasis/motor y alta de unidades
--                                 ya armadas desde la bandeja de Remisiones.
--   · puede_configurar_pedido   — cambiar modelo/color/cantidad/servicios de
--                                 cualquier remisión vía configurar_pedido_remision().
--   · puede_editar_remisiones   — corregir cualquier remisión con el flujo de
--                                 «Editar» (motivo obligatorio en bitácora).
--   · puede_cargar_anteriores   — selector «Anterior (en físico)» y, de paso,
--                                 capturar a nombre de cualquier vendedor del
--                                 equipo (es lo que destraba el error de RLS).
--
-- No toca funciones ni políticas: todo pasa por las que ya existen.
--
-- Para retirarlo:
--   UPDATE public.remisiones_asignacion_acceso
--      SET activo = false, updated_at = now()
--    WHERE lower(email) IN ('ana.rivas@dazon.mx',
--                           'anakaren@dazon.demo', 'anakaren@dazon.demo.com');
--
-- Requiere 20260929000002 (tabla) y 20261001000001 / 20261001000002 (columnas).
--
-- ADVERTENCIA: idempotente, para el SQL editor de Supabase. NO usar
-- `supabase db push`.
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := '{}';
BEGIN
  IF to_regclass('public.remisiones_asignacion_acceso') IS NULL THEN
    _faltan := _faltan || 'tabla remisiones_asignacion_acceso (20260929000002)'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public'
                    AND table_name  = 'remisiones_asignacion_acceso'
                    AND column_name = 'puede_configurar_pedido') THEN
    _faltan := _faltan || 'columna remisiones_asignacion_acceso.puede_configurar_pedido (20261001000001)'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public'
                    AND table_name  = 'remisiones_asignacion_acceso'
                    AND column_name = 'puede_editar_remisiones') THEN
    _faltan := _faltan || 'columna remisiones_asignacion_acceso.puede_editar_remisiones (20261001000002)'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public'
                    AND table_name  = 'remisiones_asignacion_acceso'
                    AND column_name = 'puede_cargar_anteriores') THEN
    _faltan := _faltan || 'columna remisiones_asignacion_acceso.puede_cargar_anteriores (20261001000002)'::text; END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ', ');
  END IF;
END;
$preflight$;

-- ── Fila de allowlist: como la de Atenea ────────────────────────────────────
-- Se busca por el correo real (ana.rivas@dazon.mx, el mismo que usa
-- 20261014000002) y por las variantes demo por si la cuenta de Auth usa otra.
INSERT INTO public.remisiones_asignacion_acceso
  (user_id, email, activo, puede_configurar_pedido, puede_editar_remisiones, puede_cargar_anteriores)
SELECT u.id, u.email, true, true, true, true
FROM auth.users u
WHERE lower(u.email) IN ('ana.rivas@dazon.mx',
                         'anakaren@dazon.demo',
                         'anakaren@dazon.demo.com')
ON CONFLICT (user_id) DO UPDATE
SET email                    = EXCLUDED.email,
    activo                   = true,
    puede_configurar_pedido  = true,
    puede_editar_remisiones  = true,
    puede_cargar_anteriores  = true,
    updated_at               = now();

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.remisiones_asignacion_acceso a
     WHERE lower(a.email) IN ('ana.rivas@dazon.mx',
                              'anakaren@dazon.demo',
                              'anakaren@dazon.demo.com')
       AND a.activo
  ) THEN
    RAISE EXCEPTION 'No existe el usuario de Ana Karen en Auth (ana.rivas@dazon.mx / anakaren@dazon.demo); no se otorgó el permiso';
  END IF;
END;
$$;

-- ── Verificación ────────────────────────────────────────────────────────────
SELECT email, activo, puede_configurar_pedido, puede_editar_remisiones, puede_cargar_anteriores
  FROM public.remisiones_asignacion_acceso
 WHERE lower(email) IN ('ana.rivas@dazon.mx',
                        'anakaren@dazon.demo',
                        'anakaren@dazon.demo.com',
                        'atenea@dazon.demo.com')
 ORDER BY email;

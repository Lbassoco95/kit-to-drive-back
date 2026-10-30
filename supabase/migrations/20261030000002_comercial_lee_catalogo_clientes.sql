-- ============================================================================
-- Comercial lee el catálogo completo de clientes
-- Fecha: 2026-10-30
--
-- Desde 20261007000002 el operador de Comercial sólo veía los clientes con
-- `vendedor_id = él` o los de sus propias remisiones. En la práctica el
-- catálogo casi no tiene `vendedor_id` asignado, así que un vendedor nuevo
-- abre Clientes y ve «0 de 0», y en el CRM (Oportunidades, Actividades,
-- Rutas) el buscador de cliente sale vacío: no puede crear nada porque no
-- puede elegir cliente. Martín lo confirmó: al subir al usuario a supervisor
-- entra por `ve_todo_comercial` y todo aparece.
--
-- El catálogo de clientes es de prospección: cualquier comercial activo
-- necesita buscar y elegir clientes aunque todavía no tenga remisiones con
-- ellos. Las remisiones NO cambian: el vendedor sigue viendo sólo las suyas
-- (política «comercial lee remisiones» de 20261007000001).
--
-- Sólo LECTURA y ADITIVO: no toca la política «leer clientes» ni los permisos
-- de escritura (insert/update/delete siguen igual).
--
-- Efecto colateral aceptado: lo que sigue a la visibilidad del cliente se
-- abre para todo Comercial — comentarios/bitácora del cliente, documentos
-- del expediente (storage clientes-docs) y cartera (cuentas_por_cobrar).
-- Es la misma lectura que ya tenían supervisor y administrativas.
--
-- Para retirarlo: DROP POLICY "comercial lee catalogo clientes".
--
-- ADVERTENCIA: idempotente, para el SQL editor de Supabase. NO usar
-- `supabase db push`.
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := '{}';
BEGIN
  IF to_regclass('public.clientes') IS NULL THEN _faltan := _faltan || 'tabla clientes'::text; END IF;
  IF to_regprocedure('public.usuario_activo(uuid)') IS NULL THEN _faltan := _faltan || 'función usuario_activo (20260824000003)'::text; END IF;
  IF to_regprocedure('public.es_area(uuid,public.user_area)') IS NULL THEN _faltan := _faltan || 'función es_area (20260823000005)'::text; END IF;
  IF to_regprocedure('public.has_role(uuid,public.app_role)') IS NULL THEN _faltan := _faltan || 'función has_role'::text; END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ', ');
  END IF;
END;
$preflight$;

DROP POLICY IF EXISTS "comercial lee catalogo clientes" ON public.clientes;
CREATE POLICY "comercial lee catalogo clientes" ON public.clientes
  FOR SELECT TO authenticated
  USING (
    public.usuario_activo(auth.uid())
    AND (
      public.es_area(auth.uid(), 'comercial'::public.user_area)
      OR public.has_role(auth.uid(), 'ventas'::app_role)
    )
  );

-- ── Verificación (solo lectura) ─────────────────────────────────────────────
-- 1) La política existe:
--    SELECT policyname FROM pg_policies
--     WHERE schemaname='public' AND tablename='clientes'
--       AND policyname='comercial lee catalogo clientes';
--
-- 2) Con sesión de un vendedor operador: SELECT count(*) FROM clientes;
--    debe devolver el catálogo completo, no 0.
--
-- ── Diagnóstico aparte: «el vendedor ve TODAS las remisiones» ───────────────
-- La política ya lo limita a vendedor_id = auth.uid(); si ve todo, su cuenta
-- tiene un permiso amplio. Correr con los correos de los vendedores afectados:
--
--   SELECT p.email, p.nombre_completo, p.es_administrativo,
--          ur.area, ur.nivel, ur.role AS app_role,
--          public.es_administrativo_comercial(p.id) AS adm_comercial,
--          public.ve_todo_comercial(p.id)           AS ve_todo,
--          public.es_admin_global(p.id)             AS admin_global
--     FROM public.profiles p
--     LEFT JOIN public.user_roles ur ON ur.user_id = p.id
--    WHERE lower(p.email) IN ('carlos.chavarria@dazon.mx' /*, 'otro@dazon.mx'*/);
--
-- Si sale ve_todo / adm_comercial / admin_global en true, o un app_role como
-- 'coordinador'/'finanzas'/'admin', ahí está la fuga: quitar ese rol/nivel, no
-- tocar la política.

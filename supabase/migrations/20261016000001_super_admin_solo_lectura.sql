-- ============================================================================
-- Super admin: Dirección · admin con pedidos de clientes y finanzas en solo
-- lectura (2026-10-16).
--
-- Un Super admin ve y modifica todo lo que ve un admin de Dirección
-- (producción, inventario, compras, almacén, clientes, CRM, tareas…), pero no
-- puede dar de alta, cambiar ni borrar pedidos de clientes (remisiones de motos
-- y de refacciones) ni información financiera. Es para evitar errores.
--
-- Quién es Super admin vive en una tabla aparte y no en `user_roles`, porque
-- admin-update-user borra y vuelve a crear la fila de `user_roles` cada vez
-- que se edita un usuario: la marca se perdería. Nadie la puede cambiar desde
-- la app; sólo desde el SQL editor (ver supabase/asignar_super_admin.sql).
--
-- El bloqueo es un trigger en cada tabla de pedidos y finanzas, así que aplica
-- igual a escrituras directas y a las que hacen las funciones RPC (la API pasa
-- el token del usuario, así que auth.uid() es él). Sólo frena la escritura que
-- el usuario provoca de primera mano (pg_trigger_depth() = 1); lo que otros
-- triggers escriben en cascada —bitácoras, asignaciones automáticas— sigue
-- funcionando. Idempotente.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.usuarios_solo_lectura_pedidos_finanzas (
  user_id   uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  creado_en timestamptz NOT NULL DEFAULT now(),
  nota      text
);
ALTER TABLE public.usuarios_solo_lectura_pedidos_finanzas ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.usuarios_solo_lectura_pedidos_finanzas FROM PUBLIC, anon, authenticated;

-- ¿El usuario de esta sesión es Super admin? Sólo responde por uno mismo.
CREATE OR REPLACE FUNCTION public.es_solo_lectura_pedidos_finanzas()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT auth.uid() IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM public.usuarios_solo_lectura_pedidos_finanzas
        WHERE user_id = auth.uid()
     )
$$;
REVOKE ALL ON FUNCTION public.es_solo_lectura_pedidos_finanzas() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.es_solo_lectura_pedidos_finanzas() TO authenticated;

CREATE OR REPLACE FUNCTION public.bloquear_escritura_solo_lectura()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF pg_trigger_depth() = 1 AND public.es_solo_lectura_pedidos_finanzas() THEN
    RAISE EXCEPTION 'Solo lectura: tu usuario no puede modificar pedidos de clientes ni finanzas (%).', TG_TABLE_NAME
      USING ERRCODE = '42501',
            HINT = 'Pide el cambio a Comercial, Administración o a un admin de Dirección.';
  END IF;
  RETURN COALESCE(NEW, OLD);
END
$$;
REVOKE ALL ON FUNCTION public.bloquear_escritura_solo_lectura() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bloquear_escritura_solo_lectura() TO authenticated, service_role;

-- Tablas de pedidos de clientes y de finanzas. Las que no existan en esta base
-- se saltan sin error.
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    -- Pedidos de clientes (motos y refacciones)
    'remisiones', 'remision_items',
    'remisiones_refacciones', 'remision_refaccion_items',
    'remision_refaccion_ordenes', 'remision_refaccion_correcciones',
    'remision_refaccion_eventos',
    -- Finanzas
    'movimientos_financieros', 'movimiento_adjuntos', 'cuentas_financieras',
    'flujo_dinero', 'flujo_capacidades', 'pagos',
    'cuentas_por_cobrar', 'cxc_abonos',
    'cobranza_pagos', 'cobranza_aplicaciones',
    'cobranza_saldos_favor', 'cobranza_solicitudes_saldo'
  ] LOOP
    IF EXISTS (
      SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public' AND c.relname = t AND c.relkind IN ('r', 'p')
    ) THEN
      EXECUTE format('DROP TRIGGER IF EXISTS trg_solo_lectura_pedidos_finanzas ON public.%I', t);
      EXECUTE format(
        'CREATE TRIGGER trg_solo_lectura_pedidos_finanzas
           BEFORE INSERT OR UPDATE OR DELETE ON public.%I
           FOR EACH ROW EXECUTE FUNCTION public.bloquear_escritura_solo_lectura()', t);
    END IF;
  END LOOP;
END
$$;

-- Verificación: lista las tablas que quedaron protegidas.
SELECT c.relname AS tabla_protegida
  FROM pg_trigger tg
  JOIN pg_class c ON c.oid = tg.tgrelid
 WHERE tg.tgname = 'trg_solo_lectura_pedidos_finanzas'
 ORDER BY 1;

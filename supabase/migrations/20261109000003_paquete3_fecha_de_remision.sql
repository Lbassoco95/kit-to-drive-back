-- ============================================================================
-- PAQUETE 3 · 3 de 3: EDITAR la fecha de la remisión (solo Dirección y administrativos de Comercial, con motivo)
--
-- Hallazgo: hoy la fecha de la remisión la puede cambiar cualquiera que edite la remisión (la pantalla manda
-- `fecha_remision` en el UPDATE, y la política «actualizar remisiones» deja editar al vendedor dueño).
--
-- Decisiones de Polo (26 oct 2026): D-B1 = A (no se edita la fecha de una remisión de refacciones que ya surtió
-- inventario: hay movimientos de kárdex con esa fecha), D-B2 = A (no se mueve el vencimiento de ninguna cuenta por
-- cobrar: se AVISA al área de administración/finanzas), D-B3 = A (las dos remisiones: motocarros y refacciones).
-- (Crédito, que era la parte C del paquete, espera a Martin y NO se construye aquí.)
--
-- Qué crea: tabla `remision_fecha_cambios` (remisión, tipo, folio, fecha original y nueva, motivo obligatorio, quién y cuándo;
-- sin llave foránea a la remisión para que el historial sobreviva a una eliminación; con RLS: solo lectura para Dirección,
-- administrativos y supervisores de Comercial, finanzas/cobranza y super admin; nadie escribe directo);
-- función `cambiar_fecha_remision(_tipo, _remision_id, _fecha_nueva, _motivo)` (SECURITY DEFINER, search_path fijo);
-- y un trigger en las dos tablas que impide cambiar `fecha_remision` por otra vía (la fecha original nunca se pierde).
-- Reglas de la función: la fecha nueva no es futura (hora de la Ciudad de México), motivo ≥ 5 caracteres, distinta de la actual,
-- remisión no cancelada, y para refacciones sin inventario surtido. Deja el aviso en `avisos` (área administración).
-- Idempotente. Reversa: supabase/reversas/20261109000003_paquete3_fecha_de_remision_reversa.sql
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.remision_fecha_cambios (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tipo           text NOT NULL CHECK (tipo IN ('motocarro', 'refacciones')),
  remision_id    uuid NOT NULL,
  folio          text,
  fecha_original date NOT NULL,
  fecha_nueva    date NOT NULL,
  motivo         text NOT NULL CHECK (char_length(trim(motivo)) >= 5),
  cambiado_por   uuid NOT NULL,
  nombre_usuario text,
  cambiado_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_remision_fecha_cambios_remision ON public.remision_fecha_cambios (tipo, remision_id, cambiado_at);

ALTER TABLE public.remision_fecha_cambios ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.remision_fecha_cambios FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.remision_fecha_cambios TO authenticated;
GRANT ALL ON TABLE public.remision_fecha_cambios TO service_role;

DROP POLICY IF EXISTS "leer cambios de fecha de remision" ON public.remision_fecha_cambios;
CREATE POLICY "leer cambios de fecha de remision" ON public.remision_fecha_cambios FOR SELECT TO authenticated
  USING (public.es_area(auth.uid(), 'direccion'::public.user_area)
         OR public.es_administrativo_comercial(auth.uid())
         OR public.ve_todo_comercial(auth.uid())
         OR public.puede_finanzas_cobranza(auth.uid())
         OR public.es_super_admin(auth.uid()));

CREATE OR REPLACE FUNCTION public.remision_fecha_solo_por_funcion()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.fecha_remision IS DISTINCT FROM OLD.fecha_remision
     AND coalesce(current_setting('kit.permite_cambio_fecha', true), '') <> '1' THEN
    RAISE EXCEPTION 'La fecha de la remisión solo se cambia con «Cambiar fecha» (Dirección o administrativo de Comercial), con motivo'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.remision_fecha_solo_por_funcion() FROM PUBLIC, anon, authenticated;  -- función de trigger: nadie la llama

DROP TRIGGER IF EXISTS trg_remisiones_fecha_solo_funcion ON public.remisiones;
CREATE TRIGGER trg_remisiones_fecha_solo_funcion BEFORE UPDATE OF fecha_remision ON public.remisiones
  FOR EACH ROW EXECUTE FUNCTION public.remision_fecha_solo_por_funcion();
DROP TRIGGER IF EXISTS trg_remisiones_refacciones_fecha_solo_funcion ON public.remisiones_refacciones;
CREATE TRIGGER trg_remisiones_refacciones_fecha_solo_funcion BEFORE UPDATE OF fecha_remision ON public.remisiones_refacciones
  FOR EACH ROW EXECUTE FUNCTION public.remision_fecha_solo_por_funcion();

CREATE OR REPLACE FUNCTION public.cambiar_fecha_remision(_tipo text, _remision_id uuid, _fecha_nueva date, _motivo text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_folio text;
  v_original date;
  v_hoy date := (now() AT TIME ZONE 'America/Mexico_City')::date;
  v_nombre text;
  v_prueba boolean := false;
BEGIN
  IF auth.uid() IS NULL OR NOT (
       (public.es_area(auth.uid(), 'direccion'::public.user_area) OR public.es_administrativo_comercial(auth.uid()))
       AND public.usuario_activo(auth.uid())
     ) THEN
    RAISE EXCEPTION 'Solo Dirección o un administrativo de Comercial cambia la fecha de una remisión' USING ERRCODE = '42501';
  END IF;
  IF _tipo IS NULL OR _tipo NOT IN ('motocarro', 'refacciones') THEN
    RAISE EXCEPTION 'Tipo de remisión no válido (motocarro o refacciones)';
  END IF;
  IF _fecha_nueva IS NULL THEN RAISE EXCEPTION 'Indica la fecha nueva'; END IF;
  IF _fecha_nueva > v_hoy THEN RAISE EXCEPTION 'La fecha nueva no puede ser futura'; END IF;
  IF nullif(trim(_motivo), '') IS NULL OR char_length(trim(_motivo)) < 5 THEN
    RAISE EXCEPTION 'Escribe el motivo del cambio (mínimo 5 caracteres)';
  END IF;

  IF _tipo = 'motocarro' THEN
    SELECT folio_remision, fecha_remision INTO v_folio, v_original FROM public.remisiones
     WHERE id = _remision_id AND estatus <> 'CANCELADA' FOR UPDATE;
  ELSE
    SELECT folio, fecha_remision, es_prueba INTO v_folio, v_original, v_prueba FROM public.remisiones_refacciones
     WHERE id = _remision_id AND etapa <> 'cancelada' FOR UPDATE;
  END IF;
  IF NOT FOUND THEN RAISE EXCEPTION 'No se encontró la remisión (o está cancelada)'; END IF;
  IF v_original IS NOT DISTINCT FROM _fecha_nueva THEN RAISE EXCEPTION 'La fecha nueva es igual a la actual'; END IF;
  IF _tipo = 'refacciones' AND (
       EXISTS (SELECT 1 FROM public.remision_refaccion_items i WHERE i.remision_id = _remision_id AND i.cantidad_surtida > 0)
       OR EXISTS (SELECT 1 FROM public.almacen_refacciones_movimientos m WHERE m.documento_id = _remision_id)) THEN
    RAISE EXCEPTION 'Ya surtió inventario (hay movimientos de kárdex con esa fecha): la fecha no se edita';
  END IF;

  PERFORM set_config('kit.permite_cambio_fecha', '1', true);
  IF _tipo = 'motocarro' THEN
    UPDATE public.remisiones SET fecha_remision = _fecha_nueva WHERE id = _remision_id;
  ELSE
    UPDATE public.remisiones_refacciones SET fecha_remision = _fecha_nueva WHERE id = _remision_id;
  END IF;
  PERFORM set_config('kit.permite_cambio_fecha', '', true);

  SELECT coalesce(nombre_completo, email) INTO v_nombre FROM public.profiles WHERE id = auth.uid();
  INSERT INTO public.remision_fecha_cambios (tipo, remision_id, folio, fecha_original, fecha_nueva, motivo, cambiado_por, nombre_usuario)
  VALUES (_tipo, _remision_id, v_folio, v_original, _fecha_nueva, trim(_motivo), auth.uid(), v_nombre);

  INSERT INTO public.avisos (area_destino, tipo, titulo, cuerpo, remision_id, remision_refaccion_id, folio_remision, datos,
                             creado_por, nombre_creador, requiere_respuesta, estado, es_prueba)
  VALUES ('administracion', 'cambio_fecha_remision', 'Cambió la fecha de la remisión ' || v_folio,
          'De ' || to_char(v_original, 'DD/MM/YYYY') || ' a ' || to_char(_fecha_nueva, 'DD/MM/YYYY') || '. Motivo: ' || trim(_motivo)
            || '. Las cuentas por cobrar y sus vencimientos NO se movieron.',
          CASE WHEN _tipo = 'motocarro' THEN _remision_id END, CASE WHEN _tipo = 'refacciones' THEN _remision_id END, v_folio,
          jsonb_build_object('fecha_original', v_original, 'fecha_nueva', _fecha_nueva),
          auth.uid(), v_nombre, false, 'pendiente', coalesce(v_prueba, false));

  RETURN jsonb_build_object('folio', v_folio, 'fecha_original', v_original, 'fecha_nueva', _fecha_nueva);
END;
$$;

REVOKE ALL ON FUNCTION public.cambiar_fecha_remision(text, uuid, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cambiar_fecha_remision(text, uuid, date, text) TO authenticated, service_role;

-- Verificación: tabla con RLS y 1 política, 2 triggers, función DEFINER con search_path fijo, anon sin nada.
SELECT
  (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.remision_fecha_cambios'::regclass) AS tabla_con_rls,
  (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND tablename = 'remision_fecha_cambios') AS politicas_tabla,
  (SELECT count(*) FROM pg_trigger WHERE tgname IN ('trg_remisiones_fecha_solo_funcion', 'trg_remisiones_refacciones_fecha_solo_funcion') AND NOT tgisinternal) AS triggers_fecha,
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'cambiar_fecha_remision' AND p.prosecdef
      AND EXISTS (SELECT 1 FROM unnest(p.proconfig) x WHERE x LIKE 'search_path=%')) AS funcion_definer_con_search_path,
  has_function_privilege('anon', 'public.cambiar_fecha_remision(text, uuid, date, text)', 'EXECUTE') AS anon_ejecuta,
  has_table_privilege('anon', 'public.remision_fecha_cambios', 'SELECT') AS anon_lee_tabla;

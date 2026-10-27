-- ============================================================================
-- Flujo de dinero: las etapas salen del PERFIL del usuario (decisión de Polo, 2026-10-27)
--
--   Perfil                  Etapa
--   ─────────────────────   ──────
--   Recepción de cobros     recibe
--   Cajera                  caja
--   Aplicación de cobranza  aplica
--
-- Una sola fuente de verdad: `usuario_perfiles_flujo`. `flujo_cap()` (lo que
-- consultan todos los RPC del flujo) lee de ahí y de ningún otro lado. La marca
-- anterior por persona (`flujo_capacidades`) se MIGRA a perfiles y se RETIRA,
-- junto con sus funciones, para no dejar dos formas de dar el mismo permiso.
--
-- · Un usuario puede tener varios perfiles; la separación de funciones sigue en
--   los RPC (por persona y por movimiento), aunque alguien tenga los tres.
-- · Retirar un perfil surte efecto al instante (flujo_cap consulta en vivo).
-- · Los movimientos no pertenecen a una persona sino a una COLA por etapa:
--   lo que alguien deja a medias lo continúa otra persona con el perfil.
-- · Quien ocupa el perfil ve solo la cola de su etapa (y lo que ella misma
--   trabajó). El libro general y la cobranza siguen cerrados por su propia RLS.
-- · Solo un administrador o administrador financiero asigna; todo cambio queda
--   en `usuario_perfiles_flujo_bitacora` (quién, a quién, antes, después, cuándo).
-- · Aislamiento de prueba: un usuario de prueba solo ve flujos de prueba y uno
--   real solo flujos reales (corrige la política de lectura anterior).
--
-- Depende de 20261012000001_flujo_dinero_tres_etapas. Idempotente.
-- Para el SQL editor de Supabase; NO usar `supabase db push`.
-- ============================================================================

DO $preflight$
BEGIN
  IF to_regclass('public.flujo_dinero') IS NULL THEN
    RAISE EXCEPTION 'No se modificó nada. Corre antes 20261012000001_flujo_dinero_tres_etapas.sql.';
  END IF;
  IF to_regprocedure('public.flujo_es_admin(uuid)') IS NULL OR to_regprocedure('public.es_usuario_prueba(uuid)') IS NULL THEN
    RAISE EXCEPTION 'No se modificó nada. Falta flujo_es_admin(uuid) o es_usuario_prueba(uuid).';
  END IF;
END $preflight$;

-- ── 1. Catálogo de perfiles (uno por etapa) ────────────────────────────────
CREATE TABLE IF NOT EXISTS public.perfiles_flujo (
  clave       text PRIMARY KEY,
  nombre      text NOT NULL,
  etapa       text NOT NULL UNIQUE CHECK (etapa IN ('recibe', 'caja', 'aplica')),
  descripcion text NOT NULL,
  orden       integer NOT NULL
);
INSERT INTO public.perfiles_flujo (clave, nombre, etapa, descripcion, orden) VALUES
  ('recepcion_cobros',   'Recepción de cobros',    'recibe', 'Registra el dinero que recibe (pago de cliente, reembolso) o la salida que entrega.', 1),
  ('cajera',             'Cajera',                 'caja',   'Confirma en caja o cuenta que el dinero entró o salió. Ve solo las cuentas y lo pendiente de caja.', 2),
  ('aplicacion_cobranza','Aplicación de cobranza', 'aplica', 'Reparte el cobro entre remisiones (el remanente queda a favor) o clasifica el reembolso.', 3)
ON CONFLICT (clave) DO UPDATE
  SET nombre = EXCLUDED.nombre, etapa = EXCLUDED.etapa, descripcion = EXCLUDED.descripcion, orden = EXCLUDED.orden;

-- ── 2. Perfiles por usuario ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.usuario_perfiles_flujo (
  user_id      uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  perfil       text NOT NULL REFERENCES public.perfiles_flujo(clave),
  asignado_por uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  asignado_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, perfil)
);
CREATE INDEX IF NOT EXISTS idx_usuario_perfiles_flujo_perfil ON public.usuario_perfiles_flujo (perfil);

-- ── 3. Bitácora de cambios de perfil (no se edita ni se borra) ─────────────
CREATE TABLE IF NOT EXISTS public.usuario_perfiles_flujo_bitacora (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id       uuid NOT NULL,
  actor_id         uuid,
  actor            text,
  origen           text NOT NULL CHECK (origen IN ('app', 'mati-admin', 'alta', 'migracion')),
  perfiles_antes   text[] NOT NULL,
  perfiles_despues text[] NOT NULL,
  es_prueba        boolean NOT NULL DEFAULT false,
  created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_perfiles_flujo_bitacora_usuario ON public.usuario_perfiles_flujo_bitacora (usuario_id, created_at DESC);

CREATE OR REPLACE FUNCTION public.perfiles_flujo_bitacora_inmutable()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'La bitácora de perfiles del flujo no se edita ni se borra.';
END;
$$;
DROP TRIGGER IF EXISTS trg_perfiles_flujo_bitacora_inmutable ON public.usuario_perfiles_flujo_bitacora;
CREATE TRIGGER trg_perfiles_flujo_bitacora_inmutable BEFORE UPDATE OR DELETE ON public.usuario_perfiles_flujo_bitacora
  FOR EACH ROW EXECUTE FUNCTION public.perfiles_flujo_bitacora_inmutable();

ALTER TABLE public.perfiles_flujo ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.usuario_perfiles_flujo ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.usuario_perfiles_flujo_bitacora ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.perfiles_flujo FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.usuario_perfiles_flujo FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.usuario_perfiles_flujo_bitacora FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.perfiles_flujo TO authenticated;
GRANT SELECT ON public.usuario_perfiles_flujo TO authenticated;
GRANT SELECT ON public.usuario_perfiles_flujo_bitacora TO authenticated;
GRANT ALL ON public.perfiles_flujo, public.usuario_perfiles_flujo, public.usuario_perfiles_flujo_bitacora TO service_role;

DROP POLICY IF EXISTS perfiles_flujo_leer ON public.perfiles_flujo;
CREATE POLICY perfiles_flujo_leer ON public.perfiles_flujo FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS usuario_perfiles_flujo_leer ON public.usuario_perfiles_flujo;
CREATE POLICY usuario_perfiles_flujo_leer ON public.usuario_perfiles_flujo FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.flujo_es_admin());
DROP POLICY IF EXISTS perfiles_flujo_bitacora_leer ON public.usuario_perfiles_flujo_bitacora;
CREATE POLICY perfiles_flujo_bitacora_leer ON public.usuario_perfiles_flujo_bitacora FOR SELECT TO authenticated
  USING (public.flujo_es_admin() AND es_prueba = public.es_usuario_prueba(auth.uid()));

-- ── 4. flujo_cap: la ÚNICA fuente de la etapa es el perfil ─────────────────
CREATE OR REPLACE FUNCTION public.flujo_cap(_cap text, _uid uuid DEFAULT auth.uid())
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT _uid IS NOT NULL AND public.usuario_activo(_uid)
     AND EXISTS (SELECT 1
                   FROM public.usuario_perfiles_flujo up
                   JOIN public.perfiles_flujo pf ON pf.clave = up.perfil
                  WHERE up.user_id = _uid AND pf.etapa = _cap)
$$;

-- ── 5. Migrar la marca por persona a perfiles y retirarla ──────────────────
DO $migrar$
DECLARE
  v_marcas integer;
  v_filas  integer;
BEGIN
  IF to_regclass('public.flujo_capacidades') IS NULL THEN RETURN; END IF;

  EXECUTE $q$SELECT (SELECT count(*) FROM public.flujo_capacidades WHERE recibe)
                   + (SELECT count(*) FROM public.flujo_capacidades WHERE caja)
                   + (SELECT count(*) FROM public.flujo_capacidades WHERE aplica)$q$ INTO v_marcas;

  EXECUTE $q$
    INSERT INTO public.usuario_perfiles_flujo (user_id, perfil, asignado_por, asignado_at)
    SELECT c.user_id, p.clave, c.updated_by, c.updated_at
      FROM public.flujo_capacidades c
      JOIN public.perfiles_flujo p
        ON (p.etapa = 'recibe' AND c.recibe) OR (p.etapa = 'caja' AND c.caja) OR (p.etapa = 'aplica' AND c.aplica)
    ON CONFLICT (user_id, perfil) DO NOTHING$q$;

  SELECT count(*) INTO v_filas FROM public.usuario_perfiles_flujo;
  IF v_filas < v_marcas THEN
    RAISE EXCEPTION 'La migración de capacidades a perfiles no cuadra (% marcas, % perfiles). No se retiró nada.', v_marcas, v_filas;
  END IF;

  INSERT INTO public.usuario_perfiles_flujo_bitacora (usuario_id, actor_id, actor, origen, perfiles_antes, perfiles_despues, es_prueba)
  SELECT up.user_id, NULL, 'migración de capacidades a perfiles', 'migracion', '{}',
         array_agg(up.perfil ORDER BY up.perfil), public.es_usuario_prueba(up.user_id)
    FROM public.usuario_perfiles_flujo up
   GROUP BY up.user_id;

  EXECUTE 'DROP TABLE public.flujo_capacidades';
END $migrar$;

DROP FUNCTION IF EXISTS public.flujo_asignar_capacidad(uuid, text, boolean);
DROP FUNCTION IF EXISTS public.flujo_listar_capacidades();

-- ── 6. Asignar, cambiar y retirar perfiles ─────────────────────────────────
-- Núcleo: fija el conjunto COMPLETO de perfiles de una persona y deja bitácora.
-- Solo lo llaman las Edge Functions (service_role, en el alta y en MATI Admin)
-- y la función de la app (que antes comprueba que quien llama sea administrador).
CREATE OR REPLACE FUNCTION public.perfiles_flujo_fijar(
  _actor_id uuid, _actor text, _origen text, _user_id uuid, _perfiles text[]
) RETURNS text[] LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_antes   text[];
  v_nuevos  text[];
BEGIN
  IF _origen NOT IN ('app', 'mati-admin', 'alta') THEN RAISE EXCEPTION 'Origen inválido: %', _origen; END IF;
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = _user_id) THEN RAISE EXCEPTION 'No existe el usuario'; END IF;

  SELECT coalesce(array_agg(DISTINCT p ORDER BY p), '{}') INTO v_nuevos FROM unnest(coalesce(_perfiles, '{}')) p;
  IF EXISTS (SELECT 1 FROM unnest(v_nuevos) p WHERE p NOT IN (SELECT clave FROM public.perfiles_flujo)) THEN
    RAISE EXCEPTION 'Perfil inválido. Los perfiles del flujo son: %',
      (SELECT string_agg(clave, ', ' ORDER BY orden) FROM public.perfiles_flujo);
  END IF;

  SELECT coalesce(array_agg(perfil ORDER BY perfil), '{}') INTO v_antes FROM public.usuario_perfiles_flujo WHERE user_id = _user_id;
  IF v_antes = v_nuevos THEN RETURN v_antes; END IF;

  DELETE FROM public.usuario_perfiles_flujo WHERE user_id = _user_id AND NOT (perfil = ANY (v_nuevos));
  INSERT INTO public.usuario_perfiles_flujo (user_id, perfil, asignado_por)
    SELECT _user_id, p, _actor_id FROM unnest(v_nuevos) p ON CONFLICT (user_id, perfil) DO NOTHING;

  INSERT INTO public.usuario_perfiles_flujo_bitacora (usuario_id, actor_id, actor, origen, perfiles_antes, perfiles_despues, es_prueba)
  VALUES (_user_id, _actor_id, _actor, _origen, v_antes, v_nuevos, public.es_usuario_prueba(_user_id));
  RETURN v_nuevos;
END;
$$;

-- App: un perfil a la vez (marcar o quitar).
CREATE OR REPLACE FUNCTION public.flujo_asignar_perfil(_user_id uuid, _perfil text, _valor boolean)
RETURNS text[] LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_actuales text[];
BEGIN
  IF NOT public.flujo_es_admin() THEN
    RAISE EXCEPTION 'Sólo un administrador o administrador financiero asigna, cambia o retira los perfiles del flujo de dinero';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.perfiles_flujo WHERE clave = _perfil) THEN RAISE EXCEPTION 'Perfil inválido: %', _perfil; END IF;
  SELECT coalesce(array_agg(perfil), '{}') INTO v_actuales FROM public.usuario_perfiles_flujo WHERE user_id = _user_id;
  IF coalesce(_valor, false) THEN v_actuales := array_append(v_actuales, _perfil);
  ELSE v_actuales := array_remove(v_actuales, _perfil); END IF;
  RETURN public.perfiles_flujo_fijar(auth.uid(), public.flujo_nombre(auth.uid()), 'app', _user_id, v_actuales);
END;
$$;

CREATE OR REPLACE FUNCTION public.flujo_catalogo_perfiles()
RETURNS TABLE (clave text, nombre text, etapa text, descripcion text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p.clave, p.nombre, p.etapa, p.descripcion FROM public.perfiles_flujo p
   WHERE auth.uid() IS NOT NULL ORDER BY p.orden
$$;

-- Quién tiene qué perfil. Solo administradores; cada quien ve solo su "clase"
-- (reales con reales, de prueba con de prueba).
CREATE OR REPLACE FUNCTION public.flujo_listar_perfiles()
RETURNS TABLE (user_id uuid, nombre text, perfiles text[])
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.flujo_es_admin() THEN RAISE EXCEPTION 'Sólo un administrador ve quién ocupa cada perfil'; END IF;
  RETURN QUERY
    SELECT p.id, coalesce(nullif(btrim(p.nombre_completo), ''), p.id::text),
           coalesce((SELECT array_agg(up.perfil ORDER BY up.perfil) FROM public.usuario_perfiles_flujo up WHERE up.user_id = p.id), '{}')
      FROM public.profiles p
     WHERE public.usuario_activo(p.id)
       AND public.es_usuario_prueba(p.id) = public.es_usuario_prueba(auth.uid())
     ORDER BY 2;
END;
$$;

-- Lo que ve la propia persona (el front decide menú y pantallas con esto; la base decide siempre).
CREATE OR REPLACE FUNCTION public.flujo_mis_capacidades()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT jsonb_build_object(
    'recibe', public.flujo_cap('recibe'), 'caja', public.flujo_cap('caja'), 'aplica', public.flujo_cap('aplica'),
    'perfiles', coalesce((SELECT jsonb_agg(up.perfil ORDER BY up.perfil) FROM public.usuario_perfiles_flujo up WHERE up.user_id = auth.uid()), '[]'::jsonb))
$$;

-- ── 7. Cada quien ve solo su cola; prueba y real no se mezclan ─────────────
-- Recepción: lo que ella registró. Cajera: lo pendiente de caja y lo que ella
-- confirmó. Aplicación: lo pendiente de aplicar y lo que ella aplicó. Si alguien
-- deja a medias un movimiento, lo ve y lo continúa cualquiera con el perfil.
DROP POLICY IF EXISTS flujo_dinero_leer ON public.flujo_dinero;
CREATE POLICY flujo_dinero_leer ON public.flujo_dinero FOR SELECT TO authenticated
  USING (
    es_prueba = public.es_usuario_prueba(auth.uid())
    AND (
      public.flujo_es_admin()
      OR (public.flujo_cap('recibe') AND recibido_por = auth.uid())
      OR (public.flujo_cap('caja')   AND (etapa = 'RECIBIDO' OR caja_por = auth.uid()))
      OR (public.flujo_cap('aplica') AND (etapa = 'EN_CAJA'  OR aplicado_por = auth.uid()))
    )
  );

-- Un usuario real no opera movimientos de prueba (el de prueba ya lo frena exigir_dato_prueba).
CREATE OR REPLACE FUNCTION public.flujo_dinero_mismo_modo()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NOT NULL AND NEW.es_prueba AND NOT public.es_usuario_prueba(auth.uid()) THEN
    RAISE EXCEPTION 'Este movimiento (%) es de prueba y tu usuario es real: no se mezclan.', NEW.folio;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_flujo_dinero_mismo_modo ON public.flujo_dinero;
CREATE TRIGGER trg_flujo_dinero_mismo_modo BEFORE UPDATE ON public.flujo_dinero
  FOR EACH ROW EXECUTE FUNCTION public.flujo_dinero_mismo_modo();

-- ── 8. Permisos: nada abierto a anon ───────────────────────────────────────
REVOKE ALL ON FUNCTION public.perfiles_flujo_bitacora_inmutable() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.flujo_dinero_mismo_modo() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.perfiles_flujo_fijar(uuid, text, text, uuid, text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.perfiles_flujo_fijar(uuid, text, text, uuid, text[]) TO service_role;
REVOKE ALL ON FUNCTION public.flujo_asignar_perfil(uuid, text, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_catalogo_perfiles() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_listar_perfiles() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_mis_capacidades() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.flujo_cap(text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_asignar_perfil(uuid, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.flujo_catalogo_perfiles() TO authenticated;
GRANT EXECUTE ON FUNCTION public.flujo_listar_perfiles() TO authenticated;
GRANT EXECUTE ON FUNCTION public.flujo_mis_capacidades() TO authenticated;
GRANT EXECUTE ON FUNCTION public.flujo_cap(text, uuid) TO authenticated;

-- ── 9. Postflight ──────────────────────────────────────────────────────────
DO $postflight$
BEGIN
  IF to_regclass('public.flujo_capacidades') IS NOT NULL THEN RAISE EXCEPTION 'Quedó la marca anterior flujo_capacidades: habría dos fuentes de permiso.'; END IF;
  IF to_regprocedure('public.flujo_asignar_capacidad(uuid,text,boolean)') IS NOT NULL
     OR to_regprocedure('public.flujo_listar_capacidades()') IS NOT NULL THEN
    RAISE EXCEPTION 'Quedó una función de capacidades por persona.';
  END IF;
  IF (SELECT count(*) FROM public.perfiles_flujo) <> 3 THEN RAISE EXCEPTION 'El catálogo debe tener tres perfiles.'; END IF;
  IF has_function_privilege('anon', 'public.perfiles_flujo_fijar(uuid,text,text,uuid,text[])', 'execute')
     OR has_function_privilege('authenticated', 'public.perfiles_flujo_fijar(uuid,text,text,uuid,text[])', 'execute') THEN
    RAISE EXCEPTION 'perfiles_flujo_fijar no debe estar abierta a anon ni authenticated.';
  END IF;
END $postflight$;

-- Verificación: perfiles por etapa y quién ocupa cada uno.
SELECT pf.nombre AS perfil, pf.etapa, count(up.user_id) AS personas
  FROM public.perfiles_flujo pf
  LEFT JOIN public.usuario_perfiles_flujo up ON up.perfil = pf.clave
 GROUP BY pf.nombre, pf.etapa, pf.orden ORDER BY pf.orden;

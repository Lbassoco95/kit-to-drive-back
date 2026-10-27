-- ============================================================================
-- PAQUETE 3 · 2 de 3: ELIMINAR una remisión (solo super admin, solo por función, solo con el modo prueba encendido)
--
-- Hallazgo: `Remisiones.tsx` borra desde el navegador, en dos pasos no atómicos (INSERT en `bitacora_eliminaciones` y
-- luego DELETE), con las políticas «borrar remisiones admin» y «admin de area borra remisiones». Eso deja filas
-- huérfanas de dinero (`cuentas_por_cobrar.remision_id` y `movimientos_financieros.remision_id` quedan en NULL), libera
-- unidades sin restablecer su estado de entrega y pierde la bitácora de la remisión.
--
-- Decisiones de Polo (26 oct 2026): D-A1 = A (interruptor global, migración anterior; NACE APAGADO: Dirección lo enciende
-- cuando lo necesite), D-A2 = A (se cierran los DELETE directos de `remisiones`: solo el super admin elimina, y solo por esta
-- función), D-A3 = pendiente de confirmar (qué dato es «factura»; aquí se usa `movimientos_financieros.tiene_factura`/`factura_uuid`/
-- `factura_folio`, y además se rechaza CUALQUIER movimiento financiero ligado, así que la regla no depende de esa confirmación).
-- Una remisión de refacciones que ya surtió inventario se CANCELA, no se elimina (acordado).
--
-- Revisión independiente (26 oct): se corrigieron el criterio de «pago» de motocarros (`remisiones.pagado` vale true en las 93 remisiones
-- de producción por su valor por omisión: ya NO cuenta; cuentan el comprobante de pago, la cuenta por cobrar y los movimientos financieros),
-- las condiciones de carrera (se bloquean unidades y partidas antes de verificar), el folio con espacios, la copia de las unidades
-- (fila completa), las solicitudes de firma (si existen, se cancela, no se elimina) y los avisos (entran en la copia).
--
-- `eliminar_remision(_tipo, _remision_id, _folio_confirmacion, _motivo)`: SECURITY DEFINER, search_path fijo. En UNA transacción:
-- exige super admin, modo prueba global encendido, motivo (≥ 10 caracteres) y el folio escrito igual al de la remisión;
-- RECHAZA si tiene comprobante de pago, pago (refacciones), cuenta por cobrar, movimiento financiero o factura, solicitud de firma,
-- entrega confirmada, cobranza (refacciones), correcciones, o inventario surtido (esas se cancelan, no se eliminan);
-- guarda la COPIA de la remisión, sus partidas, unidades (fila completa), bitácora, órdenes, eventos y avisos en `bitacora_eliminaciones`,
-- y un renglón en `bitacora_eventos`; deja libres las unidades (remision_id = NULL, estatus_entrega = 'NO_APLICA': el mismo efecto sobre la
-- unidad que `desasignar_motocarro_de_remision`, que además exige otro permiso y recalcula el estatus de una remisión que aquí se borra);
-- borra, y comprueba contra las llaves foráneas que no quedó ninguna fila apuntando a la remisión.
-- Las cantidades bloqueadas de refacciones se liberan solas al borrar las partidas (el apartado se calcula de ellas).
--
-- Se cierran los DELETE directos de `remisiones` (dos políticas y el privilegio) y se revoca el privilegio DELETE de `authenticated` en
-- `remisiones_refacciones` (no había política que lo permitiera). NO se cierran, a propósito: las políticas DELETE de `motocarros` y de
-- `remision_items` (la edición de remisiones borra partidas con ellas), `service_role`, y `reiniciar_datos_prueba_compras` (solo borra filas
-- marcadas `es_prueba`; excepción documentada).
--
-- Si falta una columna que la función usa (por ejemplo en una base construida solo con las migraciones, donde `remisiones.comprobante_pago_url`
-- viene del script suelto `fix_remisiones_columns.sql`), la migración ABORTA con un mensaje claro en vez de crear una función que falle al usarla.
-- Idempotente. Reversa: supabase/reversas/20261109000002_paquete3_eliminar_remision_reversa.sql
-- ============================================================================
DO $$
DECLARE
  v_faltan text;
BEGIN
  SELECT string_agg(r.tabla || '.' || r.columna, ', ') INTO v_faltan
    FROM (VALUES ('remisiones', 'comprobante_pago_url'), ('remisiones', 'folio_remision'),
                 ('movimientos_financieros', 'remision_id'), ('movimientos_financieros', 'tiene_factura'),
                 ('movimientos_financieros', 'factura_uuid'), ('movimientos_financieros', 'factura_folio'),
                 ('cuentas_por_cobrar', 'remision_id'), ('motocarros', 'remision_id'), ('motocarros', 'estatus_entrega'),
                 ('crm_oportunidades', 'remision_id'), ('firmas_solicitudes', 'entidad_id'),
                 ('remisiones_refacciones', 'pagado'), ('remisiones_refacciones', 'evidencia_pago_path'),
                 ('remisiones_refacciones', 'pago_conciliado'), ('remisiones_refacciones', 'entregada_at')) AS r(tabla, columna)
   WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns c
                      WHERE c.table_schema = 'public' AND c.table_name = r.tabla AND c.column_name = r.columna);
  IF v_faltan IS NOT NULL THEN
    RAISE EXCEPTION 'Esta migración necesita columnas que no existen en esta base: %. No se aplica nada.', v_faltan;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.eliminar_remision(_tipo text, _remision_id uuid, _folio_confirmacion text, _motivo text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_folio text;
  v_snap jsonb;
  v_unidades integer := 0;
  v_unidades_total integer := 0;
  v_tabla regclass;
  v_nombre text;
  fk record;
  v_quedan bigint;
BEGIN
  IF auth.uid() IS NULL OR NOT public.es_super_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Solo un super admin puede eliminar remisiones' USING ERRCODE = '42501';
  END IF;
  IF _tipo IS NULL OR _tipo NOT IN ('motocarro', 'refacciones') THEN
    RAISE EXCEPTION 'Tipo de remisión no válido (motocarro o refacciones)';
  END IF;
  IF NOT public.modo_prueba_global_activo() THEN
    RAISE EXCEPTION 'El modo prueba está apagado: una remisión ya no se elimina, se cancela';
  END IF;
  IF nullif(trim(_motivo), '') IS NULL OR char_length(trim(_motivo)) < 10 THEN
    RAISE EXCEPTION 'Escribe el motivo de la eliminación (mínimo 10 caracteres)';
  END IF;

  IF _tipo = 'motocarro' THEN
    v_tabla := 'public.remisiones'::regclass;
    SELECT folio_remision INTO v_folio FROM public.remisiones WHERE id = _remision_id FOR UPDATE;
  ELSE
    v_tabla := 'public.remisiones_refacciones'::regclass;
    SELECT folio INTO v_folio FROM public.remisiones_refacciones WHERE id = _remision_id FOR UPDATE;
  END IF;
  IF NOT FOUND THEN RAISE EXCEPTION 'No se encontró la remisión'; END IF;
  IF trim(coalesce(_folio_confirmacion, '')) <> trim(coalesce(v_folio, '')) THEN
    RAISE EXCEPTION 'El folio escrito no coincide con el de la remisión';
  END IF;

  IF EXISTS (SELECT 1 FROM public.firmas_solicitudes f WHERE f.entidad_tipo = 'remision' AND f.entidad_id = _remision_id) THEN
    RAISE EXCEPTION 'Tiene una solicitud de firma (documento firmado o en trámite): se cancela, no se elimina';
  END IF;

  IF _tipo = 'motocarro' THEN
    -- Se bloquean las unidades ANTES de verificar: marcar una unidad «ENTREGADA» no toca remision_id, así que sin este bloqueo
    -- podría confirmarse una entrega entre la verificación y la liberación.
    PERFORM 1 FROM public.motocarros m WHERE m.remision_id = _remision_id FOR UPDATE;
    SELECT count(*) INTO v_unidades_total FROM public.motocarros m WHERE m.remision_id = _remision_id;
    IF EXISTS (SELECT 1 FROM public.remisiones r WHERE r.id = _remision_id AND r.comprobante_pago_url IS NOT NULL) THEN
      RAISE EXCEPTION 'Tiene un comprobante de pago: se cancela, no se elimina';
    END IF;
    IF EXISTS (SELECT 1 FROM public.movimientos_financieros m WHERE m.remision_id = _remision_id
                AND (m.tiene_factura IS TRUE OR m.factura_uuid IS NOT NULL OR m.factura_folio IS NOT NULL)) THEN
      RAISE EXCEPTION 'Tiene factura: se cancela, no se elimina';
    END IF;
    IF EXISTS (SELECT 1 FROM public.cuentas_por_cobrar c WHERE c.remision_id = _remision_id) THEN
      RAISE EXCEPTION 'Tiene una cuenta por cobrar: se cancela, no se elimina';
    END IF;
    IF EXISTS (SELECT 1 FROM public.movimientos_financieros m WHERE m.remision_id = _remision_id) THEN
      RAISE EXCEPTION 'Tiene movimientos financieros (cobranza): se cancela, no se elimina';
    END IF;
    IF EXISTS (SELECT 1 FROM public.motocarros m WHERE m.remision_id = _remision_id AND m.estatus_entrega = 'ENTREGADA') THEN
      RAISE EXCEPTION 'Tiene una entrega confirmada: se cancela, no se elimina';
    END IF;
    v_snap := jsonb_build_object(
      'tipo', 'motocarro',
      'remision', (SELECT to_jsonb(r) FROM public.remisiones r WHERE r.id = _remision_id),
      'partidas', (SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY i.orden_linea), '[]'::jsonb) FROM public.remision_items i WHERE i.remision_id = _remision_id),
      'unidades', (SELECT coalesce(jsonb_agg(to_jsonb(m) ORDER BY m.orden_armado), '[]'::jsonb) FROM public.motocarros m WHERE m.remision_id = _remision_id),
      'bitacora', (SELECT coalesce(jsonb_agg(to_jsonb(b) ORDER BY b.created_at), '[]'::jsonb) FROM public.remisiones_bitacora b WHERE b.remision_id = _remision_id),
      'avisos', (SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.created_at), '[]'::jsonb) FROM public.avisos a WHERE a.remision_id = _remision_id),
      'oportunidades_ligadas', (SELECT coalesce(jsonb_agg(o.id), '[]'::jsonb) FROM public.crm_oportunidades o WHERE o.remision_id = _remision_id));
    UPDATE public.motocarros SET remision_id = NULL, estatus_entrega = 'NO_APLICA'
     WHERE remision_id = _remision_id AND estatus_entrega <> 'ENTREGADA';
    GET DIAGNOSTICS v_unidades = ROW_COUNT;
    IF v_unidades <> v_unidades_total THEN
      RAISE EXCEPTION 'Una unidad cambió mientras se eliminaba la remisión; no se elimina nada. Vuelve a intentarlo';
    END IF;
  ELSE
    -- Se bloquean las partidas ANTES de verificar: surtir una partida no bloquea la remisión padre.
    PERFORM 1 FROM public.remision_refaccion_items i WHERE i.remision_id = _remision_id FOR UPDATE;
    IF EXISTS (SELECT 1 FROM public.remisiones_refacciones r WHERE r.id = _remision_id
                AND (r.pagado IS TRUE OR r.pagado_at IS NOT NULL OR r.evidencia_pago_path IS NOT NULL OR r.pago_conciliado IS TRUE)) THEN
      RAISE EXCEPTION 'Tiene un pago registrado: se cancela, no se elimina';
    END IF;
    IF EXISTS (SELECT 1 FROM public.cobranza_aplicaciones a WHERE a.remision_id = _remision_id)
       OR EXISTS (SELECT 1 FROM public.cobranza_saldos_favor s WHERE s.remision_origen_id = _remision_id)
       OR EXISTS (SELECT 1 FROM public.cobranza_solicitudes_saldo s WHERE s.remision_id = _remision_id) THEN
      RAISE EXCEPTION 'Tiene cobranza aplicada: se cancela, no se elimina';
    END IF;
    IF EXISTS (SELECT 1 FROM public.remisiones_refacciones r WHERE r.id = _remision_id AND (r.entregada_at IS NOT NULL OR r.etapa = 'entregada')) THEN
      RAISE EXCEPTION 'Tiene una entrega confirmada: se cancela, no se elimina';
    END IF;
    IF EXISTS (SELECT 1 FROM public.remision_refaccion_correcciones c WHERE c.remision_id = _remision_id) THEN
      RAISE EXCEPTION 'Tiene correcciones registradas: se cancela, no se elimina';
    END IF;
    IF EXISTS (SELECT 1 FROM public.remision_refaccion_items i WHERE i.remision_id = _remision_id AND i.cantidad_surtida > 0)
       OR EXISTS (SELECT 1 FROM public.almacen_refacciones_movimientos m WHERE m.documento_id = _remision_id) THEN
      RAISE EXCEPTION 'Ya surtió inventario (hay movimientos de kárdex): se cancela, no se elimina';
    END IF;
    v_snap := jsonb_build_object(
      'tipo', 'refacciones',
      'remision', (SELECT to_jsonb(r) FROM public.remisiones_refacciones r WHERE r.id = _remision_id),
      'partidas', (SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY i.created_at), '[]'::jsonb) FROM public.remision_refaccion_items i WHERE i.remision_id = _remision_id),
      'ordenes', (SELECT coalesce(jsonb_agg(to_jsonb(o) ORDER BY o.created_at), '[]'::jsonb) FROM public.remision_refaccion_ordenes o WHERE o.remision_id = _remision_id),
      'eventos', (SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY e.created_at), '[]'::jsonb) FROM public.remision_refaccion_eventos e WHERE e.remision_id = _remision_id),
      'avisos', (SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.created_at), '[]'::jsonb) FROM public.avisos a WHERE a.remision_refaccion_id = _remision_id));
  END IF;

  SELECT coalesce(nombre_completo, email) INTO v_nombre FROM public.profiles WHERE id = auth.uid();
  INSERT INTO public.bitacora_eliminaciones (tabla, registro_id, eliminado_por, nombre_usuario, motivo, datos_eliminados)
  VALUES (CASE WHEN _tipo = 'motocarro' THEN 'remisiones' ELSE 'remisiones_refacciones' END,
          _remision_id, auth.uid(), v_nombre, trim(_motivo), v_snap);
  INSERT INTO public.bitacora_eventos (usuario_id, modulo, accion, entidad_tipo, entidad_id, datos_antes, datos_despues)
  VALUES (auth.uid(), 'remisiones', 'eliminar_remision', CASE WHEN _tipo = 'motocarro' THEN 'remisiones' ELSE 'remisiones_refacciones' END,
          _remision_id, jsonb_build_object('folio', v_folio), jsonb_build_object('motivo', trim(_motivo), 'unidades_liberadas', v_unidades));

  IF _tipo = 'motocarro' THEN
    DELETE FROM public.remisiones WHERE id = _remision_id;
  ELSE
    DELETE FROM public.remisiones_refacciones WHERE id = _remision_id;
  END IF;

  -- Cinturón y tirantes: las llaves foráneas ya resuelven CASCADE / SET NULL y las NO ACTION abortan el DELETE; esto confirma que
  -- no quedó ninguna fila con llave foránea apuntando a la remisión. (Las tablas SIN llave foránea no se pueden descubrir así:
  -- `firmas_solicitudes` se rechaza arriba y `remision_fecha_cambios` conserva su historial a propósito.)
  FOR fk IN
    SELECT c.conrelid::regclass AS tabla, a.attname AS columna
      FROM pg_constraint c
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
     WHERE c.contype = 'f' AND c.confrelid = v_tabla
  LOOP
    EXECUTE format('SELECT count(*) FROM %s WHERE %I = $1', fk.tabla, fk.columna) INTO v_quedan USING _remision_id;
    IF v_quedan > 0 THEN
      RAISE EXCEPTION 'Quedaron % fila(s) en % que apuntan a la remisión eliminada; no se elimina nada', v_quedan, fk.tabla;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('folio', v_folio, 'tipo', _tipo, 'unidades_liberadas', v_unidades, 'copia_en_bitacora', true);
END;
$$;

REVOKE ALL ON FUNCTION public.eliminar_remision(text, uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.eliminar_remision(text, uuid, text, text) TO authenticated, service_role;

-- Se cierran los DELETE directos de `remisiones` y el privilegio de `remisiones_refacciones` (donde ninguna política lo permitía).
DROP POLICY IF EXISTS "borrar remisiones admin" ON public.remisiones;
DROP POLICY IF EXISTS "admin de area borra remisiones" ON public.remisiones;
REVOKE DELETE ON TABLE public.remisiones FROM authenticated;
REVOKE DELETE ON TABLE public.remisiones_refacciones FROM authenticated;

-- Verificación: función DEFINER con search_path fijo, anon sin EXECUTE, ninguna política DELETE en remisiones, sin privilegio DELETE en las dos tablas.
SELECT
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'eliminar_remision' AND p.prosecdef
      AND EXISTS (SELECT 1 FROM unnest(p.proconfig) x WHERE x LIKE 'search_path=%')) AS funcion_definer_con_search_path,
  has_function_privilege('anon', 'public.eliminar_remision(text, uuid, text, text)', 'EXECUTE') AS anon_ejecuta,
  (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND tablename = 'remisiones' AND cmd = 'DELETE') AS politicas_delete_remisiones,
  has_table_privilege('authenticated', 'public.remisiones', 'DELETE') AS authenticated_puede_delete_remisiones,
  has_table_privilege('authenticated', 'public.remisiones_refacciones', 'DELETE') AS authenticated_puede_delete_refacciones;

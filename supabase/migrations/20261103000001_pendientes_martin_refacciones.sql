-- ============================================================================
-- Pendientes de Martín (2026-11-03) — Refacciones
-- Fecha: 2026-11-03
--
-- 1. Vendedores sólo ven SUS remisiones de refacciones.
--    `puede_leer_remision_refaccion` terminaba con
--    `RETURN _area IN (..., 'comercial')`: cualquier usuario del área
--    Comercial (incluido el vendedor) leía TODAS las remisiones, sus partidas
--    y sus eventos. Ahora Comercial sólo lee las propias (vendedor o quien la
--    capturó), y las ven completas el supervisor/administrador de Comercial y
--    las administrativas de Comercial (igual que en motocarros).
--    Direccion, Administración y Almacén/Logística siguen igual.
--
-- 2. Tipo de pago «Crédito» en remisiones de refacciones
--    (anticipado / contra entrega / crédito). La tabla `remisiones` de
--    motocarros ya lo acepta en producción; aquí se abre en refacciones:
--    CHECK, crear_remision_refacciones y actualizar_envio_remision_refaccion.
--    Una remisión a crédito nace NO pagada (se cobra por Cobranza).
--
-- 3. Editar la fecha de la remisión de refacciones:
--    actualizar_envio_remision_refaccion acepta `fecha_remision`
--    (no futura; las históricas no se tocan).
--
-- 4. Eliminar por completo una remisión de refacciones:
--    eliminar_remision_refacciones(_remision_id, _motivo, _devolver_inventario).
--    Sólo admin de Comercial / global. Si se pide, regresa al inventario las
--    piezas que la remisión tiene surtidas (movimiento «devolución», el
--    kárdex no se rompe), deja bitácora y NO borra remisiones reales ya
--    entregadas, históricas ni con cobros aplicados (esas se cancelan o se
--    anulan).
--
-- 5. Reporte de ventas de refacciones: reporte_ventas_refacciones(...) por
--    periodo, almacén, vendedor y varios artículos a la vez (sólo lectura).
--
-- 6. Eliminar un movimiento financiero que viene del flujo de dinero: la llave
--    flujo_dinero_movimiento_id_fkey pasa a ON DELETE SET NULL (antes bloqueaba).
--
-- ADVERTENCIA: idempotente, para el SQL editor de Supabase. NO usar
-- `supabase db push`. Todo es CREATE OR REPLACE / reemplazo de constraint:
-- no borra ni modifica datos.
--
-- Para revertir (si hiciera falta):
--   * puede_leer_remision_refaccion: volver a la definición de
--     20260925000001 (sin la excepción de Comercial).
--   * ALTER TABLE remisiones_refacciones DROP CONSTRAINT
--     remisiones_refacciones_tipo_pago_check, y recrearlo con
--     ('anticipado','contra_entrega') (sólo si no hay remisiones a crédito).
--   * flujo_dinero_movimiento_id_fkey: recrearla sin ON DELETE (NO ACTION).
--   * DROP FUNCTION eliminar_remision_refacciones(uuid, text, boolean);
--     DROP FUNCTION reporte_ventas_refacciones(date, date, boolean);
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := '{}';
BEGIN
  IF to_regclass('public.remisiones_refacciones') IS NULL THEN _faltan := _faltan || 'tabla remisiones_refacciones'::text; END IF;
  IF to_regclass('public.remision_refaccion_items') IS NULL THEN _faltan := _faltan || 'tabla remision_refaccion_items'::text; END IF;
  IF to_regclass('public.almacen_refacciones_movimientos') IS NULL THEN _faltan := _faltan || 'tabla almacen_refacciones_movimientos'::text; END IF;
  IF to_regclass('public.flujo_dinero') IS NULL THEN _faltan := _faltan || 'tabla flujo_dinero'::text; END IF;
  IF to_regclass('public.movimientos_financieros') IS NULL THEN _faltan := _faltan || 'tabla movimientos_financieros'::text; END IF;
  IF to_regclass('public.bitacora_eliminaciones') IS NULL THEN _faltan := _faltan || 'tabla bitacora_eliminaciones'::text; END IF;
  IF to_regprocedure('public.es_administrativo_comercial(uuid)') IS NULL THEN _faltan := _faltan || 'función es_administrativo_comercial'::text; END IF;
  IF to_regprocedure('public.es_admin_area(uuid,public.user_area)') IS NULL THEN _faltan := _faltan || 'función es_admin_area'::text; END IF;
  IF to_regprocedure('public.es_admin_global(uuid)') IS NULL THEN _faltan := _faltan || 'función es_admin_global'::text; END IF;
  IF to_regprocedure('public.rol_comercial(uuid)') IS NULL THEN _faltan := _faltan || 'función rol_comercial'::text; END IF;
  IF to_regprocedure('public.puede_ver_almacen_refacciones(uuid)') IS NULL THEN _faltan := _faltan || 'función puede_ver_almacen_refacciones'::text; END IF;
  IF to_regprocedure('public._mover_inventario_refaccion(uuid,text,integer,date,text,text,uuid,text,text,text,uuid,numeric,boolean)') IS NULL THEN _faltan := _faltan || 'función _mover_inventario_refaccion'::text; END IF;
  IF to_regprocedure('public.importe_partida_refaccion(numeric,integer,numeric,numeric)') IS NULL THEN _faltan := _faltan || 'función importe_partida_refaccion'::text; END IF;
  IF to_regprocedure('public.puede_leer_compras_inventario(uuid)') IS NULL THEN _faltan := _faltan || 'función puede_leer_compras_inventario'::text; END IF;
  IF to_regprocedure('public.es_usuario_prueba(uuid)') IS NULL THEN _faltan := _faltan || 'función es_usuario_prueba'::text; END IF;
  IF to_regprocedure('public.es_vendedor_activo(uuid)') IS NULL THEN _faltan := _faltan || 'función es_vendedor_activo'::text; END IF;
  IF to_regprocedure('public.stock_bloqueado_producto(uuid)') IS NULL THEN _faltan := _faltan || 'función stock_bloqueado_producto'::text; END IF;
  IF to_regprocedure('public.puede_capturar_refacciones(uuid)') IS NULL THEN _faltan := _faltan || 'función puede_capturar_refacciones'::text; END IF;
  IF to_regprocedure('public.compras_supervisa_remisiones(uuid)') IS NULL THEN _faltan := _faltan || 'función compras_supervisa_remisiones'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema='public' AND table_name='remisiones_refacciones' AND column_name='es_historica') THEN
    _faltan := _faltan || 'columna remisiones_refacciones.es_historica'::text;
  END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ', ');
  END IF;
END;
$preflight$;

-- ── 1. Vendedores sólo ven sus remisiones de refacciones ────────────────────
CREATE OR REPLACE FUNCTION public.puede_leer_remision_refaccion(_remision_id uuid, _user_id uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  _rol text; _area text; _vendedor uuid; _creador uuid;
BEGIN
  IF _user_id IS NULL OR _remision_id IS NULL THEN RETURN false; END IF;
  IF EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = _user_id AND p.activo = false) THEN RETURN false; END IF;

  SELECT r.vendedor_id, r.created_by INTO _vendedor, _creador
    FROM public.remisiones_refacciones r WHERE r.id = _remision_id;
  IF NOT FOUND THEN RETURN false; END IF;

  IF public.puede_ver_almacen_refacciones(_user_id) THEN RETURN true; END IF;
  -- Lo propio: la remisión de la que es vendedor o que él capturó.
  IF _vendedor = _user_id OR _creador = _user_id THEN RETURN true; END IF;

  _rol := public.rol_comercial(_user_id);
  IF _rol IN ('global', 'supervisor') THEN RETURN true; END IF;
  -- Las administrativas de Comercial ven toda la bandeja (lectura).
  IF public.es_administrativo_comercial(_user_id) THEN RETURN true; END IF;

  SELECT ur.area::text INTO _area FROM public.user_roles ur WHERE ur.user_id = _user_id LIMIT 1;
  -- Comercial (vendedor/operador) YA NO está en la lista: sólo ve lo suyo.
  RETURN _area IN ('direccion', 'administracion', 'almacen_logistica');
END;
$$;

-- ── 2. Tipo de pago «crédito» en refacciones ────────────────────────────────
ALTER TABLE public.remisiones_refacciones DROP CONSTRAINT IF EXISTS remisiones_refacciones_tipo_pago_check;
ALTER TABLE public.remisiones_refacciones
  ADD CONSTRAINT remisiones_refacciones_tipo_pago_check
  CHECK (tipo_pago IS NULL OR tipo_pago IN ('anticipado', 'contra_entrega', 'credito'));

CREATE OR REPLACE FUNCTION public.crear_remision_refacciones(
  _cliente_id uuid, _notas text, _nombre_vendedor text, _items jsonb, _envio jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
declare
  v_prod uuid;
  v_cant integer;
  v_stock integer;
  v_disp integer;
  v_codigo text;
  v_id uuid;
  v_folio text;
  v_seq integer;
  v_nombre text;
  v_lineas integer := 0;
  v_tipo text;
  v_pago text;
  v_forma text;
  v_dir text;
  v_desc numeric;
  v_vendedor uuid;
  v_rol text;
  v_detalle text;
begin
  if not public.puede_capturar_refacciones() then
    raise exception 'No tienes permiso para levantar remisiones de refacciones';
  end if;
  if _cliente_id is null or not exists (select 1 from public.clientes c where c.id = _cliente_id) then
    raise exception 'Selecciona un cliente';
  end if;
  if _items is null or jsonb_typeof(_items) <> 'array' or jsonb_array_length(_items) = 0 then
    raise exception 'Agrega al menos una refacción';
  end if;

  v_tipo := nullif(trim(_envio->>'tipo_envio'), '');
  v_pago := nullif(trim(_envio->>'tipo_pago'), '');
  v_forma := coalesce(nullif(trim(_envio->>'forma_pago'), ''), 'efectivo');
  v_dir := nullif(trim(_envio->>'direccion'), '');
  v_desc := coalesce((_envio->>'descuento_pct')::numeric, 0);
  if v_tipo is null or v_tipo not in ('paqueteria', 'directo', 'recoge') then
    raise exception 'Indica si va por paquetería, entrega directa o la recoge el cliente';
  end if;
  if v_tipo <> 'recoge' and (v_dir is null or char_length(v_dir) < 8) then
    raise exception 'La dirección de entrega es obligatoria para logística';
  end if;
  if v_pago is null or v_pago not in ('anticipado', 'contra_entrega', 'credito') then
    raise exception 'Indica si el pago es anticipado, contra entrega o a crédito';
  end if;
  if v_forma not in ('efectivo', 'transferencia', 'credito') then
    raise exception 'La forma de pago es efectivo, transferencia o crédito';
  end if;
  if v_desc < 0 or v_desc > 100 then
    raise exception 'El descuento general va de 0 a 100';
  end if;

  v_rol := public.rol_comercial();
  begin
    v_vendedor := nullif(trim(_envio->>'vendedor_id'), '')::uuid;
  exception when invalid_text_representation then
    v_vendedor := null;
  end;
  if v_rol = 'operador' and public.es_vendedor_activo(auth.uid()) then
    v_vendedor := auth.uid();
  elsif v_vendedor is null and public.es_vendedor_activo(auth.uid()) then
    v_vendedor := auth.uid();
  end if;
  if v_vendedor is null then
    raise exception 'Indica el vendedor de la remisión';
  end if;
  if not public.es_vendedor_activo(v_vendedor) then
    raise exception 'El vendedor tiene que ser alguien del equipo de ventas';
  end if;

  perform 1
  from public.almacen_refacciones_productos p
  where p.id in (
    select (e.value->>'producto_id')::uuid
    from jsonb_array_elements(_items) as e(value)
    where nullif(e.value->>'producto_id', '') is not null
  )
  order by p.id
  for update;

  for v_prod, v_cant in
    select (e.value->>'producto_id')::uuid,
           sum((e.value->>'cantidad')::integer)
    from jsonb_array_elements(_items) as e(value)
    group by 1
  loop
    if v_prod is null then
      raise exception 'Hay una partida sin producto';
    end if;
    if v_cant is null or v_cant < 1 then
      raise exception 'La cantidad debe ser mayor a cero';
    end if;
    if exists (
      select 1 from jsonb_array_elements(_items) e
      where (e.value->>'producto_id')::uuid = v_prod
        and coalesce((e.value->>'descuento_pct')::numeric, 0) not between 0 and 100
    ) then
      raise exception 'El descuento de la pieza va de 0 a 100';
    end if;

    select p.stock, p.codigo_nuevo
      into v_stock, v_codigo
    from public.almacen_refacciones_productos p
    where p.id = v_prod
      and p.visible_venta;

    if not found then
      raise exception 'Hay una refacción que no está disponible para venta';
    end if;
    if coalesce(v_stock, 0) < 0 then
      raise exception 'El inventario de % está en negativo. Corrígelo antes de vender.', v_codigo;
    end if;

    v_disp := greatest(v_stock - public.stock_bloqueado_producto(v_prod), 0);
    if v_cant > v_disp then
      raise exception
        'No hay existencia suficiente de %: pediste % y quedan % disponibles (ya apartadas en otras remisiones).',
        v_codigo, v_cant, v_disp;
    end if;
    v_lineas := v_lineas + 1;
  end loop;

  if v_lineas = 0 then
    raise exception 'Agrega al menos una refacción';
  end if;

  perform pg_advisory_xact_lock(hashtext('remisiones_refacciones')::bigint);
  select coalesce(max((regexp_match(folio, '^RF-(\d+)$'))[1]::int), 0) + 1
    into v_seq
  from public.remisiones_refacciones;
  v_folio := 'RF-' || lpad(v_seq::text, 5, '0');

  select p.nombre_completo into v_nombre from public.profiles p where p.id = v_vendedor;
  v_nombre := coalesce(v_nombre, nullif(trim(_nombre_vendedor), ''));

  insert into public.remisiones_refacciones (
    folio, cliente_id, vendedor_id, nombre_vendedor, fecha_remision, notas,
    etapa, area_actual, abierta, created_by,
    tipo_envio, direccion_entrega, contacto_entrega, telefono_entrega,
    tipo_pago, forma_pago, descuento_pct, pagado
  ) values (
    v_folio, _cliente_id, v_vendedor, v_nombre, current_date, nullif(trim(_notas), ''),
    'almacen', 'almacen', true, auth.uid(),
    v_tipo, v_dir,
    nullif(trim(_envio->>'contacto'), ''),
    nullif(trim(_envio->>'telefono'), ''),
    v_pago, v_forma, v_desc, false
  )
  returning id into v_id;

  insert into public.remision_refaccion_items (
    remision_id, producto_id, codigo_nuevo, codigo_antiguo, descripcion,
    precio_unitario, descuento_pct, cantidad, cantidad_bloqueada, cantidad_surtida,
    cantidad_faltante, estatus
  )
  select
    v_id,
    p.id,
    p.codigo_nuevo,
    p.codigo_antiguo,
    coalesce(nullif(p.descripcion_corta, ''), p.descripcion),
    p.precio,
    ped.descuento_pct,
    ped.cantidad,
    ped.cantidad,
    0,
    0,
    'bloqueada'
  from (
    select (e.value->>'producto_id')::uuid as producto_id,
           sum((e.value->>'cantidad')::integer) as cantidad,
           max(coalesce((e.value->>'descuento_pct')::numeric, 0)) as descuento_pct
    from jsonb_array_elements(_items) as e(value)
    group by 1
  ) ped
  join public.almacen_refacciones_productos p on p.id = ped.producto_id;

  v_detalle := case
    when v_pago = 'credito' or v_forma = 'credito' then
      'Remisión creada y activada en Ventas a crédito. La existencia queda apartada y el cobro queda pendiente.'
    else
      'Remisión levantada. Envío ' || v_tipo || '. Pago ' || v_forma || '. Existencia apartada.'
  end;

  insert into public.remision_refaccion_eventos (remision_id, etapa, area, accion, detalle, usuario_id)
  values
    (v_id, 'almacen', 'ventas', 'captura', v_detalle, auth.uid()),
    (v_id, 'almacen', 'almacen', 'enviada_almacen',
     'Pasó a Almacén para surtir o reportar faltante.',
     auth.uid());

  return jsonb_build_object('id', v_id, 'folio', v_folio, 'forma_pago', v_forma, 'tipo_pago', v_pago);
end;
$$;

-- ── 2 y 3. Envío/pago y FECHA de la remisión ────────────────────────────────
CREATE OR REPLACE FUNCTION public.actualizar_envio_remision_refaccion(_remision_id uuid, _envio jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_row public.remisiones_refacciones%ROWTYPE;
  v_rol text;
  v_tipo text;
  v_dir text;
  v_forma text;
  v_pago text;
  v_desc numeric;
  v_item jsonb;
  v_fecha date;
  v_fecha_txt text;
  v_hoy date := (now() AT TIME ZONE 'America/Mexico_City')::date;
BEGIN
  IF NOT public.puede_capturar_refacciones() THEN
    RAISE EXCEPTION 'Sólo ventas puede actualizar el envío';
  END IF;

  SELECT * INTO v_row FROM public.remisiones_refacciones WHERE id = _remision_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró la remisión';
  END IF;
  IF v_row.etapa IN ('cancelada', 'entregada') OR v_row.entregada_at IS NOT NULL THEN
    RAISE EXCEPTION 'Esta remisión ya no se puede modificar';
  END IF;

  v_rol := public.rol_comercial();
  IF NOT (v_rol IN ('global', 'supervisor') OR public.compras_supervisa_remisiones(auth.uid()) OR v_row.vendedor_id = auth.uid() OR v_row.created_by = auth.uid()) THEN
    RAISE EXCEPTION 'No puedes actualizar esta remisión';
  END IF;

  v_tipo := coalesce(nullif(trim(_envio->>'tipo_envio'), ''), v_row.tipo_envio);
  v_dir := coalesce(nullif(trim(_envio->>'direccion'), ''), v_row.direccion_entrega);
  v_forma := coalesce(nullif(trim(_envio->>'forma_pago'), ''), v_row.forma_pago, 'efectivo');
  v_pago := coalesce(nullif(trim(_envio->>'tipo_pago'), ''), v_row.tipo_pago);
  v_desc := coalesce((_envio->>'descuento_pct')::numeric, v_row.descuento_pct, 0);
  IF v_tipo IS NULL OR v_tipo NOT IN ('paqueteria', 'directo', 'recoge') THEN
    RAISE EXCEPTION 'Indica si va por paquetería, entrega directa o la recoge el cliente';
  END IF;
  IF v_tipo <> 'recoge' AND (v_dir IS NULL OR char_length(v_dir) < 8) THEN
    RAISE EXCEPTION 'La dirección de entrega es obligatoria para logística';
  END IF;
  IF v_forma NOT IN ('efectivo', 'transferencia') THEN
    RAISE EXCEPTION 'La forma de pago es efectivo o transferencia';
  END IF;
  IF v_pago IS NOT NULL AND v_pago NOT IN ('anticipado', 'contra_entrega', 'credito') THEN
    RAISE EXCEPTION 'El pago es anticipado, contra entrega o a crédito';
  END IF;
  IF v_desc < 0 OR v_desc > 100 THEN
    RAISE EXCEPTION 'El descuento general va de 0 a 100';
  END IF;

  -- Fecha de la remisión (opcional): sólo si viene y cambia.
  v_fecha := v_row.fecha_remision;
  v_fecha_txt := nullif(trim(_envio->>'fecha_remision'), '');
  IF v_fecha_txt IS NOT NULL THEN
    BEGIN
      v_fecha := v_fecha_txt::date;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'La fecha de la remisión no es válida';
    END;
    IF v_fecha IS DISTINCT FROM v_row.fecha_remision THEN
      IF v_row.es_historica THEN
        RAISE EXCEPTION 'La remisión % es histórica: su fecha no se cambia', v_row.folio;
      END IF;
      IF v_fecha > v_hoy THEN
        RAISE EXCEPTION 'La fecha de la remisión no puede ser futura';
      END IF;
      IF v_fecha < date '2020-01-01' THEN
        RAISE EXCEPTION 'La fecha de la remisión no es válida';
      END IF;
    END IF;
  END IF;

  UPDATE public.remisiones_refacciones
  SET tipo_envio = v_tipo,
      direccion_entrega = CASE WHEN v_tipo = 'recoge' THEN nullif(trim(coalesce(v_dir, '')), '') ELSE v_dir END,
      contacto_entrega = coalesce(nullif(trim(_envio->>'contacto'), ''), contacto_entrega),
      telefono_entrega = coalesce(nullif(trim(_envio->>'telefono'), ''), telefono_entrega),
      tipo_pago = v_pago,
      forma_pago = v_forma,
      descuento_pct = v_desc,
      fecha_remision = v_fecha
  WHERE id = _remision_id;

  IF jsonb_typeof(_envio->'descuentos') = 'array' THEN
    FOR v_item IN SELECT value FROM jsonb_array_elements(_envio->'descuentos')
    LOOP
      IF coalesce((v_item->>'descuento_pct')::numeric, 0) NOT BETWEEN 0 AND 100 THEN
        RAISE EXCEPTION 'El descuento de la pieza va de 0 a 100';
      END IF;
      UPDATE public.remision_refaccion_items
      SET descuento_pct = coalesce((v_item->>'descuento_pct')::numeric, 0)
      WHERE id = (v_item->>'item_id')::uuid
        AND remision_id = _remision_id;
    END LOOP;
  END IF;

  INSERT INTO public.remision_refaccion_eventos (remision_id, etapa, area, accion, detalle, usuario_id)
  VALUES (
    _remision_id, v_row.etapa, 'ventas', 'actualizar_envio',
    'Ventas actualizó envío ' || v_tipo || ', pago ' || coalesce(v_pago, '—') || ' (' || v_forma || ') y descuento ' || v_desc || '%'
      || CASE WHEN v_fecha IS DISTINCT FROM v_row.fecha_remision
              THEN '; fecha de la remisión de ' || to_char(v_row.fecha_remision, 'DD/MM/YYYY') || ' a ' || to_char(v_fecha, 'DD/MM/YYYY')
              ELSE '' END
      || '.',
    auth.uid()
  );
END;
$$;

-- ── 4. Eliminar por completo una remisión de refacciones ────────────────────
-- _devolver_inventario: regresa al almacén las piezas que la remisión tiene
-- SURTIDAS (lo que sigue fuera por ella; las correcciones y devoluciones
-- anteriores ya restaron de ahí). Una remisión cancelada conserva sus piezas
-- surtidas, por eso es una decisión de quien elimina y no un efecto oculto.
DROP FUNCTION IF EXISTS public.eliminar_remision_refacciones(uuid, text);
CREATE OR REPLACE FUNCTION public.eliminar_remision_refacciones(_remision_id uuid, _motivo text, _devolver_inventario boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r public.remisiones_refacciones%ROWTYPE;
  m record;
  v_hoy date := (now() AT TIME ZONE 'America/Mexico_City')::date;
  v_devueltas integer := 0;
  v_nombre text;
  v_snapshot jsonb;
BEGIN
  IF NOT (public.rol_comercial() = 'global' OR public.es_admin_area(auth.uid(), 'comercial'::public.user_area)) THEN
    RAISE EXCEPTION 'Sólo el administrador de Comercial puede eliminar una remisión por completo';
  END IF;
  IF nullif(trim(_motivo), '') IS NULL OR char_length(trim(_motivo)) < 10 THEN
    RAISE EXCEPTION 'Escribe el motivo de la eliminación (mínimo 10 caracteres)';
  END IF;

  SELECT * INTO r FROM public.remisiones_refacciones WHERE id = _remision_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No se encontró la remisión'; END IF;
  PERFORM public.exigir_dato_prueba(r.es_prueba, 'la remisión ' || r.folio);

  IF r.es_historica THEN
    RAISE EXCEPTION 'La remisión % es histórica: un administrador la anula con anular_remision_historica_refacciones', r.folio;
  END IF;
  IF r.etapa = 'entregada' AND NOT r.es_prueba THEN
    RAISE EXCEPTION 'La remisión % ya se entregó y es real: no se elimina (queda en Entregadas). Si fue un error, Compras la corrige con una devolución.', r.folio;
  END IF;
  IF EXISTS (SELECT 1 FROM public.cobranza_aplicaciones WHERE remision_id = _remision_id)
     OR EXISTS (SELECT 1 FROM public.cobranza_saldos_favor WHERE remision_origen_id = _remision_id)
     OR EXISTS (SELECT 1 FROM public.cobranza_solicitudes_saldo WHERE remision_id = _remision_id)
     OR EXISTS (SELECT 1 FROM public.remision_refaccion_correcciones WHERE remision_id = _remision_id) THEN
    RAISE EXCEPTION 'La remisión % tiene cobros, saldos a favor o correcciones registrados: no se elimina. Cancélala para que quede en el historial.', r.folio;
  END IF;

  IF coalesce(_devolver_inventario, true) THEN
    FOR m IN
      SELECT i.producto_id, sum(i.cantidad_surtida)::integer AS piezas
        FROM public.remision_refaccion_items i
       WHERE i.remision_id = _remision_id AND i.cantidad_surtida > 0
       GROUP BY i.producto_id
    LOOP
      PERFORM public._mover_inventario_refaccion(
        m.producto_id,
        (SELECT p.linea_catalogo FROM public.almacen_refacciones_productos p WHERE p.id = m.producto_id),
        m.piezas, v_hoy, 'entrada', 'devolucion', r.id, r.folio, NULL,
        'Devolución por eliminación de ' || r.folio || ': ' || trim(_motivo),
        r.cliente_id, NULL, r.es_prueba);
      v_devueltas := v_devueltas + m.piezas;
    END LOOP;
  END IF;

  SELECT coalesce(nullif(p.nombre_completo, ''), p.email) INTO v_nombre FROM public.profiles p WHERE p.id = auth.uid();
  v_snapshot := jsonb_build_object(
    'remision', to_jsonb(r),
    'partidas', coalesce((SELECT jsonb_agg(to_jsonb(i)) FROM public.remision_refaccion_items i WHERE i.remision_id = _remision_id), '[]'::jsonb),
    'inventario_devuelto', coalesce(_devolver_inventario, true),
    'piezas_devueltas_a_inventario', v_devueltas
  );
  INSERT INTO public.bitacora_eliminaciones (tabla, registro_id, eliminado_por, nombre_usuario, motivo, datos_eliminados)
  VALUES ('remisiones_refacciones', _remision_id, auth.uid(), coalesce(v_nombre, auth.uid()::text), trim(_motivo), v_snapshot);

  -- Partidas, eventos y órdenes se van en cascada; avisos también.
  DELETE FROM public.remisiones_refacciones WHERE id = _remision_id;

  RETURN jsonb_build_object('folio', r.folio, 'piezas_devueltas', v_devueltas);
END;
$$;
REVOKE ALL ON FUNCTION public.eliminar_remision_refacciones(uuid, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.eliminar_remision_refacciones(uuid, text, boolean) TO authenticated;

-- ── 5. Reporte de ventas de refacciones ─────────────────────────────────────
-- Una fila por artículo de cada remisión NO cancelada (lo surtido más lo
-- apartado, la misma base que el total que cobra Cobranza). Sale de las
-- partidas de la remisión y no del kárdex porque los movimientos de venta
-- casi nunca guardan el id de la remisión. La fecha es la de la remisión.
-- La pantalla agrupa por almacén, vendedor, artículo, mes o remisión.
DROP FUNCTION IF EXISTS public.reporte_ventas_refacciones(date, date, boolean);
CREATE OR REPLACE FUNCTION public.reporte_ventas_refacciones(_desde date, _hasta date, _incluir_prueba boolean DEFAULT false)
RETURNS TABLE(
  fecha date, remision_id uuid, folio text, etapa text, pagado boolean,
  cliente_id uuid, cliente text,
  vendedor_id uuid, vendedor text,
  almacen text, producto_id uuid, codigo text, descripcion text,
  piezas integer, precio_unitario numeric, descuento_pct numeric, descuento_general numeric, monto numeric
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
#variable_conflict use_column
BEGIN
  IF NOT (public.puede_leer_compras_inventario(auth.uid())
          OR public.rol_comercial(auth.uid()) IN ('global', 'supervisor')) THEN
    RAISE EXCEPTION 'Sin acceso al reporte de ventas';
  END IF;
  IF _desde IS NULL OR _hasta IS NULL OR _desde > _hasta THEN
    RAISE EXCEPTION 'Indica un periodo válido';
  END IF;
  RETURN QUERY
  SELECT r.fecha_remision, r.id, r.folio, r.etapa, r.pagado,
         r.cliente_id, coalesce(cl.nombre_comercial, cl.razon_social, cl.codigo_erp, '(sin cliente)'),
         r.vendedor_id, coalesce(r.nombre_vendedor, pv.nombre_completo, '(sin vendedor)'),
         coalesce(i.almacen, p.linea_catalogo), i.producto_id, i.codigo_nuevo, i.descripcion,
         (i.cantidad_surtida + i.cantidad_bloqueada)::integer,
         i.precio_unitario, coalesce(i.descuento_pct, 0), coalesce(r.descuento_pct, 0),
         public.importe_partida_refaccion(i.precio_unitario, i.cantidad_surtida + i.cantidad_bloqueada, i.descuento_pct, r.descuento_pct)
    FROM public.remisiones_refacciones r
    JOIN public.remision_refaccion_items i ON i.remision_id = r.id
    LEFT JOIN public.almacen_refacciones_productos p ON p.id = i.producto_id
    LEFT JOIN public.clientes cl ON cl.id = r.cliente_id
    LEFT JOIN public.profiles pv ON pv.id = r.vendedor_id
   WHERE r.etapa <> 'cancelada'
     AND r.fecha_remision BETWEEN _desde AND _hasta
     AND (i.cantidad_surtida + i.cantidad_bloqueada) > 0
     AND (coalesce(_incluir_prueba, false) OR NOT r.es_prueba)
     AND (r.es_prueba OR NOT public.es_usuario_prueba(auth.uid()))
   ORDER BY r.fecha_remision, r.folio, i.codigo_nuevo;
END;
$$;
REVOKE ALL ON FUNCTION public.reporte_ventas_refacciones(date, date, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reporte_ventas_refacciones(date, date, boolean) TO authenticated;

-- ── 6. Eliminar un movimiento financiero ligado al flujo de dinero ──────────
-- «update or delete on table movimientos_financieros violates foreign key
-- constraint flujo_dinero_movimiento_id_fkey»: el flujo apunta al movimiento
-- que generó en Caja y la llave no tenía acción, así que un movimiento
-- rechazado/cancelado no se podía eliminar. Con SET NULL el movimiento se borra
-- (queda en la bitácora de eliminaciones) y el registro del flujo conserva su
-- historia —recibido, caja, rechazo— sólo que sin el enlace. Ninguna restricción
-- de flujo_dinero exige `movimiento_id`, y flujo_dinero_sin_borrar sigue
-- impidiendo borrar el flujo mismo.
ALTER TABLE public.flujo_dinero DROP CONSTRAINT IF EXISTS flujo_dinero_movimiento_id_fkey;
ALTER TABLE public.flujo_dinero
  ADD CONSTRAINT flujo_dinero_movimiento_id_fkey
  FOREIGN KEY (movimiento_id) REFERENCES public.movimientos_financieros(id) ON DELETE SET NULL;

-- ── Verificación (solo lectura) ─────────────────────────────────────────────
-- 1) CHECK nuevo:
--    SELECT pg_get_constraintdef(oid) FROM pg_constraint
--     WHERE conname = 'remisiones_refacciones_tipo_pago_check';
-- 2) Funciones nuevas:
--    SELECT to_regprocedure('public.eliminar_remision_refacciones(uuid,text,boolean)') IS NOT NULL,
--           to_regprocedure('public.reporte_ventas_refacciones(date,date,boolean)') IS NOT NULL;
-- 3) Un vendedor sólo ve sus remisiones (como el vendedor, en la app).
-- 4) Reporte: SELECT * FROM reporte_ventas_refacciones('2026-09-01','2026-11-03');

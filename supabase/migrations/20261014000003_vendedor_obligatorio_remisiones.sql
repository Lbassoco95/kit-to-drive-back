-- Toda remisión lleva un vendedor del equipo de ventas.
--
-- 1. `es_vendedor_activo(uuid)`: quién cuenta como vendedor (profiles.es_vendedor
--    y activo). Atenea, Ana Karen, Dirección, etc. cargan remisiones pero no
--    son el vendedor.
-- 2. `crear_remision_refacciones`: ya no cae «a nombre de quien la captura».
--    Pide el vendedor y debe ser del equipo de ventas; quien es vendedor y no
--    manda ninguno queda como su propio vendedor.
-- 3. `asignar_vendedor_remision`: para cerrar las que quedaron sin vendedor
--    (o con alguien que no es vendedor). Lo usan administración de ventas,
--    supervisores/administradores de Comercial y Dirección; deja constancia.
-- Idempotente.

create or replace function public.es_vendedor_activo(_user_id uuid)
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select exists (
    select 1 from public.profiles p
     where p.id = _user_id and p.es_vendedor and coalesce(p.activo, true)
  )
$$;
revoke all on function public.es_vendedor_activo(uuid) from public, anon;
grant execute on function public.es_vendedor_activo(uuid) to authenticated;

create or replace function public.crear_remision_refacciones(_cliente_id uuid, _notas text, _nombre_vendedor text, _items jsonb, _envio jsonb DEFAULT '{}'::jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
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
  if v_pago is null or v_pago not in ('anticipado', 'contra_entrega') then
    raise exception 'Indica si el pago es anticipado o contra entrega';
  end if;
  if v_forma not in ('efectivo', 'transferencia', 'credito') then
    raise exception 'La forma de pago es efectivo, transferencia o crédito';
  end if;
  if v_desc < 0 or v_desc > 100 then
    raise exception 'El descuento general va de 0 a 100';
  end if;

  -- Vendedor: obligatorio y del equipo de ventas. El operador que es vendedor
  -- sólo la levanta a su nombre; el administrativo y los demás eligen. Quien es vendedor y no elige
  -- ninguno queda como su propio vendedor.
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

  -- El nombre sale del perfil del vendedor elegido, no de lo que mande el cliente.
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
    when v_forma = 'credito' then
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

  return jsonb_build_object('id', v_id, 'folio', v_folio, 'forma_pago', v_forma);
end;
$function$;

-- Asigna (o corrige) el vendedor de una remisión ya capturada.
create or replace function public.asignar_vendedor_remision(_tipo text, _remision_id uuid, _vendedor_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_nombre text;
  v_antes uuid;
  v_antes_nombre text;
  v_etapa text;
  v_permiso boolean;
begin
  v_permiso := public.es_admin_global(v_uid)
    or exists (select 1 from public.profiles p where p.id = v_uid and p.es_administrativo and coalesce(p.activo, true))
    or exists (select 1 from public.user_roles r
                where r.user_id = v_uid and r.area = 'comercial' and r.nivel in ('supervisor', 'admin'));
  if not v_permiso then
    raise exception 'Solo administración de ventas, supervisores de Comercial y Dirección asignan vendedor';
  end if;
  if _tipo not in ('motocarros', 'refacciones') then
    raise exception 'Tipo de remisión inválido';
  end if;
  if not public.es_vendedor_activo(_vendedor_id) then
    raise exception 'El vendedor tiene que ser alguien del equipo de ventas';
  end if;
  select nombre_completo into v_nombre from public.profiles where id = _vendedor_id;

  if _tipo = 'motocarros' then
    select vendedor_id, nombre_vendedor into v_antes, v_antes_nombre from public.remisiones where id = _remision_id for update;
    if not found then raise exception 'La remisión no existe'; end if;
    update public.remisiones set vendedor_id = _vendedor_id, nombre_vendedor = v_nombre where id = _remision_id;
    insert into public.remisiones_bitacora (remision_id, usuario_id, nombre_usuario, tipo_cambio, motivo, datos_antes, datos_despues)
    values (_remision_id, v_uid, (select nombre_completo from public.profiles where id = v_uid),
            'asignacion_vendedor', 'Asignación de vendedor: ' || v_nombre,
            jsonb_build_object('vendedor_id', v_antes, 'nombre_vendedor', v_antes_nombre),
            jsonb_build_object('vendedor_id', _vendedor_id, 'nombre_vendedor', v_nombre));
  else
    select vendedor_id, nombre_vendedor, etapa into v_antes, v_antes_nombre, v_etapa from public.remisiones_refacciones where id = _remision_id for update;
    if not found then raise exception 'La remisión no existe'; end if;
    update public.remisiones_refacciones set vendedor_id = _vendedor_id, nombre_vendedor = v_nombre where id = _remision_id;
    insert into public.remision_refaccion_eventos (remision_id, etapa, area, accion, detalle, usuario_id)
    values (_remision_id, v_etapa, 'ventas', 'asigna_vendedor',
            'Vendedor asignado: ' || v_nombre || coalesce(' (antes: ' || v_antes_nombre || ')', ''), v_uid);
  end if;

  return jsonb_build_object('remision_id', _remision_id, 'vendedor_id', _vendedor_id, 'nombre_vendedor', v_nombre);
end;
$function$;
revoke all on function public.asignar_vendedor_remision(text, uuid, uuid) from public, anon;
grant execute on function public.asignar_vendedor_remision(text, uuid, uuid) to authenticated;

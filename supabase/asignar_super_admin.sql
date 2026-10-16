-- ============================================================================
-- Convertir a una persona en Super admin (pedidos de clientes y finanzas en
-- solo lectura). Requiere haber corrido antes
-- migrations/20261016000001_super_admin_solo_lectura.sql.
--
-- Cómo se usa: cambia el patrón de correo de abajo y corre el archivo completo
-- en el SQL editor. Si el patrón no encuentra exactamente UNA cuenta, se
-- detiene sin cambiar nada.
--
-- La persona queda como Dirección · admin (ve y modifica todo lo demás) y en la
-- lista de solo lectura. Para quitarle el Super admin:
--   DELETE FROM public.usuarios_solo_lectura_pedidos_finanzas
--    WHERE user_id = (SELECT id FROM auth.users WHERE email ILIKE '<correo>');
-- ============================================================================
DO $$
DECLARE
  v_patron text := '%@qq.com';   -- correo de Peter
  v_ids    uuid[];
  v_email  text;
BEGIN
  SELECT array_agg(id ORDER BY id), min(email) INTO v_ids, v_email
    FROM auth.users WHERE email ILIKE v_patron;

  IF coalesce(array_length(v_ids, 1), 0) <> 1 THEN
    RAISE EXCEPTION 'Se esperaba exactamente 1 cuenta con correo %, hay %. No se cambió nada.',
      v_patron, coalesce(array_length(v_ids, 1), 0);
  END IF;

  UPDATE public.user_roles SET area = 'direccion', nivel = 'admin' WHERE user_id = v_ids[1];
  IF NOT FOUND THEN
    INSERT INTO public.user_roles (user_id, area, nivel, role)
    VALUES (v_ids[1], 'direccion', 'admin', 'admin');
  END IF;

  INSERT INTO public.usuarios_solo_lectura_pedidos_finanzas (user_id, nota)
  VALUES (v_ids[1], 'Super admin')
  ON CONFLICT (user_id) DO NOTHING;

  RAISE NOTICE 'Super admin asignado a %', v_email;
END
$$;

-- Verificación: debe salir una fila con area = direccion, nivel = admin.
SELECT u.email, r.area, r.nivel, r.role, s.creado_en AS super_admin_desde
  FROM public.usuarios_solo_lectura_pedidos_finanzas s
  JOIN auth.users u ON u.id = s.user_id
  LEFT JOIN public.user_roles r ON r.user_id = s.user_id
 ORDER BY s.creado_en;

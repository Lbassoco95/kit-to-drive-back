-- ============================================================================
-- Crear categorías de ingreso / egreso desde el formulario del flujo
--
-- Hasta ahora el catálogo (categorias_financieras) solo lo podía escribir un
-- administrador de Finanzas, y por tabla. Quien captura en el flujo solo podía
-- elegir de la lista. Esta función deja agregar una categoría nueva sin abrir
-- la tabla: valida quién puede, normaliza el nombre y evita duplicados
-- (sin importar mayúsculas ni acentos).
--
-- Quién puede: las mismas personas que ya ven el catálogo en el formulario
-- (etapa de recepción, caja o administración del flujo).
-- Idempotente. No toca tablas ni funciones existentes.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.flujo_crear_categoria(_tipo text, _nombre text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_tipo   text := upper(btrim(coalesce(_tipo, '')));
  v_nombre text := regexp_replace(btrim(coalesce(_nombre, '')), '\s+', ' ', 'g');
  v_exist  text;
BEGIN
  IF NOT coalesce(public.flujo_cap('recibe') OR public.flujo_cap('caja') OR public.flujo_es_admin(), false) THEN
    RAISE EXCEPTION 'No tienes permiso para crear categorías';
  END IF;
  IF v_tipo NOT IN ('INGRESO', 'EGRESO') THEN
    RAISE EXCEPTION 'Tipo de categoría no válido';
  END IF;
  IF char_length(v_nombre) < 2 OR char_length(v_nombre) > 60 THEN
    RAISE EXCEPTION 'El nombre de la categoría debe tener entre 2 y 60 caracteres';
  END IF;

  -- Ya existe (aunque cambie mayúsculas o espacios): se reutiliza y, si estaba desactivada, se reactiva.
  SELECT c.nombre INTO v_exist FROM public.categorias_financieras c
   WHERE c.tipo::text = v_tipo AND lower(c.nombre) = lower(v_nombre) LIMIT 1;
  IF v_exist IS NOT NULL THEN
    UPDATE public.categorias_financieras SET activo = true
     WHERE tipo::text = v_tipo AND nombre = v_exist AND NOT activo;
    RETURN v_exist;
  END IF;

  -- Antes de "Otro ingreso / Otro egreso" (orden 99) para que sigan al final de la lista.
  INSERT INTO public.categorias_financieras (tipo, nombre, orden)
  VALUES (v_tipo::mov_tipo, v_nombre,
          coalesce((SELECT max(orden) FROM public.categorias_financieras WHERE tipo::text = v_tipo AND orden < 99), 0) + 1);
  RETURN v_nombre;
END;
$$;
REVOKE ALL ON FUNCTION public.flujo_crear_categoria(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_crear_categoria(text, text) TO authenticated;

DO $postflight$
BEGIN
  IF to_regprocedure('public.flujo_crear_categoria(text,text)') IS NULL THEN
    RAISE EXCEPTION 'flujo_crear_categoria no se creó.';
  END IF;
  IF has_function_privilege('anon', 'public.flujo_crear_categoria(text,text)', 'execute') THEN
    RAISE EXCEPTION 'flujo_crear_categoria no debe estar abierta a anon.';
  END IF;
END $postflight$;

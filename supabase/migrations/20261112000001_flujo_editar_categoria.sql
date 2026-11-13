-- ============================================================================
-- Editar categorías de ingreso / egreso (corregir una mal escrita)
-- Fecha: 2026-11-12 (continúa 20261110000001_flujo_crear_categoria)
--
-- Hasta ahora una categoría se podía crear pero no corregir: si alguien la
-- escribía mal quedaba para siempre. Esta función la renombra y, como los
-- movimientos guardan el nombre como texto, también corrige los movimientos
-- (Control Financiero) y los del flujo que ya la usaban, para que filtros y
-- reportes sigan agrupando igual.
--
-- Quién puede: las mismas personas que pueden crear (recepción, caja o
-- administración del flujo). No permite renombrar a un nombre que ya existe
-- (sin importar mayúsculas): eso sería fusionar categorías. Idempotente.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.flujo_editar_categoria(_tipo text, _nombre_actual text, _nombre_nuevo text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_tipo   text := upper(btrim(coalesce(_tipo, '')));
  v_nuevo  text := regexp_replace(btrim(coalesce(_nombre_nuevo, '')), '\s+', ' ', 'g');
  v_actual text;
BEGIN
  IF NOT coalesce(public.flujo_cap('recibe') OR public.flujo_cap('caja') OR public.flujo_es_admin(), false) THEN
    RAISE EXCEPTION 'No tienes permiso para editar categorías';
  END IF;
  IF v_tipo NOT IN ('INGRESO', 'EGRESO') THEN
    RAISE EXCEPTION 'Tipo de categoría no válido';
  END IF;
  IF char_length(v_nuevo) < 2 OR char_length(v_nuevo) > 60 THEN
    RAISE EXCEPTION 'El nombre de la categoría debe tener entre 2 y 60 caracteres';
  END IF;

  SELECT c.nombre INTO v_actual FROM public.categorias_financieras c
   WHERE c.tipo::text = v_tipo AND c.nombre = _nombre_actual FOR UPDATE;
  IF v_actual IS NULL THEN
    RAISE EXCEPTION 'La categoría no existe';
  END IF;
  IF v_actual = v_nuevo THEN
    RETURN v_actual;
  END IF;
  -- Solo cambió mayúsculas o acentos de la misma: se permite. Si es OTRA categoría, no.
  IF EXISTS (SELECT 1 FROM public.categorias_financieras c
              WHERE c.tipo::text = v_tipo AND lower(c.nombre) = lower(v_nuevo) AND c.nombre <> v_actual) THEN
    RAISE EXCEPTION 'Ya existe una categoría con ese nombre';
  END IF;

  UPDATE public.categorias_financieras SET nombre = v_nuevo WHERE tipo::text = v_tipo AND nombre = v_actual;
  UPDATE public.movimientos_financieros SET categoria = v_nuevo WHERE tipo::text = v_tipo AND categoria = v_actual;
  UPDATE public.flujo_dinero SET categoria = v_nuevo WHERE tipo::text = v_tipo AND categoria = v_actual;
  RETURN v_nuevo;
END;
$$;
REVOKE ALL ON FUNCTION public.flujo_editar_categoria(text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flujo_editar_categoria(text, text, text) TO authenticated;

DO $postflight$
BEGIN
  IF to_regprocedure('public.flujo_editar_categoria(text,text,text)') IS NULL THEN
    RAISE EXCEPTION 'flujo_editar_categoria no se creó.';
  END IF;
  IF has_function_privilege('anon', 'public.flujo_editar_categoria(text,text,text)', 'execute') THEN
    RAISE EXCEPTION 'flujo_editar_categoria no debe estar abierta a anon.';
  END IF;
END $postflight$;

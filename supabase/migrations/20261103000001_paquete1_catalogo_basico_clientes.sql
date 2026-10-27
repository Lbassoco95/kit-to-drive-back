-- ============================================================================
-- PAQUETE 1 (permisos del vendedor) · 1 de 3: catálogo BÁSICO de clientes
--
-- Síntoma (Martin, Dazon): un vendedor de Comercial ve «0 de 0 clientes» y al crear una
-- oportunidad «No hay clientes en el catálogo». Causa: la política «leer clientes» deja ver al
-- vendedor solo los clientes con vendedor_id = él, y los 1,786 clientes no tienen vendedor.
--
-- Decisión de Polo (26 oct 2026): NO se abre la ficha de los clientes sin asignar (traería crédito,
-- saldo y documentos de los 1,786 clientes a todo vendedor, y contradice la Fase 2). En su lugar,
-- un catálogo BÁSICO, solo para ELEGIR cliente en oportunidad, ruta y actividad:
--   · columnas básicas:   id, codigo_erp, folio_interno, nombre_comercial, activo   (sin teléfono: decisión de Polo, 27 oct 2026)
--   · todo lo demás de «clientes» (crédito, saldo, documentos, fiscal, contacto, domicilio, notas,
--     coordenadas, vendedor) y la cartera siguen protegidos por «leer clientes», SIN CAMBIO.
--
-- Mecanismo: función de solo lectura, SECURITY DEFINER **porque es necesario**: «leer clientes» oculta
-- por diseño las filas de otros vendedores, y una vista con security_invoker devolvería 0 filas
-- (una vista sin security_invoker rompería el estado 18/18 de la Fase 1 y el aviso de seguridad de
-- Supabase; una tabla copia duplicaría datos; quitar columnas con permisos rompería a todo el que
-- lea clientes). La función: sin parámetros, solo 5 columnas, solo para quien trabaja en Comercial
-- (rol_comercial = operador, supervisor o global) y para Dirección; el inactivo queda fuera), respeta el modo prueba
-- (un usuario de prueba solo ve clientes de prueba), search_path fijo, sin EXECUTE para anon.
--
-- Objeto nuevo: 1 función (catalogo_clientes_basico). Ninguna tabla, vista ni política nueva.
-- Idempotente. Reversa: supabase/reversas/20261103000001_paquete1_catalogo_basico_clientes_reversa.sql
-- ============================================================================
CREATE OR REPLACE FUNCTION public.catalogo_clientes_basico()
RETURNS TABLE (
  id uuid, codigo_erp text, folio_interno text, nombre_comercial text, activo boolean
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT (
       public.rol_comercial(auth.uid()) IN ('global', 'supervisor', 'operador')
       OR (public.es_area(auth.uid(), 'direccion'::public.user_area) AND public.usuario_activo(auth.uid()))
     ) THEN
    RAISE EXCEPTION 'Sin acceso al catálogo de clientes' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT c.id, c.codigo_erp, c.folio_interno, c.nombre_comercial, c.activo
    FROM public.clientes c
   WHERE (NOT public.es_usuario_prueba(auth.uid()) OR c.es_prueba)
   ORDER BY c.folio_interno NULLS LAST, c.codigo_erp NULLS LAST, c.id;
END;
$$;

REVOKE ALL ON FUNCTION public.catalogo_clientes_basico() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.catalogo_clientes_basico() TO authenticated, service_role;

COMMENT ON FUNCTION public.catalogo_clientes_basico() IS
  'Catálogo básico de clientes (id, código, folio, nombre comercial, activo) para elegir cliente en el CRM. Sin crédito, saldo, documentos ni cartera. Solo Comercial.';

-- Verificación: existe, es DEFINER con search_path fijo, authenticated sí y anon no la ejecutan, devuelve 5 columnas.
SELECT
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'catalogo_clientes_basico' AND p.prosecdef
      AND EXISTS (SELECT 1 FROM unnest(p.proconfig) x WHERE x LIKE 'search_path=%')) AS funcion_definer_con_search_path,
  has_function_privilege('authenticated', 'public.catalogo_clientes_basico()', 'EXECUTE') AS authenticated_ejecuta,
  has_function_privilege('anon', 'public.catalogo_clientes_basico()', 'EXECUTE') AS anon_ejecuta,
  (SELECT array_length(p.proargnames, 1) FROM pg_proc p WHERE p.oid = 'public.catalogo_clientes_basico()'::regprocedure) AS columnas_que_devuelve;

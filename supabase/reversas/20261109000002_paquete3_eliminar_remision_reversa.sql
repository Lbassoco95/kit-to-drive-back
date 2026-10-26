-- REVERSA de 20261109000002: quita `eliminar_remision` y RESTITUYE los dos DELETE directos de `remisiones` (los
-- que había en producción el 26 oct: rol heredado `admin` y administradores del área Comercial) y el privilegio DELETE.
-- Lo ya eliminado (con su copia en `bitacora_eliminaciones`) no se restituye: son datos.
DROP FUNCTION IF EXISTS public.eliminar_remision(text, uuid, text, text);
GRANT DELETE ON TABLE public.remisiones TO authenticated;
DROP POLICY IF EXISTS "borrar remisiones admin" ON public.remisiones;
CREATE POLICY "borrar remisiones admin" ON public.remisiones FOR DELETE TO authenticated
  USING (has_role(auth.uid(), 'admin'::app_role));
DROP POLICY IF EXISTS "admin de area borra remisiones" ON public.remisiones;
CREATE POLICY "admin de area borra remisiones" ON public.remisiones FOR DELETE TO authenticated
  USING (es_admin_area(auth.uid(), 'comercial'::user_area));
SELECT (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND tablename = 'remisiones' AND cmd = 'DELETE') AS politicas_delete_remisiones,
       has_table_privilege('authenticated', 'public.remisiones', 'DELETE') AS authenticated_puede_delete,
       (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'eliminar_remision') AS funcion_que_queda;

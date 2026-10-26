-- ============================================================================
-- REVERSA: vuelve a crear profiles_update_admin tal como estaba en producción el 25 oct 2026
--
-- Fase 2 de seguridad (docs/seguridad/). Reversa del cambio 3. Definición del respaldo del
-- esquema del 25 oct 2026, sin cambios. Idempotente.
-- ============================================================================
DROP POLICY IF EXISTS profiles_update_admin ON public.profiles;
CREATE POLICY profiles_update_admin ON public.profiles AS PERMISSIVE FOR UPDATE TO authenticated USING ((es_admin_global(auth.uid()) OR es_admin_area(auth.uid(), 'direccion'::user_area) OR (EXISTS ( SELECT 1
   FROM user_roles ur
  WHERE ((ur.user_id = auth.uid()) AND (ur.nivel = 'admin'::user_nivel) AND usuario_activo(auth.uid())))))) WITH CHECK ((es_admin_global(auth.uid()) OR es_admin_area(auth.uid(), 'direccion'::user_area) OR (EXISTS ( SELECT 1
   FROM user_roles ur
  WHERE ((ur.user_id = auth.uid()) AND (ur.nivel = 'admin'::user_nivel) AND usuario_activo(auth.uid()))))));

-- Verificación: debe salir 1.
SELECT count(*) AS politica_restaurada FROM pg_policies WHERE schemaname = 'public' AND tablename = 'profiles' AND policyname = 'profiles_update_admin';

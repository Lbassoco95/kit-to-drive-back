-- ============================================================================
-- profiles: quitar la política de UPDATE que deja a cualquier admin editar a cualquiera
--
-- Fase 2 de seguridad de la base de producción (docs/seguridad/). Cambio 3 de 4.
-- Depende del cambio 1 (el trigger ya impide el daño; esto quita la puerta abierta).
-- ============================================================================
--
-- Hoy hay dos políticas de UPDATE que se suman (permisivas, se combinan con OR):
--   · "admin de area actualiza profiles": global, o admin cuyo ÁREA coincide con la del destino.
--   · profiles_update_admin: cualquiera con nivel admin en CUALQUIER área, sin mirar el destino.
-- La segunda anula a la primera: un admin de Comercial pasa la seguridad por filas sobre
-- un perfil de Finanzas o del super admin. Se quita; queda la de área (que ya cubre al
-- administrador global) y profiles_update_propio (el trigger del cambio 1 limita sus campos).
--
-- Cubre lo que hace falta hoy: Usuarios.tsx activa/desactiva por la política de área y
-- el resto de ediciones pasa por Edge Functions con service_role (no usan RLS).
-- Idempotente. Reversa: supabase/reversas/20261107000003_fase2_profiles_politica_por_area_reversa.sql
-- ============================================================================
DROP POLICY IF EXISTS profiles_update_admin ON public.profiles;

-- Verificación: debe salir 0 y quedar "admin de area actualiza profiles" y profiles_update_propio.
SELECT (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND tablename = 'profiles' AND policyname = 'profiles_update_admin') AS politica_abierta,
       (SELECT string_agg(policyname, ', ' ORDER BY policyname) FROM pg_policies WHERE schemaname = 'public' AND tablename = 'profiles' AND cmd = 'UPDATE') AS politicas_update_restantes;

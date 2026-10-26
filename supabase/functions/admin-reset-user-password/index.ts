import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { enviarAcceso, generarPassword, MENSAJE_CORREO } from "../_shared/acceso.ts";
import { cargarActor, cargarDestino } from "../_shared/contexto.ts";
import { puedeRestablecerPassword } from "../_shared/permisos.ts";
import { correlacionDe, dejarRastro } from "../_shared/rastro.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-request-id",
};
const JSON_HEADERS = { ...CORS, "Content-Type": "application/json" };

const respond = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return respond({ error: "Unauthorized" }, 401);

    const supabaseClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user: caller }, error: authError } = await supabaseClient.auth.getUser();
    if (authError || !caller) return respond({ error: "Unauthorized" }, 401);

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );
    const correlacion = correlacionDe(req);
    const actor = await cargarActor(supabaseAdmin, caller.id);
    if (actor.nivel !== "admin" || !actor.activo) return respond({ error: "Forbidden: solo un administrador puede restablecer contraseñas" }, 403);

    const { user_id } = await req.json();
    if (!user_id || typeof user_id !== "string") return respond({ error: "user_id es obligatorio" }, 400);

    // Mismas reglas que la base (_shared/permisos.ts): misma área, nivel menor, y a un super admin solo otro super admin.
    const { destino } = await cargarDestino(supabaseAdmin, user_id);
    const permiso = puedeRestablecerPassword(actor, destino);
    if (!permiso.ok) return respond({ error: permiso.error }, permiso.status);

    const { data: target, error: targetError } = await supabaseAdmin.auth.admin.getUserById(user_id);
    if (targetError || !target.user) return respond({ error: "Usuario no encontrado" }, 404);

    const email = target.user.email;
    if (!email) return respond({ error: "La persona no tiene correo registrado" }, 400);
    const { data: perfil } = await supabaseAdmin.from("profiles").select("nombre_completo").eq("id", user_id).maybeSingle();

    // Rastro ANTES de cambiar nada: si no se puede dejar, la contraseña no se cambia.
    const rastroOk = await dejarRastro(supabaseAdmin, {
      accion: "usuario.restablecer_password",
      objetivo: user_id,
      actor: { id: caller.id, email: caller.email },
      correlacion,
    });
    if (!rastroOk) return respond({ error: "No se pudo registrar el cambio; no se aplicó nada. Intenta de nuevo." }, 503);

    // La contraseña la genera esta función y viaja solo por correo; nadie la ve.
    // El correo va PRIMERO: si no sale, no se cambia nada (la persona sigue pudiendo entrar).
    const temporaryPassword = generarPassword();
    const envio = await enviarAcceso(email, perfil?.nombre_completo || email, temporaryPassword, true);
    if (!envio.ok) {
      return respond({ error: MENSAJE_CORREO[envio.motivo], code: "CORREO_FALLO" }, envio.motivo === "no_configurado" ? 503 : 502);
    }

    const { error: updateError } = await supabaseAdmin.auth.admin.updateUserById(user_id, {
      password: temporaryPassword,
      app_metadata: {
        ...(target.user.app_metadata || {}),
        must_change_password: true,
      },
      user_metadata: {
        ...(target.user.user_metadata || {}),
        must_change_password: true,
      },
    });
    if (updateError) return respond({ error: updateError.message }, 400);

    const { error: profileError } = await supabaseAdmin
      .from("profiles")
      .update({ debe_cambiar_password: true })
      .eq("id", user_id);
    if (profileError) return respond({ error: profileError.message }, 500);

    return respond({ ok: true, correo: { enviado: true } });
  } catch (error) {
    return respond({ error: error instanceof Error ? error.message : "Error inesperado" }, 500);
  }
});

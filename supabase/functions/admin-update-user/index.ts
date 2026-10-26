import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { cargarActor, cargarDestino } from "../_shared/contexto.ts";
import { areaValida, nivelValido, puedeEditarUsuario, type Cambio } from "../_shared/permisos.ts";
import { correlacionDe, dejarRastro } from "../_shared/rastro.ts";

// CORS sin cambios en esta fase (queda como hallazgo O12 de la revisión de otras capas).
function corsHeaders(_req: Request) {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-request-id",
  };
}

// Rol legado que corresponde a cada área y nivel (la base lo sigue usando en políticas antiguas).
const LEGACY_ROLE: Record<string, Record<string, string>> = {
  comercial: { operador: "ventas", supervisor: "coordinador_ventas", admin: "director_ventas" },
  fabrica: { operador: "fabrica", supervisor: "fabrica", admin: "fabrica" },
  almacen_logistica: { operador: "logistica", supervisor: "logistica", admin: "logistica" },
  administracion: { operador: "finanzas", supervisor: "admin_financiero", admin: "admin_financiero" },
  compras: { operador: "compras", supervisor: "compras", admin: "compras" },
  direccion: { operador: "coordinador", supervisor: "coordinador", admin: "admin" },
};

serve(async (req) => {
  const CORS = corsHeaders(req);
  const correlacion = correlacionDe(req);
  const respond = (body: Record<string, unknown>, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json", "x-request-id": correlacion } });

  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return respond({ error: "Unauthorized" }, 401);

    // 1. Quién llama: se identifica ANTES de usar la llave de servicio.
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

    const body = await req.json().catch(() => null) as Record<string, unknown> | null;
    if (!body || typeof body.user_id !== "string" || !body.user_id) return respond({ error: "user_id es obligatorio" }, 400);
    const user_id = body.user_id;

    const actor = await cargarActor(supabaseAdmin, caller.id);
    const { destino, perfil } = await cargarDestino(supabaseAdmin, user_id);
    if (!perfil && destino.area === null) return respond({ error: "Usuario no encontrado" }, 404);

    // 2. Qué cambia de verdad (no lo que viene en la petición): el front manda todos los campos.
    const txt = (v: unknown) => (typeof v === "string" ? v.trim() : undefined);
    const nombre = txt(body.nombre_completo);
    const email = txt(body.email)?.toLowerCase();
    const codigo = body.codigo_vendedor === null ? null : txt(body.codigo_vendedor);
    const flag = (v: unknown) => (typeof v === "boolean" ? v : undefined);
    const activo = flag(body.activo);
    let esVendedor = flag(body.es_vendedor);
    let esAdministrativo = flag(body.es_administrativo);
    const hayArea = body.area !== undefined && body.area !== null && body.area !== "";
    const hayNivel = body.nivel !== undefined && body.nivel !== null && body.nivel !== "";
    if (hayArea !== hayNivel) return respond({ error: "area y nivel se cambian juntos" }, 400);
    if (hayArea && !areaValida(body.area)) return respond({ error: "Área inválida" }, 400);
    if (hayNivel && !nivelValido(body.nivel)) return respond({ error: "Tipo de usuario inválido" }, 400);
    const area = hayArea ? (body.area as string) : undefined;
    const nivel = hayNivel ? (body.nivel as string) : undefined;
    // Fuera de Comercial no hay función comercial que guardar.
    if (area && area !== "comercial") { esVendedor = false; esAdministrativo = false; }

    const cambiaRol = !!area && !!nivel && (area !== destino.area || nivel !== destino.nivel);
    const cambio: Cambio = {
      nombre: nombre !== undefined && nombre !== (perfil?.nombre_completo ?? ""),
      email: email !== undefined && email !== (perfil?.email ?? "").toLowerCase(),
      codigoVendedor: codigo !== undefined && (codigo || null) !== (perfil?.codigo_vendedor ?? null),
      activo: activo !== undefined && activo !== (perfil?.activo ?? true),
      esVendedor: esVendedor !== undefined && esVendedor !== (perfil?.es_vendedor ?? false),
      esAdministrativo: esAdministrativo !== undefined && esAdministrativo !== (perfil?.es_administrativo ?? false),
      area: cambiaRol ? (area as Cambio["area"]) : undefined,
      nivel: cambiaRol ? (nivel as Cambio["nivel"]) : undefined,
    };

    // 3. Las mismas reglas que aplica la base cuando escribe una sesión de usuario.
    const decision = puedeEditarUsuario(actor, destino, cambio);
    if (!decision.ok) return respond({ error: decision.error }, decision.status);

    const hayCambio = Object.values(cambio).some((v) => v !== undefined && v !== false);
    if (!hayCambio) return respond({ success: true, message: "Sin cambios", updated: {} });

    // 4. Rastro ANTES de cambiar: si no se puede dejar, no se cambia nada.
    const rastroOk = await dejarRastro(supabaseAdmin, {
      accion: "usuario.editar",
      objetivo: user_id,
      actor: { id: caller.id, email: caller.email },
      correlacion,
      detalle: {
        campos: Object.entries(cambio).filter(([, v]) => v !== undefined && v !== false).map(([k]) => k),
        activo: cambio.activo ? activo : undefined, es_vendedor: cambio.esVendedor ? esVendedor : undefined,
        es_administrativo: cambio.esAdministrativo ? esAdministrativo : undefined,
        area_nueva: cambio.area, nivel_nuevo: cambio.nivel, area_anterior: destino.area, nivel_anterior: destino.nivel,
      },
    });
    if (!rastroOk) return respond({ error: "No se pudo registrar el cambio; no se aplicó nada. Intenta de nuevo." }, 503);

    // 5. Aplicar solo lo que cambió.
    if (cambio.email && email) {
      const { error: authUpdateError } = await supabaseAdmin.auth.admin.updateUserById(user_id, { email });
      if (authUpdateError) return respond({ error: `Error actualizando auth.users: ${authUpdateError.message}` }, 400);
    }

    const parche: Record<string, unknown> = {};
    if (cambio.nombre && nombre) parche.nombre_completo = nombre;
    if (cambio.email && email) parche.email = email;
    if (cambio.codigoVendedor) parche.codigo_vendedor = codigo || null;
    if (cambio.activo) parche.activo = activo;
    if (cambio.esVendedor) parche.es_vendedor = esVendedor;
    if (cambio.esAdministrativo) parche.es_administrativo = esAdministrativo;
    if (Object.keys(parche).length > 0) {
      const { error: profileError } = await supabaseAdmin.from("profiles").update(parche).eq("id", user_id);
      if (profileError) return respond({ error: `Error actualizando profiles: ${profileError.message}` }, 500);
    }

    if (cambiaRol && area && nivel) {
      // Una sola instrucción (antes: borrar y volver a insertar, con una ventana sin rol).
      const { error: roleError } = await supabaseAdmin
        .from("user_roles")
        .upsert({ user_id, area, nivel, role: LEGACY_ROLE[area]?.[nivel] || "ventas" }, { onConflict: "user_id" });
      if (roleError) return respond({ error: `Error actualizando user_roles: ${roleError.message}` }, 500);
    }

    return respond({
      success: true,
      message: "Usuario actualizado correctamente",
      updated: { email: parche.email, nombre_completo: parche.nombre_completo, area: cambiaRol ? area : undefined, nivel: cambiaRol ? nivel : undefined, activo: parche.activo },
    });
  } catch (error) {
    console.error("Error en admin-update-user:", error instanceof Error ? error.message : String(error));
    return respond({ error: error instanceof Error ? error.message : "Error inesperado" }, 500);
  }
});

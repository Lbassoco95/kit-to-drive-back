// RH manda accesos a un colaborador "por ingresar" cuyo contrato (firmado en
// WeTrust) ya se subió. Es el ÚNICO camino para que RH cree usuarios:
//  · exige que quien llama sea RH (rh_es_rh, con su propio JWT);
//  · exige contrato firmado en `rh_contratos` (si no, 409);
//  · crea el usuario con el área de la plantilla y nivel operador o supervisor
//    (NUNCA admin: los administradores se dan de alta en Usuarios);
//  · la contraseña se genera aquí y viaja solo por correo; el correo sale
//    ANTES de crear la cuenta (si no sale, no se toca nada).
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { autorizarAlta, enviarAcceso, generarPassword, MENSAJE_CORREO } from "../_shared/acceso.ts";

const ALLOWED_ORIGINS = [
  "https://kit-to-drive.vercel.app",
  "http://localhost:5173",
  "http://localhost:3000",
];

function corsHeaders(req: Request) {
  const origin = req.headers.get("Origin") ?? "";
  const allow = ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0];
  return {
    "Access-Control-Allow-Origin": allow,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Vary": "Origin",
  };
}

const rolLegacy = (a: string, n: string) => {
  if (a === "comercial") return n === "supervisor" ? "coordinador_ventas" : "ventas";
  if (a === "fabrica") return "fabrica";
  if (a === "almacen_logistica") return "logistica";
  if (a === "administracion") return n === "operador" ? "finanzas" : "admin_financiero";
  if (a === "compras") return "compras";
  return "coordinador";
};

serve(async (req) => {
  const CORS = corsHeaders(req);
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return new Response("Unauthorized", { status: 401, headers: CORS });

    // Cliente con el JWT de quien llama: sus RPC validan con su propia sesión.
    const supabaseClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user: caller }, error: authErr } = await supabaseClient.auth.getUser();
    if (authErr || !caller) return new Response("Unauthorized", { status: 401, headers: CORS });

    const { data: esRh, error: rhErr } = await supabaseClient.rpc("rh_es_rh");
    if (rhErr || !esRh) return json({ error: "Forbidden: solo RH puede mandar accesos" }, 403);

    const body = await req.json().catch(() => ({}));
    const empleadoId = typeof body?.empleado_id === "string" ? body.empleado_id : "";
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(empleadoId)) {
      return json({ error: "empleado_id es obligatorio" }, 400);
    }

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data: emp } = await supabaseAdmin
      .from("rh_empleados")
      .select("id, user_id, nombre, correo, estatus, nivel_acceso, area:rh_areas(user_area)")
      .eq("id", empleadoId)
      .maybeSingle();
    if (!emp) return json({ error: "Colaborador no encontrado" }, 404);
    if (emp.user_id) return json({ error: "Este colaborador ya tiene usuario.", code: "YA_TIENE_USUARIO" }, 409);

    const { data: firmado } = await supabaseAdmin
      .from("rh_contratos")
      .select("id")
      .eq("empleado_id", empleadoId)
      .eq("estatus", "firmado")
      .limit(1)
      .maybeSingle();
    if (!firmado) {
      return json({ error: "Primero sube el contrato firmado: sin él no se mandan accesos.", code: "SIN_CONTRATO_FIRMADO" }, 409);
    }

    const email = String(emp.correo ?? "").toLowerCase().trim();
    const nombre = String(emp.nombre ?? "").trim();
    // deno-lint-ignore no-explicit-any
    const area = (emp.area as any)?.user_area as string | undefined;
    const nivel = emp.nivel_acceso as string;
    if (!email || !nombre) return json({ error: "Falta el correo o el nombre del colaborador." }, 400);
    if (!area) return json({ error: "El área del colaborador no tiene un área de acceso equivalente." }, 400);
    // Nunca se crean administradores desde RH.
    if (!["operador", "supervisor"].includes(nivel)) return json({ error: "Tipo de usuario inválido" }, 400);

    // ¿Ya existe una cuenta con ese correo?
    let existente: { id: string; user_metadata?: Record<string, unknown>; app_metadata?: Record<string, unknown> } | undefined;
    for (let page = 1; page <= 10 && !existente; page++) {
      const { data: list, error: listErr } = await supabaseAdmin.auth.admin.listUsers({ page, perPage: 200 });
      if (listErr) return json({ error: listErr.message }, 500);
      const users = list?.users ?? [];
      existente = users.find((u) => u.email?.toLowerCase() === email);
      if (users.length < 200) break;
    }
    if (existente) {
      const { data: rolExistente } = await supabaseAdmin
        .from("user_roles").select("user_id").eq("user_id", existente.id).maybeSingle();
      if (rolExistente) {
        return json({ error: "Ese correo ya tiene usuario. Edítalo en Usuarios.", code: "USUARIO_EXISTE" }, 409);
      }
    }

    // El correo va PRIMERO: si no sale, no se crea ni se cambia nada.
    const password = generarPassword();
    const envio = await enviarAcceso(email, nombre, password, !!existente);
    if (!envio.ok) {
      return json({ error: MENSAJE_CORREO[envio.motivo], code: "CORREO_FALLO" }, envio.motivo === "no_configurado" ? 503 : 502);
    }

    const appMeta = { must_change_password: true, created_via_admin: true, managed_by: "rh-enviar-accesos" };
    const userMeta = { full_name: nombre, must_change_password: false };
    let uid: string;
    if (existente) {
      const { error: updateErr } = await supabaseAdmin.auth.admin.updateUserById(existente.id, {
        password, email_confirm: true,
        app_metadata: { ...(existente.app_metadata || {}), ...appMeta },
        user_metadata: { ...(existente.user_metadata || {}), ...userMeta },
      });
      if (updateErr) return json({ error: updateErr.message }, 400);
      uid = existente.id;
    } else {
      // El candado de la base solo deja pasar altas autorizadas (el registro público sigue cerrado).
      await autorizarAlta(supabaseAdmin, email);
      const { data: newUser, error: createErr } = await supabaseAdmin.auth.admin.createUser({
        email, password, email_confirm: true, app_metadata: appMeta, user_metadata: userMeta,
      });
      if (createErr) return json({ error: createErr.message }, 400);
      uid = newUser.user!.id;
    }

    await supabaseAdmin.from("profiles").upsert({
      id: uid, email, nombre_completo: nombre, activo: true, debe_cambiar_password: true,
      es_vendedor: area === "comercial", es_administrativo: false,
    });
    await supabaseAdmin.from("user_roles").upsert(
      { user_id: uid, area, nivel, role: rolLegacy(area, nivel) },
      { onConflict: "user_id" },
    );

    // Liga la ficha con el usuario (valida RH y contrato firmado otra vez, en la base).
    const { error: linkErr } = await supabaseClient.rpc("rh_vincular_usuario", { _empleado: empleadoId, _user: uid });
    if (linkErr) return json({ error: linkErr.message, code: "VINCULO_FALLO", user_id: uid }, 500);

    return json({ user_id: uid, email, area, nivel, correo: { enviado: true } });
  } catch (err) {
    return json({ error: err instanceof Error ? err.message : String(err) }, 500);
  }
});

#!/usr/bin/env node
/**
 * Alta de 4 cuentas demo en producción (proyecto kit-to-drive). PROPUESTA: NO se ha ejecutado.
 *
 * Hace lo mismo que la función admin-create-user (la que usa la pantalla de Usuarios), paso por paso y en el mismo
 * orden, con DOS diferencias obligadas que Polo debe aprobar:
 *   · NO envía correo (las direcciones no tienen buzón), así que la contraseña no puede viajar por correo;
 *   · la contraseña se genera aquí y se imprime UNA vez, solo en esta terminal.
 * Pasos por cuenta (igual que la función): 1) rastro en bridge_bitacora (si falla, no se crea nada)
 * 2) autorizar el alta en altas_autorizadas 3) crear en Auth (Admin API, correo confirmado, sin enviar nada)
 * 4) upsert en profiles 5) upsert en user_roles. Nunca toca cuentas existentes: si alguno de los 4 correos ya existe, aborta.
 *
 * Uso (en la terminal de Polo; la llave NO se pega en el chat ni se guarda en ningún archivo):
 *   read -rs SUPABASE_SERVICE_ROLE_KEY; export SUPABASE_SERVICE_ROLE_KEY     # (zsh/bash) escribe la llave y Enter
 *   export SUPABASE_URL=https://dmhzhyeivvuliumcgsmm.supabase.co
 *   node crear-cuentas-demo.mjs                  # ensayo: solo lee y muestra el plan y los conteos
 *   CONFIRMO_VENTANA=2026-10-26 node crear-cuentas-demo.mjs --ejecutar
 * Requiere Node 18 o superior. Sin dependencias.
 */
import { randomInt, randomUUID } from "node:crypto";

const REF_PRODUCCION = "dmhzhyeivvuliumcgsmm";
const REF_QA = "qszllskpizvpnzcytqpj";
const VENTANA = "2026-10-26";

// ── Lista exacta de cuentas (PROPUESTA de perfiles: pendiente de aprobación) ────────────────────────────────────
const CUENTAS = [
  { email: "demo.vendedor@demo.kawiil.mx",  nombre: "DEMO Vendedor",  area: "comercial", nivel: "operador", es_vendedor: true },
  { email: "demo.operador@demo.kawiil.mx",  nombre: "DEMO Operador",  area: "fabrica",   nivel: "operador", es_vendedor: false },
  { email: "demo.direccion@demo.kawiil.mx", nombre: "DEMO Dirección", area: "direccion", nivel: "supervisor", es_vendedor: false },
  { email: "demo.lectura@demo.kawiil.mx",   nombre: "DEMO Lectura",   area: "direccion", nivel: "operador", es_vendedor: false },
];
// Mismo mapeo (área, nivel) → rol heredado que admin-create-user.
const rolLegacy = (a, n) => a === "comercial" ? (n === "admin" ? "director_ventas" : n === "supervisor" ? "coordinador_ventas" : "ventas")
  : a === "fabrica" ? "fabrica" : a === "almacen_logistica" ? "logistica"
  : a === "administracion" ? (n === "operador" ? "finanzas" : "admin_financiero") : a === "compras" ? "compras"
  : (n === "admin" ? "admin" : "coordinador");

const url = (process.env.SUPABASE_URL || "").replace(/\/+$/, "");
const llave = process.env.SUPABASE_SERVICE_ROLE_KEY || "";
const ejecutar = process.argv.includes("--ejecutar");
const falla = (m) => { console.error("ABORTA: " + m); process.exit(1); };

// ── Guardas de proyecto (antes de cualquier llamada) ────────────────────────────────────────────────────────────
const hostLocalDePrueba = /^http:\/\/127\.0\.0\.1:\d+$/.test(url);   // solo para el ensayo con un servidor falso local
if (!hostLocalDePrueba) {
  if (url.includes(REF_QA)) falla("la URL es la de QA: este script es solo para producción y no toca QA");
  if (url !== `https://${REF_PRODUCCION}.supabase.co`) falla(`la URL debe ser exactamente https://${REF_PRODUCCION}.supabase.co`);
}
if (!llave) falla("falta SUPABASE_SERVICE_ROLE_KEY en el entorno");
try {
  const p = JSON.parse(Buffer.from(llave.split(".")[1], "base64url").toString("utf8"));
  if (p.role !== "service_role") falla("la llave no es de rol service_role");
  if (!hostLocalDePrueba && p.ref !== REF_PRODUCCION) falla("la llave no pertenece al proyecto de producción");
} catch { falla("la llave no tiene formato de JWT"); }
if (ejecutar && process.env.CONFIRMO_VENTANA !== VENTANA) falla(`para ejecutar hace falta CONFIRMO_VENTANA=${VENTANA}`);

const H = { apikey: llave, Authorization: `Bearer ${llave}` };
async function api(metodo, ruta, cuerpo, extra = {}) {
  const r = await fetch(url + ruta, { method: metodo, headers: { ...H, "Content-Type": "application/json", ...extra }, body: cuerpo ? JSON.stringify(cuerpo) : undefined });
  const texto = await r.text();
  let json; try { json = texto ? JSON.parse(texto) : null; } catch { json = null; }
  return { ok: r.ok, status: r.status, json, headers: r.headers };
}
// Mensajes de error: solo estado y mensaje del servidor, nunca el cuerpo enviado (que lleva la contraseña).
const motivo = (r) => `HTTP ${r.status}${r.json?.message || r.json?.msg || r.json?.error ? " · " + String(r.json.message || r.json.msg || r.json.error).slice(0, 160) : ""}`;

async function conteoTabla(t) {
  const r = await fetch(`${url}/rest/v1/${t}?select=*&limit=1`, { method: "HEAD", headers: { ...H, Prefer: "count=exact" } });
  const m = /\/(\d+)$/.exec(r.headers.get("content-range") || "");
  return m ? Number(m[1]) : null;
}
async function usuariosAuth() {
  const todos = [];
  for (let pagina = 1; pagina <= 20; pagina++) {
    const r = await api("GET", `/auth/v1/admin/users?page=${pagina}&per_page=200`);
    if (!r.ok) falla("no se pudo listar Auth: " + motivo(r));
    const lote = r.json?.users ?? [];
    todos.push(...lote);
    if (lote.length < 200) break;
  }
  return todos;
}
async function conteos() {
  return { "auth.users": (await usuariosAuth()).length, profiles: await conteoTabla("profiles"), user_roles: await conteoTabla("user_roles"),
           bridge_bitacora: await conteoTabla("bridge_bitacora"), altas_autorizadas: await conteoTabla("altas_autorizadas") };
}
function generarPassword(largo = 24) {
  const U = "ABCDEFGHJKLMNPQRSTUVWXYZ", L = "abcdefghijkmnopqrstuvwxyz", D = "23456789", S = "!@#$%&*-_=+";
  const todo = U + L + D + S, pick = (c) => c[randomInt(c.length)];
  const out = [pick(U), pick(L), pick(D), pick(S)];
  while (out.length < largo) out.push(pick(todo));
  for (let i = out.length - 1; i > 0; i--) { const j = randomInt(i + 1); [out[i], out[j]] = [out[j], out[i]]; }
  return out.join("");
}

// ── Lectura previa ──────────────────────────────────────────────────────────────────────────────────────────────
const antes = await conteos();
const existentes = (await usuariosAuth()).map((u) => (u.email || "").toLowerCase());
const yaExisten = CUENTAS.filter((c) => existentes.includes(c.email));
if (yaExisten.length) falla("ya existe(n): " + yaExisten.map((c) => c.email).join(", ") + ". No se toca ninguna cuenta existente.");

console.log("Proyecto:", url.replace("https://", "").replace(".supabase.co", ""), hostLocalDePrueba ? "(servidor local de ensayo)" : "(producción)");
console.log("Cuentas a crear:");
for (const c of CUENTAS) console.log(`  ${c.email.padEnd(34)} ${c.area}/${c.nivel}${c.es_vendedor ? " · es_vendedor" : ""}  (rol heredado: ${rolLegacy(c.area, c.nivel)})`);
console.log("Conteos antes:", JSON.stringify(antes));
if (!ejecutar) { console.log("\nEnsayo: no se escribió nada. Para crear: CONFIRMO_VENTANA=" + VENTANA + " node crear-cuentas-demo.mjs --ejecutar"); process.exit(0); }

// ── Alta (mismos pasos y orden que admin-create-user, sin correo) ──────────────────────────────────────────────
const password = generarPassword();
const correlacion = randomUUID();
const creadas = [];
for (const c of CUENTAS) {
  // 1) Rastro antes de cambiar nada: si no se puede dejar, no se crea la cuenta.
  let r = await api("POST", "/rest/v1/bridge_bitacora", { accion: "usuario.crear", objetivo: c.email,
    detalle: { area: c.area, nivel: c.nivel, reutiliza_cuenta: false, actor: "script-cuentas-demo", correlacion, origen: "script", ventana: VENTANA } });
  if (!r.ok) falla(`rastro de ${c.email}: ${motivo(r)}. No se creó esa cuenta. Ya creadas: ${creadas.join(", ") || "ninguna"}.`);
  // 2) Alta autorizada (el candado de la base solo deja pasar altas autorizadas).
  r = await api("POST", "/rest/v1/altas_autorizadas?on_conflict=email", { email: c.email, expira_at: new Date(Date.now() + 3 * 60_000).toISOString() },
    { Prefer: "resolution=merge-duplicates,return=minimal" });
  if (!r.ok) falla(`autorizar alta de ${c.email}: ${motivo(r)}. Ya creadas: ${creadas.join(", ") || "ninguna"}.`);
  // 3) Auth: correo confirmado, sin enviar correo. La marca de demo va en app_metadata (solo la Admin API la escribe).
  r = await api("POST", "/auth/v1/admin/users", { email: c.email, password, email_confirm: true,
    app_metadata: { must_change_password: false, created_via_admin: true, managed_by: "cuentas-demo", demo: true },
    user_metadata: { full_name: c.nombre, must_change_password: false } });
  if (!r.ok || !r.json?.id) falla(`crear ${c.email} en Auth: ${motivo(r)}. Ya creadas: ${creadas.join(", ") || "ninguna"}.`);
  const uid = r.json.id;
  // 4) Perfil. 5) Tipo de usuario.
  r = await api("POST", "/rest/v1/profiles?on_conflict=id", { id: uid, email: c.email, nombre_completo: c.nombre, codigo_vendedor: null,
    es_vendedor: c.es_vendedor, es_administrativo: false, activo: true, debe_cambiar_password: false },
    { Prefer: "resolution=merge-duplicates,return=minimal" });
  if (!r.ok) falla(`perfil de ${c.email}: ${motivo(r)}. La cuenta de Auth YA existe (${uid.slice(0, 8)}…): no se borra; revisar a mano.`);
  r = await api("POST", "/rest/v1/user_roles?on_conflict=user_id", { user_id: uid, area: c.area, nivel: c.nivel, role: rolLegacy(c.area, c.nivel) },
    { Prefer: "resolution=merge-duplicates,return=minimal" });
  if (!r.ok) falla(`tipo de usuario de ${c.email}: ${motivo(r)}. La cuenta de Auth YA existe (${uid.slice(0, 8)}…): no se borra; revisar a mano.`);
  creadas.push(c.email);
  console.log("  creada:", c.email);
}

const despues = await conteos();
console.log("\nConteos antes :", JSON.stringify(antes));
console.log("Conteos después:", JSON.stringify(despues));
console.log("\n" + "=".repeat(64));
console.log("CONTRASEÑA (la misma para las 4 cuentas; se muestra UNA sola vez):");
console.log("  " + password);
console.log("=".repeat(64));
console.log("Cópiala a donde corresponda y limpia el historial de la terminal (clear / cerrar la pestaña).");

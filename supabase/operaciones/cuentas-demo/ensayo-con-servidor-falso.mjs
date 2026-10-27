// Ensayo de crear-cuentas-demo.mjs contra un servidor FALSO en 127.0.0.1 (no usa red ni credenciales reales).
// Comprueba: orden de pasos por cuenta, que el ensayo no escribe, que la contraseña sale una sola vez y solo en stdout,
// que no toca cuentas existentes, que respeta las guardas de proyecto y que se detiene al primer error.
import http from "node:http";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
const aqui = dirname(fileURLToPath(import.meta.url));
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const llave = `${b64({ alg: "HS256" })}.${b64({ role: "service_role", ref: "falso" })}.firma`;

function servidor({ existentes = [], fallaEn = null } = {}) {
  const bitacora = [], tablas = { profiles: 5, user_roles: 4, bridge_bitacora: 3, altas_autorizadas: 0, inventario_usuarios_prueba: 7 }; let usuarios = existentes.map((e) => ({ id: "u-" + e, email: e }));
  const s = http.createServer((req, res) => {
    let cuerpo = ""; req.on("data", (d) => cuerpo += d); req.on("end", () => {
      const ruta = req.url.split("?")[0]; const j = cuerpo ? JSON.parse(cuerpo) : null; const escribe = req.method !== "GET" && req.method !== "HEAD";
      bitacora.push({ m: req.method, ruta, email: j?.email ?? j?.objetivo ?? null, tienePassword: !!j?.password, cuerpo });
      const ok = (x, st = 200, h = {}) => { res.writeHead(st, { "content-type": "application/json", ...h }); res.end(x ? JSON.stringify(x) : ""); };
      if (fallaEn && ruta === fallaEn && escribe) return ok({ message: "fallo simulado" }, 500);
      if (ruta === "/auth/v1/admin/users" && req.method === "GET") return ok({ users: usuarios });
      if (ruta === "/auth/v1/admin/users" && escribe) { const u = { id: "id-" + usuarios.length, email: j.email }; usuarios.push(u); return ok(u); }
      const t = ruta.replace("/rest/v1/", "");
      if (req.method === "HEAD") return ok(null, 200, { "content-range": `0-0/${tablas[t] ?? 0}` });
      if (escribe) { if (t in tablas) tablas[t]++; return ok(null, 201); }
      ok([]);
    });
  });
  return new Promise((r) => s.listen(0, "127.0.0.1", () => r({ s, bitacora, puerto: s.address().port })));
}
function lanza(env, args = []) {
  return new Promise((res) => {
    const p = spawn("node", [join(aqui, "crear-cuentas-demo.mjs"), ...args], { env: { PATH: process.env.PATH, ...env } });
    let stdout = "", stderr = ""; p.stdout.on("data", (d) => stdout += d); p.stderr.on("data", (d) => stderr += d);
    p.on("close", (status) => res({ status, stdout, stderr }));
  });
}
const corre = (puerto, args = [], env = {}) => lanza({ SUPABASE_URL: `http://127.0.0.1:${puerto}`, SUPABASE_SERVICE_ROLE_KEY: llave, ...env }, args);
let fallos = 0; const T = (n, c) => { console.log((c ? "ok   " : "FALLA ") + n); if (!c) fallos++; };

{ const { s, bitacora, puerto } = await servidor(); const r = await corre(puerto);
  T("ensayo (sin --ejecutar): no escribe nada", bitacora.every((x) => x.m === "GET" || x.m === "HEAD") && r.status === 0);
  s.close(); }
{ const { s, bitacora, puerto } = await servidor(); const r = await corre(puerto, ["--ejecutar"]);
  T("--ejecutar sin CONFIRMO_VENTANA aborta y no escribe", r.status !== 0 && bitacora.length === 0);
  s.close(); }
{ const { s, bitacora, puerto } = await servidor(); const r = await corre(puerto, ["--ejecutar"], { CONFIRMO_VENTANA: "2026-10-26" });
  const esc = bitacora.filter((x) => x.m === "POST").map((x) => x.ruta);
  const porCuenta = ["/rest/v1/bridge_bitacora", "/rest/v1/inventario_usuarios_prueba", "/rest/v1/altas_autorizadas", "/auth/v1/admin/users", "/rest/v1/profiles", "/rest/v1/user_roles"];
  T("ejecución: 3 cuentas × 6 pasos (rastro, modo prueba, alta autorizada, Auth, perfil, rol)", r.status === 0 && JSON.stringify(esc) === JSON.stringify(Array(3).fill(porCuenta).flat()));
  T("los tres correos empiezan con prueba. y terminan en @demo.kawiil.mx", bitacora.filter((x) => x.ruta === "/auth/v1/admin/users" && x.m === "POST").every((x) => /^prueba\.(vendedor|operador|direccion)@demo\.kawiil\.mx$/.test(x.email)) && bitacora.filter((x) => x.ruta === "/auth/v1/admin/users" && x.m === "POST").length === 3);
  T("el registro de modo prueba va ANTES de crear la cuenta en Auth, para cada cuenta", (() => { const i = bitacora.filter((x) => x.m === "POST").map((x) => x.ruta + "|" + x.email); const a = i.indexOf("/rest/v1/inventario_usuarios_prueba|prueba.vendedor@demo.kawiil.mx"), b = i.indexOf("/auth/v1/admin/users|prueba.vendedor@demo.kawiil.mx"); return a >= 0 && b > a; })());
  const pw = bitacora.find((x) => x.tienePassword); const clave = JSON.parse(pw.cuerpo).password;
  T("contraseña de al menos 20 caracteres con las 4 clases", clave.length >= 20 && /[a-z]/.test(clave) && /[A-Z]/.test(clave) && /\d/.test(clave) && /[^A-Za-z0-9]/.test(clave));
  T("la misma contraseña para las 3 cuentas y solo en la llamada de Auth", bitacora.filter((x) => x.tienePassword).length === 3 && bitacora.filter((x) => x.cuerpo.includes(clave)).length === 3);
  T("la contraseña sale UNA vez en stdout y nunca en stderr", r.stdout.split(clave).length === 2 && !r.stderr.includes(clave));
  T("la llave de servicio no sale ni en stdout ni en stderr", !r.stdout.includes(llave) && !r.stderr.includes(llave));
  T("no se llama a ninguna ruta de correo ni de invitación", !bitacora.some((x) => /invite|recover|magiclink|otp|verify/.test(x.ruta)));
  s.close(); }
{ const { s, bitacora, puerto } = await servidor({ existentes: ["prueba.direccion@demo.kawiil.mx"] }); const r = await corre(puerto, ["--ejecutar"], { CONFIRMO_VENTANA: "2026-10-26" });
  T("si uno de los correos ya existe, aborta sin escribir", r.status !== 0 && !bitacora.some((x) => x.m === "POST"));
  s.close(); }
{ const { s, bitacora, puerto } = await servidor({ fallaEn: "/rest/v1/profiles" }); const r = await corre(puerto, ["--ejecutar"], { CONFIRMO_VENTANA: "2026-10-26" });
  const clave = JSON.parse(bitacora.find((x) => x.tienePassword).cuerpo).password;
  T("si falla el perfil se detiene en la primera cuenta, no borra nada y no imprime la contraseña", r.status !== 0 && bitacora.filter((x) => x.m === "POST" && x.ruta === "/auth/v1/admin/users").length === 1 && !bitacora.some((x) => x.m === "DELETE") && !r.stdout.includes(clave) && !r.stderr.includes(clave));
  s.close(); }
{ const r = await lanza({ SUPABASE_URL: "https://qszllskpizvpnzcytqpj.supabase.co", SUPABASE_SERVICE_ROLE_KEY: llave });
  T("la URL de QA se rechaza", r.status !== 0 && /QA/.test(r.stderr)); }
{ const r = await lanza({ SUPABASE_URL: "https://otro.supabase.co", SUPABASE_SERVICE_ROLE_KEY: llave });
  T("cualquier otra URL se rechaza", r.status !== 0); }
process.exit(fallos ? 1 : 0);

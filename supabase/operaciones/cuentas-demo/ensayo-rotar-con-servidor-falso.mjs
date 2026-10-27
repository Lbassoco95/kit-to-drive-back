import http from "node:http"; import { spawn } from "node:child_process"; import { fileURLToPath } from "node:url"; import { dirname, join } from "node:path";
const aqui = dirname(fileURLToPath(import.meta.url)); const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const llave = `${b64({ alg: "HS256" })}.${b64({ role: "service_role", ref: "falso" })}.firma`;
const C = ["prueba.vendedor@demo.kawiil.mx", "prueba.operador@demo.kawiil.mx", "prueba.direccion@demo.kawiil.mx"];
function servidor({ sinMarca = false, extra = [] } = {}) {
  const reg = []; const users = [...C.map((e, i) => ({ id: "id" + i, email: e, app_metadata: sinMarca && i === 1 ? {} : { managed_by: "cuentas-demo" } })), ...extra];
  const s = http.createServer((q, r) => { let b = ""; q.on("data", (d) => b += d); q.on("end", () => { reg.push({ m: q.method, ruta: q.url.split("?")[0], b });
    r.writeHead(200, { "content-type": "application/json" }); r.end(q.method === "GET" ? JSON.stringify({ users }) : "{}"); }); });
  return new Promise((ok) => s.listen(0, "127.0.0.1", () => ok({ s, reg, puerto: s.address().port })));
}
const lanza = (puerto, args = [], env = {}) => new Promise((res) => { const p = spawn("node", [join(aqui, "rotar-password-cuentas-demo.mjs"), ...args], { env: { PATH: process.env.PATH, SUPABASE_URL: `http://127.0.0.1:${puerto}`, SUPABASE_SERVICE_ROLE_KEY: llave, ...env } }); let o = "", e = ""; p.stdout.on("data", (d) => o += d); p.stderr.on("data", (d) => e += d); p.on("close", (st) => res({ st, o, e })); });
let f = 0; const T = (n, c) => { console.log((c ? "ok   " : "FALLA ") + n); if (!c) f++; };
{ const { s, reg, puerto } = await servidor(); const r = await lanza(puerto); T("ensayo no escribe", r.st === 0 && reg.every((x) => x.m === "GET")); s.close(); }
{ const { s, reg, puerto } = await servidor(); const r = await lanza(puerto, ["--ejecutar"]); T("sin CONFIRMO_VENTANA aborta y no escribe", r.st !== 0 && !reg.some((x) => x.m !== "GET")); s.close(); }
{ const { s, reg, puerto } = await servidor(); const r = await lanza(puerto, ["--ejecutar"], { CONFIRMO_VENTANA: "2026-10-26" });
  const puts = reg.filter((x) => x.m === "PUT"); const pw = JSON.parse(puts[0].b).password;
  T("3 PUT, uno por cuenta, solo con password", r.st === 0 && puts.length === 3 && puts.every((x) => Object.keys(JSON.parse(x.b)).join() === "password"));
  T("misma contraseña de 24 con las 4 clases", puts.every((x) => JSON.parse(x.b).password === pw) && pw.length === 24 && /[a-z]/.test(pw) && /[A-Z]/.test(pw) && /\d/.test(pw) && /[^A-Za-z0-9]/.test(pw));
  T("la contraseña sale una vez, solo en stdout; la llave nunca", r.o.split(pw).length === 2 && !r.e.includes(pw) && !r.o.includes(llave) && !r.e.includes(llave)); s.close(); }
{ const { s, reg, puerto } = await servidor({ sinMarca: true }); const r = await lanza(puerto, ["--ejecutar"], { CONFIRMO_VENTANA: "2026-10-26" }); T("si una cuenta no tiene la marca de demo, aborta sin tocar nada", r.st !== 0 && !reg.some((x) => x.m === "PUT")); s.close(); }
{ const { s, reg, puerto } = await servidor({ extra: [{ id: "x", email: "otra@real.mx", app_metadata: {} }] }); await lanza(puerto, ["--ejecutar"], { CONFIRMO_VENTANA: "2026-10-26" }); T("nunca toca otras cuentas", reg.filter((x) => x.m === "PUT").every((x) => /id[012]$/.test(x.ruta))); s.close(); }
process.exit(f ? 1 : 0);

import http from "node:http"; import { spawn } from "node:child_process"; import { fileURLToPath } from "node:url"; import { dirname, join } from "node:path"; import { mkdtempSync, writeFileSync, readFileSync, chmodSync, existsSync } from "node:fs"; import { tmpdir } from "node:os";
const aqui = dirname(fileURLToPath(import.meta.url)); const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const llave = `${b64({ alg: "HS256" })}.${b64({ role: "service_role", ref: "falso" })}.firma`;
const C = ["prueba.vendedor@demo.kawiil.mx", "prueba.operador@demo.kawiil.mx", "prueba.direccion@demo.kawiil.mx"];
function servidor({ sinMarca = false, extra = [], quitar = -1 } = {}) {
  const reg = []; const users = [...C.filter((_, i) => i !== quitar).map((e, i) => ({ id: "id" + i, email: e, app_metadata: sinMarca && i === 1 ? {} : { managed_by: "cuentas-demo" } })), ...extra];
  const s = http.createServer((q, r) => { let b = ""; q.on("data", (d) => b += d); q.on("end", () => { reg.push({ m: q.method, ruta: q.url.split("?")[0], b });
    r.writeHead(200, { "content-type": "application/json" }); r.end(q.method === "GET" ? JSON.stringify({ users }) : "{}"); }); });
  return new Promise((ok) => s.listen(0, "127.0.0.1", () => ok({ s, reg, puerto: s.address().port })));
}
// Portapapeles FALSO: un ejecutable «pbcopy» que escribe lo que recibe en un archivo; así se puede comprobar qué se copió.
function entorno(modo) { const d = mkdtempSync(join(tmpdir(), "pb-")); const dest = join(d, "portapapeles.txt");
  if (modo === "bien") { writeFileSync(join(d, "pbcopy"), `#!/bin/sh\ncat > "${dest}"\n`); chmodSync(join(d, "pbcopy"), 0o755); }
  if (modo === "falla") { writeFileSync(join(d, "pbcopy"), `#!/bin/sh\ncat >/dev/null\nexit 1\n`); chmodSync(join(d, "pbcopy"), 0o755); }
  const nodeDir = dirname(process.execPath); return { PATH: modo === "ausente" ? `${nodeDir}:/usr/bin:/bin` : `${d}:${nodeDir}:/usr/bin:/bin`, dest }; }
let _modo = "bien", _dest = "";
const lanza = (puerto, args = [], env = {}) => new Promise((res) => { const en = entorno(_modo); _dest = en.dest; const p = spawn("node", [join(aqui, "rotar-password-cuentas-demo.mjs"), ...args], { env: { PATH: en.PATH, SUPABASE_URL: `http://127.0.0.1:${puerto}`, SUPABASE_SERVICE_ROLE_KEY: llave, ...env } }); let o = "", e = ""; p.stdout.on("data", (d) => o += d); p.stderr.on("data", (d) => e += d); p.on("close", (st) => res({ st, o, e })); });
let f = 0; const T = (n, c) => { console.log((c ? "ok   " : "FALLA ") + n); if (!c) f++; };
const OK = { CONFIRMO_VENTANA: "2026-10-26" };
{ _modo = "bien"; const { s, reg, puerto } = await servidor(); const r = await lanza(puerto);
  T("ensayo: no escribe nada y solo nombra a las 3 cuentas", r.st === 0 && reg.every((x) => x.m === "GET") && r.o.trim().split("\n").length === 3); s.close(); }
{ _modo = "bien"; const { s, reg, puerto } = await servidor(); const r = await lanza(puerto, ["--ejecutar"]); T("sin CONFIRMO_VENTANA aborta y no escribe", r.st !== 0 && !reg.some((x) => x.m !== "GET")); s.close(); }
{ _modo = "bien"; const { s, reg, puerto } = await servidor(); const r = await lanza(puerto, ["--ejecutar"], OK);
  const puts = reg.filter((x) => x.m === "PUT"); const pw = JSON.parse(puts[0].b).password; const portapapeles = readFileSync(_dest, "utf8");
  T("3 PUT, uno por cuenta, solo con password", r.st === 0 && puts.length === 3 && puts.every((x) => Object.keys(JSON.parse(x.b)).join() === "password"));
  T("una sola contraseña de 24 caracteres con las 4 clases para las 3 cuentas", puts.every((x) => JSON.parse(x.b).password === pw) && pw.length === 24 && /[a-z]/.test(pw) && /[A-Z]/.test(pw) && /\d/.test(pw) && /[^A-Za-z0-9]/.test(pw));
  T("lo copiado al portapapeles es exactamente la contraseña aplicada", portapapeles === pw);
  T("la salida son EXACTAMENTE 3 líneas «rotada: correo» y nada más", r.o.trim().split("\n").join("|") === "rotada: prueba.vendedor@demo.kawiil.mx|rotada: prueba.operador@demo.kawiil.mx|rotada: prueba.direccion@demo.kawiil.mx");
  T("ni la contraseña ni la llave aparecen en stdout ni en stderr", !r.o.includes(pw) && !r.e.includes(pw) && !r.o.includes(llave) && !r.e.includes(llave) && r.e === ""); s.close(); }
{ _modo = "ausente"; const { s, reg, puerto } = await servidor(); const r = await lanza(puerto, ["--ejecutar"], OK); T("sin pbcopy aborta y NO rota nada", r.st !== 0 && /pbcopy/.test(r.e) && !reg.some((x) => x.m === "PUT")); s.close(); }
{ _modo = "ausente"; const { s, reg, puerto } = await servidor(); const r = await lanza(puerto); T("sin pbcopy el ensayo también avisa", r.st !== 0 && /pbcopy/.test(r.e)); s.close(); }
{ _modo = "falla"; const { s, reg, puerto } = await servidor(); const r = await lanza(puerto, ["--ejecutar"], OK); T("si pbcopy falla, aborta y NO rota nada", r.st !== 0 && !reg.some((x) => x.m === "PUT")); s.close(); }
{ _modo = "bien"; const { s, reg, puerto } = await servidor({ sinMarca: true }); const r = await lanza(puerto, ["--ejecutar"], OK); T("si una cuenta no tiene la marca de demo, aborta sin tocar nada", r.st !== 0 && !reg.some((x) => x.m === "PUT")); s.close(); }
{ _modo = "bien"; const { s, reg, puerto } = await servidor({ extra: [{ id: "x", email: "prueba.otra@demo.kawiil.mx", app_metadata: { managed_by: "cuentas-demo" } }, { id: "y", email: "otra@real.mx", app_metadata: {} }] }); await lanza(puerto, ["--ejecutar"], OK);
  T("con 4 cuentas con marca o una real extra, solo toca las 3 de la lista", reg.filter((x) => x.m === "PUT").length === 3 && reg.filter((x) => x.m === "PUT").every((x) => /id[012]$/.test(x.ruta))); s.close(); }
{ _modo = "bien"; const { s, reg, puerto } = await servidor({ quitar: 1 }); const r = await lanza(puerto, ["--ejecutar"], OK); T("si no son exactamente 3 cuentas, aborta sin tocar nada", r.st !== 0 && !reg.some((x) => x.m === "PUT")); s.close(); }
{ _modo = "bien"; const r = await new Promise((res) => { const en = entorno("bien"); const p = spawn("node", [join(aqui, "rotar-password-cuentas-demo.mjs")], { env: { PATH: en.PATH, SUPABASE_URL: "https://qszllskpizvpnzcytqpj.supabase.co", SUPABASE_SERVICE_ROLE_KEY: llave } }); let e = ""; p.stderr.on("data", (d) => e += d); p.on("close", (st) => res({ st, e })); }); T("la URL de QA se rechaza", r.st !== 0 && /QA/.test(r.e)); }
process.exit(f ? 1 : 0);

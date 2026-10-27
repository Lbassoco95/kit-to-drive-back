#!/usr/bin/env node
/**
 * Rota la contraseña de las 3 cuentas de prueba (prueba.*@demo.kawiil.mx) creadas con crear-cuentas-demo.mjs. NO se ha ejecutado.
 * Cambia SOLO la contraseña (Admin API de Auth). No toca perfiles, roles, bloqueos, sesiones ni ninguna otra cuenta.
 * La nueva contraseña (24 caracteres, la misma para las 3) NO se imprime: se copia al portapapeles de la Mac con pbcopy.
 * Si pbcopy no está disponible o falla, aborta ANTES de rotar nada (así nunca queda una contraseña que nadie pueda recibir).
 * La salida es solo una línea por cuenta: «rotada: correo». Ni la contraseña, ni la llave, ni hashes.
 * Guardas: URL exacta de producción, llave service_role de ese proyecto, y solo cuentas cuyo correo está en la lista Y que
 * llevan app_metadata.managed_by = cuentas-demo (una cuenta real nunca se toca). Si no hay exactamente 3, aborta.
 * Uso: igual que crear-cuentas-demo.mjs; ensayo por defecto y   CONFIRMO_VENTANA=2026-10-26 node rotar-password-cuentas-demo.mjs --ejecutar
 */
import { randomInt } from "node:crypto";
import { spawnSync } from "node:child_process";
const REF = "dmhzhyeivvuliumcgsmm", REF_QA = "qszllskpizvpnzcytqpj", VENTANA = "2026-10-26";
const CORREOS = ["prueba.vendedor@demo.kawiil.mx", "prueba.operador@demo.kawiil.mx", "prueba.direccion@demo.kawiil.mx"];
const url = (process.env.SUPABASE_URL || "").replace(/\/+$/, ""), llave = process.env.SUPABASE_SERVICE_ROLE_KEY || "";
const ejecutar = process.argv.includes("--ejecutar");
const falla = (m) => { console.error("ABORTA: " + m); process.exit(1); };
const local = /^http:\/\/127\.0\.0\.1:\d+$/.test(url);
if (!local) { if (url.includes(REF_QA)) falla("la URL es la de QA"); if (url !== `https://${REF}.supabase.co`) falla(`la URL debe ser exactamente https://${REF}.supabase.co`); }
if (!llave) falla("falta SUPABASE_SERVICE_ROLE_KEY");
try { const p = JSON.parse(Buffer.from(llave.split(".")[1], "base64url").toString()); if (p.role !== "service_role") falla("la llave no es service_role"); if (!local && p.ref !== REF) falla("la llave no es de producción"); } catch { falla("la llave no tiene formato de JWT"); }
if (ejecutar && process.env.CONFIRMO_VENTANA !== VENTANA) falla(`hace falta CONFIRMO_VENTANA=${VENTANA}`);
const H = { apikey: llave, Authorization: `Bearer ${llave}`, "Content-Type": "application/json" };
const motivo = async (r) => { let m = ""; try { const j = await r.json(); m = " · " + String(j.message || j.msg || j.error || "").slice(0, 160); } catch {} return `HTTP ${r.status}${m}`; };
const todos = [];
for (let pagina = 1; pagina <= 20; pagina++) {
  const r = await fetch(`${url}/auth/v1/admin/users?page=${pagina}&per_page=200`, { headers: H });
  if (!r.ok) falla("no se pudo listar Auth: " + await motivo(r));
  const lote = (await r.json()).users ?? []; todos.push(...lote); if (lote.length < 200) break;
}
const cuentas = todos.filter((u) => CORREOS.includes((u.email || "").toLowerCase()));
if (cuentas.length !== 3) falla(`se esperaban 3 cuentas y hay ${cuentas.length}: no se cambió nada`);
const sinMarca = cuentas.filter((u) => u.app_metadata?.managed_by !== "cuentas-demo");
if (sinMarca.length) falla("hay cuenta(s) sin la marca de demo: no se cambió nada");
// pbcopy debe existir ANTES de tocar nada (también en el ensayo, para enterarse temprano).
const hayPbcopy = spawnSync("sh", ["-c", "command -v pbcopy"], { encoding: "utf8" });
if (hayPbcopy.status !== 0 || !hayPbcopy.stdout.trim()) falla("pbcopy no está disponible: no se rotó nada");
if (!ejecutar) { for (const u of cuentas) console.log("ensayo (no se cambió nada):", u.email); process.exit(0); }
const U = "ABCDEFGHJKLMNPQRSTUVWXYZ", L = "abcdefghijkmnopqrstuvwxyz", D = "23456789", S = "!@#$%&*-_=+", T = U + L + D + S, pick = (c) => c[randomInt(c.length)];
const o = [pick(U), pick(L), pick(D), pick(S)]; while (o.length < 24) o.push(pick(T));
for (let i = o.length - 1; i > 0; i--) { const j = randomInt(i + 1); [o[i], o[j]] = [o[j], o[i]]; }
const password = o.join("");
// La contraseña va al portapapeles ANTES de rotar: si no se puede entregar, no se cambia nada.
const copia = spawnSync("pbcopy", [], { input: password });
if (copia.error || copia.status !== 0) falla("no se pudo copiar al portapapeles con pbcopy: no se rotó nada");
const hechas = [];
for (const u of cuentas) {
  const r = await fetch(`${url}/auth/v1/admin/users/${u.id}`, { method: "PUT", headers: H, body: JSON.stringify({ password }) });
  if (!r.ok) falla(`rotar ${u.email}: ${await motivo(r)}. Rotadas antes: ${hechas.join(", ") || "ninguna"}; las demás siguen con la contraseña anterior (el portapapeles ya tiene la nueva: solo vale para las rotadas).`);
  hechas.push(u.email); console.log("rotada:", u.email);
}

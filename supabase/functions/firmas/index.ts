/**
 * Firma electrónica SIMPLE interna. Primer origen: el PDF de una remisión de
 * motocarro (`remisiones.documento_url`, bucket `remisiones-docs`).
 *
 * Solo firmantes INTERNOS (usuarios con cuenta); clientes y proveedores no.
 * No es firma electrónica avanzada ni constancia NOM-151.
 *
 * Acciones (todas exigen sesión; verify_jwt = true):
 *   crear | cancelar | recordar            → quien creó la solicitud
 *   firmar | rechazar                      → un firmante de la solicitud
 *
 * Quién puede mandar a firmar: quien puede LEER la remisión (se comprueba con
 * el JWT de la persona, así RLS decide). La función escribe con service_role;
 * las tablas `firmas_*` son de solo lectura para el front.
 *
 * Secretos opcionales: RESEND_API_KEY + RESEND_FROM_EMAIL (aviso por correo) y
 * KIT_TO_DRIVE_APP_URL. Sin ellos el aviso va solo a la campana de la app.
 */
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { PDFDocument, rgb, StandardFonts, type PDFFont } from "npm:pdf-lib@1.17.1";

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

const BUCKET = "firmas";
const BUCKET_REMISIONES = "remisiones-docs";
const MAX_PDF_BYTES = 15 * 1024 * 1024;
const MAX_FIRMA_BYTES = 600 * 1024;
const MAX_ADJUNTO_CORREO = 3 * 1024 * 1024;
const MAX_FIRMANTES = 10;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

class HttpError extends Error {
  constructor(public status: number, message: string, public code?: string) {
    super(message);
  }
}

type Svc = SupabaseClient;
type Firmante = {
  id: string; solicitud_id: string; orden: number; usuario_id: string; nombre: string; email: string | null;
  estatus: string; notificado_at: string | null; firmado_at: string | null; firmado_ip: string | null;
  ruta_firma: string | null;
};
type Solicitud = {
  id: string; creado_por: string; titulo: string; mensaje: string | null; entidad_tipo: string; entidad_id: string | null;
  nombre_archivo: string; estatus: string; secuencial: boolean; ruta_original: string; sha256_original: string;
  ruta_firmado: string | null; vence_at: string;
};

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(d)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function b64ToBytes(b64: string): Uint8Array {
  const clean = b64.includes(",") ? b64.split(",")[1] : b64;
  const bin = atob(clean);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function bytesToB64(bytes: Uint8Array): string {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

const esPdf = (b: Uint8Array) => b.length > 4 && b[0] === 0x25 && b[1] === 0x50 && b[2] === 0x44 && b[3] === 0x46;
const esPng = (b: Uint8Array) => b.length > 8 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47;

const esc = (s: string) =>
  s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c] as string));

function fmtMx(iso: string): string {
  return new Date(iso).toLocaleString("es-MX", { timeZone: "America/Mexico_City", dateStyle: "medium", timeStyle: "short" }) +
    " (CDMX)";
}

/** IP para la evidencia: la que pone el borde (cf-connecting-ip) o el ÚLTIMO salto; el primero de x-forwarded-for lo escribe el cliente. */
function ipCliente(req: Request): string | null {
  const candidatas = [
    req.headers.get("cf-connecting-ip"),
    req.headers.get("x-real-ip"),
    (req.headers.get("x-forwarded-for") || "").split(",").pop(),
  ];
  for (const c of candidatas) {
    const v = (c ?? "").trim();
    if (v && v.length <= 45 && /^[0-9a-fA-F:.]+$/.test(v)) return v;
  }
  return null;
}

// ---------- Correo (opcional, Resend) ----------
function appUrl(): string {
  return (Deno.env.get("KIT_TO_DRIVE_APP_URL") || "https://kit-to-drive.vercel.app").replace(/\/$/, "");
}

async function enviarCorreo(o: {
  to: string; asunto: string; titulo: string; texto: string; boton?: { label: string; url: string };
  adjunto?: { nombre: string; bytes: Uint8Array };
}) {
  const key = Deno.env.get("RESEND_API_KEY");
  const from = Deno.env.get("RESEND_FROM_EMAIL");
  if (!key || !from) return;
  const html = `<div style="font-family:system-ui,sans-serif;max-width:480px;margin:0 auto;padding:32px 24px">
<h2 style="font-size:20px;font-weight:800;color:#1a1a2e;margin-bottom:8px">${esc(o.titulo)}</h2>
<p style="color:#6b7280;font-size:14px;line-height:1.6;white-space:pre-line">${esc(o.texto)}</p>
${o.boton ? `<a href="${esc(o.boton.url)}" style="display:inline-block;background:#032B61;color:#fff;font-weight:700;font-size:14px;padding:12px 24px;border-radius:10px;text-decoration:none">${esc(o.boton.label)}</a>` : ""}
</div>`;
  try {
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from, to: [o.to], subject: o.asunto, html,
        ...(o.adjunto ? { attachments: [{ filename: o.adjunto.nombre, content: bytesToB64(o.adjunto.bytes) }] } : {}),
      }),
      signal: AbortSignal.timeout(10_000),
    });
    if (!r.ok) console.error("firmas: Resend rechazó el correo, status", r.status);
  } catch {
    console.error("firmas: no se pudo enviar el correo");
  }
}

// ---------- Contexto ----------
async function descargar(svc: Svc, bucket: string, path: string): Promise<Uint8Array> {
  const { data, error } = await svc.storage.from(bucket).download(path);
  if (error || !data) throw new Error(`No se pudo leer ${bucket}/${path}`);
  return new Uint8Array(await data.arrayBuffer());
}

const vencida = (s: Solicitud) => new Date(s.vence_at).getTime() < Date.now();

function puedeFirmarAhora(s: Solicitud, f: Firmante, todos: Firmante[]): boolean {
  if (s.estatus !== "pendiente" || vencida(s) || f.estatus !== "pendiente") return false;
  if (!s.secuencial) return true;
  return !todos.some((o) => o.estatus === "pendiente" && o.orden < f.orden);
}

async function notificarTurno(svc: Svc, s: Solicitud, todos: Firmante[], creador: { id: string; nombre: string }, forzar = false) {
  const destinos = todos.filter((f) => puedeFirmarAhora(s, f, todos) && (forzar || !f.notificado_at));
  for (const f of destinos) {
    await svc.from("notificaciones").insert({
      usuario_destino: f.usuario_id,
      tipo: "firma",
      titulo: "Documento por firmar",
      cuerpo: s.titulo,
      enlace: `/firmas/${s.id}`,
      creado_por: creador.id,
      nombre_creador: creador.nombre,
    });
    await svc.from("firmas_firmantes").update({ notificado_at: new Date().toISOString() }).eq("id", f.id);
    if (f.email) {
      await enviarCorreo({
        to: f.email,
        asunto: `Documento pendiente de firma: ${s.titulo}`,
        titulo: "Tienes un documento por firmar",
        texto: `Hola ${f.nombre},\n\n${creador.nombre} te envió "${s.titulo}" para firma electrónica.${s.mensaje ? `\n\n"${s.mensaje}"` : ""}\n\nVence el ${fmtMx(s.vence_at)}.`,
        boton: { label: "Revisar y firmar", url: `${appUrl()}/firmas/${s.id}` },
      });
    }
  }
}

// ---------- PDF: hoja de firmas ----------
// Helvetica estándar solo soporta WinAnsi.
const winAnsi = (s: string) => s.replace(/[^ -~ -ÿ]/g, "?");

function ajustar(texto: string, font: PDFFont, size: number, maxW: number): string[] {
  const lineas: string[] = [];
  let cur = "";
  for (const w of winAnsi(texto).split(/\s+/)) {
    const t = cur ? `${cur} ${w}` : w;
    if (font.widthOfTextAtSize(t, size) > maxW && cur) {
      lineas.push(cur);
      cur = w;
    } else cur = t;
  }
  if (cur) lineas.push(cur);
  return lineas;
}

async function armarPdfFirmado(
  original: Uint8Array,
  meta: { titulo: string; sha: string; folio: string },
  firmas: Array<{ nombre: string; email: string | null; firmado_at: string; ip: string | null; png: Uint8Array }>,
): Promise<Uint8Array> {
  const pdf = await PDFDocument.load(original, { ignoreEncryption: true });
  const font = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const W = 595, H = 842, M = 48;
  let page = pdf.addPage([W, H]);
  const encabezado = (p: typeof page) =>
    p.drawText("Hoja de firmas electrónicas", { x: M, y: H - M, size: 18, font: bold, color: rgb(0.01, 0.17, 0.38) });
  encabezado(page);
  let y = H - M - 28;
  for (const l of ajustar(`Documento: ${meta.titulo}`, font, 11, W - 2 * M)) {
    page.drawText(l, { x: M, y, size: 11, font });
    y -= 15;
  }
  const gris = rgb(0.4, 0.4, 0.4);
  page.drawText(winAnsi(`Folio de la solicitud: ${meta.folio}`), { x: M, y, size: 9, font, color: gris });
  y -= 13;
  page.drawText("SHA-256 del documento original (calculado por Kit-to-Drive):", { x: M, y, size: 9, font, color: gris });
  y -= 12;
  page.drawText(meta.sha, { x: M, y, size: 8, font, color: gris });
  y -= 14;
  page.drawLine({ start: { x: M, y }, end: { x: W - M, y }, thickness: 0.5, color: rgb(0.8, 0.8, 0.8) });
  y -= 20;

  const BLOQUE = 120;
  for (const f of firmas) {
    if (y - BLOQUE < M + 40) {
      page = pdf.addPage([W, H]);
      encabezado(page);
      y = H - M - 40;
    }
    const img = await pdf.embedPng(f.png);
    const boxW = 200, boxH = 80;
    const escala = Math.min(boxW / img.width, boxH / img.height);
    page.drawRectangle({ x: M, y: y - boxH, width: boxW, height: boxH, borderColor: rgb(0.85, 0.85, 0.85), borderWidth: 0.5 });
    page.drawImage(img, {
      x: M + (boxW - img.width * escala) / 2, y: y - boxH + (boxH - img.height * escala) / 2,
      width: img.width * escala, height: img.height * escala,
    });
    const tx = M + boxW + 20;
    const g2 = rgb(0.3, 0.3, 0.3);
    page.drawText(winAnsi(f.nombre), { x: tx, y: y - 14, size: 12, font: bold });
    if (f.email) page.drawText(winAnsi(f.email), { x: tx, y: y - 30, size: 10, font });
    page.drawText(winAnsi(`Firmado: ${fmtMx(f.firmado_at)}`), { x: tx, y: y - 46, size: 9, font, color: g2 });
    page.drawText(winAnsi(`IP: ${f.ip ?? "n/d"}`), { x: tx, y: y - 60, size: 9, font, color: g2 });
    y -= BLOQUE;
  }

  const pie = ajustar(
    "Firma electrónica simple conforme al Código de Comercio. Esta hoja documenta la identidad declarada (usuario autenticado de Kit-to-Drive), fecha, hora, dirección IP y huella SHA-256 del documento original. No constituye firma electrónica avanzada ni constancia NOM-151.",
    font, 8, W - 2 * M,
  );
  let fy = M + pie.length * 10;
  for (const l of pie) {
    page.drawText(l, { x: M, y: fy, size: 8, font, color: rgb(0.5, 0.5, 0.5) });
    fy -= 10;
  }
  return await pdf.save();
}

// ---------- Cierre ----------
async function cerrarSiCompleta(svc: Svc, s: Solicitud, creador: { id: string; nombre: string; email: string | null }) {
  const { data } = await svc.from("firmas_firmantes").select("*").eq("solicitud_id", s.id).order("orden");
  const todos = (data ?? []) as Firmante[];
  if (!todos.length || !todos.every((f) => f.estatus === "firmado")) return;

  const original = await descargar(svc, BUCKET, s.ruta_original);
  const firmas = [];
  for (const f of todos) {
    firmas.push({
      nombre: f.nombre, email: f.email, firmado_at: f.firmado_at!, ip: f.firmado_ip,
      png: await descargar(svc, BUCKET, f.ruta_firma!),
    });
  }
  const salida = await armarPdfFirmado(original, { titulo: s.titulo, sha: s.sha256_original, folio: s.id }, firmas);
  const ruta = `${s.id}/firmado.pdf`;
  const up = await svc.storage.from(BUCKET).upload(ruta, salida, { contentType: "application/pdf", upsert: true });
  if (up.error) throw new Error(up.error.message);

  // Solo una ejecución concurrente "gana" el cierre y avisa.
  const { data: gano } = await svc.from("firmas_solicitudes")
    .update({ estatus: "completada", ruta_firmado: ruta, sha256_firmado: await sha256Hex(salida), completado_at: new Date().toISOString() })
    .eq("id", s.id).eq("estatus", "pendiente").select("id");
  if (!gano?.length) return;

  const adjunto = salida.length <= MAX_ADJUNTO_CORREO
    ? { nombre: `${s.nombre_archivo.replace(/\.pdf$/i, "")}-firmado.pdf`, bytes: salida }
    : undefined;
  const destinos = new Map<string, { id: string; email: string | null }>();
  for (const f of todos) destinos.set(f.usuario_id, { id: f.usuario_id, email: f.email });
  if (!destinos.has(creador.id)) destinos.set(creador.id, { id: creador.id, email: creador.email });
  for (const d of destinos.values()) {
    await svc.from("notificaciones").insert({
      usuario_destino: d.id, tipo: "firma", titulo: "Documento firmado por todos", cuerpo: s.titulo,
      enlace: `/firmas/${s.id}`, creado_por: creador.id, nombre_creador: creador.nombre,
    });
    if (d.email) {
      await enviarCorreo({
        to: d.email, asunto: `Documento firmado: ${s.titulo}`, titulo: "Documento firmado por todas las partes",
        texto: `"${s.titulo}" ya fue firmado por todos los participantes.${adjunto ? " Adjuntamos la copia firmada." : ""}`,
        boton: { label: "Ver documento firmado", url: `${appUrl()}/firmas/${s.id}` }, adjunto,
      });
    }
  }
}

// ---------- Servidor ----------
serve(async (req) => {
  const CORS = corsHeaders(req);
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) throw new HttpError(401, "Sesión requerida");
    const userClient = createClient(url, anon, { global: { headers: { Authorization: authHeader } } });
    const { data: ud, error: ue } = await userClient.auth.getUser();
    if (ue || !ud.user) throw new HttpError(401, "Sesión inválida");
    const svc = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const yo = ud.user;

    const { data: perfil } = await svc.from("profiles").select("nombre_completo, email, activo").eq("id", yo.id).maybeSingle();
    if (!perfil || perfil.activo === false) throw new HttpError(403, "Usuario inactivo");
    const miNombre = (perfil.nombre_completo as string) || yo.email || "Un compañero";

    const body = await req.json();
    const accion = String(body.accion ?? "");

    const cargar = async (id: unknown) => {
      if (typeof id !== "string" || !UUID.test(id)) throw new HttpError(400, "Solicitud inválida");
      const { data: s } = await svc.from("firmas_solicitudes").select("*").eq("id", id).maybeSingle();
      if (!s) throw new HttpError(404, "Solicitud no encontrada");
      const { data: fs } = await svc.from("firmas_firmantes").select("*").eq("solicitud_id", id).order("orden");
      return { s: s as Solicitud, todos: (fs ?? []) as Firmante[] };
    };

    // ===== Crear (desde el PDF de una remisión) =====
    if (accion === "crear") {
      const remisionId = String(body.remision_id ?? "");
      if (!UUID.test(remisionId)) throw new HttpError(400, "Remisión inválida");
      // RLS con el JWT de la persona: si no puede leer la remisión, no puede mandarla a firma.
      const { data: rem } = await userClient.from("remisiones").select("id, folio_remision, documento_url").eq("id", remisionId).maybeSingle();
      if (!rem) throw new HttpError(404, "Remisión no encontrada o sin acceso");
      if (!rem.documento_url) throw new HttpError(400, "La remisión no tiene PDF. Sube el PDF primero.");

      const { data: abierta } = await svc.from("firmas_solicitudes").select("id")
        .eq("entidad_tipo", "remision").eq("entidad_id", remisionId).eq("estatus", "pendiente")
        .gt("vence_at", new Date().toISOString()).limit(1);
      if (abierta?.length) throw new HttpError(409, "Esta remisión ya tiene una solicitud de firma pendiente");

      const ids: string[] = Array.isArray(body.firmantes) ? body.firmantes.map(String) : [];
      if (!ids.length || ids.length > MAX_FIRMANTES) throw new HttpError(400, `Entre 1 y ${MAX_FIRMANTES} firmantes`);
      if (new Set(ids).size !== ids.length || ids.some((i) => !UUID.test(i))) throw new HttpError(400, "Firmantes inválidos o repetidos");
      const { data: perfiles } = await svc.from("profiles").select("id, nombre_completo, email, activo").in("id", ids);
      const porId = new Map((perfiles ?? []).map((p) => [p.id as string, p]));
      if (ids.some((i) => !porId.get(i) || porId.get(i)!.activo === false)) {
        throw new HttpError(400, "Solo se puede pedir firma a usuarios activos del equipo");
      }

      const pdf = await descargar(svc, BUCKET_REMISIONES, String(rem.documento_url)).catch(() => {
        throw new HttpError(400, "No se pudo leer el PDF de la remisión");
      });
      if (pdf.length > MAX_PDF_BYTES) throw new HttpError(400, "El PDF excede 15 MB");
      if (!esPdf(pdf)) throw new HttpError(400, "Solo se pueden firmar archivos PDF");
      try {
        await PDFDocument.load(pdf, { ignoreEncryption: true });
      } catch {
        throw new HttpError(400, "El PDF está dañado o protegido");
      }

      const id = crypto.randomUUID();
      const rutaOriginal = `${id}/original.pdf`;
      const up = await svc.storage.from(BUCKET).upload(rutaOriginal, pdf, { contentType: "application/pdf" });
      if (up.error) throw new Error(up.error.message);

      const dias = Math.min(Math.max(Number(body.dias) || 30, 1), 90);
      const titulo = String(body.titulo ?? "").trim().slice(0, 200) || `Remisión ${rem.folio_remision}`;
      const { data: fila, error: eS } = await svc.from("firmas_solicitudes").insert({
        id, creado_por: yo.id, titulo, mensaje: body.mensaje ? String(body.mensaje).slice(0, 2000) : null,
        entidad_tipo: "remision", entidad_id: remisionId,
        nombre_archivo: `Remision-${String(rem.folio_remision).replace(/[^A-Za-z0-9_-]+/g, "_")}.pdf`,
        secuencial: !!body.secuencial, ruta_original: rutaOriginal, sha256_original: await sha256Hex(pdf),
        vence_at: new Date(Date.now() + dias * 86400000).toISOString(),
      }).select("*").single();
      if (eS) {
        await svc.storage.from(BUCKET).remove([rutaOriginal]);
        throw new Error(eS.message);
      }
      const { data: fRows, error: eF } = await svc.from("firmas_firmantes").insert(
        ids.map((uid, i) => ({
          solicitud_id: id, orden: body.secuencial ? i : 0, usuario_id: uid,
          nombre: (porId.get(uid)!.nombre_completo as string) || (porId.get(uid)!.email as string) || "Usuario",
          email: (porId.get(uid)!.email as string) ?? null,
        })),
      ).select("*");
      if (eF) {
        await svc.from("firmas_solicitudes").delete().eq("id", id);
        await svc.storage.from(BUCKET).remove([rutaOriginal]);
        throw new Error(eF.message);
      }
      await notificarTurno(svc, fila as Solicitud, fRows as Firmante[], { id: yo.id, nombre: miNombre });
      return json({ ok: true, solicitud_id: id });
    }

    // ===== Cancelar / recordar (solo quien creó) =====
    if (accion === "cancelar" || accion === "recordar") {
      const { s, todos } = await cargar(body.solicitud_id);
      if (s.creado_por !== yo.id) throw new HttpError(403, "Solo quien creó la solicitud puede hacerlo");
      if (s.estatus !== "pendiente") throw new HttpError(400, "La solicitud ya no está pendiente");
      if (accion === "cancelar") {
        await svc.from("firmas_solicitudes").update({ estatus: "cancelada" }).eq("id", s.id).eq("estatus", "pendiente");
      } else {
        await notificarTurno(svc, s, todos, { id: yo.id, nombre: miNombre }, true);
      }
      return json({ ok: true });
    }

    // ===== Firmar =====
    if (accion === "firmar") {
      const { s, todos } = await cargar(body.solicitud_id);
      const f = todos.find((x) => x.usuario_id === yo.id);
      if (!f) throw new HttpError(403, "No eres firmante de este documento");
      if (!body.consentimiento) throw new HttpError(400, "Debes aceptar el consentimiento para firmar");
      if (!puedeFirmarAhora(s, f, todos)) {
        throw new HttpError(409, s.estatus !== "pendiente" || vencida(s)
          ? "Esta solicitud ya no está vigente"
          : f.estatus !== "pendiente" ? "Ya firmaste este documento" : "Aún no es tu turno de firmar");
      }
      if (!body.firma_png) throw new HttpError(400, "Falta la firma");
      const png = b64ToBytes(String(body.firma_png));
      if (png.length > MAX_FIRMA_BYTES) throw new HttpError(400, "La imagen de firma es demasiado grande");
      if (!esPng(png)) throw new HttpError(400, "La firma debe ser una imagen PNG");

      const rutaFirma = `${s.id}/sig-${f.id}.png`;
      const up = await svc.storage.from(BUCKET).upload(rutaFirma, png, { contentType: "image/png", upsert: true });
      if (up.error) throw new Error(up.error.message);
      const { data: act } = await svc.from("firmas_firmantes").update({
        estatus: "firmado", firmado_at: new Date().toISOString(), firmado_ip: ipCliente(req),
        firmado_user_agent: (req.headers.get("user-agent") || "").slice(0, 300), ruta_firma: rutaFirma,
      }).eq("id", f.id).eq("estatus", "pendiente").select("id");
      if (!act?.length) throw new HttpError(409, "Ya firmaste este documento");

      const { data: cr } = await svc.from("profiles").select("nombre_completo, email").eq("id", s.creado_por).maybeSingle();
      const creador = { id: s.creado_por, nombre: (cr?.nombre_completo as string) || "Kit-to-Drive", email: (cr?.email as string) ?? null };
      await cerrarSiCompleta(svc, s, creador);
      const { s: fresca, todos: frescos } = await cargar(s.id);
      if (fresca.estatus === "pendiente") await notificarTurno(svc, fresca, frescos, { id: creador.id, nombre: creador.nombre });
      return json({ ok: true, completada: fresca.estatus === "completada" });
    }

    // ===== Rechazar =====
    if (accion === "rechazar") {
      const { s, todos } = await cargar(body.solicitud_id);
      const f = todos.find((x) => x.usuario_id === yo.id);
      if (!f) throw new HttpError(403, "No eres firmante de este documento");
      if (!puedeFirmarAhora(s, f, todos)) throw new HttpError(409, "Esta solicitud ya no está vigente");
      const motivo = String(body.motivo ?? "").trim().slice(0, 500) || null;
      const { data: rech } = await svc.from("firmas_firmantes")
        .update({ estatus: "rechazado", motivo_rechazo: motivo, firmado_at: new Date().toISOString() })
        .eq("id", f.id).eq("estatus", "pendiente").select("id");
      if (!rech?.length) throw new HttpError(409, "Esta solicitud ya no está vigente");
      await svc.from("firmas_solicitudes").update({ estatus: "rechazada" }).eq("id", s.id).eq("estatus", "pendiente");
      await svc.from("notificaciones").insert({
        usuario_destino: s.creado_por, tipo: "firma", titulo: `${f.nombre} rechazó firmar`,
        cuerpo: motivo ? `${s.titulo} — ${motivo}` : s.titulo, enlace: `/firmas/${s.id}`,
        creado_por: yo.id, nombre_creador: miNombre,
      });
      const { data: cr } = await svc.from("profiles").select("email").eq("id", s.creado_por).maybeSingle();
      if (cr?.email) {
        await enviarCorreo({
          to: cr.email as string, asunto: `Firma rechazada: ${s.titulo}`, titulo: "Un firmante rechazó el documento",
          texto: `${f.nombre} rechazó firmar "${s.titulo}".${motivo ? `\n\nMotivo: ${motivo}` : ""}`,
        });
      }
      return json({ ok: true });
    }

    throw new HttpError(400, "Acción inválida");
  } catch (e) {
    if (e instanceof HttpError) return json({ error: e.message, code: e.code }, e.status);
    // El detalle queda en los logs; al navegador, un mensaje genérico.
    console.error("firmas error:", e instanceof Error ? e.message : "Error desconocido");
    return json({ error: "Error interno. Intenta de nuevo." }, 500);
  }
});

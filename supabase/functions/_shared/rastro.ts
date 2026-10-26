/**
 * Punto de enlace con la auditoría (Fase 4): quién hizo qué sobre un usuario.
 *
 * Escribe un renglón en public.bridge_bitacora (accion, objetivo, detalle) con el actor real
 * (id y correo de quien llamó, no la llave de servicio) y un identificador de correlación.
 * NUNCA incluye contraseñas ni cuerpos de petición.
 *
 * Si no se puede dejar el rastro, la operación NO se hace (falla cerrado): decisión de Polo para
 * dinero, inventario y accesos.
 */
type Cliente = { from: (t: string) => { insert: (r: Record<string, unknown>) => PromiseLike<{ error: { message: string } | null }> } };

export type Evento = {
  accion: string;
  objetivo: string;
  actor: { id: string; email?: string | null };
  correlacion: string;
  detalle?: Record<string, unknown>;
};

/** Toma el identificador de correlación de la petición o crea uno. */
export function correlacionDe(req: Request): string {
  const h = (req.headers.get("x-request-id") ?? "").trim();
  return /^[A-Za-z0-9._-]{8,80}$/.test(h) ? h : crypto.randomUUID();
}

export async function dejarRastro(admin: Cliente, e: Evento): Promise<boolean> {
  try {
    const { error } = await admin.from("bridge_bitacora").insert({
      accion: e.accion,
      objetivo: e.objetivo,
      detalle: { ...(e.detalle ?? {}), actor_id: e.actor.id, actor: e.actor.email ?? null, correlacion: e.correlacion, origen: "edge-function" },
    });
    return !error;
  } catch {
    return false;
  }
}

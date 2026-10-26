/**
 * Carga, con la llave de servicio, quién es la persona que llama y quién es el destino,
 * para aplicar las reglas de permisos.ts. Solo lectura. No devuelve datos personales
 * más allá de lo que la regla necesita.
 */
import type { Actor, Area, Destino, Nivel } from "./permisos.ts";
import { areaValida, nivelValido } from "./permisos.ts";

// deno-lint-ignore no-explicit-any
type Cliente = any;

async function rolDe(admin: Cliente, id: string): Promise<{ area: Area | null; nivel: Nivel | null; role: string | null }> {
  const { data } = await admin.from("user_roles").select("area, nivel, role").eq("user_id", id).maybeSingle();
  // Compatibilidad con filas antiguas que solo traen el rol legado.
  const nivel = nivelValido(data?.nivel) ? data.nivel : data?.role === "admin" ? "admin" : null;
  const area = areaValida(data?.area) ? data.area : data?.role === "admin" ? "direccion" : null;
  return { area, nivel, role: data?.role ?? null };
}

async function esSuper(admin: Cliente, id: string): Promise<boolean> {
  const { data } = await admin.from("super_admins").select("user_id").eq("user_id", id).maybeSingle();
  return !!data;
}

export async function cargarActor(admin: Cliente, id: string): Promise<Actor> {
  const [rol, perfil, superAdmin] = await Promise.all([
    rolDe(admin, id),
    admin.from("profiles").select("activo").eq("id", id).maybeSingle(),
    esSuper(admin, id),
  ]);
  const activo = perfil.data?.activo !== false; // sin perfil se trata como activo, igual que usuario_activo() en la base
  const global = activo && rol.area === "direccion" && rol.nivel === "admin";
  return { id, activo, area: rol.area, nivel: rol.nivel, esSuperAdmin: superAdmin && global };
}

export type PerfilActual = {
  nombre_completo: string | null;
  email: string | null;
  codigo_vendedor: string | null;
  activo: boolean;
  es_vendedor: boolean;
  es_administrativo: boolean;
};

export async function cargarDestino(admin: Cliente, id: string): Promise<{ destino: Destino; perfil: PerfilActual | null }> {
  const [rol, perfil, superAdmin] = await Promise.all([
    rolDe(admin, id),
    admin.from("profiles").select("nombre_completo, email, codigo_vendedor, activo, es_vendedor, es_administrativo").eq("id", id).maybeSingle(),
    esSuper(admin, id),
  ]);
  return { destino: { id, area: rol.area, nivel: rol.nivel, esSuperAdmin: superAdmin }, perfil: (perfil.data as PerfilActual | null) ?? null };
}

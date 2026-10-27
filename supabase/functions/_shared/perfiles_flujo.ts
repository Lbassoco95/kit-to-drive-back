/**
 * Perfiles del flujo de dinero (Recepción de cobros, Cajera, Aplicación de cobranza).
 *
 * El perfil define la etapa (recibe, caja, aplica) y es la ÚNICA forma de darla:
 * la base lee `usuario_perfiles_flujo` en `flujo_cap()`. Las altas (admin-create-user,
 * MATI Admin) y las ediciones pasan por aquí para aceptar los mismos tres perfiles
 * y dejar bitácora en `usuario_perfiles_flujo_bitacora` (quién, a quién, antes, después).
 *
 * Si se agrega un perfil: tabla `perfiles_flujo` (migración), esta lista, el front
 * (`src/lib/perfilesFlujo.ts`) y la prueba `perfiles-flujo-alta` del back.
 */

export const PERFILES_FLUJO = ["recepcion_cobros", "cajera", "aplicacion_cobranza"] as const;
export type PerfilFlujo = (typeof PERFILES_FLUJO)[number];

/** Para listas y selectores (MATI Admin, alta): clave, nombre y etapa que da cada perfil. */
export const PERFILES_FLUJO_INFO: { clave: PerfilFlujo; nombre: string; etapa: "recibe" | "caja" | "aplica" }[] = [
  { clave: "recepcion_cobros", nombre: "Recepción de cobros", etapa: "recibe" },
  { clave: "cajera", nombre: "Cajera", etapa: "caja" },
  { clave: "aplicacion_cobranza", nombre: "Aplicación de cobranza", etapa: "aplica" },
];

export class PerfilesInvalidos extends Error {}

/** `undefined` = el cliente no habló de perfiles (no se tocan). Un arreglo (aun vacío) los fija completos. */
export function parsePerfiles(valor: unknown): PerfilFlujo[] | undefined {
  if (valor === undefined) return undefined;
  if (!Array.isArray(valor)) throw new PerfilesInvalidos("perfiles debe ser una lista");
  const limpios = [...new Set(valor.map((p) => (typeof p === "string" ? p.trim() : p)))];
  const malos = limpios.filter((p) => !PERFILES_FLUJO.includes(p as PerfilFlujo));
  if (malos.length) {
    throw new PerfilesInvalidos(`Perfil inválido: ${malos.map(String).join(", ")}. Los perfiles son: ${PERFILES_FLUJO.join(", ")}`);
  }
  return limpios as PerfilFlujo[];
}

/** Solo un administrador (Dirección) o administrador financiero asigna perfiles. */
export const puedeAsignarPerfiles = (role: string | null | undefined) => role === "admin" || role === "admin_financiero";

// deno-lint-ignore no-explicit-any
type Cliente = { rpc: (fn: string, args: Record<string, unknown>) => PromiseLike<{ data: any; error: { message: string } | null }> };

/** Fija el conjunto completo de perfiles de la persona. Lanza si la base lo rechaza. */
export async function fijarPerfiles(
  admin: Cliente,
  opts: { actorId: string | null; actor: string | null; origen: "alta" | "app" | "mati-admin"; userId: string; perfiles: PerfilFlujo[] },
): Promise<string[]> {
  const { data, error } = await admin.rpc("perfiles_flujo_fijar", {
    _actor_id: opts.actorId,
    _actor: opts.actor,
    _origen: opts.origen,
    _user_id: opts.userId,
    _perfiles: opts.perfiles,
  });
  if (error) throw new Error(`No se pudieron guardar los perfiles: ${error.message}`);
  return data as string[];
}

export async function perfilesDe(
  // deno-lint-ignore no-explicit-any
  admin: any,
  userId: string,
): Promise<string[]> {
  const { data, error } = await admin.from("usuario_perfiles_flujo").select("perfil").eq("user_id", userId);
  if (error) throw new Error(error.message);
  return (data ?? []).map((r: { perfil: string }) => r.perfil).sort();
}

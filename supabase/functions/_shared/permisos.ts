/**
 * Quién puede crear, editar o restablecer a quién (Fase 2 de seguridad, docs/seguridad/).
 *
 * Las Edge Functions de usuarios escriben con service_role: ahí `auth.uid()` es NULL y los
 * triggers de la base (impedir_escalada_rol, proteger_perfil_fase2) no actúan. Por eso estas
 * reglas se aplican AQUÍ, en código, ANTES de usar la llave de servicio, y son las mismas que
 * aplica la base cuando la escritura viene de una sesión de usuario:
 *
 *   · Un administrador global (Dirección / admin) puede todo, salvo tocar a un super admin
 *     (solo otro super admin).
 *   · Un admin de área solo toca usuarios de SU área y de nivel menor al suyo: puede activar o
 *     desactivar, cambiar es_vendedor / es_administrativo y los datos del perfil. No asigna
 *     otra área ni el nivel admin, y no toca a otro admin.
 *   · Nadie cambia su propio perfil, salvo el nombre.
 *
 * Funciones puras (sin Deno ni red): se prueban con vitest (tests/fase2-permisos-usuarios.test.ts).
 */

export const AREAS = ["comercial", "fabrica", "almacen_logistica", "administracion", "compras", "direccion"] as const;
export const NIVELES = ["operador", "supervisor", "admin"] as const;
export type Area = (typeof AREAS)[number];
export type Nivel = (typeof NIVELES)[number];

export const rangoNivel = (n: Nivel | null): number => (n === "admin" ? 3 : n === "supervisor" ? 2 : n === "operador" ? 1 : 0);

/** Quien llama. `esSuperAdmin` sale de public.super_admins y exige además ser administrador global. */
export type Actor = { id: string; activo: boolean; area: Area | null; nivel: Nivel | null; esSuperAdmin: boolean };
/** Persona sobre la que se actúa. `esSuperAdmin` = está en public.super_admins (aunque esté inactiva). */
export type Destino = { id: string; area: Area | null; nivel: Nivel | null; esSuperAdmin: boolean };

/** Qué campos cambian de verdad (no lo que viene en la petición). `true` = ese campo cambia; area y nivel traen el valor nuevo. */
export type Cambio = {
  nombre?: boolean;
  email?: boolean;
  codigoVendedor?: boolean;
  activo?: boolean;
  esVendedor?: boolean;
  esAdministrativo?: boolean;
  area?: Area;
  nivel?: Nivel;
};

export type Decision = { ok: true } | { ok: false; status: 400 | 403; error: string };
const ok: Decision = { ok: true };
const no = (error: string, status: 400 | 403 = 403): Decision => ({ ok: false, status, error });

export const esAdminGlobal = (a: Pick<Actor, "activo" | "area" | "nivel">): boolean =>
  a.activo && a.area === "direccion" && a.nivel === "admin";

const esAdmin = (a: Actor): boolean => a.activo && a.nivel === "admin";

export const areaValida = (v: unknown): v is Area => typeof v === "string" && (AREAS as readonly string[]).includes(v);
export const nivelValido = (v: unknown): v is Nivel => typeof v === "string" && (NIVELES as readonly string[]).includes(v);

/** Alta de usuario (admin-create-user). */
export function puedeCrearUsuario(actor: Actor, area: unknown, nivel: unknown): Decision {
  if (!areaValida(area)) return no("Área inválida", 400);
  if (!nivelValido(nivel)) return no("Tipo de usuario inválido", 400);
  if (!esAdmin(actor)) return no("Forbidden: solo un administrador puede crear usuarios");
  if (esAdminGlobal(actor)) return ok;
  if (area !== actor.area) return no("Solo puedes crear usuarios de tu propia área");
  if (rangoNivel(nivel) >= rangoNivel(actor.nivel)) return no("Solo un administrador global puede crear administradores");
  return ok;
}

/** Edición de un usuario (admin-update-user). `cambio` trae solo lo que realmente cambia. */
export function puedeEditarUsuario(actor: Actor, destino: Destino, cambio: Cambio): Decision {
  if (cambio.area !== undefined && !areaValida(cambio.area)) return no("Área inválida", 400);
  if (cambio.nivel !== undefined && !nivelValido(cambio.nivel)) return no("Tipo de usuario inválido", 400);
  if (!esAdmin(actor)) return no("Forbidden: solo un administrador puede actualizar usuarios");

  const toca = Object.values(cambio).some((v) => v !== undefined && v !== false);
  if (!toca) return ok;

  // 1. Nadie cambia su propio perfil, salvo el nombre.
  if (actor.id === destino.id) {
    const soloNombre = !cambio.email && !cambio.codigoVendedor && !cambio.activo && !cambio.esVendedor &&
      !cambio.esAdministrativo && cambio.area === undefined && cambio.nivel === undefined;
    return soloNombre ? ok : no("No puedes cambiar tu propio perfil ni tu propio tipo de usuario, salvo el nombre");
  }

  // 2. Un super admin solo lo toca otro super admin.
  if (destino.esSuperAdmin && !actor.esSuperAdmin) return no("Solo un super admin puede modificar a otro super admin");

  if (esAdminGlobal(actor)) return ok;

  // 3. Admin de área.
  if (destino.area === null || destino.area !== actor.area) return no("Solo puedes actualizar usuarios de tu propia área");
  if (rangoNivel(destino.nivel) >= rangoNivel(actor.nivel)) return no("No puedes modificar a un administrador");
  if (cambio.area !== undefined && cambio.area !== actor.area) return no("Solo puedes asignar usuarios de tu propia área");
  if (cambio.nivel !== undefined && rangoNivel(cambio.nivel) >= rangoNivel(actor.nivel)) {
    return no("Solo un administrador global puede crear o modificar administradores");
  }
  return ok;
}

/** Restablecer contraseña (admin-reset-user-password). Restablecerse a sí mismo sí se permite. */
export function puedeRestablecerPassword(actor: Actor, destino: Destino): Decision {
  if (!esAdmin(actor)) return no("Forbidden: solo un administrador puede restablecer contraseñas");
  if (actor.id === destino.id) return ok;
  if (destino.esSuperAdmin && !actor.esSuperAdmin) return no("Solo un super admin puede restablecer la contraseña de otro super admin");
  if (esAdminGlobal(actor)) return ok;
  if (destino.area === null || destino.area !== actor.area) return no("Solo puedes restablecer contraseñas de usuarios de tu propia área");
  if (rangoNivel(destino.nivel) >= rangoNivel(actor.nivel)) return no("No puedes restablecer la contraseña de otro administrador");
  return ok;
}

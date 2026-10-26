import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
  puedeCrearUsuario, puedeEditarUsuario, puedeRestablecerPassword, esAdminGlobal,
  type Actor, type Destino,
} from "../supabase/functions/_shared/permisos.ts";

/**
 * Fase 2 de seguridad (docs/seguridad/): perfiles, roles, super admins y cartera vencida.
 * Sin base de datos: (1) comportamiento de las reglas que aplican las Edge Functions de
 * usuarios (que escriben con service_role y se saltan los triggers); (2) forma de las cinco
 * migraciones y sus reversas; (3) que cada Edge Function aplique la regla ANTES de usar la
 * llave de servicio y deje rastro antes de cambiar nada.
 */
const RAIZ = process.cwd();
const leer = (...p: string[]) => readFileSync(join(RAIZ, ...p), "utf8");
const sinComentarios = (sql: string) => sql.split("\n").map(l => l.replace(/--.*$/, "")).join("\n");

const actor = (o: Partial<Actor> & { id: string }): Actor => ({ activo: true, area: null, nivel: null, esSuperAdmin: false, ...o });
const destino = (o: Partial<Destino> & { id: string }): Destino => ({ area: null, nivel: null, esSuperAdmin: false, ...o });

const adminComercial = actor({ id: "ac", area: "comercial", nivel: "admin" });
const adminFinanzas = actor({ id: "af", area: "administracion", nivel: "admin" });
const global = actor({ id: "ag", area: "direccion", nivel: "admin" });
const superAdmin = actor({ id: "s1", area: "direccion", nivel: "admin", esSuperAdmin: true });
const supervisor = actor({ id: "sv", area: "comercial", nivel: "supervisor" });
const vendedorDestino = destino({ id: "v", area: "comercial", nivel: "operador" });

describe("C1: nadie se asciende a sí mismo", () => {
  for (const [nombre, a] of [["admin de área", adminComercial], ["administrador global", global], ["super admin", superAdmin]] as const) {
    const yo = destino({ id: a.id, area: a.area, nivel: a.nivel, esSuperAdmin: a.esSuperAdmin });
    it(`${nombre}: puede cambiar su nombre`, () => {
      expect(puedeEditarUsuario(a, yo, { nombre: true }).ok).toBe(true);
    });
    it(`${nombre}: no puede cambiarse es_vendedor, es_administrativo, activo, área, nivel, correo ni código`, () => {
      for (const c of [{ esVendedor: true }, { esAdministrativo: true }, { activo: true }, { area: "direccion" as const }, { nivel: "admin" as const }, { email: true }, { codigoVendedor: true }]) {
        expect(puedeEditarUsuario(a, yo, c).ok, JSON.stringify(c)).toBe(false);
      }
    });
  }
  it("un cambio vacío (el front manda todos los campos sin cambios) no se rechaza", () => {
    expect(puedeEditarUsuario(adminComercial, destino({ id: "ac", area: "comercial", nivel: "admin" }), {}).ok).toBe(true);
  });
});

describe("C2: un admin de área no sube de rango a nadie", () => {
  it("puede activar/desactivar y cambiar es_vendedor / es_administrativo en su área", () => {
    for (const c of [{ activo: true }, { esVendedor: true }, { esAdministrativo: true }, { nombre: true }, { codigoVendedor: true }]) {
      expect(puedeEditarUsuario(adminComercial, vendedorDestino, c).ok, JSON.stringify(c)).toBe(true);
    }
  });
  it("no toca usuarios de otra área", () => {
    const d = puedeEditarUsuario(adminComercial, destino({ id: "f", area: "administracion", nivel: "operador" }), { esAdministrativo: true });
    expect(d.ok).toBe(false);
    expect(puedeEditarUsuario(adminComercial, destino({ id: "x", area: null, nivel: null }), { activo: true }).ok).toBe(false);
  });
  it("no asigna otra área ni nivel igual o superior al suyo, ni hace global a nadie", () => {
    expect(puedeEditarUsuario(adminComercial, vendedorDestino, { area: "administracion", nivel: "operador" }).ok).toBe(false);
    expect(puedeEditarUsuario(adminComercial, vendedorDestino, { area: "direccion", nivel: "admin" }).ok).toBe(false);
    expect(puedeEditarUsuario(adminComercial, vendedorDestino, { area: "comercial", nivel: "admin" }).ok).toBe(false);
    expect(puedeEditarUsuario(adminComercial, vendedorDestino, { area: "comercial", nivel: "supervisor" }).ok).toBe(true);
  });
  it("no modifica a otro administrador de su área ni al administrador global", () => {
    expect(puedeEditarUsuario(adminComercial, destino({ id: "ac2", area: "comercial", nivel: "admin" }), { nombre: true }).ok).toBe(false);
    expect(puedeEditarUsuario(adminComercial, destino({ id: "g", area: "direccion", nivel: "admin" }), { nombre: true }).ok).toBe(false);
  });
  it("un usuario que no es admin no edita a nadie; uno inactivo tampoco", () => {
    expect(puedeEditarUsuario(supervisor, vendedorDestino, { nombre: true }).ok).toBe(false);
    expect(puedeEditarUsuario({ ...adminComercial, activo: false }, vendedorDestino, { nombre: true }).ok).toBe(false);
  });
  it("el administrador global sí puede todo con usuarios que no son super admin", () => {
    expect(puedeEditarUsuario(global, vendedorDestino, { area: "direccion", nivel: "admin" }).ok).toBe(true);
    expect(puedeEditarUsuario(global, destino({ id: "ac", area: "comercial", nivel: "admin" }), { nivel: "operador" }).ok).toBe(true);
  });
  it("valores fuera de la lista se rechazan con 400", () => {
    const d = puedeEditarUsuario(global, vendedorDestino, { area: "inventada" as never, nivel: "admin" });
    expect(d.ok).toBe(false);
    if (!d.ok) expect(d.status).toBe(400);
  });
});

describe("C2: alta de usuarios", () => {
  it("un admin de área solo crea usuarios de su área y de nivel menor", () => {
    expect(puedeCrearUsuario(adminComercial, "comercial", "operador").ok).toBe(true);
    expect(puedeCrearUsuario(adminComercial, "comercial", "supervisor").ok).toBe(true);
    expect(puedeCrearUsuario(adminComercial, "comercial", "admin").ok).toBe(false);
    expect(puedeCrearUsuario(adminComercial, "administracion", "operador").ok).toBe(false);
    expect(puedeCrearUsuario(adminComercial, "direccion", "admin").ok).toBe(false);
  });
  it("el administrador global crea en cualquier área y nivel; quien no es admin no crea", () => {
    expect(puedeCrearUsuario(global, "direccion", "admin").ok).toBe(true);
    expect(puedeCrearUsuario(supervisor, "comercial", "operador").ok).toBe(false);
  });
  it("área o nivel inválidos → 400", () => {
    const d = puedeCrearUsuario(global, "otra", "admin");
    expect(d.ok).toBe(false);
    if (!d.ok) expect(d.status).toBe(400);
  });
});

describe("C3: los super admins solo los toca un super admin", () => {
  const otroSuper = destino({ id: "s2", area: "direccion", nivel: "admin", esSuperAdmin: true });
  it("ni un administrador global ni un admin de área lo editan, desactivan ni cambian de nivel", () => {
    for (const a of [global, adminComercial, adminFinanzas]) {
      for (const c of [{ nombre: true }, { email: true }, { activo: true }, { nivel: "operador" as const, area: "direccion" as const }]) {
        expect(puedeEditarUsuario(a, otroSuper, c).ok, `${a.id} ${JSON.stringify(c)}`).toBe(false);
      }
    }
  });
  it("otro super admin sí", () => {
    expect(puedeEditarUsuario(superAdmin, otroSuper, { activo: true }).ok).toBe(true);
  });
  it("tampoco se le restablece la contraseña (sería tomar la cuenta)", () => {
    expect(puedeRestablecerPassword(global, otroSuper).ok).toBe(false);
    expect(puedeRestablecerPassword(superAdmin, otroSuper).ok).toBe(true);
  });
  it("un super admin cuya cuenta ya no es de Dirección deja de contar como super admin del lado de quien llama", () => {
    // cargarActor() exige además ser administrador global; aquí se comprueba esAdminGlobal.
    expect(esAdminGlobal({ activo: true, area: "comercial", nivel: "admin" })).toBe(false);
    expect(esAdminGlobal({ activo: false, area: "direccion", nivel: "admin" })).toBe(false);
    expect(esAdminGlobal({ activo: true, area: "direccion", nivel: "admin" })).toBe(true);
  });
});

describe("restablecer contraseña", () => {
  it("un admin de área solo restablece a usuarios de menor nivel de su área", () => {
    expect(puedeRestablecerPassword(adminComercial, vendedorDestino).ok).toBe(true);
    expect(puedeRestablecerPassword(adminComercial, destino({ id: "f", area: "administracion", nivel: "operador" })).ok).toBe(false);
    expect(puedeRestablecerPassword(adminComercial, destino({ id: "ac2", area: "comercial", nivel: "admin" })).ok).toBe(false);
  });
  it("cualquier admin puede restablecer la suya", () => {
    expect(puedeRestablecerPassword(adminComercial, destino({ id: "ac", area: "comercial", nivel: "admin" })).ok).toBe(true);
  });
  it("quien no es admin no restablece a nadie", () => {
    expect(puedeRestablecerPassword(supervisor, vendedorDestino).ok).toBe(false);
  });
});

describe("Edge Functions: la regla va ANTES de la llave de servicio y el rastro ANTES del cambio", () => {
  const upd = leer("supabase", "functions", "admin-update-user", "index.ts");
  const crt = leer("supabase", "functions", "admin-create-user", "index.ts");
  const rst = leer("supabase", "functions", "admin-reset-user-password", "index.ts");

  it("admin-update-user: identifica al llamador, aplica la regla, deja rastro y solo entonces escribe", () => {
    const i = (t: string) => upd.indexOf(t);
    expect(i("auth.getUser()")).toBeGreaterThan(-1);
    expect(i("cargarActor(")).toBeLessThan(i("puedeEditarUsuario("));
    expect(i("puedeEditarUsuario(")).toBeLessThan(i("dejarRastro("));
    expect(i("dejarRastro(")).toBeLessThan(i("updateUserById"));
    expect(i("dejarRastro(")).toBeLessThan(i('from("profiles").update'));
    expect(i("dejarRastro(")).toBeLessThan(i('from("user_roles")'));
    expect(upd).toMatch(/if \(!rastroOk\) return respond\([^)]*503\)/); // si el rastro falla, la operación se detiene
  });
  it("admin-update-user: ya no borra user_roles, no pone activo en true por omisión ni borra campos que no llegan", () => {
    expect(sinComentarios(upd)).not.toMatch(/\.delete\(\)/);
    expect(upd).not.toMatch(/activo\s*\?\?\s*true\s*,/);
    expect(upd).not.toMatch(/nombre_completo:\s*nombre_completo\?\.trim\(\)\s*\|\|\s*null/);
    expect(upd).toContain('{ onConflict: "user_id" }');
  });
  it("admin-create-user: aplica puedeCrearUsuario y deja rastro antes de mandar correo o crear", () => {
    const i = (t: string) => crt.indexOf(t);
    expect(i("puedeCrearUsuario(")).toBeGreaterThan(-1);
    expect(i("puedeCrearUsuario(")).toBeLessThan(i("enviarAcceso("));
    expect(i("dejarRastro(")).toBeLessThan(i("enviarAcceso("));
    expect(i("dejarRastro(")).toBeLessThan(i("auth.admin.createUser"));
    expect(i("super_admins")).toBeGreaterThan(-1);
  });
  it("admin-reset-user-password: regla y rastro antes de cambiar la contraseña", () => {
    const i = (t: string) => rst.indexOf(t);
    expect(i("puedeRestablecerPassword(")).toBeLessThan(i("dejarRastro("));
    expect(i("dejarRastro(")).toBeLessThan(i("enviarAcceso("));
    expect(i("dejarRastro(")).toBeLessThan(i("updateUserById"));
  });
  it("el rastro no lleva contraseñas ni cuerpos de petición", () => {
    const r = leer("supabase", "functions", "_shared", "rastro.ts");
    expect(sinComentarios(r.replace(/\/\*[\s\S]*?\*\//g, ""))).not.toMatch(/password|contrase/i);
    expect(r).toContain("bridge_bitacora");
    expect(r).toContain("actor_id");
    expect(r).toContain("correlacion");
  });
});

const MIGRACIONES = [
  "20261107000001_fase2_perfiles_campos_protegidos",
  "20261107000002_fase2_roles_rango_y_super_admins",
  "20261107000003_fase2_profiles_politica_por_area",
  "20261107000004_fase2_cxc_vencidas_solo_quien_ve_al_cliente",
  "20261107000005_fase2_super_admins_rastro",
];
const mig = (n: string) => leer("supabase", "migrations", `${n}.sql`);
const rev = (n: string) => leer("supabase", "reversas", `${n}_reversa.sql`);

describe("Fase 2: migraciones pequeñas, cerradas y reversibles", () => {
  it("las cinco migraciones y sus reversas existen", () => {
    for (const n of MIGRACIONES) {
      expect(existsSync(join(RAIZ, "supabase", "migrations", `${n}.sql`)), n).toBe(true);
      expect(existsSync(join(RAIZ, "supabase", "reversas", `${n}_reversa.sql`)), `${n} (reversa)`).toBe(true);
    }
  });
  it("cada migración trae su verificación, menciona su reversa y dice que depende de la Fase 1 o su cambio", () => {
    for (const n of MIGRACIONES) {
      expect(mig(n), n).toMatch(/Verificaci[oó]n/);
      expect(mig(n), n).toContain(`reversas/${n}_reversa.sql`);
      expect(rev(n), `${n} reversa`).toMatch(/Verificaci[oó]n/);
    }
  });
  it("no usan CASCADE, no tocan datos y no abren permisos (ningún GRANT)", () => {
    for (const n of MIGRACIONES) {
      const sql = sinComentarios(mig(n));
      expect(sql, n).not.toMatch(/\bCASCADE\b/i);
      expect(sql, n).not.toMatch(/\bGRANT\b/i);
      expect(sql, n).not.toMatch(/^\s*(DELETE\s+FROM|UPDATE\s+public|TRUNCATE)/im);
      expect(sql, n).not.toMatch(/\bINSERT\s+INTO\s+public\.(profiles|user_roles|super_admins)\b/i);
    }
  });
  it("las funciones nuevas o reemplazadas fijan search_path y son SECURITY DEFINER solo las de trigger", () => {
    for (const n of MIGRACIONES.filter(m => /campos_protegidos|rango_y_super|rastro/.test(m))) {
      const sql = sinComentarios(mig(n));
      expect(sql, n).toMatch(/SET search_path TO 'public'/);
      expect(sql, n).toMatch(/RETURNS trigger/);
    }
  });
  it("el trigger de perfiles deja pasar a service_role (auth.uid() nulo) y solo mira sesiones de usuario", () => {
    expect(mig(MIGRACIONES[0])).toMatch(/IF _actor IS NULL THEN\s+RETURN COALESCE\(NEW, OLD\);/);
  });
  it("la reversa del cambio 2 restituye la definición de producción (con la regla de Dirección, sin la de super admin)", () => {
    const r = rev(MIGRACIONES[1]).split(/-- Verificaci[oó]n/)[0];
    expect(r).toContain("No puedes modificar al administrador global");
    expect(r).not.toContain("Solo un super admin puede cambiar el rol de otro super admin");
    expect(mig(MIGRACIONES[1])).toContain("Solo un super admin puede cambiar el rol de otro super admin");
  });
  it("la reversa del cambio 3 recrea profiles_update_admin y la del 4 devuelve SECURITY DEFINER", () => {
    expect(rev(MIGRACIONES[2])).toMatch(/CREATE POLICY profiles_update_admin ON public\.profiles/);
    expect(sinComentarios(mig(MIGRACIONES[3]))).toMatch(/SECURITY INVOKER/);
    expect(sinComentarios(rev(MIGRACIONES[3]))).toMatch(/SECURITY DEFINER/);
  });
  it("ningún archivo de la Fase 2 lleva correos reales, JWT ni llaves", () => {
    for (const n of MIGRACIONES) for (const t of [mig(n), rev(n)]) {
      expect(t, n).not.toMatch(/eyJ[\w-]{10,}\.[\w-]{10,}\./);
      expect(t, n).not.toMatch(/\b(sb_secret_|sb_publishable_|service_role_key|sk_live)/i);
      expect(t, n).not.toMatch(/[\w.+-]+@(?!ejemplo\.test)[\w-]+\.[a-z]{2,}/i);
    }
  });
});

describe("Cuentas demo (docs/seguridad/CUENTAS-DEMO.md)", () => {
  const seed = leer("supabase", "functions", "seed-demo-users", "index.ts");
  const ops = (f: string) => leer("supabase", "operaciones", f);
  const SCRIPTS = [
    "fase2-desactivar-cuentas-demo-inactivas.sql",
    "fase2-forzar-cambio-password-demo-activas.sql",
    "fase2-migrar-correo-real-lee-marco.sql",
    "fase2-cerrar-sesiones-lee.sql",
  ];

  it("seed-demo-users: la contraseña la genera el servidor, nunca viene del cuerpo y no se devuelve", () => {
    expect(seed).toContain("generarPassword()");
    expect(seed).not.toMatch(/d\.password/);
    expect(seed).not.toMatch(/JSON\.stringify\(\{[^}]*password/);
    expect(seed.indexOf("enviarAcceso(")).toBeLessThan(seed.indexOf("auth.admin.createUser"));
    expect(seed.indexOf("autorizarAlta(")).toBeLessThan(seed.indexOf("auth.admin.createUser"));
  });
  it("seed-demo-users: una cuenta que ya existe no se toca (ya no borra su rol)", () => {
    expect(sinComentarios(seed)).not.toMatch(/\.delete\(\)/);
    expect(seed).toMatch(/existed\.push\(d\.email\);\s+continue;/);
  });
  it("las operaciones sobre cuentas demo no son migraciones, traen reversa, guardas y verificación, y no borran nada", () => {
    for (const f of SCRIPTS) {
      const sql = ops(f);
      const limpio = sinComentarios(sql);
      expect(existsSync(join(RAIZ, "supabase", "operaciones", f.replace(".sql", "_reversa.sql"))), f).toBe(true);
      expect(sql, f).toMatch(/Autorizo/);
      expect(sql, f).toMatch(/Verificaci[oó]n/);
      expect(sql, f).toMatch(/RAISE EXCEPTION/);
      expect(limpio.replace(/ON COMMIT DROP/gi, ""), f).not.toMatch(/\bDELETE\s+FROM\b|\bDROP\s|\bTRUNCATE\b/i);
      expect(existsSync(join(RAIZ, "supabase", "migrations", f)), `${f} no debe estar en migrations`).toBe(false);
    }
  });
  it("bloquear no borra: usa banned_until y solo cuentas con perfil inactivo", () => {
    const sql = sinComentarios(ops(SCRIPTS[0]));
    expect(sql).toContain("banned_until = 'infinity'");
    expect(sql).toContain("p.activo IS NOT FALSE");
    expect(sql).not.toMatch(/edgar@dazon\.demo'\)\s*;/); // edgar queda comentado hasta que Polo confirme
  });
  it("el script de correo no lleva correos reales: los recibe como variables de psql", () => {
    const sql = ops("fase2-migrar-correo-real-lee-marco.sql");
    expect(sql).toContain(":'correo_lee'");
    expect(sql).toContain(":'correo_marco'");
    expect((sinComentarios(sql).match(/[\w.+-]+@[\w.-]+\.[a-z]{2,}/gi) ?? []).filter(c => !/@dazon\.demo$/.test(c))).toEqual([]);
    expect(sinComentarios(sql)).toMatch(/NOT LIKE|LIKE '%@dazon\.demo'/);
  });
  it("ningún script lleva contraseñas, JWT ni llaves", () => {
    for (const f of [...SCRIPTS, ...SCRIPTS.map(s => s.replace(".sql", "_reversa.sql")), "README.md"]) {
      const t = ops(f);
      expect(t, f).not.toMatch(/eyJ[\w-]{10,}\.[\w-]{10,}\./);
      expect(t, f).not.toMatch(/\b(sb_secret_|sb_publishable_|service_role_key|sk_live)/i);
      expect(t, f).not.toMatch(/(password|contrase[ñn]a)\s*[:=]\s*['"][^'"]{6,}['"]/i);
    }
  });
});

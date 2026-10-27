// Perfiles del flujo de dinero: el alta, MATI Admin y la base aceptan los mismos tres perfiles
// (ya hubo un alta que no aceptaba un área nueva: esta prueba evita que se repita).
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, it, expect } from "vitest";
import { PERFILES_FLUJO, PERFILES_FLUJO_INFO, parsePerfiles, puedeAsignarPerfiles } from "../supabase/functions/_shared/perfiles_flujo";

const RAIZ = join(__dirname, "..");
const leer = (...p: string[]) => readFileSync(join(RAIZ, ...p), "utf8");
const migracion = leer("supabase/migrations/20261027000001_flujo_perfiles_por_etapa.sql");
const alta = leer("supabase/functions/admin-create-user/index.ts");
const edicion = leer("supabase/functions/admin-update-user/index.ts");
const puente = leer("supabase/functions/mati-admin-bridge/index.ts");

describe("perfiles del flujo: una sola lista en base, alta, edición y MATI Admin", () => {
  it("la lista de las funciones es la del catálogo de la migración, con su etapa", () => {
    const filas = [...migracion.matchAll(/^\s+\('([a-z_]+)',\s*'([^']+)',\s*'(recibe|caja|aplica)',/gm)].map((m) => [m[1], m[3]]);
    expect(filas).toEqual([["recepcion_cobros", "recibe"], ["cajera", "caja"], ["aplicacion_cobranza", "aplica"]]);
    expect(PERFILES_FLUJO_INFO.map((p) => [p.clave, p.etapa])).toEqual(filas);
    expect([...PERFILES_FLUJO]).toEqual(filas.map((f) => f[0]));
  });

  it("parsePerfiles acepta los tres, quita duplicados y rechaza lo demás", () => {
    expect(parsePerfiles(undefined)).toBeUndefined();
    expect(parsePerfiles([])).toEqual([]);
    expect(parsePerfiles(["cajera", "cajera", " recepcion_cobros "])).toEqual(["cajera", "recepcion_cobros"]);
    expect(() => parsePerfiles(["tesorero"])).toThrow(/Perfil inválido/);
    expect(() => parsePerfiles("cajera")).toThrow(/lista/);
    expect(() => parsePerfiles([1])).toThrow(/Perfil inválido/);
  });

  it("solo administrador o administrador financiero asigna", () => {
    expect(puedeAsignarPerfiles("admin")).toBe(true);
    expect(puedeAsignarPerfiles("admin_financiero")).toBe(true);
    for (const r of ["finanzas", "director_ventas", "coordinador_ventas", "compras", "ventas", null, undefined]) {
      expect(puedeAsignarPerfiles(r as string | null | undefined)).toBe(false);
    }
  });

  it("el alta valida los perfiles y el permiso ANTES de mandar el correo y crear la cuenta", () => {
    const iParse = alta.indexOf("parsePerfiles(body.perfiles)");
    const iPermiso = alta.indexOf("puedeAsignarPerfiles(roleRow?.role)");
    expect(iParse).toBeGreaterThan(0);
    expect(iPermiso).toBeGreaterThan(iParse);
    expect(iPermiso).toBeLessThan(alta.indexOf("enviarAcceso("));
    expect(alta).toContain('origen: "alta"');
    expect(alta).toContain("perfiles: perfilesGuardados");
  });

  it("la edición cambia o retira perfiles (lista vacía = retirar) solo con permiso", () => {
    expect(edicion).toContain("parsePerfiles(body.perfiles)");
    expect(edicion).toContain("perfiles !== undefined && !puedeAsignarPerfiles(callerRole?.role)");
    expect(edicion).toContain('origen: "app"');
  });

  it("MATI Admin: meta, alta, edición y listado traen los perfiles", () => {
    expect(puente).toContain("perfiles: PERFILES_FLUJO_INFO");
    expect(puente).toContain("const perfiles = parsePerfilesBody(body.perfiles)");
    expect(puente.indexOf("parsePerfilesBody(body.perfiles)")).toBeLessThan(puente.indexOf("enviarAcceso("));
    expect(puente).toContain('origen: "mati-admin"');
    expect(puente).toContain('from("usuario_perfiles_flujo")');
  });

  it("las funciones de servidor llaman al núcleo de la base, no escriben la tabla de perfiles", () => {
    for (const src of [alta, edicion, puente]) expect(src).not.toMatch(/from\("usuario_perfiles_flujo"\)\s*\.(insert|upsert|update|delete)/);
    expect(leer("supabase/functions/_shared/perfiles_flujo.ts")).toContain('rpc("perfiles_flujo_fijar"');
  });
});

describe("perfiles del flujo (migración)", () => {
  it("una sola fuente de verdad: se retira la marca por persona y sus funciones", () => {
    expect(migracion).toContain("DROP TABLE public.flujo_capacidades");
    expect(migracion).toContain("DROP FUNCTION IF EXISTS public.flujo_asignar_capacidad(uuid, text, boolean)");
    expect(migracion).toContain("DROP FUNCTION IF EXISTS public.flujo_listar_capacidades()");
    expect(migracion).toMatch(/FROM public\.usuario_perfiles_flujo up\s+JOIN public\.perfiles_flujo pf ON pf\.clave = up\.perfil/);
    expect(migracion).not.toMatch(/FROM public\.flujo_capacidades c WHERE c\.user_id = _uid/);
  });

  it("las tablas no se escriben directo, la bitácora es inmutable y el núcleo solo lo abre service_role", () => {
    expect(migracion).toContain("ALTER TABLE public.usuario_perfiles_flujo ENABLE ROW LEVEL SECURITY");
    expect(migracion).toContain("REVOKE ALL ON public.usuario_perfiles_flujo FROM PUBLIC, anon, authenticated");
    expect(migracion).not.toMatch(/GRANT (INSERT|UPDATE|DELETE)[^;]*usuario_perfiles_flujo/);
    expect(migracion).toContain("BEFORE UPDATE OR DELETE ON public.usuario_perfiles_flujo_bitacora");
    expect(migracion).toContain("REVOKE ALL ON FUNCTION public.perfiles_flujo_fijar(uuid, text, text, uuid, text[]) FROM PUBLIC, anon, authenticated");
    expect(migracion).toContain("GRANT EXECUTE ON FUNCTION public.perfiles_flujo_fijar(uuid, text, text, uuid, text[]) TO service_role");
  });

  it("asignar desde la app exige administrador (flujo_es_admin) y deja bitácora con antes y después", () => {
    expect(migracion).toMatch(/flujo_asignar_perfil[\s\S]*IF NOT public\.flujo_es_admin\(\)/);
    expect(migracion).toContain("perfiles_antes, perfiles_despues");
  });

  it("cada quien ve solo su cola y prueba/real no se mezclan", () => {
    expect(migracion).toContain("es_prueba = public.es_usuario_prueba(auth.uid())");
    expect(migracion).toContain("public.flujo_cap('caja')   AND (etapa = 'RECIBIDO' OR caja_por = auth.uid())");
    expect(migracion).toContain("public.flujo_cap('aplica') AND (etapa = 'EN_CAJA'  OR aplicado_por = auth.uid())");
  });
});

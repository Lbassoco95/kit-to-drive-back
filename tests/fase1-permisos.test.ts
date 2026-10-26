import { readFileSync, readdirSync, existsSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/**
 * Fase 1 de seguridad de la base de producción (docs/seguridad/).
 * ───────────────────────────────────────────────────────────────────────────
 * Estas pruebas no necesitan base de datos: revisan que las seis migraciones
 * sean pequeñas, reversibles y no abran nada, y que el respaldo sobre el que se
 * calcularon las reversas no lleve datos personales.
 */
const RAIZ = process.cwd();
const leer = (...p: string[]) => readFileSync(join(RAIZ, ...p), "utf8");
/** Quita comentarios de una línea para revisar solo el SQL que se ejecuta. */
const sinComentarios = (sql: string) => sql.split("\n").map(l => l.replace(/--.*$/, "")).join("\n");

const MIGRACIONES = [
  "20261031000001_fase1_quitar_truncate_trigger_references",
  "20261031000002_fase1_cerrar_funciones_de_trigger",
  "20261031000003_fase1_fijar_search_path",
  "20261031000004_fase1_quitar_lectura_anon_de_vistas",
  "20261031000005_fase1_quitar_escritura_anon_de_tablas",
  "20261031000006_fase1_lo_nuevo_nace_cerrado",
];
const mig = (n: string) => leer("supabase", "migrations", `${n}.sql`);
const rev = (n: string) => leer("supabase", "reversas", `${n}_reversa.sql`);

describe("Fase 1: una migración por punto, cada una con su reversa", () => {
  it("las seis migraciones y sus reversas existen", () => {
    for (const n of MIGRACIONES) {
      expect(existsSync(join(RAIZ, "supabase", "migrations", `${n}.sql`)), n).toBe(true);
      expect(existsSync(join(RAIZ, "supabase", "reversas", `${n}_reversa.sql`)), `${n} (reversa)`).toBe(true);
    }
  });

  it("la carpeta de reversas no tiene archivos sin migración", () => {
    const sobrantes = readdirSync(join(RAIZ, "supabase", "reversas"))
      .filter(f => f.endsWith(".sql"))
      .map(f => f.replace(/_reversa\.sql$/, ""))
      .filter(n => n.startsWith("20261031") && !MIGRACIONES.includes(n));  // la Fase 2 (20261107…) tiene su propia prueba
    expect(sobrantes).toEqual([]);
  });

  it("ninguna migración usa CASCADE ni borra, vacía, inserta o actualiza datos", () => {
    for (const n of MIGRACIONES) {
      const sql = sinComentarios(mig(n));
      expect(sql, n).not.toMatch(/\bCASCADE\b/i);
      expect(sql, n).not.toMatch(/\b(DROP|TRUNCATE)\s+(TABLE|FUNCTION|POLICY|VIEW|SCHEMA|ROLE|TRIGGER|INDEX)/i);
      expect(sql, n).not.toMatch(/^\s*(DELETE\s+FROM|INSERT\s+INTO|UPDATE\s)/im);
    }
  });

  it("las migraciones solo quitan permisos; el único GRANT es para el rol de Auth", () => {
    for (const n of MIGRACIONES) {
      const sql = sinComentarios(mig(n));
      const grants = [...sql.matchAll(/\bGRANT\b[^;]*;/gi)].map(m => m[0]);
      for (const g of grants) expect(g, `${n}: ${g}`).toMatch(/TO\s+supabase_auth_admin/i);
    }
  });

  it("las reversas solo conceden (no quitan nada) y cada una repone algo", () => {
    for (const n of MIGRACIONES) {
      const sql = sinComentarios(rev(n));
      expect(sql, n).not.toMatch(/\bREVOKE\b/i);
      expect(sql, n).toMatch(/\b(GRANT|RESET\s+search_path|ALTER DEFAULT PRIVILEGES)\b/i);
    }
  });

  it("cada migración trae su verificación y menciona su reversa", () => {
    for (const n of MIGRACIONES) {
      const sql = mig(n);
      expect(sql, n).toMatch(/Verificaci[oó]n/);
      expect(sql, n).toContain(`reversas/${n}_reversa.sql`);
    }
  });
});

describe("Fase 1: forma de revocar", () => {
  it("1) TRUNCATE, TRIGGER y REFERENCES, solo a anon y authenticated, sin tocar SELECT/INSERT/UPDATE/DELETE", () => {
    const sql = sinComentarios(mig(MIGRACIONES[0]));
    expect(sql).toMatch(/REVOKE TRUNCATE, TRIGGER, REFERENCES ON ALL TABLES IN SCHEMA public FROM anon, authenticated;/);
    const permisos = [...sql.matchAll(/REVOKE\s+(.+?)\s+ON\s/gi)].map(m => m[1]);
    expect(permisos).toEqual(["TRUNCATE, TRIGGER, REFERENCES"]);
  });

  it("2) funciones de trigger: revoca a PUBLIC, anon y authenticated, conserva service_role y el rol de Auth", () => {
    const sql = sinComentarios(mig(MIGRACIONES[1]));
    expect(sql).toContain("REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated");
    expect(sql).not.toMatch(/service_role/);
    expect(sql).toContain("GRANT EXECUTE ON FUNCTION public.handle_new_user()        TO supabase_auth_admin");
    expect(sql).toContain("GRANT EXECUTE ON FUNCTION public.reject_public_signups()  TO supabase_auth_admin");
    expect(sql).toMatch(/prorettype IN \('trigger'::regtype/);
  });

  it("3) search_path: exactamente 14 funciones, con SET search_path = public y guarda de existencia", () => {
    const sql = sinComentarios(mig(MIGRACIONES[2]));
    const firmas = [...sql.matchAll(/'(public\.[a-z_0-9]+\([^)]*\))'/g)].map(m => m[1]);
    expect(firmas.length).toBe(14);
    expect(new Set(firmas).size).toBe(14);
    expect(sql).toContain("to_regprocedure(f) IS NULL");
    expect(sql).toContain("ALTER FUNCTION %s SET search_path = public");
    const rsql = sinComentarios(rev(MIGRACIONES[2]));
    const rfirmas = [...rsql.matchAll(/'(public\.[a-z_0-9]+\([^)]*\))'/g)].map(m => m[1]);
    expect(rfirmas.sort()).toEqual([...firmas].sort());
    expect(rsql).toContain("ALTER FUNCTION %s RESET search_path");
  });

  it("4) vistas: quita ALL solo a anon", () => {
    const sql = sinComentarios(mig(MIGRACIONES[3]));
    expect(sql).toContain("REVOKE ALL ON public.%I FROM anon");
    expect(sql).not.toMatch(/FROM[^;]*authenticated/);
  });

  it("5) tablas: quita solo INSERT, UPDATE y DELETE, solo a anon", () => {
    const sql = sinComentarios(mig(MIGRACIONES[4]));
    expect(sql).toMatch(/REVOKE INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public FROM anon;/);
    expect(sql).not.toMatch(/\bSELECT\b[^;]*FROM anon/i);
  });

  it("6) lo nuevo nace cerrado: la revocación de PUBLIC en funciones es GLOBAL (la de esquema ya falló)", () => {
    const sql = sinComentarios(mig(MIGRACIONES[5]));
    expect(sql).toMatch(/ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;/);
    expect(sql).toMatch(/ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON TABLES FROM anon;/);
    // El intento de 20261009000002 solo existe en esquema y no quitó PUBLIC: no se debe depender de él.
    expect(sinComentarios(mig("20261009000002_cerrar_puente_heredado_y_funciones_anon")))
      .toContain("ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon");
  });
});

describe("Fase 1: las reversas reponen solo lo que existía en el respaldo", () => {
  const respaldoRel = leer("docs", "seguridad", "respaldo", "permisos-relaciones.sql");
  const respaldoFun = leer("docs", "seguridad", "respaldo", "permisos-funciones.sql");
  /** { "tabla|rol": Set(permisos) } del respaldo (anon y authenticated). */
  const acl = new Map<string, Set<string>>();
  for (const m of respaldoRel.matchAll(/^GRANT (.+?) ON public\.(\S+) TO (anon|authenticated);/gm)) {
    acl.set(`${m[2]}|${m[3]}`, new Set(m[1].split(",").map(s => s.trim())));
  }

  const grantsDe = (sql: string) =>
    [...sinComentarios(sql).matchAll(/^GRANT (.+?) ON public\.(\S+) TO (anon|authenticated);/gm)]
      .map(m => ({ permisos: m[1].split(",").map(s => s.trim()), objeto: m[2], rol: m[3] }));

  it("hay respaldo de relaciones y de funciones", () => {
    expect(acl.size).toBeGreaterThan(150);
    expect(respaldoFun).toMatch(/GRANT EXECUTE ON FUNCTION public\./);
  });

  it("reversa 1: solo TRUNCATE/TRIGGER/REFERENCES y solo donde el respaldo los tenía", () => {
    const g = grantsDe(rev(MIGRACIONES[0]));
    expect(g.length).toBeGreaterThan(100);
    for (const x of g) {
      for (const p of x.permisos) {
        expect(["TRUNCATE", "TRIGGER", "REFERENCES"], `${x.objeto}: ${p}`).toContain(p);
        expect(acl.get(`${x.objeto}|${x.rol}`)?.has(p), `${x.objeto} ${x.rol} ${p}`).toBe(true);
      }
    }
  });

  it("reversa 4: solo anon, solo vistas que lo tenían, sin reponer lo que el punto 1 quitó", () => {
    const g = grantsDe(rev(MIGRACIONES[3]));
    expect(g.length).toBe(16);
    for (const x of g) {
      expect(x.rol).toBe("anon");
      for (const p of x.permisos) {
        expect(["TRUNCATE", "TRIGGER", "REFERENCES"], `${x.objeto}: ${p}`).not.toContain(p);
        expect(acl.get(`${x.objeto}|anon`)?.has(p), `${x.objeto} ${p}`).toBe(true);
      }
    }
  });

  it("reversa 5: solo INSERT, UPDATE y DELETE, solo anon, en 81 tablas", () => {
    const g = grantsDe(rev(MIGRACIONES[4]));
    expect(g.length).toBe(81);
    for (const x of g) {
      expect(x.rol).toBe("anon");
      expect(x.permisos.sort()).toEqual(["DELETE", "INSERT", "UPDATE"]);
      expect(acl.get(`${x.objeto}|anon`)?.has("INSERT"), x.objeto).toBe(true);
    }
  });

  it("reversa 2: cada GRANT EXECUTE existía tal cual en el respaldo de funciones", () => {
    const lineas = [...sinComentarios(rev(MIGRACIONES[1])).matchAll(/^GRANT EXECUTE ON FUNCTION (\S+?)\((.*?)\) TO (\S+);/gm)];
    expect(lineas.length).toBe(49);
    for (const m of lineas) {
      const esperado = `GRANT EXECUTE ON FUNCTION ${m[1]}(${m[2]}) TO ${m[3]};`;
      expect(respaldoFun.includes(esperado), esperado).toBe(true);
    }
  });
});

describe("Fase 1: el respaldo no lleva datos personales ni secretos", () => {
  const dir = join(RAIZ, "docs", "seguridad", "respaldo");
  const archivos = existsSync(dir) ? readdirSync(dir) : [];

  it("hay respaldo versionado de permisos, funciones, políticas y permisos por defecto", () => {
    for (const f of ["permisos-relaciones.sql", "permisos-funciones.sql", "politicas-public-y-storage.sql",
                     "funciones-config-y-huella.txt", "permisos-por-defecto.txt", "rls-y-vistas.txt"]) {
      expect(archivos, f).toContain(f);
    }
  });

  it("ningún archivo del respaldo contiene correos, JWT ni llaves", () => {
    for (const f of archivos) {
      const t = readFileSync(join(dir, f), "utf8");
      expect(t, `${f}: correo`).not.toMatch(/[\w.+-]+@[\w-]+\.[a-z]{2,}/i);
      expect(t, `${f}: JWT`).not.toMatch(/eyJ[\w-]{10,}\.[\w-]{10,}\./);
      expect(t, `${f}: llave`).not.toMatch(/\b(sb_secret_|sb_publishable_|service_role_key|sk_live)/i);
    }
  });
});

/**
 * Guardia para las migraciones NUEVAS (después de la Fase 1): como los permisos
 * por defecto de funciones ya no incluyen a authenticated, toda función que el
 * front llame o que usen las políticas necesita su GRANT EXECUTE explícito. QA
 * (kit-to-drive-db-qa) no recibe el cambio de permisos por defecto, así que ahí
 * una función sin GRANT sí funcionaría y en producción no: este guardia lo atrapa
 * antes de llegar a producción. Las funciones de trigger no lo necesitan, y una
 * función solo para uso interno se marca con el comentario `-- interna`.
 */
export function funcionesSinGrant(sql: string): string[] {
  const limpio = sinComentarios(sql);
  const faltan: string[] = [];
  const re = /CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+(?:public\.)?([a-z_0-9]+)\s*\(([^)]*)\)\s*RETURNS\s+([a-z_ ]+)/gi;
  for (const m of limpio.matchAll(re)) {
    const nombre = m[1];
    if (/^\s*trigger\b/i.test(m[3]) || /^\s*event_trigger\b/i.test(m[3])) continue;
    const concedida = new RegExp(`GRANT\\s+EXECUTE\\s+ON\\s+FUNCTION\\s+(?:public\\.)?${nombre}\\s*\\(`, "i").test(limpio);
    const interna = new RegExp(`--\\s*interna[^\\n]*\\b${nombre}\\b|--[^\\n]*\\b${nombre}\\b[^\\n]*\\binterna\\b`, "i").test(sql);
    if (!concedida && !interna) faltan.push(nombre);
  }
  return [...new Set(faltan)];
}

describe("guardia de migraciones nuevas: GRANT EXECUTE explícito", () => {
  it("el guardia detecta una función sin GRANT y respeta triggers, GRANT e `interna`", () => {
    expect(funcionesSinGrant("CREATE FUNCTION public.nueva(x int) RETURNS int LANGUAGE sql AS 'select 1';")).toEqual(["nueva"]);
    expect(funcionesSinGrant("CREATE FUNCTION public.nueva(x int) RETURNS int LANGUAGE sql AS 'select 1';\nGRANT EXECUTE ON FUNCTION public.nueva(int) TO authenticated;")).toEqual([]);
    expect(funcionesSinGrant("CREATE FUNCTION public.t() RETURNS trigger LANGUAGE plpgsql AS 'begin return new; end';")).toEqual([]);
    expect(funcionesSinGrant("-- interna: nueva_aux solo la llaman otras funciones\nCREATE FUNCTION public.nueva_aux() RETURNS int LANGUAGE sql AS 'select 1';")).toEqual([]);
  });

  it("las migraciones posteriores a la Fase 1 dan GRANT EXECUTE explícito a cada función", () => {
    const nuevas = readdirSync(join(RAIZ, "supabase", "migrations"))
      .filter(f => f.endsWith(".sql") && f > "20261031999999");
    const malas = nuevas.flatMap(f => funcionesSinGrant(leer("supabase", "migrations", f)).map(n => `${f}: ${n}`));
    expect(malas, "Estas funciones no traen GRANT EXECUTE explícito (ver docs/guia-del-equipo.md):\n" + malas.join("\n")).toEqual([]);
  });
});

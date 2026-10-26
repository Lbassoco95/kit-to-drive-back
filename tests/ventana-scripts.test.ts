import { existsSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/**
 * Scripts que corre Polo en la ventana (scripts/ventana/). Revisión estática: no guardan secretos, no se saltan la
 * comprobación de proyecto, las lecturas son de solo lectura y aplicar/revertir son una sola transacción con registro.
 */
const RAIZ = process.cwd();
const s = (f: string) => readFileSync(join(RAIZ, "scripts", "ventana", f), "utf8");
const SCRIPTS = ["conectar.sh", "foto-integridad.sh", "comparar-integridad.sh", "catalogo.sh", "aplicar.sh", "revertir.sh"];

describe("scripts de la ventana (mecanismo psql, opción A)", () => {
  it("existen y son ejecutables", () => {
    for (const f of SCRIPTS) {
      expect(existsSync(join(RAIZ, "scripts", "ventana", f)), f).toBe(true);
      expect(statSync(join(RAIZ, "scripts", "ventana", f)).mode & 0o111, `${f} ejecutable`).toBeGreaterThan(0);
    }
  });
  it("la contraseña se lee sin eco y nunca se escribe en un archivo ni se imprime", () => {
    const c = s("conectar.sh");
    expect(c).toContain("read -rs");
    for (const f of SCRIPTS) {
      const t = s(f);
      expect(t, f).not.toMatch(/PGPASSWORD=['"]?[^\s$'"]/);   // sin contraseña literal
      expect(t, f).not.toMatch(/echo[^\n]*\$PGPASSWORD/);
      expect(t, f).not.toMatch(/>\s*[^\n]*pgpass/i);
      expect(t, f).not.toMatch(/eyJ[\w-]{10,}\.[\w-]{10,}\./);
    }
  });
  it("conectar.sh se detiene si no es producción o si es QA", () => {
    const c = s("conectar.sh");
    expect(c).toContain("dmhzhyeivvuliumcgsmm");
    expect(c).toContain("qszllskpizvpnzcytqpj");
    expect(c).toMatch(/STOP/);
  });
  it("foto, comparación y catálogo fuerzan solo lectura", () => {
    for (const f of ["foto-integridad.sh", "comparar-integridad.sh", "catalogo.sh"]) {
      expect(s(f), f).toContain("default_transaction_read_only=on");
      expect(s(f), f).not.toMatch(/\b(INSERT|UPDATE|DELETE|DROP|ALTER|CREATE|GRANT|REVOKE|TRUNCATE)\b/);
    }
  });
  it("aplicar y revertir: una transacción, comprueban el proyecto, piden confirmación y registran", () => {
    for (const f of ["aplicar.sh", "revertir.sh"]) {
      const t = s(f);
      expect(t, f).toContain("--single-transaction");
      expect(t, f).toContain("ON_ERROR_STOP=1");
      expect(t, f).toMatch(/dmhzhyeivvuliumcgsmm/);
      expect(t, f).toMatch(/read -r -p/);
      expect(t, f).toContain("migraciones_aplicadas");
      expect(t, f).not.toMatch(/\bCASCADE\b/i);
      expect(t, f).not.toMatch(/supabase\s+db\s+push|apply_migration/);
    }
    expect(s("aplicar.sh")).toContain("ON CONFLICT (script) DO UPDATE");
    expect(s("revertir.sh")).toContain("estado = 'superado'");
    expect(s("revertir.sh")).not.toMatch(/DELETE\s+FROM/i);
  });
  it("ventana-logs no se versiona", () => {
    expect(readFileSync(join(RAIZ, ".gitignore"), "utf8")).toContain("ventana-logs/");
  });
});

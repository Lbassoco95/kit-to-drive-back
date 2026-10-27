// Carga de remisiones históricas de refacciones: reglas que no se pueden perder (estructura de la migración;
// el comportamiento lo prueba scripts/db-local/pruebas_remisiones_historicas.sql contra Postgres).
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, it, expect } from "vitest";

const sql = readFileSync(join(__dirname, "..", "supabase/migrations/20261029000001_remisiones_refacciones_historicas.sql"), "utf8");
const cuerpo = (nombre: string) => {
  const i = sql.indexOf(`FUNCTION public.${nombre}(`);
  return sql.slice(i, sql.indexOf("$$;", sql.indexOf("AS $$", i)));
};

describe("carga de remisiones históricas (migración)", () => {
  it("solo un administrador global carga o anula", () => {
    expect(cuerpo("cargar_remisiones_historicas_refacciones")).toContain("NOT public.es_admin_global(auth.uid())");
    expect(cuerpo("anular_remision_historica_refacciones")).toContain("NOT public.es_admin_global(auth.uid())");
  });

  it("no mueve inventario: no escribe stock ni movimientos y lo verifica al final", () => {
    const c = cuerpo("cargar_remisiones_historicas_refacciones");
    expect(c).not.toMatch(/UPDATE\s+public\.almacen_refacciones_productos/i);
    expect(c).not.toMatch(/INSERT\s+INTO\s+public\.almacen_refacciones_movimientos/i);
    expect(c).toContain("La carga movió inventario");
    expect(c).toContain("0, v_cant, 0, 'surtida'"); // nada apartado ni por surtir
    expect(cuerpo("anular_remision_historica_refacciones")).not.toMatch(/almacen_refacciones_(productos|movimientos)/);
  });

  it("simula por omisión, valida todo antes de escribir y no repite una referencia", () => {
    expect(sql).toContain("_simular boolean DEFAULT true");
    expect(sql).toContain("La carga tiene errores y no se escribió nada");
    expect(sql).toContain("ux_remision_refaccion_historica_ref");
  });

  it("queda marcada y auditada", () => {
    for (const k of ["es_historica", "historica_por", "historica_lote", "'carga_historica'", "registrar_bitacora_compras('cobranza', 'carga_historica'", "cargas_remisiones_historicas"]) {
      expect(sql).toContain(k);
    }
  });

  it("no se corrige ni se cancela por los caminos normales", () => {
    expect(sql).toContain("BEFORE UPDATE OR DELETE ON public.remisiones_refacciones");
    expect(sql).toContain("BEFORE UPDATE OR DELETE ON public.remision_refaccion_items");
    expect(sql).toContain("kit.historica_admin");
  });

  it("nada abierto a anon", () => {
    expect(sql).toContain("REVOKE ALL ON FUNCTION public.cargar_remisiones_historicas_refacciones(jsonb, text, boolean) FROM PUBLIC, anon");
    expect(sql).toContain("REVOKE ALL ON FUNCTION public.anular_remision_historica_refacciones(uuid, text) FROM PUBLIC, anon");
  });
});

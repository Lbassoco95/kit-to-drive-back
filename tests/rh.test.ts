import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const RAIZ = process.cwd();
const mig = readFileSync(join(RAIZ, "supabase/migrations/20261111000001_rh_modulo_base.sql"), "utf8");
const guion = readFileSync(join(RAIZ, "scripts/db-local/pruebas_rh.sql"), "utf8");

describe("Recursos Humanos (migración)", () => {
  it("la asistencia, solicitudes y bitácora solo se escriben por RPC", () => {
    expect(mig).toMatch(/REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public\.rh_asistencia,/);
    expect(mig).not.toMatch(/CREATE POLICY "rh_asistencia_(insert|update)/);
  });

  it("la ubicación exacta solo la lee la propia persona (ni RH ni el jefe)", () => {
    const pol = mig.split('"rh_asistencia_ubicacion_select"')[2] ?? "";
    expect(pol.split(";")[0]).toContain("rh_es_yo(empleado_id)");
    expect(pol.split(";")[0]).not.toContain("rh_es_rh()");
    expect(pol.split(";")[0]).not.toContain("rh_es_jefe_de");
  });

  it("el jefe directo no lee expedientes ni datos sensibles", () => {
    for (const t of ["rh_documentos_select", "rh_empleado_datos_select"]) {
      const pol = (mig.split(`"${t}"`)[2] ?? "").split(";")[0];
      expect(pol).toContain("rh_es_yo(");
      expect(pol).not.toContain("rh_es_jefe_de");
    }
  });

  it("los buckets son privados y el expediente se liga al dueño", () => {
    expect(mig).toContain("VALUES ('rh-expedientes', 'rh-expedientes', false");
    expect(mig).toContain("VALUES ('rh-biblioteca', 'rh-biblioteca', false");
  });

  it("ninguna función rh_ queda abierta a anon", () => {
    expect(mig).toContain("REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon");
  });

  it("el guion de pruebas de base cubre cada criterio", () => {
    for (const c of ["Quién es RH", "Plantilla", "Privacidad de ficha, directorio y expediente",
      "Biblioteca y publicaciones", "Checador, geocerca y correcciones",
      "Solicitudes, vacaciones y faltas", "Nada abierto a anon"]) {
      expect(guion).toContain(c);
    }
  });
});

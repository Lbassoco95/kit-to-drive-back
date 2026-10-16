import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const leer = (ruta: string) => readFileSync(join(process.cwd(), ruta), "utf8");

describe("firmas electrónicas (migración)", () => {
  const sql = leer("supabase/migrations/20261016000001_firmas_electronicas.sql");

  it("las tablas son de solo lectura para el front: lo escribe la Edge Function", () => {
    expect(sql).toContain("ALTER TABLE public.firmas_solicitudes ENABLE ROW LEVEL SECURITY");
    expect(sql).toContain("ALTER TABLE public.firmas_firmantes ENABLE ROW LEVEL SECURITY");
    expect(sql).toContain("GRANT SELECT ON public.firmas_solicitudes, public.firmas_firmantes TO authenticated");
    expect(sql).not.toMatch(/GRANT[^;]*(INSERT|UPDATE|DELETE)[^;]*firmas_/i);
    expect(sql).not.toMatch(/FOR (INSERT|UPDATE|DELETE)/i);
  });

  it("el bucket es privado y solo deja leer los PDF, nunca las imágenes de firma", () => {
    expect(sql).toContain("VALUES ('firmas', 'firmas', false");
    expect(sql).toContain("name !~ '/sig-'");
    expect(sql).not.toMatch(/ON storage\.objects\s+FOR (INSERT|UPDATE|DELETE)/i);
  });

  it("ninguna función queda abierta a anon", () => {
    expect(sql).toContain("REVOKE ALL ON FUNCTION public.firmas_puede_ver_solicitud(uuid) FROM PUBLIC, anon");
    expect(sql).toContain("REVOKE ALL ON FUNCTION public.firmas_es_firmante(uuid, uuid) FROM PUBLIC, anon, authenticated");
  });

  it("solo firmantes internos y solo remisiones por ahora", () => {
    expect(sql).toContain("usuario_id        UUID NOT NULL REFERENCES auth.users(id)");
    expect(sql).toContain("CHECK (entidad_tipo IN ('remision'))");
  });
});

describe("firmas electrónicas (Edge Function)", () => {
  const fn = leer("supabase/functions/firmas/index.ts");

  it("exige sesión y JWT", () => {
    expect(leer("supabase/config.toml")).toMatch(/\[functions\.firmas\]\s+verify_jwt = true/);
    expect(fn).toContain('throw new HttpError(401, "Sesión requerida")');
  });

  it("comprueba el acceso a la remisión con el JWT de quien llama, no con service_role", () => {
    expect(fn).toContain('userClient.from("remisiones")');
  });

  it("solo acepta como firmantes a usuarios activos del equipo", () => {
    expect(fn).toContain("Solo se puede pedir firma a usuarios activos del equipo");
  });
});

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

describe("firmas electrónicas (ver imagen de la firma)", () => {
  const sql = leer("supabase/migrations/20261026000001_firmas_ver_imagen_firma.sql");

  it("política aditiva: solo las imágenes sig-*.png y solo quien ve la solicitud", () => {
    expect(sql).toContain('CREATE POLICY "firmas_storage_select_firmas"');
    expect(sql).toContain("FOR SELECT TO authenticated");
    expect(sql).toContain("public.firmas_puede_ver_solicitud(((storage.foldername(name))[1])::uuid)");
    expect(sql).toContain("REVERSA");
    expect(sql).not.toMatch(/FOR (INSERT|UPDATE|DELETE)/i);
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

describe("firmas: documentos subidos y recuadros (migración 2)", () => {
  const sql = leer("supabase/migrations/20261016000002_firmas_documentos_y_recuadros.sql");

  it("acepta documentos sueltos y guarda el lugar de la firma de cada quien", () => {
    expect(sql).toContain("CHECK (entidad_tipo IN ('remision', 'documento'))");
    expect(sql).toContain("ADD COLUMN IF NOT EXISTS recuadros JSONB NOT NULL DEFAULT '[]'::jsonb");
  });

  it("no abre escritura al front", () => {
    expect(sql).not.toMatch(/GRANT|CREATE POLICY/i);
  });
});

describe("firmas: la función valida el documento y los recuadros", () => {
  const fn = leer("supabase/functions/firmas/index.ts");

  it("acepta remision_id o archivo_base64 y exige PDF real", () => {
    expect(fn).toContain("body.remision_id");
    expect(fn).toContain("body.archivo_base64");
    expect(fn).toContain('"Solo se pueden firmar archivos PDF"');
  });

  it("valida cada recuadro contra el número de páginas", () => {
    expect(fn).toContain("leerRecuadros(p.recuadros, paginas)");
    expect(fn).toContain("Recuadro de firma fuera de la página");
  });

  it("estampa la firma en su recuadro además de la hoja de firmas", () => {
    expect(fn).toContain("pg.drawImage(img");
  });
});

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

const leer = (f: string) => readFileSync(join(RAIZ, f), "utf8");
const mig2 = leer("supabase/migrations/20261111000002_rh_privacidad_sin_salida_contratos.sql");
const fn = leer("supabase/functions/rh-enviar-accesos/index.ts");

describe("RH: privacidad, jornadas sin salida y contratos", () => {
  it("el aviso exige aceptación para capturar datos o subir documentos", () => {
    expect(mig2).toContain("public.rh_aviso_ok(empleado_id)");
    expect(mig2).toMatch(/rh_documentos_dueno_insert[\s\S]*rh_aviso_ok/);
  });

  it("los contratos y avisos solo se escriben por RPC", () => {
    expect(mig2).toContain("REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.rh_contratos");
    expect(mig2).toContain("REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.rh_avisos_privacidad");
  });

  it("no se mandan accesos sin contrato firmado, ni en la base ni en la función", () => {
    expect(mig2).toContain("Primero sube el contrato firmado");
    expect(fn).toContain('code: "SIN_CONTRATO_FIRMADO"');
  });

  it("RH nunca crea administradores y el correo sale antes de crear la cuenta", () => {
    expect(fn).toContain('["operador", "supervisor"].includes(nivel)');
    expect(mig2).toContain("CHECK (nivel_acceso IN ('operador', 'supervisor'))");
    expect(fn).toContain('rpc("rh_es_rh")');
    expect(fn.indexOf("enviarAcceso(")).toBeLessThan(fn.indexOf("auth.admin.createUser"));
    expect(fn.indexOf("autorizarAlta(")).toBeLessThan(fn.indexOf("auth.admin.createUser"));
    expect(fn).not.toMatch(/password[^\n]*body/);
  });

  it("la jornada sin salida se cierra sola y cuenta como falta configurable", () => {
    expect(mig2).toContain("sin_salida_es_falta");
    expect(mig2).toContain("jornada_max_horas");
    expect(mig2).toContain("rh_cerrar_jornadas_vencidas");
  });

  it("el guion de pruebas cubre los tres temas", () => {
    for (const c of ["Aviso de privacidad", "Jornada sin salida", "Contratos y alta por ingresar"]) expect(guion).toContain(c);
  });
});

const mig3 = leer("supabase/migrations/20261112000001_rh_migrar_usuarios_y_auditoria.sql");

describe("RH: migrar usuarios y registro de cambios", () => {
  it("los datos personales se registran sin sus valores (solo nombres de campos)", () => {
    expect(mig3).toContain("sensible BOOLEAN := (TG_TABLE_NAME = 'rh_empleado_datos')");
    expect(mig3).toContain("IF sensible THEN antes := NULL; despues := NULL; END IF;");
  });

  it("todo cambio de RH va a su historial y a la bitácora general de Sistema", () => {
    expect(mig3).toContain("INSERT INTO public.rh_bitacora_cambios");
    expect(mig3).toContain("INSERT INTO public.bitacora_eventos");
    for (const t of ["rh_empleados", "rh_empleado_datos", "rh_documentos", "rh_horarios", "rh_contratos", "rh_vacaciones_saldos"]) {
      expect(mig3).toContain(`'${t}'`);
    }
  });

  it("el historial solo lo lee RH y nadie lo escribe directo", () => {
    expect(mig3).toContain("REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.rh_bitacora_cambios");
    expect((mig3.split('"rh_bitacora_cambios_select"')[2] ?? "").split(";")[0]).toContain("rh_es_rh()");
  });

  it("corregir datos personales o quitar un documento pide motivo", () => {
    expect(mig3).toContain("Explica el motivo de la corrección (mínimo 10 caracteres).");
    expect(mig3).toContain("Para dar de baja explica el motivo");
    expect(mig3).toContain("RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$\nDECLARE d public.rh_documentos");
  });

  it("solo RH o el admin del área marcan trabajadores; el alta en bloque es solo de RH", () => {
    expect(mig3).toContain("public.es_admin_area(auth.uid()");
    expect(mig3).toContain("Solo RH migra usuarios en bloque.");
  });

  it("el guion de pruebas cubre los dos temas", () => {
    for (const c of ["Migrar usuarios a trabajadores", "Registro de cambios de RH"]) expect(guion).toContain(c);
  });
});

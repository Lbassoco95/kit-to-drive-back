// Bancos por empresa y búsqueda de remisiones: reglas de estructura que no se pueden perder
// (el comportamiento lo prueba scripts/db-local/pruebas_bancos_busqueda.sql).
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, it, expect } from "vitest";

const sql = readFileSync(join(__dirname, "..", "supabase/migrations/20261031000001_bancos_por_empresa_busqueda_remisiones.sql"), "utf8");
const fn = (nombre: string) => {
  const i = sql.indexOf(`FUNCTION public.${nombre}(`);
  expect(i).toBeGreaterThan(0);
  return sql.slice(i, sql.indexOf("\n$$;", i));
};

describe("bancos por empresa", () => {
  it("depende de la unificación y no deja escribir cuentas directo", () => {
    expect(sql).toContain("20261030000001");
    expect(sql).toMatch(/REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public\.cuentas_financieras FROM PUBLIC, anon, authenticated/);
    expect(sql).toContain("DROP POLICY IF EXISTS cuentas_write ON public.cuentas_financieras");
  });
  it("solo últimos 4 dígitos: nunca el número completo; las cuentas no se borran", () => {
    expect(sql).toContain("cuentas_sin_numero_completo CHECK (numero_cuenta IS NULL)");
    expect(sql).toContain("ultimos4 ~ '^[0-9]{4}$'");
    expect(fn("cuenta_catalogo_guardia")).toContain("Una cuenta no se borra");
    expect(fn("cuenta_catalogo_guardia")).toContain("ya tiene movimientos");
  });
  it("alta y edición solo por el administrador financiero, con bitácora inmutable", () => {
    for (const f of ["empresa_guardar", "cuenta_guardar"]) {
      expect(fn(f)).toContain("es_finanzas_admin(auth.uid())");
      expect(fn(f)).toContain("catalogo_bancos_bitacora");
    }
    expect(fn("catalogo_bancos_bitacora_inmutable")).toContain("no se edita ni se borra");
  });
  it("Caja solo confirma en cuentas de la empresa del movimiento, sin perder reglas de método y moneda", () => {
    const c = fn("flujo_confirmar_caja");
    expect(c).toContain("c.empresa_id IS DISTINCT FROM f.empresa_id");
    expect(c).toContain("maneja % y el movimiento está en %");
    expect(fn("flujo_cuentas")).toContain("c.empresa_id = f.empresa_id");
    expect(fn("flujo_recibir")).toContain("Elige la empresa del grupo");
  });
  it("saldos solo con lo confirmado; lo no confirmado va aparte, en tránsito", () => {
    expect(sql).toContain("m.estatus = 'CONFIRMADO'");
    expect(sql).toContain("v_saldos_por_empresa");
    expect(sql).toMatch(/v_flujo_en_transito[\s\S]*WHERE f\.etapa = 'RECIBIDO'/);
  });
});

describe("búsqueda de remisiones y cambio de cliente", () => {
  it("solo confirmadas, no canceladas, con saldo; prueba y real separados; sin quien recibió o confirmó", () => {
    const b = fn("flujo_buscar_remisiones");
    expect(b).toContain("r.es_prueba = f.es_prueba");
    expect(b).toContain("r.etapa <> 'cancelada' AND NOT r.abierta");
    expect(b).toContain("e.saldo_pendiente > 0");
    expect(b).toContain("auth.uid() IN (f.recibido_por, f.caja_por)");
    expect(b).toContain("least(coalesce(_limite, 20), 100)");
  });
  it("cambiar cliente exige motivo, otra persona, misma modalidad y deja huella", () => {
    const c = fn("flujo_cambiar_cliente");
    expect(c).toContain("El motivo del cambio de cliente es obligatorio");
    expect(c).toContain("auth.uid() IN (f.recibido_por, f.caja_por)");
    expect(c).toContain("No se mezclan datos de prueba con reales");
    expect(c).toContain("'CLIENTE_CAMBIADO'");
    expect(c).toContain("flujo_cambio_cliente_exige_admin");
  });
});

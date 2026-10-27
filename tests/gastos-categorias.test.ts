// Gastos en dos etapas, categorías, cuentas por prueba/real, históricos y regularización: reglas de estructura
// que no se pueden perder (el comportamiento lo prueba scripts/db-local/pruebas_gastos.sql).
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, it, expect } from "vitest";

const sql = readFileSync(join(__dirname, "..", "supabase/migrations/20261101000001_gastos_categorias_regularizacion.sql"), "utf8");
const fn = (nombre: string) => {
  const i = sql.indexOf(`FUNCTION public.${nombre}(`);
  expect(i).toBeGreaterThan(0);
  return sql.slice(i, sql.indexOf("\n$$;", i));
};

describe("gastos: dos etapas con separación de funciones", () => {
  it("captura y confirmación son perfiles distintos y nadie confirma lo que capturó", () => {
    expect(fn("flujo_capturar_gasto")).toContain("flujo_cap('captura_gasto')");
    expect(fn("flujo_confirmar_gasto")).toContain("flujo_cap('confirma_gasto')");
    expect(fn("flujo_confirmar_gasto")).toContain("f.recibido_por = auth.uid()");
    expect(fn("flujo_rechazar_gasto")).toContain("f.recibido_por = auth.uid()");
  });
  it("efectivo: Luna autoriza y Caja entrega; el libro solo se mueve al entregar o al confirmar por banco", () => {
    expect(fn("flujo_confirmar_gasto")).toContain("'AUTORIZADO'");
    expect(fn("flujo_entregar_gasto")).toContain("flujo_cap('caja')");
    expect(fn("flujo_entregar_gasto")).toContain("auth.uid() IN (f.recibido_por, f.autorizado_por)");
    expect((sql.match(/_flujo_libro_insertar\(f, c\)/g) ?? []).length).toBe(2);
  });
  it("el saldo suficiente se exige al confirmar o entregar", () => {
    expect(fn("flujo_confirmar_gasto")).toContain("_exigir_saldo");
    expect(fn("flujo_entregar_gasto")).toContain("_exigir_saldo");
    expect(fn("_exigir_saldo")).toContain("Saldo insuficiente");
  });
  it("evidencia, categoría activa, ámbito internacional y moneda permitida", () => {
    const v = fn("_gasto_validar");
    expect(v).toContain("Sin evidencia no se registra");
    expect(v).toContain("moneda_permitida");
    expect(v).toContain("cat.ambito = 'INTERNACIONAL' AND _moneda = 'MXN'");
  });
  it("Recibe, Caja y Aplica ya no tocan los gastos", () => {
    expect(fn("flujo_recibir")).toContain("pestaña Gastos");
    expect(fn("flujo_confirmar_caja")).toContain("es un gasto");
    expect(fn("flujo_aplicar")).toContain("es un gasto");
    expect(fn("flujo_rechazar")).toContain("es un gasto");
  });
});

describe("regla para toda persona y regularización", () => {
  it("nadie cancela ni ajusta lo que capturó, confirmó, autorizó o entregó", () => {
    expect(fn("_libro_no_es_mio")).toContain("created_by, _mov.confirmado_por");
    expect(fn("_libro_no_es_mio")).toContain("f.recibido_por, f.caja_por, f.autorizado_por, f.aplicado_por");
    for (const f of ["movimiento_cancelar", "movimiento_ajustar", "movimiento_historico_resolver", "movimiento_reclasificar_cuenta"]) {
      expect(fn(f)).toContain("_libro_no_es_mio");
    }
  });
  it("los históricos se resuelven con motivo y bitácora; la reclasificación no toca el original", () => {
    expect(fn("movimiento_historico_resolver")).toContain("m.origen <> 'HISTORICO_DIRECTO'");
    expect(fn("movimiento_historico_resolver")).toContain("RESOLVER_HISTORICO");
    const r = fn("movimiento_reclasificar_cuenta");
    expect(r).toContain("'CONTRA_MOVIMIENTO'");
    expect(r).toContain("afecta_totales");
    expect(r).not.toMatch(/UPDATE public\.movimientos_financieros SET (monto|cuenta_id|estatus)/);
  });
  it("el libro solo acepta orígenes autorizados y todo pasa por funciones", () => {
    expect(sql).toContain("NEW.origen NOT IN ('FLUJO', 'CONTRA_MOVIMIENTO', 'REGULARIZACION')");
    expect(fn("cobranza_pago_regularizar")).toContain("ya pasó por el flujo de dinero");
  });
});

describe("categorías y prueba/real", () => {
  it("categorías por RPC con bitácora, sin escritura directa ni borrado", () => {
    expect(sql).toMatch(/REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public\.categorias_financieras FROM PUBLIC, anon, authenticated/);
    expect(fn("categoria_guardar")).toContain("catalogo_bancos_bitacora");
    expect(sql).toContain("UPDATE public.categorias_financieras SET activo = false WHERE tipo = 'EGRESO' AND nombre = 'Mantenimiento'");
  });
  it("empresas, cuentas y categorías: cada quien ve solo su modalidad", () => {
    expect(sql).toContain("USING (es_prueba = public.es_usuario_prueba(auth.uid()))");
    expect(sql).toContain("WHERE c.es_prueba = public.es_usuario_prueba(auth.uid())");
  });
});

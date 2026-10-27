// Unificación de Control financiero y flujo de dinero: reglas de estructura que no se pueden perder
// (el comportamiento lo prueban scripts/db-local/pruebas_unificacion.sql y probar_unificacion_transicion.sh).
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, it, expect } from "vitest";

const sql = readFileSync(join(__dirname, "..", "supabase/migrations/20261030000001_unificar_control_financiero_flujo.sql"), "utf8");
const fn = (nombre: string) => {
  const i = sql.indexOf(`FUNCTION public.${nombre}(`);
  expect(i).toBeGreaterThan(0);
  return sql.slice(i, sql.indexOf("\n$$;", i));
};

describe("unificación: una sola puerta", () => {
  it("el libro no se escribe directo: sin políticas ni privilegios de escritura, y el candado exige pasar por Caja", () => {
    for (const p of ["movimientos_insert", "movimientos_update_admin", "movimientos_update_propio", "movimientos_delete"]) {
      expect(sql).toContain(`DROP POLICY IF EXISTS ${p} ON public.movimientos_financieros`);
    }
    expect(sql).toMatch(/REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public\.movimientos_financieros FROM PUBLIC, anon, authenticated/);
    expect(sql).toContain("kit.libro_via_flujo");
    expect(sql).toContain("BEFORE INSERT OR UPDATE OR DELETE ON public.movimientos_financieros");
    expect(fn("libro_guardia")).toContain("En el libro nada se borra");
  });

  it("solo flujo_confirmar_caja abre el interruptor del libro", () => {
    const quienes = [...sql.matchAll(/set_config\('kit\.libro_via_flujo', 'on'/g)].length;
    expect(quienes).toBe(1);
    expect(fn("flujo_confirmar_caja")).toContain("set_config('kit.libro_via_flujo', 'on'");
    expect(fn("flujo_confirmar_caja")).toContain("'FLUJO', f.id");
  });

  it("los abonos a cuentas por cobrar solo nacen del flujo y no se borran", () => {
    expect(sql).toContain("DROP POLICY IF EXISTS cxc_abonos_insert ON public.cxc_abonos");
    expect(sql).toContain("DROP POLICY IF EXISTS cxc_abonos_delete ON public.cxc_abonos");
    expect(fn("cxc_guardia")).toContain("nacen solo del flujo de dinero");
    expect(fn("flujo_aplicar")).toContain("INSERT INTO public.cxc_abonos");
  });

  it("se cierran los pagos de cobranza directos", () => {
    for (const f of ["registrar_pago_cobranza(jsonb)", "validar_pago_cobranza(uuid, boolean, text)", "aplicar_pago_cobranza(uuid, jsonb, boolean, text)"]) {
      expect(sql).toContain(`REVOKE EXECUTE ON FUNCTION public.${f} FROM PUBLIC, anon, authenticated`);
    }
    expect(sql).toContain("REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.cobranza_pagos, public.cobranza_aplicaciones, public.cobranza_saldos_favor");
  });
});

describe("unificación: evidencia, historial y reversa", () => {
  it("Recibe exige evidencia y solo acepta datos de una lista", () => {
    const f = fn("flujo_recibir");
    expect(f).toContain("Sin evidencia no se registra");
    expect(f).toContain("Datos no permitidos");
    expect(sql).toContain("DROP FUNCTION IF EXISTS public.flujo_recibir(text, numeric, text, text, date, text, uuid, text, text, numeric)");
  });

  it("el historial no se edita ni se borra y cada paso lo escribe", () => {
    expect(sql).toContain("BEFORE UPDATE OR DELETE ON public.flujo_dinero_eventos");
    for (const f of ["flujo_recibir", "flujo_confirmar_caja", "flujo_aplicar", "flujo_rechazar", "_flujo_revertir"]) {
      expect(fn(f)).toContain("_flujo_evento(");
    }
  });

  it("la reversa desde Cobranza deja el flujo coherente y no borra nada", () => {
    expect(fn("revertir_pago_cobranza")).toContain("_flujo_revertir(v_flujo, _motivo, true)");
    expect(fn("revertir_aplicacion_cobranza")).toContain("_flujo_revertir(v_flujo, _motivo, false)");
    const r = fn("_flujo_revertir");
    expect(r).toContain("etapa = 'EN_CAJA'");
    expect(r).toContain("etapa = 'REVERTIDO'");
    expect(r).not.toMatch(/DELETE FROM/);
  });

  it("corregir el libro es solo del administrador financiero, con motivo, y no toca montos", () => {
    for (const f of ["movimiento_cancelar", "movimiento_ajustar", "cuenta_ajustar_saldo_inicial"]) {
      expect(fn(f)).toContain("es_finanzas_admin(auth.uid())");
      expect(fn(f)).toContain("mínimo 5 caracteres");
    }
    expect(fn("movimiento_ajustar")).not.toMatch(/monto\s*=\s*CASE/);
    expect(fn("movimiento_cancelar")).toContain("Quien confirmó este movimiento en caja no lo cancela");
  });

  it("nada abierto a anon y los núcleos internos no se llaman desde fuera", () => {
    for (const f of ["_flujo_revertir(uuid, text, boolean)", "_flujo_evento(uuid, text, text, text, text, jsonb)", "_cxc_revertir_abono(uuid, text)"]) {
      expect(sql).toContain(`REVOKE ALL ON FUNCTION public.${f} FROM PUBLIC, anon, authenticated`);
    }
    expect(sql).toContain("REVOKE ALL ON FUNCTION public.flujo_aplicar(uuid, text, jsonb, text, jsonb) FROM PUBLIC, anon");
  });

  it("sin pérdida: la migración no elimina tablas ni columnas", () => {
    expect(sql).not.toMatch(/DROP TABLE/i);
    expect(sql).not.toMatch(/DROP COLUMN/i);
    expect(sql).not.toMatch(/TRUNCATE\s+(TABLE\s+)?public\./i);
  });
});

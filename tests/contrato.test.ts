import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
// @ts-expect-error módulo .mjs sin tipos
import { contrato } from "../scripts/generar-contrato.mjs";

describe("contrato con el front", () => {
  it("contrato/funciones.json está al día (si falla: npm run contrato y copia el archivo al front)", () => {
    const guardado = JSON.parse(readFileSync(join(process.cwd(), "contrato", "funciones.json"), "utf8"));
    expect(guardado).toEqual(contrato());
  });

  it("las funciones retiradas (DROP) ya no están en el contrato y las nuevas sí", () => {
    const f: string[] = contrato().funciones;
    // Perfiles por etapa: una sola forma de dar la etapa del flujo de dinero.
    expect(f).not.toContain("flujo_asignar_capacidad");
    expect(f).not.toContain("flujo_listar_capacidades");
    for (const n of ["flujo_asignar_perfil", "flujo_listar_perfiles", "flujo_catalogo_perfiles", "flujo_mis_capacidades", "perfiles_flujo_fijar"]) {
      expect(f).toContain(n);
    }
  });
});

// Genera contrato/funciones.json: las funciones de `public` que las migraciones crean.
// El front (kit-to-drive) copia este archivo para comprobar que toda RPC que llama existe,
// sin necesitar una copia de las migraciones.   Uso: npm run contrato
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const RAIZ = join(dirname(fileURLToPath(import.meta.url)), "..");
const DIR = join(RAIZ, "supabase", "migrations");

export function funcionesDeMigraciones() {
  // Se recorren las migraciones en orden: una función cuyo ÚLTIMO evento es un DROP ya no existe
  // (p. ej. flujo_asignar_capacidad, retirada al pasar a perfiles) y no debe estar en el contrato.
  // (Si un DROP quita solo una sobrecarga y otra sigue viva, hay que volver a crearla después.)
  const ultimo = new Map();
  for (const f of readdirSync(DIR).filter((x) => x.endsWith(".sql")).sort()) {
    const sql = readFileSync(join(DIR, f), "utf8");
    for (const m of sql.matchAll(/(CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION|DROP\s+FUNCTION(?:\s+IF\s+EXISTS)?)\s+public\.([a-z_0-9]+)\s*\(/gi)) {
      ultimo.set(m[2], /^DROP/i.test(m[1]) ? "drop" : "create");
    }
  }
  return [...ultimo].filter(([, e]) => e === "create").map(([n]) => n).sort();
}

export function contrato() {
  return { generado_de: "supabase/migrations", funciones: funcionesDeMigraciones() };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  writeFileSync(join(RAIZ, "contrato", "funciones.json"), JSON.stringify(contrato(), null, 2) + "\n");
  console.log(`contrato/funciones.json: ${contrato().funciones.length} funciones`);
}

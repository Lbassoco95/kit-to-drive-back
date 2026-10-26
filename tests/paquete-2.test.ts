import { describe, it, expect } from 'vitest';
import { readFileSync, readdirSync } from 'node:fs';

const MIG = readdirSync('supabase/migrations').filter((f) => f.startsWith('20261108')).sort();
const leer = (f: string) => readFileSync(`supabase/migrations/${f}`, 'utf8');
const sinComentarios = (s: string) => s.replace(/--.*$/gm, '');

describe('Paquete 2 — reportes y buscadores (solo lectura)', () => {
  it('son 3 migraciones con versión única, posteriores a la Fase 2 (20261107…) y con su reversa', () => {
    expect(MIG).toHaveLength(3);
    const versiones = readdirSync('supabase/migrations').map((f) => f.split('_')[0]);
    for (const m of MIG) {
      const v = m.split('_')[0];
      expect(versiones.filter((x) => x === v)).toHaveLength(1);
      expect(Number(v)).toBeGreaterThan(20261107000005);
      expect(readdirSync('supabase/reversas')).toContain(m.replace(/\.sql$/, '_reversa.sql'));
    }
  });

  it('ninguna función del paquete escribe: sin INSERT, UPDATE ni DELETE, y sin tocar tablas ni políticas', () => {
    for (const m of MIG) {
      const sql = sinComentarios(leer(m));
      expect(sql, m).not.toMatch(/\b(INSERT\s+INTO|UPDATE\s+public|DELETE\s+FROM|CREATE\s+TABLE|CREATE\s+POLICY|ALTER\s+TABLE)\b/i);
      expect(sql, m).toMatch(/STABLE/);
    }
  });

  it('el reporte de ventas es SECURITY INVOKER: la visibilidad es la de las remisiones de quien llama', () => {
    const sql = sinComentarios(leer(MIG[0]));
    expect(sql).toMatch(/SECURITY INVOKER/);
    expect(sql).not.toMatch(/SECURITY DEFINER/);
    expect(sql).toMatch(/r\.etapa <> 'cancelada'/);
    expect(sql).toMatch(/importe_partida_refaccion/);
  });

  it('kárdex y rotación filtrada: misma puerta que las originales (el vendedor no entra), search_path fijo y modo prueba', () => {
    const k = sinComentarios(leer(MIG[1])), r = sinComentarios(leer(MIG[2]));
    expect(k).toMatch(/puede_leer_compras_inventario\(auth\.uid\(\)\)/);
    expect(k).toMatch(/puede_ver_almacen_refacciones\(auth\.uid\(\)\)/);
    expect(k).toMatch(/exigir_lectura_prueba/);
    expect(k).toMatch(/cardinality\(_productos\) > 50/);
    expect(r).toMatch(/puede_leer_compras_inventario\(auth\.uid\(\)\)/);
    expect(r).toMatch(/es_usuario_prueba/);
    for (const sql of [k, r]) expect(sql).toMatch(/SECURITY DEFINER SET search_path = public/);
  });

  it('la rotación filtrada tiene OTRO nombre (una sobrecarga con opcionales haría ambiguas las llamadas por RPC)', () => {
    const sql = sinComentarios(leer(MIG[2]));
    expect(sql).toMatch(/FUNCTION public\.resumen_rotacion_refacciones_filtrado\(/);
    expect(sql).not.toMatch(/FUNCTION public\.resumen_rotacion_refacciones\(/);
  });

  it('todo nace cerrado: REVOKE a PUBLIC y anon, GRANT explícito a authenticated, y reversas que solo borran lo creado', () => {
    for (const m of MIG) {
      const sql = sinComentarios(leer(m));
      expect(sql, m).toMatch(/REVOKE ALL ON FUNCTION public\.\w+\([^)]*\) FROM PUBLIC, anon;/);
      expect(sql, m).toMatch(/GRANT EXECUTE ON FUNCTION public\.\w+\([^)]*\) TO authenticated, service_role;/);
      const rev = sinComentarios(readFileSync(`supabase/reversas/${m.replace(/\.sql$/, '_reversa.sql')}`, 'utf8'));
      expect(rev, m).toMatch(/DROP FUNCTION IF EXISTS public\.\w+\(/);
      expect(rev, m).not.toMatch(/DROP (TABLE|POLICY|TRIGGER)/i);
    }
  });

  it('no vuelve a crear ninguna función que la Fase 2 dejó SECURITY INVOKER', () => {
    for (const m of MIG) expect(sinComentarios(leer(m))).not.toMatch(/cliente_tiene_cxc_vencidas|cxc_vencidas_resumen/);
  });
});

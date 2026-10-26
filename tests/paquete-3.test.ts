import { describe, it, expect } from 'vitest';
import { readFileSync, readdirSync } from 'node:fs';

const MIG = readdirSync('supabase/migrations').filter((f) => f.startsWith('20261109')).sort();
const leer = (f: string) => readFileSync(`supabase/migrations/${f}`, 'utf8');
const leerRev = (m: string) => readFileSync(`supabase/reversas/${m.replace(/\.sql$/, '_reversa.sql')}`, 'utf8');
const sinComentarios = (s: string) => s.replace(/--.*$/gm, '');

describe('Paquete 3 — eliminar remisión y fecha de remisión (el crédito espera a Martin)', () => {
  it('son 3 migraciones con versión única, posteriores a las del Paquete 2 y con su reversa', () => {
    expect(MIG).toHaveLength(3);
    const versiones = readdirSync('supabase/migrations').map((f) => f.split('_')[0]);
    for (const m of MIG) {
      const v = m.split('_')[0];
      expect(versiones.filter((x) => x === v)).toHaveLength(1);
      expect(Number(v)).toBeGreaterThan(20261108000003);
      expect(readdirSync('supabase/reversas')).toContain(m.replace(/\.sql$/, '_reversa.sql'));
    }
  });

  it('no construye crédito (D-C1 espera a Martin) y no toca las funciones de cartera que la Fase 2 dejó INVOKER', () => {
    for (const m of MIG) {
      const sql = sinComentarios(leer(m));
      expect(sql, m).not.toMatch(/cliente_tiene_cxc_vencidas|cxc_vencidas_resumen/);
      expect(sql, m).not.toMatch(/tipo_pago|limite_credito|dias_credito|INSERT INTO public\.cuentas_por_cobrar/i);
    }
  });

  it('el interruptor global: arranca encendido, solo Dirección o super admin lo cambian, y un trigger protege la fila', () => {
    const sql = sinComentarios(leer(MIG[0]));
    expect(sql).toMatch(/'modo_prueba_global', 'true'::jsonb/);
    expect(sql).toMatch(/es_area\(auth\.uid\(\), 'direccion'::public\.user_area\)/);
    expect(sql).toMatch(/es_super_admin\(auth\.uid\(\)\)/);
    expect(sql).toMatch(/CREATE TRIGGER trg_proteger_modo_prueba_global[\s\S]*BEFORE INSERT OR UPDATE OR DELETE ON public\.compras_parametros/);
    expect(sql).toMatch(/REVOKE ALL ON FUNCTION public\.proteger_modo_prueba_global\(\) FROM PUBLIC, anon, authenticated;/);
    // si la fila no existe, el interruptor se interpreta como APAGADO
    expect(sql).toMatch(/SELECT coalesce\(\(SELECT valor = 'true'::jsonb[\s\S]*, false\)/);
  });

  it('eliminar_remision: super admin, modo prueba, folio, motivo; rechaza pago, cuenta por cobrar, factura, entrega e inventario surtido', () => {
    const sql = sinComentarios(leer(MIG[1]));
    expect(sql).toMatch(/SECURITY DEFINER SET search_path = public/);
    expect(sql).toMatch(/NOT public\.es_super_admin\(auth\.uid\(\)\)/);
    expect(sql).toMatch(/NOT public\.modo_prueba_global_activo\(\)/);
    expect(sql).toMatch(/_folio_confirmacion/);
    expect(sql).toMatch(/char_length\(trim\(_motivo\)\) < 10/);
    for (const frag of ['pago registrado', 'cuenta por cobrar', 'factura', 'entrega confirmada', 'surtió inventario']) expect(sql).toContain(frag);
    // copia completa antes de borrar, y comprobación de huérfanos contra TODAS las llaves foráneas
    expect(sql.indexOf('INSERT INTO public.bitacora_eliminaciones')).toBeLessThan(sql.indexOf('DELETE FROM public.remisiones WHERE'));
    expect(sql).toMatch(/c\.contype = 'f' AND c\.confrelid = v_tabla/);
    // libera las unidades igual que desasignar_motocarro_de_remision
    expect(sql).toMatch(/SET remision_id = NULL, estatus_entrega = 'NO_APLICA'/);
  });

  it('se cierran los dos DELETE directos y la reversa los restituye tal como estaban', () => {
    const sql = sinComentarios(leer(MIG[1])), rev = sinComentarios(leerRev(MIG[1]));
    expect(sql).toMatch(/DROP POLICY IF EXISTS "borrar remisiones admin" ON public\.remisiones;/);
    expect(sql).toMatch(/DROP POLICY IF EXISTS "admin de area borra remisiones" ON public\.remisiones;/);
    expect(sql).toMatch(/REVOKE DELETE ON TABLE public\.remisiones FROM authenticated;/);
    expect(rev).toMatch(/CREATE POLICY "borrar remisiones admin" ON public\.remisiones FOR DELETE TO authenticated\s+USING \(has_role\(auth\.uid\(\), 'admin'::app_role\)\);/);
    expect(rev).toMatch(/CREATE POLICY "admin de area borra remisiones" ON public\.remisiones FOR DELETE TO authenticated\s+USING \(es_admin_area\(auth\.uid\(\), 'comercial'::user_area\)\);/);
    expect(rev).toMatch(/GRANT DELETE ON TABLE public\.remisiones TO authenticated;/);
  });

  it('la fecha: solo Dirección y administrativos de Comercial, con motivo; no se mueve ningún vencimiento; la tabla nace cerrada', () => {
    const sql = sinComentarios(leer(MIG[2]));
    expect(sql).toMatch(/es_area\(auth\.uid\(\), 'direccion'::public\.user_area\) OR public\.es_administrativo_comercial\(auth\.uid\(\)\)/);
    expect(sql).toMatch(/char_length\(trim\(_motivo\)\) < 5/);
    expect(sql).toMatch(/almacen_refacciones_movimientos m WHERE m\.documento_id = _remision_id/);
    expect(sql).not.toMatch(/UPDATE public\.cuentas_por_cobrar|fecha_vencimiento\s*=/);
    expect(sql).toMatch(/ENABLE ROW LEVEL SECURITY/);
    expect(sql).toMatch(/REVOKE ALL ON TABLE public\.remision_fecha_cambios FROM PUBLIC, anon, authenticated;/);
    expect(sql).toMatch(/GRANT SELECT ON TABLE public\.remision_fecha_cambios TO authenticated;/);
    expect(sql).not.toMatch(/REFERENCES public\.remisiones/); // el historial sobrevive a una eliminación
    expect(sql).toMatch(/REVOKE ALL ON FUNCTION public\.remision_fecha_solo_por_funcion\(\) FROM PUBLIC, anon, authenticated;/);
  });

  it('todo nace cerrado: las funciones públicas sin EXECUTE para PUBLIC y anon, y con search_path fijo', () => {
    for (const m of MIG) {
      const sql = sinComentarios(leer(m));
      for (const f of sql.matchAll(/CREATE OR REPLACE FUNCTION public\.(\w+)\(([^)]*)\)[\s\S]*?\$\$;/g)) {
        const nombre = f[1];
        if (nombre === 'proteger_modo_prueba_global' || nombre === 'remision_fecha_solo_por_funcion') continue; // de trigger: revocadas a todos
        if (/SECURITY DEFINER/.test(f[0])) expect(f[0], nombre).toMatch(/SET search_path = public/);
        expect(sql, nombre).toMatch(new RegExp(`REVOKE ALL ON FUNCTION public\\.${nombre}\\([^)]*\\) FROM PUBLIC, anon;`));
      }
    }
  });
});

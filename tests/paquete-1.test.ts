import { describe, it, expect } from 'vitest';
import { readFileSync, readdirSync } from 'node:fs';

const MIG = readdirSync('supabase/migrations').filter((f) => f.startsWith('20261103')).sort();
const leer = (f: string) => readFileSync(`supabase/migrations/${f}`, 'utf8');
const sinComentarios = (s: string) => s.replace(/--.*$/gm, '');

describe('Paquete 1 — permisos del vendedor', () => {
  it('son 3 migraciones con versión única, anteriores a la Fase 2 (20261107…) y con su reversa', () => {
    expect(MIG).toHaveLength(3);
    const versiones = readdirSync('supabase/migrations').map((f) => f.split('_')[0]);
    for (const m of MIG) {
      const v = m.split('_')[0];
      expect(versiones.filter((x) => x === v)).toHaveLength(1);
      expect(Number(v)).toBeLessThan(20261107000001);
      expect(readdirSync('supabase/reversas')).toContain(m.replace(/\.sql$/, '_reversa.sql'));
    }
  });

  it('toda función nueva nace con sus permisos explícitos (nada para PUBLIC, anon ni authenticated)', () => {
    const sql = sinComentarios(leer(MIG[1]));
    const funciones = [...sql.matchAll(/CREATE OR REPLACE FUNCTION public\.(\w+)\(/g)].map((m) => m[1]);
    expect(funciones.sort()).toEqual(['clientes_asignar_vendedor_al_crear', 'crm_asignar_cliente_al_usar', 'crm_validar_cliente_visible', 'es_vendedor_comercial']);
    for (const f of funciones) expect(sql).toMatch(new RegExp(`REVOKE ALL ON FUNCTION public\\.${f}\\([^)]*\\) FROM PUBLIC, anon, authenticated`));
    expect(sql).not.toMatch(/GRANT EXECUTE[^;]*TO[^;]*\b(anon|authenticated|PUBLIC)\b/i);
  });

  it('todas las funciones nuevas fijan search_path; la que debe respetar RLS es INVOKER y las que escriben son DEFINER', () => {
    const sql = sinComentarios(leer(MIG[1]));
    for (const bloque of sql.split(/CREATE OR REPLACE FUNCTION /).slice(1)) expect(bloque.split('$$')[0]).toContain('SET search_path = public');
    expect(sql).toMatch(/crm_validar_cliente_visible\(\)\s+RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER/);
    expect(sql).toMatch(/crm_asignar_cliente_al_usar\(\)\s+RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER/);
  });

  it('no toca profiles, user_roles, super_admins, impedir_escalada_rol ni las funciones de cuentas por cobrar (lo que cambia la Fase 2)', () => {
    for (const m of MIG) {
      const sql = sinComentarios(leer(m));
      expect(sql).not.toMatch(/\b(ON|TABLE)\s+public\.(profiles|user_roles|super_admins)\b/i);
      expect(sql).not.toMatch(/impedir_escalada_rol|proteger_perfil_fase2|rastro_lista_super_admins|cliente_tiene_cxc_vencidas|cxc_vencidas_resumen/);
    }
  });

  it('la política «leer clientes» agrega solo los clientes sin vendedor y el resto es idéntico a la versión anterior', () => {
    const nueva = sinComentarios(leer(MIG[0]));
    const vieja = sinComentarios(readFileSync('supabase/reversas/' + MIG[0].replace(/\.sql$/, '_reversa.sql'), 'utf8'));
    const cuerpo = (s: string) => s.slice(s.indexOf('CREATE POLICY'), s.indexOf(';', s.indexOf('CREATE POLICY'))).replace(/\s+/g, ' ');
    expect(cuerpo(nueva).replace(' OR vendedor_id IS NULL', '')).toBe(cuerpo(vieja));
    expect(cuerpo(nueva)).toContain('OR vendedor_id IS NULL');
  });

  it('puede_leer_remision_refaccion: quita «comercial» de la lista final y conserva a los administrativos', () => {
    const nueva = sinComentarios(leer(MIG[2]));
    expect(nueva).toMatch(/RETURN _area IN \('direccion', 'administracion', 'almacen_logistica'\);/);
    expect(nueva).toContain('es_administrativo_comercial(_user_id)');
    const vieja = readFileSync('supabase/reversas/' + MIG[2].replace(/\.sql$/, '_reversa.sql'), 'utf8');
    expect(vieja).toContain("'almacen_logistica', 'comercial'");
  });

  it('el diagnóstico de esquema registra las tres migraciones', () => {
    const d = readFileSync('supabase/diagnostico_esquema.sql', 'utf8');
    for (const m of MIG) expect(d).toContain(`('${m.replace(/\.sql$/, '')}'`);
  });
});

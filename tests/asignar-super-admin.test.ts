import { describe, it, expect } from 'vitest';
import { readFileSync, readdirSync } from 'node:fs';

const MIG = '20261110000001_asignar_super_admin_solo_super_admin.sql';
const sinComentarios = (s: string) => s.replace(/--.*$/gm, '');
const mig = sinComentarios(readFileSync(`supabase/migrations/${MIG}`, 'utf8'));
const rev = sinComentarios(readFileSync(`supabase/reversas/${MIG.replace('.sql', '_reversa.sql')}`, 'utf8'));

describe('asignar_super_admin — opción B (solo un super admin), después de la Fase 2', () => {
  it('tiene versión única, posterior a la Fase 2 y a los Paquetes 2 y 3, y reversa', () => {
    const versiones = readdirSync('supabase/migrations').map((f) => f.split('_')[0]);
    expect(versiones.filter((v) => v === MIG.split('_')[0])).toHaveLength(1);
    expect(Number(MIG.split('_')[0])).toBeGreaterThan(20261109000003);
  });
  it('la puerta es «super admin» y ya no «administrador global que no es super admin»', () => {
    expect(mig).toMatch(/IF auth\.uid\(\) IS NULL OR NOT public\.es_super_admin\(auth\.uid\(\)\) THEN/);
    expect(mig).not.toMatch(/es_admin_global\(auth\.uid\(\)\)/);
    expect(rev).toMatch(/IF NOT public\.es_admin_global\(auth\.uid\(\)\) OR public\.es_super_admin\(auth\.uid\(\)\) THEN/);
  });
  it('conserva las reglas de siempre: nadie cambia su propio tipo, la asignación deja renglón y solo quita de super_admins', () => {
    expect(mig).toMatch(/_user_id = auth\.uid\(\)/);
    expect(mig).toMatch(/INSERT INTO public\.bitacora_super_admin/);
    expect(mig).toMatch(/DELETE FROM public\.super_admins WHERE user_id = _user_id/);
    expect(mig).not.toMatch(/DELETE FROM public\.(user_roles|profiles)/);
  });
  it('mismo nombre y firma; permisos sin cambio; DEFINER con search_path fijo', () => {
    expect(mig).toMatch(/CREATE OR REPLACE FUNCTION public\.asignar_super_admin\(_user_id uuid, _activo boolean\)/);
    expect(mig).toMatch(/SECURITY DEFINER SET search_path = public/);
    expect(mig).toMatch(/REVOKE ALL ON FUNCTION public\.asignar_super_admin\(uuid, boolean\) FROM PUBLIC, anon;/);
    expect(mig).toMatch(/GRANT EXECUTE ON FUNCTION public\.asignar_super_admin\(uuid, boolean\) TO authenticated;/);
    expect(mig).not.toMatch(/CREATE (TABLE|POLICY|TRIGGER)|ALTER TABLE|DROP /i);
  });
});

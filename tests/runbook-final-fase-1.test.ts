import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';

const leer = () => readFileSync('docs/seguridad/RUNBOOK-FINAL-FASE-1.md', 'utf8');
const doc = leer();

describe('RUNBOOK-FINAL-FASE-1.md', () => {
  it('los bloques SQL del SQL Editor son de solo lectura y van completos en el documento', () => {
    const bloques = [...doc.matchAll(/```sql\n([\s\S]*?)\n```/g)].map((m) => m[1]);
    const delEditor = bloques.filter((b) => !/\bedge_logs\b|\bpostgres_logs\b/.test(b));
    expect(delEditor.length).toBe(5); // 0, V, A1, A2, A3
    for (const b of delEditor) {
      expect(b.trimStart().startsWith('begin read only;')).toBe(true);
      expect(b.trimEnd().endsWith('rollback;')).toBe(true);
    }
  });

  it('aplica en el orden 1, 2, 4, 5, 6 y por último 3, y revierte en el inverso 3, 6, 5, 4, 2, 1, cada uno en una transacción', () => {
    const cmds = [...doc.matchAll(/```bash\n(psql [\s\S]*?)\n```/g)].map((m) => m[1]);
    expect(cmds.length).toBe(12);
    for (const c of cmds) {
      expect(c).toContain('--single-transaction');
      expect(c).toContain('ON_ERROR_STOP=1');
      expect(c).toContain('migraciones_aplicadas');
      expect(c).not.toMatch(/PGPASSWORD|password/i);
    }
    const num = (c: string) => c.match(/2026103100000(\d)_/)![1];
    expect(cmds.slice(0, 6).map(num)).toEqual(['1', '2', '4', '5', '6', '3']);
    expect(cmds.slice(6).map(num)).toEqual(['3', '6', '5', '4', '2', '1']);
    expect(cmds.slice(0, 6).every((c) => c.includes('/migrations/') && c.includes("'aplicado'"))).toBe(true);
    expect(cmds.slice(6).every((c) => c.includes('/reversas/') && c.includes("'superado'"))).toBe(true);
  });

  it('no contiene secretos y declara que Claude no usa el conector de Supabase', () => {
    expect(doc).toContain('Claude no usa el conector de Supabase de claude.ai para nada, ni para leer');
    expect(doc).not.toMatch(/eyJ[A-Za-z0-9_-]{20,}|sbp_[A-Za-z0-9]{20,}|@kawiil\.mx/);
  });

  it('está al día con las consultas', () => {
    execFileSync('python3', ['scripts/ventana/generar-runbook-final.py']);
    expect(leer()).toBe(doc);
  });
});

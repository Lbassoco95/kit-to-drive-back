import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';

const doc = readFileSync('docs/seguridad/SQL-PARA-POLO.md', 'utf8');
const bloques = [...doc.matchAll(/```sql\n([\s\S]*?)\n```/g)].map((m) => m[1]);

describe('SQL-PARA-POLO.md', () => {
  it('cada bloque para el SQL Editor va en begin read only … rollback', () => {
    const delEditor = bloques.filter((b) => !/\bedge_logs\b|\bpostgres_logs\b/.test(b));
    expect(delEditor.length).toBeGreaterThanOrEqual(9);
    for (const b of delEditor) {
      expect(b.trimStart().startsWith('begin read only;')).toBe(true);
      expect(b.trimEnd().endsWith('rollback;')).toBe(true);
    }
  });

  it('no trae sentencias que escriban ni devuelve el texto de las migraciones', () => {
    const sql = bloques.join('\n').replace(/--.*$/gm, '');
    expect(sql).not.toMatch(/\b(insert\s+into|delete\s+from|drop\s|create\s|alter\s+(table|function)|truncate\s+\w|grant\s+\w+\s+on|revoke\s+\w+\s+on)/i);
    expect(sql).not.toMatch(/\bupdate\s+\w+\s+set\b/i);
    const sinUsoPermitido = sql.replace(/array_(length|to_string)\(s\.statements[^)]*\)/g, '');
    expect(sinUsoPermitido).not.toMatch(/statements/);
  });

  it('está al día con las consultas de docs/seguridad/consultas', () => {
    const antes = doc;
    execFileSync('python3', ['scripts/ventana/generar-sql-para-polo.py']);
    expect(readFileSync('docs/seguridad/SQL-PARA-POLO.md', 'utf8')).toBe(antes);
  });
});

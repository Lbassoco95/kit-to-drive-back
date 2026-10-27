import { describe, it, expect } from 'vitest';
import { readFileSync, readdirSync } from 'node:fs';

const MIG = readdirSync('supabase/migrations').filter((f) => f.startsWith('20261103')).sort();
const leer = (f: string) => readFileSync(`supabase/migrations/${f}`, 'utf8');
const sinComentarios = (s: string) => s.replace(/--.*$/gm, '');
const BASICAS = ['id', 'codigo_erp', 'folio_interno', 'nombre_comercial', 'activo'];
// Columnas de `clientes` que NO son básicas: crédito, fiscal, contacto, domicilio, documentos, notas, coordenadas, vendedor.
const SENSIBLES = ['limite_credito', 'dias_credito', 'moneda_credito', 'rfc', 'razon_social', 'email', 'email_cobranza', 'nombre_contacto',
  'cargo_contacto', 'telefono_contacto', 'telefono', 'direccion', 'calle', 'num_exterior', 'num_interior', 'colonia', 'municipio', 'estado',
  'codigo_postal', 'pais', 'latitud', 'longitud', 'notas', 'vendedor_id', 'doc_constancia_sf_url', 'doc_comprobante_domicilio_url',
  'doc_ine_representante_url', 'doc_acta_constitutiva_url', 'doc_poder_notarial_url'];

describe('Paquete 1 — permisos del vendedor (catálogo básico)', () => {
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

  it('el catálogo devuelve SOLO las 5 columnas básicas (sin teléfono), sin parámetros, y ninguna sensible', () => {
    const sql = sinComentarios(leer(MIG[0]));
    const firma = sql.match(/CREATE OR REPLACE FUNCTION public\.catalogo_clientes_basico\(\)\s+RETURNS TABLE \(([\s\S]*?)\)\s+LANGUAGE/)!;
    expect(firma).toBeTruthy();
    const columnas = firma[1].split(',').map((c) => c.trim().split(/\s+/)[0]);
    expect(columnas).toEqual(BASICAS);
    const select = sql.match(/SELECT c\.id[\s\S]*?FROM public\.clientes c/)![0];
    for (const s of SENSIBLES) expect(select, s).not.toMatch(new RegExp(`\\bc\\.${s}\\b`));
    expect(select).not.toContain('*');
  });

  it('el catálogo es DEFINER con search_path fijo, solo para Comercial, respeta el modo prueba y no lo ejecuta anon', () => {
    const sql = sinComentarios(leer(MIG[0]));
    expect(sql).toMatch(/SECURITY DEFINER SET search_path = public/);
    expect(sql).toMatch(/rol_comercial\(auth\.uid\(\)\) IN \('global', 'supervisor', 'operador'\)/);
    expect(sql).toMatch(/es_area\(auth\.uid\(\), 'direccion'::public\.user_area\)/);
    expect(sql).toContain('es_usuario_prueba(auth.uid())');
    expect(sql).toMatch(/REVOKE ALL ON FUNCTION public\.catalogo_clientes_basico\(\) FROM PUBLIC, anon;/);
    expect(sql).toMatch(/GRANT EXECUTE ON FUNCTION public\.catalogo_clientes_basico\(\) TO authenticated, service_role;/);
    expect(sql).not.toMatch(/GRANT[^;]*\b(anon|PUBLIC)\b/);
  });

  it('no abre la ficha: ninguna migración toca políticas de clientes, de cartera ni asigna clientes al usarlos', () => {
    for (const m of MIG) {
      const sql = sinComentarios(leer(m));
      expect(sql, m).not.toMatch(/CREATE POLICY|DROP POLICY|ALTER POLICY/i);
      expect(sql, m).not.toMatch(/UPDATE public\.clientes/i);
      expect(sql, m).not.toMatch(/crm_asignar_cliente_al_usar|crm_validar_cliente_visible/);
    }
  });

  it('el trigger de alta solo toca clientes NUEVOS de un vendedor y nada necesita EXECUTE', () => {
    const sql = sinComentarios(leer(MIG[1]));
    expect(sql).toMatch(/BEFORE INSERT ON public\.clientes/);
    expect(sql).not.toMatch(/crm_oportunidades|crm_actividades|crm_ruta_paradas/);
    for (const f of ['es_vendedor_comercial\\(uuid\\)', 'clientes_asignar_vendedor_al_crear\\(\\)', 'remisiones_validar_cliente_visible\\(\\)'])
      expect(sql).toMatch(new RegExp(`REVOKE ALL ON FUNCTION public\\.${f} FROM PUBLIC, anon, authenticated`));
    expect(sql).not.toMatch(/GRANT EXECUTE[^;]*TO[^;]*\b(anon|authenticated|PUBLIC)\b/i);
    for (const bloque of sql.split(/CREATE OR REPLACE FUNCTION /).slice(1)) expect(bloque.split('$$')[0]).toContain('SET search_path = public');
  });

  it('la remisión solo se captura a un cliente que el vendedor ya ve: INVOKER (aplica la política de clientes) y solo para vendedores', () => {
    const sql = sinComentarios(leer(MIG[1]));
    expect(sql).toMatch(/remisiones_validar_cliente_visible\(\)\s+RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER/);
    expect(sql).toMatch(/BEFORE INSERT OR UPDATE OF cliente_id ON public\.remisiones/);
    expect(sql).toContain("rol_comercial(auth.uid()) <> 'operador'");
    expect(sql).toContain('es_administrativo_comercial(auth.uid())');
  });

  it('no toca profiles, user_roles, super_admins, impedir_escalada_rol ni las funciones de cuentas por cobrar (lo que cambia la Fase 2)', () => {
    for (const m of MIG) {
      const sql = sinComentarios(leer(m));
      expect(sql).not.toMatch(/\b(ON|TABLE)\s+public\.(profiles|user_roles|super_admins)\b/i);
      expect(sql).not.toMatch(/impedir_escalada_rol|proteger_perfil_fase2|rastro_lista_super_admins|cliente_tiene_cxc_vencidas|cxc_vencidas_resumen/);
    }
  });

  it('puede_leer_remision_refaccion: quita «comercial» de la lista final y conserva a los administrativos', () => {
    const nueva = sinComentarios(leer(MIG[2]));
    expect(nueva).toMatch(/RETURN _area IN \('direccion', 'administracion', 'almacen_logistica'\);/);
    expect(nueva).toContain('es_administrativo_comercial(_user_id)');
    const vieja = readFileSync('supabase/reversas/' + MIG[2].replace(/\.sql$/, '_reversa.sql'), 'utf8');
    expect(vieja).toContain("'almacen_logistica', 'comercial'");
  });

  it('el diagnóstico de esquema registra las tres migraciones y el contrato trae las funciones nuevas', () => {
    const d = readFileSync('supabase/diagnostico_esquema.sql', 'utf8');
    for (const m of MIG) expect(d).toContain(`('${m.replace(/\.sql$/, '')}'`);
    const c = JSON.parse(readFileSync('contrato/funciones.json', 'utf8')).funciones as string[];
    for (const f of ['catalogo_clientes_basico', 'es_vendedor_comercial', 'clientes_asignar_vendedor_al_crear']) expect(c).toContain(f);
    expect(c).not.toContain('crm_asignar_cliente_al_usar');
  });
});

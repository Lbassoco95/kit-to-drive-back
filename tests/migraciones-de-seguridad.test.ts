import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const mig = (f: string) => readFileSync(join(process.cwd(), "supabase/migrations", f), "utf8");

describe("historial de conexiones (migración)", () => {
  const migration = mig("20260929000001_historial_conexiones.sql");

  it("registra con la sesión autenticada y no duplica", () => {
    expect(migration).toContain("auth.uid()");
    expect(migration).toContain("ON CONFLICT (usuario_id, sesion_id) DO NOTHING");
  });

  it("protege el historial para que solo Dirección pueda consultarlo", () => {
    expect(migration).toContain("public.es_area(auth.uid(), 'direccion'::public.user_area)");
    expect(migration).not.toMatch(/FOR SELECT TO authenticated\s+USING \(true\)/);
    expect(migration).toContain("REVOKE ALL ON FUNCTION public.registrar_conexion() FROM PUBLIC, anon");
  });
});

describe("vendedor solo ve su información (migración)", () => {
  const sql = mig("20261007000001_vendedor_solo_su_informacion.sql");

  it("ya no abre clientes/remisiones/items/cxc a todo el comercial", () => {
    expect(sql).not.toMatch(/remision_items_select[\s\S]{0,120}USING \(true\)/);
    expect(sql).not.toMatch(/cxc_select[\s\S]{0,120}USING \(true\)/);
    const rol = sql.split('"leer remisiones por rol"')[2]?.split(");")[0] ?? "";
    expect(rol).not.toContain("'ventas'");
    expect(sql).toContain("vendedor_id = auth.uid()");
    expect(sql).toContain("ve_todo_comercial");
  });
});

describe("cierre de seguridad (2026-10-09/10)", () => {
  it("ninguna función de public queda abierta a anon y las nuevas no nacen abiertas", () => {
    const s = mig("20261009000002_cerrar_puente_heredado_y_funciones_anon.sql");
    expect(s).toContain("REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon");
    expect(s).toContain("ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon");
  });

  it("el rol de Auth conserva permiso sobre el trigger que crea cuentas", () => {
    expect(mig("20261010000001_arreglo_permiso_trigger_auth.sql")).toContain(
      "GRANT EXECUTE ON FUNCTION public.handle_new_user() TO supabase_auth_admin",
    );
  });

  it("las altas autorizadas no son visibles para anon ni authenticated", () => {
    const s = mig("20261010000002_altas_autorizadas.sql");
    expect(s).toContain("ENABLE ROW LEVEL SECURITY");
    expect(s).toContain("REVOKE ALL ON public.altas_autorizadas FROM PUBLIC, anon, authenticated");
  });
});

describe("flujo de dinero en tres etapas (migración)", () => {
  const s = mig("20261012000001_flujo_dinero_tres_etapas.sql");

  it("las tablas no se escriben directo: todo pasa por RPC con RLS activa", () => {
    expect(s).toContain("ALTER TABLE public.flujo_dinero ENABLE ROW LEVEL SECURITY");
    expect(s).toContain("ALTER TABLE public.flujo_capacidades ENABLE ROW LEVEL SECURITY");
    expect(s).toContain("REVOKE ALL ON public.flujo_dinero FROM PUBLIC, anon, authenticated");
    expect(s).toContain("GRANT SELECT ON public.flujo_dinero TO authenticated");
    expect(s).not.toMatch(/GRANT (INSERT|UPDATE|DELETE)[^;]*flujo_dinero/);
  });

  it("hace cumplir la separación de funciones en la base", () => {
    expect(s).toContain("f.recibido_por = auth.uid()");
    expect(s).toContain("auth.uid() IN (f.recibido_por, f.caja_por)");
  });

  it("ninguna función del flujo queda abierta a anon", () => {
    const rpcs = [...s.matchAll(/CREATE OR REPLACE FUNCTION public\.(flujo_[a-z_]+)\(/g)].map(m => m[1])
      .filter(n => n !== "flujo_dinero_sin_borrar");
    expect(rpcs.length).toBeGreaterThanOrEqual(10);
    for (const n of rpcs) expect(s).toMatch(new RegExp(`REVOKE ALL ON FUNCTION public\\.${n}\\([^)]*\\) FROM PUBLIC, anon`));
  });

  it("un flujo de prueba no escribe en el libro mayor real", () => {
    expect(s).toContain("IF NOT f.es_prueba THEN");
  });
});

describe("subir documentos de remisiones (comercial)", () => {
  const s = mig("20261013000001_subir_docs_remisiones_comercial.sql");

  it("amplía la subida sin tocar las políticas existentes", () => {
    expect(s).toContain('create policy "subir docs remisiones comercial"');
    expect(s).toContain("for insert");
    expect(s).toContain("bucket_id = 'remisiones-docs'");
    expect(s).not.toMatch(/drop policy if exists "(subir docs remisiones admin\/ventas|compras supervisa docs remisiones subir)"/);
  });

  it("auxiliar y área comercial solo suben a remisiones propias", () => {
    expect(s).toContain("r.vendedor_id = auth.uid()");
    expect(s).toContain("(storage.foldername(name))[1]");
  });
});

describe("catálogo: compatibilidades, baja de artículo y borrar compra (migración)", () => {
  const sql = mig("20261014000001_catalogo_compat_baja_articulo_y_borrar_compra.sql");

  it("las tres funciones piden Compras o administrador y no están abiertas a anon", () => {
    for (const fn of ["definir_compatibilidades_articulo(uuid, uuid[])", "eliminar_articulo_refaccion(uuid)", "eliminar_compra_refacciones(uuid, text)"]) {
      expect(sql).toContain(`REVOKE ALL ON FUNCTION public.${fn} FROM PUBLIC, anon`);
    }
    expect(sql.match(/puede_compras_inventario\(auth\.uid\(\)\)/g)?.length).toBe(3);
  });

  it("un artículo con historial no se borra y una compra confirmada se revierte con salidas (el kárdex es inmutable)", () => {
    expect(sql).toContain("almacen_refacciones_movimientos WHERE producto_id = _id");
    expect(sql).toContain("'salida', 'cancelacion'");
    expect(sql).toContain("recepciones_refacciones WHERE compra_id = _id");
  });
});

describe("super admin: pedidos y finanzas en solo lectura (migración)", () => {
  const sql = mig("20261016000001_super_admin_solo_lectura.sql");

  it("la lista de Super admin no se lee ni se escribe desde la app", () => {
    expect(sql).toContain("ALTER TABLE public.usuarios_solo_lectura_pedidos_finanzas ENABLE ROW LEVEL SECURITY");
    expect(sql).toContain("REVOKE ALL ON public.usuarios_solo_lectura_pedidos_finanzas FROM PUBLIC, anon, authenticated");
    expect(sql).not.toMatch(/GRANT [^;]*ON public\.usuarios_solo_lectura_pedidos_finanzas/);
  });

  it("la consulta sólo responde por el usuario de la sesión y no está abierta a anon", () => {
    expect(sql).toContain("WHERE user_id = auth.uid()");
    expect(sql).toContain("REVOKE ALL ON FUNCTION public.es_solo_lectura_pedidos_finanzas() FROM PUBLIC, anon");
    expect(sql).toContain("REVOKE ALL ON FUNCTION public.bloquear_escritura_solo_lectura() FROM PUBLIC, anon");
  });

  it("bloquea altas, cambios y borrados en pedidos y finanzas, también vía RPC", () => {
    expect(sql).toContain("BEFORE INSERT OR UPDATE OR DELETE");
    expect(sql).toContain("pg_trigger_depth() = 1");
    for (const t of ["remisiones", "remision_items", "remisiones_refacciones", "remision_refaccion_items",
      "movimientos_financieros", "flujo_dinero", "cobranza_pagos", "cobranza_aplicaciones", "cxc_abonos"]) {
      expect(sql).toContain(`'${t}'`);
    }
  });
});

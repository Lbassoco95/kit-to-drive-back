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

describe("super admin con aprobaciones (migración)", () => {
  const sql = mig("20261016000001_super_admin_aprobaciones.sql");

  it("quién es Super admin no se lee ni se escribe desde la app", () => {
    expect(sql).toContain("REVOKE ALL ON public.super_admins FROM PUBLIC, anon, authenticated");
    expect(sql).not.toMatch(/GRANT [^;]*ON public\.super_admins /);
    expect(sql).toContain("REVOKE ALL ON public.solicitudes_aprobacion FROM PUBLIC, anon, authenticated");
    expect(sql).not.toMatch(/GRANT (INSERT|UPDATE|DELETE)[^;]*(solicitudes_aprobacion|bitacora_super_admin)/);
  });

  it("borrar, cancelar y revertir del Super admin se frenan y piden aprobación", () => {
    expect(sql).toContain("HINT = 'aprobacion_requerida'");
    expect(sql).toContain("^(eliminar|borrar|cancelar|revertir)_");
    expect(sql).toContain("v_nuevo->>'estatus' = 'CANCELADA'");
    expect(sql).toContain("AFTER INSERT OR UPDATE OR DELETE");
  });

  it("aprueba el admin del área, nunca el mismo Super admin", () => {
    expect(sql).toContain("public.es_admin_de_area(s.area, auth.uid())");
    expect(sql).toContain("OR s.solicitado_por = auth.uid()");
  });

  it("ninguna función nueva queda abierta a anon", () => {
    for (const f of ["es_super_admin(uuid)", "asignar_super_admin(uuid, boolean)", "super_admins_ids()",
      "solicitar_aprobacion(text, text, jsonb, text, text)", "resolver_solicitud_aprobacion(uuid, boolean, text)"]) {
      expect(sql).toContain(`REVOKE ALL ON FUNCTION public.${f} FROM PUBLIC, anon`);
    }
  });
});

describe("super admin entra a refacciones (migración)", () => {
  const sql = mig("20261016000002_super_admin_refacciones.sql");

  it("conserva la lista de acceso y suma solo al Super admin", () => {
    expect(sql).toContain("FROM public.almacen_refacciones_acceso a");
    expect(sql).toContain("OR public.es_super_admin(_user_id)");
    expect(sql).toContain("REVOKE ALL ON FUNCTION public.puede_ver_almacen_refacciones(UUID) FROM PUBLIC");
    expect(sql).not.toMatch(/GRANT [^;]*puede_ver_almacen_refacciones[^;]* TO anon/);
  });
});

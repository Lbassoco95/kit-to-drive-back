import { beforeEach, describe, expect, it, vi } from "vitest";
import { AppError } from "@/lib/errors/app-error";
import { resolveRequestId, withApiHandler } from "@/lib/http/handler";
import { ok, type ApiFailure } from "@/lib/http/response";

const request = (headers: Record<string, string> = {}) =>
  new Request("http://localhost/api/v1/prueba", { headers });

let logs: string[];

beforeEach(() => {
  logs = [];
  const capture = (line: string) => void logs.push(line);
  vi.spyOn(console, "log").mockImplementation(capture);
  vi.spyOn(console, "warn").mockImplementation(capture);
  vi.spyOn(console, "error").mockImplementation(capture);
});

describe("withApiHandler — éxito", () => {
  it("devuelve la respuesta del handler con x-request-id y no-store", async () => {
    const handler = withApiHandler(() => ok({ hola: "mundo" }));
    const res = await handler(request(), undefined);

    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ success: true, data: { hola: "mundo" } });
    expect(res.headers.get("x-request-id")).toMatch(/^[0-9a-f-]{36}$/);
    expect(res.headers.get("cache-control")).toBe("no-store");
  });

  it("respeta un Cache-Control que el handler haya puesto", async () => {
    const handler = withApiHandler(() => ok(1, { headers: { "cache-control": "public, max-age=60" } }));
    const res = await handler(request(), undefined);
    expect(res.headers.get("cache-control")).toBe("public, max-age=60");
  });

  it("entrega al handler el contexto de la ruta y el requestId", async () => {
    const spy = vi.fn(() => ok(null));
    const handler = withApiHandler<{ params: Promise<{ id: string }> }>(spy);
    const ctx = { params: Promise.resolve({ id: "x" }) };
    await handler(request({ "x-request-id": "req-12345678" }), ctx);

    expect(spy).toHaveBeenCalledWith(expect.any(Request), ctx, expect.objectContaining({ requestId: "req-12345678" }));
  });

  it("registra una línea por petición con status y duración", async () => {
    await withApiHandler(() => ok(null))(request(), undefined);
    const linea = JSON.parse(logs.at(-1)!);
    expect(linea).toMatchObject({ level: "info", msg: "request completed", status: 200, method: "GET", path: "/api/v1/prueba" });
    expect(typeof linea.durationMs).toBe("number");
  });
});

describe("withApiHandler — errores", () => {
  it("un AppError se convierte en su status y código, con el requestId", async () => {
    const handler = withApiHandler(() => {
      throw new AppError("NOT_FOUND", "Proveedor no encontrado");
    });
    const res = await handler(request({ "x-request-id": "req-abcdefgh" }), undefined);
    const body = (await res.json()) as ApiFailure;

    expect(res.status).toBe(404);
    expect(body).toEqual({
      success: false,
      error: { code: "NOT_FOUND", message: "Proveedor no encontrado", requestId: "req-abcdefgh" },
    });
    expect(res.headers.get("x-request-id")).toBe("req-abcdefgh");
  });

  it("incluye details sólo cuando el AppError los trae", async () => {
    const details = [{ campo: "rfc", problema: "formato inválido" }];
    const res = await withApiHandler(() => {
      throw new AppError("VALIDATION_ERROR", "Datos inválidos", { details });
    })(request(), undefined);
    const body = (await res.json()) as ApiFailure;

    expect(res.status).toBe(400);
    expect(body.error.details).toEqual(details);
  });

  it("un error inesperado responde 500 genérico y NO filtra su mensaje", async () => {
    const handler = withApiHandler(() => {
      throw new Error('relation "tabla_interna" does not exist (host db.interno)');
    });
    const res = await handler(request(), undefined);
    const texto = await res.text();
    const body = JSON.parse(texto) as ApiFailure;

    expect(res.status).toBe(500);
    expect(body.error.code).toBe("INTERNAL_ERROR");
    expect(body.error.message).toBe("Error interno del servidor");
    expect(texto).not.toContain("tabla_interna");
    // …pero el detalle sí queda en el log para diagnosticar.
    expect(logs.some((l) => l.includes("tabla_interna") && l.includes('"level":"error"'))).toBe(true);
  });

  it("también maneja valores lanzados que no son Error", async () => {
    const res = await withApiHandler(() => {
      throw "algo raro";
    })(request(), undefined);
    expect(res.status).toBe(500);
  });

  it("un rechazo asíncrono se maneja igual que uno síncrono", async () => {
    const res = await withApiHandler(async () => {
      throw new AppError("FORBIDDEN", "Sin permiso");
    })(request(), undefined);
    expect(res.status).toBe(403);
  });

  it("los 4xx se registran como warn y los 5xx como error", async () => {
    await withApiHandler(() => {
      throw new AppError("UNAUTHORIZED", "Sin sesión");
    })(request(), undefined);
    await withApiHandler(() => {
      throw new Error("boom");
    })(request(), undefined);

    const niveles = logs.map((l) => JSON.parse(l)).filter((l) => l.msg !== "request completed").map((l) => l.level);
    expect(niveles).toEqual(["warn", "error"]);
  });
});

describe("resolveRequestId", () => {
  it("reutiliza un id entrante válido", () => {
    expect(resolveRequestId("abc-123_XYZ.9")).toBe("abc-123_XYZ.9");
  });

  it.each([null, "", "corto", "tiene espacios dentro", "línea\nfalsa en el log", "x".repeat(129)])(
    "genera uno nuevo si el entrante es inválido: %j",
    (entrante) => {
      expect(resolveRequestId(entrante)).toMatch(/^[0-9a-f-]{36}$/);
    },
  );
});

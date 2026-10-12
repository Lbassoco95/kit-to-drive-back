import { describe, expect, it, vi } from "vitest";
import { logger, redact, REDACTED } from "@/lib/logger";

// Valores de prueba armados en tiempo de ejecución: no son credenciales reales.
const fakeJwt = ["eyJhbGciOiJIUzI1NiJ9", "eyJzdWIiOiIxMjMifQ", "firmaFalsa123"].join(".");

describe("redact", () => {
  it("oculta campos sensibles por nombre, a cualquier profundidad", () => {
    const out = redact({
      usuario: "ana",
      password: "x",
      headers: { Authorization: "y", "x-api-key": "z", accept: "json" },
      lista: [{ refresh_token: "a" }, { nombre: "b" }],
      config: { SUPABASE_SERVICE_ROLE_KEY: "k", contraseña: "c" },
    });

    expect(out).toEqual({
      usuario: "ana",
      password: REDACTED,
      headers: { Authorization: REDACTED, "x-api-key": REDACTED, accept: "json" },
      lista: [{ refresh_token: REDACTED }, { nombre: "b" }],
      config: { SUPABASE_SERVICE_ROLE_KEY: REDACTED, contraseña: REDACTED },
    });
  });

  it("oculta valores con forma de credencial aunque el campo sea inocente", () => {
    expect(redact({ nota: `Bearer ${fakeJwt}` })).toEqual({ nota: REDACTED });
    expect(redact({ nota: `token pegado: ${fakeJwt} fin` })).toEqual({ nota: `token pegado: ${REDACTED} fin` });
    expect(redact({ nota: "llave sb_secret_abc123XYZ" })).toEqual({ nota: `llave ${REDACTED}` });
  });

  it("serializa errores sin perder el mensaje y redacta lo que traigan", () => {
    const err = new Error(`falló con ${fakeJwt}`, { cause: { token: "t" } });
    const out = redact(err) as Record<string, unknown>;
    expect(out.name).toBe("Error");
    expect(out.message).toBe(`falló con ${REDACTED}`);
    expect(out.cause).toEqual({ token: REDACTED });
  });

  it("no se cicla con referencias circulares ni modifica el original", () => {
    const a: Record<string, unknown> = { password: "p" };
    a.self = a;
    expect(redact(a)).toEqual({ password: REDACTED, self: "[Circular]" });
    expect(a.password).toBe("p");
  });
});

describe("logger", () => {
  it("escribe JSON de una línea con nivel, hora, campos fijos y redacción aplicada", () => {
    const lines: string[] = [];
    vi.spyOn(console, "log").mockImplementation((l: string) => void lines.push(l));

    logger.child({ requestId: "r-1" }).info("hola", { password: "secreta", n: 1 });

    expect(lines).toHaveLength(1);
    const entry = JSON.parse(lines[0]);
    expect(entry).toMatchObject({ level: "info", msg: "hola", requestId: "r-1", service: "kit-to-drive-api", password: REDACTED, n: 1 });
    expect(new Date(entry.time).toString()).not.toBe("Invalid Date");
    expect(lines[0]).not.toContain("secreta");
  });
});

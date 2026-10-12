import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  extractBearerToken,
  INVALID_AUTHORIZATION,
  MAX_AUTHORIZATION_LENGTH,
  MISSING_AUTHORIZATION,
} from "@/lib/auth/bearer";
import { AppError } from "@/lib/errors/app-error";
import { withApiHandler } from "@/lib/http/handler";
import { ok, type ApiFailure } from "@/lib/http/response";

// Token ficticio con forma de JWT (no está firmado por nadie).
const TOKEN = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJmaWN0aWNpbyJ9.firma_ficticia-123";

function errorOf(header: string | null | undefined): AppError {
  try {
    extractBearerToken(header);
  } catch (error) {
    expect(error).toBeInstanceOf(AppError);
    return error as AppError;
  }
  throw new Error("se esperaba AppError");
}

describe("extractBearerToken — formato válido", () => {
  it("devuelve el token de «Bearer <token>»", () => {
    expect(extractBearerToken(`Bearer ${TOKEN}`)).toBe(TOKEN);
  });

  it.each(["bearer", "BEARER", "bEaReR"])("acepta el esquema %s sin distinguir mayúsculas", (scheme) => {
    expect(extractBearerToken(`${scheme} ${TOKEN}`)).toBe(TOKEN);
  });

  it("tolera varios espacios entre esquema y token, y espacios en los extremos", () => {
    expect(extractBearerToken(`  Bearer   ${TOKEN}  `)).toBe(TOKEN);
  });

  it("acepta todos los caracteres de b64token, incluido el relleno «=»", () => {
    expect(extractBearerToken("Bearer aZ09-._~+/abc==")).toBe("aZ09-._~+/abc==");
  });

  it("acepta un encabezado justo en el límite de longitud", () => {
    const token = "a".repeat(MAX_AUTHORIZATION_LENGTH - "Bearer ".length);
    expect(extractBearerToken(`Bearer ${token}`)).toBe(token);
  });
});

describe("extractBearerToken — encabezado ausente o vacío", () => {
  it.each([
    ["null", null],
    ["undefined", undefined],
    ["cadena vacía", ""],
    ["sólo espacios", "   "],
  ])("rechaza %s como encabezado faltante", (_caso, header) => {
    const error = errorOf(header);
    expect(error.code).toBe("UNAUTHORIZED");
    expect(error.status).toBe(401);
    expect(error.message).toBe(MISSING_AUTHORIZATION);
  });
});

describe("extractBearerToken — formato inválido", () => {
  it.each([
    ["esquema sin token", "Bearer"],
    ["esquema con espacios y sin token", "Bearer    "],
    ["token sin esquema", TOKEN],
    ["otro esquema (Basic)", "Basic dXN1YXJpbzpjbGF2ZQ=="],
    ["otro esquema (Token)", `Token ${TOKEN}`],
    ["esquema pegado al token", `Bearer${TOKEN}`],
    ["esquema parecido", `Bearers ${TOKEN}`],
    ["dos tokens separados por espacio", `Bearer ${TOKEN} otro`],
    ["dos tokens separados por coma", `Bearer ${TOKEN},otro`],
    ["dos credenciales Bearer", `Bearer ${TOKEN}, Bearer otro`],
    ["tabulador en vez de espacio", `Bearer\t${TOKEN}`],
    ["salto de línea dentro", `Bearer ${TOKEN}\nX-Inyectado: 1`],
    ["caracteres fuera de b64token", "Bearer abc$def"],
    ["«=» en medio del token", "Bearer abc=def"],
    ["token entre comillas", `Bearer "${TOKEN}"`],
    ["encabezado demasiado largo", `Bearer ${"a".repeat(MAX_AUTHORIZATION_LENGTH)}`],
  ])("rechaza %s", (_caso, header) => {
    const error = errorOf(header);
    expect(error.code).toBe("UNAUTHORIZED");
    expect(error.status).toBe(401);
    expect(error.message).toBe(INVALID_AUTHORIZATION);
  });
});

describe("extractBearerToken — nunca expone el token", () => {
  it.each([
    ["dos tokens", `Bearer ${TOKEN} ${TOKEN}`],
    ["otro esquema", `Basic ${TOKEN}`],
    ["sin esquema", TOKEN],
  ])("el error por %s no contiene el token ni el encabezado", (_caso, header) => {
    const error = errorOf(header);
    expect(error.message).not.toContain(TOKEN);
    expect(error.cause).toBeUndefined();
    expect(error.details).toBeUndefined();
  });

  it("dentro de un Route Handler: 401 y ni la respuesta ni el log contienen el token", async () => {
    const logs: string[] = [];
    const capture = (line: string) => void logs.push(line);
    vi.spyOn(console, "log").mockImplementation(capture);
    vi.spyOn(console, "warn").mockImplementation(capture);
    vi.spyOn(console, "error").mockImplementation(capture);

    const handler = withApiHandler((request) => ok({ token: extractBearerToken(request.headers.get("authorization")) }));
    const res = await handler(
      new Request("http://localhost/api/v1/prueba", { headers: { authorization: `Basic ${TOKEN}` } }),
      undefined,
    );
    const body = (await res.json()) as ApiFailure;

    expect(res.status).toBe(401);
    expect(body.error).toMatchObject({ code: "UNAUTHORIZED", message: INVALID_AUTHORIZATION });
    expect(JSON.stringify(body)).not.toContain(TOKEN);
    expect(logs.join("\n")).toMatch(/request rejected/);
    expect(logs.join("\n")).not.toContain(TOKEN);
  });
});

describe("extractBearerToken — sin red", () => {
  let fetchMock: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    return () => vi.unstubAllGlobals();
  });

  it("no hace ninguna petición, ni con token válido ni inválido", () => {
    extractBearerToken(`Bearer ${TOKEN}`);
    errorOf("Basic algo");
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

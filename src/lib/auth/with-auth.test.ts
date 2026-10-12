import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { GET as healthGET } from "@/app/api/v1/health/route";
import { AUTH_UNAVAILABLE, INVALID_TOKEN, type AuthIdentity } from "@/lib/auth/verify";
import { BEARER_CHALLENGE, createWithAuth, type AuthApiContext } from "@/lib/auth/with-auth";
import { ConfigError } from "@/lib/config/env";
import { AppError } from "@/lib/errors/app-error";
import { ok, type ApiFailure, type ApiSuccess } from "@/lib/http/response";

// Tokens ficticios SIN forma de JWT: así el logger no los oculta por casualidad
// y las pruebas de filtración comprueban de verdad que nunca se escriben.
const TOKEN_A = "token-ficticio-A-0123456789abcdef";
const TOKEN_B = "token-ficticio-B-fedcba9876543210";
const USER_A: AuthIdentity = { id: "aaaaaaaa-0000-4000-8000-000000000001", sessionId: "aaaaaaaa-0000-4000-8000-0000000000a1" };
const USER_B: AuthIdentity = { id: "bbbbbbbb-0000-4000-8000-000000000002", sessionId: null };

let logs: string[];

beforeEach(() => {
  logs = [];
  const capture = (line: string) => void logs.push(line);
  vi.spyOn(console, "log").mockImplementation(capture);
  vi.spyOn(console, "warn").mockImplementation(capture);
  vi.spyOn(console, "error").mockImplementation(capture);
});

const request = (authorization?: string, path = "/api/v1/protegido") =>
  new Request(`http://localhost${path}`, authorization === undefined ? {} : { headers: { authorization } });

const unauthorized = (cause = "prueba") => new AppError("UNAUTHORIZED", INVALID_TOKEN, { cause });
const unavailable = () =>
  new AppError("SERVICE_UNAVAILABLE", AUTH_UNAVAILABLE, { cause: new Error("fetch failed") });

/** Cliente falso: no guarda el token, así no puede filtrarlo por accidente. */
const FAKE_CLIENT = { cliente: "falso-de-prueba" } as unknown as SupabaseClient;
const fakeUserClient = (): SupabaseClient => FAKE_CLIENT;

/** Handler protegido espía que devuelve la identidad que recibió. */
function setup(verifyImpl: (token: string) => Promise<AuthIdentity>) {
  const verify = vi.fn(verifyImpl);
  const createUserClient = vi.fn(fakeUserClient);
  const inner = vi.fn(async (_req: Request, _ctx: unknown, api: AuthApiContext) => ok({ identity: api.identity }));
  const route = createWithAuth(verify, createUserClient)(inner);
  return { verify, createUserClient, inner, call: (req: Request, ctx: unknown = undefined) => route(req, ctx) };
}

async function expectError(res: Response, status: 401 | 500 | 503, code: string) {
  const body = (await res.json()) as ApiFailure;
  expect(res.status).toBe(status);
  expect(body).toEqual({
    success: false,
    error: { code, message: expect.any(String), requestId: res.headers.get("x-request-id") },
  });
  expect(res.headers.get("x-request-id")).toMatch(/^[0-9a-f-]{36}$/);
  expect(res.headers.get("cache-control")).toBe("no-store");
  return body;
}

// ── Unitarias: verificador simulado ─────────────────────────────────────────

describe("withAuth — credenciales ausentes o mal formadas (401)", () => {
  it.each([
    ["sin Authorization", undefined],
    ["Authorization vacío", ""],
    ["esquema Basic", "Basic dXN1YXJpbzpjbGF2ZQ=="],
    ["Bearer sin token", "Bearer"],
    ["dos tokens", `Bearer ${TOKEN_A} ${TOKEN_B}`],
  ])("%s → 401 con WWW-Authenticate, sin verificar ni ejecutar el handler", async (_caso, authorization) => {
    const { verify, inner, call } = setup(async () => USER_A);
    const res = await call(request(authorization));

    await expectError(res, 401, "UNAUTHORIZED");
    expect(res.headers.get("www-authenticate")).toBe(BEARER_CHALLENGE);
    expect(verify).not.toHaveBeenCalled();
    expect(inner).not.toHaveBeenCalled();
  });
});

describe("withAuth — token rechazado por la verificación", () => {
  it.each([
    ["token inválido (firma)", "signature-or-exp"],
    ["token expirado", "exp"],
    ["emisor incorrecto", "iss"],
  ])("%s → 401 con WWW-Authenticate y el handler no se ejecuta", async (_caso, reason) => {
    const { verify, inner, call } = setup(async () => {
      throw unauthorized(reason);
    });
    const res = await call(request(`Bearer ${TOKEN_A}`));

    const body = await expectError(res, 401, "UNAUTHORIZED");
    expect(body.error.message).toBe(INVALID_TOKEN);
    expect(res.headers.get("www-authenticate")).toBe(BEARER_CHALLENGE);
    expect(verify).toHaveBeenCalledExactlyOnceWith(TOKEN_A);
    expect(inner).not.toHaveBeenCalled();
  });

  it("proveedor caído → 503 SIN WWW-Authenticate y el handler no se ejecuta", async () => {
    const { inner, call } = setup(async () => {
      throw unavailable();
    });
    const res = await call(request(`Bearer ${TOKEN_A}`));

    const body = await expectError(res, 503, "SERVICE_UNAVAILABLE");
    expect(body.error.message).toBe(AUTH_UNAVAILABLE);
    expect(res.headers.get("www-authenticate")).toBeNull();
    expect(inner).not.toHaveBeenCalled();
  });

  it("configuración ausente → 500 genérico como antes, sin WWW-Authenticate", async () => {
    const { inner, call } = setup(async () => {
      throw new ConfigError([{ variable: "SUPABASE_URL", problem: "falta o está vacía" }]);
    });
    const res = await call(request(`Bearer ${TOKEN_A}`));

    const body = await expectError(res, 500, "INTERNAL_ERROR");
    expect(body.error.message).toBe("Error interno del servidor");
    expect(JSON.stringify(body)).not.toContain("SUPABASE_URL");
    expect(res.headers.get("www-authenticate")).toBeNull();
    expect(inner).not.toHaveBeenCalled();
    expect(logs.join("\n")).toMatch(/unhandled error/);
  });
});

describe("withAuth — usuario autenticado", () => {
  it("ejecuta el handler una vez con la identidad tipada y responde normal", async () => {
    const { verify, inner, call } = setup(async () => USER_A);
    const res = await call(request(`bearer ${TOKEN_A}`));
    const body = (await res.json()) as ApiSuccess<{ identity: AuthIdentity }>;

    expect(res.status).toBe(200);
    expect(body).toEqual({ success: true, data: { identity: USER_A } });
    expect(res.headers.get("www-authenticate")).toBeNull();
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(verify).toHaveBeenCalledExactlyOnceWith(TOKEN_A);
    expect(inner).toHaveBeenCalledTimes(1);
  });

  it("conserva requestId, ctx (params de ruta) y añade userId al log del handler", async () => {
    let seen: { api?: AuthApiContext; ctx?: unknown } = {};
    const route = createWithAuth(async () => USER_A, fakeUserClient)(async (_req, ctx, api) => {
      seen = { api, ctx };
      api.log.info("dentro del handler");
      return ok({});
    });
    const ctx = { params: Promise.resolve({ id: "42" }) };
    const res = await route(
      new Request("http://localhost/x", { headers: { authorization: `Bearer ${TOKEN_A}`, "x-request-id": "req-prueba-123" } }),
      ctx,
    );

    expect(res.headers.get("x-request-id")).toBe("req-prueba-123");
    expect(seen.ctx).toBe(ctx);
    expect(seen.api?.requestId).toBe("req-prueba-123");
    expect(Object.keys(seen.api ?? {}).sort()).toEqual(["identity", "log", "requestId", "supabase"]);
    const line = JSON.parse(logs.find((l) => l.includes("dentro del handler")) ?? "{}");
    expect(line).toMatchObject({ requestId: "req-prueba-123", userId: USER_A.id });
  });

  it("no pasa el token ni el encabezado al handler", async () => {
    const { inner, call } = setup(async () => USER_A);
    await call(request(`Bearer ${TOKEN_A}`));
    const [, , api] = inner.mock.calls[0];
    expect(JSON.stringify(api.identity)).not.toContain(TOKEN_A);
    expect(Object.keys(api.identity).sort()).toEqual(["id", "sessionId"]);
  });
});

describe("withAuth — errores del handler protegido", () => {
  it("un 401 lanzado por el handler también lleva WWW-Authenticate", async () => {
    const route = createWithAuth(async () => USER_A, fakeUserClient)(async () => {
      throw new AppError("UNAUTHORIZED", "Sesión no válida para esta operación");
    });
    const res = await route(request(`Bearer ${TOKEN_A}`), undefined);
    await expectError(res, 401, "UNAUTHORIZED");
    expect(res.headers.get("www-authenticate")).toBe(BEARER_CHALLENGE);
  });

  it.each([
    ["403", new AppError("FORBIDDEN", "Sin permiso"), 403],
    ["404", new AppError("NOT_FOUND", "No existe"), 404],
    ["503", unavailable(), 503],
  ])("un %s del handler NO lleva WWW-Authenticate", async (_caso, error, status) => {
    const route = createWithAuth(async () => USER_A, fakeUserClient)(async () => {
      throw error;
    });
    const res = await route(request(`Bearer ${TOKEN_A}`), undefined);
    expect(res.status).toBe(status);
    expect(res.headers.get("www-authenticate")).toBeNull();
  });

  it("un error inesperado del handler sigue siendo 500 genérico", async () => {
    const route = createWithAuth(async () => USER_A, fakeUserClient)(async () => {
      throw new Error("bug interno con detalles");
    });
    const res = await route(request(`Bearer ${TOKEN_A}`), undefined);
    const body = await expectError(res, 500, "INTERNAL_ERROR");
    expect(JSON.stringify(body)).not.toContain("bug interno");
    expect(res.headers.get("www-authenticate")).toBeNull();
  });
});

describe("withAuth — identidad aislada por petición", () => {
  it("peticiones concurrentes reciben cada una su identidad aunque terminen en otro orden", async () => {
    const verify = async (token: string) => {
      // A tarda más que B: si hubiera estado compartido, A vería a B.
      await new Promise((resolve) => setTimeout(resolve, token === TOKEN_A ? 30 : 5));
      return token === TOKEN_A ? USER_A : USER_B;
    };
    const { inner, call } = setup(verify);

    const [resA, resB] = await Promise.all([call(request(`Bearer ${TOKEN_A}`)), call(request(`Bearer ${TOKEN_B}`))]);

    expect(((await resA.json()) as ApiSuccess<{ identity: AuthIdentity }>).data.identity).toEqual(USER_A);
    expect(((await resB.json()) as ApiSuccess<{ identity: AuthIdentity }>).data.identity).toEqual(USER_B);
    expect(inner).toHaveBeenCalledTimes(2);
  });

  it("una petición sin credenciales después de una autenticada no hereda la identidad", async () => {
    const { inner, call } = setup(async () => USER_A);
    expect((await call(request(`Bearer ${TOKEN_A}`))).status).toBe(200);
    expect((await call(request())).status).toBe(401);
    expect(inner).toHaveBeenCalledTimes(1);
  });

  it("muchas peticiones intercaladas: ninguna mezcla identidades", async () => {
    const users = Array.from({ length: 20 }, (_, i) => ({
      token: `token-ficticio-${i}-xxxxxxxx`,
      identity: { id: `00000000-0000-4000-8000-${String(i).padStart(12, "0")}`, sessionId: null },
    }));
    const byToken = new Map(users.map((u) => [u.token, u.identity]));
    const { call } = setup(async (token) => {
      await new Promise((resolve) => setTimeout(resolve, Math.random() * 10));
      return byToken.get(token)!;
    });

    const results = await Promise.all(users.map((u) => call(request(`Bearer ${u.token}`)).then((r) => r.json())));
    results.forEach((body, i) => expect((body as ApiSuccess<{ identity: AuthIdentity }>).data.identity).toEqual(users[i].identity));
  });
});

describe("withAuth — sin filtración de credenciales", () => {
  it.each([
    ["Bearer mal formado", `Bearer ${TOKEN_A} extra`, async () => USER_A],
    ["token inválido", `Bearer ${TOKEN_A}`, async () => { throw unauthorized(); }],
    ["proveedor caído", `Bearer ${TOKEN_A}`, async () => { throw unavailable(); }],
    ["éxito", `Bearer ${TOKEN_A}`, async () => USER_A],
  ] as const)("%s: ni respuesta, ni encabezados, ni logs contienen el token", async (_caso, authorization, impl) => {
    const { call } = setup(impl as (token: string) => Promise<AuthIdentity>);
    const res = await call(request(authorization));
    const headers = JSON.stringify([...res.headers.entries()]);
    const output = `${await res.text()}\n${headers}\n${logs.join("\n")}`;

    expect(output).not.toContain(TOKEN_A);
    expect(output).not.toContain(TOKEN_B);
    // El valor del encabezado nunca se escribe (el mensaje fijo sí puede nombrarlo).
    expect(output).not.toContain(authorization);
  });
});

describe("withAuth — cliente de Supabase por petición", () => {
  it("con token válido crea el cliente UNA vez con ese token y lo entrega al handler", async () => {
    const { createUserClient, inner, call } = setup(async () => USER_A);
    await call(request(`Bearer ${TOKEN_A}`));

    expect(createUserClient).toHaveBeenCalledExactlyOnceWith(TOKEN_A);
    const [, , api] = inner.mock.calls[0];
    expect(api.supabase).toBe(FAKE_CLIENT);
  });

  it("el handler no recibe el token en ningún argumento", async () => {
    const { inner, call } = setup(async () => USER_A);
    const req = request(`Bearer ${TOKEN_A}`);
    await call(req, { params: Promise.resolve({}) });

    const [, ctx, api] = inner.mock.calls[0];
    expect(Object.values(api)).not.toContain(TOKEN_A);
    expect(JSON.stringify({ identity: api.identity, requestId: api.requestId, ctx })).not.toContain(TOKEN_A);
    expect("token" in api || "accessToken" in api).toBe(false);
  });

  it.each([
    ["sin Authorization", undefined, async () => USER_A],
    ["Bearer mal formado", "Bearer", async () => USER_A],
    ["token inválido", `Bearer ${TOKEN_A}`, async () => { throw unauthorized(); }],
    ["proveedor caído", `Bearer ${TOKEN_A}`, async () => { throw unavailable(); }],
  ] as const)("%s: nunca se construye el cliente", async (_caso, authorization, impl) => {
    const { createUserClient, inner, call } = setup(impl as (token: string) => Promise<AuthIdentity>);
    await call(request(authorization));
    expect(createUserClient).not.toHaveBeenCalled();
    expect(inner).not.toHaveBeenCalled();
  });

  it("peticiones concurrentes: cada cliente se crea con el token de su propia petición", async () => {
    const created: string[] = [];
    const route = createWithAuth(
      async (token) => {
        await new Promise((resolve) => setTimeout(resolve, token === TOKEN_A ? 25 : 5));
        return token === TOKEN_A ? USER_A : USER_B;
      },
      (token) => {
        created.push(token);
        return { dueño: token === TOKEN_A ? USER_A.id : USER_B.id } as unknown as SupabaseClient;
      },
    )(async (_req, _ctx, { identity, supabase }) =>
      ok({ identity: identity.id, cliente: (supabase as unknown as { dueño: string }).dueño }),
    );

    const [a, b] = await Promise.all([
      route(request(`Bearer ${TOKEN_A}`), undefined).then((r) => r.json()),
      route(request(`Bearer ${TOKEN_B}`), undefined).then((r) => r.json()),
    ]);
    expect((a as ApiSuccess<object>).data).toEqual({ identity: USER_A.id, cliente: USER_A.id });
    expect((b as ApiSuccess<object>).data).toEqual({ identity: USER_B.id, cliente: USER_B.id });
    expect(created.sort()).toEqual([TOKEN_A, TOKEN_B].sort());
  });

  it("si construir el cliente falla: 500 genérico, sin handler y sin filtrar el token", async () => {
    const inner = vi.fn();
    const route = createWithAuth(async () => USER_A, (token) => {
      throw new TypeError(`fallo al construir el cliente (${token.length} caracteres)`);
    })(inner);
    const res = await route(request(`Bearer ${TOKEN_A}`), undefined);

    const body = await expectError(res, 500, "INTERNAL_ERROR");
    expect(JSON.stringify(body)).not.toContain(TOKEN_A);
    expect(res.headers.get("www-authenticate")).toBeNull();
    expect(inner).not.toHaveBeenCalled();
  });
});

// ── Integración: verifyAccessToken real + supabase-js + fetch simulado ──────

describe("withAuth — integración con verificación real (ES256 local, sin red)", () => {
  let privateKey: CryptoKey;
  let otherKey: CryptoKey;
  let publicJwk: JsonWebKey;
  let fetchMock: ReturnType<typeof vi.fn>;
  let jwksStatus: number;
  let projectSeq = 0;
  let supabaseUrl: string;

  const b64url = (v: object | Uint8Array) =>
    Buffer.from(v instanceof Uint8Array ? v : JSON.stringify(v)).toString("base64url");
  const now = () => Math.floor(Date.now() / 1000);

  async function sign(key: CryptoKey, claims: Record<string, unknown>) {
    const input = `${b64url({ alg: "ES256", typ: "JWT", kid: "k-integracion" })}.${b64url(claims)}`;
    const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(input));
    return `${input}.${b64url(new Uint8Array(sig))}`;
  }

  const claims = (overrides: Record<string, unknown> = {}) => ({
    iss: `${supabaseUrl}/auth/v1`,
    aud: "authenticated",
    role: "authenticated",
    sub: USER_A.id,
    session_id: USER_A.sessionId,
    exp: now() + 3600,
    ...overrides,
  });

  beforeAll(async () => {
    const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
    otherKey = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])).privateKey;
    privateKey = pair.privateKey;
    publicJwk = { ...(await crypto.subtle.exportKey("jwk", pair.publicKey)), kid: "k-integracion", alg: "ES256" } as JsonWebKey;
  });

  beforeEach(() => {
    // Proyecto ficticio distinto por prueba: auth-js cachea el JWKS por proyecto.
    supabaseUrl = `https://proyecto-ficticio-${++projectSeq}.supabase.co`;
    jwksStatus = 200;
    vi.stubEnv("SUPABASE_URL", supabaseUrl);
    vi.stubEnv("SUPABASE_PUBLISHABLE_KEY", "sb_publishable_ficticia_0123456789");
    fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = input instanceof Request ? input.url : String(input);
      if (url === `${supabaseUrl}/auth/v1/.well-known/jwks.json`) {
        return jwksStatus === 200 ? Response.json({ keys: [publicJwk] }) : new Response("down", { status: jwksStatus });
      }
      // PostgREST simulado: ninguna tabla real; sólo se inspeccionan encabezados.
      if (url.startsWith(`${supabaseUrl}/rest/v1/`)) return Response.json([]);
      throw new Error(`URL inesperada: ${url}`);
    });
    vi.stubGlobal("fetch", fetchMock);
  });

  /** Encabezados de las solicitudes simuladas a PostgREST. */
  const restCalls = () =>
    fetchMock.mock.calls
      .map(([input, init]) => ({
        url: input instanceof Request ? input.url : String(input),
        headers: new Headers((init as RequestInit | undefined)?.headers),
      }))
      .filter((c) => c.url.includes("/rest/v1/"));

  /** Handler que hace una solicitud simulada con el cliente recibido, marcada con su identidad. */
  async function queryingRoute() {
    const { withAuth } = await import("@/lib/auth/with-auth");
    return withAuth(async (_req, _ctx, { identity, supabase }) => {
      const { error } = await supabase.from("tabla_ficticia").select("id").eq("marca", identity.id);
      if (error) throw new Error("la solicitud simulada falló");
      return ok({ identity });
    });
  }

  const payloadOf = (jwt: string) => JSON.parse(Buffer.from(jwt.split(".")[1], "base64url").toString());

  it("el cliente del handler manda el JWT del usuario como Bearer y la clave publicable como apikey", async () => {
    const route = await queryingRoute();
    const token = await sign(privateKey, claims());
    const res = await route(request(`Bearer ${token}`), undefined);

    expect(res.status).toBe(200);
    const [call] = restCalls();
    expect(call.url).toContain("/rest/v1/tabla_ficticia");
    expect(call.headers.get("authorization")).toBe(`Bearer ${token}`);
    expect(call.headers.get("apikey")).toBe("sb_publishable_ficticia_0123456789");
  });

  it("dos usuarios concurrentes: cada solicitud lleva SU token, nunca el del otro", async () => {
    const route = await queryingRoute();
    const tokenA = await sign(privateKey, claims({ sub: USER_A.id }));
    const tokenB = await sign(privateKey, claims({ sub: USER_B.id, session_id: undefined }));

    const responses = await Promise.all([
      route(request(`Bearer ${tokenA}`), undefined),
      route(request(`Bearer ${tokenB}`), undefined),
      route(request(`Bearer ${tokenA}`), undefined),
      route(request(`Bearer ${tokenB}`), undefined),
    ]);
    expect(responses.map((r) => r.status)).toEqual([200, 200, 200, 200]);

    const calls = restCalls();
    expect(calls).toHaveLength(4);
    for (const call of calls) {
      const bearer = call.headers.get("authorization")!.replace(/^Bearer /, "");
      // La marca de la URL es la identidad del handler; el token debe ser del mismo usuario.
      expect(call.url).toContain(`marca=eq.${payloadOf(bearer).sub}`);
    }
  });

  it("el cliente del usuario no gestiona sesiones (supabase.auth está deshabilitado)", async () => {
    const { withAuth } = await import("@/lib/auth/with-auth");
    const route = withAuth(async (_req, _ctx, { supabase }) => {
      expect(() => supabase.auth.getSession()).toThrow(/accessToken option/);
      return ok({});
    });
    expect((await route(request(`Bearer ${await sign(privateKey, claims())}`), undefined)).status).toBe(200);
  });

  it("token inválido: el handler no corre y no hay ninguna solicitud a datos", async () => {
    const route = await queryingRoute();
    const res = await route(request(`Bearer ${await sign(otherKey, claims())}`), undefined);
    expect(res.status).toBe(401);
    expect(restCalls()).toHaveLength(0);
  });

  afterEach(() => {
    vi.unstubAllEnvs();
    vi.unstubAllGlobals();
    vi.resetModules();
  });

  /** Módulos frescos: la configuración y el verificador se crean en la primera petición. */
  async function protectedRoute() {
    const { withAuth } = await import("@/lib/auth/with-auth");
    return withAuth(async (_req, _ctx, { identity }) => ok({ identity }));
  }

  it("token ES256 válido → 200 con la identidad", async () => {
    const route = await protectedRoute();
    const res = await route(request(`Bearer ${await sign(privateKey, claims())}`), undefined);
    expect(res.status).toBe(200);
    expect(((await res.json()) as ApiSuccess<{ identity: AuthIdentity }>).data.identity).toEqual(USER_A);
  });

  it("token expirado → 401 con WWW-Authenticate y sin red", async () => {
    const route = await protectedRoute();
    const res = await route(request(`Bearer ${await sign(privateKey, claims({ exp: now() - 10 }))}`), undefined);
    await expectError(res, 401, "UNAUTHORIZED");
    expect(res.headers.get("www-authenticate")).toBe(BEARER_CHALLENGE);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("firma de otra clave → 401 con WWW-Authenticate", async () => {
    const route = await protectedRoute();
    const res = await route(request(`Bearer ${await sign(otherKey, claims())}`), undefined);
    await expectError(res, 401, "UNAUTHORIZED");
    expect(res.headers.get("www-authenticate")).toBe(BEARER_CHALLENGE);
  });

  it("emisor de otro proyecto → 401", async () => {
    const route = await protectedRoute();
    const token = await sign(privateKey, claims({ iss: "https://otro.supabase.co/auth/v1" }));
    expect((await route(request(`Bearer ${token}`), undefined)).status).toBe(401);
  });

  it("JWKS no disponible → 503 sin WWW-Authenticate", async () => {
    jwksStatus = 503;
    const route = await protectedRoute();
    const res = await route(request(`Bearer ${await sign(privateKey, claims())}`), undefined);
    await expectError(res, 503, "SERVICE_UNAVAILABLE");
    expect(res.headers.get("www-authenticate")).toBeNull();
  });

  it("sin variables de Supabase → 500 genérico, sin red ni WWW-Authenticate", async () => {
    vi.stubEnv("SUPABASE_URL", "");
    vi.stubEnv("SUPABASE_PUBLISHABLE_KEY", "");
    const route = await protectedRoute();
    const res = await route(request(`Bearer ${await sign(privateKey, claims())}`), undefined);
    await expectError(res, 500, "INTERNAL_ERROR");
    expect(res.headers.get("www-authenticate")).toBeNull();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("el JWT real tampoco aparece en respuesta ni logs (ni por partes)", async () => {
    const route = await protectedRoute();
    const token = await sign(otherKey, claims());
    const res = await route(request(`Bearer ${token}`), undefined);
    const output = `${await res.text()}\n${logs.join("\n")}`;
    for (const part of token.split(".")) expect(output).not.toContain(part);
  });
});

// ── /api/v1/health sigue siendo público ─────────────────────────────────────

describe("/api/v1/health sigue siendo público", () => {
  it.each([
    ["sin Authorization", undefined],
    ["con Authorization inválido (se ignora)", "Bearer basura"],
  ])("%s → 200 sin WWW-Authenticate ni llamadas de red", async (_caso, authorization) => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    try {
      const res = await healthGET(request(authorization, "/api/v1/health"), undefined);
      expect(res.status).toBe(200);
      expect(((await res.json()) as ApiSuccess<{ status: string }>).data.status).toBe("ok");
      expect(res.headers.get("www-authenticate")).toBeNull();
      expect(fetchMock).not.toHaveBeenCalled();
    } finally {
      vi.unstubAllGlobals();
    }
  });
});

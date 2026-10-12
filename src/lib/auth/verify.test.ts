import {
  AuthApiError,
  AuthInvalidJwtError,
  AuthRetryableFetchError,
  AuthSessionMissingError,
  AuthUnknownError,
  createClient,
} from "@supabase/supabase-js";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import {
  AUTH_UNAVAILABLE,
  createAccessTokenVerifier,
  INVALID_TOKEN,
  type AccessTokenVerifierDeps,
} from "@/lib/auth/verify";
import { AppError } from "@/lib/errors/app-error";
import { withApiHandler } from "@/lib/http/handler";
import { ok, type ApiFailure } from "@/lib/http/response";

// ── Datos ficticios ─────────────────────────────────────────────────────────
// Ningún valor corresponde a un proyecto real; las claves se generan aquí.
const SUPABASE_URL = "https://proyecto-ficticio.supabase.co";
const ISSUER = `${SUPABASE_URL}/auth/v1`;
const PUBLICABLE = "sb_publishable_ficticia_0123456789";
const USER_ID = "11111111-2222-4333-8444-555555555555";
const SESSION_ID = "66666666-7777-4888-9999-000000000000";
const KID = "clave-de-prueba-1";

const now = () => Math.floor(Date.now() / 1000);

const validClaims = (overrides: Record<string, unknown> = {}) => ({
  iss: ISSUER,
  aud: "authenticated",
  role: "authenticated",
  sub: USER_ID,
  session_id: SESSION_ID,
  iat: now() - 60,
  exp: now() + 3600,
  email: "persona@ejemplo.test",
  user_metadata: { nombre: "Persona" },
  app_metadata: { provider: "email" },
  is_anonymous: false,
  ...overrides,
});

const b64url = (value: object | Uint8Array) =>
  Buffer.from(value instanceof Uint8Array ? value : JSON.stringify(value)).toString("base64url");

/** JWT con firma de relleno: sólo sirve con `getClaims` simulado. */
const unsignedToken = (payload: object, header: object = { alg: "ES256", typ: "JWT", kid: KID }) =>
  `${b64url(header)}.${b64url(payload)}.${b64url(new TextEncoder().encode("firma-ficticia"))}`;

/** Firma ES256 real con WebCrypto (formato JWS: r||s). */
async function signEs256(privateKey: CryptoKey, payload: object, header: object = { alg: "ES256", typ: "JWT", kid: KID }) {
  const input = `${b64url(header)}.${b64url(payload)}`;
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, privateKey, new TextEncoder().encode(input));
  return `${input}.${b64url(new Uint8Array(sig))}`;
}

function expectAppError(error: unknown, code: "UNAUTHORIZED" | "SERVICE_UNAVAILABLE") {
  expect(error).toBeInstanceOf(AppError);
  const appError = error as AppError;
  expect(appError.code).toBe(code);
  expect(appError.status).toBe(code === "UNAUTHORIZED" ? 401 : 503);
  expect(appError.message).toBe(code === "UNAUTHORIZED" ? INVALID_TOKEN : AUTH_UNAVAILABLE);
  expect(appError.details).toBeUndefined();
  return appError;
}

async function rejectionOf(promise: Promise<unknown>): Promise<unknown> {
  try {
    await promise;
  } catch (error) {
    return error;
  }
  throw new Error("se esperaba un rechazo");
}

// ── 1. Reglas de validación con getClaims simulado ──────────────────────────

type GetClaims = AccessTokenVerifierDeps["auth"]["getClaims"];

function mockVerifier(result: unknown) {
  const getClaims = vi.fn(async () => result) as unknown as GetClaims & ReturnType<typeof vi.fn>;
  const verify = createAccessTokenVerifier({ auth: { getClaims }, issuer: ISSUER });
  return { verify, getClaims };
}

const claimsResult = (claims: object) => ({
  data: { claims, header: { alg: "ES256", kid: KID }, signature: new Uint8Array() },
  error: null,
});

describe("verificación — token válido", () => {
  it("devuelve sólo { id, sessionId } y pasa el token tal cual a getClaims", async () => {
    const claims = validClaims();
    const token = unsignedToken(claims);
    const { verify, getClaims } = mockVerifier(claimsResult(claims));

    const identity = await verify(token);

    expect(identity).toEqual({ id: USER_ID, sessionId: SESSION_ID });
    expect(Object.keys(identity).sort()).toEqual(["id", "sessionId"]);
    expect(getClaims).toHaveBeenCalledExactlyOnceWith(token);
  });

  it("acepta aud como arreglo que incluye authenticated", async () => {
    const claims = validClaims({ aud: ["otra", "authenticated"] });
    const { verify } = mockVerifier(claimsResult(claims));
    await expect(verify(unsignedToken(claims))).resolves.toMatchObject({ id: USER_ID });
  });

  it("sessionId es null si falta o no es UUID", async () => {
    for (const session_id of [undefined, "no-uuid", 123]) {
      const claims = validClaims({ session_id });
      const { verify } = mockVerifier(claimsResult(claims));
      await expect(verify(unsignedToken(claims))).resolves.toEqual({ id: USER_ID, sessionId: null });
    }
  });
});

describe("verificación — claims inválidos (firma ya verificada)", () => {
  it.each([
    ["expirado", { exp: now() - 1 }],
    ["sin exp", { exp: undefined }],
    ["exp no numérico", { exp: "9999999999" }],
    ["nbf en el futuro", { nbf: now() + 3600 }],
    ["emisor de otro proyecto", { iss: "https://otro-proyecto.supabase.co/auth/v1" }],
    ["emisor sin /auth/v1", { iss: SUPABASE_URL }],
    ["sin emisor", { iss: undefined }],
    ["audiencia distinta", { aud: "anon" }],
    ["audiencia en arreglo sin authenticated", { aud: ["anon"] }],
    ["sin audiencia", { aud: undefined }],
    ["rol anon", { role: "anon" }],
    ["rol service_role", { role: "service_role" }],
    ["sin rol", { role: undefined }],
    ["usuario anónimo", { is_anonymous: true }],
    ["sub ausente", { sub: undefined }],
    ["sub vacío", { sub: "" }],
    ["sub no UUID", { sub: "usuario-1" }],
    ["sub no string", { sub: 42 }],
  ])("rechaza %s con 401", async (_caso, overrides) => {
    const claims = validClaims(overrides);
    const { verify } = mockVerifier(claimsResult(claims));
    expectAppError(await rejectionOf(verify(unsignedToken(claims))), "UNAUTHORIZED");
  });

  it("tolera nbf con desfase de reloj pequeño", async () => {
    const claims = validClaims({ nbf: now() + 10 });
    const { verify } = mockVerifier(claimsResult(claims));
    await expect(verify(unsignedToken(claims))).resolves.toMatchObject({ id: USER_ID });
  });
});

describe("verificación — token mal formado (no llega a getClaims)", () => {
  it.each([
    ["vacío", ""],
    ["dos partes", "abc.def"],
    ["cuatro partes", "a.b.c.d"],
    ["caracteres fuera de base64url", "a+b.c/d.e="],
    ["cabecera que no es JSON", `${Buffer.from("no-json").toString("base64url")}.${b64url({})}.c2ln`],
    ["payload que no es objeto", `${b64url({ alg: "ES256" })}.${Buffer.from("123").toString("base64url")}.c2ln`],
    ["alg none", unsignedToken(validClaims(), { alg: "none" })],
    ["alg no admitido (PS256)", unsignedToken(validClaims(), { alg: "PS256", kid: KID })],
    ["sin alg", unsignedToken(validClaims(), { typ: "JWT" })],
  ])("rechaza %s con 401", async (_caso, token) => {
    const { verify, getClaims } = mockVerifier(claimsResult(validClaims()));
    expectAppError(await rejectionOf(verify(token)), "UNAUTHORIZED");
    expect(getClaims).not.toHaveBeenCalled();
  });
});

describe("verificación — errores de getClaims: token inválido vs. proveedor caído", () => {
  const token = unsignedToken(validClaims());

  it.each([
    ["firma inválida", new AuthInvalidJwtError("Invalid JWT signature")],
    ["expirado según getClaims", new AuthInvalidJwtError("JWT has expired")],
    ["Auth rechaza el token (401)", new AuthApiError("invalid JWT", 401, "bad_jwt")],
    ["Auth rechaza el token (403)", new AuthApiError("forbidden", 403, "bad_jwt")],
    ["usuario inexistente (404)", new AuthApiError("User not found", 404, "user_not_found")],
    ["sesión cerrada (session_not_found)", new AuthSessionMissingError()],
  ])("%s → 401", async (_caso, error) => {
    const { verify } = mockVerifier({ data: null, error });
    expectAppError(await rejectionOf(verify(token)), "UNAUTHORIZED");
  });

  it.each([
    ["fallo de red", new AuthRetryableFetchError("fetch failed", 0)],
    ["Auth responde 503", new AuthRetryableFetchError("Service Unavailable", 503)],
    ["límite de peticiones (429)", new AuthApiError("Too many requests", 429, "over_request_rate_limit")],
    ["error 500 como AuthApiError", new AuthApiError("boom", 500, undefined)],
    ["respuesta ilegible", new AuthUnknownError("Unexpected token <", new SyntaxError("x"))],
  ])("%s → 503 (no se culpa al token)", async (_caso, error) => {
    const { verify } = mockVerifier({ data: null, error });
    const appError = expectAppError(await rejectionOf(verify(token)), "SERVICE_UNAVAILABLE");
    expect(appError.cause).toBe(error);
  });

  it("una excepción inesperada dentro de getClaims → 503", async () => {
    const getClaims = vi.fn(async () => {
      throw new TypeError("crypto.subtle no disponible");
    }) as unknown as GetClaims;
    const verify = createAccessTokenVerifier({ auth: { getClaims }, issuer: ISSUER });
    expectAppError(await rejectionOf(verify(token)), "SERVICE_UNAVAILABLE");
  });

  it("respuesta sin claims ni error → 503", async () => {
    const { verify } = mockVerifier({ data: null, error: null });
    expectAppError(await rejectionOf(verify(token)), "SERVICE_UNAVAILABLE");
  });
});

// ── 2. Criptografía real: supabase-js + claves generadas aquí + fetch simulado ──

describe("verificación con getClaims real (ES256 y HS256), sin red", () => {
  let privateKey: CryptoKey;
  let otherPrivateKey: CryptoKey;
  let publicJwk: JsonWebKey & { kid: string; alg: string };
  let fetchMock: ReturnType<typeof vi.fn>;
  let userEndpoint: () => Promise<Response>;
  let jwksEndpoint: () => Promise<Response>;

  beforeAll(async () => {
    const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
    const other = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
    privateKey = pair.privateKey;
    otherPrivateKey = other.privateKey;
    publicJwk = { ...(await crypto.subtle.exportKey("jwk", pair.publicKey)), kid: KID, alg: "ES256" };
  });

  beforeEach(() => {
    jwksEndpoint = async () => Response.json({ keys: [publicJwk] });
    userEndpoint = async () => {
      throw new Error("no se esperaba llamar a /user");
    };
    fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = input instanceof Request ? input.url : String(input);
      if (url === `${ISSUER}/.well-known/jwks.json`) return jwksEndpoint();
      if (url === `${ISSUER}/user`) return userEndpoint();
      throw new Error(`URL inesperada en la prueba: ${url}`);
    });
  });

  // auth-js guarda el JWKS en una caché global del proceso (10 min) indexada por
  // `storageKey`: una clave distinta por cliente aísla cada prueba.
  let clientSeq = 0;

  /** Cliente real de supabase-js; su único `fetch` es el simulado. */
  const realVerifier = () =>
    createAccessTokenVerifier({
      auth: createClient(SUPABASE_URL, PUBLICABLE, {
        auth: {
          persistSession: false,
          autoRefreshToken: false,
          detectSessionInUrl: false,
          storageKey: `prueba-verify-${++clientSeq}`,
        },
        global: { fetch: fetchMock as unknown as typeof fetch },
      }).auth,
      issuer: ISSUER,
    });

  it("ES256 válido: verifica la firma localmente con el JWKS y no llama a /user", async () => {
    const token = await signEs256(privateKey, validClaims());
    await expect(realVerifier()(token)).resolves.toEqual({ id: USER_ID, sessionId: SESSION_ID });
    expect(fetchMock).toHaveBeenCalledTimes(1); // sólo el JWKS
  });

  it("reutiliza el JWKS cacheado en la segunda verificación", async () => {
    const verify = realVerifier();
    await verify(await signEs256(privateKey, validClaims()));
    await verify(await signEs256(privateKey, validClaims({ session_id: undefined })));
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("firma hecha con otra clave (mismo kid) → 401", async () => {
    const token = await signEs256(otherPrivateKey, validClaims());
    expectAppError(await rejectionOf(realVerifier()(token)), "UNAUTHORIZED");
  });

  it("payload alterado después de firmar → 401", async () => {
    const [header, , signature] = (await signEs256(privateKey, validClaims())).split(".");
    const forged = `${header}.${b64url(validClaims({ sub: "99999999-2222-4333-8444-555555555555" }))}.${signature}`;
    expectAppError(await rejectionOf(realVerifier()(forged)), "UNAUTHORIZED");
  });

  it("firma truncada → 401", async () => {
    const token = await signEs256(privateKey, validClaims());
    expectAppError(await rejectionOf(realVerifier()(token.slice(0, -10))), "UNAUTHORIZED");
  });

  it("expirado con firma válida → 401 sin consultar la red", async () => {
    const token = await signEs256(privateKey, validClaims({ exp: now() - 5 }));
    expectAppError(await rejectionOf(realVerifier()(token)), "UNAUTHORIZED");
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it.each([
    ["emisor incorrecto", { iss: "https://otro-proyecto.supabase.co/auth/v1" }],
    ["audiencia incorrecta", { aud: "anon" }],
    ["rol incorrecto", { role: "service_role" }],
    ["sub inválido", { sub: "no-es-uuid" }],
  ])("%s con firma válida → 401", async (_caso, overrides) => {
    const token = await signEs256(privateKey, validClaims(overrides));
    expectAppError(await rejectionOf(realVerifier()(token)), "UNAUTHORIZED");
  });

  it("JWKS caído (500) → 503", async () => {
    jwksEndpoint = async () => new Response("oops", { status: 500 });
    const token = await signEs256(privateKey, validClaims());
    expectAppError(await rejectionOf(realVerifier()(token)), "SERVICE_UNAVAILABLE");
  });

  it("kid desconocido: lo decide Auth (/user) y si lo rechaza → 401", async () => {
    userEndpoint = async () => Response.json({ error_code: "bad_jwt", msg: "invalid JWT" }, { status: 401 });
    const token = await signEs256(privateKey, validClaims(), { alg: "ES256", typ: "JWT", kid: "otra-clave" });
    expectAppError(await rejectionOf(realVerifier()(token)), "UNAUTHORIZED");
  });

  describe("HS256 (secreto del proyecto): la firma la verifica Auth vía /user", () => {
    const hsToken = (claims = validClaims()) => unsignedToken(claims, { alg: "HS256", typ: "JWT" });

    it("Auth acepta → identidad, y /user recibe el token como Bearer", async () => {
      userEndpoint = async () => Response.json({ id: USER_ID, aud: "authenticated", role: "authenticated" });
      const token = hsToken();
      await expect(realVerifier()(token)).resolves.toEqual({ id: USER_ID, sessionId: SESSION_ID });

      const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
      expect(new Headers(init.headers).get("authorization")).toBe(`Bearer ${token}`);
    });

    it("Auth rechaza la firma (401) → 401", async () => {
      userEndpoint = async () => Response.json({ error_code: "bad_jwt", msg: "invalid JWT" }, { status: 401 });
      expectAppError(await rejectionOf(realVerifier()(hsToken())), "UNAUTHORIZED");
    });

    it("sesión cerrada (403 session_not_found) → 401", async () => {
      userEndpoint = async () => Response.json({ error_code: "session_not_found", msg: "x" }, { status: 403 });
      expectAppError(await rejectionOf(realVerifier()(hsToken())), "UNAUTHORIZED");
    });

    it("Auth acepta pero el emisor no es el configurado → 401", async () => {
      userEndpoint = async () => Response.json({ id: USER_ID });
      const token = hsToken(validClaims({ iss: "https://otro-proyecto.supabase.co/auth/v1" }));
      expectAppError(await rejectionOf(realVerifier()(token)), "UNAUTHORIZED");
    });

    it.each([
      ["red caída", async () => Promise.reject(new TypeError("fetch failed"))],
      ["Auth 503", async () => new Response("down", { status: 503 })],
      ["Auth 429", async () => Response.json({ error_code: "over_request_rate_limit", msg: "x" }, { status: 429 })],
    ])("%s → 503", async (_caso, endpoint) => {
      userEndpoint = endpoint as () => Promise<Response>;
      expectAppError(await rejectionOf(realVerifier()(hsToken())), "SERVICE_UNAVAILABLE");
    });
  });
});

// ── 3. Nunca expone el token ────────────────────────────────────────────────

describe("verificación — sin filtraciones", () => {
  const token = unsignedToken(validClaims());
  const scenarios = [
    ["401 por firma inválida", { data: null, error: new AuthInvalidJwtError("Invalid JWT signature") }],
    ["401 por claim", claimsResult(validClaims({ aud: "anon" }))],
    ["503 por red", { data: null, error: new AuthRetryableFetchError("fetch failed", 0) }],
  ] as const;

  it.each(scenarios)("%s: el error (mensaje, cause, details) no contiene el token", async (_caso, result) => {
    const { verify } = mockVerifier(result);
    const error = (await rejectionOf(verify(token))) as AppError;
    const cause = error.cause instanceof Error ? error.cause.message : String(error.cause);
    expect(`${error.message} ${cause} ${JSON.stringify(error.details ?? null)}`).not.toContain(token);
  });

  it.each(scenarios)("%s: ni la respuesta ni el log contienen el token ni sus partes", async (_caso, result) => {
    const logs: string[] = [];
    const capture = (line: string) => void logs.push(line);
    vi.spyOn(console, "log").mockImplementation(capture);
    vi.spyOn(console, "warn").mockImplementation(capture);
    vi.spyOn(console, "error").mockImplementation(capture);

    const { verify } = mockVerifier(result);
    const handler = withApiHandler(async () => ok(await verify(token)));
    const res = await handler(new Request("http://localhost/api/v1/prueba"), undefined);
    const body = (await res.json()) as ApiFailure;
    const output = `${JSON.stringify(body)}\n${logs.join("\n")}`;

    expect([401, 503]).toContain(res.status);
    for (const part of token.split(".")) expect(output).not.toContain(part);
    // Tampoco datos personales del payload.
    expect(output).not.toContain("persona@ejemplo.test");
  });
});

// ── 4. verifyAccessToken: perezoso y conectado a la configuración ───────────

describe("verifyAccessToken — configuración perezosa", () => {
  afterEach(() => {
    vi.unstubAllEnvs();
    vi.unstubAllGlobals();
    vi.resetModules();
  });

  const load = async () => (await import("@/lib/auth/verify")).verifyAccessToken;

  it("importar el módulo no exige variables de Supabase", async () => {
    vi.stubEnv("SUPABASE_URL", "");
    vi.stubEnv("SUPABASE_PUBLISHABLE_KEY", "");
    await expect(load()).resolves.toBeTypeOf("function");
  });

  it("sin configuración: rechaza con ConfigError (500), no con 401", async () => {
    vi.stubEnv("SUPABASE_URL", "");
    vi.stubEnv("SUPABASE_PUBLISHABLE_KEY", "");
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    const verifyAccessToken = await load();

    await expect(verifyAccessToken(unsignedToken(validClaims()))).rejects.toMatchObject({ name: "ConfigError" });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("con configuración ficticia: usa SUPABASE_URL para el emisor y para Auth", async () => {
    vi.stubEnv("SUPABASE_URL", SUPABASE_URL);
    vi.stubEnv("SUPABASE_PUBLISHABLE_KEY", PUBLICABLE);
    const fetchMock = vi.fn(async () => Response.json({ id: USER_ID }));
    vi.stubGlobal("fetch", fetchMock);
    const verifyAccessToken = await load();

    const token = unsignedToken(validClaims(), { alg: "HS256", typ: "JWT" });
    await expect(verifyAccessToken(token)).resolves.toEqual({ id: USER_ID, sessionId: SESSION_ID });
    expect(String((fetchMock.mock.calls[0] as unknown[])[0])).toBe(`${ISSUER}/user`);
  });
});

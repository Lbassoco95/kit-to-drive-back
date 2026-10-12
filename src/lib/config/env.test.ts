import { afterEach, describe, expect, it, vi } from "vitest";
import { ConfigError, parseServerEnv } from "@/lib/config/env";

// Valores ficticios: ninguno corresponde a un proyecto real.
const URL_FICTICIA = "https://proyecto-ficticio.supabase.co";
const PUBLICABLE = "sb_publishable_ficticia_0123456789";
const SECRETA = "sb_secret_ficticia_0123456789";

/** JWT sin firma válida, sólo con el payload que interesa. */
const jwt = (payload: object) =>
  [
    Buffer.from(JSON.stringify({ alg: "HS256", typ: "JWT" })).toString("base64url"),
    Buffer.from(JSON.stringify(payload)).toString("base64url"),
    "firma-ficticia",
  ].join(".");

const ANON_JWT = jwt({ iss: "supabase", role: "anon" });
const SERVICE_ROLE_JWT = jwt({ iss: "supabase", role: "service_role" });

function issuesOf(source: Record<string, string | undefined>) {
  try {
    parseServerEnv(source);
  } catch (error) {
    expect(error).toBeInstanceOf(ConfigError);
    return (error as ConfigError).issues;
  }
  throw new Error("se esperaba ConfigError");
}

function messageOf(source: Record<string, string | undefined>) {
  try {
    parseServerEnv(source);
  } catch (error) {
    return (error as Error).message;
  }
  throw new Error("se esperaba ConfigError");
}

describe("parseServerEnv — valores válidos", () => {
  it("acepta URL https y clave sb_publishable_", () => {
    expect(parseServerEnv({ SUPABASE_URL: URL_FICTICIA, SUPABASE_PUBLISHABLE_KEY: PUBLICABLE })).toEqual({
      supabaseUrl: URL_FICTICIA,
      supabasePublishableKey: PUBLICABLE,
    });
  });

  it("acepta la clave anon antigua (JWT con role anon)", () => {
    const env = parseServerEnv({ SUPABASE_URL: URL_FICTICIA, SUPABASE_PUBLISHABLE_KEY: ANON_JWT });
    expect(env.supabasePublishableKey).toBe(ANON_JWT);
  });

  it("normaliza la URL al origen y quita espacios", () => {
    const env = parseServerEnv({ SUPABASE_URL: ` ${URL_FICTICIA}/ `, SUPABASE_PUBLISHABLE_KEY: ` ${PUBLICABLE} ` });
    expect(env).toEqual({ supabaseUrl: URL_FICTICIA, supabasePublishableKey: PUBLICABLE });
  });

  it("acepta http sólo para Supabase local", () => {
    const env = parseServerEnv({ SUPABASE_URL: "http://127.0.0.1:54321", SUPABASE_PUBLISHABLE_KEY: PUBLICABLE });
    expect(env.supabaseUrl).toBe("http://127.0.0.1:54321");
  });
});

describe("parseServerEnv — variables faltantes", () => {
  it("reporta las dos cuando no hay ninguna", () => {
    expect(issuesOf({})).toEqual([
      { variable: "SUPABASE_URL", problem: "falta o está vacía" },
      { variable: "SUPABASE_PUBLISHABLE_KEY", problem: "falta o está vacía" },
    ]);
  });

  it("trata una variable de sólo espacios como vacía", () => {
    expect(issuesOf({ SUPABASE_URL: "   ", SUPABASE_PUBLISHABLE_KEY: PUBLICABLE })).toEqual([
      { variable: "SUPABASE_URL", problem: "falta o está vacía" },
    ]);
  });
});

describe("parseServerEnv — URL inválida", () => {
  it.each([
    ["no es URL", "proyecto-ficticio.supabase.co"],
    ["http remoto", "http://proyecto-ficticio.supabase.co"],
    ["con ruta", `${URL_FICTICIA}/rest/v1`],
    ["con parámetros", `${URL_FICTICIA}/?apikey=algo`],
    ["con credenciales", "https://usuario:clave@proyecto-ficticio.supabase.co"],
  ])("rechaza %s", (_caso, url) => {
    const issues = issuesOf({ SUPABASE_URL: url, SUPABASE_PUBLISHABLE_KEY: PUBLICABLE });
    expect(issues).toHaveLength(1);
    expect(issues[0].variable).toBe("SUPABASE_URL");
  });
});

describe("parseServerEnv — clave no publicable", () => {
  it("rechaza una clave sb_secret_", () => {
    expect(issuesOf({ SUPABASE_URL: URL_FICTICIA, SUPABASE_PUBLISHABLE_KEY: SECRETA })).toEqual([
      { variable: "SUPABASE_PUBLISHABLE_KEY", problem: "es una clave secreta; aquí va la publicable" },
    ]);
  });

  it("rechaza un JWT service_role", () => {
    expect(issuesOf({ SUPABASE_URL: URL_FICTICIA, SUPABASE_PUBLISHABLE_KEY: SERVICE_ROLE_JWT })).toEqual([
      { variable: "SUPABASE_PUBLISHABLE_KEY", problem: "es la clave service_role; aquí va la publicable" },
    ]);
  });

  it.each([
    ["texto cualquiera", "no-es-una-clave"],
    ["JWT sin role", jwt({ iss: "supabase" })],
    ["JWT con payload ilegible", "aaa.%%%.bbb"],
  ])("rechaza %s como formato no reconocido", (_caso, key) => {
    expect(issuesOf({ SUPABASE_URL: URL_FICTICIA, SUPABASE_PUBLISHABLE_KEY: key })[0].problem).toMatch(
      /formato no reconocido/,
    );
  });
});

describe("parseServerEnv — nunca expone valores", () => {
  it.each([
    ["clave secreta", { SUPABASE_URL: URL_FICTICIA, SUPABASE_PUBLISHABLE_KEY: SECRETA }, SECRETA],
    ["service_role", { SUPABASE_URL: URL_FICTICIA, SUPABASE_PUBLISHABLE_KEY: SERVICE_ROLE_JWT }, SERVICE_ROLE_JWT],
    ["URL con credenciales", { SUPABASE_URL: "https://u:clave-ficticia@x.supabase.co", SUPABASE_PUBLISHABLE_KEY: PUBLICABLE }, "clave-ficticia"],
  ])("el error por %s sólo nombra la variable", (_caso, source, valor) => {
    const message = messageOf(source);
    expect(message).toMatch(/SUPABASE_/);
    expect(message).not.toContain(valor);
  });
});

describe("getServerEnv — lectura perezosa de process.env", () => {
  afterEach(() => {
    vi.unstubAllEnvs();
    vi.resetModules();
  });

  const load = async () => (await import("@/lib/config/env")).getServerEnv;

  it("importar el módulo no valida nada aunque falten variables", async () => {
    vi.stubEnv("SUPABASE_URL", "");
    vi.stubEnv("SUPABASE_PUBLISHABLE_KEY", "");
    await expect(load()).resolves.toBeTypeOf("function");
  });

  it("falla de forma controlada en la primera llamada si faltan variables", async () => {
    vi.stubEnv("SUPABASE_URL", "");
    vi.stubEnv("SUPABASE_PUBLISHABLE_KEY", "");
    const getServerEnv = await load();
    expect(() => getServerEnv()).toThrow(/SUPABASE_URL.*SUPABASE_PUBLISHABLE_KEY/);
  });

  it("no guarda el fallo: al corregir la variable, la siguiente llamada funciona", async () => {
    vi.stubEnv("SUPABASE_URL", URL_FICTICIA);
    vi.stubEnv("SUPABASE_PUBLISHABLE_KEY", "");
    const getServerEnv = await load();
    expect(() => getServerEnv()).toThrow();

    vi.stubEnv("SUPABASE_PUBLISHABLE_KEY", PUBLICABLE);
    expect(getServerEnv().supabasePublishableKey).toBe(PUBLICABLE);
  });

  it("valida una sola vez y reutiliza el resultado", async () => {
    vi.stubEnv("SUPABASE_URL", URL_FICTICIA);
    vi.stubEnv("SUPABASE_PUBLISHABLE_KEY", PUBLICABLE);
    const getServerEnv = await load();
    expect(getServerEnv()).toBe(getServerEnv());
  });
});

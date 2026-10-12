import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { withApiHandler } from "@/lib/http/handler";
import { ok, type ApiFailure } from "@/lib/http/response";

// Valores ficticios: ninguno corresponde a un proyecto real.
const URL_FICTICIA = "https://proyecto-ficticio.supabase.co";
const PUBLICABLE = "sb_publishable_ficticia_0123456789";
const SECRETA = "sb_secret_ficticia_0123456789";

let fetchMock: ReturnType<typeof vi.fn>;
let logs: string[];

beforeEach(() => {
  // Cualquier intento de red falla la prueba en vez de salir a internet.
  fetchMock = vi.fn(() => Promise.reject(new Error("red bloqueada en pruebas")));
  vi.stubGlobal("fetch", fetchMock);

  logs = [];
  const capture = (line: string) => void logs.push(line);
  vi.spyOn(console, "log").mockImplementation(capture);
  vi.spyOn(console, "warn").mockImplementation(capture);
  vi.spyOn(console, "error").mockImplementation(capture);
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.unstubAllEnvs();
  vi.resetModules();
});

// Módulos frescos en cada prueba: `getServerEnv()` guarda su resultado.
const load = async () => (await import("@/lib/supabase/server")).createServerSupabaseClient;

describe("createServerSupabaseClient", () => {
  it("crea el cliente con valores ficticios sin hacer ninguna petición de red", async () => {
    vi.stubEnv("SUPABASE_URL", URL_FICTICIA);
    vi.stubEnv("SUPABASE_PUBLISHABLE_KEY", PUBLICABLE);
    const createServerSupabaseClient = await load();

    const client = createServerSupabaseClient();

    expect(typeof client.from).toBe("function");
    // Deja correr microtareas por si la librería programara algo al iniciar.
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("devuelve un cliente nuevo en cada llamada", async () => {
    vi.stubEnv("SUPABASE_URL", URL_FICTICIA);
    vi.stubEnv("SUPABASE_PUBLISHABLE_KEY", PUBLICABLE);
    const createServerSupabaseClient = await load();

    expect(createServerSupabaseClient()).not.toBe(createServerSupabaseClient());
  });

  it("lanza ConfigError si falta la configuración, sin tocar la red", async () => {
    vi.stubEnv("SUPABASE_URL", "");
    vi.stubEnv("SUPABASE_PUBLISHABLE_KEY", "");
    const createServerSupabaseClient = await load();

    expect(() => createServerSupabaseClient()).toThrow(expect.objectContaining({ name: "ConfigError" }));
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("rechaza una clave secreta antes de construir el cliente", async () => {
    vi.stubEnv("SUPABASE_URL", URL_FICTICIA);
    vi.stubEnv("SUPABASE_PUBLISHABLE_KEY", SECRETA);
    const createServerSupabaseClient = await load();

    expect(() => createServerSupabaseClient()).toThrow(/SUPABASE_PUBLISHABLE_KEY/);
  });
});

describe("ConfigError dentro de un Route Handler", () => {
  it("responde 500 genérico y ni la respuesta ni el log contienen la clave", async () => {
    vi.stubEnv("SUPABASE_URL", URL_FICTICIA);
    vi.stubEnv("SUPABASE_PUBLISHABLE_KEY", SECRETA);
    const createServerSupabaseClient = await load();

    const handler = withApiHandler(() => {
      createServerSupabaseClient();
      return ok({});
    });
    const res = await handler(new Request("http://localhost/api/v1/prueba"), undefined);
    const body = (await res.json()) as ApiFailure;

    expect(res.status).toBe(500);
    expect(body.error.code).toBe("INTERNAL_ERROR");
    expect(JSON.stringify(body)).not.toMatch(/SUPABASE_|sb_secret_/);
    expect(logs.join("\n")).toMatch(/SUPABASE_PUBLISHABLE_KEY/);
    expect(logs.join("\n")).not.toContain(SECRETA);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

// ── Cliente con la identidad del usuario ────────────────────────────────────

describe("createUserSupabaseClient", () => {
  // Tokens ficticios (no son JWT válidos de ningún proyecto).
  const TOKEN_A = "token-usuario-A-ficticio-0123456789";
  const TOKEN_B = "token-usuario-B-ficticio-9876543210";

  const loadUser = async () => (await import("@/lib/supabase/server")).createUserSupabaseClient;

  /** fetch simulado que responde vacío y deja ver URL y encabezados de cada solicitud. */
  function captureRequests() {
    fetchMock.mockImplementation(async () => Response.json([]));
    return () =>
      fetchMock.mock.calls.map(([input, init]) => ({
        url: input instanceof Request ? input.url : String(input),
        headers: new Headers((init as RequestInit | undefined)?.headers),
      }));
  }

  beforeEach(() => {
    vi.stubEnv("SUPABASE_URL", URL_FICTICIA);
    vi.stubEnv("SUPABASE_PUBLISHABLE_KEY", PUBLICABLE);
  });

  it("construirlo no hace solicitudes HTTP ni abre WebSocket", async () => {
    const webSocket = vi.fn();
    vi.stubGlobal("WebSocket", webSocket);
    const createUserSupabaseClient = await loadUser();

    createUserSupabaseClient(TOKEN_A);
    // supabase-js entrega el token a Realtime en una microtarea: se le deja correr.
    await new Promise((resolve) => setTimeout(resolve, 10));

    expect(fetchMock).not.toHaveBeenCalled();
    expect(webSocket).not.toHaveBeenCalled();
  });

  it("PostgREST: Authorization Bearer con el token del usuario y apikey publicable", async () => {
    const requests = captureRequests();
    const client = (await loadUser())(TOKEN_A);

    await client.from("tabla_ficticia").select("id");

    const [req] = requests();
    expect(req.url).toBe(`${URL_FICTICIA}/rest/v1/tabla_ficticia?select=id`);
    expect(req.headers.get("authorization")).toBe(`Bearer ${TOKEN_A}`);
    expect(req.headers.get("apikey")).toBe(PUBLICABLE);
  });

  it("RPC, Storage y Functions también llevan el token del usuario", async () => {
    const requests = captureRequests();
    const client = (await loadUser())(TOKEN_A);

    await client.rpc("funcion_ficticia");
    await client.storage.from("bucket-ficticio").list();
    await client.functions.invoke("funcion-ficticia", { body: {} });

    const calls = requests();
    expect(calls.map((c) => new URL(c.url).pathname)).toEqual([
      "/rest/v1/rpc/funcion_ficticia",
      "/storage/v1/object/list/bucket-ficticio",
      "/functions/v1/funcion-ficticia",
    ]);
    for (const c of calls) {
      expect(c.headers.get("authorization")).toBe(`Bearer ${TOKEN_A}`);
      expect(c.headers.get("apikey")).toBe(PUBLICABLE);
    }
  });

  it("dos clientes usados a la vez no comparten token", async () => {
    const requests = captureRequests();
    const createUserSupabaseClient = await loadUser();
    const clientA = createUserSupabaseClient(TOKEN_A);
    const clientB = createUserSupabaseClient(TOKEN_B);

    // Cada cliente usa rutas con su sufijo para saber de quién es cada solicitud.
    await Promise.all([
      clientA.from("tabla_a").select("id"),
      clientB.from("tabla_b").select("id"),
      clientA.rpc("funcion_a"),
      clientB.rpc("funcion_b"),
    ]);

    const calls = requests();
    expect(calls).toHaveLength(4);
    for (const c of calls) {
      const expected = new URL(c.url).pathname.endsWith("_a") ? TOKEN_A : TOKEN_B;
      expect(c.headers.get("authorization")).toBe(`Bearer ${expected}`);
    }
    expect(clientA).not.toBe(clientB);
  });

  it("no gestiona sesiones: supabase.auth está deshabilitado", async () => {
    const client = (await loadUser())(TOKEN_A);
    expect(() => client.auth.getSession()).toThrow(/accessToken option/);
    expect(() => client.auth.refreshSession()).toThrow(/accessToken option/);
  });

  it.each([
    ["vacío", ""],
    ["no texto", undefined as unknown as string],
  ])("token %s: no construye el cliente (para no caer en anon)", async (_caso, token) => {
    const createUserSupabaseClient = await loadUser();
    expect(() => createUserSupabaseClient(token)).toThrow(TypeError);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("sin configuración lanza ConfigError, y el mensaje no incluye el token", async () => {
    vi.stubEnv("SUPABASE_URL", "");
    const createUserSupabaseClient = await loadUser();
    let error: unknown;
    try {
      createUserSupabaseClient(TOKEN_A);
    } catch (e) {
      error = e;
    }
    expect(error).toMatchObject({ name: "ConfigError" });
    expect(String((error as Error).message)).not.toContain(TOKEN_A);
  });

  it("no usa service_role: sólo la clave publicable sale en las solicitudes", async () => {
    const requests = captureRequests();
    await (await loadUser())(TOKEN_A).from("t").select("id");
    const sent = JSON.stringify([...requests()[0].headers.entries()]);
    expect(sent).not.toMatch(/sb_secret_|service_role/);
    expect(sent).toContain(PUBLICABLE);
  });
});

/**
 * Variables de entorno del servidor, validadas.
 *
 * Sólo servidor: `server-only` rompe el build si un componente cliente lo
 * importa, y ninguna variable lleva `NEXT_PUBLIC_`, así que Next nunca las
 * incrusta en el bundle del navegador.
 *
 * La validación es perezosa: ocurre en la primera llamada a `getServerEnv()`,
 * no al importar el módulo. Así `next build` y `/api/v1/health` funcionan sin
 * `.env.local`; sólo falla el endpoint que de verdad necesita Supabase.
 *
 * Los errores nombran la variable y el problema, nunca su valor.
 */
import "server-only";

export type ServerEnv = {
  /** Origen del proyecto, p. ej. `https://<ref>.supabase.co` (sin barra final). */
  supabaseUrl: string;
  /**
   * Clave publicable (`sb_publishable_…` o la antigua `anon`). No autoriza nada
   * por sí sola: lo que se puede leer o escribir lo deciden la identidad de la
   * petición y las políticas RLS.
   */
  supabasePublishableKey: string;
};

export type EnvIssue = { variable: string; problem: string };

/** Configuración incompleta o inválida. No es un `AppError`: al cliente le llega un 500 genérico. */
export class ConfigError extends Error {
  readonly issues: readonly EnvIssue[];

  constructor(issues: EnvIssue[]) {
    super(`Configuración inválida: ${issues.map((i) => `${i.variable} (${i.problem})`).join("; ")}`);
    this.name = "ConfigError";
    this.issues = issues;
  }
}

type EnvSource = Record<string, string | undefined>;

// Con http sólo se acepta Supabase local (`supabase start`).
const LOCAL_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]"]);

function parseSupabaseUrl(raw: string): { value?: string; problem?: string } {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return { problem: "no es una URL válida" };
  }
  if (url.protocol !== "https:" && !(url.protocol === "http:" && LOCAL_HOSTS.has(url.hostname))) {
    return { problem: "debe usar https (http sólo en localhost)" };
  }
  if (url.username || url.password || url.search || url.hash || url.pathname !== "/") {
    return { problem: "debe ser sólo el origen del proyecto, sin ruta, parámetros ni credenciales" };
  }
  return { value: url.origin };
}

/** `role` del payload de un JWT, sin verificar la firma (sólo para clasificar la clave). */
function jwtRole(token: string): string | undefined {
  const parts = token.split(".");
  if (parts.length !== 3) return undefined;
  try {
    const payload: unknown = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
    if (payload && typeof payload === "object" && "role" in payload && typeof payload.role === "string") {
      return payload.role;
    }
  } catch {
    // Payload ilegible: se trata como clave no reconocida.
  }
  return undefined;
}

function checkPublishableKey(key: string): string | undefined {
  if (key.startsWith("sb_secret_")) return "es una clave secreta; aquí va la publicable";
  if (key.startsWith("sb_publishable_")) return undefined;
  const role = jwtRole(key);
  if (role === "anon") return undefined;
  if (role === "service_role") return "es la clave service_role; aquí va la publicable";
  return "formato no reconocido (se espera sb_publishable_… o la clave anon)";
}

/** Valida y normaliza. Pura: no lee `process.env` ni guarda nada (se prueba aislada). */
export function parseServerEnv(source: EnvSource): ServerEnv {
  const issues: EnvIssue[] = [];
  const read = (variable: string): string | undefined => {
    const value = source[variable]?.trim();
    if (!value) issues.push({ variable, problem: "falta o está vacía" });
    return value || undefined;
  };

  const rawUrl = read("SUPABASE_URL");
  const key = read("SUPABASE_PUBLISHABLE_KEY");

  let supabaseUrl: string | undefined;
  if (rawUrl) {
    const parsed = parseSupabaseUrl(rawUrl);
    if (parsed.problem) issues.push({ variable: "SUPABASE_URL", problem: parsed.problem });
    supabaseUrl = parsed.value;
  }
  if (key) {
    const problem = checkPublishableKey(key);
    if (problem) issues.push({ variable: "SUPABASE_PUBLISHABLE_KEY", problem });
  }

  if (issues.length > 0 || !supabaseUrl || !key) throw new ConfigError(issues);
  return { supabaseUrl, supabasePublishableKey: key };
}

let cached: ServerEnv | undefined;

/**
 * Entorno validado del proceso. Se valida en la primera llamada y se guarda;
 * un fallo no se guarda, para que corregir la variable baste sin reiniciar caché.
 */
export function getServerEnv(): ServerEnv {
  cached ??= parseServerEnv({
    SUPABASE_URL: process.env.SUPABASE_URL,
    SUPABASE_PUBLISHABLE_KEY: process.env.SUPABASE_PUBLISHABLE_KEY,
  });
  return cached;
}

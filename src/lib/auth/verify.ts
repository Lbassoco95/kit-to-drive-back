/**
 * Verificación del access token (JWT) de Supabase Auth.
 *
 * Firma y expiración las comprueba `auth.getClaims(token)`, el mecanismo
 * oficial de supabase-js:
 *   - ES256/RS256 con `kid`: verifica la firma localmente con la clave pública
 *     del JWKS del proyecto (`/auth/v1/.well-known/jwks.json`, cacheado en el
 *     cliente).
 *   - HS256 (secreto compartido) o `kid` desconocido: pregunta al servidor de
 *     Auth (`GET /auth/v1/user`), que es quien conoce el secreto.
 * `getClaims` NO revisa emisor, audiencia, rol ni `sub`: eso se hace aquí, y
 * sólo sobre los claims que devuelve ya verificados.
 *
 * Errores:
 *   - 401 UNAUTHORIZED: el token no sirve (mensaje fijo, sin detalles).
 *   - 503 SERVICE_UNAVAILABLE: Supabase Auth no respondió; el token puede ser
 *     bueno, así que no se le dice al cliente que inicie sesión de nuevo.
 *   - 500: configuración ausente o inválida (`ConfigError`).
 *
 * Limitación conocida: con verificación local, un token de una sesión ya
 * cerrada sigue siendo válido hasta su `exp` (igual que para PostgREST).
 */
import "server-only";
import {
  isAuthApiError,
  isAuthError,
  isAuthRetryableFetchError,
  isAuthSessionMissingError,
  type SupabaseClient,
} from "@supabase/supabase-js";
import { getServerEnv } from "@/lib/config/env";
import { AppError } from "@/lib/errors/app-error";
import { createServerSupabaseClient } from "@/lib/supabase/server";

/** Identidad mínima del usuario autenticado. Nada de token, correo ni metadatos. */
export type AuthIdentity = {
  /** `sub`: id del usuario en `auth.users`. */
  id: string;
  /** `session_id` de Supabase Auth, si viene en el token. */
  sessionId: string | null;
};

export type AccessTokenVerifierDeps = {
  auth: Pick<SupabaseClient["auth"], "getClaims">;
  /** `iss` esperado: `<SUPABASE_URL>/auth/v1`. */
  issuer: string;
};

export const INVALID_TOKEN = "Token de acceso inválido o expirado";
export const AUTH_UNAVAILABLE = "El servicio de autenticación no está disponible; intenta de nuevo";

const EXPECTED_AUDIENCE = "authenticated";
const EXPECTED_ROLE = "authenticated";
// HS256: proyectos con el secreto JWT antiguo. ES256/RS256: claves de firma asimétricas.
const ALLOWED_ALGS = new Set(["ES256", "RS256", "HS256"]);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const BASE64URL = /^[A-Za-z0-9_-]+$/;
// Margen para `nbf` por relojes desfasados.
const CLOCK_SKEW_S = 30;

/** El motivo queda en `cause` (no se envía ni se registra en un 4xx); el mensaje es fijo. */
const invalid = (reason: string) => new AppError("UNAUTHORIZED", INVALID_TOKEN, { cause: reason });

const unavailable = (cause: unknown) => new AppError("SERVICE_UNAVAILABLE", AUTH_UNAVAILABLE, { cause });

function decodeSegment(segment: string): unknown {
  return JSON.parse(Buffer.from(segment, "base64url").toString("utf8"));
}

/**
 * Filtro previo de forma, SIN confiar en el contenido: así un token roto es un
 * 401 y no una excepción de la librería que se confundiría con una caída.
 */
function assertWellFormed(token: string): void {
  const parts = token.split(".");
  if (parts.length !== 3 || !parts.every((p) => BASE64URL.test(p))) throw invalid("structure");

  let header: unknown;
  let payload: unknown;
  try {
    header = decodeSegment(parts[0]);
    payload = decodeSegment(parts[1]);
  } catch {
    throw invalid("structure");
  }
  if (!header || typeof header !== "object" || !payload || typeof payload !== "object") throw invalid("structure");

  const alg = (header as { alg?: unknown }).alg;
  if (typeof alg !== "string" || !ALLOWED_ALGS.has(alg)) throw invalid("alg");
}

/** Error de `getClaims` → 401 si el problema es el token, 503 si es el proveedor. */
function classify(error: unknown): AppError {
  if (isAuthRetryableFetchError(error)) return unavailable(error);
  if (isAuthApiError(error)) {
    // 4xx: Auth rechazó el token. 429 y 5xx: Auth no pudo atender.
    return error.status === 429 || error.status >= 500 ? unavailable(error) : invalid("rejected");
  }
  if (isAuthError(error) && error.name === "AuthInvalidJwtError") return invalid("signature-or-exp");
  // Auth responde `session_not_found`: la sesión del token se cerró o el usuario se borró.
  if (isAuthSessionMissingError(error)) return invalid("session");
  // AuthUnknownError o cualquier otra excepción: no hay prueba de que el token sea malo.
  return unavailable(error);
}

function hasAudience(aud: unknown): boolean {
  if (typeof aud === "string") return aud === EXPECTED_AUDIENCE;
  return Array.isArray(aud) && aud.includes(EXPECTED_AUDIENCE);
}

/** Reglas sobre claims YA verificados por `getClaims`. */
function identityFromClaims(claims: Record<string, unknown>, issuer: string): AuthIdentity {
  const now = Math.floor(Date.now() / 1000);

  if (typeof claims.exp !== "number" || claims.exp <= now) throw invalid("exp");
  if (claims.nbf !== undefined && (typeof claims.nbf !== "number" || claims.nbf > now + CLOCK_SKEW_S)) {
    throw invalid("nbf");
  }
  if (claims.iss !== issuer) throw invalid("iss");
  if (!hasAudience(claims.aud)) throw invalid("aud");
  if (claims.role !== EXPECTED_ROLE) throw invalid("role");
  // Los inicios de sesión anónimos también tienen rol `authenticated`.
  if (claims.is_anonymous === true) throw invalid("anonymous");
  if (typeof claims.sub !== "string" || !UUID.test(claims.sub)) throw invalid("sub");

  const sessionId =
    typeof claims.session_id === "string" && UUID.test(claims.session_id) ? claims.session_id : null;
  return { id: claims.sub, sessionId };
}

/** Verificador con dependencias explícitas (se usa en pruebas con un `getClaims` simulado). */
export function createAccessTokenVerifier({ auth, issuer }: AccessTokenVerifierDeps) {
  return async function verify(token: string): Promise<AuthIdentity> {
    // Sin token, `getClaims()` leería la sesión guardada del cliente: nunca se le llama así.
    if (typeof token !== "string" || token.length === 0) throw invalid("empty");
    assertWellFormed(token);

    let result: Awaited<ReturnType<typeof auth.getClaims>>;
    try {
      result = await auth.getClaims(token);
    } catch (error) {
      throw classify(error);
    }
    if (result.error) throw classify(result.error);
    if (!result.data?.claims) throw unavailable(new Error("getClaims no devolvió claims ni error"));

    return identityFromClaims(result.data.claims, issuer);
  };
}

let defaultVerifier: ((token: string) => Promise<AuthIdentity>) | undefined;

/**
 * Verifica un access token de Supabase y devuelve la identidad mínima.
 *
 * Perezoso: la configuración y el cliente se crean en la primera llamada, no al
 * importar. El cliente se reutiliza para aprovechar la caché del JWKS; es
 * seguro compartirlo porque no guarda sesión (`persistSession: false`) y
 * siempre se le pasa el token explícito.
 *
 * @throws AppError UNAUTHORIZED (401) | SERVICE_UNAVAILABLE (503); ConfigError (500).
 */
export async function verifyAccessToken(token: string): Promise<AuthIdentity> {
  defaultVerifier ??= createAccessTokenVerifier({
    auth: createServerSupabaseClient().auth,
    issuer: `${getServerEnv().supabaseUrl}/auth/v1`,
  });
  return defaultVerifier(token);
}

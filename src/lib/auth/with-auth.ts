/**
 * Protección de Route Handlers: sólo se ejecuta el handler si la petición trae
 * un access token de Supabase válido.
 *
 * Uso:
 *   export const GET = withAuth(async (request, ctx, { identity, supabase, requestId, log }) =>
 *     ok({ id: identity.id }),
 *   );
 *
 * Se apoya en `withApiHandler`: requestId, formato de errores, no-store y log
 * por petición siguen saliendo de ahí. Aquí sólo se añade:
 *   - Authorization → `extractBearerToken()` → `verifyAccessToken()`;
 *   - la identidad y un cliente de Supabase que actúa como ese usuario (RLS),
 *     como argumentos del handler (nunca en estado global);
 *   - `WWW-Authenticate: Bearer` en cualquier 401 del endpoint (RFC 6750 §3).
 *
 * El token vive sólo en esta llamada: va del encabezado al verificador y al
 * cliente, y el handler nunca lo recibe.
 *
 * Errores: 401 credenciales ausentes/mal formadas/inválidas; 503 Supabase Auth
 * no disponible (sin `WWW-Authenticate`); 500 configuración ausente.
 */
import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";
import { extractBearerToken } from "@/lib/auth/bearer";
import { verifyAccessToken, type AuthIdentity } from "@/lib/auth/verify";
import { AppError, isAppError } from "@/lib/errors/app-error";
import { withApiHandler, type ApiContext } from "@/lib/http/handler";
import { createUserSupabaseClient } from "@/lib/supabase/server";

export type AuthApiContext = ApiContext & {
  /** Usuario verificado de esta petición. */
  identity: AuthIdentity;
  /** Cliente de Supabase que actúa como `identity` (las consultas pasan por RLS). */
  supabase: SupabaseClient;
};

export type AuthHandler<Ctx> = (
  request: Request,
  ctx: Ctx,
  api: AuthApiContext,
) => Response | Promise<Response>;

export type VerifyAccessToken = (token: string) => Promise<AuthIdentity>;
export type CreateUserClient = (accessToken: string) => SupabaseClient;

export const BEARER_CHALLENGE = "Bearer";

/** Copia de un 401 con el desafío Bearer; el resto de errores pasa intacto. */
function withChallenge(error: unknown): unknown {
  if (!isAppError(error) || error.status !== 401) return error;
  return new AppError(error.code, error.message, {
    details: error.details,
    cause: error.cause,
    headers: { ...error.headers, "WWW-Authenticate": BEARER_CHALLENGE },
  });
}

/** `withAuth` con dependencias inyectadas (pruebas). En código normal se usa `withAuth`. */
export function createWithAuth(
  verify: VerifyAccessToken,
  createUserClient: CreateUserClient = createUserSupabaseClient,
) {
  return function withAuthHandler<Ctx = unknown>(handler: AuthHandler<Ctx>) {
    return withApiHandler<Ctx>(async (request, ctx, api) => {
      // Todo vive en variables locales de esta llamada: nada se comparte entre peticiones.
      let identity: AuthIdentity;
      let supabase: SupabaseClient;
      try {
        const token = extractBearerToken(request.headers.get("authorization"));
        identity = await verify(token);
        // Sólo después de verificar: un token inválido nunca llega a construir un cliente.
        supabase = createUserClient(token);
      } catch (error) {
        throw withChallenge(error);
      }

      try {
        return await handler(request, ctx, {
          ...api,
          identity,
          supabase,
          log: api.log.child({ userId: identity.id }),
        });
      } catch (error) {
        // Un 401 del propio handler también es de un endpoint protegido.
        throw withChallenge(error);
      }
    });
  };
}

/** Envuelve un Route Handler para que sólo se ejecute con un usuario autenticado. */
export const withAuth = createWithAuth(verifyAccessToken);

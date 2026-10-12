/**
 * Envoltorio de todos los Route Handlers.
 *
 * Se encarga de lo que ningún endpoint debe repetir:
 *   - requestId por petición (se devuelve en `x-request-id` y en los errores);
 *   - captura de errores → respuesta con el formato único;
 *   - un error inesperado nunca filtra su mensaje al cliente;
 *   - `Cache-Control: no-store` por omisión (una API con datos de usuario no se cachea);
 *   - una línea de log por petición con status y duración.
 *
 * Uso:
 *   export const GET = withApiHandler(async (request, ctx, { requestId, log }) => ok(...));
 */
import { AppError, isAppError } from "@/lib/errors/app-error";
import { fail } from "@/lib/http/response";
import { logger, type Logger } from "@/lib/logger";

export type ApiContext = {
  requestId: string;
  log: Logger;
};

export type ApiHandler<Ctx> = (
  request: Request,
  ctx: Ctx,
  api: ApiContext,
) => Response | Promise<Response>;

// Un requestId que manda el cliente se reutiliza sólo si es inofensivo:
// sin espacios ni saltos de línea (evita inyectar líneas falsas en el log).
const REQUEST_ID = /^[A-Za-z0-9._-]{8,128}$/;

export function resolveRequestId(incoming: string | null): string {
  return incoming && REQUEST_ID.test(incoming) ? incoming : crypto.randomUUID();
}

function errorToResponse(error: unknown, requestId: string, log: Logger): Response {
  if (isAppError(error)) {
    // 4xx es comportamiento esperado del cliente; 5xx sí es un problema nuestro.
    if (error.status >= 500) log.error("request failed", { code: error.code, error });
    else log.warn("request rejected", { code: error.code, message: error.message });
    return fail(error, requestId);
  }

  log.error("unhandled error", { error });
  return fail(new AppError("INTERNAL_ERROR", "Error interno del servidor"), requestId);
}

export function withApiHandler<Ctx = unknown>(handler: ApiHandler<Ctx>) {
  return async (request: Request, ctx: Ctx): Promise<Response> => {
    const startedAt = performance.now();
    const requestId = resolveRequestId(request.headers.get("x-request-id"));
    const log = logger.child({
      requestId,
      method: request.method,
      path: new URL(request.url).pathname,
    });

    let response: Response;
    try {
      response = await handler(request, ctx, { requestId, log });
    } catch (error) {
      response = errorToResponse(error, requestId, log);
    }

    // Se copia la respuesta en vez de mutarla: las respuestas de `fetch()`
    // tienen headers inmutables y lanzarían al intentar escribirlos.
    const headers = new Headers(response.headers);
    headers.set("x-request-id", requestId);
    if (!headers.has("cache-control")) headers.set("cache-control", "no-store");

    log.info("request completed", {
      status: response.status,
      durationMs: Math.round(performance.now() - startedAt),
    });

    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers,
    });
  };
}

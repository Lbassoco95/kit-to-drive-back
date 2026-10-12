/**
 * Formato único de respuesta. Ningún endpoint arma su propio JSON de salida:
 * todos pasan por `ok()` o `fail()`, así el front tiene un solo contrato.
 *
 *   éxito: { "success": true,  "data": ... }
 *   error: { "success": false, "error": { "code", "message", "requestId", "details"? } }
 */
import type { AppError, ErrorCode } from "@/lib/errors/app-error";

export type ApiSuccess<T> = { success: true; data: T };

export type ApiFailure = {
  success: false;
  error: {
    code: ErrorCode;
    message: string;
    /** Para que soporte encuentre la petición exacta en los logs. */
    requestId: string;
    details?: unknown;
  };
};

export type ApiResponse<T> = ApiSuccess<T> | ApiFailure;

export function ok<T>(data: T, init?: ResponseInit): Response {
  const body: ApiSuccess<T> = { success: true, data };
  return Response.json(body, init);
}

export function fail(error: AppError, requestId: string): Response {
  const body: ApiFailure = {
    success: false,
    error: {
      code: error.code,
      message: error.message,
      requestId,
      ...(error.details !== undefined ? { details: error.details } : {}),
    },
  };
  return Response.json(body, { status: error.status, headers: error.headers });
}

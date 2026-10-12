/**
 * Errores de la API.
 *
 * Un `AppError` es un error *esperado*: su `code` y su `message` están
 * pensados para el cliente. Cualquier otro error (un bug, una excepción de una
 * librería) se trata como inesperado: se registra completo en el log y al
 * cliente sólo le llega un 500 genérico, para no filtrar detalles internos.
 */

/** Catálogo cerrado de códigos y su status HTTP. El cliente decide por `code`, no por el texto. */
export const ERROR_STATUS = {
  VALIDATION_ERROR: 400,
  UNAUTHORIZED: 401,
  FORBIDDEN: 403,
  NOT_FOUND: 404,
  CONFLICT: 409,
  INTERNAL_ERROR: 500,
  /** Un servicio del que dependemos (p. ej. Supabase Auth) no respondió; reintentar puede funcionar. */
  SERVICE_UNAVAILABLE: 503,
} as const;

export type ErrorCode = keyof typeof ERROR_STATUS;

export class AppError extends Error {
  readonly code: ErrorCode;
  readonly status: number;
  /** Información segura para el cliente (p. ej. qué campos no pasaron la validación). */
  readonly details?: unknown;
  /** Encabezados HTTP que exige el error (p. ej. `WWW-Authenticate` en un 401). */
  readonly headers?: Readonly<Record<string, string>>;

  constructor(
    code: ErrorCode,
    message: string,
    options: { details?: unknown; cause?: unknown; headers?: Record<string, string> } = {},
  ) {
    // `cause` queda sólo para el log: nunca se envía al cliente.
    super(message, { cause: options.cause });
    this.name = "AppError";
    this.code = code;
    this.status = ERROR_STATUS[code];
    this.details = options.details;
    this.headers = options.headers;
  }
}

export function isAppError(error: unknown): error is AppError {
  return error instanceof AppError;
}

/**
 * Token Bearer del encabezado `Authorization` (RFC 6750 §2.1).
 *
 * Sólo comprueba la FORMA: `Bearer <token>`, con el esquema sin distinguir
 * mayúsculas. No verifica firma ni expiración; eso es trabajo de quien reciba
 * el token. Un token con forma válida todavía no identifica a nadie.
 *
 * Los mensajes de error son fijos: nunca incluyen el encabezado ni el token,
 * porque `withApiHandler` registra el mensaje de cada 4xx y lo envía al cliente.
 */
import { AppError } from "@/lib/errors/app-error";

// b64token de RFC 6750: sin espacios ni comas, así que dos tokens no pasan.
const BEARER = /^Bearer +([A-Za-z0-9\-._~+/]+=*)$/i;

// Un JWT de Supabase mide unos cientos de bytes; esto sólo corta abusos.
export const MAX_AUTHORIZATION_LENGTH = 8192;

export const MISSING_AUTHORIZATION = "Falta el encabezado Authorization";
export const INVALID_AUTHORIZATION = "El encabezado Authorization debe tener el formato «Bearer <token>»";

/**
 * Devuelve el token de `Bearer <token>`.
 *
 * @param header valor de `request.headers.get("authorization")`.
 * @throws AppError `UNAUTHORIZED` (401) si falta, está vacío o no tiene el formato.
 */
export function extractBearerToken(header: string | null | undefined): string {
  // `Headers` ya recorta espacios de los extremos; se repite para llamadas directas.
  const value = header?.trim();
  if (!value) throw new AppError("UNAUTHORIZED", MISSING_AUTHORIZATION);

  const match = value.length <= MAX_AUTHORIZATION_LENGTH ? BEARER.exec(value) : null;
  if (!match) throw new AppError("UNAUTHORIZED", INVALID_AUTHORIZATION);

  return match[1];
}

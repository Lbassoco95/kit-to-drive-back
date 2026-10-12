/**
 * Logger estructurado: una línea JSON por evento en stdout/stderr, que es lo
 * que Vercel (o cualquier colector) indexa sin configuración.
 *
 * Todo lo que se registra pasa por `redact()`: un campo cuyo nombre parezca
 * credencial, o un texto con forma de token, nunca llega al log. Es la red de
 * seguridad para el día en que alguien registre un objeto completo sin pensar.
 *
 * Sin dependencias a propósito. Si más adelante hace falta pino, se cambia la
 * implementación de `write()` y la interfaz (`info/warn/error/child`) se queda.
 */

export type LogLevel = "debug" | "info" | "warn" | "error";
export type LogContext = Record<string, unknown>;

export interface Logger {
  debug(msg: string, context?: LogContext): void;
  info(msg: string, context?: LogContext): void;
  warn(msg: string, context?: LogContext): void;
  error(msg: string, context?: LogContext): void;
  /** Logger con campos fijos (p. ej. `requestId`) en cada línea. */
  child(bindings: LogContext): Logger;
}

export const REDACTED = "[REDACTED]";

const LEVEL_RANK: Record<LogLevel, number> = { debug: 10, info: 20, warn: 30, error: 40 };

// Nombres de campo que se ocultan siempre, sin importar el valor.
const SENSITIVE_KEY =
  /pass(word|wd)?|contrase|secret|token|authorization|cookie|api[-_]?key|apikey|service[-_]?role|jwt|session|credential|private[-_]?key/i;

// Valores con forma de credencial aunque el campo tenga un nombre inocente.
const BEARER = /^\s*bearer\s+\S+/i;
const JWT = /eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]+/g;
const SUPABASE_KEY = /sb_(secret|publishable)_[A-Za-z0-9_-]+/g;

const MAX_DEPTH = 6;

function redactString(value: string): string {
  if (BEARER.test(value)) return REDACTED;
  return value.replace(JWT, REDACTED).replace(SUPABASE_KEY, REDACTED);
}

/** Copia del valor con credenciales ocultas. No modifica el original. */
export function redact(value: unknown, depth = 0, seen: WeakSet<object> = new WeakSet()): unknown {
  if (typeof value === "string") return redactString(value);
  if (value === null || typeof value !== "object") return value;
  if (depth >= MAX_DEPTH) return "[MaxDepth]";
  if (seen.has(value)) return "[Circular]";
  seen.add(value);

  if (value instanceof Error) {
    return {
      name: value.name,
      message: redactString(value.message),
      ...(value.stack ? { stack: redactString(value.stack) } : {}),
      ...(value.cause !== undefined ? { cause: redact(value.cause, depth + 1, seen) } : {}),
    };
  }
  if (Array.isArray(value)) return value.map((item) => redact(item, depth + 1, seen));

  const out: Record<string, unknown> = {};
  for (const [key, item] of Object.entries(value)) {
    out[key] = SENSITIVE_KEY.test(key) ? REDACTED : redact(item, depth + 1, seen);
  }
  return out;
}

function minLevel(): LogLevel {
  return process.env.NODE_ENV === "production" ? "info" : "debug";
}

function write(level: LogLevel, msg: string, bindings: LogContext, context?: LogContext) {
  if (LEVEL_RANK[level] < LEVEL_RANK[minLevel()]) return;
  const entry = redact({ ...bindings, ...context }) as LogContext;
  const line = JSON.stringify({ level, time: new Date().toISOString(), msg, ...entry });
  if (level === "error") console.error(line);
  else if (level === "warn") console.warn(line);
  else console.log(line);
}

function createLogger(bindings: LogContext = {}): Logger {
  return {
    debug: (msg, context) => write("debug", msg, bindings, context),
    info: (msg, context) => write("info", msg, bindings, context),
    warn: (msg, context) => write("warn", msg, bindings, context),
    error: (msg, context) => write("error", msg, bindings, context),
    child: (extra) => createLogger({ ...bindings, ...extra }),
  };
}

export const logger: Logger = createLogger({ service: "kit-to-drive-api" });

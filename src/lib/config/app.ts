/**
 * Identidad de la aplicación (no es configuración de entorno ni contiene
 * secretos). Las variables de entorno validadas viven en `config/env.ts`.
 */
import pkg from "../../../package.json";

export const APP_INFO = {
  name: pkg.name,
  version: pkg.version,
} as const;

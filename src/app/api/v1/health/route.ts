/**
 * GET /api/v1/health — ¿el proceso de la API está vivo y respondiendo?
 *
 * Público y sin dependencias: no consulta la base ni servicios externos, así
 * que nunca falla porque otro servicio esté caído (eso será un `/ready` aparte).
 * Tampoco expone entorno, versión de Node ni identificadores del proyecto.
 *
 * Con `cacheComponents: false`, un GET de Route Handler se ejecuta en cada
 * petición; `timestamp` lo demuestra (y la prueba lo verifica).
 */
import { APP_INFO } from "@/lib/config/app";
import { withApiHandler } from "@/lib/http/handler";
import { ok } from "@/lib/http/response";

export type HealthData = {
  status: "ok";
  service: string;
  version: string;
  timestamp: string;
};

export const GET = withApiHandler(() =>
  ok<HealthData>({
    status: "ok",
    service: APP_INFO.name,
    version: APP_INFO.version,
    timestamp: new Date().toISOString(),
  }),
);

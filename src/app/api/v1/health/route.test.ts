import { beforeEach, describe, expect, it, vi } from "vitest";
import pkg from "../../../../../package.json";
import type { ApiSuccess } from "@/lib/http/response";
import { GET, type HealthData } from "./route";

const call = () => GET(new Request("http://localhost/api/v1/health"), undefined);

beforeEach(() => {
  vi.spyOn(console, "log").mockImplementation(() => {});
});

describe("GET /api/v1/health", () => {
  it("responde 200 con el formato estándar", async () => {
    const res = await call();
    const body = (await res.json()) as ApiSuccess<HealthData>;

    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("application/json");
    expect(body.success).toBe(true);
    expect(body.data).toMatchObject({ status: "ok", service: pkg.name, version: pkg.version });
  });

  it("no expone nada más que lo previsto", async () => {
    const body = (await (await call()).json()) as ApiSuccess<HealthData>;
    expect(Object.keys(body.data).sort()).toEqual(["service", "status", "timestamp", "version"]);
  });

  it("calcula el timestamp en cada petición (no queda congelado)", async () => {
    const antes = Date.now();
    const body = (await (await call()).json()) as ApiSuccess<HealthData>;
    const ts = Date.parse(body.data.timestamp);

    expect(ts).toBeGreaterThanOrEqual(antes - 1000);
    expect(ts).toBeLessThanOrEqual(Date.now() + 1000);
  });

  it("no se cachea y trae x-request-id", async () => {
    const res = await call();
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(res.headers.get("x-request-id")).toBeTruthy();
  });
});

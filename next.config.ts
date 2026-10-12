import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // API: los Route Handlers no se cachean salvo que se pida explícitamente.
  // Se deja en `false` explícito porque Next respeta el valor del config por
  // encima de su activación por variable de entorno. `partialPrefetching`
  // se retira porque exige `cacheComponents` (falla la validación sin él).
  cacheComponents: false,
  turbopack: {
    rules: {
      "*.css": {
        loaders: ["@tailwindcss/turbopack"],
        as: "*.css",
      },
    },
  },
};

export default nextConfig;

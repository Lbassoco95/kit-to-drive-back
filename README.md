# kit-to-drive-back

Back de Dazon: base de datos y funciones de servidor en Supabase.

- `supabase/migrations/` — línea base documental del esquema (no se usa `supabase db push`).
- `supabase/functions/` — Edge Functions (admin-create-user, admin-update-user, admin-reset-user-password, complete-password-change, seed-demo-users).
- `docs/` — arquitectura en capas y reglas para no romper producción.

El front vive en `lbassoco95/kit-to-drive` (Vercel). Orden de cambios: primero el back, después el front.

## API (Next.js) — en construcción

`src/` contiene la nueva API de Kit-to-Drive (Next.js 16, Route Handlers). Se
desarrolla en paralelo: todavía no la consume el front ni toca la base.

```bash
pnpm install
pnpm dev                 # http://localhost:3000/api/v1/health
pnpm typecheck && pnpm lint && pnpm test && pnpm build
```

- `src/app/api/v1/**/route.ts` — endpoints; sin lógica de negocio.
- `src/lib/http/` — `withApiHandler` (requestId, errores, no-store, log) y el
  formato único de respuesta `{ success, data }` / `{ success: false, error }`.
- `src/lib/errors/` — `AppError` y su catálogo de códigos.
- `src/lib/logger/` — logs JSON con redacción de credenciales.
- `src/lib/config/env.ts` — variables de entorno validadas (sólo servidor).
- `src/lib/supabase/server.ts` — cliente de Supabase para Route Handlers (sólo
  servidor). Todavía ningún endpoint lo usa ni hace consultas.

### Entorno local (`.env.local`)

Hoy sólo hacen falta para endpoints que usen Supabase; `pnpm build`, las
pruebas y `/api/v1/health` funcionan sin `.env.local`.

1. `cp .env.example .env.local` (`.env.local` está en `.gitignore`).
2. En el panel de Supabase del proyecto, copiar a mano:
   - `SUPABASE_URL` — Project Settings → Data API → Project URL.
   - `SUPABASE_PUBLISHABLE_KEY` — Project Settings → API Keys → Publishable
     key (`sb_publishable_…`), o la clave `anon` antigua.
3. No copiar valores del front (`VITE_*`) ni de Vercel sin verificar en el
   panel qué clave es. No usar `NEXT_PUBLIC_` para estas variables.

La API **rechaza** una clave secreta (`sb_secret_…`) o `service_role` puesta en
`SUPABASE_PUBLISHABLE_KEY`. La clave publicable no autoriza nada por sí sola:
los permisos los deciden la identidad de la petición y las políticas RLS.

Si falta una variable o es inválida, el endpoint que la necesite responde 500
genérico y el log indica qué variable falló (nunca su valor). Las pruebas
(`vitest`) no leen `.env.local`: usan valores ficticios y `fetch` simulado.

`supabase/` queda fuera de TypeScript y ESLint de la API: es código Deno y SQL
con su propio ciclo.

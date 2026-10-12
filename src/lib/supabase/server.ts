/**
 * Clientes de Supabase para el servidor (Route Handlers). Nunca para el navegador.
 *
 * Ambos usan sólo `SUPABASE_URL` y la clave publicable; ninguno usa
 * `service_role`, así que RLS siempre aplica:
 *   - `createServerSupabaseClient()`: sin usuario (actúa como `anon`). Lo usa
 *     la verificación de tokens; no sirve para leer datos de usuarios.
 *   - `createUserSupabaseClient(token)`: actúa como el usuario dueño del JWT.
 *     Es el que reciben los handlers protegidos por `withAuth`.
 *
 * Aquí sólo se construyen clientes: no hay consultas. Las operaciones de
 * datos irán en una capa aparte que reciba el cliente.
 */
import "server-only";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { getServerEnv } from "@/lib/config/env";

/**
 * Cliente nuevo por llamada: en el servidor no se comparte estado de sesión
 * entre peticiones. Crearlo no hace peticiones de red.
 *
 * @throws ConfigError si faltan variables o son inválidas.
 */
export function createServerSupabaseClient(): SupabaseClient {
  const { supabaseUrl, supabasePublishableKey } = getServerEnv();
  return createClient(supabaseUrl, supabasePublishableKey, {
    auth: {
      // Sin almacenamiento ni temporizadores: nada que persistir en el servidor.
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
  });
}

/**
 * Cliente que actúa como el usuario del access token: cada petición a
 * PostgREST, RPC, Storage o Functions lleva `apikey: <clave publicable>` y
 * `Authorization: Bearer <token>`, así que `auth.uid()` y RLS ven a ese usuario.
 *
 * SÓLO con un token ya verificado (`verifyAccessToken`); `withAuth` lo
 * garantiza. Usa la opción `accessToken` de supabase-js, que además:
 *   - deshabilita `client.auth` (lanza si se usa): no se inician, guardan ni
 *     renuevan sesiones en el servidor;
 *   - deja el token en un closure de este cliente, que es nuevo en cada llamada:
 *     nada se comparte entre peticiones.
 * Crearlo no hace peticiones de red. Si el token expira durante la petición,
 * Supabase lo rechaza: no se renueva.
 *
 * @throws ConfigError si faltan variables o son inválidas.
 */
export function createUserSupabaseClient(accessToken: string): SupabaseClient {
  // Sin token, supabase-js mandaría la clave publicable como Bearer (= anon).
  if (typeof accessToken !== "string" || accessToken.length === 0) {
    throw new TypeError("createUserSupabaseClient requiere un access token verificado");
  }
  const { supabaseUrl, supabasePublishableKey } = getServerEnv();
  return createClient(supabaseUrl, supabasePublishableKey, {
    accessToken: async () => accessToken,
  });
}

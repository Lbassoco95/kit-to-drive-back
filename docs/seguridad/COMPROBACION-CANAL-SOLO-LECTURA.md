# Comprobación del canal de solo lectura (para cuando Polo avise)

**Pendiente hasta que Polo avise que configuró el MCP de solo lectura (`supabase-prod`) y desactivó el conector con escritura y el token.** Mientras tanto, Claude **no consulta producción**.

## Qué hace Claude cuando Polo avise

1. **Proyecto:** `get_project_url` debe devolver `https://dmhzhyeivvuliumcgsmm.supabase.co`. Si es otro: **se detiene**.
2. **Lectura-solo del servidor:** `show transaction_read_only;` → debe dar **`on`** (el MCP la fuerza con `read_only=true`).
3. **Un `CREATE` de prueba debe ser rechazado**, sin dejar nada:
   ```sql
   begin read only;
   create table public.zz_prueba_solo_lectura_borrar (x int);   -- debe fallar: «cannot execute CREATE TABLE in a read-only transaction» (25006)
   rollback;
   ```
   Y después, comprobar que **no existe**: `select to_regclass('public.zz_prueba_solo_lectura_borrar');` → `null`. **No se deja ningún `CREATE` real.**
   Si en cambio el `CREATE` **se ejecutara**, es el conector con escritura: **se detiene, no se usa, y se avisa a Polo** (y se comprueba que la tabla no quedó).
4. **El conector con escritura ya no aparece:** la lista de herramientas no debe traer `apply_migration` ni `deploy_edge_function` del conector de claude.ai.
5. Se anota en el reporte: proyecto, `transaction_read_only = on`, resultado del `CREATE` (rechazado) y que no quedó la tabla.

## Después de eso

Todas las mediciones de la ventana se hacen **solo** por este canal: `consultas/02`, `05` y `06`, el comparador de integridad, `consultas/07` (historial de migraciones) y los registros.

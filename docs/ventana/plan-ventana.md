# Plan de ventana · Control financiero unificado (27 oct 2026)

Nada se ejecuta hasta que Polo escriba la autorización con fecha y hora. Orden pedido: (a) unificación con evidencia obligatoria, (b) bancos por empresa, (c) búsqueda al aplicar. (b) y (c) viajan en un solo archivo de migración (`20261031000001`), que se aplica después de (a).

| # | Paso | Quién | Verificación después | Reversa |
|---|------|-------|----------------------|---------|
| 0 | Aviso al equipo y **apagar el módulo de finanzas** en MATI Admin (desaparece del menú). Cobranza y Crédito siguen, pero no se usan en la ventana | Polo | El menú ya no muestra «Control financiero» | Volver a encender el módulo |
| 1 | **Respaldo** (`00_respaldo.sql`): schema `respaldo_20261027` con las 5 tablas | Polo pega, yo verifico | Conteos vivo = respaldo (3·3·6·1·9) | `DROP SCHEMA respaldo_20261027 CASCADE` (solo si ya no se necesita) |
| 2 | **Migración (a)** `20261030000001` (unificación, evidencia, reversa, historial, candados) | Polo pega | V1 (conteos y saldos idénticos), V2 (sin_origen = 0; libro y registrar cerrados) | `reversa_unificacion_y_bancos.sql`: quita candados y devuelve políticas/privilegios; los datos no se tocan. Si hiciera falta, restaurar tablas desde el respaldo |
| 3 | **Migración (b)+(c)** `20261031000001` (empresas, cuentas por empresa, búsqueda, cambio de cliente, crédito, políticas de evidencia) | Polo pega | V1, V3 (empresas 0, cuentas sin empresa 3, firmas nuevas presentes, políticas `evidencias_flujo_*`) | Mismo script de reversa (quita los candados de cuentas; las tablas nuevas quedan vacías) |
| 4 | **Registro** de ambas en `migraciones_aplicadas` | Polo pega (SQL que entrego) | Dos filas nuevas | `DELETE` de esas dos filas |
| 5 | **Compuerta** (`kit-to-drive-api`): allowlist nueva y solo lectura en libro/cuentas/abonos | Yo preparo PR, Polo autoriza el despliegue | `/rest/v1/rpc/flujo_empresas` pasa; `POST movimientos_financieros` da 403 | Revertir el despliegue en la plataforma (rollback al anterior) |
| 6 | **Front**: merge a `main` y Vercel despliega (un solo módulo con pestañas) | Yo, tras autorización | Vercel en verde para el SHA; `https://kit-to-drive.vercel.app` apunta a él | Rollback del deployment anterior en Vercel (el anterior *no* funciona con la base nueva; usar solo junto con la reversa SQL) |
| 7 | **Cuentas bancarias**: el administrador financiero da de alta las empresas y asigna las 3 cuentas actuales (banco y últimos 4) | Admin financiero (UI) | V4: saldos por cuenta iguales a V1; bitácora con las altas | Desactivar (no se borra) |
| 8 | **Movimiento heredado**: cancelar con motivo el movimiento PENDIENTE antiguo del libro y volver a capturarlo por Recibe | Admin financiero | Libro: 1 cancelado con motivo; nuevo movimiento con folio FD-… | Es un movimiento más; no hay reversa necesaria |
| 9 | **Prueba de humo** con cuentas de prueba: recibir con evidencia → caja con la cuenta de la empresa → aplicar con búsqueda de remisiones → cambiar cliente → revertir | Yo (cuentas `prueba.*`) | Cada paso OK; el libro real no cambia (prueba y real separados); V1 igual | Datos de prueba, no se tocan los reales |
| 10 | **Encender el módulo** y avisar al equipo | Polo | Menú visible; Jair/Leti/Martin entran a su pestaña | Apagar de nuevo |

## Qué ve el equipo mientras tanto
- Pasos 0 a 6 (≈ 30 min, fuera de horario): «Control financiero» no aparece en el menú. No se puede registrar ni confirmar dinero. Lo que llegue hoy se anota en papel y se captura al terminar.
- Entre 2 y 6 no se debe abrir la versión anterior de la pantalla (fallaría: ya exige evidencia y empresa).
- Desde el paso 10: una sola entrada, «Control financiero», con pestañas Recibe, Caja, Aplica, Movimientos y (solo administración) Cuentas bancarias; cada persona ve las de su etapa.

## Lo que se conserva
Los 3 movimientos del libro (uno PENDIENTE, dos CONFIRMADOS), 6 pagos, 1 abono, 9 flujos y 3 cuentas con su saldo: ninguna migración borra ni modifica montos. Los movimientos anteriores quedan marcados `HISTORICO_DIRECTO`; los flujos abiertos siguen en su etapa.

## Qué se probó y qué no
Probado en local: ambas migraciones sobre base vacía y sobre una base con datos (transición sin pérdida), pruebas SQL de las puertas cerradas, evidencia, empresas, reglas de cuenta/método/moneda, búsqueda, cambio de cliente, reversa, prueba/real y separación de funciones; vitest y typecheck/build del front; pruebas de la compuerta; la reversa SQL.
Sin probar: la pantalla en un navegador contra una base real (solo typecheck, vitest y build); la política de Storage para subir evidencia (se prueba en el paso 9); el despliegue de la compuerta (plataforma por confirmar).

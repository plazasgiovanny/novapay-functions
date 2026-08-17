# novapay-functions

Código de aplicación del flujo serverless de confirmación de pagos de NovaPay (Maestría en Arquitectura de Software, Politécnico Grancolombiano — Unidad 4, "Automatización, despliegue continuo y estrategia de escalabilidad y resiliencia").

Repositorio separado de la infraestructura ([`novapay-iac-terraform`](https://github.com/plazasgiovanny/novapay-iac-terraform)) a propósito — ver ADR-01/ADR-02 en ese repo (`decisiones/`). Cadencia de release de código independiente de la de infraestructura: este repo despliega directo a Azure con su propia identidad OIDC, sin pasar por Terraform ni por su gate de aprobación.

## Contenido

| Carpeta | Qué es |
|---|---|
| `src/NovaPay.Payments/` | Proyecto .NET 8 isolated worker: `ValidatePayment` (HTTP trigger) y `ProcessPayment` (Service Bus trigger). Ver su propio `README.md` para setup y ejecución local. |

## Responsabilidad y límite

Este código depende de que la infraestructura ya exista (Function Apps, Service Bus Topic + Subscriptions, Azure SQL — módulos `compute-serverless`, `messaging-servicebus`, `data-sql` de `novapay-iac-terraform`) y de que el script `sql/002_notificaciones_transaccionales.sql` de ese repo ya se haya ejecutado. No se puede desplegar ni correr en vacío.

Terraform gestiona el *shell* del recurso (runtime, integración VNet, identidad, escalado); este repo gestiona el código que corre dentro de ese shell. Coordinación cross-repo solo cuando cambia el contrato entre ambos (PR humano normal, sin automatización cruzada).

## CI/CD

- **CI** (`.github/workflows/ci.yml`, en cada PR): `dotnet build` con SDK fijada a `net8.0`.
- **CD** (`.github/workflows/cd.yml`, en cada release publicado): consulta el peso actual del backend pool de APIM para elegir la instancia en 0% (aborta si el estado es ambiguo), despliega ahí (`az functionapp deployment source config-zip`), atesta la procedencia del artefacto, verifica el despliegue, y avanza la rampa 5% → 25% → 100% con ventana de observación (≥15 min y ≥50 solicitudes) y guardrail de error rate (rollback de tráfico automático si supera 3%). Rollback manual: `workflow_dispatch` con el tag del release anterior — mismo mecanismo, no un camino aparte.
- **Verificación post-despliegue vía ruta directa en APIM** — **HALLAZGO REAL** (primer run real de este pipeline, 2026-08-17, nunca antes ejercitado): esperar tráfico real vía Application Insights en la instancia recién desplegada no podía funcionar nunca — esa instancia siempre está al 0% de peso justo después del deploy, así que el backend pool jamás la selecciona para tráfico público (confirmado empíricamente: 0 de 10 solicitudes reales llegaron). Fix real: la policy de APIM (`novapay-iac-terraform`) tiene una ruta directa condicional, gateada por dos headers (`X-Novapay-Verify-Key` con un secreto — `secrets.APIM_VERIFY_KEY`, salida `apim_verify_key` de Terraform — y `X-Novapay-Verify-Target` con el `backend-id` exacto, validado contra una lista fija de dos valores), que bypassa el Pool solo para estas solicitudes de verificación. Sigue pasando por `ip_restriction` porque el origen real sigue siendo APIM.
- **Observabilidad de la rampa** (ADR-07 U4, Bloque 2d): antes de cada incremento de peso, consulta el consumo del error budget (ventana móvil de 30 días) y bloquea el siguiente incremento si supera 80% (la instancia se queda en el peso ya alcanzado, sin rollback — distinto del guardrail de error rate agudo, que sí hace rollback inmediato). Cada cambio de peso real se emite como evento `PesoActualizado` vía Logs Ingestion API a la Data Collection Rule de `novapay-iac-terraform` (secrets `DCE_LOGS_INGESTION_ENDPOINT`/`DCR_PESOACTUALIZADO_IMMUTABLE_ID`, salidas del módulo `observability` tras su apply) — no bloqueante si esos secrets no están configurados o el POST falla.
- Identidad OIDC propia (`sp-novapay-functions-prod`), con `Website Contributor` sobre ambos Function Apps, `API Management Service Contributor` acotado a `apim-novapay-prod` (necesario porque el propio CD mueve los pesos del pool), `Monitoring Metrics Publisher` acotado a la DCR del evento `PesoActualizado`, y `Monitoring Reader` sobre `appi-novapay-prod` (necesario para `az monitor app-insights query` — otro hallazgo real del mismo primer run, nunca antes ejercitado) — nunca sobre el resource group completo.

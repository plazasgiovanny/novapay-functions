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
- **CD**: pendiente — depende de que el backend pool ponderado de APIM (Sección 2, ADR-03) exista en `novapay-iac-terraform` antes de poder consultar su peso y decidir el destino del despliegue (ver ADR-02). Se agrega en cuanto esa infraestructura esté lista.

# NovaPay.Payments

Azure Functions (.NET 8, isolated worker) que aloja `ValidatePayment` y `ProcessPayment`, el flujo de confirmación y notificación de pagos de NovaPay. Se despliega sobre las dos instancias `func-novapay-pagos-{env}` / `func-novapay-pagos-canary-{env}` (Flex Consumption, sin jerarquía fija — ver ADR-03 en el repo de infraestructura), aprovisionadas por `modules/compute-serverless` en [`novapay-iac-terraform`](https://github.com/plazasgiovanny/novapay-iac-terraform).

Este proyecto vivía originalmente dentro de ese mismo repo (`functions/NovaPay.Payments/`, Entrega 2/U3) y se extrajo a un repositorio propio para la Unidad 4 — cadencia de release de código independiente de la de infraestructura (ver ADR-01/ADR-02). El historial de commits previo no se migró (decisión explícita, no una pérdida accidental).

## Estructura

```
NovaPay.Payments/
├── Functions/
│   ├── ValidatePayment.cs   # HTTP trigger, POST /api/confirmations
│   └── ProcessPayment.cs    # Service Bus trigger, Topic + Subscription propia de esta instancia
├── Models/
│   ├── PaymentConfirmationRequest.cs  # body del POST
│   └── PaymentValidatedEvent.cs       # evento publicado en el Topic
├── Data/
│   ├── SqlConnectionFactory.cs               # conexión a Azure SQL vía Managed Identity
│   ├── TransactionalNotificationsRepository.cs  # idempotencia (UNIQUE TransactionId) + persistencia
│   └── AccountValidationService.cs           # validación de cuenta/límites — PENDIENTE, ver abajo
├── Program.cs
└── host.json
```

## Cómo funciona el flujo

1. `ValidatePayment` recibe `POST /api/confirmations` (APIM reenvía aquí, vía el backend pool ponderado que decide qué instancia recibe el tráfico — ver ADR-03).
2. Valida el body, revisa si el `transactionId` ya fue procesado (`409` si sí), valida cuenta/monto/límites (`400` si no pasa), y si todo está bien:
   - responde `202 Accepted` con `{transactionId, status:"pending"}`,
   - publica un `ServiceBusMessage` al Topic con `MessageId = transactionId` (activa la deduplicación nativa de Service Bus) y `ApplicationProperties["sourceInstance"] = WEBSITE_SITE_NAME` — el evento `PaymentValidated` serializado como body.
3. Cada Subscription del Topic filtra por `sourceInstance` (SQL filter sobre `$Default`), así que el mensaje llega únicamente a la `ProcessPayment` de la misma instancia física que lo publicó — nunca a la otra.
4. `ProcessPayment` consume ese mensaje, inserta en `dbo.TransactionalNotifications` (segunda capa de idempotencia: si el `INSERT` viola `UNIQUE(TransactionId)`, se trata como ya procesado, no como error) y marca la notificación como `sent` (simulada, sin proveedor externo real).
5. Si `ProcessPayment` lanza una excepción no controlada (error transitorio), el runtime abandona el mensaje y Service Bus lo reintenta según `host.json` (`maxRetryCount = 5`, backoff exponencial 5s–60s) hasta el `max_delivery_count` de la Subscription; agotados los intentos, cae a la Dead-Letter Queue de esa Subscription.

## Requisitos previos

- .NET SDK con soporte para `net8.0`.
- Azure Functions Core Tools v4 (`func --version`).
- Azure CLI (`az`), con sesión iniciada contra la suscripción real de NovaPay si vas a probar contra recursos reales (`az account set --subscription <id>`).

## Configuración local

```bash
cp local.settings.json.example local.settings.json
```

`local.settings.json` **no se versiona** (está en `.gitignore`). Ajusta los valores al ambiente real (`dev` normalmente):

| Setting | De dónde sale |
|---|---|
| `serviceBusConnection__fullyQualifiedNamespace` | `sb-novapay-{env}.servicebus.windows.net` — salida `namespace_fqdn` de `messaging-servicebus` |
| `ServiceBusTopicName` | `sbt-novapay-pagos-pendientes-{env}` — salida `topic_name` de `messaging-servicebus` |
| `ServiceBusSubscriptionName` | `sub-func-novapay-pagos-{env}` (o `-canary-{env}` según la instancia) — específico de cada Function App, no compartido |
| `SqlServer__Fqdn` | `sql-novapay-{env}.database.windows.net` — salida `fully_qualified_domain_name` de `data-sql` |
| `SqlServer__Database` | `sqldb-novapay-core-{env}` — salida `database_name` de `data-sql` |

Estos valores viajan como app settings reales una vez desplegado (`modules/compute-serverless/main.tf`, repo de infraestructura) — `local.settings.json` solo los duplica para desarrollo local.

**Importante sobre identidad para pruebas locales**: en Azure, la autenticación es 100% por Managed Identity (Service Bus y SQL). Localmente no existe Managed Identity, así que `DefaultAzureCredential`/`Authentication=Active Directory Default` cae a tu sesión de `az login` — tu usuario necesita los mismos roles que la identidad del Function App (`Azure Service Bus Data Sender` sobre el Topic, `Data Receiver` sobre la Subscription propia, usuario AAD con `SELECT/INSERT/UPDATE` sobre `TransactionalNotifications`) para que las pruebas locales funcionen de extremo a extremo contra los recursos reales de `dev`.

## Ejecutar localmente

```bash
dotnet build
func start
```

`ValidatePayment` queda en `http://localhost:7071/api/confirmations`.

## Desplegar

En producción, el despliegue lo hace el pipeline CD de este repo (ver `.github/workflows/`), que consulta el peso actual del backend pool de APIM y publica en la instancia que esté en 0% — nunca en la que sirve tráfico vigente (ADR-02). Para una prueba manual puntual:

```bash
func azure functionapp publish func-novapay-pagos-<env>
# o func-novapay-pagos-canary-<env>, según cuál instancia se esté probando
```

## Pendiente / coordinación necesaria

- **Tabla de cuentas real**: `AccountValidationService` todavía no consulta el core bancario — solo aplica un límite máximo configurable (`Payments__MaxTransactionAmount`). El nombre real de la tabla de cuentas/movimientos está señalado como pendiente en `sql/002_notificaciones_transaccionales.sql` (repo de infraestructura). Hay que confirmarlo y completar `AccountValidationService.ValidateAsync`.
- **Script SQL**: `sql/002_notificaciones_transaccionales.sql` (repo de infraestructura) debe ejecutarse contra `sqldb-novapay-core-{env}` (crea la tabla + el usuario contenido AAD por cada Function App) antes de que esta app pueda escribir nada.
- **Coordinación cross-repo**: cualquier cambio de contrato entre este código y la infraestructura (nombres de Topic/Subscription, nueva app setting, cambio de subred) se resuelve con un PR humano normal en ambos repos — no hay disparo automático entre ellos (ver ADR-01).

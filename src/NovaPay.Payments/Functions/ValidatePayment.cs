using System.Net;
using System.Text.Json;
using Azure.Messaging.ServiceBus;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;
using NovaPay.Payments.Data;
using NovaPay.Payments.Models;

namespace NovaPay.Payments.Functions;

/// <summary>
/// HTTP trigger, ruta "confirmations" para que la ruta final del Function App
/// (prefijo por defecto "api") sea /api/confirmations — la misma ruta que
/// Azure API Management reenvia al backend (apim-novapay-{env}, operacion
/// POST /confirmations sobre https://{host}/api).
/// </summary>
public sealed class ValidatePayment
{
    private readonly TransactionalNotificationsRepository _notifications;
    private readonly AccountValidationService _accountValidation;
    private readonly ServiceBusSender _serviceBusSender;
    private readonly ILogger<ValidatePayment> _logger;

    public ValidatePayment(
        TransactionalNotificationsRepository notifications,
        AccountValidationService accountValidation,
        ServiceBusSender serviceBusSender,
        ILogger<ValidatePayment> logger)
    {
        _notifications = notifications;
        _accountValidation = accountValidation;
        _serviceBusSender = serviceBusSender;
        _logger = logger;
    }

    [Function(nameof(ValidatePayment))]
    public async Task<HttpResponseData> RunAsync(
        [HttpTrigger(AuthorizationLevel.Function, "post", Route = "confirmations")] HttpRequestData req,
        CancellationToken cancellationToken)
    {
        PaymentConfirmationRequest? request;
        try
        {
            request = await JsonSerializer.DeserializeAsync<PaymentConfirmationRequest>(
                req.Body, cancellationToken: cancellationToken);
        }
        catch (JsonException)
        {
            return await BadRequestAsync(req, "Body invalido: no se pudo interpretar como JSON.", cancellationToken);
        }

        if (request is null || !request.IsStructurallyValid())
        {
            return await BadRequestAsync(req, "Body invalido: faltan campos requeridos o tienen formato incorrecto.", cancellationToken);
        }

        if (await _notifications.ExistsAsync(request.TransactionId, cancellationToken))
        {
            _logger.LogInformation("TransactionId {TransactionId} ya fue procesado, respondiendo 409.", request.TransactionId);
            var conflict = req.CreateResponse(HttpStatusCode.Conflict);
            await conflict.WriteAsJsonAsync(new { transactionId = request.TransactionId, status = "already_processed" }, cancellationToken);
            return conflict;
        }

        var validation = await _accountValidation.ValidateAsync(request, cancellationToken);
        if (!validation.IsValid)
        {
            return await BadRequestAsync(req, validation.Reason!, cancellationToken);
        }

        var paymentEvent = new PaymentValidatedEvent
        {
            TransactionId = request.TransactionId,
            SourceAccount = request.SourceAccount,
            DestinationAccount = request.DestinationAccount,
            Amount = request.Amount,
            Currency = request.Currency,
            Timestamp = DateTimeOffset.UtcNow,
        };

        // Envio directo con el SDK (ServiceBusSender), no [ServiceBusOutput]
        // sobre ServiceBusMessage: ese tipo no esta soportado como output
        // binding en el modelo isolated worker, y terminaba publicando
        // metadata interna del SDK en vez del body real. MessageId =
        // transactionId activa la deduplicacion nativa de Service Bus
        // (ventana configurada en messaging-servicebus/main.tf).
        //
        // sourceInstance (ADR-03 U4): estampa qué instancia física envió
        // el mensaje (WEBSITE_SITE_NAME, ambiental por Function App —
        // "func-novapay-pagos-{env}" o "-canary-{env}"). El filtro SQL de
        // cada Subscription del Topic lo usa para enrutar el mensaje
        // únicamente al ProcessPayment de esa misma instancia — el
        // aislamiento real ocurre ahí, no en este productor.
        var message = new ServiceBusMessage(JsonSerializer.SerializeToUtf8Bytes(paymentEvent))
        {
            MessageId = paymentEvent.TransactionId.ToString(),
            ContentType = "application/json",
        };
        message.ApplicationProperties["sourceInstance"] =
            Environment.GetEnvironmentVariable("WEBSITE_SITE_NAME")
                ?? throw new InvalidOperationException("Falta WEBSITE_SITE_NAME (variable ambiental de Azure Functions).");
        await _serviceBusSender.SendMessageAsync(message, cancellationToken);

        _logger.LogInformation("Publicando PaymentValidated para {TransactionId}.", request.TransactionId);

        var accepted = req.CreateResponse(HttpStatusCode.Accepted);
        await accepted.WriteAsJsonAsync(new { transactionId = request.TransactionId, status = "pending" }, cancellationToken);

        return accepted;
    }

    private static async Task<HttpResponseData> BadRequestAsync(HttpRequestData req, string reason, CancellationToken cancellationToken)
    {
        var response = req.CreateResponse(HttpStatusCode.BadRequest);
        await response.WriteAsJsonAsync(new { error = reason }, cancellationToken);
        return response;
    }
}

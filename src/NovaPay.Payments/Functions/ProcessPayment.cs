using System.Text.Json;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using NovaPay.Payments.Data;
using NovaPay.Payments.Models;

namespace NovaPay.Payments.Functions;

/// <summary>
/// Service Bus trigger sobre la Subscription propia de esta instancia
/// (sbt-novapay-pagos-pendientes-{env}, ADR-03 U4: Topic + una
/// Subscription por instancia física, filtrada por sourceInstance —
/// reemplaza la cola única de Entrega 2). ServiceBusSubscriptionName es
/// específico de cada Function App (estable/canary); ServiceBusTopicName
/// es el mismo Topic para ambas. Modelo peek-lock: la excepcion no
/// controlada hace que el runtime abandone el mensaje (Service Bus
/// incrementa DeliveryCount y reintenta segun la politica de host.json /
/// max_delivery_count de la Subscription en Terraform).
/// </summary>
public sealed class ProcessPayment
{
    private readonly TransactionalNotificationsRepository _notifications;
    private readonly ILogger<ProcessPayment> _logger;

    public ProcessPayment(TransactionalNotificationsRepository notifications, ILogger<ProcessPayment> logger)
    {
        _notifications = notifications;
        _logger = logger;
    }

    [Function(nameof(ProcessPayment))]
    public async Task RunAsync(
        [ServiceBusTrigger("%ServiceBusTopicName%", "%ServiceBusSubscriptionName%", Connection = "serviceBusConnection")] string messageBody,
        CancellationToken cancellationToken)
    {
        PaymentValidatedEvent paymentEvent;
        try
        {
            paymentEvent = JsonSerializer.Deserialize<PaymentValidatedEvent>(messageBody)
                ?? throw new JsonException("El mensaje se deserializo como null.");
        }
        catch (JsonException ex)
        {
            // Error permanente: un mensaje mal formado no se va a arreglar
            // solo reintentando. Se registra y se completa (no se relanza)
            // para que no agote los 5 intentos contra un payload invalido.
            _logger.LogError(ex, "Mensaje PaymentValidated invalido, se descarta sin reintentar. Body: {Body}", messageBody);
            return;
        }

        var inserted = await _notifications.TryInsertAsync(paymentEvent, cancellationToken);
        if (!inserted)
        {
            // Segunda capa de idempotencia (UNIQUE TransactionId): ya se proceso
            // antes, ya sea por una entrega duplicada real o por un reintento
            // sobre un mensaje cuyo lock expiro despues de escribir. No es un
            // error — se completa el mensaje sin duplicar el movimiento.
            _logger.LogInformation("TransactionId {TransactionId} ya estaba registrado, mensaje tratado como duplicado.", paymentEvent.TransactionId);
            return;
        }

        // Notificacion transaccional simulada (sin proveedor externo real,
        // ver documento guia - arq serverless.md, seccion 7).
        await _notifications.MarkAsSentAsync(paymentEvent.TransactionId, cancellationToken);

        _logger.LogInformation("Pago {TransactionId} procesado y notificacion registrada.", paymentEvent.TransactionId);

        // Errores transitorios (timeout de red, SQL momentaneamente no
        // disponible) no se capturan aqui a proposito: deben propagarse para
        // que el runtime abandone el mensaje y Service Bus lo reintente.
    }
}

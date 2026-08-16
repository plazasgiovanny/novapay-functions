namespace NovaPay.Payments.Models;

/// <summary>
/// Evento de dominio publicado por ValidatePayment en sbq-novapay-pagos-pendientes-{env}
/// y consumido por ProcessPayment. Esquema fijado en documento guia - arq serverless.md, seccion 2.
/// </summary>
public sealed class PaymentValidatedEvent
{
    public string EventType { get; set; } = "PaymentValidated";
    public Guid TransactionId { get; set; }
    public string SourceAccount { get; set; } = string.Empty;
    public string DestinationAccount { get; set; } = string.Empty;
    public decimal Amount { get; set; }
    public string Currency { get; set; } = string.Empty;
    public DateTimeOffset Timestamp { get; set; }
}

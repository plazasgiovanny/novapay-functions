namespace NovaPay.Payments.Models;

/// <summary>
/// Body de POST /confirmations, recibido por ValidatePayment.
/// Contrato fijado en documento guia - arq serverless.md, seccion 2.
/// </summary>
public sealed class PaymentConfirmationRequest
{
    public Guid TransactionId { get; set; }
    public string SourceAccount { get; set; } = string.Empty;
    public string DestinationAccount { get; set; } = string.Empty;
    public decimal Amount { get; set; }
    public string Currency { get; set; } = string.Empty;

    public bool IsStructurallyValid()
    {
        return TransactionId != Guid.Empty
            && !string.IsNullOrWhiteSpace(SourceAccount)
            && !string.IsNullOrWhiteSpace(DestinationAccount)
            && Amount > 0
            && !string.IsNullOrWhiteSpace(Currency);
    }
}

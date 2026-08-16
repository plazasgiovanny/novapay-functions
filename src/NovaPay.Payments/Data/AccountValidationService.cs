using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using NovaPay.Payments.Models;

namespace NovaPay.Payments.Data;

/// <summary>
/// Valida sourceAccount/amount/limites antes de publicar PaymentValidated.
///
/// PENDIENTE: el nombre real de la(s) tabla(s) de cuentas/movimientos
/// (esquema transaccional ya existente) no esta confirmado todavia —
/// ver sql/002_notificaciones_transaccionales.sql linea 79 del repo de
/// infraestructura. Mientras tanto, esta clase solo aplica una validacion
/// de limite maximo configurable (MaxTransactionAmount) y NO confirma que
/// sourceAccount exista realmente en el core bancario. Reemplazar el
/// cuerpo de ValidateAsync por una consulta real en cuanto se confirme
/// el nombre de la tabla.
/// </summary>
public sealed class AccountValidationService
{
    private readonly decimal _maxTransactionAmount;
    private readonly ILogger<AccountValidationService> _logger;

    public AccountValidationService(IConfiguration configuration, ILogger<AccountValidationService> logger)
    {
        _maxTransactionAmount = configuration.GetValue("Payments:MaxTransactionAmount", 50_000_000m);
        _logger = logger;
    }

    public Task<AccountValidationResult> ValidateAsync(PaymentConfirmationRequest request, CancellationToken cancellationToken)
    {
        _logger.LogWarning(
            "Validacion de cuenta {SourceAccount} contra el core bancario aun no implementada (tabla real pendiente de confirmar) — solo se aplica el limite maximo configurado.",
            request.SourceAccount);

        if (request.Amount > _maxTransactionAmount)
        {
            return Task.FromResult(AccountValidationResult.Invalid($"El monto excede el limite maximo permitido ({_maxTransactionAmount})."));
        }

        return Task.FromResult(AccountValidationResult.Valid());
    }
}

public sealed record AccountValidationResult(bool IsValid, string? Reason)
{
    public static AccountValidationResult Valid() => new(true, null);
    public static AccountValidationResult Invalid(string reason) => new(false, reason);
}

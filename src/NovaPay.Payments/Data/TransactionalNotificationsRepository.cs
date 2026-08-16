using Microsoft.Data.SqlClient;
using NovaPay.Payments.Models;

namespace NovaPay.Payments.Data;

/// <summary>
/// Acceso a dbo.TransactionalNotifications (esquema propuesto en
/// sql/002_notificaciones_transaccionales.sql del repo de infraestructura).
/// La restriccion UNIQUE(TransactionId) es la segunda capa de idempotencia:
/// esta clase no reimplementa esa logica, solo interpreta el error 2627/2601
/// que SQL Server lanza cuando se viola.
/// </summary>
public sealed class TransactionalNotificationsRepository
{
    private const int UniqueConstraintViolation = 2627;
    private const int UniqueIndexViolation = 2601;

    private readonly SqlConnectionFactory _connectionFactory;

    public TransactionalNotificationsRepository(SqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /// <summary>Usado por ValidatePayment para responder 409 si el transactionId ya fue procesado.</summary>
    public async Task<bool> ExistsAsync(Guid transactionId, CancellationToken cancellationToken)
    {
        await using var connection = await _connectionFactory.OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT 1 FROM dbo.TransactionalNotifications WHERE TransactionId = @TransactionId";
        command.Parameters.AddWithValue("@TransactionId", transactionId);

        var result = await command.ExecuteScalarAsync(cancellationToken);
        return result is not null;
    }

    /// <summary>
    /// Usado por ProcessPayment. Devuelve false (sin lanzar) si el TransactionId
    /// ya existia — la funcion interpreta eso como "ya procesado", no como error.
    /// </summary>
    public async Task<bool> TryInsertAsync(PaymentValidatedEvent paymentEvent, CancellationToken cancellationToken)
    {
        await using var connection = await _connectionFactory.OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText = """
            INSERT INTO dbo.TransactionalNotifications
                (TransactionId, SourceAccount, DestinationAccount, Amount, Channel, Status)
            VALUES
                (@TransactionId, @SourceAccount, @DestinationAccount, @Amount, @Channel, @Status)
            """;
        command.Parameters.AddWithValue("@TransactionId", paymentEvent.TransactionId);
        command.Parameters.AddWithValue("@SourceAccount", paymentEvent.SourceAccount);
        command.Parameters.AddWithValue("@DestinationAccount", paymentEvent.DestinationAccount);
        command.Parameters.AddWithValue("@Amount", paymentEvent.Amount);
        command.Parameters.AddWithValue("@Channel", "push");
        command.Parameters.AddWithValue("@Status", "pending");

        try
        {
            await command.ExecuteNonQueryAsync(cancellationToken);
            return true;
        }
        catch (SqlException ex) when (ex.Number is UniqueConstraintViolation or UniqueIndexViolation)
        {
            return false;
        }
    }

    /// <summary>
    /// Simula el envio de la notificacion transaccional (sin proveedor externo
    /// real de SMS/correo/push — decision de alcance documentada en
    /// documento guia - arq serverless.md, seccion 7).
    /// </summary>
    public async Task MarkAsSentAsync(Guid transactionId, CancellationToken cancellationToken)
    {
        await using var connection = await _connectionFactory.OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText = """
            UPDATE dbo.TransactionalNotifications
            SET Status = 'sent', SentAt = SYSUTCDATETIME()
            WHERE TransactionId = @TransactionId
            """;
        command.Parameters.AddWithValue("@TransactionId", transactionId);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }
}

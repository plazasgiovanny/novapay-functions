using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;

namespace NovaPay.Payments.Data;

/// <summary>
/// Abre conexiones a sqldb-novapay-core-{env} autenticando con la identidad
/// administrada del Function App (Authentication=Active Directory Default),
/// sin cadena de conexion con usuario/contrasena. Requiere que el usuario
/// contenido AAD ya exista (sql/002_notificaciones_transaccionales.sql,
/// seccion 2, en el repo de infraestructura).
/// </summary>
public sealed class SqlConnectionFactory
{
    private readonly string _connectionString;

    public SqlConnectionFactory(IConfiguration configuration)
    {
        var serverFqdn = configuration["SqlServer:Fqdn"]
            ?? throw new InvalidOperationException("Falta la configuracion SqlServer__Fqdn.");
        var database = configuration["SqlServer:Database"]
            ?? throw new InvalidOperationException("Falta la configuracion SqlServer__Database.");

        _connectionString =
            $"Server=tcp:{serverFqdn},1433;Database={database};" +
            "Authentication=Active Directory Default;Encrypt=True;TrustServerCertificate=False;";
    }

    public async Task<SqlConnection> OpenAsync(CancellationToken cancellationToken)
    {
        var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);
        return connection;
    }
}

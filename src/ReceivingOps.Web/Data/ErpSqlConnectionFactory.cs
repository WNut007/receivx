using System.Data;
using Microsoft.Data.SqlClient;

namespace ReceivingOps.Web.Data;

public class ErpSqlConnectionFactory : IErpDbConnectionFactory
{
    private readonly string? _cs;

    public ErpSqlConnectionFactory(IConfiguration config)
    {
        // Section-keyed lookup (ErpDb:ConnectionString) — matches the
        // user-secrets layout. Don't reuse ConnectionStrings:* because that
        // namespace is reserved for the local Receivx DB and other framework
        // conveniences (Hangfire, etc.).
        _cs = config["ErpDb:ConnectionString"];
    }

    public IDbConnection Create()
    {
        if (string.IsNullOrWhiteSpace(_cs))
            throw new InvalidOperationException(
                "ErpDb:ConnectionString is not configured. Set it via " +
                "`dotnet user-secrets set ErpDb:ConnectionString ...` " +
                "in dev, or via environment variable in production.");
        return new SqlConnection(_cs);
    }
}

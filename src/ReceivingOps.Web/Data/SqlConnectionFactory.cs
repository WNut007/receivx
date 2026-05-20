using System.Data;
using Microsoft.Data.SqlClient;

namespace ReceivingOps.Web.Data;

public class SqlConnectionFactory : IDbConnectionFactory
{
    private readonly string _cs;

    public SqlConnectionFactory(IConfiguration config)
    {
        _cs = config.GetConnectionString("Default")
            ?? throw new InvalidOperationException("Connection string 'Default' missing");
    }

    public IDbConnection Create() => new SqlConnection(_cs);
}

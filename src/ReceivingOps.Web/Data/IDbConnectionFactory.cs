using System.Data;

namespace ReceivingOps.Web.Data;

public interface IDbConnectionFactory
{
    IDbConnection Create();
}

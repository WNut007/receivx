using System.Data;

namespace ReceivingOps.Web.Data;

/// <summary>
/// Phase 10.1 — connection factory for the ERP source DB (read-only).
///
/// <para>Intentionally a separate type from <see cref="IDbConnectionFactory"/>
/// even though both return <see cref="IDbConnection"/>. The two factories
/// point at different hosts, hold different credentials, and have different
/// lifetimes: the Receivx DB is the app's home (read/write, local-network,
/// always required), while the ERP DB is an external system (read-only,
/// remote, optional in dev). Mixing them in one interface would let a
/// repository accidentally write to the ERP host through a misregistered
/// factory.</para>
///
/// <para>Connection string lives in user-secrets under
/// <c>ErpDb:ConnectionString</c>. The factory throws at <see cref="Create"/>
/// time (not at construction) if the secret is missing — keeps app startup
/// successful when ERP integration is disabled (<c>ErpSync:Enabled=false</c>).</para>
/// </summary>
public interface IErpDbConnectionFactory
{
    IDbConnection Create();
}

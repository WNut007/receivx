using Microsoft.Data.SqlClient;

namespace ReceivingOps.Web.Data;

/// <summary>
/// Development-only refusal to start against anything but the local dev database.
///
/// Why this exists: this project's documented precedence chain is
/// <c>env vars &gt; DB &gt; user-secrets &gt; appsettings.json</c>
/// (docs/configuration.md). A User-level <c>ConnectionStrings__Default</c>
/// environment variable therefore silently outranks the user-secret every
/// developer assumes is in force, and a plain <c>dotnet run</c> drives whatever
/// that variable points at. RECEIVINGOPS_HARDENING.md records the same hazard
/// arriving once before through user-secrets itself; it recurred through the
/// environment.
///
/// Config alone cannot fix it, because the machine variable is legitimately
/// required by a different application and has to stay. So the pin is applied in
/// three places that between them cover every way the app starts —
/// Properties/launchSettings.json (F5 and <c>dotnet run</c> with a profile),
/// tools/run-smokes.ps1 (scripted runs, which never read launchSettings) — and
/// this guard, which is the backstop for the case both of those miss.
///
/// Deliberately Development-only: production is SUPPOSED to point somewhere
/// else, and <see cref="Verify"/> is a no-op there.
/// </summary>
public static class DevDatabaseGuard
{
    /// <summary>The only database a Development run may open.</summary>
    public const string ExpectedDatabase = "ReceivingOps";

    /// <summary>
    /// Server names that count as "this machine". <see cref="Environment.MachineName"/>
    /// is included so the guard works on any developer's box, not just the one
    /// whose hostname happens to be hard-coded in the docs.
    /// </summary>
    private static readonly string[] LocalAliases =
    {
        "localhost", ".", "(local)", "(localdb)", "127.0.0.1", "::1",
    };

    /// <summary>
    /// Throws when <c>ConnectionStrings:Default</c> resolves to a host other than
    /// this machine, or to a database other than <see cref="ExpectedDatabase"/>.
    /// Call this BEFORE anything can open a connection.
    /// </summary>
    /// <remarks>
    /// The failure names the configuration provider that supplied the value,
    /// because "why is it pointing there?" is the actual question a developer
    /// has at that moment, and the answer is usually a provider they forgot
    /// outranks the one they edited. Server and database are reported; the
    /// connection string itself never is, since it may carry a password.
    /// </remarks>
    public static void Verify(IConfiguration configuration)
    {
        var connectionString = configuration.GetConnectionString("Default");
        // Missing entirely is a different failure with its own message, raised
        // by SqlConnectionFactory / the Hangfire wiring. Don't pre-empt it.
        if (string.IsNullOrWhiteSpace(connectionString)) return;

        string server, database;
        try
        {
            var parsed = new SqlConnectionStringBuilder(connectionString);
            server = parsed.DataSource ?? "";
            database = parsed.InitialCatalog ?? "";
        }
        catch (ArgumentException)
        {
            // Unparseable: let the real connection attempt produce the error.
            // Never echo the raw string — it may contain a password.
            return;
        }

        var serverOk = IsLocal(server);
        var databaseOk = string.Equals(database, ExpectedDatabase, StringComparison.OrdinalIgnoreCase);
        if (serverOk && databaseOk) return;

        var wrong = !serverOk && !databaseOk ? "server and database"
                  : !serverOk ? "server"
                  : "database";

        var message =
            $"Refusing to start: ConnectionStrings:Default names a non-local {wrong}.{Environment.NewLine}" +
            $"  Server   : {(string.IsNullOrEmpty(server) ? "(none)" : server)}" +
            $"{(serverOk ? "" : "   <- expected this machine (" + Environment.MachineName + ", localhost, .)")}{Environment.NewLine}" +
            $"  Database : {(string.IsNullOrEmpty(database) ? "(none)" : database)}" +
            $"{(databaseOk ? "" : "   <- expected " + ExpectedDatabase)}{Environment.NewLine}" +
            $"  Supplied by: {DescribeProvider(configuration, "ConnectionStrings:Default")}{Environment.NewLine}" +
            $"A Development run must use the local database. If a machine-level " +
            $"ConnectionStrings__Default environment variable is the source, it outranks " +
            $"user-secrets: start through a launch profile (dotnet run --launch-profile http), " +
            $"or pin $env:ConnectionStrings__Default for the process as tools/run-smokes.ps1 does.";

        // Written explicitly as well as thrown: an unhandled startup exception is
        // easy to lose in a host's own framing, and this message is the whole
        // point of the guard.
        Console.Error.WriteLine(message);
        throw new InvalidOperationException(message);
    }

    /// <summary>
    /// True when the server name refers to this machine. Tolerates the forms a
    /// connection string may carry: a <c>tcp:</c> prefix, a <c>,port</c> suffix,
    /// and a <c>\INSTANCE</c> suffix.
    /// </summary>
    private static bool IsLocal(string dataSource)
    {
        if (string.IsNullOrWhiteSpace(dataSource)) return false;

        var host = dataSource.Trim();
        if (host.StartsWith("tcp:", StringComparison.OrdinalIgnoreCase)) host = host[4..];
        var comma = host.IndexOf(',');
        if (comma >= 0) host = host[..comma];
        var backslash = host.IndexOf('\\');
        if (backslash >= 0) host = host[..backslash];
        host = host.Trim();

        if (string.Equals(host, Environment.MachineName, StringComparison.OrdinalIgnoreCase)) return true;
        foreach (var alias in LocalAliases)
            if (string.Equals(host, alias, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }

    /// <summary>
    /// Names the configuration provider that supplied the key. Providers are
    /// ordered low-to-high precedence, so the LAST one holding the key is the
    /// one in force; any earlier holders are reported as overridden, which is
    /// what makes the "but I set it in user-secrets" case legible.
    /// </summary>
    private static string DescribeProvider(IConfiguration configuration, string key)
    {
        if (configuration is not IConfigurationRoot root) return "unknown (configuration is not a root)";

        var holders = new List<string>();
        foreach (var provider in root.Providers)
            if (provider.TryGet(key, out _))
                holders.Add(provider.ToString() ?? provider.GetType().Name);

        if (holders.Count == 0) return "no provider reported the key";
        if (holders.Count == 1) return holders[0];
        return $"{holders[^1]}, overriding: {string.Join(" | ", holders.Take(holders.Count - 1))}";
    }
}

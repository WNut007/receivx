using Dapper;
using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Data.Repositories;

public class AppSettingsRepository : IAppSettingsRepository
{
    private readonly IDbConnectionFactory _factory;

    public AppSettingsRepository(IDbConnectionFactory factory) => _factory = factory;

    private const string SelectColumns = @"
        [Key], [Value], EncryptedValue, IsSecret,
        UpdatedAt, UpdatedBy, PreviousValueHash";

    public async Task<AppSettingRow?> GetAsync(string key, CancellationToken ct = default)
    {
        const string sql = "SELECT " + SelectColumns + " FROM dbo.AppSettings WHERE [Key] = @Key;";
        using var conn = _factory.Create();
        return await conn.QuerySingleOrDefaultAsync<AppSettingRow>(
            new CommandDefinition(sql, new { Key = key }, cancellationToken: ct));
    }

    public async Task<IReadOnlyList<AppSettingRow>> GetSectionAsync(string prefix, CancellationToken ct = default)
    {
        // LIKE escape: ':' is not a LIKE wildcard so the concatenation is safe
        // without an ESCAPE clause. Section prefix is a controlled string ("Smtp",
        // "Exports", "ErpSync", "ErpDb") set in Program.cs / seeder — never user input.
        const string sql = @"
            SELECT " + SelectColumns + @"
            FROM   dbo.AppSettings
            WHERE  [Key] LIKE @Prefix + ':%'
            ORDER  BY [Key];";
        using var conn = _factory.Create();
        var rows = await conn.QueryAsync<AppSettingRow>(
            new CommandDefinition(sql, new { Prefix = prefix }, cancellationToken: ct));
        return rows.AsList();
    }

    public async Task UpsertAsync(string key, string? value, byte[]? encryptedValue, bool isSecret,
        string updatedBy, string? previousValueHash, CancellationToken ct = default)
    {
        // MERGE keeps the call atomic without an explicit transaction. The
        // CHECK constraint on the table enforces Value-XOR-EncryptedValue per
        // IsSecret so even a buggy caller can't corrupt the schema invariant.
        const string sql = @"
            MERGE dbo.AppSettings AS tgt
            USING (SELECT @Key AS [Key]) AS src
              ON tgt.[Key] = src.[Key]
            WHEN MATCHED THEN UPDATE SET
                [Value]            = @Value,
                EncryptedValue     = @EncryptedValue,
                IsSecret           = @IsSecret,
                UpdatedAt          = SYSUTCDATETIME(),
                UpdatedBy          = @UpdatedBy,
                PreviousValueHash  = @PreviousValueHash
            WHEN NOT MATCHED THEN INSERT
                ([Key], [Value], EncryptedValue, IsSecret, UpdatedAt, UpdatedBy, PreviousValueHash)
              VALUES
                (@Key,  @Value,  @EncryptedValue, @IsSecret, SYSUTCDATETIME(), @UpdatedBy, @PreviousValueHash);";
        using var conn = _factory.Create();
        await conn.ExecuteAsync(new CommandDefinition(sql, new
        {
            Key = key,
            Value = value,
            EncryptedValue = encryptedValue,
            IsSecret = isSecret,
            UpdatedBy = updatedBy,
            PreviousValueHash = previousValueHash,
        }, cancellationToken: ct));
    }

    public async Task<int> DeleteAsync(string key, CancellationToken ct = default)
    {
        const string sql = "DELETE FROM dbo.AppSettings WHERE [Key] = @Key;";
        using var conn = _factory.Create();
        return await conn.ExecuteAsync(
            new CommandDefinition(sql, new { Key = key }, cancellationToken: ct));
    }

    public async Task<int> CountAsync(CancellationToken ct = default)
    {
        const string sql = "SELECT COUNT(*) FROM dbo.AppSettings;";
        using var conn = _factory.Create();
        return await conn.ExecuteScalarAsync<int>(
            new CommandDefinition(sql, cancellationToken: ct));
    }
}

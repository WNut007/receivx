using System.Data;
using Dapper;
using ReceivingOps.Web.Models.Entities;

namespace ReceivingOps.Web.Data.Repositories;

public class PullSignatureRepository : IPullSignatureRepository
{
    private readonly IDbConnectionFactory _factory;

    public PullSignatureRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IReadOnlyList<PullSignature>> GetByPullAsync(Guid pullId, CancellationToken ct = default)
    {
        const string sql = @"
            SELECT  Id, PullId, Party, WarehouseId, SignerUserId, SignerName, SignedAt
            FROM    dbo.PullSignatures
            WHERE   PullId = @PullId
            ORDER BY Party;";

        using var conn = _factory.Create();
        var rows = await conn.QueryAsync<PullSignature>(
            new CommandDefinition(sql, new { PullId = pullId }, cancellationToken: ct));
        return rows.AsList();
    }

    public async Task<bool> ExistsAsync(IDbConnection conn, IDbTransaction tx,
        Guid pullId, string party, CancellationToken ct = default)
    {
        const string sql = @"
            SELECT 1
            FROM   dbo.PullSignatures WITH (UPDLOCK, HOLDLOCK)
            WHERE  PullId = @PullId AND Party = @Party;";

        var hit = await conn.ExecuteScalarAsync<int?>(new CommandDefinition(
            sql, new { PullId = pullId, Party = party }, transaction: tx, cancellationToken: ct));
        return hit.HasValue;
    }

    public async Task<PullSignature> InsertAsync(IDbConnection conn, IDbTransaction tx,
        PullSignature s, CancellationToken ct = default)
    {
        // Id (NEWID) + SignedAt (SYSUTCDATETIME) are DB defaults — OUTPUT them back.
        const string sql = @"
            INSERT INTO dbo.PullSignatures (PullId, Party, WarehouseId, SignerUserId, SignerName)
            OUTPUT INSERTED.Id, INSERTED.SignedAt
            VALUES (@PullId, @Party, @WarehouseId, @SignerUserId, @SignerName);";

        var ins = await conn.QuerySingleAsync<InsertedRow>(new CommandDefinition(
            sql,
            new { s.PullId, s.Party, s.WarehouseId, s.SignerUserId, s.SignerName },
            transaction: tx, cancellationToken: ct));

        s.Id = ins.Id;
        s.SignedAt = ins.SignedAt;
        return s;
    }

    private sealed class InsertedRow
    {
        public Guid Id { get; set; }
        public DateTime SignedAt { get; set; }
    }
}

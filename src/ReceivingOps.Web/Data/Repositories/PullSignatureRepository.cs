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
            SELECT  Id, PullId, Party, WarehouseId, SignerUserId, SignerName, SignedAt, SignatureSvg
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
            INSERT INTO dbo.PullSignatures (PullId, Party, WarehouseId, SignerUserId, SignerName, SignatureSvg)
            OUTPUT INSERTED.Id, INSERTED.SignedAt
            VALUES (@PullId, @Party, @WarehouseId, @SignerUserId, @SignerName, @SignatureSvg);";

        var ins = await conn.QuerySingleAsync<InsertedRow>(new CommandDefinition(
            sql,
            new { s.PullId, s.Party, s.WarehouseId, s.SignerUserId, s.SignerName, s.SignatureSvg },
            transaction: tx, cancellationToken: ct));

        s.Id = ins.Id;
        s.SignedAt = ins.SignedAt;
        return s;
    }

    public async Task<bool> UpsertWarehouseAsync(IDbConnection conn, IDbTransaction tx,
        Guid pullId, Guid warehouseId, Guid signerUserId, string signerName,
        DateTime signedAt, string? signatureSvg, CancellationToken ct = default)
    {
        // UPDATE-then-conditional-INSERT (rather than MERGE) for the (PullId,'Warehouse')
        // grain. Serialized by the close tx's UPDLOCK on the Pulls row — only one close
        // can run per pull — with UQ_PullSig_Party as the hard backstop. SignedAt is set
        // explicitly to the close timestamp (not the SYSUTCDATETIME default). Phase 8:
        // SignatureSvg carries the drawn close-pad image so the Warehouse box renders
        // a drawing (D1) — uniform with Customer/Production.
        const string sql = @"
            UPDATE dbo.PullSignatures
               SET WarehouseId  = @WarehouseId,
                   SignerUserId = @SignerUserId,
                   SignerName   = @SignerName,
                   SignedAt     = @SignedAt,
                   SignatureSvg = @SignatureSvg
             WHERE PullId = @PullId AND Party = 'Warehouse';

            IF @@ROWCOUNT = 0
            BEGIN
                INSERT INTO dbo.PullSignatures
                    (PullId, Party, WarehouseId, SignerUserId, SignerName, SignedAt, SignatureSvg)
                VALUES (@PullId, 'Warehouse', @WarehouseId, @SignerUserId, @SignerName, @SignedAt, @SignatureSvg);
                SELECT 1;   -- inserted
            END
            ELSE SELECT 0;  -- updated";

        var inserted = await conn.ExecuteScalarAsync<int>(new CommandDefinition(
            sql,
            new { PullId = pullId, WarehouseId = warehouseId, SignerUserId = signerUserId,
                  SignerName = signerName, SignedAt = signedAt, SignatureSvg = signatureSvg },
            transaction: tx, cancellationToken: ct));
        return inserted == 1;
    }

    private sealed class InsertedRow
    {
        public Guid Id { get; set; }
        public DateTime SignedAt { get; set; }
    }
}

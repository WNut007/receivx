using System.Security.Claims;
using Dapper;
using Microsoft.Data.SqlClient;
using ReceivingOps.Web.Data;
using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Services;

public class PurchaseOrderAdminService : IPurchaseOrderAdminService
{
    private readonly IDbConnectionFactory _factory;
    private readonly IAuditService _audit;
    private readonly IHttpContextAccessor _httpContext;

    public PurchaseOrderAdminService(IDbConnectionFactory factory, IAuditService audit, IHttpContextAccessor httpContext)
    {
        _factory = factory;
        _audit = audit;
        _httpContext = httpContext;
    }

    // ====================================================================
    // CREATE
    // ====================================================================
    public async Task<Guid> CreateAsync(PoCreateRequest req, CancellationToken ct = default)
    {
        ValidateCreate(req);

        var actorId = CurrentUserId();

        using var conn = _factory.Create();
        conn.Open();
        using var tx = conn.BeginTransaction();
        try
        {
            // PoNumber uniqueness — DB UNIQUE is the last line of defense; pre-check gives a friendlier error.
            var exists = await conn.ExecuteScalarAsync<int?>(new CommandDefinition(
                "SELECT 1 FROM dbo.PurchaseOrders WHERE PoNumber = @PoNumber;",
                new { req.PoNumber }, transaction: tx, cancellationToken: ct));
            if (exists.HasValue)
                throw new BusinessException($"PO number '{req.PoNumber}' is already taken");

            // §3.5 — when PullId is set, validate the link is sound BEFORE we insert.
            //   - Pull must exist (FK_PO_Pull would also catch this, but we want a friendlier message).
            //   - Pull.Status must not be 'closed' (procurement shouldn't add capacity to a finished pull).
            //   - Pull.WarehouseId must match req.WarehouseId (consistency — strict-mode FIFO joins on warehouse anyway).
            if (req.PullId is { } pullId)
            {
                var pull = await conn.QuerySingleOrDefaultAsync<PullLinkProbe>(new CommandDefinition(@"
                    SELECT Id, PullNumber, Status, WarehouseId
                    FROM   dbo.Pulls WITH (UPDLOCK, ROWLOCK)
                    WHERE  Id = @PullId;",
                    new { PullId = pullId }, transaction: tx, cancellationToken: ct))
                    ?? throw new BusinessException($"Linked pull {pullId} does not exist");

                if (string.Equals(pull.Status, "closed", StringComparison.Ordinal))
                    throw new BusinessException($"Cannot link PO to closed pull {pull.PullNumber}");

                if (pull.WarehouseId != req.WarehouseId)
                    throw new BusinessException(
                        $"Warehouse mismatch: PO is for warehouse {req.WarehouseId} but pull {pull.PullNumber} is for warehouse {pull.WarehouseId}");
            }

            // WarehouseId must point to an existing warehouse (FK enforces).
            var newId = await conn.QuerySingleAsync<Guid>(new CommandDefinition(@"
                INSERT INTO dbo.PurchaseOrders (Id, PoNumber, WarehouseId, PullId, VendorCode, VendorName,
                                                OrderDate, ExpectedDate, Status, Notes, CreatedBy, CreatedAt)
                OUTPUT INSERTED.Id
                VALUES (NEWID(), @PoNumber, @WarehouseId, @PullId, @VendorCode, @VendorName,
                        @OrderDate, @ExpectedDate, 'open', @Notes, @CreatedBy, SYSUTCDATETIME());",
                new
                {
                    req.PoNumber, req.WarehouseId, req.PullId,
                    req.VendorCode, req.VendorName,
                    req.OrderDate, req.ExpectedDate, req.Notes,
                    CreatedBy = actorId,
                }, transaction: tx, cancellationToken: ct));

            foreach (var line in req.Lines)
            {
                ValidateLine(line);
                await conn.ExecuteAsync(new CommandDefinition(@"
                    INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty)
                    VALUES (NEWID(), @PoId, @LineNumber, @ItemCode, @Description, @OrderedQty, 0);",
                    new
                    {
                        PoId = newId,
                        line.LineNumber, line.ItemCode, line.Description, line.OrderedQty,
                    }, transaction: tx, cancellationToken: ct));
            }

            var linkSuffix = req.PullId is null ? "" : $" linked to pull {req.PullId}";
            await _audit.WriteAsync(conn, tx, "create", "PurchaseOrder", newId.ToString(),
                $"Created PO {req.PoNumber} with {req.Lines.Count} line(s){linkSuffix}", ct);

            tx.Commit();
            return newId;
        }
        catch (SqlException ex) when (ex.Number is 2627 or 2601)
        {
            tx.Rollback();
            throw new BusinessException($"PO number '{req.PoNumber}' or duplicate line number conflict");
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    // ====================================================================
    // UPDATE (§7.13 immutability)
    // ====================================================================
    public async Task UpdateAsync(Guid id, PoUpdateRequest req, CancellationToken ct = default)
    {
        using var conn = _factory.Create();
        conn.Open();
        using var tx = conn.BeginTransaction();
        try
        {
            var po = await conn.QuerySingleOrDefaultAsync<PoLockRow>(new CommandDefinition(@"
                SELECT Id, PoNumber, Status, PullId
                FROM   dbo.PurchaseOrders WITH (UPDLOCK, ROWLOCK)
                WHERE  Id = @Id;",
                new { Id = id }, transaction: tx, cancellationToken: ct))
                ?? throw new NotFoundException("PO not found");

            // Defense-in-depth: a closed/canceled PO has been retired from the FIFO pool;
            // header edits would mutate a "frozen" record. The UI already disables the
            // inputs when status != 'open' (see pos.js openDetail), but the server is the
            // source of truth. Checked BEFORE the §3.5 / §7.13 rules so the error message
            // tells the operator the real reason.
            if (!string.Equals(po.Status, "open", StringComparison.Ordinal))
                throw new BusinessException(
                    $"Cannot edit a closed PO. Status is {po.Status}.");

            // §3.5 — PullId is immutable. Check this BEFORE the receipt-reference rule because
            // the immutability bar is strict in both directions (NULL→value AND value→NULL), and
            // applies even when no receipts reference the PO.
            if (req.PullId != po.PullId)
                throw new BusinessException(
                    "PO-pull link is immutable. Cancel and reissue if you need to change.");

            // §7.13 — refuse if any receipt references this PO.
            var refCount = await conn.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM dbo.Receipts WHERE PurchaseOrderId = @Id;",
                new { Id = id }, transaction: tx, cancellationToken: ct));
            if (refCount > 0)
                throw new BusinessException(
                    $"Cannot update PO {po.PoNumber}: {refCount} receipt(s) reference it. Cancel and reissue the PO instead.");

            await conn.ExecuteAsync(new CommandDefinition(@"
                UPDATE dbo.PurchaseOrders
                   SET VendorCode   = @VendorCode,
                       VendorName   = @VendorName,
                       OrderDate    = @OrderDate,
                       ExpectedDate = @ExpectedDate,
                       Notes        = @Notes
                 WHERE Id = @Id;",
                new
                {
                    Id = id, req.VendorCode, req.VendorName,
                    req.OrderDate, req.ExpectedDate, req.Notes,
                }, transaction: tx, cancellationToken: ct));

            await _audit.WriteAsync(conn, tx, "update", "PurchaseOrder", id.ToString(),
                $"Updated PO {po.PoNumber}", ct);

            tx.Commit();
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    // ====================================================================
    // CLOSE (manual — even if outstanding qty)
    // ====================================================================
    public async Task CloseAsync(Guid id, PoCloseRequest req, CancellationToken ct = default)
    {
        var reason = (req.Reason ?? "").Trim();
        if (string.IsNullOrEmpty(reason))
            throw new BusinessException("Reason is required for manual PO close");
        if (reason.Length > 500)
            throw new BusinessException("Reason exceeds 500 characters");

        using var conn = _factory.Create();
        conn.Open();
        using var tx = conn.BeginTransaction();
        try
        {
            var po = await conn.QuerySingleOrDefaultAsync<PoLockRow>(new CommandDefinition(@"
                SELECT Id, PoNumber, Status
                FROM   dbo.PurchaseOrders WITH (UPDLOCK, ROWLOCK)
                WHERE  Id = @Id;",
                new { Id = id }, transaction: tx, cancellationToken: ct))
                ?? throw new NotFoundException("PO not found");

            if (string.Equals(po.Status, "closed", StringComparison.Ordinal))
                throw new BusinessException("PO is already closed");
            if (string.Equals(po.Status, "canceled", StringComparison.Ordinal))
                throw new BusinessException("PO is canceled");

            // For audit, compute outstanding qty before closing.
            var outstanding = await conn.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT ISNULL(SUM(OrderedQty - ReceivedQty), 0) FROM dbo.PurchaseOrderLines WHERE PurchaseOrderId = @Id;",
                new { Id = id }, transaction: tx, cancellationToken: ct));

            await conn.ExecuteAsync(new CommandDefinition(@"
                UPDATE dbo.PurchaseOrders
                   SET Status   = 'closed',
                       ClosedAt = SYSUTCDATETIME()
                 WHERE Id = @Id;",
                new { Id = id }, transaction: tx, cancellationToken: ct));

            await _audit.WriteAsync(conn, tx, "close", "PurchaseOrder", id.ToString(),
                $"Manually closed PO {po.PoNumber} ({outstanding} pcs forfeited). Reason: {reason}", ct);

            tx.Commit();
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    // ====================================================================
    // ADD LINE
    // ====================================================================
    public async Task<Guid> AddLineAsync(Guid poId, PoLineCreateRequest req, CancellationToken ct = default)
    {
        ValidateLine(req);

        using var conn = _factory.Create();
        conn.Open();
        using var tx = conn.BeginTransaction();
        try
        {
            var po = await conn.QuerySingleOrDefaultAsync<PoLockRow>(new CommandDefinition(@"
                SELECT Id, PoNumber, Status
                FROM   dbo.PurchaseOrders WITH (UPDLOCK, ROWLOCK)
                WHERE  Id = @Id;",
                new { Id = poId }, transaction: tx, cancellationToken: ct))
                ?? throw new NotFoundException("PO not found");

            if (!string.Equals(po.Status, "open", StringComparison.Ordinal))
                throw new BusinessException($"Cannot add line: PO is {po.Status}");

            var newId = await conn.QuerySingleAsync<Guid>(new CommandDefinition(@"
                INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty)
                OUTPUT INSERTED.Id
                VALUES (NEWID(), @PoId, @LineNumber, @ItemCode, @Description, @OrderedQty, 0);",
                new
                {
                    PoId = poId,
                    req.LineNumber, req.ItemCode, req.Description, req.OrderedQty,
                }, transaction: tx, cancellationToken: ct));

            await _audit.WriteAsync(conn, tx, "create", "PurchaseOrderLine", newId.ToString(),
                $"Added line {req.LineNumber} ({req.ItemCode}, {req.OrderedQty} pcs) to PO {po.PoNumber}", ct);

            tx.Commit();
            return newId;
        }
        catch (SqlException ex) when (ex.Number is 2627 or 2601)
        {
            tx.Rollback();
            throw new BusinessException($"Line number {req.LineNumber} already exists on this PO");
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    // ====================================================================
    // DELETE LINE (§7.13)
    // ====================================================================
    public async Task DeleteLineAsync(Guid poId, Guid lineId, CancellationToken ct = default)
    {
        using var conn = _factory.Create();
        conn.Open();
        using var tx = conn.BeginTransaction();
        try
        {
            var line = await conn.QuerySingleOrDefaultAsync<PoLineDeleteContext>(new CommandDefinition(@"
                SELECT pol.Id, pol.PurchaseOrderId, pol.LineNumber, pol.ItemCode, po.PoNumber
                FROM   dbo.PurchaseOrderLines pol WITH (UPDLOCK, ROWLOCK)
                INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
                WHERE  pol.Id = @LineId AND pol.PurchaseOrderId = @PoId;",
                new { LineId = lineId, PoId = poId }, transaction: tx, cancellationToken: ct))
                ?? throw new NotFoundException("PO line not found");

            // §7.13 — refuse if any receipt references the line.
            var refCount = await conn.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM dbo.Receipts WHERE PurchaseOrderLineId = @LineId;",
                new { LineId = lineId }, transaction: tx, cancellationToken: ct));
            if (refCount > 0)
                throw new BusinessException(
                    $"Cannot delete PO line: {refCount} receipt(s) reference it. Cancel those receipts first.");

            await conn.ExecuteAsync(new CommandDefinition(
                "DELETE FROM dbo.PurchaseOrderLines WHERE Id = @LineId;",
                new { LineId = lineId }, transaction: tx, cancellationToken: ct));

            await _audit.WriteAsync(conn, tx, "delete", "PurchaseOrderLine", lineId.ToString(),
                $"Deleted line {line.LineNumber} ({line.ItemCode}) from PO {line.PoNumber}", ct);

            tx.Commit();
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    // ====================================================================
    // UPDATE LINE EXTENDED FIELDS (Phase 9.2)
    // ====================================================================
    public async Task UpdateLineExtendedFieldsAsync(
        Guid poId, Guid lineId, PoLineExtendedFieldsUpdateRequest req, CancellationToken ct = default)
    {
        ValidateLineExtendedFields(req);

        using var conn = _factory.Create();
        conn.Open();
        using var tx = conn.BeginTransaction();
        try
        {
            // Lock the PO header — UPDLOCK on the open-status check, ROWLOCK
            // keeps the scope tight. Mirror of LockPullAsync in §9.1.
            var po = await conn.QuerySingleOrDefaultAsync<PoLockRow>(new CommandDefinition(@"
                SELECT Id, PoNumber, Status
                FROM   dbo.PurchaseOrders WITH (UPDLOCK, ROWLOCK)
                WHERE  Id = @Id;",
                new { Id = poId }, transaction: tx, cancellationToken: ct))
                ?? throw new NotFoundException("PO not found");

            if (!string.Equals(po.Status, "open", StringComparison.Ordinal))
                throw new BusinessException(
                    $"Cannot edit line metadata on a {po.Status} PO. Reopen it first if you need to change line fields.");

            // Verify the line belongs to this PO (defense against /api/pos/{x}/lines/{y}
            // where y belongs to a different PO) + lock it.
            var line = await conn.QuerySingleOrDefaultAsync<PoLineDeleteContext>(new CommandDefinition(@"
                SELECT pol.Id, pol.PurchaseOrderId, pol.LineNumber, pol.ItemCode, @PoNumber AS PoNumber
                FROM   dbo.PurchaseOrderLines pol WITH (UPDLOCK, ROWLOCK)
                WHERE  pol.Id = @LineId AND pol.PurchaseOrderId = @PoId;",
                new { LineId = lineId, PoId = poId, PoNumber = po.PoNumber },
                transaction: tx, cancellationToken: ct))
                ?? throw new NotFoundException("PO line not found");

            await conn.ExecuteAsync(new CommandDefinition(@"
                UPDATE dbo.PurchaseOrderLines
                   SET OrderId                  = @OrderId,
                       AsnNo                    = @AsnNo,
                       KanbanNo                 = @KanbanNo,
                       VendorItem               = @VendorItem,
                       Location                 = @Location,
                       SubInventory             = @SubInventory,
                       ToLocation               = @ToLocation,
                       Building                 = @Building,
                       ProductionLine           = @ProductionLine,
                       PalletId                 = @PalletId,
                       VmiPalletId              = @VmiPalletId,
                       BatchNo                  = @BatchNo,
                       InvoiceNo                = @InvoiceNo,
                       PCCNo                    = @PCCNo,
                       ManufacturingControlNo   = @ManufacturingControlNo,
                       OrderRound               = @OrderRound,
                       ExportDeclarationNo      = @ExportDeclarationNo,
                       CustomerReferenceNo      = @CustomerReferenceNo,
                       ManufacturingReferenceNo = @ManufacturingReferenceNo,
                       Note                     = @Note
                 WHERE Id = @Id;",
                new
                {
                    Id = lineId,
                    req.OrderId, req.AsnNo, req.KanbanNo, req.VendorItem,
                    req.Location, req.SubInventory, req.ToLocation, req.Building, req.ProductionLine,
                    req.PalletId, req.VmiPalletId, req.BatchNo,
                    req.InvoiceNo, req.PCCNo, req.ManufacturingControlNo, req.OrderRound,
                    req.ExportDeclarationNo, req.CustomerReferenceNo, req.ManufacturingReferenceNo,
                    req.Note,
                }, transaction: tx, cancellationToken: ct));

            await _audit.WriteAsync(conn, tx, "update", "PurchaseOrderLine", lineId.ToString(),
                $"Updated extended fields on line {line.LineNumber} ({line.ItemCode}) of PO {po.PoNumber}", ct);

            tx.Commit();
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    // ====================================================================
    // helpers
    // ====================================================================
    // Phase 9.2 — schema is NVARCHAR(50) on all 19 short fields + NVARCHAR(500)
    // on Note. UI maxlength mirrors this so the validator catches only the
    // copy-paste-too-long edge case rather than firing on every input.
    private static void ValidateLineExtendedFields(PoLineExtendedFieldsUpdateRequest req)
    {
        static void CheckShort(string field, string? value)
        {
            if (value is not null && value.Length > 50)
                throw new BusinessException($"{field} is too long (≤ 50 chars)");
        }
        CheckShort(nameof(req.OrderId),                  req.OrderId);
        CheckShort(nameof(req.AsnNo),                    req.AsnNo);
        CheckShort(nameof(req.KanbanNo),                 req.KanbanNo);
        CheckShort(nameof(req.VendorItem),               req.VendorItem);
        CheckShort(nameof(req.Location),                 req.Location);
        CheckShort(nameof(req.SubInventory),             req.SubInventory);
        CheckShort(nameof(req.ToLocation),               req.ToLocation);
        CheckShort(nameof(req.Building),                 req.Building);
        CheckShort(nameof(req.ProductionLine),           req.ProductionLine);
        CheckShort(nameof(req.PalletId),                 req.PalletId);
        CheckShort(nameof(req.VmiPalletId),              req.VmiPalletId);
        CheckShort(nameof(req.BatchNo),                  req.BatchNo);
        CheckShort(nameof(req.InvoiceNo),                req.InvoiceNo);
        CheckShort(nameof(req.PCCNo),                    req.PCCNo);
        CheckShort(nameof(req.ManufacturingControlNo),   req.ManufacturingControlNo);
        CheckShort(nameof(req.OrderRound),               req.OrderRound);
        CheckShort(nameof(req.ExportDeclarationNo),      req.ExportDeclarationNo);
        CheckShort(nameof(req.CustomerReferenceNo),      req.CustomerReferenceNo);
        CheckShort(nameof(req.ManufacturingReferenceNo), req.ManufacturingReferenceNo);

        if (req.Note is not null && req.Note.Length > 500)
            throw new BusinessException("Note is too long (≤ 500 chars)");
    }


    private static void ValidateCreate(PoCreateRequest req)
    {
        if (string.IsNullOrWhiteSpace(req.PoNumber) || req.PoNumber.Length > 32)
            throw new BusinessException("PoNumber is required (≤ 32 chars)");
        if (req.WarehouseId == Guid.Empty)
            throw new BusinessException("WarehouseId is required");
        if (req.OrderDate == default)
            throw new BusinessException("OrderDate is required");
        if (req.Lines is null) throw new BusinessException("Lines cannot be null");
        // Duplicate LineNumber would also be caught by UQ_POL_LineNumber, but pre-check is friendlier.
        var dup = req.Lines.GroupBy(l => l.LineNumber).FirstOrDefault(g => g.Count() > 1);
        if (dup is not null)
            throw new BusinessException($"Duplicate LineNumber {dup.Key} in request");
    }

    private static void ValidateLine(PoLineCreateRequest line)
    {
        if (line.LineNumber <= 0)
            throw new BusinessException("LineNumber must be ≥ 1");
        if (string.IsNullOrWhiteSpace(line.ItemCode) || line.ItemCode.Length > 64)
            throw new BusinessException("ItemCode is required (≤ 64 chars)");
        if (string.IsNullOrWhiteSpace(line.Description) || line.Description.Length > 255)
            throw new BusinessException("Description is required (≤ 255 chars)");
        if (line.OrderedQty <= 0)
            throw new BusinessException("OrderedQty must be positive");
    }

    private Guid CurrentUserId()
    {
        var ctx = _httpContext.HttpContext
            ?? throw new InvalidOperationException("HttpContext unavailable");
        var idClaim = ctx.User.FindFirstValue(ClaimTypes.NameIdentifier);
        if (!Guid.TryParse(idClaim, out var id))
            throw new InvalidOperationException("Authenticated user has no NameIdentifier claim");
        return id;
    }

    private sealed class PoLockRow
    {
        public Guid Id { get; set; }
        public string PoNumber { get; set; } = "";
        public string Status { get; set; } = "";
        public Guid? PullId { get; set; }   // §3.5 — used by UpdateAsync to enforce immutability
    }

    private sealed class PullLinkProbe
    {
        public Guid Id { get; set; }
        public string PullNumber { get; set; } = "";
        public string Status { get; set; } = "";
        public Guid WarehouseId { get; set; }
    }

    private sealed class PoLineDeleteContext
    {
        public Guid Id { get; set; }
        public Guid PurchaseOrderId { get; set; }
        public int LineNumber { get; set; }
        public string ItemCode { get; set; } = "";
        public string PoNumber { get; set; } = "";
    }
}

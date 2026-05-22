using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Services;

/// <summary>
/// v2.1 PullItem admin write surface (retires tools/add-pull-item.ps1).
/// All operations are transactional and write an audit row.
///
/// Invariants enforced here (not in repository):
///   • Pull must exist and be open (pending|in_progress) — closed/fully_received
///     pulls are read-only at the items surface (§7.4 spirit).
///   • (PullId, ItemCode) is the natural key; Create rejects duplicates with 409.
///   • ItemCode is immutable after Create — Update can change Description, Vendor,
///     Tag, Status, Remark only.
///   • Delete is refused (409) when any window on the item has ReceivedQty > 0
///     — receipt history would lose its anchor row. Operators must cancel
///     receipts first, then delete the item.
///   • Windows on Create: at least one, HourOfDay 0..23 unique, ExpectedQty > 0.
///   • SortOrder is auto-assigned MAX(SortOrder)+1 within the pull on Create.
/// </summary>
public interface IPullItemAdminService
{
    /// <summary>Creates a new PullItem with its hour windows. Returns the new Id.</summary>
    Task<Guid> CreateAsync(Guid pullId, PullItemCreateRequest req, CancellationToken ct = default);

    /// <summary>Edits Description/Vendor/Tag/Status/Remark. Refuses 409 on closed pull.</summary>
    Task UpdateAsync(Guid pullId, Guid itemId, PullItemUpdateRequest req, CancellationToken ct = default);

    /// <summary>Deletes the item and cascades its windows. Refuses 409 if any window has ReceivedQty &gt; 0.</summary>
    Task DeleteAsync(Guid pullId, Guid itemId, CancellationToken ct = default);

    // v2.1 Phase 6.2 — per-hour window sub-resource. Same closed-pull and
    // pull-item-exists checks as the item CRUD above; hour-specific rules are
    // documented on the request DTOs (PullItemWindowCreateRequest /
    // PullItemWindowUpdateRequest).

    /// <summary>Adds a new hour window. Returns the window's HourOfDay (the natural key on the item).</summary>
    Task<byte> AddWindowAsync(Guid pullId, Guid itemId, PullItemWindowCreateRequest req, CancellationToken ct = default);

    /// <summary>Updates ExpectedQty for an existing hour. Refuses 409 if new qty &lt; current ReceivedQty.</summary>
    Task UpdateWindowAsync(Guid pullId, Guid itemId, byte hourOfDay, PullItemWindowUpdateRequest req, CancellationToken ct = default);

    /// <summary>Deletes the hour window. Refuses 409 if it has any ReceivedQty.</summary>
    Task DeleteWindowAsync(Guid pullId, Guid itemId, byte hourOfDay, CancellationToken ct = default);
}

using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Services.Exports;

/// <summary>
/// Phase 8.4 ext — audit log export filter snapshot. Mirrors the
/// /Masters Audit Log toolbar filters (action + search) plus an
/// explicit date window so an export can target a specific incident
/// window without pulling the whole log.
///
/// Admin-only at the controller layer — audit data is sensitive
/// (operator names, IP addresses, entity identifiers).
/// </summary>
public class AuditLogExportRequest
{
    public string? Action { get; set; }
    public string? Q { get; set; }
    public DateTime? OccurredFrom { get; set; }
    public DateTime? OccurredTo { get; set; }
    public int MaxRows { get; set; } = 100_000;

    public AuditExportQuery ToQuery() => new(
        Action:       Action,
        Q:            Q,
        OccurredFrom: OccurredFrom,
        OccurredTo:   OccurredTo,
        MaxRows:      MaxRows);
}

namespace ReceivingOps.Web.Models.Dtos;

public record AuditQuery(string? Action, string? Q, int Take);

/// <summary>
/// Phase 8.4 ext — audit export filter. Same shape as <see cref="AuditQuery"/>
/// plus a date window. The repository's export method uses this and is
/// NOT capped at the 500-row UI cap.
/// </summary>
public record AuditExportQuery(
    string? Action,
    string? Q,
    DateTime? OccurredFrom,
    DateTime? OccurredTo,
    int MaxRows);

public class AuditRow
{
    public long Id { get; set; }
    public string ActionType { get; set; } = "";
    public string? EntityType { get; set; }
    public string? EntityId { get; set; }
    public string Message { get; set; } = "";
    public Guid? ActorUserId { get; set; }
    public string? ActorName { get; set; }
    public string? IpAddress { get; set; }
    public DateTime OccurredAt { get; set; }
}

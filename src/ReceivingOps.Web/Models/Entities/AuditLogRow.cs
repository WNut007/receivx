namespace ReceivingOps.Web.Models.Entities;

public class AuditLogRow
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

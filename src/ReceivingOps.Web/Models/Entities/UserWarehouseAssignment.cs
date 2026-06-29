namespace ReceivingOps.Web.Models.Entities;

public class UserWarehouseAssignment
{
    public Guid UserId { get; set; }
    public Guid WarehouseId { get; set; }
    public string Role { get; set; } = "viewer";  // admin|supervisor|operator|viewer

    // Digital-signature capabilities (db/043) — additive per-warehouse flags,
    // independent of the operational Role. A user may both receive (operator/
    // supervisor) and sign one or more parties at the same warehouse.
    public bool CanSignCustomer { get; set; }
    public bool CanSignWarehouse { get; set; }
    public bool CanSignProduction { get; set; }

    public DateTime AssignedAt { get; set; }
}

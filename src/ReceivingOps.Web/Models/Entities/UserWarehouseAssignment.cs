namespace ReceivingOps.Web.Models.Entities;

public class UserWarehouseAssignment
{
    public Guid UserId { get; set; }
    public Guid WarehouseId { get; set; }
    public string Role { get; set; } = "viewer";  // admin|supervisor|operator|viewer
    public DateTime AssignedAt { get; set; }
}

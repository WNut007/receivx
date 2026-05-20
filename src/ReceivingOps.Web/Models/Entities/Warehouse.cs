namespace ReceivingOps.Web.Models.Entities;

public class Warehouse
{
    public Guid Id { get; set; }
    public string Code { get; set; } = "";
    public string Name { get; set; } = "";
    public string? City { get; set; }
    public string? Country { get; set; }
    public string? Address { get; set; }
    public int Capacity { get; set; }
    public string Timezone { get; set; } = "Asia/Bangkok";
    public Guid? ManagerId { get; set; }
    public string? Phone { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedAt { get; set; }
    public DateTime? UpdatedAt { get; set; }
}

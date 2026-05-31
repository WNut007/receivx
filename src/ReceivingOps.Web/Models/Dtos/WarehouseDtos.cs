namespace ReceivingOps.Web.Models.Dtos;

/// <summary>One row in GET /api/warehouses.</summary>
public class WarehouseListRow
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
    public string? ManagerName { get; set; }
    public string? Phone { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedAt { get; set; }
    public int UserCount { get; set; }
    /// <summary>
    /// Data URL ("data:image/png;base64,...") for the per-warehouse logo
    /// rendered on the Delivery Order header. Null when no logo is set.
    /// </summary>
    public string? LogoDataUrl { get; set; }
}

public class WarehouseCreateRequest
{
    public string Code { get; set; } = "";
    public string Name { get; set; } = "";
    public string? City { get; set; }
    public string? Country { get; set; }
    public string? Address { get; set; }
    public int Capacity { get; set; }
    public string Timezone { get; set; } = "Asia/Bangkok";
    public Guid? ManagerId { get; set; }
    public string? Phone { get; set; }
    public bool IsActive { get; set; } = true;
    public string? LogoDataUrl { get; set; }
}

public class WarehouseUpdateRequest
{
    public string Name { get; set; } = "";
    public string? City { get; set; }
    public string? Country { get; set; }
    public string? Address { get; set; }
    public int Capacity { get; set; }
    public string Timezone { get; set; } = "Asia/Bangkok";
    public Guid? ManagerId { get; set; }
    public string? Phone { get; set; }
    public bool IsActive { get; set; } = true;
    public string? LogoDataUrl { get; set; }
}

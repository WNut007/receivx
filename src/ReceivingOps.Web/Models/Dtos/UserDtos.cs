namespace ReceivingOps.Web.Models.Dtos;

/// <summary>One row in GET /api/users — includes per-user assignments so the
/// masters list can render warehouse chips without an N+1 fetch.</summary>
public class UserListRow
{
    public Guid Id { get; set; }
    public string Username { get; set; } = "";
    public string Name { get; set; } = "";
    public string? Email { get; set; }
    public string? Phone { get; set; }
    public string Role { get; set; } = "viewer";
    public bool IsActive { get; set; }
    public DateTime? LastSignInAt { get; set; }
    public DateTime CreatedAt { get; set; }
    public int AssignmentCount { get; set; }
    public List<AssignmentRow> Assignments { get; set; } = new();
}

/// <summary>One assignment row inside a UserDetail or on the assignments PUT body.</summary>
public class AssignmentInput
{
    public Guid WarehouseId { get; set; }
    public string Role { get; set; } = "operator"; // admin|supervisor|operator|viewer
}

/// <summary>One assignment row enriched with warehouse code+name (for the detail view).</summary>
public class AssignmentRow
{
    public Guid WarehouseId { get; set; }
    public string WarehouseCode { get; set; } = "";
    public string WarehouseName { get; set; } = "";
    public string Role { get; set; } = "";
    public DateTime AssignedAt { get; set; }
}

/// <summary>GET /api/users/{id}.</summary>
public class UserDetail
{
    public Guid Id { get; set; }
    public string Username { get; set; } = "";
    public string Name { get; set; } = "";
    public string? Email { get; set; }
    public string? Phone { get; set; }
    public string Role { get; set; } = "viewer";
    public bool IsActive { get; set; }
    public DateTime? LastSignInAt { get; set; }
    public DateTime CreatedAt { get; set; }
    public DateTime? UpdatedAt { get; set; }
    public List<AssignmentRow> Assignments { get; set; } = new();
}

/// <summary>POST /api/users body.</summary>
public class UserCreateRequest
{
    public string Username { get; set; } = "";
    public string Name { get; set; } = "";
    public string? Email { get; set; }
    public string? Phone { get; set; }
    public string Role { get; set; } = "viewer";
    public string Password { get; set; } = "";
    public bool IsActive { get; set; } = true;
    public List<AssignmentInput>? Assignments { get; set; }
}

/// <summary>PUT /api/users/{id} body. Password not allowed here — use reset-password.</summary>
public class UserUpdateRequest
{
    public string Name { get; set; } = "";
    public string? Email { get; set; }
    public string? Phone { get; set; }
    public string Role { get; set; } = "viewer";
    public bool IsActive { get; set; } = true;
}

/// <summary>POST /api/users/{id}/reset-password body.</summary>
public class ResetPasswordRequest
{
    public string NewPassword { get; set; } = "";
}

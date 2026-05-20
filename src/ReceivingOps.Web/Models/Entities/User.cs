namespace ReceivingOps.Web.Models.Entities;

public class User
{
    public Guid Id { get; set; }
    public string Username { get; set; } = "";
    public string Name { get; set; } = "";
    public string? Email { get; set; }
    public string? Phone { get; set; }
    public string Role { get; set; } = "viewer";  // admin|supervisor|operator|viewer
    public string PasswordHash { get; set; } = "";
    public bool IsActive { get; set; }
    public DateTime? LastSignInAt { get; set; }
    public DateTime CreatedAt { get; set; }
    public DateTime? UpdatedAt { get; set; }
}

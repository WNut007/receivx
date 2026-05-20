namespace ReceivingOps.Web.Models.Entities;

public class UserPreferences
{
    public Guid UserId { get; set; }
    public string Theme { get; set; } = "light";          // light|midnight|slate
    public string NavPosition { get; set; } = "horizontal"; // horizontal|vertical
    public string NavBehavior { get; set; } = "sticky";   // sticky|auto-hide|static
    public bool NavCollapsed { get; set; }
    public DateTime UpdatedAt { get; set; }
}

namespace ReceivingOps.Web.Models.Dtos;

public class PreferencesDto
{
    public string Theme { get; set; } = "light";
    public string NavPosition { get; set; } = "horizontal";
    public string NavBehavior { get; set; } = "sticky";
    public bool NavCollapsed { get; set; }
    public DateTime? UpdatedAt { get; set; }
}

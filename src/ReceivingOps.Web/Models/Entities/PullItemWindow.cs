namespace ReceivingOps.Web.Models.Entities;

public class PullItemWindow
{
    public Guid Id { get; set; }
    public Guid PullItemId { get; set; }
    public byte HourOfDay { get; set; }
    public int ExpectedQty { get; set; }
    public int ReceivedQty { get; set; }  // denormalized cache; truth = vw_PullItemReceived
}

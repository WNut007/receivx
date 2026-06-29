namespace ReceivingOps.Web.Models.Dtos;

// POST body for the sign endpoint. Party is Customer/Warehouse/Production
// (case-insensitive; normalized server-side).
public class SignPartyRequest
{
    public string Party { get; set; } = "";
}

// Returned on a successful sign.
public class SignatureResult
{
    public Guid PullId { get; set; }
    public string Party { get; set; } = "";
    public string SignerName { get; set; } = "";
    public DateTime SignedAt { get; set; }
}

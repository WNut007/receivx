namespace ReceivingOps.Web.Models.Entities;

// Digital signature feature (3-party, per-warehouse). One row per
// (Pull × Party); see db/042. Party is Title-case (Customer/Warehouse/
// Production) — the per-warehouse whRole that authorizes a sign is the
// lowercase peer. SignerName is denormalized (copied from Users.Name at
// sign time) so a printed/displayed signature survives a later rename.
public class PullSignature
{
    public Guid Id { get; set; }
    public Guid PullId { get; set; }
    public string Party { get; set; } = "";          // Customer | Warehouse | Production
    public Guid WarehouseId { get; set; }
    public Guid SignerUserId { get; set; }
    public string SignerName { get; set; } = "";
    public DateTime SignedAt { get; set; }
}

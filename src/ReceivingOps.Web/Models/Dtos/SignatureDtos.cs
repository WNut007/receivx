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

// POST body for the batch sign endpoint (Phase 7d). Party must be Customer or
// Production — Warehouse is auto-signed at close and is rejected (400).
public class SignBatchRequest
{
    public List<Guid> PullIds { get; set; } = new();
    public string Party { get; set; } = "";
}

// One pull's outcome inside a batch. Outcome ∈ signed | skipped | error.
// 'skipped' = already signed (idempotent no-op); 'error' = couldn't sign
// (not found / different warehouse). Neither fails the rest of the batch.
public class BatchSignItemResult
{
    public Guid PullId { get; set; }
    public string Outcome { get; set; } = "";
    public string? Detail { get; set; }
    public DateTime? SignedAt { get; set; }
}

// Aggregate result of a batch sign — per-pull outcomes + roll-up counts.
public class SignBatchResult
{
    public string Party { get; set; } = "";
    public int Signed { get; set; }
    public int Skipped { get; set; }
    public int Errors { get; set; }
    public List<BatchSignItemResult> Results { get; set; } = new();
}

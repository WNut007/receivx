namespace ReceivingOps.Web.Services.PoImport;

/// <summary>
/// Phase 12.4 — orchestrator for the Stage 1 leg of the PO Excel import.
///
/// <para>Flow: <c>InsertSubmittedAsync</c> (Status='validating') →
/// <c>IPoImportReader.ParseAsync</c> → either
/// <c>MarkValidatedAsync</c> (Stage 1 PASS) or
/// <c>MarkValidationFailedAsync</c> (Stage 1 FAIL).</para>
///
/// <para>Stage 2 (atomic upsert into Pulls / PurchaseOrders /
/// PurchaseOrderLines) is a separate concern that lives in the
/// Hangfire job — landing in 12.5+. This service deliberately stops
/// at the validated state so the operator can preview before
/// committing.</para>
/// </summary>
public interface IPoImportService
{
    /// <summary>
    /// Mint a log row, parse the file, persist the outcome. Never throws
    /// for content errors — those land in <see cref="PoImportSubmissionResult"/>.
    /// Throws for infra failures (DB unreachable, file vanished between
    /// upload-save and parse).
    /// </summary>
    Task<PoImportSubmissionResult> SubmitForValidationAsync(
        PoImportSubmission submission, CancellationToken ct = default);
}

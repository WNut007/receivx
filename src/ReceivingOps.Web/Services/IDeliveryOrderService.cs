using FastReport;

namespace ReceivingOps.Web.Services;

/// <summary>
/// v2.x Phase 7.3 — Builds the Delivery Order report for a closed pull.
/// Returns a prepared FastReport.Report ready for HTML preview, PDF
/// export, or any other FastReport sink. Caller owns the Report
/// instance and is responsible for disposing it.
///
/// Eligibility: pull must be in 'closed' status AND have at least one
/// non-reversal positive receipt. Open / fully-reversed pulls throw
/// BusinessException — a DO is proof of delivery; there's nothing to
/// prove for those.
/// </summary>
public interface IDeliveryOrderService
{
    /// <summary>Builds + prepares the DO report. Throws NotFoundException / BusinessException for ineligible pulls.</summary>
    Task<Report> BuildAsync(Guid pullId, CancellationToken ct = default);
}

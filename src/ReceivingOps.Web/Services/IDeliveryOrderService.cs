using FastReport;
using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Services;

/// <summary>
/// v2.x Phase 7.3 / 7.4 — Builds the Delivery Order report for a closed
/// pull. The data shape (DoReportData) feeds both the HTML preview partial
/// and the FastReport PDF builder; one source of truth, no drift between
/// browser preview and the printed paper.
///
/// Eligibility: pull must be in 'closed' status AND have at least one
/// (PO × Line × Item) tuple with net-positive received qty. Open /
/// fully-reversed pulls throw BusinessException — a DO is proof of
/// delivery; there's nothing to prove for those.
/// </summary>
public interface IDeliveryOrderService
{
    /// <summary>
    /// v2.x Phase 7.4 — Loads the aggregated DO data (pull header + one
    /// DoOrder per PO touched + per-line aggregated qty + company info).
    /// Throws NotFoundException / BusinessException for ineligible pulls.
    /// </summary>
    Task<DoReportData> GetReportDataAsync(Guid pullId, CancellationToken ct = default);

    /// <summary>
    /// v2.x Phase 7.3 — Builds + prepares the FastReport.Report for PDF
    /// export. Throws NotFoundException / BusinessException for ineligible
    /// pulls. Caller owns the Report and is responsible for disposing it.
    /// </summary>
    Task<Report> BuildAsync(Guid pullId, CancellationToken ct = default);
}

using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Data.Repositories;

/// <summary>
/// Read-only query surface behind Reports → Pull Sheets and the per-pull
/// Export button. Separate from <see cref="IPullRepository"/> because it
/// answers a different question: that one is pull-grained and (on the Reports
/// page) closed-only, this one is window-grained and deliberately includes
/// OPEN pulls.
/// </summary>
public interface IPullSheetReportRepository
{
    /// <summary>
    /// Detail rows — one per (pull, item, window) — matching the criteria.
    ///
    /// Period mode reads the hour set of the requested period. Every period
    /// reads a single PullDate except Night, which reads hour 23 of date D and
    /// hours 0,1,2 of D+1; see the implementation for why that has to be
    /// constructed rather than queried.
    ///
    /// Single-pull mode (<see cref="PullSheetCriteria.PullId"/> set) reads all
    /// 24 hours of that one pull and ignores warehouse/date/period/status.
    /// </summary>
    Task<List<PullSheetDetailRow>> GetDetailRowsAsync(
        PullSheetCriteria criteria, CancellationToken ct = default);
}

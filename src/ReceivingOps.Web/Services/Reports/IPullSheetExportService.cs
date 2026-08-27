using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Services.Reports;

/// <summary>
/// Builds the pull-sheet workbook. ONE generator, two callers: Reports → Pull
/// Sheets (warehouse + date + period) and the Receiving Console's per-pull
/// Export button. They differ only in the criteria handed in.
///
/// Returns bytes rather than writing a file or taking an HttpResponse, so
/// wrapping it in a Hangfire job later needs no refactor here. Today the
/// controller serves the bytes straight back in-request — see
/// <see cref="DetailRowLimit"/> for the guard that keeps that safe.
/// </summary>
public interface IPullSheetExportService
{
    /// <summary>
    /// Above this many Detail rows the export is refused rather than generated,
    /// so an over-broad filter cannot tie up a request thread building a
    /// workbook nobody wants. One period in one warehouse is far below it.
    /// </summary>
    const int DetailRowLimit = 5000;

    /// <summary>Resolve criteria to rows. Preview and export both go through this.</summary>
    Task<PullSheetResult> QueryAsync(PullSheetCriteria criteria, CancellationToken ct = default);

    /// <summary>Render an already-resolved result to XLSX bytes plus a filename.</summary>
    PullSheetWorkbook Build(PullSheetResult result, PullSheetCriteria criteria);
}

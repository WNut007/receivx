namespace ReceivingOps.Web.Services.PoImport;

/// <summary>
/// Phase 12.2 — read an uploaded Excel file (.xls or .xlsx) and project
/// it into <see cref="PoImportRow"/> instances ready for the atomic
/// insert in 12.4. Pure read + transform; no persistence.
///
/// <para>NPOI is fully synchronous. The async signature is preserved for
/// caller compatibility (controllers expect async I/O) but the
/// implementation does not introduce thread-pool offloading — file
/// parsing is fast enough at our row counts (~6k rows in the sample
/// file) that the cost of Task.Run hops outweighs the gain.</para>
/// </summary>
public interface IPoImportReader
{
    /// <summary>
    /// Parse the file at <paramref name="filePath"/>. Returns a result
    /// with <see cref="PoImportParseResult.IsValid"/> = false when:
    /// <list type="bullet">
    ///   <item>File extension is not .xls or .xlsx</item>
    ///   <item>No data sheet is present</item>
    ///   <item>Required header columns are missing</item>
    ///   <item>Any data row fails per-row validation</item>
    /// </list>
    /// Callers should treat IsValid=false as fail-the-whole-import
    /// (Q3=A — atomic, no partial accept).
    /// </summary>
    Task<PoImportParseResult> ParseAsync(string filePath, CancellationToken ct = default);
}

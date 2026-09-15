using System.Text.Json;
using FastReport;
using FastReport.Barcode;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.FileProviders;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using ReceivingOps.Web.Data;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Models;
using ReceivingOps.Web.Models.Dtos;
using ReceivingOps.Web.Services;

// ---------------------------------------------------------------------------
// Dump every object FastReport has laid out, page by page, after Prepare().
//
//   DumpPreparedPages --pull <PullNumber> [--type note|order] [--out <file>]
//
// Prints JSON: { "pages": [ { "page": 1, "objects": [ {name,type,value} ] } ] }
//
// The point is to read per-PAGE values. A page-footer object bound to a data
// column renders whatever row the data source is sitting on when the page
// closes, which is not necessarily the row printed on that page — that is
// exactly the class of fault this tool exists to expose.
// ---------------------------------------------------------------------------

static string? Arg(string[] a, string name)
{
    var i = Array.IndexOf(a, name);
    return i >= 0 && i + 1 < a.Length ? a[i + 1] : null;
}

var pullNumber = Arg(args, "--pull");
if (string.IsNullOrWhiteSpace(pullNumber))
{
    Console.Error.WriteLine("usage: DumpPreparedPages --pull <PullNumber> [--type note|order] [--out <file>]");
    return 2;
}

var typeArg = (Arg(args, "--type") ?? "note").ToLowerInvariant();
var reportType = typeArg == "order" ? ReportType.DeliveryOrder : ReportType.DeliveryNote;
var outPath = Arg(args, "--out");

// The connection string comes from the same precedence chain the app uses, so
// this tool cannot be pointed somewhere the app would not go. ContentRootPath
// must be the web project so Reports/*.frx resolves to the real template.
var repoRoot = FindRepoRoot(AppContext.BaseDirectory)
    ?? throw new InvalidOperationException("could not locate the repo root from " + AppContext.BaseDirectory);
var contentRoot = Path.Combine(repoRoot, "src", "ReceivingOps.Web");

var config = new ConfigurationBuilder()
    .SetBasePath(contentRoot)
    .AddJsonFile("appsettings.json", optional: true)
    .AddJsonFile("appsettings.Development.json", optional: true)
    .AddUserSecrets(typeof(ReceivingOps.Web.Data.SqlConnectionFactory).Assembly, optional: true)
    .AddEnvironmentVariables()
    .Build();

var factory    = new SqlConnectionFactory(config);
var pulls      = new PullRepository(factory);
var warehouses = new WarehouseRepository(factory);
var signatures = new PullSignatureRepository(factory);

var company = new CompanyInfo();
config.GetSection("Company").Bind(company);

var service = new DeliveryOrderService(
    pulls, warehouses, signatures,
    Options.Create(company),
    new ToolHostEnvironment(contentRoot),
    NullLogger<DeliveryOrderService>.Instance);

// Resolve the pull by number — the smoke knows its fixture by number, not id.
var pullId = await ResolvePullIdAsync(factory, pullNumber!);
if (pullId is null)
{
    Console.Error.WriteLine($"pull '{pullNumber}' not found");
    return 3;
}

var data = await service.GetReportDataAsync(pullId.Value, reportType);
using var report = service.Build(data, reportType);

var pages = new List<object>();
for (int i = 0; i < report.PreparedPages.Count; i++)
{
    var page = report.PreparedPages.GetPage(i);
    var objects = new List<object>();
    Walk(page, objects);
    pages.Add(new { page = i + 1, objects });
    page.Dispose();
}

var json = JsonSerializer.Serialize(
    new { pull = pullNumber, type = typeArg, pageCount = report.PreparedPages.Count, pages },
    new JsonSerializerOptions { WriteIndented = true });

if (string.IsNullOrWhiteSpace(outPath)) Console.WriteLine(json);
else { File.WriteAllText(outPath, json); Console.WriteLine($"wrote {outPath} ({report.PreparedPages.Count} pages)"); }
return 0;

// ---------------------------------------------------------------------------
static void Walk(Base parent, List<object> sink)
{
    foreach (Base child in parent.AllObjects)
    {
        // Geometry is absolute on the prepared page, which is what makes a
        // before/after comparison meaningful: moving an object between bands
        // must not move it on the paper.
        switch (child)
        {
            case TextObject t:
                sink.Add(Rec(t.Name, "TextObject", t.Text ?? "", t));
                break;
            case BarcodeObject b:
                // Text is the ENCODED payload — what the scanner reads. NOTE: a
                // BarcodeObject only evaluates an [Expression] here when
                // AllowExpressions is set; without it the literal is encoded.
                sink.Add(Rec(b.Name, "BarcodeObject", b.Text ?? "", b));
                break;
            case PictureObject p:
                // Images carry no readable text; record presence and size so a
                // shifted or missing signature image is still visible here.
                sink.Add(Rec(p.Name, "PictureObject",
                    p.Image is null ? "" : $"image {p.Image.Width}x{p.Image.Height}", p));
                break;
        }
    }
}

static object Rec(string name, string type, string value, ComponentBase c) => new
{
    name,
    type,
    value,
    // AbsLeft/AbsTop are the position on the page after layout, in FastReport
    // units (1/96"). Rounded so a float wobble does not read as a move.
    left   = Math.Round(c.AbsLeft, 2),
    top    = Math.Round(c.AbsTop, 2),
    width  = Math.Round(c.Width, 2),
    height = Math.Round(c.Height, 2),
};

static async Task<Guid?> ResolvePullIdAsync(IDbConnectionFactory factory, string pullNumber)
{
    using var conn = factory.Create();
    var cmd = conn.CreateCommand();
    cmd.CommandText = "SELECT Id FROM dbo.Pulls WHERE PullNumber = @p";
    var p = cmd.CreateParameter();
    p.ParameterName = "@p";
    p.Value = pullNumber;
    cmd.Parameters.Add(p);
    if (conn.State != System.Data.ConnectionState.Open) conn.Open();
    var result = cmd.ExecuteScalar();
    await Task.CompletedTask;
    return result is Guid g ? g : null;
}

static string? FindRepoRoot(string start)
{
    var dir = new DirectoryInfo(start);
    while (dir is not null)
    {
        if (Directory.Exists(Path.Combine(dir.FullName, "src", "ReceivingOps.Web"))) return dir.FullName;
        dir = dir.Parent;
    }
    return null;
}

/// <summary>
/// Minimal IWebHostEnvironment — DeliveryOrderService only reads
/// ContentRootPath, to resolve Reports/*.frx.
/// </summary>
file sealed class ToolHostEnvironment : Microsoft.AspNetCore.Hosting.IWebHostEnvironment
{
    public ToolHostEnvironment(string contentRoot)
    {
        ContentRootPath = contentRoot;
        WebRootPath = Path.Combine(contentRoot, "wwwroot");
        ContentRootFileProvider = new PhysicalFileProvider(contentRoot);
        WebRootFileProvider = Directory.Exists(WebRootPath)
            ? new PhysicalFileProvider(WebRootPath)
            : ContentRootFileProvider;
    }

    public string WebRootPath { get; set; }
    public IFileProvider WebRootFileProvider { get; set; }
    public string ApplicationName { get; set; } = "DumpPreparedPages";
    public IFileProvider ContentRootFileProvider { get; set; }
    public string ContentRootPath { get; set; }
    public string EnvironmentName { get; set; } = "Development";
}


using System.Text.Json;
using System.Text.Json.Serialization;
using FastReport.Web;
using Hangfire;
using Hangfire.SqlServer;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.Identity;
using ReceivingOps.Web.Data;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Hangfire;
using ReceivingOps.Web.Json;
using ReceivingOps.Web.Models;
using ReceivingOps.Web.Models.Entities;
using ReceivingOps.Web.Services;
using ReceivingOps.Web.Services.Config;
using ReceivingOps.Web.Services.Email;
using ReceivingOps.Web.Services.ErpSync;
using ReceivingOps.Web.Services.Exports;

var builder = WebApplication.CreateBuilder(args);

// ---- MVC + JSON conventions ----
builder.Services.AddControllersWithViews()
    .AddJsonOptions(o =>
    {
        o.JsonSerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.CamelCase;
        o.JsonSerializerOptions.DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull;
        // All DB timestamps are UTC (DATETIME2 fed by SYSUTCDATETIME()); without
        // these converters the JSON drops the tz marker and the browser parses
        // them as local time, off by the user's offset. See UtcDateTimeConverter.
        o.JsonSerializerOptions.Converters.Add(new UtcDateTimeConverter());
        o.JsonSerializerOptions.Converters.Add(new NullableUtcDateTimeConverter());
    });

// ---- HttpContext access for AuthService + AuditService ----
builder.Services.AddHttpContextAccessor();

// ---- v3.x Phase 11.1 — Data Protection ----
// Provides the encryption primitives for dbo.AppSettings.EncryptedValue.
// Keys persist to a folder ON DISK that MUST move with the database in
// any migration / restore — losing the keys means losing every encrypted
// secret already stored. DataProtection:KeyDirectory is a bootstrap
// exclusion (NEVER stored in AppSettings) for the same chicken-and-egg
// reason as ConnectionStrings:Default. Default location: ".dp-keys/"
// under ContentRootPath, gitignored.
var dpKeyDir = builder.Configuration["DataProtection:KeyDirectory"]
    ?? Path.Combine(builder.Environment.ContentRootPath, ".dp-keys");
Directory.CreateDirectory(dpKeyDir);
builder.Services.AddDataProtection()
    .SetApplicationName("Receivx")
    .PersistKeysToFileSystem(new DirectoryInfo(dpKeyDir))
    .SetDefaultKeyLifetime(TimeSpan.FromDays(90));

// ---- Cookie authentication ----
builder.Services
    .AddAuthentication(CookieAuthenticationDefaults.AuthenticationScheme)
    .AddCookie(o =>
    {
        o.LoginPath = "/Account/Login";
        o.AccessDeniedPath = "/Account/AccessDenied";
        o.Cookie.HttpOnly = true;
        o.Cookie.SameSite = SameSiteMode.Lax;
        o.ExpireTimeSpan = TimeSpan.FromHours(12);
        o.SlidingExpiration = true;
        // API routes need real 401/403 status codes — the default cookie scheme
        // redirects to LoginPath / AccessDeniedPath which produces HTML 200 and
        // breaks every fetch() check on the client.
        o.Events.OnRedirectToLogin = ctx =>
        {
            if (ctx.Request.Path.StartsWithSegments("/api"))
            {
                ctx.Response.StatusCode = 401;
                return Task.CompletedTask;
            }
            ctx.Response.Redirect(ctx.RedirectUri);
            return Task.CompletedTask;
        };
        o.Events.OnRedirectToAccessDenied = ctx =>
        {
            if (ctx.Request.Path.StartsWithSegments("/api"))
            {
                ctx.Response.StatusCode = 403;
                return Task.CompletedTask;
            }
            ctx.Response.Redirect(ctx.RedirectUri);
            return Task.CompletedTask;
        };
    });

// ---- Authorization policies (§5.5) ----
builder.Services.AddAuthorization(opts =>
{
    opts.AddPolicy("AdminOnly", p => p.RequireRole("admin"));

    opts.AddPolicy("CanManagePulls", p => p.RequireAssertion(ctx =>
        ctx.User.IsInRole("admin") ||
        ctx.User.HasClaim("whRole", "supervisor")));

    opts.AddPolicy("CanReceive", p => p.RequireAssertion(ctx =>
        ctx.User.IsInRole("admin") ||
        new[] { "supervisor", "operator" }.Contains(
            ctx.User.FindFirst("whRole")?.Value ?? "")));

    opts.AddPolicy("CanReopenPull", p => p.RequireAssertion(ctx =>
        ctx.User.IsInRole("admin") ||
        ctx.User.HasClaim("whRole", "supervisor")));
});

// ---- Data + repositories + services ----
builder.Services.AddScoped<IDbConnectionFactory, SqlConnectionFactory>();
// v3.x Phase 10.1 — ERP source DB connection factory (separate from the
// Receivx DB factory above: different host, read-only credentials, optional
// in dev). Throws at Create() time when ErpDb:ConnectionString isn't set,
// so startup stays healthy even with ERP integration disabled.
builder.Services.AddScoped<IErpDbConnectionFactory, ErpSqlConnectionFactory>();

builder.Services.AddScoped<IUserRepository, UserRepository>();
builder.Services.AddScoped<IWarehouseRepository, WarehouseRepository>();
builder.Services.AddScoped<IAssignmentRepository, AssignmentRepository>();
builder.Services.AddScoped<IPullRepository, PullRepository>();
builder.Services.AddScoped<IReceiptRepository, ReceiptRepository>();
builder.Services.AddScoped<IPurchaseOrderRepository, PurchaseOrderRepository>();
builder.Services.AddScoped<IAuditRepository, AuditRepository>();
builder.Services.AddScoped<IExportJobLogRepository, ExportJobLogRepository>();
builder.Services.AddScoped<IErpSyncLogRepository, ErpSyncLogRepository>();
builder.Services.AddScoped<IPreferencesRepository, PreferencesRepository>();
// Phase 11.1 — admin-edited config storage. Repository is Scoped (matches
// project convention); the service that wraps it is Singleton (see below).
builder.Services.AddScoped<IAppSettingsRepository, AppSettingsRepository>();

builder.Services.AddScoped<IAuditService, AuditService>();
builder.Services.AddScoped<IAuthService, AuthService>();
builder.Services.AddScoped<IReceiptService, ReceiptService>();
builder.Services.AddScoped<ICloseService, CloseService>();
builder.Services.AddScoped<IMastersService, MastersService>();
builder.Services.AddScoped<IPurchaseOrderAdminService, PurchaseOrderAdminService>();
builder.Services.AddScoped<IPullAdminService, PullAdminService>();
builder.Services.AddScoped<IPullItemAdminService, PullItemAdminService>();
builder.Services.AddScoped<IDeliveryOrderService, DeliveryOrderService>();

builder.Services.AddSingleton<IPasswordHasher<User>, PasswordHasher<User>>();

// Phase 11.1 — config storage facade. Singleton because the encryption
// protector is thread-safe and there's no per-request state. Scoped deps
// (repository, audit) are resolved per-call via IServiceScopeFactory.
builder.Services.AddSingleton<IAppSettingsService, AppSettingsService>();
// One-time hydration: copies appsettings.json + user-secrets into the DB
// on first start. Scoped — instantiated once at startup via app.Services.
builder.Services.AddScoped<AppSettingsSeeder>();

// ---- v2.x Phase 8.4 — email transport (Gmail SMTP via MailKit) ----
// SmtpOptions used to bind directly from "Smtp" (appsettings + user-secrets).
// Phase 11.1 routes it through IAppSettingsService instead — the bind below
// first pulls IConfiguration defaults, then overlays DB / env-var resolution.
// Precedence: env vars > DB > user-secrets > appsettings.json.
builder.Services.AddOptions<SmtpOptions>()
    .Configure(opts => builder.Configuration.GetSection("Smtp").Bind(opts))
    .Configure<IAppSettingsService>((opts, settings) =>
    {
        var host = settings.GetAsync("Smtp:Host").GetAwaiter().GetResult();
        if (host is not null) opts.Host = host;
        if (int.TryParse(settings.GetAsync("Smtp:Port").GetAwaiter().GetResult(), out var port))
            opts.Port = port;
        if (bool.TryParse(settings.GetAsync("Smtp:UseStartTls").GetAwaiter().GetResult(), out var tls))
            opts.UseStartTls = tls;
        var user = settings.GetAsync("Smtp:Username").GetAwaiter().GetResult();
        if (user is not null) opts.Username = user;
        var pass = settings.GetAsync("Smtp:Password").GetAwaiter().GetResult();
        if (pass is not null) opts.Password = pass;
        var from = settings.GetAsync("Smtp:FromAddress").GetAwaiter().GetResult();
        if (from is not null) opts.FromAddress = from;
        var fromName = settings.GetAsync("Smtp:FromName").GetAwaiter().GetResult();
        if (fromName is not null) opts.FromName = fromName;
    });
builder.Services.AddSingleton<IEmailService, MailKitEmailService>();

// ---- v2.x Phase 8.4 — export pipeline ----
// ExportOptions: storage root + signing key + base URL for download links
// + file lifetime. Same precedence as Smtp — DB rows from AppSettings beat
// user-secrets / appsettings.json defaults, env vars beat DB.
builder.Services.AddOptions<ExportOptions>()
    .Configure(opts => builder.Configuration.GetSection("Exports").Bind(opts))
    .Configure<IAppSettingsService>((opts, settings) =>
    {
        var root = settings.GetAsync("Exports:StorageRoot").GetAwaiter().GetResult();
        if (root is not null) opts.StorageRoot = root;
        var key = settings.GetAsync("Exports:SigningKey").GetAwaiter().GetResult();
        if (key is not null) opts.SigningKey = key;
        var baseUrl = settings.GetAsync("Exports:BaseUrl").GetAwaiter().GetResult();
        if (baseUrl is not null) opts.BaseUrl = baseUrl;
        var lifetime = settings.GetAsync("Exports:FileLifetime").GetAwaiter().GetResult();
        if (lifetime is not null && TimeSpan.TryParse(lifetime, out var span))
            opts.FileLifetime = span;
    });
builder.Services.AddSingleton<ExportTokenService>();
builder.Services.AddScoped<TransactionsExportJob>();
builder.Services.AddScoped<PosExportJob>();
builder.Services.AddScoped<AuditLogExportJob>();
builder.Services.AddScoped<IExportService, ExportService>();

// ---- v3.x Phase 10.1 — ERP sync pipeline ----
// ErpSyncOptions: kill-switch + cron expression + warehouse default +
// backfill window. Phase 11.1 routes through IAppSettingsService —
// admins flip Enabled / DefaultWarehouseId via the config UI without
// touching appsettings.json.
builder.Services.AddOptions<ErpSyncOptions>()
    .Configure(opts => builder.Configuration.GetSection("ErpSync").Bind(opts))
    .Configure<IAppSettingsService>((opts, settings) =>
    {
        if (bool.TryParse(settings.GetAsync("ErpSync:Enabled").GetAwaiter().GetResult(), out var en))
            opts.Enabled = en;
        var cron = settings.GetAsync("ErpSync:CronExpression").GetAwaiter().GetResult();
        if (cron is not null) opts.CronExpression = cron;
        if (int.TryParse(settings.GetAsync("ErpSync:TimeoutSeconds").GetAwaiter().GetResult(), out var t))
            opts.TimeoutSeconds = t;
        if (Guid.TryParse(settings.GetAsync("ErpSync:DefaultWarehouseId").GetAwaiter().GetResult(), out var wh))
            opts.DefaultWarehouseId = wh;
        if (int.TryParse(settings.GetAsync("ErpSync:BackfillDays").GetAwaiter().GetResult(), out var bd))
            opts.BackfillDays = bd;
    });
builder.Services.AddScoped<IErpSyncService, ErpSyncService>();
builder.Services.AddScoped<IErpUpsertService, ErpUpsertService>();
builder.Services.AddScoped<ErpSyncJob>();
// Singleton — guards recurring vs manual-trigger overlap. In-process only;
// distributed locking would be needed for a multi-instance deployment.
builder.Services.AddSingleton<ErpSyncMutex>();

// ---- v2.x Phase 7.2 — Reports (FastReport.OpenSource) ----
// CompanyInfo binds from the "CompanyInfo" section in appsettings.json;
// consumed by the DO report header (Phase 7.3+) via IOptions<CompanyInfo>.
// Defaults to empty strings on missing section so startup never crashes on
// a fresh deploy that hasn't filled the placeholders.
builder.Services.Configure<CompanyInfo>(builder.Configuration.GetSection("CompanyInfo"));

// FastReport DI — registers the engine + Web viewer services. Endpoints +
// .frx templates land in Phase 7.3; this commit only wires the bootstrap.
builder.Services.AddFastReport();

// ---- v2.x Phase 8.4 — Hangfire (background jobs, SQL-Server-backed) ----
// Uses the same SQL Server as the app (ConnectionStrings:Default). Hangfire
// creates its own tables under schema [HangFire] on first start, so the
// app schema stays untouched. The schema flag PrepareSchemaIfNecessary
// defaults to true — fine for dev; production turns it off post-bootstrap.
var hangfireCs = builder.Configuration.GetConnectionString("Default")
    ?? throw new InvalidOperationException("ConnectionStrings:Default required for Hangfire");
builder.Services.AddHangfire(cfg => cfg
    .SetDataCompatibilityLevel(CompatibilityLevel.Version_180)
    .UseSimpleAssemblyNameTypeSerializer()
    .UseRecommendedSerializerSettings()
    .UseSqlServerStorage(hangfireCs, new SqlServerStorageOptions
    {
        CommandBatchMaxTimeout = TimeSpan.FromMinutes(5),
        SlidingInvisibilityTimeout = TimeSpan.FromMinutes(5),
        QueuePollInterval = TimeSpan.FromSeconds(15),
        UseRecommendedIsolationLevel = true,
        DisableGlobalLocks = true,
    }));
// In-process worker — runs background jobs alongside the web tier. Fine
// for the export-on-demand workload; a separate Hangfire worker process
// can be added later if exports start contending with request threads.
builder.Services.AddHangfireServer(opts =>
{
    opts.WorkerCount = 2;
    // Phase 10.1 adds the "erp-sync" queue. Order matters: Hangfire scans
    // queues left-to-right when picking the next job, so put time-sensitive
    // user-facing work (exports) ahead of the background ETL.
    opts.Queues = new[] { "exports", "erp-sync", "default" };
});

var app = builder.Build();

// ---- v3.x Phase 11.1 — AppSettings seeder ----
// Runs BEFORE any IOptions<T> consumer so the options binding (commit 5)
// reads from a populated DB. Idempotent: no-ops when rows already exist.
using (var seedScope = app.Services.CreateScope())
{
    var seeder = seedScope.ServiceProvider.GetRequiredService<AppSettingsSeeder>();
    await seeder.RunAsync();
}

if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Account/AccessDenied");
    app.UseHsts();
}

app.UseHttpsRedirection();
app.UseStaticFiles();
app.UseRouting();
app.UseAuthentication();
app.UseAuthorization();

// FastReport Web viewer middleware — mounts /_fr/* routes for the embedded
// preview component. Reports themselves are served by a dedicated controller
// in Phase 7.3; this just enables the viewer's runtime assets.
app.UseFastReport();

// Hangfire dashboard at /hangfire — admin only. The filter checks
// User.IsInRole("admin") in HangfireDashboardAuth.
app.UseHangfireDashboard("/hangfire", new DashboardOptions
{
    Authorization = new[] { new HangfireDashboardAuth() },
    DashboardTitle = "ReceivingOps — Background Jobs",
});

// ---- v3.x Phase 10.1 — ErpSync recurring registration ----
// Conditional: register only when ErpSync:Enabled is true. The else
// branch explicitly removes the schedule so toggling Enabled=false at
// config time (and restarting) actually disables the recurring fire —
// otherwise a stale entry would survive in [HangFire].[Set] forever.
using (var scope = app.Services.CreateScope())
{
    var erpOpts = scope.ServiceProvider
        .GetRequiredService<Microsoft.Extensions.Options.IOptions<ErpSyncOptions>>().Value;
    if (erpOpts.Enabled)
    {
        RecurringJob.AddOrUpdate<ErpSyncJob>(
            "erp-sync-hourly",
            "erp-sync",
            job => job.RunAsync(),
            erpOpts.CronExpression);
    }
    else
    {
        RecurringJob.RemoveIfExists("erp-sync-hourly");
    }
}

app.MapControllerRoute(
    name: "default",
    pattern: "{controller=Dashboard}/{action=Index}/{id?}");
app.MapControllers();

app.Run();

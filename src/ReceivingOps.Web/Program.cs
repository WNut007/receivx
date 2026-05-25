using System.Text.Json;
using System.Text.Json.Serialization;
using FastReport.Web;
using Hangfire;
using Hangfire.SqlServer;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Identity;
using ReceivingOps.Web.Data;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Hangfire;
using ReceivingOps.Web.Json;
using ReceivingOps.Web.Models;
using ReceivingOps.Web.Models.Entities;
using ReceivingOps.Web.Services;
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
builder.Services.AddScoped<IPreferencesRepository, PreferencesRepository>();

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

// ---- v2.x Phase 8.4 — email transport (Gmail SMTP via MailKit) ----
// SmtpOptions binds from the "Smtp" section — typically user-secrets in
// dev, env vars in prod. Empty Host disables real sending (the service
// logs the would-be email instead) so dev without SMTP doesn't crash.
builder.Services.Configure<SmtpOptions>(builder.Configuration.GetSection("Smtp"));
builder.Services.AddSingleton<IEmailService, MailKitEmailService>();

// ---- v2.x Phase 8.4 — export pipeline ----
// ExportOptions: storage root + signing key + base URL for download links
// + file lifetime. Production deploys must override SigningKey via secret.
builder.Services.Configure<ExportOptions>(builder.Configuration.GetSection("Exports"));
builder.Services.AddSingleton<ExportTokenService>();
builder.Services.AddScoped<TransactionsExportJob>();
builder.Services.AddScoped<PosExportJob>();
builder.Services.AddScoped<AuditLogExportJob>();
builder.Services.AddScoped<IExportService, ExportService>();

// ---- v3.x Phase 10.1 — ERP sync pipeline ----
// ErpSyncOptions: kill-switch + cron expression. ErpSyncJob: Hangfire-
// scheduled stub that opens the ERP DB connection and runs SELECT @@VERSION.
// 10.2+ fleshes out the actual ETL transform + upsert logic.
builder.Services.Configure<ErpSyncOptions>(builder.Configuration.GetSection("ErpSync"));
builder.Services.AddScoped<IErpSyncService, ErpSyncService>();
builder.Services.AddScoped<IErpUpsertService, ErpUpsertService>();
builder.Services.AddScoped<ErpSyncJob>();

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

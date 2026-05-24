using Hangfire.Dashboard;

namespace ReceivingOps.Web.Hangfire;

/// <summary>
/// Gates the /hangfire dashboard to admin users only. The dashboard
/// exposes job state, retries, and recurring schedules — too much
/// surface for operators to poke at. Cookie auth must already have
/// populated the principal before this fires (UseAuthentication +
/// UseAuthorization sit in the pipeline ahead of UseHangfireDashboard).
/// </summary>
public class HangfireDashboardAuth : IDashboardAuthorizationFilter
{
    public bool Authorize(DashboardContext context)
    {
        var user = context.GetHttpContext().User;
        return user.Identity?.IsAuthenticated == true && user.IsInRole("admin");
    }
}

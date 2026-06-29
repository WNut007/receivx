using System.Security.Claims;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Identity;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Models.Dtos;
using ReceivingOps.Web.Models.Entities;

namespace ReceivingOps.Web.Services;

public class AuthService : IAuthService
{
    private readonly IUserRepository _users;
    private readonly IWarehouseRepository _warehouses;
    private readonly IAssignmentRepository _assignments;
    private readonly IPasswordHasher<User> _hasher;
    private readonly IAuditService _audit;
    private readonly IHttpContextAccessor _httpContext;
    private readonly ILogger<AuthService> _logger;

    public AuthService(
        IUserRepository users,
        IWarehouseRepository warehouses,
        IAssignmentRepository assignments,
        IPasswordHasher<User> hasher,
        IAuditService audit,
        IHttpContextAccessor httpContext,
        ILogger<AuthService> logger)
    {
        _users = users;
        _warehouses = warehouses;
        _assignments = assignments;
        _hasher = hasher;
        _audit = audit;
        _httpContext = httpContext;
        _logger = logger;
    }

    public async Task<AuthResult> LoginAsync(LoginRequest req, CancellationToken ct = default)
    {
        // §5.1 step 1: user lookup
        var user = await _users.GetByUsernameAsync(req.Username, ct);
        if (user is null)
            return new AuthResult.Failure(401, "No account found with that username");

        // §5.1 step 2: disabled?
        if (!user.IsActive)
            return new AuthResult.Failure(403, "This account is disabled");

        // §5.1 step 3: password
        var verify = _hasher.VerifyHashedPassword(user, user.PasswordHash, req.Password);
        if (verify == PasswordVerificationResult.Failed)
            return new AuthResult.Failure(401, "Incorrect password");

        // §5.1 step 4: warehouse access (admins bypass)
        var warehouse = await _warehouses.GetByIdAsync(req.WarehouseId, ct);
        if (warehouse is null || !warehouse.IsActive)
            return new AuthResult.Failure(404, "Selected warehouse not found");

        var isGlobalAdmin = string.Equals(user.Role, "admin", StringComparison.Ordinal);
        string whRole;

        if (isGlobalAdmin)
        {
            whRole = "admin";
        }
        else
        {
            var assignedRole = await _assignments.GetRoleAsync(user.Id, warehouse.Id, ct);
            if (assignedRole is null)
                return new AuthResult.Failure(403, "You don't have access to that warehouse");
            whRole = assignedRole;
        }

        // §5.1 step 6: cookie sign-in
        var claims = new List<Claim>
        {
            new(ClaimTypes.NameIdentifier, user.Id.ToString()),
            new(ClaimTypes.Name,           user.Username),
            new("displayName",             user.Name),
            new("email",                   user.Email ?? ""),
            new("warehouseId",             warehouse.Id.ToString()),
            new("warehouseCode",           warehouse.Code),
            new("warehouseName",           warehouse.Name),
            new("whRole",                  whRole),
            new(ClaimTypes.Role,           user.Role),
        };
        var principal = new ClaimsPrincipal(
            new ClaimsIdentity(claims, CookieAuthenticationDefaults.AuthenticationScheme));

        var ctx = _httpContext.HttpContext
            ?? throw new InvalidOperationException("HttpContext unavailable during login");

        await ctx.SignInAsync(
            CookieAuthenticationDefaults.AuthenticationScheme,
            principal,
            new AuthenticationProperties { IsPersistent = req.Remember });

        // §5.1 step 7: stamp last sign-in (post-sign-in so audit row carries the actor)
        await _users.UpdateLastSignInAsync(user.Id, ct);

        // §5.1 step 8: audit
        await _audit.WriteAsync("login", "User", user.Id.ToString(),
            $"User {user.Username} signed in to {warehouse.Code}", ct);

        // §5.1 step 9: response
        var info = new SessionInfo(
            Name: user.Name,
            Role: RoleLabel(whRole),
            RoleKey: whRole,
            Initials: Initials(user.Name),
            WarehouseCode: warehouse.Code,
            WarehouseName: warehouse.Name,
            RedirectTo: "/Dashboard");

        return new AuthResult.Success(info);
    }

    public async Task LogoutAsync(CancellationToken ct = default)
    {
        var ctx = _httpContext.HttpContext;
        if (ctx is null) return;

        var userId = ctx.User.FindFirstValue(ClaimTypes.NameIdentifier);
        var username = ctx.User.Identity?.Name;

        await ctx.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);

        // §5.4: audit AFTER sign-out so the row records who just left.
        // Actor resolution in AuditService reads HttpContext.User which is now anonymous;
        // we pass the identity explicitly via the message so it's preserved.
        if (!string.IsNullOrEmpty(userId))
        {
            await _audit.WriteAsync("logout", "User", userId,
                $"User {username ?? "(unknown)"} signed out", ct);
        }
    }

    public async Task<IReadOnlyList<WarehouseOption>> GetWarehousesForUsernameAsync(
        string username, CancellationToken ct = default)
    {
        // §5.2: return [] for both unknown user and "no warehouses" — don't leak existence.
        var user = await _users.GetByUsernameAsync(username, ct);
        if (user is null || !user.IsActive) return Array.Empty<WarehouseOption>();

        if (string.Equals(user.Role, "admin", StringComparison.Ordinal))
        {
            var all = await _warehouses.GetAllActiveAsync(ct);
            return all.Select(w => new WarehouseOption(w.Id, w.Code, w.Name)).ToList();
        }

        var assigned = await _assignments.GetWarehousesForUserAsync(user.Id, ct);
        return assigned.Select(a => new WarehouseOption(a.Id, a.Code, a.Name)).ToList();
    }

    public MeResponse? GetCurrentSession()
    {
        var ctx = _httpContext.HttpContext;
        var user = ctx?.User;
        if (user?.Identity is null || !user.Identity.IsAuthenticated) return null;

        var name = user.FindFirstValue("displayName") ?? "";
        var whRole = user.FindFirstValue("whRole") ?? "";
        var globalRole = user.FindFirstValue(ClaimTypes.Role) ?? "";
        var whIdStr = user.FindFirstValue("warehouseId") ?? "";
        Guid.TryParse(whIdStr, out var whId);

        return new MeResponse(
            Username:      user.Identity.Name ?? "",
            Name:          name,
            Email:         user.FindFirstValue("email") ?? "",
            Role:          RoleLabel(whRole),
            RoleKey:       whRole,
            GlobalRole:    globalRole,
            Initials:      Initials(name),
            WarehouseId:   whId,
            WarehouseCode: user.FindFirstValue("warehouseCode") ?? "",
            WarehouseName: user.FindFirstValue("warehouseName") ?? "");
    }

    private static string RoleLabel(string roleKey) => roleKey switch
    {
        "admin"      => "Administrator",
        "supervisor" => "Inbound Supervisor",
        "operator"   => "Warehouse Operator",
        "viewer"     => "Viewer",
        "customer"   => "Customer Signer",
        "warehouse"  => "Warehouse Signer",
        "production" => "Production Signer",
        _            => "User",
    };

    private static string Initials(string name)
    {
        if (string.IsNullOrWhiteSpace(name)) return "??";
        var parts = name.Split(new[] { ' ', '.', '-' }, StringSplitOptions.RemoveEmptyEntries);
        var chars = parts.Take(2).Select(p => char.ToUpperInvariant(p[0])).ToArray();
        return new string(chars);
    }
}

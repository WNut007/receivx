using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Services;

public interface IAuthService
{
    /// <summary>§5.1 full login flow: validate, sign in, audit, return session info.</summary>
    Task<AuthResult> LoginAsync(LoginRequest req, CancellationToken ct = default);

    /// <summary>§5.4 logout: sign out + audit. Safe to call when unauthenticated.</summary>
    Task LogoutAsync(CancellationToken ct = default);

    /// <summary>§5.2 warehouses available to a username (admins see all active).</summary>
    Task<IReadOnlyList<WarehouseOption>> GetWarehousesForUsernameAsync(string username, CancellationToken ct = default);

    /// <summary>§5.3 current session claims as a flat DTO.</summary>
    MeResponse? GetCurrentSession();
}

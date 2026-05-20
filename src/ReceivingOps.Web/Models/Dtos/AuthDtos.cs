namespace ReceivingOps.Web.Models.Dtos;

public record LoginRequest(string Username, string Password, Guid WarehouseId, bool Remember);

public record SessionInfo(
    string Name,
    string Role,
    string RoleKey,
    string Initials,
    string WarehouseCode,
    string WarehouseName,
    string RedirectTo);

public record WarehouseOption(Guid Id, string Code, string Name);

public record MeResponse(
    string Username,
    string Name,
    string Email,
    string Role,         // human label
    string RoleKey,      // admin|supervisor|operator|viewer (whRole)
    string GlobalRole,   // raw Users.Role for admin-override checks
    string Initials,
    Guid WarehouseId,
    string WarehouseCode,
    string WarehouseName);

public abstract record AuthResult
{
    public sealed record Success(SessionInfo Info) : AuthResult;
    public sealed record Failure(int Status, string Title) : AuthResult;
}

using ReceivingOps.Web.Models.Dtos;
using ReceivingOps.Web.Models.Entities;

namespace ReceivingOps.Web.Data.Repositories;

public interface IWarehouseRepository
{
    // ----- existing (auth) -----
    Task<Warehouse?> GetByIdAsync(Guid id, CancellationToken ct = default);
    Task<IReadOnlyList<Warehouse>> GetAllActiveAsync(CancellationToken ct = default);

    // ----- masters CRUD -----
    Task<IReadOnlyList<WarehouseListRow>> QueryAsync(string? status, string? q, CancellationToken ct = default);
    Task<WarehouseListRow?> GetListRowAsync(Guid id, CancellationToken ct = default);
    Task<bool> ExistsByCodeAsync(string code, CancellationToken ct = default);
    Task<Guid> CreateAsync(WarehouseCreateRequest req, CancellationToken ct = default);
    Task<int> UpdateAsync(Guid id, WarehouseUpdateRequest req, CancellationToken ct = default);
    Task<int> DeleteAsync(Guid id, CancellationToken ct = default);
}

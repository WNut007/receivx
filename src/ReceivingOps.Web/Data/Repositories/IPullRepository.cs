using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Data.Repositories;

public interface IPullRepository
{
    Task<IReadOnlyList<PullSummary>> QueryAsync(PullQuery filter, CancellationToken ct = default);
    Task<PullDetail?> GetByIdAsync(Guid id, CancellationToken ct = default);
    Task<PullDetail?> GetByPullNumberAsync(string pullNumber, CancellationToken ct = default);
}

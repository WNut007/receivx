using ReceivingOps.Web.Models.Entities;

namespace ReceivingOps.Web.Data.Repositories;

public interface IPreferencesRepository
{
    /// <summary>Returns the user's preferences row, or null if none has been written yet.</summary>
    Task<UserPreferences?> GetAsync(Guid userId, CancellationToken ct = default);

    /// <summary>Insert or update the preferences row.</summary>
    Task UpsertAsync(UserPreferences prefs, CancellationToken ct = default);
}

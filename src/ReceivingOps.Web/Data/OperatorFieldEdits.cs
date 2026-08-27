using System.Data;
using Dapper;

namespace ReceivingOps.Web.Data;

// ---------------------------------------------------------------------------
// Operator field ownership — "once data is in Receivx, it belongs to Receivx".
//
// ERP sync populates a pull initially. After that, any field an operator
// changes is authoritative and no later sync may write it again, for the life
// of that pull, EVEN IF ERP later sends a different value. There is no
// comparison against the ERP value and no conflict flag: the operator wins
// permanently. See db/052 for the full decision record.
//
// This is the per-row, dynamic complement to the STATIC protected-column list
// in ErpUpsertService. That list names columns ETL must never write for
// anybody (Pulls.Status, PullItemWindows.ReceivedQty, …) and is unchanged.
// This decides, per row and per field, at runtime. Neither replaces the other.
//
// Protection is FIELD-level. Editing Remark must not freeze ExpectedQty.
// ---------------------------------------------------------------------------

/// <summary>
/// Reads and writes <c>dbo.OperatorFieldEdits</c>. Static and SQL-only, in the
/// same shape as <see cref="PullScopeSql"/> and <c>VendorCodeSql</c> — one
/// definition, so the write sites and the ETL read cannot drift on what
/// ownership means.
/// </summary>
public static class OperatorFieldEdits
{
    // Entity types. Mirrors CK_OFE_EntityType in db/052.
    public const string Pull = "Pull";
    public const string PullItem = "PullItem";
    public const string PullItemWindow = "PullItemWindow";

    /// <summary>
    /// The twelve protectable column names — every field an operator can
    /// change that ETL also writes. Compile-time constants, never operator
    /// input, which is what makes it safe for the ETL to interpolate them into
    /// a dynamic SET clause.
    ///
    /// <para>Fields an operator can edit that ETL never writes (Eta, Notes,
    /// ReferenceNumber, VendorName, Tag, the window close/variance columns)
    /// are absent on purpose: they need no protection and recording them would
    /// imply a guarantee this mechanism does not provide.</para>
    /// </summary>
    public static class Fields
    {
        // dbo.Pulls
        public const string PullDate = "PullDate";

        // dbo.PullItems — the three on the general edit endpoint
        public const string Description = "Description";
        public const string VendorCode = "VendorCode";
        public const string Remark = "Remark";

        // dbo.PullItems — the seven Phase 9.1 extended fields
        public const string ProductFamily = "ProductFamily";
        public const string FromSubInventory = "FromSubInventory";
        public const string ToSubInventory = "ToSubInventory";
        public const string SpecialControl = "SpecialControl";
        public const string TrialId = "TrialId";
        public const string Location = "Location";
        public const string Phase = "Phase";

        // dbo.PullItemWindows
        public const string ExpectedQty = "ExpectedQty";
    }

    /// <summary>Provenance value for <c>dbo.PullItems.Origin</c> — see db/052.</summary>
    public const string OriginOperator = "operator";

    // ----------------------------------------------------------------------
    // Write side
    // ----------------------------------------------------------------------

    /// <summary>
    /// One field's before/after, as seen at the moment of an operator write.
    /// </summary>
    public readonly record struct FieldChange(string FieldName, object? OldValue, object? NewValue);

    /// <summary>
    /// Records ownership for every change whose value ACTUALLY DIFFERS.
    ///
    /// <para><b>Ownership comes from a value diff, never from request
    /// presence.</b> The operator endpoints are bulk-overwrite PUTs: every
    /// request carries every field, and a blank means NULL. "The request
    /// included Remark" is therefore true on every single call and says
    /// nothing about whether the operator changed it. Marking on presence
    /// would freeze all of an item's fields on the first PUT of any kind,
    /// silently turning field-level protection into row-level protection
    /// while every test still passed.</para>
    ///
    /// <para>Do not "simplify" this into marking whatever the request carried.
    /// The distinction is the feature.</para>
    ///
    /// <para>Ownership is never released. A field edited back to its original
    /// ERP value stays owned — see the un-editing decision in db/052.</para>
    ///
    /// <para>Callers already hold the pull lock (LockPullAsync), so the
    /// UPDATE-then-INSERT below cannot race another writer for the same key.</para>
    /// </summary>
    /// <returns>The field names actually marked.</returns>
    public static async Task<IReadOnlyList<string>> MarkChangedAsync(
        IDbConnection conn, IDbTransaction tx,
        string entityType, Guid entityId,
        IEnumerable<FieldChange> changes, Guid? editedBy,
        CancellationToken ct = default)
    {
        var marked = new List<string>();

        foreach (var change in changes)
        {
            if (SameValue(change.OldValue, change.NewValue)) continue;

            var rows = await conn.ExecuteAsync(new CommandDefinition(@"
                UPDATE dbo.OperatorFieldEdits
                   SET LastEditedAt = SYSUTCDATETIME(),
                       LastEditedBy = @EditedBy
                 WHERE EntityType = @EntityType
                   AND EntityId   = @EntityId
                   AND FieldName  = @FieldName;",
                new { EntityType = entityType, EntityId = entityId, change.FieldName, EditedBy = editedBy },
                transaction: tx, cancellationToken: ct));

            if (rows == 0)
            {
                await conn.ExecuteAsync(new CommandDefinition(@"
                    INSERT INTO dbo.OperatorFieldEdits
                           (EntityType, EntityId, FieldName,
                            FirstEditedAt, FirstEditedBy, LastEditedAt, LastEditedBy)
                    VALUES (@EntityType, @EntityId, @FieldName,
                            SYSUTCDATETIME(), @EditedBy, SYSUTCDATETIME(), @EditedBy);",
                    new { EntityType = entityType, EntityId = entityId, change.FieldName, EditedBy = editedBy },
                    transaction: tx, cancellationToken: ct));
            }

            marked.Add(change.FieldName);
        }

        return marked;
    }

    /// <summary>
    /// Value equality as the diff sees it.
    ///
    /// <para>Whitespace-only strings normalize to NULL first, because the edit
    /// endpoints save a blank input as NULL. Without that, clearing an already
    /// empty field would register as a change and take ownership of a field
    /// nobody meaningfully touched.</para>
    /// </summary>
    private static bool SameValue(object? a, object? b)
    {
        a = Normalize(a);
        b = Normalize(b);

        if (a is null && b is null) return true;
        if (a is null || b is null) return false;

        if (a is string sa && b is string sb)
            return string.Equals(sa, sb, StringComparison.Ordinal);

        if (a is DateTime da && b is DateTime db)
            return da == db;

        return a.Equals(b);
    }

    private static object? Normalize(object? v)
        => v is string s && string.IsNullOrWhiteSpace(s) ? null : v;

    // ----------------------------------------------------------------------
    // Read side
    // ----------------------------------------------------------------------

    /// <summary>
    /// Every ownership mark covering one pull — the pull row itself, its
    /// items, and those items' windows — in ONE round trip.
    ///
    /// <para>Called once per pull from inside the ETL's existing per-pull
    /// transaction, which already holds UPDLOCK on the pull. Reading once per
    /// RUN instead would be cheaper but sits outside that transaction and
    /// would miss an operator edit landing mid-run, which is the exact failure
    /// this feature exists to prevent.</para>
    ///
    /// <para>Cost is one seek per entity group against a table that only holds
    /// genuinely-edited fields, ~469 times an hour.</para>
    /// </summary>
    public static async Task<OperatorEditSet> ReadForPullAsync(
        IDbConnection conn, IDbTransaction? tx, Guid pullId, CancellationToken ct = default)
    {
        var rows = await conn.QueryAsync<EditMark>(new CommandDefinition(@"
            SELECT e.EntityType, e.EntityId, e.FieldName
            FROM   dbo.OperatorFieldEdits e
            WHERE  (e.EntityType = 'Pull' AND e.EntityId = @PullId)
               OR  (e.EntityType = 'PullItem' AND e.EntityId IN (
                        SELECT pi.Id FROM dbo.PullItems pi WHERE pi.PullId = @PullId))
               OR  (e.EntityType = 'PullItemWindow' AND e.EntityId IN (
                        SELECT w.Id
                        FROM   dbo.PullItemWindows w
                        INNER JOIN dbo.PullItems pi2 ON pi2.Id = w.PullItemId
                        WHERE  pi2.PullId = @PullId));",
            new { PullId = pullId }, transaction: tx, cancellationToken: ct));

        return new OperatorEditSet(rows);
    }

    /// <summary>Dapper materialization shape for <see cref="ReadForPullAsync"/>.</summary>
    internal sealed record EditMark(string EntityType, Guid EntityId, string FieldName);

    /// <summary>
    /// The ownership marks for one pull, in memory. Immutable and cheap to ask.
    /// </summary>
    public sealed class OperatorEditSet
    {
        private readonly HashSet<(string EntityType, Guid EntityId, string FieldName)> _owned;

        internal OperatorEditSet(IEnumerable<EditMark> marks)
        {
            _owned = new HashSet<(string, Guid, string)>();
            foreach (var m in marks)
                _owned.Add((m.EntityType, m.EntityId, m.FieldName));
        }

        private OperatorEditSet() => _owned = new HashSet<(string, Guid, string)>();

        /// <summary>No marks — every field writable. Also what a pre-db/052 row looks like.</summary>
        public static OperatorEditSet Empty { get; } = new();

        public int Count => _owned.Count;

        /// <summary>True when an operator has edited this field on this row, so ETL must not write it.</summary>
        public bool IsOwned(string entityType, Guid entityId, string fieldName)
            => _owned.Contains((entityType, entityId, fieldName));
    }
}

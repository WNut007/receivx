# API pagination contract

Last updated: v2.2 (Phase 8 close).
Audience: anyone adding a new list endpoint or wiring a UI to one.

The contract is uniform across every paginated surface in the app — JSON
endpoints, the server-rendered Reports page, and the shared client
component all speak the same shape.

---

## 1. Request shape

`ReceivingOps.Web.Models.PaginatedRequest`:

```csharp
public class PaginatedRequest
{
    public int Page     { get; set; } = 1;   // 1-based
    public int PageSize { get; set; } = 50;

    public int Skip => Math.Max(0, (Math.Max(1, Page) - 1) * Take);
    public int Take => Math.Clamp(PageSize, 1, 500);
}
```

- **`Page` is 1-based** (operator-facing). `Page = 0` and negatives are
  normalized up to `1`.
- **`PageSize` defaults to 50** and is **hard-capped at 500**. The cap is
  on the server, not the client — a request for `pageSize=10000` returns
  500 rows, no error.
- `Skip` and `Take` are computed properties; pass them directly into
  Dapper `OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY` queries.

### Wire format

Bound from query string:

```
GET /api/pos?page=2&pageSize=50&warehouse=WH-01
```

Additional filter parameters (warehouse, date range, etc.) live alongside
`page` + `pageSize` — the partial / component preserves them across
navigation (see §5).

---

## 2. Response shape

`ReceivingOps.Web.Models.PaginatedResponse<T>`:

```csharp
public class PaginatedResponse<T>
{
    public IReadOnlyList<T> Items { get; set; } = Array.Empty<T>();
    public int Page     { get; set; }
    public int PageSize { get; set; }
    public int Total    { get; set; }

    // Computed
    public int  TotalPages => PageSize <= 0 ? 0 : (int)Math.Ceiling((double)Total / PageSize);
    public bool HasMore    => Page < TotalPages;
}
```

- **`Items`** — this page's slice.
- **`Total`** — unfiltered-by-paging row count. Drives "Showing X of Z"
  banners and page navigation. Must come from the same `WHERE` clause as
  the slice; the canonical pattern is a `QueryMultiple` that returns
  slice + count in one round trip:

  ```sql
  SELECT * FROM dbo.Foo WHERE Status = @Status
  ORDER BY CreatedAt DESC
  OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

  SELECT COUNT(*) FROM dbo.Foo WHERE Status = @Status;
  ```

- **`TotalPages` + `HasMore`** are computed properties — clients don't
  derive them.

### JSON example

```json
{
  "items": [ { "...": "..." } ],
  "page": 2,
  "pageSize": 50,
  "total": 312,
  "totalPages": 7,
  "hasMore": true
}
```

---

## 3. Surfaces using the contract

| Surface | Type | Endpoint / route |
|---|---|---|
| Purchase Orders | JSON | `GET /api/pos` |
| Transactions | JSON | `GET /api/transactions` |
| My Exports | JSON | `GET /api/exports/jobs` |
| Reports list | Server-rendered | `GET /Reports?page=N&pageSize=M` |

JSON surfaces return `PaginatedResponse<T>`. The Reports controller
hydrates a `PaginatedResponse<PullSummary>` server-side and passes it
to the Razor view, which renders the `_Pagination.cshtml` partial below
the result list.

---

## 4. Server-render variant (Reports)

Reports is the only paginated page without AJAX — page navigation is
plain `<a href="?page=N&...">` to keep filter URLs shareable. The partial
that renders the page bar is `Views/Shared/_Pagination.cshtml`, fed by
`PaginationPartialModel`:

```csharp
public class PaginationPartialModel
{
    public int Page       { get; set; } = 1;
    public int PageSize   { get; set; } = 50;
    public int Total      { get; set; }
    public string? BaseQuery { get; set; }   // "dateRange=last_2_days&warehouse=WH-01"
    public string? Label     { get; set; }   // caption suffix, default "records"
    public int MaxButtons    { get; set; }   // window before ellipsis, default 7
}
```

`BaseQuery` is the **current query string with `page=` stripped**. The
partial appends `page=N` to each rendered link, so filters survive
navigation without the controller having to enumerate them.

Render call:

```cshtml
@await Html.PartialAsync("_Pagination", new PaginationPartialModel
{
    Page = Model.Page,
    PageSize = Model.PageSize,
    Total = Model.Total,
    BaseQuery = ViewBag.BaseQuery as string,
    Label = "pulls"
})
```

---

## 5. Client component (AJAX surfaces)

`wwwroot/js/components/pagination.js` exposes `mountPagination()` for
JSON-fed lists.

```js
const ctrl = mountPagination(containerEl, {
    page: 1, pageSize: 50, total: 0,
    label: 'exports',
    ariaLabel: 'My exports pagination',
    onChange: (newPage) => {
        currentPage = newPage;
        loadList(); // your fetch — and call ctrl.update() in the response handler
    }
});

// After loadList() completes:
ctrl.update({ page: response.page, total: response.total, pageSize: 50 });

// On teardown (rare; mostly SPA transitions):
ctrl.destroy();
```

### Page-aware ellipsis

With `totalPages > maxButtons` (default 7), the rendered set is:

```
Prev  1  …  (cur-1)  cur  (cur+1)  …  N  Next
```

First, last, and current ± 1 are always visible regardless of N. The
control hides itself (sets `hidden` on the wrapper) when
`totalPages <= 1` so the host page doesn't need to gate visibility.

### Shared CSS

`wwwroot/css/components/pagination.css` themes both the JS component and
the Razor partial — same DOM shape, same selectors, single source of
truth for spacing / colors / hover states.

---

## 6. Conventions

- **Filter changes reset to page 1.** Whenever the user toggles a
  warehouse, status, date range, or any other server-side filter, jump
  back to `page=1` before reissuing the fetch — staying on page 7 of a
  filter that now only has 2 pages is a bad UX. The /Pos, /Transactions,
  /Exports, and /Reports surfaces all do this.
- **Page size is server-policy, not user-policy.** The 500-row cap
  exists so that no operator can accidentally pull a million-row export
  through the list endpoint — that's the export pipeline's job. Don't
  expose a "rows per page" picker that lets users opt past 500.
- **`Total` must come from the same `WHERE` as the slice.** Easy to get
  this wrong when the slice query joins extra tables for display fields
  the count doesn't need. If page counts ever look off-by-N, this is the
  first place to look.
- **Sort order belongs in the SQL, not in the contract.** The pagination
  contract doesn't carry sort parameters — each endpoint picks its own
  stable ordering (`ORDER BY CreatedAt DESC, Id` is the common pattern).
  If you need user-controlled sort, layer it onto the query string
  alongside `page` + `pageSize` and document it on that endpoint.

---

## 7. Adding a new paginated endpoint

1. Accept `PaginatedRequest` (or `[FromQuery] int page = 1, int pageSize = 50`).
2. Use `req.Skip` and `req.Take` directly in the SQL.
3. Return `PaginatedResponse<T>` with the slice + accurate `Total`.
4. For UI: pick AJAX (`mountPagination`) or server-rendered
   (`_Pagination.cshtml`) based on whether deep-linkable filter URLs
   matter.
5. Smoke test the page-2 boundary — most pagination bugs are
   off-by-one or `Total` mismatches that only surface past page 1.

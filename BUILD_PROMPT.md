# BUILD PROMPT — Receiving OPS v3.2 (ASP.NET Core 8 + Dapper + SQL Server)

You are a senior .NET developer. Build a complete ASP.NET Core 8 MVC application that turns the existing HTML/CSS/JS mockup of **Receiving OPS v3.2** into a working multi-warehouse receiving system. The mockup files are provided:

| File | Role |
|---|---|
| `login.html` | Split-panel login with warehouse picker driven by master data |
| `pull-controller-v2.html` | Kanban dashboard (4 columns) of pull sheets with stats strip + drawer |
| `receiving-mockup-v2-fullreceived.html` | Hour-grid receiving console with cell→Receive Goods modal + transactions drawer + close-pull signature flow + supervisor reopen |
| `transactions.html` | Standalone searchable receipt journal across all pulls |
| `masters.html` | User + Warehouse + Audit Log CRUD with N:M assignments |
| `config.html` | Theme + nav-position + nav-behavior settings |
| `app-nav.js` | Shared nav, auth guard, theme switcher, profile dropdown — injected on every page |

**Reuse the existing layout, classes, IDs, and JS behavior exactly.** Your job is the backend, persistence, and replacing `localStorage` reads/writes with API calls. Do not redesign the UI.

---

## 1. Stack & Conventions

- **Framework**: ASP.NET Core 8 MVC, C# 12, .NET 8 LTS.
- **Data access**: Dapper only (no EF Core). Parameterized queries everywhere. No string concatenation in SQL.
- **Database**: SQL Server (local instance). All tables in `dbo`.
- **Frontend**: keep HTML/CSS exactly as it is. Replace `localStorage`-backed JS logic with `fetch()` calls. Bootstrap 5.3 + Bootstrap Icons stay.
- **Auth**: cookie authentication (`Microsoft.AspNetCore.Authentication.Cookies`). No JWT unless explicitly requested.
- **Password hashing**: PBKDF2 via `Microsoft.AspNetCore.Identity.PasswordHasher<T>` — never store plaintext.
- **DI**: repositories `Scoped`, `IDbConnection` factory `Scoped`, services `Scoped`.
- **SQL naming**: PascalCase columns matching POCO properties directly (no Dapper mapping required).
- **Routing**: attribute routing on API controllers (`[Route("api/[controller]")]`), conventional routing for MVC views.
- **Return shape**: API controllers return `ActionResult<T>` with proper status codes. Errors return RFC 7807 `ProblemDetails`.
- **Logging**: `ILogger<T>` injected. Log every write, every login, every permission denial.
- **JSON**: camelCase property names; ignore nulls on serialization.

---

## 2. Connection String

**Server**: `LAPTOP-CSB3KO3E` • **User**: `LAPTOP-CSB3KO3E` • **Password**: `Pocket007` • **Database**: `ReceivingOps`

```json
// appsettings.Development.json (gitignored)
{
  "ConnectionStrings": {
    "Default": "Server=LAPTOP-CSB3KO3E;Database=ReceivingOps;User Id=LAPTOP-CSB3KO3E;Password=Pocket007;TrustServerCertificate=True;Encrypt=False;Application Name=ReceivingOps;"
  }
}
```

> ⚠️ **Security**: this credential is acceptable only for local development. Before any commit, move it to **User Secrets** (`dotnet user-secrets set "ConnectionStrings:Default" "..."`) or environment variables. Production must use Managed Identity or a vault — never a hardcoded SQL login. Add `appsettings.Development.json` to `.gitignore` if it ends up containing the password.

```csharp
public interface IDbConnectionFactory { IDbConnection Create(); }

public class SqlConnectionFactory(IConfiguration config) : IDbConnectionFactory
{
    private readonly string _cs = config.GetConnectionString("Default")
        ?? throw new InvalidOperationException("Connection string 'Default' missing");
    public IDbConnection Create() => new SqlConnection(_cs);
}
```

Register: `services.AddScoped<IDbConnectionFactory, SqlConnectionFactory>();`

---

## 3. Project Structure

```
ReceivingOps.sln
└── src/
    └── ReceivingOps.Web/
        ├── Controllers/
        │   ├── AccountController.cs        (Login/Logout views)
        │   ├── DashboardController.cs      (Pull Controller view)
        │   ├── ReceivingController.cs      (Hour-grid receiving view)
        │   ├── TransactionsController.cs   (Standalone journal view)
        │   ├── MastersController.cs        (Users + Warehouses + Audit Log)
        │   ├── ConfigController.cs         (Settings)
        │   └── Api/
        │       ├── AuthApiController.cs
        │       ├── UsersApiController.cs
        │       ├── WarehousesApiController.cs
        │       ├── AssignmentsApiController.cs
        │       ├── PullsApiController.cs
        │       ├── PullItemsApiController.cs
        │       ├── ReceiptsApiController.cs
        │       ├── TransactionsApiController.cs
        │       ├── AuditApiController.cs
        │       └── PreferencesApiController.cs
        ├── Models/
        │   ├── Entities/        (POCOs that match tables 1:1)
        │   ├── Dtos/            (request/response shapes)
        │   └── ViewModels/      (for Razor views)
        ├── Services/
        │   ├── IAuthService.cs / AuthService.cs
        │   ├── IPullService.cs / PullService.cs
        │   ├── IReceiptService.cs / ReceiptService.cs   ← receive + cancel/reverse
        │   ├── ICloseService.cs / CloseService.cs       ← close + reopen
        │   └── IAuditService.cs / AuditService.cs
        ├── Data/
        │   ├── IDbConnectionFactory.cs
        │   ├── SqlConnectionFactory.cs
        │   └── Repositories/        (one per table; interfaces + implementations)
        ├── Views/                    (Razor — one per controller)
        ├── wwwroot/
        │   ├── css/site.css          (lift the <style> blocks from the mockups)
        │   ├── js/app-nav.js         (kept as-is, swap localStorage for fetch)
        │   ├── js/login.js
        │   ├── js/dashboard.js
        │   ├── js/receiving.js       (largest — includes drawer + modal-embedded tx + close/reopen)
        │   ├── js/transactions.js
        │   ├── js/masters.js
        │   └── js/config.js
        ├── Program.cs
        ├── appsettings.json
        └── appsettings.Development.json  (gitignored)
└── db/
    ├── 001_schema.sql
    ├── 002_views.sql
    ├── 003_seed_users.sql
    ├── 004_seed_warehouses.sql
    ├── 005_seed_assignments.sql
    └── 006_seed_pulls_and_items.sql
└── tools/
    └── HashPassword/                 (small console: takes plaintext → emits PBKDF2 hash)
```

---

## 4. Database Schema

Generate as **idempotent migration scripts** in `db/001_schema.sql`. Use `NVARCHAR` for human text, `VARCHAR` for codes, `DATETIME2(0)` for timestamps, `BIT` for booleans, `UNIQUEIDENTIFIER DEFAULT NEWID()` for surrogate IDs.

### 4.1 Warehouses

```sql
CREATE TABLE dbo.Warehouses (
    Id          UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID() PRIMARY KEY,
    Code        VARCHAR(16)      NOT NULL UNIQUE,
    Name        NVARCHAR(120)    NOT NULL,
    City        NVARCHAR(80)     NULL,
    Country     CHAR(2)          NULL,
    Address     NVARCHAR(255)    NULL,
    Capacity    INT              NOT NULL DEFAULT 0,
    Timezone    VARCHAR(64)      NOT NULL DEFAULT 'Asia/Bangkok',
    ManagerId   UNIQUEIDENTIFIER NULL,
    Phone       VARCHAR(32)      NULL,
    IsActive    BIT              NOT NULL DEFAULT 1,
    CreatedAt   DATETIME2(0)     NOT NULL DEFAULT SYSUTCDATETIME(),
    UpdatedAt   DATETIME2(0)     NULL
);
```

### 4.2 Users

```sql
CREATE TABLE dbo.Users (
    Id            UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID() PRIMARY KEY,
    Username      VARCHAR(64)      NOT NULL UNIQUE,
    Name          NVARCHAR(120)    NOT NULL,
    Email         NVARCHAR(160)    NULL,
    Phone         VARCHAR(32)      NULL,
    Role          VARCHAR(20)      NOT NULL CHECK (Role IN ('admin','supervisor','operator','viewer')),
    PasswordHash  NVARCHAR(512)    NOT NULL,
    IsActive      BIT              NOT NULL DEFAULT 1,
    LastSignInAt  DATETIME2(0)     NULL,
    CreatedAt     DATETIME2(0)     NOT NULL DEFAULT SYSUTCDATETIME(),
    UpdatedAt     DATETIME2(0)     NULL
);

ALTER TABLE dbo.Warehouses
  ADD CONSTRAINT FK_Warehouses_Manager
  FOREIGN KEY (ManagerId) REFERENCES dbo.Users(Id) ON DELETE SET NULL;
```

### 4.3 UserWarehouseAssignments — N:M with role per assignment

```sql
CREATE TABLE dbo.UserWarehouseAssignments (
    UserId      UNIQUEIDENTIFIER NOT NULL,
    WarehouseId UNIQUEIDENTIFIER NOT NULL,
    Role        VARCHAR(20)      NOT NULL CHECK (Role IN ('admin','supervisor','operator','viewer')),
    AssignedAt  DATETIME2(0)     NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_UserWarehouse PRIMARY KEY (UserId, WarehouseId),
    CONSTRAINT FK_UWA_User      FOREIGN KEY (UserId)      REFERENCES dbo.Users(Id)      ON DELETE CASCADE,
    CONSTRAINT FK_UWA_Warehouse FOREIGN KEY (WarehouseId) REFERENCES dbo.Warehouses(Id) ON DELETE CASCADE
);

CREATE INDEX IX_UWA_Warehouse ON dbo.UserWarehouseAssignments(WarehouseId);
```

### 4.4 Pulls — with close + reopen history fields

```sql
CREATE TABLE dbo.Pulls (
    Id             UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID() PRIMARY KEY,
    PullNumber     VARCHAR(32)      NOT NULL UNIQUE,
    WarehouseId    UNIQUEIDENTIFIER NOT NULL,
    PullDate       DATE             NOT NULL,
    Status         VARCHAR(20)      NOT NULL CHECK (Status IN ('pending','in_progress','fully_received','closed')),
    Eta            VARCHAR(64)      NULL,
    Notes          NVARCHAR(500)    NULL,
    CreatedBy      UNIQUEIDENTIFIER NULL,
    CreatedAt      DATETIME2(0)     NOT NULL DEFAULT SYSUTCDATETIME(),
    FirstReceiptAt DATETIME2(0)     NULL,
    LastActivityAt DATETIME2(0)     NULL,
    -- Close fields (set on close; PRESERVED across reopen so the history isn't lost)
    ClosedAt       DATETIME2(0)     NULL,
    ClosedBy       UNIQUEIDENTIFIER NULL,
    SignatureSvg   NVARCHAR(MAX)    NULL,
    -- Reopen fields (set when supervisor unlocks a closed pull)
    ReopenedAt     DATETIME2(0)     NULL,
    ReopenedBy     UNIQUEIDENTIFIER NULL,
    ReopenReason   NVARCHAR(500)    NULL,
    -- PO scoping policy — IMMUTABLE after pull creation (see §7.15)
    --   false: FIFO scope = all open POs in the warehouse (cross-pull pool)
    --   true:  FIFO scope = only POs explicitly linked to this pull (po.PullId = this.Id)
    LockPoByPull   BIT              NOT NULL CONSTRAINT DF_Pulls_LockPoByPull DEFAULT 0,
    CONSTRAINT FK_Pulls_Warehouse  FOREIGN KEY (WarehouseId) REFERENCES dbo.Warehouses(Id),
    CONSTRAINT FK_Pulls_CreatedBy  FOREIGN KEY (CreatedBy)   REFERENCES dbo.Users(Id),
    CONSTRAINT FK_Pulls_ClosedBy   FOREIGN KEY (ClosedBy)    REFERENCES dbo.Users(Id),
    CONSTRAINT FK_Pulls_ReopenedBy FOREIGN KEY (ReopenedBy)  REFERENCES dbo.Users(Id)
);

CREATE INDEX IX_Pulls_WhDate ON dbo.Pulls(WarehouseId, PullDate);
CREATE INDEX IX_Pulls_Status ON dbo.Pulls(Status);
```

> **Why `LockPoByPull` is `NOT NULL` with a default of `0`**: backward compatibility for existing pulls — every pre-feature pull defaults to "warehouse-wide FIFO" (the v1 semantic). New pulls can opt into strict per-pull locking via the create form. Once set, the value is immutable for the life of the pull (see §7.15).

### 4.5 PullItems

```sql
CREATE TABLE dbo.PullItems (
    Id          UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID() PRIMARY KEY,
    PullId      UNIQUEIDENTIFIER NOT NULL,
    ItemCode    VARCHAR(64)      NOT NULL,
    Description NVARCHAR(255)    NOT NULL,
    VendorCode  VARCHAR(64)      NULL,
    VendorName  NVARCHAR(160)    NULL,
    Tag         VARCHAR(16)      NULL CHECK (Tag IN ('pcba','swap') OR Tag IS NULL),
    Status      VARCHAR(16)      NOT NULL CHECK (Status IN ('normal','new','canceled')) DEFAULT 'normal',
    Remark      NVARCHAR(255)    NULL,
    SortOrder   INT              NOT NULL DEFAULT 0,
    CONSTRAINT FK_PullItems_Pull FOREIGN KEY (PullId) REFERENCES dbo.Pulls(Id) ON DELETE CASCADE
);

CREATE INDEX IX_PullItems_Pull ON dbo.PullItems(PullId);
```

### 4.5a PurchaseOrders + PurchaseOrderLines — qty source of truth

**Purchase orders are the hard cap on receive quantities.** Each PO header has many lines; each line represents one item with an ordered quantity. The `PullItems`/`PullItemWindows` schedule says **when** material is expected; the PO line says **how much is actually ordered** — and the server will not let receive totals exceed `OrderedQty`.

PO lifecycle is independent of pull lifecycle: POs are created (typically imported from ERP) before any pull is planned and stay alive across many pulls until fully received.

```sql
CREATE TABLE dbo.PurchaseOrders (
    Id             UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID() PRIMARY KEY,
    PoNumber       VARCHAR(32)      NOT NULL UNIQUE,
    WarehouseId    UNIQUEIDENTIFIER NOT NULL,
    VendorCode     VARCHAR(64)      NULL,
    VendorName     NVARCHAR(160)    NULL,
    OrderDate      DATE             NOT NULL,                    -- the FIFO key for allocation
    ExpectedDate   DATE             NULL,
    Status         VARCHAR(16)      NOT NULL DEFAULT 'open'
                    CHECK (Status IN ('open','closed','canceled')),
    Notes          NVARCHAR(500)    NULL,
    CreatedBy      UNIQUEIDENTIFIER NULL,
    CreatedAt      DATETIME2(0)     NOT NULL DEFAULT SYSUTCDATETIME(),
    ClosedAt       DATETIME2(0)     NULL,                        -- set automatically when all lines fully received
    -- Optional direct link to a single pull. When set, this PO is reserved for that pull
    -- if (and only if) the pull has LockPoByPull = 1. Set at PO creation; IMMUTABLE (see §7.15).
    PullId         UNIQUEIDENTIFIER NULL,
    CONSTRAINT FK_PO_Warehouse FOREIGN KEY (WarehouseId) REFERENCES dbo.Warehouses(Id),
    CONSTRAINT FK_PO_CreatedBy FOREIGN KEY (CreatedBy)   REFERENCES dbo.Users(Id),
    CONSTRAINT FK_PO_Pull      FOREIGN KEY (PullId)      REFERENCES dbo.Pulls(Id)
);

CREATE INDEX IX_PO_FIFO ON dbo.PurchaseOrders(WarehouseId, Status, OrderDate); -- the FIFO query path
CREATE INDEX IX_PO_Pull ON dbo.PurchaseOrders(PullId) WHERE PullId IS NOT NULL; -- filtered: lock=true lookup

CREATE TABLE dbo.PurchaseOrderLines (
    Id              UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID() PRIMARY KEY,
    PurchaseOrderId UNIQUEIDENTIFIER NOT NULL,
    LineNumber      INT              NOT NULL,                   -- 1, 2, 3... within the PO
    ItemCode        VARCHAR(64)      NOT NULL,
    Description     NVARCHAR(255)    NOT NULL,
    OrderedQty      INT              NOT NULL CHECK (OrderedQty > 0),
    ReceivedQty     INT              NOT NULL DEFAULT 0,         -- denormalized cache; truth = SUM(Receipts.QtyReceived) WHERE PurchaseOrderLineId = this
    CONSTRAINT FK_POL_PO PRIMARY KEY (Id),
    CONSTRAINT FK_POL_PurchaseOrder FOREIGN KEY (PurchaseOrderId) REFERENCES dbo.PurchaseOrders(Id) ON DELETE CASCADE,
    CONSTRAINT UQ_POL_LineNumber UNIQUE (PurchaseOrderId, LineNumber),
    CONSTRAINT CK_POL_Caps      CHECK (ReceivedQty <= OrderedQty AND ReceivedQty >= 0)
);

CREATE INDEX IX_POL_FIFO ON dbo.PurchaseOrderLines(ItemCode, PurchaseOrderId)
    INCLUDE (OrderedQty, ReceivedQty);
```

> **Why `PullId` is nullable**: most POs live in the cross-pull pool (the v1 default behavior). Only POs created for pulls that have `LockPoByPull = 1` need an explicit link. Mixing both styles in the same warehouse is a deliberate design choice — see §4.5b for how they interact.

> **Why the FIFO index includes `OrderedQty` and `ReceivedQty`**: the allocation query reads all open lines for `(WarehouseId, ItemCode)` ordered by `OrderDate ASC` and needs the remaining-qty calculation — the covering index makes this index-only.

### 4.5b Pull ↔ PO linking: two coexisting modes

POs and pulls can be linked in two different ways depending on how the planner sets up each pull. **Both modes coexist in the same warehouse** — the choice is per-pull, made at pull creation, and immutable thereafter.

**Mode A — Warehouse-wide pool (default, `Pulls.LockPoByPull = 0`)**:
- Pull and PO are linked **only through Receipts** at receive time
- FIFO allocator scopes by `WarehouseId` — all open POs in the warehouse are candidates
- `PurchaseOrders.PullId` is typically `NULL` for these POs (though it doesn't have to be — see Mode B caveat below)
- This is the v1 behavior; backward compatible

**Mode B — Pull-locked (`Pulls.LockPoByPull = 1`)**:
- Procurement must explicitly link one or more POs to the pull by setting `PurchaseOrders.PullId = @PullId` at PO creation
- FIFO allocator scopes by `PullId` — only POs with `po.PullId = pull.Id` are candidates
- Receiving on this pull when **no** PO is linked returns `409 "No PO linked to this pull"` (see §7.14)
- Use case: regulated workflows (pharma, aerospace) where each shipment must trace to a specific PO

**Important interaction caveat**: a PO with `PullId` set still appears in the cross-pull pool for **other** Mode-A pulls in the same warehouse. If `PO-2405-001` is linked to `PL-2900` (lock=1), an unrelated `PL-2899` (lock=0) can still consume from it via warehouse-wide FIFO. Procurement teams should be aware that "linking" reserves a PO for one pull's view of FIFO, but does **not** prevent other Mode-A pulls from draining it. Strict reservation is a possible future enhancement and is explicitly out of scope for v2.

The FIFO `OrderDate ASC, PoNumber ASC` ordering applies in both modes; what changes is the filter clause in the query (see §7.2).

### 4.6 PullItemWindows — expected qty per hour (planning hint)

Hour-of-day expected quantities are **planning hints**, not hard caps. The PO line's `OrderedQty` is the hard limit (see §4.5a). `PullItemWindows.ReceivedQty` is still maintained as a denormalized cache so the UI can render per-hour progress quickly.

```sql
CREATE TABLE dbo.PullItemWindows (
    Id          UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID() PRIMARY KEY,
    PullItemId  UNIQUEIDENTIFIER NOT NULL,
    HourOfDay   TINYINT          NOT NULL CHECK (HourOfDay BETWEEN 0 AND 23),
    ExpectedQty INT              NOT NULL DEFAULT 0,
    ReceivedQty INT              NOT NULL DEFAULT 0,
    CONSTRAINT FK_PIW_PullItem FOREIGN KEY (PullItemId) REFERENCES dbo.PullItems(Id) ON DELETE CASCADE,
    CONSTRAINT UQ_PIW_Hour     UNIQUE (PullItemId, HourOfDay),
    CONSTRAINT CK_PIW_NonNeg   CHECK (ReceivedQty >= 0)
);
```

> **What changed**: the old `CK_PIW_Caps` constraint enforced `ReceivedQty <= ExpectedQty`. That constraint is **removed** — receiving may now legitimately exceed the per-hour planned quantity (e.g. a truck arrives early and unloads two hours' worth in one) as long as the PO has remaining `OrderedQty`. The UI still shows per-hour expectation as a guide but no longer treats overage as an error.

### 4.7 Receipts — append-only with reverse-entry

This is the heart of the audit story. `Receipts` is **append-only**: never `UPDATE` except to set `ReversedById` on the original when a reversal is created, and never `DELETE`. Cancellations are recorded as new rows with negative `QtyReceived`.

```sql
CREATE TABLE dbo.Receipts (
    Id                    UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID() PRIMARY KEY,
    PullItemId            UNIQUEIDENTIFIER NOT NULL,

    -- PO binding (set by server-side FIFO allocator; cannot be chosen by the user)
    PurchaseOrderId       UNIQUEIDENTIFIER NOT NULL,
    PurchaseOrderLineId   UNIQUEIDENTIFIER NOT NULL,

    HourOfDay             TINYINT          NOT NULL CHECK (HourOfDay BETWEEN 0 AND 23),
    QtyReceived           INT              NOT NULL CHECK (QtyReceived <> 0),
    LotBatch              VARCHAR(64)      NULL,
    PalletId              VARCHAR(64)      NULL,
    BinLocation           VARCHAR(64)      NULL,
    QcStatus              VARCHAR(32)      NOT NULL DEFAULT 'pending'
                           CHECK (QcStatus IN ('pending','passed','hold','rejected')),
    Note                  NVARCHAR(500)    NULL,
    ReceivedBy            UNIQUEIDENTIFIER NOT NULL,
    ReceivedAt            DATETIME2(0)     NOT NULL DEFAULT SYSUTCDATETIME(),

    -- Reverse-entry linkage:
    ReversesReceiptId     UNIQUEIDENTIFIER NULL,
    ReversedById          UNIQUEIDENTIFIER NULL,
    CancelReason          VARCHAR(32)      NULL
                           CHECK (CancelReason IN ('miscount','wrong-item','qc-fail','duplicate','other') OR CancelReason IS NULL),

    CONSTRAINT FK_Receipts_Item     FOREIGN KEY (PullItemId)          REFERENCES dbo.PullItems(Id),
    CONSTRAINT FK_Receipts_PO       FOREIGN KEY (PurchaseOrderId)     REFERENCES dbo.PurchaseOrders(Id),
    CONSTRAINT FK_Receipts_POLine   FOREIGN KEY (PurchaseOrderLineId) REFERENCES dbo.PurchaseOrderLines(Id),
    CONSTRAINT FK_Receipts_User     FOREIGN KEY (ReceivedBy)          REFERENCES dbo.Users(Id),
    CONSTRAINT FK_Receipts_Reverses FOREIGN KEY (ReversesReceiptId)   REFERENCES dbo.Receipts(Id),
    CONSTRAINT FK_Receipts_Reversed FOREIGN KEY (ReversedById)        REFERENCES dbo.Receipts(Id),

    CONSTRAINT CK_Receipts_ReversalIntegrity CHECK (
        (ReversesReceiptId IS NULL AND QtyReceived > 0) OR
        (ReversesReceiptId IS NOT NULL AND QtyReceived < 0)
    )
);

CREATE INDEX IX_Receipts_PullItem ON dbo.Receipts(PullItemId, HourOfDay);
CREATE INDEX IX_Receipts_POLine   ON dbo.Receipts(PurchaseOrderLineId);
CREATE INDEX IX_Receipts_When     ON dbo.Receipts(ReceivedAt);
CREATE INDEX IX_Receipts_Reverses ON dbo.Receipts(ReversesReceiptId) WHERE ReversesReceiptId IS NOT NULL;
```

> **One receipt row = one allocation against one PO line.** A user entering "receive 2000 pcs" may produce **multiple receipt rows** if the FIFO allocator splits the qty across two or three PO lines (oldest PO had 1500 remaining, next PO covers the other 500, etc.). Each row remembers exactly which PO line it consumed, so cancellation is unambiguous: cancelling one row returns qty to exactly that PO line — no FIFO logic involved on the way back.

> **Why reverse-entry instead of soft-delete**: full audit fidelity. Both the original and the reversal are visible in chronological order; you can answer "what did the operator enter at 09:24?" *and* "who corrected it and why?" without forensics. Soft-delete erases the time of the mistake.

### 4.8 Helper views (`db/002_views.sql`)

```sql
-- Net received per (item, hour) — sums positive and negative rows. ALL downstream calculations use this.
CREATE OR ALTER VIEW dbo.vw_PullItemReceived AS
SELECT  PullItemId,
        HourOfDay,
        SUM(QtyReceived) AS NetReceived
FROM    dbo.Receipts
GROUP BY PullItemId, HourOfDay;
GO

-- Per-pull progress summary used by the dashboard
CREATE OR ALTER VIEW dbo.vw_PullProgress AS
SELECT  p.Id AS PullId,
        p.PullNumber,
        p.Status,
        p.WarehouseId,
        SUM(CASE WHEN pi.Status <> 'canceled' THEN piw.ExpectedQty ELSE 0 END) AS TotalExpected,
        SUM(CASE WHEN pi.Status <> 'canceled' THEN ISNULL(v.NetReceived, 0) ELSE 0 END) AS TotalReceived,
        COUNT(DISTINCT CASE WHEN pi.Status <> 'canceled' THEN pi.Id END) AS ActiveItemCount
FROM    dbo.Pulls p
LEFT JOIN dbo.PullItems pi          ON pi.PullId = p.Id
LEFT JOIN dbo.PullItemWindows piw   ON piw.PullItemId = pi.Id
LEFT JOIN dbo.vw_PullItemReceived v ON v.PullItemId = pi.Id AND v.HourOfDay = piw.HourOfDay
GROUP BY p.Id, p.PullNumber, p.Status, p.WarehouseId;
GO

-- Transactions journal (used by both the in-page drawer and the standalone page).
-- Now includes PO context so the UI shows which PO each receive consumed.
CREATE OR ALTER VIEW dbo.vw_TransactionsJournal AS
SELECT  r.Id,
        r.PullItemId,
        pi.PullId,
        p.PullNumber,
        p.WarehouseId,
        w.Code AS WarehouseCode,
        w.Name AS WarehouseName,
        pi.ItemCode,
        pi.Description AS ItemDescription,
        -- PO context — visible on every transaction row in the UI
        r.PurchaseOrderId,
        po.PoNumber,
        po.VendorCode,
        po.VendorName,
        r.PurchaseOrderLineId,
        pol.LineNumber AS PoLineNumber,
        r.HourOfDay,
        r.QtyReceived,
        r.LotBatch,
        r.PalletId,
        r.BinLocation,
        r.QcStatus,
        r.Note,
        r.ReceivedBy,
        u.Name AS ReceivedByName,
        r.ReceivedAt,
        r.ReversesReceiptId,
        r.ReversedById,
        r.CancelReason,
        CASE
            WHEN r.QtyReceived < 0          THEN 'reversal'
            WHEN r.ReversedById IS NOT NULL THEN 'voided'
            ELSE 'receive'
        END AS Kind
FROM    dbo.Receipts r
INNER JOIN dbo.PullItems pi          ON pi.Id = r.PullItemId
INNER JOIN dbo.Pulls p               ON p.Id  = pi.PullId
INNER JOIN dbo.Warehouses w          ON w.Id  = p.WarehouseId
INNER JOIN dbo.Users u               ON u.Id  = r.ReceivedBy
INNER JOIN dbo.PurchaseOrders po     ON po.Id = r.PurchaseOrderId
INNER JOIN dbo.PurchaseOrderLines pol ON pol.Id = r.PurchaseOrderLineId;
GO

-- PO line availability — what's left to receive on each open PO line, in FIFO order.
-- This is the view the FIFO allocator (§7.2a) reads under UPDLOCK.
CREATE OR ALTER VIEW dbo.vw_PurchaseOrderAvailability AS
SELECT  pol.Id            AS PurchaseOrderLineId,
        pol.PurchaseOrderId,
        po.PoNumber,
        po.WarehouseId,
        po.VendorCode,
        po.VendorName,
        po.OrderDate,
        po.Status         AS PoStatus,
        pol.LineNumber,
        pol.ItemCode,
        pol.OrderedQty,
        pol.ReceivedQty,
        (pol.OrderedQty - pol.ReceivedQty) AS RemainingQty
FROM    dbo.PurchaseOrderLines pol
INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE   po.Status = 'open'
  AND   pol.OrderedQty > pol.ReceivedQty;
GO
```

### 4.9 AuditLog — append-only

```sql
CREATE TABLE dbo.AuditLog (
    Id          BIGINT IDENTITY(1,1) PRIMARY KEY,
    ActionType  VARCHAR(16)      NOT NULL,    -- create|update|delete|assign|login|logout|receive|cancel|close|reopen
    EntityType  VARCHAR(32)      NULL,        -- User|Warehouse|Pull|Receipt|...
    EntityId    VARCHAR(64)      NULL,
    Message     NVARCHAR(1000)   NOT NULL,
    ActorUserId UNIQUEIDENTIFIER NULL,
    ActorName   NVARCHAR(160)    NULL,        -- denormalized; survives user deletion
    IpAddress   VARCHAR(64)      NULL,
    OccurredAt  DATETIME2(0)     NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT FK_Audit_Actor FOREIGN KEY (ActorUserId) REFERENCES dbo.Users(Id) ON DELETE SET NULL
);

CREATE INDEX IX_Audit_When   ON dbo.AuditLog(OccurredAt DESC);
CREATE INDEX IX_Audit_Action ON dbo.AuditLog(ActionType, OccurredAt DESC);
```

### 4.10 UserPreferences

```sql
CREATE TABLE dbo.UserPreferences (
    UserId       UNIQUEIDENTIFIER NOT NULL PRIMARY KEY,
    Theme        VARCHAR(16)      NOT NULL DEFAULT 'light'      CHECK (Theme IN ('light','midnight','slate')),
    NavPosition  VARCHAR(16)      NOT NULL DEFAULT 'horizontal' CHECK (NavPosition IN ('horizontal','vertical')),
    NavBehavior  VARCHAR(16)      NOT NULL DEFAULT 'sticky'     CHECK (NavBehavior IN ('sticky','auto-hide','static')),
    NavCollapsed BIT              NOT NULL DEFAULT 0,
    UpdatedAt    DATETIME2(0)     NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT FK_Prefs_User FOREIGN KEY (UserId) REFERENCES dbo.Users(Id) ON DELETE CASCADE
);
```

### 4.11 Seed data

Insert exactly the demo records that appear in the mockup so the UI looks identical on first run:

- **Users** (6): `sadmin/admin` (admin), `swattana/demo1234` (supervisor), `psomchai/demo1234` (supervisor), `npatcharin/demo1234` (operator), `kanucha/demo1234` (operator), `tviewer/demo1234` (viewer, `IsActive=0`).
- **Warehouses** (4): WH-01 Bangkok Main, WH-02 Chonburi, WH-03 Rayong (active), WH-04 Hanoi DC (inactive).
- **Assignments** (11) matching `masters.html`:
  - `sadmin` → all 4 warehouses (admin role each)
  - `swattana` → WH-01 (supervisor), WH-02 (operator)
  - `psomchai` → WH-01 (supervisor)
  - `npatcharin` → WH-02 (supervisor), WH-03 (operator)
  - `kanucha` → WH-03 (supervisor)
  - `tviewer` → WH-01 (viewer)
- **Pulls** (12): PL-2840 through PL-2851 with statuses, dates, warehouses, and item counts from `pull-controller-v2.html`'s seed array.
- **PullItems + PullItemWindows**: realistic items per pull. For PL-2847 specifically, populate the full 8-item set from `receiving-mockup-v2-fullreceived.html`.
- **PurchaseOrders + PurchaseOrderLines** — at least 3 POs per warehouse covering every `ItemCode` that appears in the seed pulls, with **enough remaining qty across all POs to fully satisfy every active pull**. Make some PO lines older than others so FIFO has something to do; make one item have at least two open PO lines so a single receive call will visibly split across them. Example for WH-01:
  - `PO-2401-018` (OrderDate: 2026-01-15) → line 1: PCBA-AX450-R2 / 3000 pcs (1500 already received) · line 2: CAP-470UF-25V / 5000 pcs (1200 already received)
  - `PO-2401-019` (OrderDate: 2026-01-22) → line 1: PCBA-AX450-R2 / 2500 pcs (0 received) · line 2: RES-10K-0805 / 4000 pcs (0 received)
  - `PO-2403-044` (OrderDate: 2026-03-08) → line 1: CAP-470UF-25V / 2000 pcs · line 2: CONN-USB-C-16 / 1500 pcs · line 3: IC-MCU-STM32 / 200 pcs
  - One **closed PO** (`PO-2312-091`, fully received) so the UI can show what closed looks like and the FIFO query correctly excludes it.
- **Receipts** (~20) bound to PO lines, including **two reversal pairs**:
  - QC-fail reversal: receive `r-1005` (1500 RES-10K from `PO-2401-019` line 2) → reversal `r-1007` (-1500 against the same PO line, reason `qc-fail`)
  - Miscount + correction: receive `r-2002` (2000 RES-10K, split across `PO-2401-019` line 2 = 1500 + `PO-2403-044` line 2 = 500 → **so this is actually 2 receipt rows**) → cancel both rows via reversals `r-2003a`, `r-2003b` (reason `miscount`) → receive `r-2004` (200, the right amount, allocated from oldest PO)

Passwords must be **hashed** in the seed — never plaintext. Use the `tools/HashPassword` console to generate the hashes, then paste them into the SQL.

---

## 5. Authentication & Authorization

### 5.1 Login flow

`POST /api/auth/login` — body `{ username, password, warehouseId, remember }`.

1. Look up user by `Username` (case-insensitive). Missing → `401` "No account found with that username".
2. `IsActive = 0` → `403` "This account is disabled".
3. `PasswordHasher.VerifyHashedPassword`. Mismatch → `401` "Incorrect password".
4. If user is **not** admin, verify `(UserId, WarehouseId)` exists in `UserWarehouseAssignments`. Missing → `403` "You don't have access to that warehouse".
5. Resolve `whRole`: the assignment row's `Role`, or `admin` if user's global Role is admin.
6. Sign in with cookie:

```csharp
var claims = new List<Claim>
{
    new(ClaimTypes.NameIdentifier, user.Id.ToString()),
    new(ClaimTypes.Name, user.Username),
    new("displayName", user.Name),
    new("email", user.Email ?? ""),
    new("warehouseId", warehouseId.ToString()),
    new("warehouseCode", wh.Code),
    new("warehouseName", wh.Name),
    new("whRole", whRole),                 // role AT this warehouse
    new(ClaimTypes.Role, user.Role)        // global role (admin override)
};
var principal = new ClaimsPrincipal(new ClaimsIdentity(claims, CookieAuthenticationDefaults.AuthenticationScheme));
await HttpContext.SignInAsync(principal, new AuthenticationProperties { IsPersistent = req.Remember });
```

7. `UPDATE dbo.Users SET LastSignInAt = SYSUTCDATETIME() WHERE Id = @id`.
8. Audit `login`.
9. Return `{ name, role, roleKey, initials, warehouseCode, warehouseName, redirectTo: "/Dashboard" }`.

### 5.2 GET /api/auth/warehouses-for/{username}

Returns active warehouses available to that username (admins see all). Used by `login.html` to populate the dropdown after the user types their username. Returning `[]` for both "unknown user" and "user has no warehouses" is acceptable — don't reveal user existence via status code.

### 5.3 GET /api/auth/me

Returns the current session claims for `app-nav.js` to render the profile chip and for `receiving.js` to gate the Reopen button.

### 5.4 Logout

`POST /api/auth/logout` → `SignOutAsync` + audit row → `204`.

### 5.5 Authorization policies

```csharp
builder.Services.AddAuthorization(opts =>
{
    opts.AddPolicy("AdminOnly", p => p.RequireRole("admin"));

    opts.AddPolicy("CanManagePulls", p => p.RequireAssertion(ctx =>
        ctx.User.IsInRole("admin") ||
        ctx.User.HasClaim("whRole", "supervisor")));

    opts.AddPolicy("CanReceive", p => p.RequireAssertion(ctx =>
        ctx.User.IsInRole("admin") ||
        new[]{"supervisor","operator"}.Contains(ctx.User.FindFirstValue("whRole") ?? "")));

    // Reopen is supervisor+admin only — operators cannot reopen even though they can receive
    opts.AddPolicy("CanReopenPull", p => p.RequireAssertion(ctx =>
        ctx.User.IsInRole("admin") ||
        ctx.User.HasClaim("whRole", "supervisor")));
});
```

Apply policies on controllers: `[Authorize(Policy = "AdminOnly")]` for `MastersController`, `[Authorize(Policy = "CanReceive")]` for receipt write paths, `[Authorize(Policy = "CanReopenPull")]` for the reopen endpoint.

---

## 6. API Endpoints

Every endpoint returns `application/json`. Errors are RFC 7807 `ProblemDetails`. Timestamps are ISO-8601 UTC. IDs are GUIDs as strings.

### Auth
| Method | Route | Body | Auth | Returns |
|---|---|---|---|---|
| GET  | `/api/auth/warehouses-for/{username}` | — | anonymous | `[{ id, code, name }]` |
| POST | `/api/auth/login`                     | `{ username, password, warehouseId, remember }` | anonymous | session info + redirectTo |
| POST | `/api/auth/logout`                    | — | authenticated | 204 |
| GET  | `/api/auth/me`                        | — | authenticated | session claims |

### Users (AdminOnly)
| Method | Route | Returns |
|---|---|---|
| GET    | `/api/users?role=&status=&q=`     | list |
| GET    | `/api/users/{id}`                 | user + assignments |
| POST   | `/api/users`                      | created |
| PUT    | `/api/users/{id}`                 | updated |
| DELETE | `/api/users/{id}`                 | 204 (refuses if deleting self) |
| PUT    | `/api/users/{id}/assignments`     | replaces ALL assignments atomically. Body: `[{ warehouseId, role }]` |
| POST   | `/api/users/{id}/reset-password`  | `{ newPassword }` |

### Warehouses (AdminOnly for write; authenticated read)
| Method | Route | Returns |
|---|---|---|
| GET    | `/api/warehouses?status=&q=`       | list |
| GET    | `/api/warehouses/{id}`             | warehouse + user count |
| POST   | `/api/warehouses`                  | created |
| PUT    | `/api/warehouses/{id}`             | updated |
| DELETE | `/api/warehouses/{id}`             | 204 |

### Pulls
| Method | Route | Body | Auth | Returns |
|---|---|---|---|---|
| GET  | `/api/pulls?warehouseId=&dateFrom=&dateTo=&status=&q=` | — | authenticated | list with progress + `lockPoByPull` per row |
| GET  | `/api/pulls/{id}`                  | — | authenticated | full pull + items + windows + `lockPoByPull` |
| POST | `/api/pulls`                       | `{ pullNumber, warehouseId, pullDate, lockPoByPull?, ... }` | CanManagePulls | created. `lockPoByPull` defaults to `false` if omitted; **immutable** thereafter (see §7.15) |
| PUT  | `/api/pulls/{id}`                  | edits | CanManagePulls | updated (refused if closed). **Rejects** any change to `lockPoByPull` with `409` (§7.15) |
| POST | `/api/pulls/{id}/close`            | `{ signatureSvg }` | CanManagePulls | 204 (refused unless every active window is full) |
| POST | `/api/pulls/{id}/reopen`           | `{ reason }` | **CanReopenPull** | 204 (only when status='closed') |
| PUT  | `/api/pulls/{id}/items/{itemId}/status` | `{ status }` | CanManagePulls | updated item (refused if pull closed) |

### Receipts

A single `POST /api/receipts` call may produce **multiple receipt rows** when the server's FIFO allocator splits the requested qty across two or more PO lines (see §7.2 for the algorithm). The allocation scope depends on the pull's `LockPoByPull` flag.

| Method | Route | Body | Auth | Returns |
|---|---|---|---|---|
| POST | `/api/receipts` | `{ pullItemId, hour, qty, lotBatch?, palletId?, binLocation?, qcStatus?, note? }` | CanReceive | `{ allocations: [{ receiptId, purchaseOrderId, poNumber, purchaseOrderLineId, qty }], totalQty, newReceivedQty, fullyReceived, scope: "warehouse-wide" \| "pull-locked" }` |
| GET  | `/api/receipts/preview?pullItemId=&qty=` | — | CanReceive | `{ allocations: [...], totalAllocatable, shortage, scope }` — preview FIFO allocation without committing; the `scope` field drives the badge in the Receive Goods modal |
| POST | `/api/receipts/{id}/cancel` | `{ reason, note? }` | CanReceive | `{ reversalReceiptId, newReceivedQty, poLineRestored }` — cancel one receipt row; qty goes back to that row's PO line |
| GET  | `/api/receipts?pullId={id}&itemCode=&hour=` | — | authenticated | journal scoped to one pull, each row includes its PO context |

### PurchaseOrders
| Method | Route | Body | Auth | Returns |
|---|---|---|---|---|
| GET  | `/api/pos?warehouseId=&status=&itemCode=&pullId=&q=` | — | authenticated | list of POs with line summary + `pullId` per row |
| GET  | `/api/pos/{id}` | — | authenticated | header + all lines + receipts referencing each line + `pullId` |
| GET  | `/api/pos/availability?warehouseId=&itemCode=&pullId=` | — | authenticated | FIFO-ordered open lines for that item. If `pullId` is supplied, filters to linked POs only (the lock-aware path) |
| POST | `/api/pos` | `{ poNumber, warehouseId, orderDate, pullId?, ... }` | CanManagePulls | created. `pullId` is optional and **immutable** thereafter (§7.15). When supplied, pull must exist + match warehouse + not be closed |
| PUT  | `/api/pos/{id}` | edits | CanManagePulls | updated (refused if any receipts exist against this PO). **Rejects** any change to `pullId` with `409` including `NULL ↔ NOT NULL` (§7.15) |
| POST | `/api/pos/{id}/close` | `{ reason }` | CanManagePulls | manually close a PO before fully received (rare; logs reason) |
| POST | `/api/pos/{id}/lines` | new line | CanManagePulls | added |
| DELETE | `/api/pos/{id}/lines/{lineId}` | — | CanManagePulls | removed (refused if any receipts exist against this line) |

### Transactions (cross-pull journal for `transactions.html`)
| Method | Route | Returns |
|---|---|---|
| GET  | `/api/transactions?warehouseId=&dateFrom=&dateTo=&action=&operatorId=&pullNumber=&poNumber=&itemCode=&hour=&q=&take=&skip=` | paged list |
| GET  | `/api/transactions/export?...` (same filters) | XLSX stream (optional for v1) |

The `q` filter supports **multi-token AND match** — split on whitespace and require every token to match somewhere in the row's combined haystack (pullNumber + warehouseCode + **poNumber** + **vendorName** + itemCode + description + lotBatch + palletId + binLocation + receivedByName + note). PO context is part of the searchable text so users can find all receipts for a specific PO without using the structured filter.

### Audit
| Method | Route | Returns |
|---|---|---|
| GET  | `/api/audit?action=&q=&take=200`   | recent entries |

### User preferences
| Method | Route | Returns |
|---|---|---|
| GET | `/api/me/preferences`                 | current prefs |
| PUT | `/api/me/preferences`                 | upsert |

---

## 7. Business Rules (server-side — client checks are advisory)

Every rule below **must be re-checked on the server** — never trust the client.

### 7.1 PO cap is the hard limit (no hour cap)

The total quantity received against a PO line (sum of all positive receipt rows minus all reversals) must never exceed `OrderedQty`. The per-hour `ExpectedQty` in `PullItemWindows` is **planning only** — overage on a single hour is allowed as long as PO capacity exists.

`POST /api/receipts` must reject when the **total open PO line capacity for that item in the FIFO scope** is less than the requested qty. The scope depends on the pull's `LockPoByPull` flag (see §4.5b):

```sql
-- Mode A (LockPoByPull = 0): warehouse-wide
SELECT SUM(OrderedQty - ReceivedQty)
FROM   dbo.vw_PurchaseOrderAvailability
WHERE  WarehouseId = @WarehouseId
  AND  ItemCode    = @ItemCode;

-- Mode B (LockPoByPull = 1): pull-locked
SELECT SUM(OrderedQty - ReceivedQty)
FROM   dbo.vw_PurchaseOrderAvailability
WHERE  PullId   = @PullId
  AND  ItemCode = @ItemCode;
```

If the SUM is < `req.Qty` → return `409 Conflict` with title `"Insufficient PO capacity"` and detail `"Requested {qty} but only {available} pcs remain across all open POs for {itemCode}. Open another PO before receiving."`. **The receive call is rejected as a whole — no partial allocation.**

If Mode B is active and the result set is **empty** (no linked POs at all) → return `409` with title `"No PO linked"` and detail `"No PO linked to this pull. Procurement must link a PO before receiving."` This is a distinct error from insufficient capacity; the modal should surface different guidance for each.

The DB-level `CK_POL_Caps` (PO line) is the last line of defense.

### 7.2 FIFO allocation algorithm (lock-aware)

The server allocates the requested qty across open PO lines **automatically, in FIFO order by `OrderDate`**, and creates one `Receipts` row per allocation slice. The user **does not see PO numbers in the Receive Goods modal until allocation completes** — there is no PO dropdown, no override, no manual selection. This guarantees consistent FIFO discipline across the operation.

**Algorithm** (run inside the receive transaction, see §7.2a):

```text
Input: pullId, warehouseId, itemCode, qtyRequested, lockPoByPull
Output: List<(poLineId, qtyToAllocate)>

1. Build the FIFO query. Base WHERE clause filters open lines for itemCode.
   - If lockPoByPull == false: add "AND po.WarehouseId = @WarehouseId"
   - If lockPoByPull == true:  add "AND po.PullId      = @PullId"
   ORDER BY po.OrderDate ASC, po.PoNumber ASC, pol.LineNumber ASC.
2. Lock and read the matching rows.
3. If lockPoByPull == true AND result set is empty
     → throw BusinessException("No PO linked to this pull...").
4. Compute total available = SUM(OrderedQty - ReceivedQty) across all locked rows.
5. If total available < qtyRequested
     → throw BusinessException("Insufficient PO capacity...").
6. Walk the lines in FIFO order; for each line:
     remaining = line.OrderedQty - line.ReceivedQty
     take = MIN(remaining, qtyRequested - allocatedSoFar)
     if take > 0 → emit (line.Id, take); allocatedSoFar += take
     if allocatedSoFar == qtyRequested → break
7. Return the list. The caller will tag the audit with
   "Scope: pull-locked" or "Scope: warehouse-wide FIFO" based on lockPoByPull.
```

The allocator's read **must use `WITH (UPDLOCK, HOLDLOCK)`** on `PurchaseOrderLines` so two concurrent receive calls for the same item see consistent remaining quantities. `HOLDLOCK` upgrades the range lock to serializable for the FIFO query — without this, two concurrent receives could each see 1500 remaining on the same PO line and both try to take 1000, double-spending the line.

> **Lock scope and concurrency**: under Mode B the lock granularity is narrower (only lines with `po.PullId = @PullId`), so concurrent receives on different pulls don't contend even when they touch the same item. Under Mode A all open PO lines for the item in the warehouse are locked together — higher contention but consistent with the "single warehouse-wide pool" semantic.

> **GET /api/receipts/preview** runs the same algorithm **without taking locks or inserting** — it's a read-only preview the modal calls when the user types a quantity, so the modal can show "Will allocate 1500 from PO-2401-018 + 500 from PO-2401-019" (plus a scope badge) before the user clicks Confirm. The preview output may be stale by the time Confirm fires, so the transactional path re-runs allocation under lock and is the source of truth.

### 7.2a Atomic receive transaction (now multi-row)

Receiving is atomic across: lock pull row + lock PO lines + insert N receipt rows + update PO line cache (`ReceivedQty`) + update window cache + update pull timing + auto-promote status + auto-close any PO fully consumed + audit. One `IDbTransaction`:

```csharp
public async Task<ReceiveResult> ReceiveAsync(ReceiveRequest req, Guid currentUserId)
{
    using var conn = _factory.Create();
    conn.Open();
    using var tx = conn.BeginTransaction();
    try
    {
        // 0. Read pull + item + warehouse — pull must not be closed
        var ctx = await conn.QuerySingleAsync<(Guid PullId, string PullStatus, Guid WarehouseId, string ItemCode)>(@"
            SELECT p.Id, p.Status, p.WarehouseId, pi.ItemCode
            FROM   dbo.Pulls p WITH (UPDLOCK, ROWLOCK)
            INNER JOIN dbo.PullItems pi ON pi.PullId = p.Id
            WHERE  pi.Id = @PullItemId", new { req.PullItemId }, tx);
        if (ctx.PullStatus == "closed")
            throw new BusinessException("Pull is closed and cannot accept receipts");

        // 1. Lock all open PO lines for this (warehouse, item) and read FIFO order.
        //    HOLDLOCK + UPDLOCK gives serializable range protection across the FIFO query.
        var openLines = (await conn.QueryAsync<PoLineAvail>(@"
            SELECT pol.Id, pol.PurchaseOrderId, po.PoNumber, po.OrderDate,
                   pol.OrderedQty, pol.ReceivedQty
            FROM   dbo.PurchaseOrderLines pol WITH (UPDLOCK, HOLDLOCK, ROWLOCK)
            INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
            WHERE  po.WarehouseId = @WarehouseId
              AND  po.Status      = 'open'
              AND  pol.ItemCode   = @ItemCode
              AND  pol.OrderedQty > pol.ReceivedQty
            ORDER BY po.OrderDate ASC, po.PoNumber ASC",
            new { ctx.WarehouseId, ctx.ItemCode }, tx)).ToList();

        var totalAvailable = openLines.Sum(l => l.OrderedQty - l.ReceivedQty);
        if (totalAvailable < req.Qty)
            throw new BusinessException(
                $"Insufficient PO capacity. Requested {req.Qty} but only {totalAvailable} pcs remain across all open POs for {ctx.ItemCode}. Open another PO before receiving.");

        // 2. Walk FIFO and build the allocation plan
        var plan = new List<(PoLineAvail line, int take)>();
        var remaining = req.Qty;
        foreach (var line in openLines)
        {
            var lineRemaining = line.OrderedQty - line.ReceivedQty;
            var take = Math.Min(lineRemaining, remaining);
            if (take > 0)
            {
                plan.Add((line, take));
                remaining -= take;
            }
            if (remaining == 0) break;
        }

        // 3. Insert one Receipts row per allocation + update PO line cache
        var allocations = new List<AllocationResult>();
        foreach (var (line, take) in plan)
        {
            var receiptId = await conn.QuerySingleAsync<Guid>(@"
                INSERT INTO dbo.Receipts
                    (PullItemId, PurchaseOrderId, PurchaseOrderLineId, HourOfDay,
                     QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, Note, ReceivedBy)
                OUTPUT INSERTED.Id
                VALUES (@PullItemId, @PoId, @PoLineId, @Hour,
                        @Qty, @Lot, @Pallet, @Bin, @Qc, @Note, @Actor)",
                new {
                    req.PullItemId, PoId = line.PurchaseOrderId, PoLineId = line.Id,
                    req.Hour, Qty = take,
                    Lot = req.LotBatch, Pallet = req.PalletId, Bin = req.BinLocation,
                    Qc = req.QcStatus ?? "pending", req.Note, Actor = currentUserId
                }, tx);

            await conn.ExecuteAsync(
                "UPDATE dbo.PurchaseOrderLines SET ReceivedQty = ReceivedQty + @Take WHERE Id = @LineId",
                new { Take = take, LineId = line.Id }, tx);

            allocations.Add(new AllocationResult(receiptId, line.PurchaseOrderId, line.PoNumber, line.Id, take));
        }

        // 4. Auto-close POs that are now fully received
        var poIdsTouched = plan.Select(p => p.line.PurchaseOrderId).Distinct().ToList();
        await conn.ExecuteAsync(@"
            UPDATE dbo.PurchaseOrders
               SET Status   = 'closed',
                   ClosedAt = SYSUTCDATETIME()
             WHERE Id IN @PoIds
               AND Status = 'open'
               AND NOT EXISTS (
                   SELECT 1 FROM dbo.PurchaseOrderLines pol
                   WHERE pol.PurchaseOrderId = dbo.PurchaseOrders.Id
                     AND pol.OrderedQty > pol.ReceivedQty
               )", new { PoIds = poIdsTouched }, tx);

        // 5. Update window cache + pull timing
        await conn.ExecuteAsync(@"
            UPDATE dbo.PullItemWindows
               SET ReceivedQty = ReceivedQty + @Qty
             WHERE PullItemId = @PullItemId AND HourOfDay = @Hour",
            new { Qty = req.Qty, req.PullItemId, req.Hour }, tx);

        await conn.ExecuteAsync(@"
            UPDATE dbo.Pulls
               SET LastActivityAt = SYSUTCDATETIME(),
                   FirstReceiptAt = ISNULL(FirstReceiptAt, SYSUTCDATETIME()),
                   Status         = CASE WHEN Status = 'pending' THEN 'in_progress' ELSE Status END
             WHERE Id = @PullId", new { PullId = ctx.PullId }, tx);

        // 6. Audit — one row summarizing the allocation. The Scope tag is a
        //    wire contract the frontend parses; see §8 for the exact format.
        var summary  = string.Join(" + ", plan.Select(p => $"{p.take}@{p.line.PoNumber}"));
        var scopeLbl = ctx.LockPoByPull ? "pull-locked" : "warehouse-wide FIFO";
        await _audit.WriteAsync(conn, tx, "receive", "Receipt", $"pi={req.PullItemId}",
            $"Received {req.Qty} pcs of {ctx.ItemCode} at hour {req.Hour}. Scope: {scopeLbl}. Allocated: {summary}");

        tx.Commit();

        // Read the new window total for the response
        var newReceivedQty = await conn.QuerySingleAsync<int>(@"
            SELECT ReceivedQty FROM dbo.PullItemWindows
            WHERE PullItemId = @PullItemId AND HourOfDay = @Hour",
            new { req.PullItemId, req.Hour });

        return new ReceiveResult {
            Allocations    = allocations,
            TotalQty       = req.Qty,
            NewReceivedQty = newReceivedQty
        };
    }
    catch { tx.Rollback(); throw; }
}
```

> **Note on isolation**: do not switch the entire transaction to SERIALIZABLE — that's overkill and will create deadlocks under load. The `WITH (UPDLOCK, HOLDLOCK, ROWLOCK)` hint on the FIFO query is enough: it locks the candidate rows + the range needed to prevent phantom inserts of new PO lines mid-allocation. Other concurrent receivers for the same item will block on this query until our transaction commits, which is exactly what we want.

### 7.3 Cancel a receipt (reverse-entry)

`POST /api/receipts/{id}/cancel`:

- **Permission**: `CanReceive` (operator + supervisor + admin). Operators **can** cancel both their own and others' receipts. The audit row records the actor; no per-row ownership check.
- **Validation**:
  - Original must exist, have positive `QtyReceived`, and `ReversedById IS NULL`.
  - Reject reversals of reversals (don't double-negate); return `409`.
  - Parent `Pull.Status` must not be `closed` — return `409` "Cannot cancel; pull is closed."
- **Action** in one transaction:
  1. `SELECT … WITH (UPDLOCK, ROWLOCK)` the original receipt + its target PO line + its `PullItemWindows` row + the pull's current status.
  2. `INSERT` a new `Receipts` row with `QtyReceived = -original.QtyReceived`, `PurchaseOrderId = original.PurchaseOrderId`, `PurchaseOrderLineId = original.PurchaseOrderLineId` (the reversal lives on **the same PO line** as the original — no FIFO logic), `ReversesReceiptId = original.Id`, `CancelReason = req.Reason`, `Note = req.Note`, `ReceivedBy = currentUserId`. Copy `LotBatch`/`PalletId`/`BinLocation`/`QcStatus` from original so the reversal is traceable.
  3. `UPDATE Receipts SET ReversedById = @newReversalId WHERE Id = @originalId`.
  4. `UPDATE PurchaseOrderLines SET ReceivedQty = ReceivedQty - @origQty` — qty goes back to **exactly the PO line the original took it from**.
  5. **Auto-reopen the PO** if it had been auto-closed: `UPDATE PurchaseOrders SET Status='open', ClosedAt=NULL WHERE Id=@PoId AND Status='closed'` (only when the cancel restored capacity to a line that had been at zero).
  6. `UPDATE PullItemWindows SET ReceivedQty = ReceivedQty - @origQty` (window cache decrement).
  7. `UPDATE Pulls SET LastActivityAt = SYSUTCDATETIME()`. If the pull was at `fully_received`, demote to `in_progress`. Do **not** clear `FirstReceiptAt`.
  8. Audit `cancel` — `"Cancelled receipt {id} (-{qty} pcs of {itemCode} from {poNumber}). Reason: {reason}. {note}"`.
- **Response**: `{ reversalReceiptId, newReceivedQty, poLineRestored: { poNumber, lineNumber, newRemainingQty } }` so the client can refresh the cell, the modal's qty cards, the drawer, and (if visible) the PO availability panel.

```csharp
public async Task<CancelResult> CancelAsync(Guid receiptId, CancelRequest req, Guid currentUserId)
{
    using var conn = _factory.Create();
    conn.Open();
    using var tx = conn.BeginTransaction();
    try
    {
        var orig = await conn.QuerySingleOrDefaultAsync<Receipt>(
            "SELECT * FROM dbo.Receipts WITH (UPDLOCK, ROWLOCK) WHERE Id = @Id",
            new { Id = receiptId }, tx)
            ?? throw new NotFoundException("Receipt not found");

        if (orig.QtyReceived < 0)          throw new BusinessException("Cannot cancel a reversal entry");
        if (orig.ReversedById is not null) throw new BusinessException("Receipt is already voided");

        var pullStatus = await conn.QuerySingleAsync<string>(@"
            SELECT p.Status FROM dbo.Pulls p
            INNER JOIN dbo.PullItems pi ON pi.PullId = p.Id
            WHERE pi.Id = @PullItemId", new { orig.PullItemId }, tx);
        if (pullStatus == "closed") throw new BusinessException("Cannot cancel; pull is closed");

        // Lock the target PO line (and read PO number for audit)
        var poLine = await conn.QuerySingleAsync<(Guid PoId, string PoNumber, int LineNumber, int OrderedQty, int ReceivedQty)>(@"
            SELECT pol.PurchaseOrderId, po.PoNumber, pol.LineNumber, pol.OrderedQty, pol.ReceivedQty
            FROM   dbo.PurchaseOrderLines pol WITH (UPDLOCK, ROWLOCK)
            INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
            WHERE  pol.Id = @LineId", new { LineId = orig.PurchaseOrderLineId }, tx);

        // 1. Insert reversal (same PO line as original)
        var reversalId = await conn.QuerySingleAsync<Guid>(@"
            INSERT INTO dbo.Receipts
                (PullItemId, PurchaseOrderId, PurchaseOrderLineId, HourOfDay, QtyReceived,
                 LotBatch, PalletId, BinLocation, QcStatus, Note, ReceivedBy,
                 ReversesReceiptId, CancelReason)
            OUTPUT INSERTED.Id
            VALUES (@PullItemId, @PoId, @PoLineId, @Hour, @NegQty,
                    @Lot, @Pallet, @Bin, @Qc, @Note, @Actor,
                    @OrigId, @Reason)",
            new {
                orig.PullItemId, PoId = orig.PurchaseOrderId, PoLineId = orig.PurchaseOrderLineId,
                Hour = orig.HourOfDay, NegQty = -orig.QtyReceived,
                Lot = orig.LotBatch, Pallet = orig.PalletId, Bin = orig.BinLocation, Qc = orig.QcStatus,
                Note = req.Note, Actor = currentUserId, OrigId = orig.Id, Reason = req.Reason
            }, tx);

        // 2. Back-link original → reversal
        await conn.ExecuteAsync(
            "UPDATE dbo.Receipts SET ReversedById = @RevId WHERE Id = @OrigId",
            new { RevId = reversalId, OrigId = orig.Id }, tx);

        // 3. Restore qty to the PO line
        await conn.ExecuteAsync(
            "UPDATE dbo.PurchaseOrderLines SET ReceivedQty = ReceivedQty - @Qty WHERE Id = @LineId",
            new { Qty = orig.QtyReceived, LineId = orig.PurchaseOrderLineId }, tx);

        // 4. Auto-reopen the PO if it was auto-closed (cancel restored capacity)
        await conn.ExecuteAsync(@"
            UPDATE dbo.PurchaseOrders
               SET Status   = 'open',
                   ClosedAt = NULL
             WHERE Id = @PoId
               AND Status = 'closed'", new { PoId = orig.PurchaseOrderId }, tx);

        // 5. Decrement window cache
        await conn.ExecuteAsync(@"
            UPDATE dbo.PullItemWindows
               SET ReceivedQty = ReceivedQty - @Qty
             WHERE PullItemId = @PullItemId AND HourOfDay = @Hour",
            new { Qty = orig.QtyReceived, orig.PullItemId, Hour = orig.HourOfDay }, tx);

        // 6. Update pull status if demote needed
        await conn.ExecuteAsync(@"
            UPDATE dbo.Pulls
               SET LastActivityAt = SYSUTCDATETIME(),
                   Status = CASE WHEN Status = 'fully_received' THEN 'in_progress' ELSE Status END
             WHERE Id = (SELECT PullId FROM dbo.PullItems WHERE Id = @PullItemId)",
            new { orig.PullItemId }, tx);

        // 7. Audit
        var itemCode = await conn.QuerySingleAsync<string>(
            "SELECT ItemCode FROM dbo.PullItems WHERE Id = @Id", new { Id = orig.PullItemId }, tx);
        await _audit.WriteAsync(conn, tx, "cancel", "Receipt", orig.Id.ToString(),
            $"Cancelled receipt {orig.Id} (-{orig.QtyReceived} pcs of {itemCode} from {poLine.PoNumber}). Reason: {req.Reason}. {req.Note}");

        tx.Commit();

        var newWindowQty = await conn.QuerySingleAsync<int>(@"
            SELECT ReceivedQty FROM dbo.PullItemWindows
            WHERE PullItemId = @PullItemId AND HourOfDay = @Hour",
            new { orig.PullItemId, Hour = orig.HourOfDay });

        return new CancelResult {
            ReversalReceiptId = reversalId,
            NewReceivedQty    = newWindowQty,
            PoLineRestored    = new PoLineRestored {
                PoNumber        = poLine.PoNumber,
                LineNumber      = poLine.LineNumber,
                NewRemainingQty = poLine.OrderedQty - (poLine.ReceivedQty - orig.QtyReceived)
            }
        };
    }
    catch { tx.Rollback(); throw; }
}
```

> **PO auto-reopen note**: it's possible for a PO that was auto-closed by an earlier receive to be auto-reopened by a later cancel. That's correct behavior — the PO has capacity again, so it should be in the FIFO pool. An audit row is **not** written for the reopen itself (the cancel's audit row implies it); but you may want to add a separate `po_reopen` audit if procurement needs to track these.

### 7.4 Close pull — only when fully received

`POST /api/pulls/{id}/close` with body `{ signatureSvg }`:

- **Permission**: `CanManagePulls` (supervisor + admin). Operators **cannot** close.
- **Gate**: every non-canceled item's every window must satisfy `ReceivedQty >= ExpectedQty`. (Note: this checks the PLAN — did the operators receive at least what was planned for this pull. It's independent of the PO cap, which limits the upper bound of any individual receive.) Compute in one query — never loop in C#:

```sql
SELECT COUNT(*) FROM dbo.PullItems pi
INNER JOIN dbo.PullItemWindows piw ON piw.PullItemId = pi.Id
WHERE pi.PullId = @PullId
  AND pi.Status <> 'canceled'
  AND piw.ExpectedQty > piw.ReceivedQty;
```

If > 0, refuse with `409` "Pull has outstanding receipts; cannot close."

- **Action** in one transaction:
  1. Validate pull is not already `closed`.
  2. Validate `signatureSvg` length ≤ 200 KB (sanity bound for the base64-encoded canvas image); otherwise reject with `413 Payload Too Large`.
  3. `UPDATE Pulls SET Status='closed', ClosedAt=SYSUTCDATETIME(), ClosedBy=@actor, SignatureSvg=@sig WHERE Id=@id`.
  4. Audit `close` — `"Closed pull {pullNumber} ({totalReceived} pcs received)"`.

### 7.5 Reopen pull — supervisor only

`POST /api/pulls/{id}/reopen` with body `{ reason }`:

- **Permission**: `CanReopenPull` (supervisor + admin). Operators get `403`.
- **Validation**:
  - Pull must currently be `Status='closed'` — otherwise `409` "Pull is not closed."
  - `reason` is **required**, max 500 chars, trimmed. Reopen must always state why.
- **Action** in one transaction:
  1. Set `Status = 'in_progress'` (NOT back to `pending` — work has already happened).
  2. **Preserve** `ClosedAt`, `ClosedBy`, `SignatureSvg` — DO NOT NULL them. These remain as evidence of the original close.
  3. Set `ReopenedAt = SYSUTCDATETIME()`, `ReopenedBy = @actor`, `ReopenReason = @reason`.
  4. Audit `reopen` — `"Reopened pull {pullNumber}. Reason: {reason}. Previously closed at {ClosedAt} by {ClosedByName}."`.

> **Why preserve close fields**: a supervisor reopening shouldn't erase the fact that the pull was previously closed and signed. If it's closed again later, the close fields overwrite — but the audit log keeps the full history.

### 7.6 Canceled items

Rows with `PullItems.Status='canceled'` are excluded from the close check, from received/expected totals shown to the user, and rendered hatched/grey in the UI. Status is updated via `PUT /api/pulls/{id}/items/{itemId}/status` with values `normal|new|canceled`. Refuse if pull is closed.

### 7.7 Assignment cascade

Deleting a user with active assignments cascades the assignment rows (FK CASCADE). Deleting a warehouse cascades too. Both write `delete` audit rows for the entity **and** for each affected assignment.

### 7.8 User cannot delete themselves

Return `409` "You cannot delete your own account."

### 7.9 Admin override

A global `Role='admin'` user can access every warehouse and bypasses the per-warehouse role check. They still get a `whRole='admin'` claim on login.

### 7.10 Receipts are append-only

No `UPDATE` against `Receipts` except setting `ReversedById` on the original. No `DELETE` ever. Don't expose update/delete methods in `IReceiptRepository`.

### 7.11 Net received calculation via the view

Use `vw_PullItemReceived` for any downstream calculation. Never count receipt rows manually or filter for positive qty. This is what makes reverse-entry transparent to every progress percentage and close-eligibility check.

### 7.12 Read-only mode when pull is closed — SERVER ENFORCED

When `Pulls.Status='closed'`, the server **must reject** any of these even if the client tries:

- `POST /api/receipts` (where `pullItemId` belongs to a closed pull) → `409`
- `POST /api/receipts/{id}/cancel` (when the receipt's parent pull is closed) → `409`
- `PUT /api/pulls/{id}` → `409`
- `PUT /api/pulls/{id}/items/{itemId}/status` → `409`

Only `POST /api/pulls/{id}/reopen` (CanReopenPull) is allowed against a closed pull. The frontend additionally hides/disables these actions to give immediate feedback, but the server is the source of truth.

### 7.13 PO immutability when consumed

- `PUT /api/pos/{id}` — refuse with `409` if **any** receipt exists referencing this PO (positive or reversal). Procurement must cancel the existing PO and issue a new one rather than edit a consumed PO.
- `DELETE /api/pos/{id}/lines/{lineId}` — same rule: refuse if any receipt references the line.
- Closing a PO manually via `POST /api/pos/{id}/close` is allowed even with outstanding `OrderedQty`. This is the **rare** scenario where procurement stops a partially-received PO (vendor went bust, etc.). The remaining `OrderedQty - ReceivedQty` is forfeited from FIFO availability. Audit captures the reason supplied in the request body.

### 7.14 Server is FIFO authority — no user override

The Receive Goods modal must **not** show or accept a PO selection input. The server's FIFO allocation by `PurchaseOrders.OrderDate ASC` is the only valid binding. The modal can show a **preview** of where the qty would be allocated (via `GET /api/receipts/preview`) so the operator sees the audit trail before committing, but it cannot change the choice. This enforces FIFO discipline at the organization level — old POs always close out first.

The same rule applies regardless of `LockPoByPull` setting. Under Mode B the choice is even narrower (POs linked to the pull only), but the operator still does not pick — the server walks the linked-PO chain in FIFO order. If no PO is linked, the receive call returns `409` ("No PO linked to this pull"); the operator's only remedy is to coordinate with procurement to link a PO, not to select a different one.

### 7.15 Immutability of pull–PO linkage decisions

Two fields capture the planner/procurement intent at object-creation time and are **immutable for the life of the object**. The server rejects any attempt to change them with `409 Conflict`, regardless of role (including admin) and regardless of whether the object has been consumed yet:

| Field | Set when | Mutability after create |
|---|---|---|
| `Pulls.LockPoByPull` | Pull is created via `POST /api/pulls`. Defaults to `false` if omitted. | **Immutable.** `PUT /api/pulls/{id}` rejects any change with `"LockPoByPull is immutable after pull creation."` |
| `PurchaseOrders.PullId` | PO is created via `POST /api/pos`. Optional in the request body; defaults to `NULL`. | **Immutable.** `PUT /api/pos/{id}` rejects any change including `NULL → NOT NULL` and `NOT NULL → NULL` with `"PO–pull link is immutable. Cancel and reissue if you need to change."` |

**Why strict immutability**:
- Receipts already created under one policy can't be retroactively reframed under another without producing inconsistent audit history
- A pull that started life as Mode A may have receipts spread across multiple POs in the warehouse pool; flipping it to Mode B mid-stream would orphan those receipts from the new "linked POs only" rule
- Re-linking a PO from `PL-A` to `PL-B` would mean previously valid receipts under `PL-A` now reference a PO that's no longer linked to `PL-A` — the FIFO/audit story falls apart

The escape hatch is **cancel + reissue** — cancel the misconfigured pull or PO and create a new one with the correct setting. This is intentional friction: it forces deliberation at create time and preserves audit fidelity afterwards.

Validation at `POST` time:
- `POST /api/pos` with `pullId` set: pull must exist, must belong to the same warehouse as the PO, and must not be `closed`. If any check fails → `409`.

---

## 8. Auditing — Wire It Into Every Write

Create `IAuditService` injected everywhere mutations happen. Every successful create/update/delete/login/receive/cancel/close/reopen writes a row.

```csharp
public interface IAuditService
{
    Task WriteAsync(IDbConnection conn, IDbTransaction? tx,
        string actionType, string? entityType, string? entityId,
        string message, CancellationToken ct = default);
}
```

The service reads `HttpContext.User` for actor name/ID and `HttpContext.Connection.RemoteIpAddress` for `IpAddress`. **Never let an audit write throw and roll back the user's business action** — wrap in try/catch and `_logger.LogError` if it fails.

### 8.1 Audit message formats — wire contracts

These message strings are **wire contracts**: the frontend parses them (e.g. to colorize the journal by scope, to extract the PO summary), and downstream consumers may grep them for analytics. Treat any change to the format as a breaking change; if you genuinely need to change a format, bump a version marker in the string and update consumers in the same commit.

**`actionType = "receive"` — written by `ReceiptService.ReceiveAsync` (§7.2a):**

```
Received {qty} pcs of {itemCode} at hour {hr}. Scope: {scope}. Allocated: {alloc1}[ + {alloc2}…]
```

Where:
- `{scope}` ∈ `"warehouse-wide FIFO"` *or* `"pull-locked"` — derived from `Pulls.LockPoByPull` (§4.5b). Drives the scope badge on the receive modal and the journal row pill.
- `{alloc}` is `"{qty}@{poNumber}"`, joined with `" + "`. One slice per consumed PO line.

Examples:
- `Received 100 pcs of PCBA-AX450-R2 at hour 7. Scope: warehouse-wide FIFO. Allocated: 100@PO-2401-018`
- `Received 3301 pcs of PCBA-AX450-R2 at hour 8. Scope: warehouse-wide FIFO. Allocated: 3300@PO-2401-018 + 1@PO-2401-019`
- `Received 50 pcs of PCBA-AX450-R2 at hour 12. Scope: pull-locked. Allocated: 50@PO-2405-001`

**`actionType = "cancel"` — written by `ReceiptService.CancelAsync` (§7.3):**

```
Cancelled receipt {receiptGuid} (-{qty} pcs of {itemCode} from {poNumber}). Reason: {reason}.{ {note}}
```

No scope tag — cancel binds to the original receipt's PO line by Id, not via FIFO, so the scope semantics are not relevant. The PO number names the line being restored.

---

## 9. Frontend Wiring — replace localStorage with fetch

The HTML/CSS stays as-is. Replace **every** `localStorage` read/write in the mockups with `fetch()` calls.

### 9.1 `login.html`

- Warehouse dropdown — replace the `loadMasters()` localStorage helper with:
  ```js
  const r = await fetch(`/api/auth/warehouses-for/${encodeURIComponent(username)}`);
  const warehouses = await r.json();
  // populate <select id="warehouse"> options
  ```
  Trigger on `input`/`blur` of the username field.
- Submit handler → `POST /api/auth/login` → on success, redirect to `data.redirectTo`. On error, show `err.title` in the error box.
- Delete the `BOOTSTRAP_USERS/WAREHOUSES/ASSIGNMENTS` fallback arrays — they're only there because the mockup runs offline.

### 9.2 `pull-controller-v2.html` (Dashboard)

- Hardcoded `pulls = [...]` array → `fetch('/api/pulls?' + new URLSearchParams({warehouseId, dateFrom, dateTo}))`.
- Filter changes refetch.
- Excel export: keep client-side SheetJS for v1.
- The **Launch button** with URL params hands off to Receiving — keep the contract `?pull={number}&warehouse={code}&from=controller`.

### 9.3 `receiving-mockup-v2-fullreceived.html` — the big one

This file has **the most wiring** because it contains: hour-grid receive, Receive Goods modal with embedded transactions list, transactions drawer with cancel, close-pull signature flow, and supervisor reopen.

Read `?pull=PL-2847&warehouse=WH-01&from=controller` from query string. `fetch('/api/pulls/{id}')` to get the full sheet with items + windows + current `Status` (so `pullClosed` starts correctly).

**Replace localStorage receipts store** (`ops.receipts`) with `fetch('/api/receipts?pullId={id}')` on load. Keep a client-side cache for instant render; refresh after every write.

**Receive Goods modal — FIFO allocation preview** (NEW with PO support):

As the user types a quantity into `#m-input`, debounce ~200ms then call:

```js
async function refreshAllocationPreview() {
    const qty = parseInt(document.getElementById('m-input').value, 10);
    if (!qty || qty <= 0) {
        hideAllocationPanel();
        return;
    }
    const r = await fetch(`/api/receipts/preview?pullItemId=${pullItemId}&qty=${qty}`);
    if (!r.ok) return;
    const { allocations, totalAllocatable, shortage } = await r.json();

    if (shortage > 0) {
        // Cannot fulfill — show warning, disable Confirm
        document.getElementById('m-alloc-warning').textContent =
            `Insufficient PO capacity: requested ${qty}, only ${totalAllocatable} pcs across all open POs.`;
        document.getElementById('m-confirm').disabled = true;
    } else {
        // Show "Will allocate" list
        const items = allocations.map(a => `${a.qty} from ${a.poNumber}`).join(' + ');
        document.getElementById('m-alloc-list').textContent = `Will allocate: ${items}`;
        document.getElementById('m-confirm').disabled = false;
    }
}
```

The preview is **advisory only** — server re-runs allocation under lock at Confirm time and may produce a different split if a concurrent receive consumed capacity between preview and confirm.

**Receive Goods modal — Confirm Receipt button**:
```js
const r = await fetch('/api/receipts', {
    method: 'POST',
    headers: {'Content-Type':'application/json'},
    body: JSON.stringify({ pullItemId, hour, qty, lotBatch, palletId, binLocation, qcStatus, note })
});
if (r.ok) {
    const { allocations, totalQty, newReceivedQty } = await r.json();
    // allocations is an ARRAY — one entry per PO line consumed.
    // 1. Update the visible hour cell with newReceivedQty
    // 2. Refresh the modal's embedded transactions list (will now show N new rows, one per allocation)
    // 3. Show success toast: "Received 2000 pcs · split across 2 POs"
    // 4. If isFullyReceived(), call updateCloseButton() to enable the Close pulse
} else if (r.status === 409) {
    // Insufficient PO capacity OR pull-closed OR concurrent capacity exhaustion
    const err = await r.json();
    showToast(err.title || 'Receive rejected', err.detail);
    refreshAllocationPreview();  // re-run preview — capacity may have changed
}
```

**Transactions list — show PO column**:
Each row in the modal-embedded list, drawer, and standalone `transactions.html` now shows the PO number prominently. Suggested layout per row:

```
[10:32]  Receive 1500 pcs  PCBA-AX450-R2  PO-2401-018 · LINE 1  by S.Wattana  [Cancel]
[10:32]  Receive  500 pcs  PCBA-AX450-R2  PO-2401-019 · LINE 1  by S.Wattana  [Cancel]
```

The two rows above are the result of **one** Receive Goods click for 2000 pcs that the server split FIFO. They can be cancelled independently.

**Receive Goods modal — embedded transactions list** (`#m-tx-list`):
- On modal open, call `fetch('/api/receipts?pullId={id}&itemCode={code}&hour={hour}')`. Render rows. Per-row Cancel button is hidden when `pullClosed === true`.
- "View all in drawer →" button → close the modal + open the drawer with `{ hour, itemCode }` context.

**Drawer — open with context**:
- `openTxDrawer({ hour, itemCode })` pre-filters drawer. Without args, shows all receipts for the pull.
- The drawer's `data-hour-filter` attribute is read in `renderTxDrawer()` to apply the filter.
- The drawer's filter-chip with Clear button stays as-is (already wired).
- "Open full view ↗" link goes to: `transactions.html?pull={n}&warehouse={c}&hour={h}&item={code}` — pass all four params when context is set.

**Drawer — Cancel button per row** (also used by the modal-embedded list — both use the same `data-tx-cancel` attribute and same handler):
```js
const r = await fetch(`/api/receipts/${receiptId}/cancel`, {
    method: 'POST',
    headers: {'Content-Type':'application/json'},
    body: JSON.stringify({ reason, note })
});
if (r.ok) {
    const { newReceivedQty } = await r.json();
    // 1. Refresh the drawer's list
    // 2. If the Receive Goods modal is open, refresh its embedded list + qty cards
    // 3. Update the visible hour-grid cell
    // 4. updateCloseButton() — close eligibility may have changed
}
```

**Close Pull Sheet button**:
- Client-side enable when `isFullyReceived()` returns true. Server gates definitively.
- On confirm with signature:
  ```js
  const sigSvg = sigCanvas.toDataURL('image/png');
  const r = await fetch(`/api/pulls/${pullId}/close`, {
      method: 'POST',
      headers: {'Content-Type':'application/json'},
      body: JSON.stringify({ signatureSvg: sigSvg })
  });
  if (r.ok) {
      pullClosed = true;
      document.body.classList.add('pull-closed');
      updateCloseButton();  // swaps to Reopen for supervisors
  }
  ```

**Reopen button** (visible only when `pullClosed && canReopenPull()`):
- `canReopenPull()` reads `whRole` from `/api/auth/me` response (cached on page load) — only `supervisor` or `admin` returns true.
- On click → `confirm()` dialog → prompt for reason → `POST /api/pulls/{id}/reopen` with `{ reason }`.
- On success: `pullClosed = false`, `document.body.classList.remove('pull-closed')`, `updateCloseButton()`, refresh modal/drawer if open.

**Read-only mode (`pullClosed === true`)** — the frontend already gates these; verify after the API integration:
- Cell click → modal opens in view-only (banner shown, form disabled, Confirm hidden).
- Status menu → `if (pullClosed) return;` at top of `openStatusMenu`.
- Cancel buttons in drawer + modal-embedded list → hidden when closed.
- "Back to Controller" pill → points to `pull-controller-v2.html` (not v1). **The mockup had v1 in this link as of the previous fix — make sure it's v2 in the Razor view too.**

### 9.4 `transactions.html`

Replace seed data with `fetch('/api/transactions?' + params)`.

**URL params on load** (already implemented in the mockup — preserve the contract):
- `pull` → adds to search box
- `item` → adds to search box (joined with `pull` for multi-token search)
- `warehouse` → sets warehouse dropdown
- `hour` → applies hour filter at data layer + shows the green banner with **Clear** button

Search box does **multi-token AND match** — preserve this on the server side (§6 above).

Cancel button per row → same `POST /api/receipts/{id}/cancel` endpoint. On success, refresh the visible list.

Excel export: keep client-side SheetJS for v1.

### 9.5 `masters.html`

Replace all `masters.users` / `masters.warehouses` / `masters.assignments` / `masters.auditLog` localStorage operations with their respective API endpoints. Optimistic UI is fine, but always re-fetch the affected list after a write to stay consistent. The audit-log tab → `GET /api/audit?take=200`.

### 9.6 `config.html`

Reads/writes via `/api/me/preferences`. Theme/nav choices are still applied immediately client-side for instant feedback, then sent to the API.

### 9.7 `app-nav.js`

- Auth guard: instead of reading `auth.user` from localStorage, call `/api/auth/me` once on first render. If `401`, redirect to `/Account/Login`.
- Profile/menu data comes from the response.
- Theme/nav prefs come from `/api/me/preferences` (with cached fallback for first paint to avoid FOUC).
- Sign out → `POST /api/auth/logout` then redirect to `/Account/Login`.
- The menu items array stays as: Dashboard / Receiving / Transactions / Reports (disabled) / Master Data / Settings.

### 9.8 URL parameter contract (cross-page handoff)

This is the contract pages depend on — preserve exactly:

| From → To | Params |
|---|---|
| Dashboard → Receiving | `?pull={number}&warehouse={code}&from=controller` |
| Receiving "Back to Controller" pill | navigates to `pull-controller-v2.html` (not v1) when `from=controller` was set on arrival |
| Receiving modal → in-page drawer | passes `{ hour, itemCode }` to `openTxDrawer()` — sets `data-hour-filter` |
| Receiving drawer "Open full view ↗" → Transactions | `?pull={n}&warehouse={c}&hour={h}&item={code}` |
| Transactions → Receiving (pull link in table) | `?pull={number}&from=transactions` |

---

## 10. Razor Layout

`Views/Shared/_Layout.cshtml`:

```html
<!DOCTYPE html>
<html lang="en" data-theme="@(Context.User.FindFirst("theme")?.Value ?? "light")">
<head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>@ViewData["Title"] · Receiving Operations</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link href="https://fonts.googleapis.com/css2?family=Roboto:wght@@300;400;500;600;700&family=Roboto+Mono:wght@@400;500;600;700&display=swap" rel="stylesheet">
    <link href="~/lib/bootstrap/dist/css/bootstrap.min.css" rel="stylesheet" />
    <link href="~/lib/bootstrap-icons/font/bootstrap-icons.min.css" rel="stylesheet" />
    <link href="~/css/site.css" rel="stylesheet" />
    @await RenderSectionAsync("Styles", required: false)
</head>
<body data-app-page="@ViewData["PageId"]">
    <div class="app">
        @RenderBody()
    </div>
    <script src="~/lib/bootstrap/dist/js/bootstrap.bundle.min.js"></script>
    <script src="~/js/app-nav.js"></script>
    @await RenderSectionAsync("Scripts", required: false)
</body>
</html>
```

Each view sets `ViewData["PageId"]` matching the mockup's `data-app-page` value (`pull`, `receiving`, `transactions`, `masters`, `config`).

---

## 11. Program.cs

```csharp
var builder = WebApplication.CreateBuilder(args);

builder.Services.AddControllersWithViews()
    .AddJsonOptions(o =>
    {
        o.JsonSerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.CamelCase;
        o.JsonSerializerOptions.DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull;
    });

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
    });

builder.Services.AddAuthorization(opts => { /* policies — see §5.5 */ });

// Data
builder.Services.AddScoped<IDbConnectionFactory, SqlConnectionFactory>();

// Repositories
builder.Services.AddScoped<IUserRepository, UserRepository>();
builder.Services.AddScoped<IWarehouseRepository, WarehouseRepository>();
builder.Services.AddScoped<IAssignmentRepository, AssignmentRepository>();
builder.Services.AddScoped<IPullRepository, PullRepository>();
builder.Services.AddScoped<IPullItemRepository, PullItemRepository>();
builder.Services.AddScoped<IPullItemWindowRepository, PullItemWindowRepository>();
builder.Services.AddScoped<IReceiptRepository, ReceiptRepository>();
builder.Services.AddScoped<IAuditRepository, AuditRepository>();
builder.Services.AddScoped<IPreferencesRepository, PreferencesRepository>();

// Services
builder.Services.AddScoped<IAuthService, AuthService>();
builder.Services.AddScoped<IPullService, PullService>();
builder.Services.AddScoped<IReceiptService, ReceiptService>();
builder.Services.AddScoped<ICloseService, CloseService>();
builder.Services.AddScoped<IAuditService, AuditService>();

builder.Services.AddSingleton<IPasswordHasher<User>, PasswordHasher<User>>();

var app = builder.Build();

if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Home/Error");
    app.UseHsts();
}

app.UseHttpsRedirection();
app.UseStaticFiles();
app.UseRouting();
app.UseAuthentication();
app.UseAuthorization();

app.MapControllerRoute(
    name: "default",
    pattern: "{controller=Dashboard}/{action=Index}/{id?}");
app.MapControllers();

app.Run();
```

---

## 12. Acceptance Criteria (definition of "done")

The build is complete when **all** of these pass on a clean machine after running the SQL scripts and `dotnet run`:

### Auth + Master Data
1. Navigating to `/` redirects to `/Account/Login`.
2. Typing `swattana` populates the warehouse dropdown with **WH-01 and WH-02** (not WH-03; WH-04 is excluded as inactive).
3. Logging in with `swattana / demo1234` and choosing WH-01 lands on `/Dashboard`.
4. Logging in with `sadmin / admin` shows all 3 active warehouses.
5. Logging in with `tviewer` (disabled) shows an error.
6. Master Data tabs perform full CRUD; assignments save atomically (one PUT replaces all rows for a user); every change appears in the audit log.

### Dashboard
7. Dashboard shows 12 pulls grouped into 4 columns matching the mockup data.
8. Clicking a pull opens the offcanvas drawer with correct stats and a working "Open in Receiving" button that passes `?pull=X&warehouse=Y&from=controller`.

### Receiving — receive flow
9. Receiving page renders the hour grid with the correct `pullClosed` state from `GET /api/pulls/{id}`.
10. Typing a qty in the Receive Goods modal triggers the FIFO preview within ~200ms; the panel shows e.g. "Will allocate: 1500 from PO-2401-018 + 500 from PO-2401-019".
11. Receiving 100 pcs into a cell with 200 expected updates the visible value to 100/200 within ~200 ms.
12. Receiving 2000 pcs when the FIFO-oldest PO has only 1500 remaining produces **two receipt rows** in the journal (1500 from oldest PO, 500 from next), each with its `PurchaseOrderLineId` set. The hour cell updates by the total (2000).
13. Trying to receive **more than the sum of all open PO capacity for that (item, warehouse)** returns `409 "Insufficient PO capacity"` and the cell does not update.
14. Trying to receive into a **closed** pull returns `409` even if the client somehow attempts it.
15. The Receive Goods modal shows a transactions list filtered to that exact `(itemCode, hour)`, with one row per matching receipt + reversal, **each row displaying its PO number**.

### Receiving — PO behavior
16. When a receive consumes the last remaining qty on a PO, the PO's `Status` flips to `closed` automatically and disappears from the FIFO availability for subsequent receives.
17. The Receive Goods modal does **not** expose any PO selector — the user cannot override FIFO.
18. `GET /api/receipts/preview?pullItemId=X&qty=Y` returns the FIFO allocation plan without taking locks or creating rows.

### Receiving — cancel/reverse flow
19. Clicking Cancel on a row in the modal-embedded list opens the cancel modal. Picking a reason and confirming creates a reversal row (negative qty, `ReversesReceiptId` set, same `PurchaseOrderLineId` as original) and marks the original as `ReversedById`. Both rows are visible in the journal afterwards.
20. After a cancel, the qty goes back to **exactly the PO line the original receipt came from** — not redistributed via FIFO. Verifiable via `GET /api/pos/{id}` showing the line's `ReceivedQty` decremented.
21. If a cancel restores capacity to a PO that had been auto-closed, the PO's `Status` flips back to `open` automatically and reappears in FIFO availability.
22. After a successful cancel, the hour-grid cell, the modal's "Previously Received" + "Outstanding" cards, and the drawer all refresh.
23. Attempting to cancel a reversal row returns `409`.
24. Attempting to cancel a receipt whose parent pull is closed returns `409`.
25. The same Cancel flow from the drawer's per-row button, the modal-embedded list, and `transactions.html`'s table action menu produces identical server-side results.

### Drawer + Transactions page
19. Opening the drawer from the toolbar button shows all receipts for the pull. Opening it from "View all in drawer →" inside the Receive Goods modal pre-filters to that `(hour, itemCode)` — the green chip is visible and Clear removes the filter.
20. The drawer's "Open full view ↗" link goes to `transactions.html?pull=X&warehouse=Y&hour=H&item=CODE` with the hour banner visible and the search box pre-filled with both `pull` and `item` tokens.
21. `transactions.html` search "PL-2847 PCBA-AX450" returns only rows where **both** tokens are found (AND match).
22. Clicking the "Back to Controller" pill in the Receiving topbar navigates to **`pull-controller-v2.html`** (not v1).

### Close + Reopen
23. Close Pull Sheet is **disabled** until every non-canceled item's every window is full. Once eligible, the button pulses; clicking opens the signature modal.
24. On signature submit, the pull is closed server-side (`Status='closed'`, `ClosedAt`/`ClosedBy`/`SignatureSvg` persisted). Cells become view-only; status menu, all cancel buttons, and Confirm Receipt are gated everywhere.
25. As an **operator** viewing a closed pull, no Reopen button appears — only the "Pull Sheet Closed" pill.
26. As a **supervisor**, a Reopen button appears in place of the close pill. Clicking it prompts for a reason; submitting unlocks the pull (`Status='in_progress'`); `ClosedAt`, `ClosedBy`, `SignatureSvg` remain populated as history; `ReopenedAt`, `ReopenedBy`, `ReopenReason` are populated.
27. After reopen, receiving and cancellations work again. A subsequent close overwrites the close fields; the old close + reopen events stay in the audit log.
28. `POST /api/pulls/{id}/reopen` as an operator returns `403`.

### Settings + general
29. Switching theme/nav-position in `/Config` persists across reload and across log-out/log-in.
30. SQL injection probes against any search box / filter return clean — verified by reviewing that every `WHERE` uses Dapper parameters.
31. Direct API call to a write endpoint without auth returns `401`.
32. Direct API call to `DELETE /api/users/{id}` as a non-admin returns `403`.
33. No connection strings or passwords appear in any committed file under source control.

---

## 13. Deliverables (how to produce code)

1. **One reply per layer**: schema → repositories → services → controllers → view ports. Don't dump everything in one message.
2. **No skipped files**: if a controller references `IUserRepository.GetByUsernameAsync`, the interface and implementation must be in the same response or clearly referenced.
3. **Include `db/001_schema.sql` + `db/002_views.sql` + the seed scripts complete and runnable** — they are the foundation.
4. **For the seed**, generate password hashes using `PasswordHasher<User>` via `tools/HashPassword`. Do not leave plaintext in the SQL.
5. **Treat the HTML/CSS/JS mockups as ground truth**. Do not redesign. If something in the design is genuinely incompatible with server-rendering, call it out with a `// NOTE:` and propose the smallest change.
6. **Write at least one xUnit test per controller** hitting the happy path with `WebApplicationFactory`. Skip if time-boxed.
7. **All numeric arithmetic is whole units (pcs)** — use `int`, never `decimal`/`double`. DB enforces this via `INT` columns.

---

## 14. Out of Scope (do not build unless asked)

- Server-side Excel export (client-side SheetJS is fine for v1).
- Signature image processing (store the canvas data URL as-is, render with `<img>`).
- Multi-tenant / multi-org support.
- Email notifications.
- Internationalization (UI is English; data can be Thai — DB collation must support both).
- Mobile native app.
- Real-time updates via SignalR (poll every 30s on dashboard is acceptable for v1).
- Soft-delete on any entity. Receipts use reverse-entry; everything else hard-deletes with audit.

---

## 15. Start Here

1. Create solution + project: `dotnet new mvc -n ReceivingOps.Web -o src/ReceivingOps.Web`.
2. NuGet: `Dapper`, `Microsoft.Data.SqlClient`, `Microsoft.AspNetCore.Authentication.Cookies`, `Microsoft.AspNetCore.Identity.Core`.
3. Write `db/001_schema.sql` + `db/002_views.sql`. Run against the local instance.
4. Build `tools/HashPassword`, generate hashes for the 6 seed users, write `db/003_seed_users.sql` through `db/007_seed_pos_and_lines.sql`, then `db/008_seed_pulls_and_items.sql`, then `db/009_seed_receipts.sql`. Run them in order — POs must exist before pulls reference items, and receipts must reference both.
5. Build `IDbConnectionFactory`, repositories for Users + Warehouses + Assignments, `IAuthService`, `AccountController`, `AuthApiController`. **Demo the login flow before moving on** — including the dynamic warehouse dropdown.
6. **Build `IPurchaseOrderRepository` + `PurchaseOrdersApiController` first** (before any receive logic). Demo `GET /api/pos` + `GET /api/pos/availability` against the seed data — verify FIFO ordering is correct.
7. Repositories for Pulls + PullItems + PullItemWindows + view-based progress reads. Dashboard read path.
8. `IReceiptService.PreviewAsync` — the read-only FIFO preview (§7.2). Demo via curl before wiring the modal.
9. `IReceiptService.ReceiveAsync` — the transactional **receive** path with FIFO allocation (§7.2a). Test with a concurrent receive scenario to verify locking works.
10. `IReceiptService.CancelAsync` — the **cancel/reverse** path (§7.3). Wire the drawer Cancel button, the Receive Goods modal's embedded list, and `transactions.html` to the same endpoint.
11. `ICloseService` — **close** (§7.4) + **reopen** (§7.5), with the supervisor gate on reopen and the preserve-close-history semantics.
12. `TransactionsApiController` — the cross-pull journal with multi-token search (now PO-aware).
13. `MastersController` + Audit + Preferences.
14. Hand off the connection string to User Secrets the moment the first commit is about to happen.

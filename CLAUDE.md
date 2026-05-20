# ReceivingOps — Project Context

Multi-warehouse receiving system. ASP.NET Core 8 MVC + Dapper + SQL Server.

## Stack
- .NET 8 LTS, C# 12
- Dapper (no EF Core, no string concat in SQL)
- SQL Server (local: LAPTOP-CSB3KO3E)
- Cookie auth, PBKDF2 password hashing
- Bootstrap 5.3 + Bootstrap Icons frontend

## Source of truth
- `BUILD_PROMPT.md` — full spec (read this first)
- `mockups/` — HTML files that define the UI exactly (do not redesign)

## Conventions
- PascalCase SQL columns matching POCO properties (no Dapper mapping)
- Repositories `Scoped`, services `Scoped`, password hasher `Singleton`
- Every write writes an audit row via `IAuditService`
- Receipts table is APPEND-ONLY (no UPDATE except ReversedById, no DELETE)
- All numeric arithmetic is whole units (int, not decimal)

## Workflow
1. Schema first (db/001_schema.sql) before any C# code
2. Run SQL → verify → then build repositories → services → controllers
3. Demo each layer before moving on (see BUILD_PROMPT.md §15)

## Connection string
Local dev only. Move to User Secrets before first commit:
`dotnet user-secrets set "ConnectionStrings:Default" "..."`

## Out of scope (don't add unless asked)
See BUILD_PROMPT.md §14
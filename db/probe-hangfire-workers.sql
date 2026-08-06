/* ============================================================================
   ReceivingOps — Hangfire worker probe   (READ-ONLY)
   ----------------------------------------------------------------------------
   PURPOSE
     Answers one question: which machines are registered as Hangfire workers
     against THIS database, and are any of them still heartbeating?

     Hangfire is backed by the same SQL Server as the app —
     Program.cs:322-332 passes ConnectionStrings:Default straight into
     UseSqlServerStorage. So a Hangfire "server" row in HangFire.Server means a
     process somewhere opened that connection string and started taking jobs
     from these queues. There is no separate Hangfire credential to check.

     Run this on PRODUCTION. Every row it returns is a machine that has been
     picking up production background work: exports, ERP sync, PO import.

   WHY IT MATTERS
     `RECEIVINGOPS_HARDENING.md` records that on 2026-07-16 the DEV machine's
     user-secrets `ConnectionStrings:Default` pointed at the production host.
     Any `dotnet run` during that period would have registered the dev laptop
     in this table and let it execute production jobs against production data
     using whatever build happened to be checked out.

     Hangfire's ServerWatchdog removes rows whose heartbeat has lapsed, so a
     stale entry usually disappears on its own. The check that matters is
     whether anything OTHER than the production host appears below, especially
     with a recent heartbeat.

   READ-ONLY
     SELECTs only. Makes no changes. Safe to run against production any number
     of times.

   HOW TO RUN
     sqlcmd -S <prod-server> -d ReceivingOps -W -s " | " -i db\probe-hangfire-workers.sql

   INTERPRETING IT
     Result set 1 — one row per registered worker. `Id` is
       "<machinename>:<pid>:<guid>". Anything that is not the production web
       host is the finding. `SecondsSinceHeartbeat` under ~60 means it is live
       RIGHT NOW; a large value means the row is stale and the watchdog has not
       swept it yet.
     Result set 2 — queue depth, so an unexpected worker can be weighed against
       whether work is actually waiting.
     Result set 3 — recent job history, to see what has been executing.
   ============================================================================ */
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

IF OBJECT_ID('HangFire.Server') IS NULL
BEGIN
    SELECT 'NO HANGFIRE SCHEMA' AS Probe,
           'This database has no HangFire schema — nothing is registered here.' AS Result;
END
ELSE
BEGIN
    ------------------------------------------------------------------------
    -- 1. Registered workers. Anything that is not the production web host
    --    is the finding.
    ------------------------------------------------------------------------
    SELECT 'WORKER' AS Probe,
           s.Id,
           LEFT(s.Id, CHARINDEX(':', s.Id + ':') - 1)            AS MachineName,
           CONVERT(varchar(19), s.LastHeartbeat, 120)            AS LastHeartbeatUtc,
           DATEDIFF(SECOND, s.LastHeartbeat, GETUTCDATE())       AS SecondsSinceHeartbeat,
           CASE WHEN DATEDIFF(SECOND, s.LastHeartbeat, GETUTCDATE()) < 60
                THEN '*** LIVE NOW ***' ELSE 'stale' END          AS State
    FROM   HangFire.Server s
    ORDER  BY s.LastHeartbeat DESC;

    ------------------------------------------------------------------------
    -- 2. What is waiting, per queue.
    ------------------------------------------------------------------------
    SELECT 'QUEUE' AS Probe, q.Queue, COUNT(*) AS Enqueued
    FROM   HangFire.JobQueue q
    GROUP  BY q.Queue
    ORDER  BY q.Queue;

    ------------------------------------------------------------------------
    -- 3. Recent job history — what has actually been executing here.
    ------------------------------------------------------------------------
    SELECT TOP 25 'RECENT JOB' AS Probe,
           j.Id,
           j.StateName,
           CONVERT(varchar(19), j.CreatedAt, 120) AS CreatedAtUtc,
           LEFT(j.InvocationData, 160)            AS Invocation
    FROM   HangFire.Job j
    ORDER  BY j.CreatedAt DESC;
END
GO

PRINT 'probe-hangfire-workers.sql complete (read-only).';
GO

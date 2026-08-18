# Defect — a pull item whose storer has no PO line of its own allocates across storers, silently and indefinitely

**Status:** open, not fixed, and **not fixable by the storer-grain change** — this is
the residual case that change's vendor filter deliberately cannot close. Logged
2026-08-19 alongside `fa8a0e2`.

**Severity:** moderate, standing, and invisible. It is not a migration artefact and it
does not resolve as pulls close: every ETL run recreates the same condition for as long
as the underlying purchase orders are missing.

---

## The condition

`fa8a0e2` made the FIFO walk filter PO lines by the pull item's storer, so stock
delivered by one storer can no longer be booked against another's purchase order. That
filter applies **only when the item's storer actually has a candidate line**. When it
has none — but other storers' lines exist for the same SKU — the filter is skipped and
the walk falls back to the whole SKU pool, exactly as it behaved before storer grain.

That fallback is deliberate and must stay: without it, those items become unreceivable
(`Insufficient PO capacity. Need N, have 0`), which would break receiving on live data
in the name of correctness. `smoke-storer-grain.ps1` §8b pins it.

But the fallback is silent. An item in this state keeps allocating onto **some other
storer's** purchase order, receipt after receipt, with nothing in the UI, the audit
trail, or the response saying so. It is the original §1 defect, surviving in the one
population the fix cannot reach — and now less likely to be noticed, because everywhere
else the boundary is enforced.

## Scale — measured on the dev database, 2026-08-19

| Measure | Value |
|---|---|
| Pull items in the fallback state | **593** |
| Distinct pulls affected | 516 |
| Distinct storers | 39 |
| Distinct SKUs | 80 |

Top storers by affected item count: `5732` (106), `WIPBP3` (76), `70262` (60), `3160`
(57), `HSABP3` (56), `76583` (36), `25152` (34), `IHGST` (23). These are real ERP storer
codes, not seed data.

### The query

Run against the target database. It reports items on non-closed pulls whose storer has
**no** open PO line for the SKU while other storers **do** — the exact population the
vendor filter skips. The `matchLine` subquery is the same either-form comparison
`ReceiptService.VendorMatchSql` builds (exact, or prefixed-with-a-hyphen), because
`PurchaseOrderLines.VendorCode` is prefixed (`COI-5732`) and `PullItems.VendorCode` is
stripped (`5732`).

```sql
SELECT pi.Id, pi.ItemCode, pi.VendorCode, p.PullNumber, p.Status AS PullStatus,
  (SELECT COUNT(*) FROM dbo.PurchaseOrderLines pol
     INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
   WHERE pol.ItemCode = pi.ItemCode AND po.Status = 'open'
     AND pol.OrderedQty > pol.ReceivedQty)                                   AS anyLine,
  (SELECT COUNT(*) FROM dbo.PurchaseOrderLines pol
     INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
   WHERE pol.ItemCode = pi.ItemCode AND po.Status = 'open'
     AND pol.OrderedQty > pol.ReceivedQty
     AND (pol.VendorCode = pi.VendorCode
          OR (RIGHT(pol.VendorCode, LEN(pi.VendorCode)) = pi.VendorCode
              AND SUBSTRING(pol.VendorCode, LEN(pol.VendorCode) - LEN(pi.VendorCode), 1) = '-')))
                                                                             AS matchLine
INTO   #c
FROM   dbo.PullItems pi
INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE  pi.VendorCode IS NOT NULL
  AND  p.Status  <> 'closed'
  AND  pi.Status <> 'canceled';

-- The population:
SELECT COUNT(*) AS ItemsInFallback FROM #c WHERE anyLine > 0 AND matchLine = 0;
SELECT VendorCode, COUNT(*) AS Items FROM #c
WHERE anyLine > 0 AND matchLine = 0 GROUP BY VendorCode ORDER BY Items DESC;

DROP TABLE #c;
```

## The question this raises, which is not a code question

Every one of these 593 items is a planned delivery from a storer for which **no open
purchase order line exists**. Either:

- **procurement should be issuing those POs** and isn't — in which case the goods are
  arriving without purchase-order cover and the fallback is masking a procurement gap;
  or
- **the storer genuinely has no PO** because the goods are covered some other way (a
  transfer, a VMI arrangement, WIP movement — note `WIPBP3` and `HSABP3` are prominent
  in the list), in which case allocating them onto another storer's PO is still wrong,
  and what they need is their own cover rather than a borrowed line.

Either way the answer belongs to whoever owns purchasing, not to this codebase. That is
why this is logged rather than coded around: a code fix would have to pick one of those
answers, and picking wrong writes fabricated attribution into receipt history.

## Fix sketch — not applied

1. **Surface it, change nothing.** When the walk falls back, write an audit row
   (`receive-storer-fallback`) naming the item, its storer, and the PO line actually
   consumed. Cheapest option, and it converts an invisible condition into a searchable
   one. Cost: one audit row per receive in this population.
2. **Report it.** A standing query on the admin surface, or a column on the pull drawer,
   flagging items with no PO line for their storer — visible before receiving rather
   than after.
3. **Refuse, once procurement confirms.** If the answer to the question above is "those
   POs should exist", then the fallback becomes wrong and the honest behaviour is the
   hard filter that `fa8a0e2` backed out of — with the 593 items resolved first, not
   after. **Do not do this without that confirmation**: applied today it makes 593 live
   items unreceivable.

## Related, do not conflate

- `fa8a0e2` is the storer-grain fix. It closes the case where **both** storers have
  their own PO lines — the 107 (pull, SKU) pairs and 2,500,523 units in one day's
  export. This document is the complement: where **one** storer has none.
- `smoke-storer-grain.ps1` §8b asserts the fallback still receives. It asserts nothing
  about the allocation being cross-storer, because that is the behaviour being
  preserved, not a bug being guarded.
- `defect-erp-piped-round-drops-hours.md` — same export, unrelated mechanism.

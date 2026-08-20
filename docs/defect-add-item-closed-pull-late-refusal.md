# Defect — Add Item on a closed pull is refused only after the form is filled

**Status:** open, not fixed. Logged 2026-08-20 while building the drawer's duplicate-row
action (`brief-drawer-duplicate-row.md`). **Deliberately out of scope for that change** —
§3.4 of that brief directed duplicate to inherit Add Item's existing behaviour rather than
introduce a second, better-behaved path into the same operation. Fixing it belongs to Add
Item, not to duplicate.

**Severity:** low. Nothing is lost or corrupted; the server refuses correctly and the
transaction rolls back. The cost is wasted operator effort and a refusal that arrives at the
least useful moment.

---

## Symptom

An operator opens the drawer on a closed pull. The **Add item** button is present and looks
active. They click it, the modal opens, they type an item code, a description, a vendor, a
tag, a remark, and at least one window hour and quantity. They press **Create item**.

Only then are they told:

> Cannot modify items on a closed pull. Reopen it first if you need to change items.

The message is correct, and it names the remedy. It simply arrives after all the typing
rather than before any of it.

Since 2026-08-20 the same is true of the drawer's **duplicate** action, which opens the same
modal and goes through the same create path. Duplicate is cheaper to abandon — the form comes
pre-filled, so less is lost — but the shape of the failure is identical.

## Mechanism

The gate exists in exactly one place, and it is on the server.

- `PullsApiController.CreateItem` is `[Authorize(Policy = "CanManagePulls")]`, which covers
  *who* may add items but says nothing about the pull's state.
- `PullItemAdminService.CreateAsync` calls `LockPullAsync` then `RefuseClosed`, which throws
  `BusinessException` when `Pulls.Status = 'closed'`. Seven other methods in that service
  follow the same pattern, so the rule is applied consistently — it is only the *timing* that
  is poor.

The client has no gate at all:

- `Views/Dashboard/Index.cshtml` renders `#d-add-item` unconditionally. There is no
  `data-admin-only`, no role attribute, no status attribute.
- `dashboard.js` binds one click listener to it and nothing else. Nothing reads the pull's
  status, and nothing disables the button.

So the drawer offers an action on a closed pull that the pull cannot accept, and discovers
that only on submit.

## Why it has not been noticed

Closed pulls are a small share of what operators open, and an operator who has just closed a
pull is unlikely to try adding items to it in the same sitting. The people most likely to hit
it are those opening an old pull to read its history, where clicking **Add item** is a
mis-click rather than an intention — which is also why nobody reports it.

## What a fix would look like

The cheap version is a client-side disable driven by the data the drawer already has.
`renderDrawer` receives the pull object and already branches on `p.status === 'closed'` for
the close-authorisation section (`dashboard.js:583`), so the status is in hand at the right
moment. Disabling `#d-add-item` and the per-row duplicate trigger there, with a `title`
explaining why, would move the refusal to before the typing.

Two things that fix must not do:

- **It must not become the only gate.** `RefuseClosed` stays exactly as it is. A client
  disable is a courtesy; the server is the authority, and the API is reachable without the
  page.
- **It must not gate one action and not the other.** Add Item and duplicate open the same
  modal and share the same create path. Gating one would produce precisely the divergence
  `smoke-pull-drawer-actions.ps1` now asserts against, where a closed pull refuses one entry
  point and silently accepts the other as far as the submit.

## Related

- `brief-drawer-duplicate-row.md` §2.1 and §3.4 — where this was found and why it was left.
- `tools/smoke-pull-drawer-actions.ps1` — asserts that duplicate has not acquired a
  client-side gate Add Item lacks, so the two cannot drift apart before this is fixed
  properly.

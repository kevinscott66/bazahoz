# Migration application order

> ## Recorded production state on 2026-08-02: all migrations applied
>
> The live database was fully reconciled. `2026-07-31_verify_applied_state.sql` returned 41 successful rows and a correct-order result. Four migrations outside its coverage were checked separately: `2026-08-01_search_path_and_is_admin_policies`, `2026-08-02_default_privileges`, `2026-08-02_guard_bases_update` and `2026-08-02_rls_speed_stock`. `pg_cron` 1.6.4 was enabled, and `vahtahoz_stock_history_prune` and `vahtahoz_auth_rate_prune` were active with `succeeded` runs.
>
> The instructions below are for rebuilding a database and applying new migrations. Always run the verifier before applying anything; this dated observation is not a current live check.

Migrations are applied **manually** through Supabase → SQL Editor. There is no migration framework enforcing their order.

## 0. Single-file installation

**`APPLY_ALL_2026-07-31.sql`** combines the package in order and finishes with diagnostics. Paste the entire file into SQL Editor and run it. Three consecutive runs against a fresh database completed without errors. All final diagnostic rows should indicate present/OK and the summary should report correct order.

This file is **generated** from the individual migrations. Edit those sources, then regenerate the bundle; the generation command is in Git history and concatenates the section 2 files followed by verification.

**For an already-applied package:** `2026-08-01_handover_round9_fixes.sql` is the incremental, self-contained update described by this package. Three repeated runs confirmed idempotency; it removes duplicate overloads itself. If pg_cron is enabled but retention has not been scheduled, apply `2026-07-31_schedule_retention.sql` separately.

## 1. Inspect current state first

Run **`2026-07-31_verify_applied_state.sql`**. It only reads system catalogs and reports each expected object plus a final recommendation. The final summary row tells the operator what to do next; runtime diagnostic labels remain in Russian.

## 2. Order for the July 2026 package

```text
2026-07-30_base_member_preset_all_roles.sql     # Permission presets for all base roles
2026-07-30_stock_history_guard.sql              # Stock history and CHECK qty >= 0
2026-07-30_stock_history_guard_fix.sql          # Report authorization and near-zero threshold
2026-07-30_auth_rate_per_ip.sql                 # auth_rate table and IP throttling
2026-07-31_audit_round3_sql_fixes.sql           # Round 3/4 fixes, after the preceding files
2026-07-31_org_roles_preset_guard.sql           # Organization-role presets and guard
2026-08-01_zeroing_report_fixes.sql             # Loss threshold, shared semantics, misclassification detection
2026-08-01_audit_round6_fixes.sql               # Round 6 fixes
2026-08-01_handover_consistency.sql             # Handover: orphan, race and incoming-role preset fixes
2026-08-01_handover_round9_fixes.sql            # Round 9 fixes, LAST
```

**Handover files must follow `2026-07-28_journal_private_orphan_handover.sql`.** Three files define `handover_shift`; section 6 of the July 28 file is the oldest. Before round 9, it unconditionally recreated the function and silently reverted newer versions, while the verifier failed to check handover. Now it recognizes a newer version, skips section 6 and prints `WARNING`. The verifier checks the function revision and reports a partial/reverted handover state. Both handover files are included in `APPLY_ALL`.

Outside that chain, requiring pg_cron but no specific ordering:

```text
2026-07-31_schedule_retention.sql               # stock_history_prune and auth_rate_prune jobs
```

**The order of the August 1 files matters.** `audit_round6_fixes` recreates the same four functions with broader signatures. Running `zeroing_report_fixes` afterward reverts them; the file warns and the verifier detects it. Reapply `audit_round6_fixes` to recover. Likewise, `handover_round9_fixes` must follow `audit_round6_fixes`: it recreates `stock_zeroing_report` and `stock_qty_restore` with round 9 parameters. Reversing them reverts those functions; round 6 now warns about that too.

`zeroing_report_fixes` adds a configurable substantial-loss threshold (`p_min_frac`), shared before-window semantics (`qty_at_window_start`), routine-consumption classification (`verdict`), and metadata misclassification detection/restoration (`stock_meta_change_report` / `stock_meta_restore`).

`audit_round6_fixes` addresses:

- `is_backend_role` returning NULL and bypassing six permission checks.
- Restoration overwriting legitimate changes after the incident window.
- Type-filter differences between report and restoration sets.
- `verdict='routine'` hiding a single large loss.
- Inability to repair legacy `base_members` rows through the UI.
- Duplicate overloads created by rerunning older files.

`handover_round9_fixes` addresses:

- Moving another base's tasks to an unrelated manager because only the outgoing member was checked.
- Handover reporting success without acting: replay detection now uses invocation identity through `public.handover_log`, rather than state alone.
- Restoration treating its own second incident stage as legitimate shift work.
- Deleted items missing from restoration output, causing report/count mismatches.
- An absolute routine threshold hiding near-total losses of low-volume stock.
- An incorrect comment about the restoration-subset-of-report invariant.
- Journal entries with an indeterminate type that could not be created, viewed or deleted.

`org_roles_preset_guard` fixes warehouse visibility for party-chief/director roles: legacy `can_view_stock=false` could deny access through `has_perm` despite role-type permissions. It also permits deactivation of legacy unknown (`custom`) roles during handover, matching the round 3 organization-role fix.

`_guard_fix` **supplements, rather than replaces, `stock_history_guard`**. It does not create the history table, trigger or CHECK. An explicit prerequisite check rejects out-of-order application.

## 2.1 Independent August files

```text
2026-08-02_default_privileges.sql               # Do not automatically grant new public objects to anon
2026-08-02_guard_bases_update.sql               # Preserve an existing database guard in source
2026-08-02_rls_speed_stock.sql                  # Stock query: 1678 ms to 11 ms
```

These files can be applied independently of the preceding chain.

`default_privileges` removes an unsafe default for future objects: automatic grants to anon/authenticated combined with a table created without RLS could expose it silently. New tables instead require explicit grants; forgetting one produces a visible permission error. Existing table privileges and older app builds are unchanged.

`guard_bases_update` records a guard that existed only in the live database. Reconciliation of 24 functions, 25 policies and six triggers found that rename/base-transfer protection would otherwise disappear during a rebuild. It preserves existing behavior.

`rls_speed_stock` reduced a measured 21,000-row stock query from **1678 ms to 11 ms**. SECURITY DEFINER functions with `SET search_path` were not inlined, producing per-row calls with three subqueries each, despite depending only on eight bases and four property types. `my_perm_bases` and `my_visible_types` now calculate the 32 possible answers once. Permissions still use the same functions. Validation compared 240 old/new answer pairs, per-user visible row counts and set checksums, warehouse-clerk insert/update/select/delete, and rejection of writes to another base.

Repeat the measurement in SQL Editor:

```sql
begin;
select set_config('request.jwt.claims',
  json_build_object('sub', '<user UUID>', 'role','authenticated')::text, true);
set local role authenticated;
explain (analyze, timing off) select id, base_id from public.stock_items;
rollback;
```

## 3. Unsafe intermediate states

### 3.1 Broken shift handover

Applying `base_member_preset_all_roles.sql` without `audit_round3_sql_fixes.sql` breaks handover. The intermediate `enforce_base_member_write` rejects INSERT/UPDATE for non-base roles. Pre-v134 bases can contain organization roles such as `party_chief` in `base_members`; deactivating those rows from `handover_shift` then fails.

`audit_round3` limits rejection to row creation or an actual change to an organization role, allowing legacy deactivation/handover. Local PostgreSQL 16 tests reproduced the failure with presets alone and verified recovery after round 3. The verifier marks that intermediate state urgent.

### 3.2 Duplicate overloads: `is not unique`

Rerunning `audit_round3_sql_fixes.sql` over August 1 files left old signatures alongside new ones: `stock_zeroing_report(uuid,int)` and `stock_qty_restore(uuid,timestamptz,boolean,timestamptz)`. All three runbook tools then failed with `is not unique`, and verification failed with `more than one row returned by a subquery`.

Since round 6, each of the three files removes all overloads before recreation. Apply `2026-08-01_audit_round6_fixes.sql` to repair an existing duplicate state, then retain the required subsequent migration order. The verifier now reports overloads as its first row instead of crashing.

## 4. After application

- Rerun `2026-07-31_verify_applied_state.sql`; every row should report present/OK.
- `CHECK stock_items_qty_nonneg` starts as `NOT VALID` to accommodate legacy rows. Once negative balances are resolved, run `alter table public.stock_items validate constraint stock_items_qty_nonneg;`.
- `2026-07-31_schedule_retention.sql` schedules `vahtahoz_stock_history_prune` for 180 days and `vahtahoz_auth_rate_prune` for one day. Without pg_cron it reports that no jobs were created. Manual alternatives: `select public.stock_history_prune(180);` and `select public.auth_rate_prune(1);`.
- See `docs/RUNBOOK_STOCK_RECOVERY.md` for incident recovery.

## Large files

`audit_round3_sql_fixes.sql` is about 22 KB; Management API submission sometimes returns 502. SQL Editor accepts the full file. For API application, split only at `begin; ... commit;` boundaries; never split a transaction.

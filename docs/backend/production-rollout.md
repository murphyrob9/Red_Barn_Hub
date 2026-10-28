# RB04 release scope

The DEV CSV path imports immutable exported financial fields, normalizes linked
orders/payments, posts positive payment-tip events and report-level discount
groups, and exposes reconciled collections through `rb04-app-operations`.

The CSV source adapter is `scripts/rb04/prepare_clover_csv_batch.py`. Original
export hashes, filenames and row positions remain in raw snapshots. CSV records
use separate resource names and never masquerade as native Clover API responses.
Run the prepared batch through `rb04.import_clover_csv_batch_dev(jsonb)` as the
database operator in one transaction: lock the disabled global and merchant
controls, enable them inside the transaction, import, restore both to disabled,
and commit. Import errors roll back the entire transaction. Reusing the identical
batch returns its existing result; changed sources for an already-imported date
require an explicit correction rather than a second posting.

`accountability_collections_daily` and `financial_summary` retain separate actual
and Clover-reference metrics. Gross here is receipt-net plus reported discounts;
it is not an assertion of per-order historical gross allocation. Tips use payment
employee IDs. Report discount groups never inherit inferred order/employee IDs.
No SALE events or employee-to-login mappings are manufactured.

Review decisions append to the event history with the verified reviewer user ID.
OWNER/MANAGER may review; ADMIN retains read access under the current schema.
Approval/rejection requires a rule matching the event type, role, amount and event
business date. An owner configures those rules through the app; no approval
limits or policy references are supplied automatically. Decisions do not modify
financial amounts. Unlinked employees continue to be denied employee data.

# Production release boundary

The functions in this repository are currently DEV-scoped, including compiled
DEV merchant guards and the two private-preview CORS origins. They are not a
production deployment artifact. No CI workflow deploys them or enables ingestion.

A production release requires the actual destination project and merchant
identity, a published origin, the approved per-order/line sales and reversal
recognition mappings, configured approval policies, and verified employee/login
links. Keep opening-business-date sales recognition distinct from payment-date
collections. Current order exports cannot establish historical order states by
themselves. Native Clover ingestion stays disabled while that release scope is
unresolved.

The captured baseline has been recorded as applied in DEV migration history
without executing its CREATE statements over existing objects. The follow-on
pipeline migration has been applied to DEV as version `20261028060542`, matching
the versioned SQL filename. A fresh destination must
first provide the Supabase auth objects and external roles stated in the baseline
header; role credentials and local auth stubs are never included in migrations.

No production database, Clover POS data, scheduler, or published site has been
changed by this release.

# RB04 Edge Functions

`rb04-app-api` is the canonical authenticated read API. Send POST bodies with `view`, optional `merchantId`, and dated-view `start`/`end`. Identity is verified with Supabase Auth; membership, merchant eligibility, role, and employee linkage are enforced by `public.rb04_app_readonly_dev`. No caller-supplied user, employee, or role fields are accepted.

`rb04-app-readonly` is the existing compatibility endpoint, including its empty-body connectivity contract. Its deployed source is preserved unchanged.

`hyper-worker` is the actual deployed slug for the function displayed as `rb04-clover-ingest-dev`. Keep that slug when capturing or deploying the existing ingestion handler. The captured build keeps commit/import routes disabled.

`rb04-db-connectivity-test` is the existing restricted connectivity diagnostic.

`../deployed-functions.json` records the deployment versions captured before the authenticated API update. The capture commit preserves those source files exactly; subsequent API revisions are ordinary commits.

No service keys or Clover credentials belong in these files. Runtime secrets stay in Supabase.

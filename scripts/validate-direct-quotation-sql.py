from pathlib import Path
from pglast import parse_sql

paths = [
    Path("supabase/migrations/20261119120000_frosttech_independent_quotations_foundation.sql"),
    Path("supabase/migrations/20261119130000_frosttech_direct_quotation_draft_editing.sql"),
    Path("supabase/migrations/20261119140000_frosttech_admin_direct_quotation_count_rpc.sql"),
    Path("supabase/migrations/20261119170000_frosttech_direct_order_sourcing_finance.sql"),
    Path("supabase/migrations/20261120102000_harden_receipt_delivery_trigger_function.sql"),
    Path("supabase/migrations/20261120113000_fix_direct_finance_activity_period.sql"),
]
for path in paths:
    statements = parse_sql(path.read_text(encoding="utf-8"))
    print(f"PostgreSQL parser accepted {len(statements)} statements in {path}.")

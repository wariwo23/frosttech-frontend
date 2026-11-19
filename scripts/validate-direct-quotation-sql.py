from pathlib import Path
from pglast import parse_sql

paths = [
    Path("supabase/migrations/20261119120000_frosttech_independent_quotations_foundation.sql"),
    Path("supabase/migrations/20261119130000_frosttech_direct_quotation_draft_editing.sql"),
]
for path in paths:
    statements = parse_sql(path.read_text(encoding="utf-8"))
    print(f"PostgreSQL parser accepted {len(statements)} statements in {path}.")

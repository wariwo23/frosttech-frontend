from pathlib import Path
from pglast import parse_sql

path = Path("supabase/migrations/20261119120000_frosttech_independent_quotations_foundation.sql")
sql = path.read_text(encoding="utf-8")
statements = parse_sql(sql)
print(f"PostgreSQL parser accepted {len(statements)} statements in {path}.")

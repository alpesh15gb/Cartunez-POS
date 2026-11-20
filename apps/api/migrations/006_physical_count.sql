CREATE INDEX IF NOT EXISTS stock_ledger_count_revision ON stock_ledger(organization_id,branch_id,product_id,bin_id);
INSERT INTO schema_migrations(version) VALUES(6) ON CONFLICT DO NOTHING;

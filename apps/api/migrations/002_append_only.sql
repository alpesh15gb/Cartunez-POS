CREATE OR REPLACE FUNCTION reject_ledger_rewrite() RETURNS trigger AS $$ BEGIN
 RAISE EXCEPTION 'Financial ledgers and idempotency records are append-only';
END; $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS append_only_stock_ledger ON stock_ledger;
CREATE TRIGGER append_only_stock_ledger BEFORE UPDATE OR DELETE ON stock_ledger FOR EACH ROW EXECUTE FUNCTION reject_ledger_rewrite();
DROP TRIGGER IF EXISTS append_only_transactions ON transactions;
CREATE TRIGGER append_only_transactions BEFORE UPDATE OR DELETE ON transactions FOR EACH ROW EXECUTE FUNCTION reject_ledger_rewrite();
INSERT INTO schema_migrations(version) VALUES(2) ON CONFLICT DO NOTHING;

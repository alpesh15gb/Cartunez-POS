-- Drawer movements stay available for shift reconciliation and must be append-only.
DROP TRIGGER IF EXISTS append_only_cash_movements ON records;
CREATE TRIGGER append_only_cash_movements BEFORE UPDATE OR DELETE ON records
 FOR EACH ROW WHEN (OLD.kind = 'cashMovement') EXECUTE FUNCTION reject_ledger_rewrite();
INSERT INTO schema_migrations(version) VALUES(4) ON CONFLICT DO NOTHING;

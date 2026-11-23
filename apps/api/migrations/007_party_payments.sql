DROP TRIGGER IF EXISTS append_only_party_payments ON records;
CREATE TRIGGER append_only_party_payments BEFORE UPDATE OR DELETE ON records
 FOR EACH ROW WHEN (OLD.kind = 'partyPayment') EXECUTE FUNCTION reject_ledger_rewrite();
INSERT INTO schema_migrations(version) VALUES(7) ON CONFLICT DO NOTHING;

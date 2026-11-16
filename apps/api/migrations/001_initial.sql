CREATE TABLE IF NOT EXISTS schema_migrations (version integer PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS installation_lock (id integer PRIMARY KEY, revision bigint NOT NULL DEFAULT 0);
INSERT INTO installation_lock(id) VALUES (1) ON CONFLICT DO NOTHING;
CREATE TABLE IF NOT EXISTS records (
  id text NOT NULL, organization_id text NOT NULL, branch_id text NOT NULL DEFAULT '',
  kind text NOT NULL, data jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id,kind,id)
);
CREATE INDEX IF NOT EXISTS records_scope ON records(organization_id,branch_id,kind);
CREATE TABLE IF NOT EXISTS stock (
 organization_id text NOT NULL, branch_id text NOT NULL, product_id text NOT NULL,
 bin_id text NOT NULL, quantity bigint NOT NULL DEFAULT 0,
 PRIMARY KEY(organization_id,branch_id,product_id,bin_id)
);
CREATE TABLE IF NOT EXISTS stock_ledger (
 id text PRIMARY KEY, organization_id text NOT NULL, branch_id text NOT NULL,
 product_id text NOT NULL, bin_id text NOT NULL, quantity bigint NOT NULL,
 reason text NOT NULL, reference_id text NOT NULL, user_id text NOT NULL,
 cost bigint NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ledger_scope ON stock_ledger(organization_id,branch_id,created_at);
CREATE TABLE IF NOT EXISTS transactions (
 organization_id text NOT NULL, transaction_id text NOT NULL,
 request_hash text NOT NULL, result jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(organization_id,transaction_id)
);
CREATE OR REPLACE FUNCTION protect_invoice() RETURNS trigger AS $$ BEGIN
 IF OLD.kind IN ('invoice','return','audit','coreReturn') THEN RAISE EXCEPTION 'Issued financial and audit records are immutable'; END IF;
 RETURN NEW;
END; $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS immutable_financial_records ON records;
CREATE TRIGGER immutable_financial_records BEFORE UPDATE OR DELETE ON records FOR EACH ROW EXECUTE FUNCTION protect_invoice();
INSERT INTO schema_migrations(version) VALUES(1) ON CONFLICT DO NOTHING;

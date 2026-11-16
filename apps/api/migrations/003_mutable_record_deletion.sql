-- A BEFORE DELETE trigger must return OLD to permit ordinary record deletion.
-- Financial and audit records remain append-only.
CREATE OR REPLACE FUNCTION protect_invoice() RETURNS trigger AS $$ BEGIN
 IF OLD.kind IN ('invoice','return','audit','coreReturn') THEN RAISE EXCEPTION 'Issued financial and audit records are immutable'; END IF;
 IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END; $$ LANGUAGE plpgsql;
INSERT INTO schema_migrations(version) VALUES(3) ON CONFLICT DO NOTHING;

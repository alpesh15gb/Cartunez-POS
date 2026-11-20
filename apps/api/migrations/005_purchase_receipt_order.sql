CREATE INDEX IF NOT EXISTS purchase_receipt_order ON records
 (organization_id, branch_id, (data->>'purchaseOrderId'), created_at DESC, id DESC)
 WHERE kind = 'purchaseReceipt';
INSERT INTO schema_migrations(version) VALUES(5) ON CONFLICT DO NOTHING;

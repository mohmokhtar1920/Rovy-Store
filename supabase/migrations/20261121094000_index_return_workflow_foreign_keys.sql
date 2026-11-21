CREATE INDEX IF NOT EXISTS idx_return_request_events_actor ON private.return_request_events(actor_user_id);
CREATE INDEX IF NOT EXISTS idx_return_request_events_request ON private.return_request_events(return_request_id,created_at DESC);
CREATE INDEX IF NOT EXISTS idx_return_request_items_product ON private.return_request_items(product_id);
CREATE INDEX IF NOT EXISTS idx_return_requests_inspected_by ON private.return_requests(inspected_by);
CREATE INDEX IF NOT EXISTS idx_return_requests_received_by ON private.return_requests(received_by);
CREATE INDEX IF NOT EXISTS idx_return_requests_refund_paid_by ON private.return_requests(refund_paid_by);
CREATE INDEX IF NOT EXISTS idx_return_requests_replacement_order ON private.return_requests(replacement_order_id);
CREATE INDEX IF NOT EXISTS idx_return_requests_reviewed_by ON private.return_requests(reviewed_by);
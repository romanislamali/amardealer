-- =============================================================================
-- AmarDealer DMS · smoke test for isolation, limits, stock, ledgers, numbering, audit
-- Run against a FRESH database after schema.sql + seed/reference_data.sql:
--   psql -v ON_ERROR_STOP=1 -d amardealer_test -f db/tests/smoke_test.sql
-- Tenant-side steps run as dms_app (SET LOCAL ROLE) so RLS is really enforced.
-- =============================================================================
\set ON_ERROR_STOP on
\set QUIET on
\pset tuples_only on
\pset format unaligned

-- expect_error(sql, sqlstate): passes only if the statement fails with that SQLSTATE
CREATE FUNCTION pg_temp.expect_error(p_sql text, p_sqlstate text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = p_sqlstate THEN
      RETURN format('PASS  %s -> %s %s', left(p_sql, 60), SQLSTATE, left(SQLERRM, 70));
    END IF;
    RAISE EXCEPTION 'FAIL  % -> expected %, got % %', left(p_sql, 60), p_sqlstate, SQLSTATE, SQLERRM;
  END;
  RAISE EXCEPTION 'FAIL  % -> expected %, but it succeeded', left(p_sql, 60), p_sqlstate;
END $$;

CREATE FUNCTION pg_temp.expect(p_label text, p_actual anyelement, p_expected anyelement) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  IF p_actual IS DISTINCT FROM p_expected THEN
    RAISE EXCEPTION 'FAIL  %: expected %, got %', p_label, p_expected, p_actual;
  END IF;
  RETURN format('PASS  %s = %s', p_label, p_actual);
END $$;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO PUBLIC;

-- -----------------------------------------------------------------------------
\echo '== 1. Platform provisioning (Super Admin, BYPASSRLS)'
-- -----------------------------------------------------------------------------
BEGIN;
INSERT INTO tenants (id, slug, legal_name, status, bin) VALUES
  ('a0000000-0000-4000-8000-000000000001', 'rahim-motors', 'Rahim Motors Ltd', 'active', '000123456'),
  ('b0000000-0000-4000-8000-000000000002', 'karim-fmcg',   'Karim Distribution', 'active', NULL);
INSERT INTO users (id, email, full_name) VALUES
  ('10000000-0000-4000-8000-000000000001', 'owner@rahim.test', 'Owner A'),
  ('10000000-0000-4000-8000-000000000002', 'owner@karim.test', 'Owner B');
SELECT sync_tenant_limits_from_plan('a0000000-0000-4000-8000-000000000001', (SELECT id FROM plans WHERE code = 'starter'));
SELECT sync_tenant_limits_from_plan('b0000000-0000-4000-8000-000000000002', (SELECT id FROM plans WHERE code = 'growth'));
INSERT INTO subscriptions (id, tenant_id, plan_id, plan_price_id, status, locked_price, trial_ends_at,
                           current_period_start, current_period_end)
SELECT 'c0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001', p.id, pp.id, 'trialing',
       pp.price, now() + interval '14 days', now(), now() + interval '14 days'
  FROM plans p JOIN plan_prices pp ON pp.plan_id = p.id AND pp.billing_interval = 'monthly'
 WHERE p.code = 'starter';
COMMIT;
SELECT pg_temp.expect('starter max_branches', limit_value, 1::bigint)
  FROM tenant_feature_limits WHERE tenant_id = 'a0000000-0000-4000-8000-000000000001' AND feature_key = 'max_branches';

-- -----------------------------------------------------------------------------
\echo '== 2. Tenant A onboarding as dms_app (motorbike dealer)'
-- -----------------------------------------------------------------------------
BEGIN;
SET LOCAL ROLE dms_app;
SELECT set_config('app.current_tenant_id', 'a0000000-0000-4000-8000-000000000001', true),
       set_config('app.current_user_id',   '10000000-0000-4000-8000-000000000001', true) \g /dev/null

INSERT INTO branches (id, tenant_id, code, name, branch_type)
VALUES ('a1000000-0000-4000-8000-000000000001', current_tenant_id(), 'DHK01', 'Dhaka Showroom', 'showroom');
INSERT INTO warehouses (id, tenant_id, branch_id, code, name, warehouse_type)
VALUES ('a2000000-0000-4000-8000-000000000001', current_tenant_id(), 'a1000000-0000-4000-8000-000000000001', 'DHK-WH', 'Dhaka Store', 'main');
INSERT INTO tenant_memberships (tenant_id, user_id, status, is_owner, default_branch_id)
VALUES (current_tenant_id(), '10000000-0000-4000-8000-000000000001', 'active', true, 'a1000000-0000-4000-8000-000000000001');

INSERT INTO units (id, tenant_id, code, name, unit_category, allows_fraction) VALUES
  ('a3000000-0000-4000-8000-000000000001', current_tenant_id(), 'pcs', 'Piece', 'count', false),
  ('a3000000-0000-4000-8000-000000000002', current_tenant_id(), 'ltr', 'Litre', 'volume', true);
INSERT INTO serial_identifier_types (id, tenant_id, code, label, validation_regex)
VALUES ('a6000000-0000-4000-8000-000000000001', current_tenant_id(), 'chassis_no', 'Chassis No', '^[A-Z0-9]{5,20}$');

INSERT INTO products (id, tenant_id, code, name, product_type, tracking_mode, base_unit_id, warranty_months, custom_fields) VALUES
  ('a4000000-0000-4000-8000-000000000001', current_tenant_id(), 'BIKE-150', 'Roadster 150cc', 'stockable', 'serial',
   'a3000000-0000-4000-8000-000000000001', 24, '{"engine_cc": 150}'),
  ('a4000000-0000-4000-8000-000000000002', current_tenant_id(), 'OIL-1L', 'Engine Oil 1L', 'stockable', 'none',
   'a3000000-0000-4000-8000-000000000002', NULL, '{}');
INSERT INTO product_variants (id, tenant_id, product_id, sku, name, is_default) VALUES
  ('a5000000-0000-4000-8000-000000000001', current_tenant_id(), 'a4000000-0000-4000-8000-000000000001', 'BIKE-150-RED', 'Roadster 150cc Red', true),
  ('a5000000-0000-4000-8000-000000000002', current_tenant_id(), 'a4000000-0000-4000-8000-000000000002', 'OIL-1L', 'Engine Oil 1L', true);
INSERT INTO product_identifier_requirements (tenant_id, product_id, identifier_type_id, is_primary)
VALUES (current_tenant_id(), 'a4000000-0000-4000-8000-000000000001', 'a6000000-0000-4000-8000-000000000001', true);

-- two physical bikes received
INSERT INTO product_serials (id, tenant_id, variant_id, serial_no, status, warehouse_id, unit_cost, received_at) VALUES
  ('a7000000-0000-4000-8000-000000000001', current_tenant_id(), 'a5000000-0000-4000-8000-000000000001', 'CH0001', 'in_stock', 'a2000000-0000-4000-8000-000000000001', 150000, now()),
  ('a7000000-0000-4000-8000-000000000002', current_tenant_id(), 'a5000000-0000-4000-8000-000000000001', 'CH0002', 'in_stock', 'a2000000-0000-4000-8000-000000000001', 152000, now());
INSERT INTO product_serial_identifiers (tenant_id, serial_id, identifier_type_id, value) VALUES
  (current_tenant_id(), 'a7000000-0000-4000-8000-000000000001', 'a6000000-0000-4000-8000-000000000001', 'CH0001'),
  (current_tenant_id(), 'a7000000-0000-4000-8000-000000000002', 'a6000000-0000-4000-8000-000000000001', 'CH0002');
INSERT INTO stock_movements (tenant_id, movement_type, warehouse_id, variant_id, serial_id, quantity, unit_cost, source_doc_type, source_doc_id) VALUES
  (current_tenant_id(), 'opening', 'a2000000-0000-4000-8000-000000000001', 'a5000000-0000-4000-8000-000000000001', 'a7000000-0000-4000-8000-000000000001', 1, 150000, 'opening', gen_random_uuid()),
  (current_tenant_id(), 'opening', 'a2000000-0000-4000-8000-000000000001', 'a5000000-0000-4000-8000-000000000001', 'a7000000-0000-4000-8000-000000000002', 1, 152000, 'opening', gen_random_uuid()),
  (current_tenant_id(), 'opening', 'a2000000-0000-4000-8000-000000000001', 'a5000000-0000-4000-8000-000000000002', NULL, 10, 800, 'opening', gen_random_uuid());

INSERT INTO parties (id, tenant_id, party_code, party_kind, display_name, phone)
VALUES ('a8000000-0000-4000-8000-000000000001', current_tenant_id(), 'C-0001', 'individual', 'Mr. Customer', '+8801711000001');
INSERT INTO customers_dealers (id, tenant_id, party_id, credit_limit, credit_days)
VALUES ('a9000000-0000-4000-8000-000000000001', current_tenant_id(), 'a8000000-0000-4000-8000-000000000001', 500000, 30);
INSERT INTO document_number_formats (tenant_id, document_type, prefix, format)
VALUES (current_tenant_id(), 'invoice', 'INV', '{PREFIX}-{BR}-{FY}-{SEQ}');
COMMIT;

SELECT pg_temp.expect('bike balance after opening', qty_on_hand::numeric, 2.0000)
  FROM stock_balances WHERE variant_id = 'a5000000-0000-4000-8000-000000000001';
SELECT pg_temp.expect('bike avg cost', avg_unit_cost::numeric, 151000.0000)
  FROM stock_balances WHERE variant_id = 'a5000000-0000-4000-8000-000000000001';

-- -----------------------------------------------------------------------------
\echo '== 3. Plan limit: Starter allows 1 branch'
-- -----------------------------------------------------------------------------
BEGIN;
SET LOCAL ROLE dms_app;
SELECT set_config('app.current_tenant_id', 'a0000000-0000-4000-8000-000000000001', true) \g /dev/null
SELECT pg_temp.expect_error($$INSERT INTO branches (tenant_id, code, name) VALUES (current_tenant_id(), 'CTG01', 'Chattogram')$$, 'DL001');
-- deactivate-then-reactivate path is also guarded
INSERT INTO branches (tenant_id, code, name, is_active) VALUES (current_tenant_id(), 'CTG01', 'Chattogram', false);
SELECT pg_temp.expect_error($$UPDATE branches SET is_active = true WHERE code = 'CTG01'$$, 'DL001');
COMMIT;

-- -----------------------------------------------------------------------------
\echo '== 4. RLS isolation'
-- -----------------------------------------------------------------------------
BEGIN;
SET LOCAL ROLE dms_app;
-- no tenant context: fail closed
SELECT pg_temp.expect('rows visible without tenant context', (SELECT count(*) FROM branches), 0::bigint);
SELECT pg_temp.expect_error($$INSERT INTO units (tenant_id, code, name) VALUES ('a0000000-0000-4000-8000-000000000001', 'x', 'x')$$, '42501');
COMMIT;

BEGIN;
SET LOCAL ROLE dms_app;
SELECT set_config('app.current_tenant_id', 'b0000000-0000-4000-8000-000000000002', true),
       set_config('app.current_user_id',   '10000000-0000-4000-8000-000000000002', true) \g /dev/null
SELECT pg_temp.expect('tenant B sees A branches', (SELECT count(*) FROM branches), 0::bigint);
SELECT pg_temp.expect('tenant B sees A serials',  (SELECT count(*) FROM product_serials WHERE serial_no = 'CH0001'), 0::bigint);
SELECT pg_temp.expect('tenant B sees only itself', (SELECT array_agg(slug::text) FROM tenants), ARRAY['karim-fmcg']);
SELECT pg_temp.expect('tenant B sees A users', (SELECT count(*) FROM users WHERE email = 'owner@rahim.test'), 0::bigint);
-- writing a row tagged with another tenant is rejected by WITH CHECK
SELECT pg_temp.expect_error($$INSERT INTO units (tenant_id, code, name) VALUES ('a0000000-0000-4000-8000-000000000001', 'x', 'x')$$, '42501');
-- updating A's rows silently matches nothing
UPDATE customers_dealers SET credit_limit = 0 WHERE id = 'a9000000-0000-4000-8000-000000000001';
INSERT INTO branches (id, tenant_id, code, name) VALUES ('b1000000-0000-4000-8000-000000000001', current_tenant_id(), 'MAIN', 'Main Depot');
-- composite FK: B cannot point its warehouse at A's branch even if it knows the UUID
SELECT pg_temp.expect_error($$INSERT INTO warehouses (tenant_id, branch_id, code, name) VALUES (current_tenant_id(), 'a1000000-0000-4000-8000-000000000001', 'W', 'W')$$, '23503');
-- B cannot read the column-restricted password hash at all
SELECT pg_temp.expect_error($$SELECT password_hash FROM users$$, '42501');
COMMIT;
SELECT pg_temp.expect('A credit limit untouched by B', credit_limit::numeric, 500000.00)
  FROM customers_dealers WHERE id = 'a9000000-0000-4000-8000-000000000001';

-- -----------------------------------------------------------------------------
\echo '== 5. Post a serialized invoice (reference posting transaction)'
-- -----------------------------------------------------------------------------
BEGIN;
SET LOCAL ROLE dms_app;
SELECT set_config('app.current_tenant_id', 'a0000000-0000-4000-8000-000000000001', true),
       set_config('app.current_user_id',   '10000000-0000-4000-8000-000000000001', true),
       set_config('app.request_id', 'req-test-1', true) \g /dev/null
DO $$
DECLARE
  v_tenant  uuid := current_tenant_id();
  v_inv     uuid := 'aa000000-0000-4000-8000-000000000001';
  v_item    uuid := gen_random_uuid();
  v_wh      uuid := 'a2000000-0000-4000-8000-000000000001';
  v_serials uuid[] := ARRAY['a7000000-0000-4000-8000-000000000001']::uuid[];
  v_claimed int;
  v_cost    numeric;
  v_due     numeric;
  v_limit   numeric;
  v_total   numeric := 185000;
BEGIN
  -- draft
  INSERT INTO invoices (id, tenant_id, branch_id, warehouse_id, customer_id, bill_to_name, payment_mode, due_date, subtotal, grand_total)
  VALUES (v_inv, v_tenant, 'a1000000-0000-4000-8000-000000000001', v_wh, 'a9000000-0000-4000-8000-000000000001',
          'Mr. Customer', 'credit', tenant_today() + 30, v_total, v_total);
  INSERT INTO invoice_items (id, tenant_id, invoice_id, line_no, variant_id, unit_id, quantity, unit_price, taxable_amount, line_total)
  VALUES (v_item, v_tenant, v_inv, 1, 'a5000000-0000-4000-8000-000000000001', 'a3000000-0000-4000-8000-000000000001', 1, v_total, v_total, v_total);

  -- (1) credit check under a row lock on the customer
  SELECT current_due_balance, credit_limit INTO v_due, v_limit
    FROM customers_dealers WHERE id = 'a9000000-0000-4000-8000-000000000001' FOR UPDATE;
  IF v_due + v_total > v_limit THEN RAISE EXCEPTION 'CREDIT_LIMIT_EXCEEDED'; END IF;

  -- (2) claim the serials with a conditional update (row lock + re-check of status)
  WITH claimed AS (
    UPDATE product_serials
       SET status = 'sold', warehouse_id = NULL, sold_invoice_id = v_inv,
           sold_to_customer_id = 'a9000000-0000-4000-8000-000000000001', sold_at = now(),
           warranty_starts_on = tenant_today(), warranty_ends_on = tenant_today() + interval '24 months',
           version = version + 1
     WHERE tenant_id = v_tenant AND id = ANY (v_serials) AND status = 'in_stock' AND warehouse_id = v_wh
    RETURNING id, unit_cost)
  SELECT count(*), sum(unit_cost) INTO v_claimed, v_cost FROM claimed;
  IF v_claimed <> cardinality(v_serials) THEN
    RAISE EXCEPTION USING ERRCODE = 'DL070', MESSAGE = 'SERIAL_NOT_AVAILABLE';
  END IF;
  INSERT INTO invoice_item_serials (tenant_id, invoice_id, invoice_item_id, serial_id)
  SELECT v_tenant, v_inv, v_item, unnest(v_serials);

  -- (3) stock ledger (trigger locks + decrements the balance row)
  INSERT INTO stock_movements (tenant_id, movement_type, warehouse_id, variant_id, serial_id, quantity, unit_cost,
                               source_doc_type, source_doc_id, source_line_id, created_by)
  SELECT v_tenant, 'sale', v_wh, 'a5000000-0000-4000-8000-000000000001', s, -1,
         (SELECT unit_cost FROM product_serials WHERE id = s), 'invoice', v_inv, v_item, current_app_user_id()
    FROM unnest(v_serials) s;

  -- (4) party ledger (trigger updates current_due_balance)
  INSERT INTO payments_ledger (tenant_id, party_id, party_role, branch_id, entry_type, debit, source_doc_type, source_doc_id, description)
  VALUES (v_tenant, 'a8000000-0000-4000-8000-000000000001', 'customer', 'a1000000-0000-4000-8000-000000000001',
          'invoice', v_total, 'invoice', v_inv, 'Sale of 1 motorcycle');

  -- (5) gapless number LAST (shortest lock on the sequence row), then flip to posted
  UPDATE invoices
     SET invoice_no = next_document_number('invoice', branch_id, invoice_date),
         status = 'posted', posted_at = now(), posted_by = current_app_user_id(), cost_total = v_cost
   WHERE id = v_inv;
END $$;
COMMIT;

SELECT pg_temp.expect('invoice number', invoice_no::text,
       'INV-DHK01-' || right(fy::text, 2) || right((fy + 1)::text, 2) || '-000001')
  FROM invoices,
       LATERAL (SELECT CASE WHEN extract(month FROM invoice_date) >= 7 THEN extract(year FROM invoice_date)::int
                            ELSE extract(year FROM invoice_date)::int - 1 END AS fy) f
 WHERE id = 'aa000000-0000-4000-8000-000000000001';
SELECT pg_temp.expect('customer due after invoice', current_due_balance::numeric, 185000.00)
  FROM customers_dealers WHERE id = 'a9000000-0000-4000-8000-000000000001';
SELECT pg_temp.expect('bike stock after sale', qty_on_hand::numeric, 1.0000)
  FROM stock_balances WHERE variant_id = 'a5000000-0000-4000-8000-000000000001';
SELECT pg_temp.expect('monthly invoice usage', used, 1::bigint)
  FROM tenant_usage_counters WHERE tenant_id = 'a0000000-0000-4000-8000-000000000001' AND feature_key = 'max_monthly_invoices';

-- -----------------------------------------------------------------------------
\echo '== 6. Oversell protection'
-- -----------------------------------------------------------------------------
BEGIN;
SET LOCAL ROLE dms_app;
SELECT set_config('app.current_tenant_id', 'a0000000-0000-4000-8000-000000000001', true) \g /dev/null
-- conditional claim finds nothing: the chassis is already sold
WITH c AS (UPDATE product_serials SET status = 'sold'
             WHERE id = 'a7000000-0000-4000-8000-000000000001' AND status = 'in_stock' RETURNING 1)
SELECT pg_temp.expect('re-claim sold chassis rows', (SELECT count(*) FROM c), 0::bigint);
-- even if app code skipped the check, the partial unique index refuses a 2nd active sale
SELECT pg_temp.expect_error($$INSERT INTO invoice_item_serials (tenant_id, invoice_id, invoice_item_id, serial_id)
  SELECT tenant_id, invoice_id, id, 'a7000000-0000-4000-8000-000000000001' FROM invoice_items LIMIT 1$$, '23505');
-- the same chassis number can never be received twice
SELECT pg_temp.expect_error($$INSERT INTO product_serial_identifiers (tenant_id, serial_id, identifier_type_id, value)
  VALUES (current_tenant_id(), 'a7000000-0000-4000-8000-000000000002', 'a6000000-0000-4000-8000-000000000001', 'CH0001')$$, '23505');
-- non-serialized: 10 litres on hand, selling 11 violates stock_balances_non_negative
SELECT pg_temp.expect_error($$INSERT INTO stock_movements (tenant_id, movement_type, warehouse_id, variant_id, quantity, source_doc_type, source_doc_id)
  VALUES (current_tenant_id(), 'sale', 'a2000000-0000-4000-8000-000000000001', 'a5000000-0000-4000-8000-000000000002', -11, 'invoice', gen_random_uuid())$$, '23514');
COMMIT;

-- -----------------------------------------------------------------------------
\echo '== 7. Append-only ledgers & audit'
-- -----------------------------------------------------------------------------
BEGIN;
SET LOCAL ROLE dms_app;
SELECT set_config('app.current_tenant_id', 'a0000000-0000-4000-8000-000000000001', true) \g /dev/null
SELECT pg_temp.expect_error($$UPDATE stock_movements SET quantity = 5$$, '42501');
SELECT pg_temp.expect_error($$DELETE FROM payments_ledger$$, '42501');
SELECT pg_temp.expect_error($$INSERT INTO audit.audit_logs (action) VALUES ('X')$$, '42501');
SELECT pg_temp.expect('audit rows for the invoice',
  (SELECT count(*) > 0 FROM audit.audit_logs WHERE table_name = 'invoices' AND record_id = 'aa000000-0000-4000-8000-000000000001'), true);
SELECT pg_temp.expect('audit captured request id',
  (SELECT bool_and(request_id = 'req-test-1') FROM audit.audit_logs WHERE table_name = 'invoices'), true);
COMMIT;
-- even the owner cannot rewrite history (trigger, not just grants)
SELECT pg_temp.expect_error($$UPDATE stock_movements SET quantity = 5$$, 'DL010');
SELECT pg_temp.expect_error($$DELETE FROM audit.audit_logs$$, 'DL010');

BEGIN;
SET LOCAL ROLE dms_app;
SELECT set_config('app.current_tenant_id', 'b0000000-0000-4000-8000-000000000002', true) \g /dev/null
SELECT pg_temp.expect('tenant B sees A audit rows', (SELECT count(*) FROM audit.audit_logs WHERE tenant_id <> current_tenant_id()), 0::bigint);
COMMIT;

-- -----------------------------------------------------------------------------
\echo '== 8. Metered limit: monthly invoices'
-- -----------------------------------------------------------------------------
UPDATE tenant_feature_limits SET limit_value = 1, source = 'override', override_reason = 'test'
 WHERE tenant_id = 'a0000000-0000-4000-8000-000000000001' AND feature_key = 'max_monthly_invoices';
BEGIN;
SET LOCAL ROLE dms_app;
SELECT set_config('app.current_tenant_id', 'a0000000-0000-4000-8000-000000000001', true) \g /dev/null
SELECT pg_temp.expect_error($$INSERT INTO invoices (tenant_id, invoice_no, branch_id, customer_id, bill_to_name, status, posted_at)
  VALUES (current_tenant_id(), 'MANUAL-2', 'a1000000-0000-4000-8000-000000000001', 'a9000000-0000-4000-8000-000000000001', 'X', 'posted', now())$$, 'DL001');
COMMIT;

-- -----------------------------------------------------------------------------
\echo '== 9. Hierarchies (ltree) & subscription state machine'
-- -----------------------------------------------------------------------------
BEGIN;
SET LOCAL ROLE dms_app;
SELECT set_config('app.current_tenant_id', 'a0000000-0000-4000-8000-000000000001', true) \g /dev/null
INSERT INTO territories (id, tenant_id, parent_id, level_label, code, name) VALUES
  ('ab000000-0000-4000-8000-000000000001', current_tenant_id(), NULL, 'Zone', 'Z1', 'North'),
  ('ab000000-0000-4000-8000-000000000002', current_tenant_id(), 'ab000000-0000-4000-8000-000000000001', 'Region', 'R1', 'Rajshahi'),
  ('ab000000-0000-4000-8000-000000000003', current_tenant_id(), 'ab000000-0000-4000-8000-000000000002', 'Area', 'A1', 'Bogura');
SELECT pg_temp.expect('subtree size of North',
  (SELECT count(*) FROM territories t, territories z WHERE z.code = 'Z1' AND t.path <@ z.path), 3::bigint);
SELECT pg_temp.expect_error($$UPDATE territories SET parent_id = 'ab000000-0000-4000-8000-000000000003' WHERE code = 'Z1'$$, 'DL030');
-- move Area under a new zone: path of the subtree follows
INSERT INTO territories (id, tenant_id, level_label, code, name) VALUES ('ab000000-0000-4000-8000-000000000004', current_tenant_id(), 'Zone', 'Z2', 'South');
UPDATE territories SET parent_id = 'ab000000-0000-4000-8000-000000000004' WHERE code = 'R1';
SELECT pg_temp.expect('Area moved with its Region',
  (SELECT t.path <@ z.path FROM territories t, territories z WHERE t.code = 'A1' AND z.code = 'Z2'), true);
COMMIT;

SELECT pg_temp.expect_error($$SELECT transition_subscription('c0000000-0000-4000-8000-000000000001', 'suspended', 'test')$$, 'DL060');
SELECT transition_subscription('c0000000-0000-4000-8000-000000000001', 'past_due', 'trial_expired') \g /dev/null
SELECT transition_subscription('c0000000-0000-4000-8000-000000000001', 'suspended', 'grace_expired') \g /dev/null
SELECT pg_temp.expect('tenant suspended', status::text, 'suspended') FROM tenants WHERE id = 'a0000000-0000-4000-8000-000000000001';
SELECT transition_subscription('c0000000-0000-4000-8000-000000000001', 'active', 'bank_transfer_verified') \g /dev/null
SELECT pg_temp.expect('tenant reactivated', status::text, 'active') FROM tenants WHERE id = 'a0000000-0000-4000-8000-000000000001';
SELECT pg_temp.expect('status history rows', count(*), 3::bigint) FROM subscription_status_history;
-- the API role cannot drive billing state
BEGIN;
SET LOCAL ROLE dms_app;
SELECT pg_temp.expect_error($$SELECT transition_subscription('c0000000-0000-4000-8000-000000000001', 'active', 'hack')$$, '42501');
COMMIT;

\echo '== ALL SMOKE TESTS PASSED'

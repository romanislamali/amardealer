-- =============================================================================
-- AmarDealer DMS · 12 Security: grants, Row-Level Security, updated_at triggers,
-- and a self-check that fails the migration if any tenant table lacks RLS.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Standard tenant policy. FORCE makes RLS apply to the table owner as well, so the
-- only way past it is a role with BYPASSRLS (dms_owner / dms_auth / dms_platform).
-- The generated SQL for each table is exactly:
--   ALTER TABLE <t> ENABLE ROW LEVEL SECURITY;
--   ALTER TABLE <t> FORCE ROW LEVEL SECURITY;
--   CREATE POLICY tenant_isolation ON <t> AS PERMISSIVE FOR ALL TO dms_app, dms_worker
--     USING (tenant_id = current_tenant_id())
--     WITH CHECK (tenant_id = current_tenant_id());
-- current_tenant_id() returns NULL when app.current_tenant_id is unset, and
-- "tenant_id = NULL" is never true: a forgotten context returns zero rows and
-- every INSERT fails. The system fails closed.
-- -----------------------------------------------------------------------------
CREATE FUNCTION apply_tenant_rls(p_table regclass) RETURNS void
LANGUAGE plpgsql SET client_min_messages = warning AS
$$
BEGIN
  EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', p_table);
  EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY', p_table);
  EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON %s', p_table);
  EXECUTE format('CREATE POLICY tenant_isolation ON %s AS PERMISSIVE FOR ALL TO dms_app, dms_worker '
                 'USING (tenant_id = current_tenant_id()) WITH CHECK (tenant_id = current_tenant_id())', p_table);
END
$$;

SELECT apply_tenant_rls(t::regclass) FROM unnest(ARRAY[
  -- tenant self-service configuration
  'tenant_settings', 'tenant_payment_methods',
  -- organization & RBAC
  'territories', 'branches', 'warehouses', 'warehouse_locations',
  'roles', 'role_permissions', 'tenant_memberships', 'membership_roles',
  -- catalog
  'units', 'categories', 'brands', 'tax_rates', 'tax_groups', 'tax_group_rates',
  'products', 'product_uoms', 'product_variants', 'product_barcodes', 'product_bundle_items',
  'serial_identifier_types', 'product_identifier_requirements', 'product_batches',
  'product_serials', 'product_serial_identifiers', 'custom_field_definitions',
  'price_lists', 'price_list_items', 'promotions',
  -- parties & sales force
  'parties', 'party_addresses', 'customer_groups', 'sales_reps', 'sales_rep_territories', 'routes',
  'customers_dealers', 'route_customers', 'suppliers', 'sales_targets', 'sr_visits',
  -- sales
  'document_number_formats', 'document_sequences', 'approval_rules', 'approval_requests', 'vat_challans',
  'sales_orders', 'sales_order_items', 'invoices', 'invoice_items', 'invoice_item_serials',
  'deliveries', 'delivery_items', 'emi_plans', 'installment_schedules', 'installment_schedule_items',
  'sales_returns', 'sales_return_items', 'warranty_claims',
  -- procurement
  'purchase_orders', 'purchase_order_items', 'goods_received_notes', 'grn_items', 'purchase_landed_costs',
  'supplier_bills', 'purchase_returns', 'purchase_return_items',
  -- inventory
  'stock_balances', 'stock_movements', 'stock_transfers', 'stock_transfer_items',
  'stock_transfer_item_serials', 'stock_adjustments', 'stock_adjustment_items',
  -- money
  'financial_accounts', 'payments', 'payment_allocations', 'payments_ledger',
  -- services
  'attachments', 'sms_messages', 'outbox_events', 'api_keys', 'import_jobs'
]) AS t;

-- -----------------------------------------------------------------------------
-- Special-case policies (written out explicitly)
-- -----------------------------------------------------------------------------

-- tenants: a tenant sees and edits (whitelisted columns of) its own row only
ALTER TABLE tenants ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenants FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_self_select ON tenants FOR SELECT TO dms_app, dms_worker
  USING (id = current_tenant_id());
CREATE POLICY tenant_self_update ON tenants FOR UPDATE TO dms_app
  USING (id = current_tenant_id()) WITH CHECK (id = current_tenant_id());

-- users are global; inside a tenant you can see yourself and members of the current tenant
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE users FORCE ROW LEVEL SECURITY;
CREATE POLICY users_visible ON users FOR SELECT TO dms_app, dms_worker
  USING (id = current_app_user_id()
         OR EXISTS (SELECT 1 FROM tenant_memberships m
                     WHERE m.user_id = users.id AND m.tenant_id = current_tenant_id()));
CREATE POLICY users_self_update ON users FOR UPDATE TO dms_app
  USING (id = current_app_user_id()) WITH CHECK (id = current_app_user_id());

-- platform-managed rows the tenant may read but never write
ALTER TABLE tenant_feature_limits ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenant_feature_limits FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_read ON tenant_feature_limits FOR SELECT TO dms_app, dms_worker
  USING (tenant_id = current_tenant_id());

ALTER TABLE tenant_usage_counters ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenant_usage_counters FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_read ON tenant_usage_counters FOR SELECT TO dms_app, dms_worker
  USING (tenant_id = current_tenant_id());

ALTER TABLE subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscriptions FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_read ON subscriptions FOR SELECT TO dms_app, dms_worker
  USING (tenant_id = current_tenant_id());

ALTER TABLE subscription_status_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscription_status_history FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_read ON subscription_status_history FOR SELECT TO dms_app, dms_worker
  USING (tenant_id = current_tenant_id());

ALTER TABLE subscription_invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscription_invoices FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_read ON subscription_invoices FOR SELECT TO dms_app, dms_worker
  USING (tenant_id = current_tenant_id());

-- tenants can submit a bank-transfer proof / start a gateway payment, but only the
-- platform (dms_platform, BYPASSRLS) can mark it succeeded / rejected
ALTER TABLE subscription_payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscription_payments FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_read ON subscription_payments FOR SELECT TO dms_app
  USING (tenant_id = current_tenant_id());
CREATE POLICY tenant_submit ON subscription_payments FOR INSERT TO dms_app
  WITH CHECK (tenant_id = current_tenant_id()
              AND status IN ('initiated', 'pending_verification')
              AND verified_by IS NULL AND verified_at IS NULL);

-- platform default templates (tenant_id NULL) are readable by all; overrides are private
ALTER TABLE notification_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE notification_templates FORCE ROW LEVEL SECURITY;
CREATE POLICY templates_read ON notification_templates FOR SELECT TO dms_app, dms_worker
  USING (tenant_id IS NULL OR tenant_id = current_tenant_id());
CREATE POLICY templates_insert ON notification_templates FOR INSERT TO dms_app
  WITH CHECK (tenant_id = current_tenant_id());
CREATE POLICY templates_update ON notification_templates FOR UPDATE TO dms_app
  USING (tenant_id = current_tenant_id()) WITH CHECK (tenant_id = current_tenant_id());
CREATE POLICY templates_delete ON notification_templates FOR DELETE TO dms_app
  USING (tenant_id = current_tenant_id());

-- audit trail: tenants read their own history; writes only through SECURITY DEFINER functions
ALTER TABLE audit.audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit.audit_logs FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_read ON audit.audit_logs FOR SELECT TO dms_app
  USING (tenant_id = current_tenant_id());

-- -----------------------------------------------------------------------------
-- Grants
-- -----------------------------------------------------------------------------
GRANT USAGE ON SCHEMA public, audit TO dms_app, dms_worker, dms_auth, dms_platform;

-- dms_app / dms_worker: full DML on tenant tables (RLS does the scoping) ...
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO dms_app, dms_worker;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO dms_app, dms_worker;

-- ... minus global catalogs (read-only)
REVOKE INSERT, UPDATE, DELETE ON feature_catalog, industry_templates, geo_areas, permissions,
  plans, plan_prices, plan_features FROM dms_app, dms_worker;
-- ... minus platform-only tables
REVOKE ALL ON platform_admins, payment_gateway_events, backup_runs FROM dms_app, dms_worker;
-- ... minus platform-managed tenant rows (read-only)
REVOKE INSERT, UPDATE, DELETE ON tenants, tenant_feature_limits, tenant_usage_counters, subscriptions,
  subscription_status_history, subscription_invoices FROM dms_app, dms_worker;
REVOKE UPDATE, DELETE ON subscription_payments FROM dms_app, dms_worker;
GRANT UPDATE (legal_name, legal_name_bn, trade_name, business_model, industry_tags, bin, tin, trade_license_no,
              vat_registration_type, email, phone, website, address_line1, address_line2, geo_area_id,
              postal_code, default_locale, logo_file_key, updated_at)
  ON tenants TO dms_app;
-- ... users: never expose password hashes / MFA secrets to the API role
REVOKE ALL ON users FROM dms_app, dms_worker;
GRANT SELECT (id, email, phone, full_name, full_name_bn, avatar_file_key, preferred_locale, is_active,
              last_login_at, created_at, updated_at)
  ON users TO dms_app, dms_worker;
GRANT UPDATE (full_name, full_name_bn, avatar_file_key, preferred_locale, updated_at) ON users TO dms_app;
-- ... ledgers are append-only for everyone
REVOKE UPDATE, DELETE, TRUNCATE ON stock_movements, payments_ledger FROM dms_app, dms_worker;

-- audit: read own tenant's trail; write via functions only
GRANT SELECT ON audit.audit_logs TO dms_app, dms_platform;

-- dms_auth (identity service): login, signup, invite acceptance, workspace switcher, tenant resolver
GRANT SELECT, INSERT, UPDATE ON users TO dms_auth;
GRANT SELECT ON tenants, tenant_memberships, platform_admins, roles, membership_roles, role_permissions,
  permissions, subscriptions, branches TO dms_auth;
GRANT UPDATE (status, joined_at, last_active_at, updated_at) ON tenant_memberships TO dms_auth;

-- dms_platform (Super Admin portal, billing/dunning/backup workers)
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO dms_platform;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO dms_platform;
REVOKE UPDATE, DELETE, TRUNCATE ON stock_movements, payments_ledger FROM dms_platform;

-- Functions: PUBLIC gets EXECUTE by default; lock down the sensitive ones
REVOKE EXECUTE ON FUNCTION consume_usage(uuid, text, bigint) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION consume_usage(uuid, text, bigint) TO dms_app, dms_worker;
REVOKE EXECUTE ON FUNCTION transition_subscription(uuid, subscription_status, text, uuid, interval) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION transition_subscription(uuid, subscription_status, text, uuid, interval) TO dms_platform;
REVOKE EXECUTE ON FUNCTION sync_tenant_limits_from_plan(uuid, uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION sync_tenant_limits_from_plan(uuid, uuid) TO dms_platform;
REVOKE EXECUTE ON FUNCTION enforce_plan_limit() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION audit.log_row_change() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION audit.ensure_partition(date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION apply_tenant_rls(regclass) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION audit.log_event(text, text, uuid, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION audit.log_event(text, text, uuid, jsonb) TO dms_app, dms_worker, dms_auth, dms_platform;

-- -----------------------------------------------------------------------------
-- updated_at maintenance on every table that has the column
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT c.oid::regclass AS tbl
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'updated_at' AND NOT a.attisdropped
     WHERE n.nspname = 'public' AND c.relkind = 'r'
  LOOP
    EXECUTE format('CREATE TRIGGER trg_set_updated_at BEFORE UPDATE ON %s FOR EACH ROW EXECUTE FUNCTION set_updated_at()', r.tbl);
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- Self-check: abort the migration if any table carrying tenant_id is not protected.
-- Keep this at the end of every future migration too.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_missing text[];
BEGIN
  SELECT array_agg(c.oid::regclass::text ORDER BY 1) INTO v_missing
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
   WHERE n.nspname IN ('public', 'audit')
     AND c.relkind IN ('r', 'p')
     AND NOT c.relispartition
     AND c.relname NOT IN ('backup_runs')            -- platform-only, no app grants
     AND (NOT c.relrowsecurity OR NOT c.relforcerowsecurity
          OR NOT EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid = c.oid));
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'RLS self-check failed. Unprotected tenant tables: %', v_missing;
  END IF;
END $$;

-- =============================================================================
-- AmarDealer DMS · 11 Immutable audit trail
--   * Row-level triggers capture INSERT/UPDATE/DELETE on financial & stock tables
--     with before/after images and the request context (user, IP, request id).
--   * Business events (POST, VOID, LOGIN, EXPORT, IMPERSONATE) via audit.log_event().
--   * Append-only: UPDATE/DELETE/TRUNCATE blocked by trigger; app roles get SELECT only.
--   * Monthly range partitions -> cheap retention (detach + archive to cold storage).
-- =============================================================================

CREATE TABLE audit.audit_logs (
  id             uuid NOT NULL DEFAULT gen_random_uuid(),
  occurred_at    timestamptz NOT NULL DEFAULT now(),
  tenant_id      uuid,                                   -- NULL for platform-level events
  actor_user_id  uuid,
  actor_type     varchar(16) NOT NULL DEFAULT 'user'
                 CHECK (actor_type IN ('user', 'system', 'worker', 'platform_admin', 'api_key')),
  impersonator_user_id uuid,                             -- Super Admin acting "as" a tenant user
  action         varchar(32) NOT NULL,                   -- INSERT/UPDATE/DELETE or POST/VOID/LOGIN/EXPORT ...
  table_name     varchar(64),
  record_id      uuid,
  old_data       jsonb,
  new_data       jsonb,
  changed_fields text[],
  details        jsonb,
  request_id     varchar(64),
  client_ip      inet,
  user_agent     varchar(255),
  db_role        name NOT NULL DEFAULT session_user,
  txid           bigint NOT NULL DEFAULT txid_current(),
  PRIMARY KEY (occurred_at, id)
) PARTITION BY RANGE (occurred_at);

CREATE TABLE audit.audit_logs_default PARTITION OF audit.audit_logs DEFAULT;

CREATE INDEX ix_audit_tenant_time ON audit.audit_logs (tenant_id, occurred_at DESC);
CREATE INDEX ix_audit_record ON audit.audit_logs (tenant_id, table_name, record_id, occurred_at DESC);
CREATE INDEX ix_audit_actor ON audit.audit_logs (tenant_id, actor_user_id, occurred_at DESC);

-- Scheduler calls this monthly for (now + 1..3 months).
CREATE FUNCTION audit.ensure_partition(p_month date) RETURNS void
LANGUAGE plpgsql AS
$$
DECLARE
  v_from date := date_trunc('month', p_month)::date;
  v_to   date := (date_trunc('month', p_month) + interval '1 month')::date;
  v_name text := format('audit_logs_%s', to_char(v_from, 'YYYYMM'));
BEGIN
  IF to_regclass(format('audit.%I', v_name)) IS NULL THEN
    EXECUTE format('CREATE TABLE audit.%I PARTITION OF audit.audit_logs FOR VALUES FROM (%L) TO (%L)',
                   v_name, v_from, v_to);
  END IF;
END
$$;

SELECT audit.ensure_partition((date_trunc('month', now()) + make_interval(months => m))::date)
  FROM generate_series(-1, 3) AS m;

CREATE FUNCTION audit.log_row_change() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS
$$
DECLARE
  v_old     jsonb;
  v_new     jsonb;
  v_changed text[];
BEGIN
  IF TG_OP IN ('UPDATE', 'DELETE') THEN v_old := to_jsonb(OLD); END IF;
  IF TG_OP IN ('INSERT', 'UPDATE') THEN v_new := to_jsonb(NEW); END IF;

  IF TG_OP = 'UPDATE' THEN
    SELECT array_agg(n.key ORDER BY n.key) INTO v_changed
      FROM jsonb_each(v_new) AS n
     WHERE n.value IS DISTINCT FROM v_old -> n.key
       AND n.key NOT IN ('updated_at', 'version');
    IF v_changed IS NULL THEN
      RETURN NULL;   -- no-op update, nothing to audit
    END IF;
  END IF;

  INSERT INTO audit.audit_logs (tenant_id, actor_user_id, actor_type, impersonator_user_id, action, table_name,
                                record_id, old_data, new_data, changed_fields, request_id, client_ip)
  VALUES (
    COALESCE(v_new ->> 'tenant_id', v_old ->> 'tenant_id')::uuid,
    NULLIF(current_setting('app.current_user_id', true), '')::uuid,
    COALESCE(NULLIF(current_setting('app.actor_type', true), ''), 'user'),
    NULLIF(current_setting('app.impersonator_user_id', true), '')::uuid,
    TG_OP,
    TG_TABLE_NAME,
    (COALESCE(v_new ->> 'id', v_old ->> 'id'))::uuid,
    v_old,
    v_new,
    v_changed,
    NULLIF(current_setting('app.request_id', true), ''),
    NULLIF(current_setting('app.client_ip', true), '')::inet
  );
  RETURN NULL;
END
$$;

-- Business-level events. tenant_id is forced from the session, never taken from the caller.
CREATE FUNCTION audit.log_event(p_action text, p_entity_type text DEFAULT NULL, p_entity_id uuid DEFAULT NULL,
                                p_details jsonb DEFAULT NULL) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS
$$
  INSERT INTO audit.audit_logs (tenant_id, actor_user_id, actor_type, impersonator_user_id, action, table_name,
                                record_id, details, request_id, client_ip)
  VALUES (current_tenant_id(),
          current_app_user_id(),
          COALESCE(NULLIF(current_setting('app.actor_type', true), ''), 'user'),
          NULLIF(current_setting('app.impersonator_user_id', true), '')::uuid,
          upper(p_action), p_entity_type, p_entity_id, p_details,
          NULLIF(current_setting('app.request_id', true), ''),
          NULLIF(current_setting('app.client_ip', true), '')::inet);
$$;

CREATE TRIGGER trg_audit_logs_immutable BEFORE UPDATE OR DELETE ON audit.audit_logs
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();
CREATE TRIGGER trg_audit_logs_no_truncate BEFORE TRUNCATE ON audit.audit_logs
  FOR EACH STATEMENT EXECUTE FUNCTION forbid_mutation();

-- Attach row auditing to every financial, stock, pricing, credit and access-control table.
-- (stock_movements / payments_ledger are already append-only ledgers with created_by.)
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    -- access control & configuration
    'tenant_memberships', 'membership_roles', 'roles', 'role_permissions', 'tenant_settings',
    'tenant_feature_limits', 'subscriptions', 'subscription_payments', 'branches', 'warehouses',
    'document_number_formats', 'approval_requests', 'api_keys',
    -- pricing, tax & credit
    'products', 'product_variants', 'price_lists', 'price_list_items', 'promotions', 'tax_rates',
    'tax_group_rates', 'customers_dealers', 'suppliers', 'emi_plans',
    -- sales & receivables
    'sales_orders', 'invoices', 'invoice_items', 'invoice_item_serials', 'sales_returns', 'sales_return_items',
    'installment_schedules', 'installment_schedule_items', 'vat_challans', 'deliveries', 'warranty_claims',
    -- money
    'financial_accounts', 'payments', 'payment_allocations',
    -- procurement & stock
    'purchase_orders', 'goods_received_notes', 'grn_items', 'purchase_landed_costs', 'supplier_bills',
    'purchase_returns', 'purchase_return_items', 'product_serials', 'product_batches',
    'stock_transfers', 'stock_transfer_items', 'stock_adjustments', 'stock_adjustment_items'
  ]
  LOOP
    EXECUTE format('CREATE TRIGGER trg_audit AFTER INSERT OR UPDATE OR DELETE ON public.%I
                    FOR EACH ROW EXECUTE FUNCTION audit.log_row_change()', t);
  END LOOP;
END $$;

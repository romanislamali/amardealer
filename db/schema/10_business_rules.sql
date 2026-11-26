-- =============================================================================
-- AmarDealer DMS · 10 Business rules enforced inside PostgreSQL
--   * stock ledger -> balance projection (no oversell, moving average cost)
--   * party ledger -> cached due/payable balances
--   * append-only ledgers
--   * subscription plan limits (count limits + metered monthly usage)
--   * gapless document numbering (NBR requires sequential Mushak numbers)
--   * subscription state machine
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Stock: every movement row locks and updates exactly one balance row.
-- -----------------------------------------------------------------------------
CREATE FUNCTION apply_stock_movement() RETURNS trigger
LANGUAGE plpgsql AS
$$
DECLARE
  v_bal            stock_balances%ROWTYPE;
  v_allow_negative boolean;
  v_new_qty        numeric(18,4);
BEGIN
  SELECT allow_negative_stock INTO v_allow_negative
    FROM warehouses WHERE tenant_id = NEW.tenant_id AND id = NEW.warehouse_id;

  INSERT INTO stock_balances (tenant_id, warehouse_id, variant_id, batch_id, allow_negative)
  VALUES (NEW.tenant_id, NEW.warehouse_id, NEW.variant_id, NEW.batch_id, COALESCE(v_allow_negative, false))
  ON CONFLICT ON CONSTRAINT uq_stock_balances_key DO NOTHING;

  -- Row lock serializes concurrent movements of the same SKU/batch in the same warehouse.
  SELECT * INTO v_bal
    FROM stock_balances
   WHERE tenant_id = NEW.tenant_id
     AND warehouse_id = NEW.warehouse_id
     AND variant_id = NEW.variant_id
     AND batch_id IS NOT DISTINCT FROM NEW.batch_id
   FOR UPDATE;

  v_new_qty := v_bal.qty_on_hand + NEW.quantity;

  IF NEW.quantity < 0 THEN
    -- outbound: value at current moving average unless the caller passed a specific cost (serials)
    NEW.unit_cost := COALESCE(NEW.unit_cost, v_bal.avg_unit_cost);
    UPDATE stock_balances
       SET qty_on_hand = v_new_qty,                -- CHECK stock_balances_non_negative fires here
           last_movement_at = NEW.occurred_at,
           updated_at = now()
     WHERE id = v_bal.id;
  ELSE
    UPDATE stock_balances
       SET qty_on_hand = v_new_qty,
           avg_unit_cost = CASE
             WHEN NEW.unit_cost IS NULL THEN avg_unit_cost
             WHEN v_bal.qty_on_hand <= 0 THEN NEW.unit_cost
             ELSE round((v_bal.qty_on_hand * v_bal.avg_unit_cost + NEW.quantity * NEW.unit_cost)
                        / (v_bal.qty_on_hand + NEW.quantity), 4)
           END,
           last_movement_at = NEW.occurred_at,
           updated_at = now()
     WHERE id = v_bal.id;
  END IF;

  NEW.balance_after := v_new_qty;
  RETURN NEW;
END
$$;

CREATE TRIGGER trg_stock_movements_apply BEFORE INSERT ON stock_movements
  FOR EACH ROW EXECUTE FUNCTION apply_stock_movement();
CREATE TRIGGER trg_stock_movements_immutable BEFORE UPDATE OR DELETE ON stock_movements
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

-- -----------------------------------------------------------------------------
-- Party ledger -> cached balances (locks the customer/supplier row)
-- -----------------------------------------------------------------------------
CREATE FUNCTION apply_ledger_entry() RETURNS trigger
LANGUAGE plpgsql AS
$$
DECLARE
  v_balance numeric(15,2);
BEGIN
  IF NEW.party_role = 'customer' THEN
    UPDATE customers_dealers
       SET current_due_balance = current_due_balance + NEW.debit - NEW.credit,
           last_invoice_at = CASE WHEN NEW.entry_type = 'invoice' THEN now() ELSE last_invoice_at END,
           last_payment_at = CASE WHEN NEW.entry_type = 'receipt' THEN now() ELSE last_payment_at END,
           version = version + 1,
           updated_at = now()
     WHERE tenant_id = NEW.tenant_id AND party_id = NEW.party_id
    RETURNING current_due_balance INTO v_balance;
  ELSE
    UPDATE suppliers
       SET current_payable_balance = current_payable_balance + NEW.credit - NEW.debit,
           version = version + 1,
           updated_at = now()
     WHERE tenant_id = NEW.tenant_id AND party_id = NEW.party_id
    RETURNING current_payable_balance INTO v_balance;
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'DL050',
      MESSAGE = format('Party %s has no %s profile in this tenant', NEW.party_id, NEW.party_role);
  END IF;

  NEW.balance_after := v_balance;
  RETURN NEW;
END
$$;

CREATE TRIGGER trg_payments_ledger_apply BEFORE INSERT ON payments_ledger
  FOR EACH ROW EXECUTE FUNCTION apply_ledger_entry();
CREATE TRIGGER trg_payments_ledger_immutable BEFORE UPDATE OR DELETE ON payments_ledger
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

-- -----------------------------------------------------------------------------
-- Plan limits on countable resources (branches, warehouses, users, SKUs, SRs).
-- AFTER trigger so the new row is included in the count. The FOR UPDATE on the
-- tenant's limit row serializes concurrent creations for that tenant, so two
-- simultaneous "create branch" requests cannot both squeeze under the limit.
-- SECURITY DEFINER: counts with the owner's rights (no RLS) and reads limits the
-- app role may not update.
--   TG_ARGV[0] = feature key, TG_ARGV[1] = SQL predicate for "counts toward the limit"
-- -----------------------------------------------------------------------------
CREATE FUNCTION enforce_plan_limit() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS
$$
DECLARE
  v_key     text := TG_ARGV[0];
  v_pred    text := COALESCE(TG_ARGV[1], 'true');
  v_limit   bigint;
  v_enabled boolean;
  v_count   bigint;
BEGIN
  SELECT limit_value, is_enabled INTO v_limit, v_enabled
    FROM tenant_feature_limits
   WHERE tenant_id = NEW.tenant_id AND feature_key = v_key
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'DL003', MESSAGE = format('LIMIT_NOT_CONFIGURED:%s', v_key);
  END IF;
  IF NOT v_enabled THEN
    RAISE EXCEPTION USING ERRCODE = 'DL002', MESSAGE = format('FEATURE_DISABLED:%s', v_key);
  END IF;
  IF v_limit IS NULL THEN
    RETURN NULL;   -- unlimited
  END IF;

  EXECUTE format('SELECT count(*) FROM %I.%I WHERE tenant_id = $1 AND (%s)', TG_TABLE_SCHEMA, TG_TABLE_NAME, v_pred)
     INTO v_count USING NEW.tenant_id;

  IF v_count > v_limit THEN
    RAISE EXCEPTION USING ERRCODE = 'DL001',
      MESSAGE = format('PLAN_LIMIT_REACHED:%s', v_key),
      DETAIL  = format('limit=%s current=%s', v_limit, v_count - 1),
      HINT    = 'Upgrade the subscription plan or deactivate an existing record.';
  END IF;
  RETURN NULL;
END
$$;

CREATE TRIGGER trg_limit_branches_ins AFTER INSERT ON branches
  FOR EACH ROW WHEN (NEW.is_active) EXECUTE FUNCTION enforce_plan_limit('max_branches', 'is_active');
CREATE TRIGGER trg_limit_branches_upd AFTER UPDATE OF is_active ON branches
  FOR EACH ROW WHEN (NEW.is_active AND NOT OLD.is_active) EXECUTE FUNCTION enforce_plan_limit('max_branches', 'is_active');

CREATE TRIGGER trg_limit_warehouses_ins AFTER INSERT ON warehouses
  FOR EACH ROW WHEN (NEW.is_active) EXECUTE FUNCTION enforce_plan_limit('max_warehouses', 'is_active');
CREATE TRIGGER trg_limit_warehouses_upd AFTER UPDATE OF is_active ON warehouses
  FOR EACH ROW WHEN (NEW.is_active AND NOT OLD.is_active) EXECUTE FUNCTION enforce_plan_limit('max_warehouses', 'is_active');

-- invited users count too, otherwise a tenant could invite unlimited users and activate later
CREATE TRIGGER trg_limit_users_ins AFTER INSERT ON tenant_memberships
  FOR EACH ROW WHEN (NEW.status <> 'disabled') EXECUTE FUNCTION enforce_plan_limit('max_users', $$status <> 'disabled'$$);
CREATE TRIGGER trg_limit_users_upd AFTER UPDATE OF status ON tenant_memberships
  FOR EACH ROW WHEN (NEW.status <> 'disabled' AND OLD.status = 'disabled')
  EXECUTE FUNCTION enforce_plan_limit('max_users', $$status <> 'disabled'$$);

CREATE TRIGGER trg_limit_variants_ins AFTER INSERT ON product_variants
  FOR EACH ROW WHEN (NEW.is_active) EXECUTE FUNCTION enforce_plan_limit('max_skus', 'is_active');
CREATE TRIGGER trg_limit_variants_upd AFTER UPDATE OF is_active ON product_variants
  FOR EACH ROW WHEN (NEW.is_active AND NOT OLD.is_active) EXECUTE FUNCTION enforce_plan_limit('max_skus', 'is_active');

CREATE TRIGGER trg_limit_sales_reps_ins AFTER INSERT ON sales_reps
  FOR EACH ROW WHEN (NEW.is_active) EXECUTE FUNCTION enforce_plan_limit('max_sales_reps', 'is_active');
CREATE TRIGGER trg_limit_sales_reps_upd AFTER UPDATE OF is_active ON sales_reps
  FOR EACH ROW WHEN (NEW.is_active AND NOT OLD.is_active) EXECUTE FUNCTION enforce_plan_limit('max_sales_reps', 'is_active');

-- -----------------------------------------------------------------------------
-- Metered usage (monthly invoices, SMS). The upsert row-locks the counter, so
-- increments are atomic; exceeding the limit raises and rolls the increment back.
-- -----------------------------------------------------------------------------
CREATE FUNCTION consume_usage(p_tenant_id uuid, p_feature_key text, p_amount bigint DEFAULT 1) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS
$$
DECLARE
  v_limit   bigint;
  v_enabled boolean;
  v_reset   text;
  v_tz      text;
  v_period  date;
  v_used    bigint;
BEGIN
  IF p_tenant_id IS DISTINCT FROM current_tenant_id() THEN
    RAISE EXCEPTION USING ERRCODE = 'DL020', MESSAGE = 'consume_usage called outside the tenant context';
  END IF;

  SELECT l.limit_value, l.is_enabled, f.reset_period INTO v_limit, v_enabled, v_reset
    FROM tenant_feature_limits l
    JOIN feature_catalog f ON f.feature_key = l.feature_key
   WHERE l.tenant_id = p_tenant_id AND l.feature_key = p_feature_key;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'DL003', MESSAGE = format('LIMIT_NOT_CONFIGURED:%s', p_feature_key);
  END IF;
  IF NOT v_enabled THEN
    RAISE EXCEPTION USING ERRCODE = 'DL002', MESSAGE = format('FEATURE_DISABLED:%s', p_feature_key);
  END IF;

  SELECT timezone INTO v_tz FROM tenants WHERE id = p_tenant_id;
  v_period := CASE WHEN v_reset = 'monthly'
                   THEN date_trunc('month', now() AT TIME ZONE v_tz)::date
                   ELSE DATE '1970-01-01' END;

  INSERT INTO tenant_usage_counters (tenant_id, feature_key, period_start, used)
  VALUES (p_tenant_id, p_feature_key, v_period, p_amount)
  ON CONFLICT (tenant_id, feature_key, period_start)
  DO UPDATE SET used = tenant_usage_counters.used + EXCLUDED.used, updated_at = now()
  RETURNING used INTO v_used;

  IF v_limit IS NOT NULL AND v_used > v_limit THEN
    RAISE EXCEPTION USING ERRCODE = 'DL001',
      MESSAGE = format('PLAN_LIMIT_REACHED:%s', p_feature_key),
      DETAIL  = format('limit=%s used=%s period=%s', v_limit, v_used - p_amount, v_period);
  END IF;
  RETURN v_used;
END
$$;

CREATE FUNCTION count_posted_invoice_usage() RETURNS trigger
LANGUAGE plpgsql AS
$$ BEGIN PERFORM consume_usage(NEW.tenant_id, 'max_monthly_invoices', 1); RETURN NULL; END $$;

CREATE TRIGGER trg_invoices_usage_ins AFTER INSERT ON invoices
  FOR EACH ROW WHEN (NEW.status = 'posted') EXECUTE FUNCTION count_posted_invoice_usage();
CREATE TRIGGER trg_invoices_usage_post AFTER UPDATE OF status ON invoices
  FOR EACH ROW WHEN (NEW.status = 'posted' AND OLD.status <> 'posted') EXECUTE FUNCTION count_posted_invoice_usage();

-- Copy plan features into tenant_feature_limits; keeps live overrides, resets expired ones.
CREATE FUNCTION sync_tenant_limits_from_plan(p_tenant_id uuid, p_plan_id uuid) RETURNS void
LANGUAGE sql AS
$$
  INSERT INTO tenant_feature_limits (tenant_id, feature_key, limit_value, is_enabled, source)
  SELECT p_tenant_id, pf.feature_key, pf.limit_value, pf.is_enabled, 'plan'
    FROM plan_features pf
   WHERE pf.plan_id = p_plan_id
  ON CONFLICT (tenant_id, feature_key) DO UPDATE
     SET limit_value = EXCLUDED.limit_value,
         is_enabled = EXCLUDED.is_enabled,
         source = 'plan',
         override_reason = NULL,
         expires_at = NULL,
         updated_at = now()
   WHERE tenant_feature_limits.source = 'plan'
      OR tenant_feature_limits.expires_at < now();
$$;

-- -----------------------------------------------------------------------------
-- Gapless document numbers. The upsert holds a row lock on the sequence row until
-- COMMIT; a ROLLBACK returns the number, so posted documents never skip a number.
-- Call it as the LAST step of a posting transaction to keep the lock short.
-- -----------------------------------------------------------------------------
CREATE FUNCTION next_document_number(p_document_type text, p_branch_id uuid DEFAULT NULL, p_doc_date date DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql AS
$$
DECLARE
  v_tenant      uuid := current_tenant_id();
  v_date        date := COALESCE(p_doc_date, tenant_today());
  f             document_number_formats%ROWTYPE;
  v_fy_month    smallint;
  v_fy_start    integer;
  v_period      text;
  v_seq_branch  uuid;
  v_next        bigint;
  v_branch_code text := '';
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'DL020', MESSAGE = 'TENANT_CONTEXT_MISSING';
  END IF;

  SELECT * INTO f
    FROM document_number_formats
   WHERE tenant_id = v_tenant AND document_type = p_document_type AND is_active
     AND (branch_id = p_branch_id OR branch_id IS NULL)
   ORDER BY branch_id NULLS LAST
   LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'DL040', MESSAGE = format('NUMBERING_NOT_CONFIGURED:%s', p_document_type);
  END IF;

  SELECT fiscal_year_start_month INTO v_fy_month FROM tenants WHERE id = v_tenant;
  v_fy_start := CASE WHEN extract(month FROM v_date) >= v_fy_month
                     THEN extract(year FROM v_date)::int ELSE extract(year FROM v_date)::int - 1 END;

  v_period := CASE f.reset_period
                WHEN 'never'         THEN 'all'
                WHEN 'monthly'       THEN to_char(v_date, 'YYYY-MM')
                WHEN 'calendar_year' THEN to_char(v_date, 'YYYY')
                WHEN 'fiscal_year'   THEN v_fy_start || '-' || (v_fy_start + 1)
              END;

  v_seq_branch := CASE WHEN f.sequence_scope = 'branch' THEN p_branch_id END;
  IF f.sequence_scope = 'branch' AND p_branch_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'DL040', MESSAGE = format('BRANCH_REQUIRED_FOR_NUMBERING:%s', p_document_type);
  END IF;

  INSERT INTO document_sequences (tenant_id, format_id, branch_id, period_key, last_number)
  VALUES (v_tenant, f.id, v_seq_branch, v_period, f.start_number)
  ON CONFLICT ON CONSTRAINT uq_document_sequences
  DO UPDATE SET last_number = document_sequences.last_number + 1, updated_at = now()
  RETURNING last_number INTO v_next;

  IF p_branch_id IS NOT NULL THEN
    SELECT code INTO v_branch_code FROM branches WHERE tenant_id = v_tenant AND id = p_branch_id;
  END IF;

  RETURN replace(replace(replace(replace(replace(replace(replace(f.format,
           '{PREFIX}', f.prefix),
           '{BR}',     COALESCE(v_branch_code, '')),
           '{YYYY}',   to_char(v_date, 'YYYY')),
           '{YY}',     to_char(v_date, 'YY')),
           '{MM}',     to_char(v_date, 'MM')),
           '{FY}',     right(v_fy_start::text, 2) || right((v_fy_start + 1)::text, 2)),
           '{SEQ}',    lpad(v_next::text, f.padding, '0'));
END
$$;

-- -----------------------------------------------------------------------------
-- Subscription state machine (called by billing worker / Super Admin as dms_platform)
--   trialing  -> active | past_due | cancelled
--   active    -> past_due | cancelled
--   past_due  -> active | suspended | cancelled        (grace period, full access + banner)
--   suspended -> active | cancelled | expired          (login to billing page only)
--   cancelled -> expired                               (read-only until export window ends)
-- -----------------------------------------------------------------------------
CREATE FUNCTION transition_subscription(
  p_subscription_id uuid,
  p_to              subscription_status,
  p_reason          text,
  p_actor_user_id   uuid DEFAULT NULL,
  p_grace           interval DEFAULT interval '7 days'
) RETURNS void
LANGUAGE plpgsql AS
$$
DECLARE
  v_sub subscriptions%ROWTYPE;
BEGIN
  SELECT * INTO v_sub FROM subscriptions WHERE id = p_subscription_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Subscription % not found', p_subscription_id;
  END IF;
  IF v_sub.status = p_to THEN
    RETURN;
  END IF;

  IF NOT (v_sub.status::text || '>' || p_to::text) = ANY (ARRAY[
      'trialing>active', 'trialing>past_due', 'trialing>cancelled',
      'active>past_due', 'active>cancelled',
      'past_due>active', 'past_due>suspended', 'past_due>cancelled',
      'suspended>active', 'suspended>cancelled', 'suspended>expired',
      'cancelled>expired']) THEN
    RAISE EXCEPTION USING ERRCODE = 'DL060',
      MESSAGE = format('ILLEGAL_SUBSCRIPTION_TRANSITION:%s->%s', v_sub.status, p_to);
  END IF;

  UPDATE subscriptions
     SET status = p_to,
         grace_period_ends_at = CASE WHEN p_to = 'past_due' THEN now() + p_grace
                                     WHEN p_to = 'active' THEN NULL
                                     ELSE grace_period_ends_at END,
         suspended_at = CASE WHEN p_to = 'suspended' THEN now() WHEN p_to = 'active' THEN NULL ELSE suspended_at END,
         cancelled_at = CASE WHEN p_to = 'cancelled' THEN now() ELSE cancelled_at END,
         updated_at = now()
   WHERE id = p_subscription_id;

  INSERT INTO subscription_status_history (tenant_id, subscription_id, from_status, to_status, reason, actor_user_id)
  VALUES (v_sub.tenant_id, v_sub.id, v_sub.status, p_to, p_reason, p_actor_user_id);

  UPDATE tenants
     SET status = CASE p_to
                    WHEN 'active'    THEN 'active'
                    WHEN 'trialing'  THEN 'active'
                    WHEN 'past_due'  THEN 'active'
                    WHEN 'suspended' THEN 'suspended'
                    WHEN 'cancelled' THEN 'read_only'
                    WHEN 'expired'   THEN 'closed'
                  END::tenant_status,
         status_reason = p_reason,
         suspended_at = CASE WHEN p_to = 'suspended' THEN now() WHEN p_to = 'active' THEN NULL ELSE suspended_at END,
         closed_at = CASE WHEN p_to = 'expired' THEN now() ELSE closed_at END,
         updated_at = now()
   WHERE id = v_sub.tenant_id;

  -- the API caches tenant status in Redis; the outbox relay invalidates it
  INSERT INTO outbox_events (tenant_id, event_type, aggregate_type, aggregate_id, payload)
  VALUES (v_sub.tenant_id, 'subscription.status_changed', 'subscription', v_sub.id,
          jsonb_build_object('from', v_sub.status, 'to', p_to, 'reason', p_reason));
END
$$;

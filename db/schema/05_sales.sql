-- =============================================================================
-- AmarDealer DMS · 05 Sales: numbering, approvals, NBR VAT challans, orders,
-- invoices (cash / credit / installment / mixed), deliveries, EMI, returns, warranty
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Gapless, per-tenant (optionally per-branch) document numbering.
-- format tokens: {PREFIX} {BR} {YYYY} {YY} {MM} {FY} {SEQ}
--   'INV-{BR}-{FY}-{SEQ}'  ->  INV-DHK01-2526-000123   (FY 2025-26, BD fiscal year)
-- -----------------------------------------------------------------------------
CREATE TABLE document_number_formats (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid NOT NULL REFERENCES tenants(id),
  document_type  varchar(32) NOT NULL
                 CHECK (document_type IN ('quotation', 'sales_order', 'invoice', 'delivery', 'sales_return',
                                          'payment_receipt', 'payment_voucher', 'purchase_order', 'grn',
                                          'supplier_bill', 'purchase_return', 'stock_transfer', 'stock_adjustment',
                                          'installment_schedule', 'warranty_claim', 'customer', 'supplier', 'product',
                                          'mushak_6_3', 'mushak_6_5', 'mushak_6_6', 'mushak_6_7', 'mushak_6_8')),
  branch_id      uuid,                       -- NULL = tenant-wide default; a branch row overrides it
  prefix         varchar(20) NOT NULL DEFAULT '',
  format         varchar(80) NOT NULL DEFAULT '{PREFIX}-{FY}-{SEQ}',
  padding        smallint NOT NULL DEFAULT 6 CHECK (padding BETWEEN 1 AND 12),
  reset_period   varchar(16) NOT NULL DEFAULT 'fiscal_year'
                 CHECK (reset_period IN ('never', 'fiscal_year', 'calendar_year', 'monthly')),
  sequence_scope varchar(8) NOT NULL DEFAULT 'branch' CHECK (sequence_scope IN ('tenant', 'branch')),
  start_number   bigint NOT NULL DEFAULT 1 CHECK (start_number > 0),
  is_active      boolean NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE NULLS NOT DISTINCT (tenant_id, document_type, branch_id),
  FOREIGN KEY (tenant_id, branch_id) REFERENCES branches (tenant_id, id),
  CHECK (format LIKE '%{SEQ}%')
);

CREATE TABLE document_sequences (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES tenants(id),
  format_id   uuid NOT NULL,
  branch_id   uuid,
  period_key  varchar(16) NOT NULL,          -- 'all' | '2025-2026' | '2026' | '2026-11'
  last_number bigint NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_document_sequences UNIQUE NULLS NOT DISTINCT (tenant_id, format_id, branch_id, period_key),
  FOREIGN KEY (tenant_id, format_id) REFERENCES document_number_formats (tenant_id, id),
  FOREIGN KEY (tenant_id, branch_id) REFERENCES branches (tenant_id, id)
);

-- -----------------------------------------------------------------------------
-- Configurable approvals (credit-limit override, discount above X%, price below
-- min_price, stock adjustment, PO above amount, invoice void ...)
-- -----------------------------------------------------------------------------
CREATE TABLE approval_rules (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL REFERENCES tenants(id),
  name             varchar(120) NOT NULL,
  document_type    varchar(32) NOT NULL,       -- sales_order, invoice, purchase_order, stock_adjustment ...
  trigger_event    varchar(32) NOT NULL
                   CHECK (trigger_event IN ('credit_limit_exceeded', 'overdue_exists', 'discount_exceeded',
                                            'below_min_price', 'amount_exceeds', 'void', 'always')),
  condition        jsonb NOT NULL DEFAULT '{}'::jsonb,   -- {"discount_pct_gt": 10} / {"amount_gt": 500000}
  approval_level   smallint NOT NULL DEFAULT 1,
  approver_role_id uuid NOT NULL,
  branch_id        uuid,
  is_active        boolean NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, approver_role_id) REFERENCES roles (tenant_id, id),
  FOREIGN KEY (tenant_id, branch_id)        REFERENCES branches (tenant_id, id)
);

CREATE TABLE approval_requests (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid NOT NULL REFERENCES tenants(id),
  rule_id        uuid,
  document_type  varchar(32) NOT NULL,
  document_id    uuid NOT NULL,
  approval_level smallint NOT NULL DEFAULT 1,
  status         varchar(12) NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'approved', 'rejected', 'cancelled', 'expired')),
  reason         text,                         -- why approval was needed (system generated)
  snapshot       jsonb NOT NULL DEFAULT '{}'::jsonb,   -- values at request time (due, limit, discount)
  requested_by   uuid NOT NULL REFERENCES users(id),
  requested_at   timestamptz NOT NULL DEFAULT now(),
  decided_by     uuid REFERENCES users(id),
  decided_at     timestamptz,
  decision_note  text,
  expires_at     timestamptz,
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, rule_id) REFERENCES approval_rules (tenant_id, id),
  CHECK (status = 'pending' OR status = 'expired' OR status = 'cancelled' OR decided_by IS NOT NULL)
);
CREATE INDEX ix_approval_requests_pending ON approval_requests (tenant_id, status, requested_at) WHERE status = 'pending';
CREATE INDEX ix_approval_requests_doc ON approval_requests (tenant_id, document_type, document_id);

-- -----------------------------------------------------------------------------
-- NBR VAT documents (VAT & SD Act 2012 / Rules 2016)
--   6.3 tax invoice · 6.5 inter-branch transfer challan · 6.6 VDS certificate
--   6.7 credit note · 6.8 debit note
-- Snapshots seller/buyer data so the challan stays valid if master data changes.
-- Sales/purchase registers (6.1/6.2) and the monthly return (9.1) are reports over these rows.
-- -----------------------------------------------------------------------------
CREATE TABLE vat_challans (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id            uuid NOT NULL REFERENCES tenants(id),
  branch_id            uuid NOT NULL,
  challan_type         varchar(4) NOT NULL CHECK (challan_type IN ('6.3', '6.5', '6.6', '6.7', '6.8')),
  challan_no           varchar(40) NOT NULL,
  issued_at            timestamptz NOT NULL DEFAULT now(),
  source_document_type varchar(32) NOT NULL,    -- invoice, stock_transfer, sales_return, payment ...
  source_document_id   uuid NOT NULL,
  original_challan_id  uuid,                    -- 6.7/6.8 reference the original 6.3
  seller_name          varchar(200) NOT NULL,
  seller_bin           bin_t,
  seller_address       text,
  buyer_name           varchar(200),
  buyer_bin            bin_t,
  buyer_address        text,
  delivery_address     text,
  vehicle_no           varchar(30),
  total_value          amount_t NOT NULL DEFAULT 0,   -- value excluding taxes
  total_sd             amount_t NOT NULL DEFAULT 0,
  total_vat            amount_t NOT NULL DEFAULT 0,
  total_amount         amount_t NOT NULL DEFAULT 0,
  status               varchar(10) NOT NULL DEFAULT 'issued' CHECK (status IN ('issued', 'cancelled')),
  cancelled_at         timestamptz,
  cancel_reason        text,
  pdf_file_key         text,
  created_by           uuid REFERENCES users(id),
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, challan_type, challan_no),
  FOREIGN KEY (tenant_id, branch_id)           REFERENCES branches (tenant_id, id),
  FOREIGN KEY (tenant_id, original_challan_id) REFERENCES vat_challans (tenant_id, id),
  CHECK (challan_type NOT IN ('6.7', '6.8') OR original_challan_id IS NOT NULL),
  CHECK (status <> 'cancelled' OR cancel_reason IS NOT NULL)
);
CREATE INDEX ix_vat_challans_register ON vat_challans (tenant_id, branch_id, challan_type, issued_at);
CREATE INDEX ix_vat_challans_source ON vat_challans (tenant_id, source_document_type, source_document_id);

-- -----------------------------------------------------------------------------
-- Sales orders & quotations (back office, SR mobile app, B2B portal, e-commerce)
-- -----------------------------------------------------------------------------
CREATE TABLE sales_orders (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id              uuid NOT NULL REFERENCES tenants(id),
  order_no               varchar(40),
  order_type             varchar(12) NOT NULL DEFAULT 'sales_order' CHECK (order_type IN ('quotation', 'sales_order')),
  branch_id              uuid NOT NULL,
  warehouse_id           uuid,
  customer_id            uuid NOT NULL,
  sales_rep_id           uuid,
  price_list_id          uuid,
  order_date             date NOT NULL DEFAULT tenant_today(),
  expected_delivery_date date,
  valid_until            date,
  source_channel         varchar(16) NOT NULL DEFAULT 'back_office'
                         CHECK (source_channel IN ('back_office', 'sr_app', 'pos', 'b2b_portal', 'phone',
                                                   'ecommerce', 'api')),
  status                 varchar(20) NOT NULL DEFAULT 'draft'
                         CHECK (status IN ('draft', 'submitted', 'pending_approval', 'approved',
                                           'partially_invoiced', 'invoiced', 'cancelled', 'rejected', 'expired')),
  currency               currency_t NOT NULL DEFAULT 'BDT',
  exchange_rate          fx_rate_t NOT NULL DEFAULT 1,
  subtotal               amount_t NOT NULL DEFAULT 0,
  discount_total         amount_t NOT NULL DEFAULT 0,
  tax_total              amount_t NOT NULL DEFAULT 0,
  grand_total            amount_t NOT NULL DEFAULT 0,
  shipping_address_id    uuid,
  approval_request_id    uuid,
  notes                  text,
  custom_fields          jsonb NOT NULL DEFAULT '{}'::jsonb,
  client_ref             uuid,                        -- offline SR app idempotency
  cancel_reason          text,
  created_by             uuid REFERENCES users(id),
  approved_by            uuid REFERENCES users(id),
  approved_at            timestamptz,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, order_no),
  UNIQUE (tenant_id, client_ref),
  FOREIGN KEY (tenant_id, branch_id)           REFERENCES branches (tenant_id, id),
  FOREIGN KEY (tenant_id, warehouse_id)        REFERENCES warehouses (tenant_id, id),
  FOREIGN KEY (tenant_id, customer_id)         REFERENCES customers_dealers (tenant_id, id),
  FOREIGN KEY (tenant_id, sales_rep_id)        REFERENCES sales_reps (tenant_id, id),
  FOREIGN KEY (tenant_id, price_list_id)       REFERENCES price_lists (tenant_id, id),
  FOREIGN KEY (tenant_id, shipping_address_id) REFERENCES party_addresses (tenant_id, id),
  FOREIGN KEY (tenant_id, approval_request_id) REFERENCES approval_requests (tenant_id, id),
  CHECK (status = 'draft' OR order_no IS NOT NULL)
);
CREATE INDEX ix_sales_orders_date ON sales_orders (tenant_id, order_date DESC);
CREATE INDEX ix_sales_orders_customer ON sales_orders (tenant_id, customer_id, order_date DESC);
CREATE INDEX ix_sales_orders_sr ON sales_orders (tenant_id, sales_rep_id, order_date DESC);
CREATE INDEX ix_sales_orders_open ON sales_orders (tenant_id, branch_id, status)
  WHERE status IN ('submitted', 'pending_approval', 'approved', 'partially_invoiced');

CREATE TABLE sales_order_items (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenants(id),
  sales_order_id    uuid NOT NULL,
  line_no           smallint NOT NULL,
  variant_id        uuid NOT NULL,
  description       varchar(255),
  unit_id           uuid NOT NULL,
  uom_factor        numeric(18,6) NOT NULL DEFAULT 1 CHECK (uom_factor > 0),
  quantity          qty_t NOT NULL CHECK (quantity > 0),
  free_quantity     qty_t NOT NULL DEFAULT 0 CHECK (free_quantity >= 0),   -- scheme bonus
  base_quantity     numeric(18,4) GENERATED ALWAYS AS (round((quantity + free_quantity) * uom_factor, 4)) STORED,
  unit_price        price_t NOT NULL CHECK (unit_price >= 0),
  discount_pct      pct_t NOT NULL DEFAULT 0,
  discount_amount   amount_t NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
  tax_group_id      uuid,
  tax_amount        amount_t NOT NULL DEFAULT 0,
  line_total        amount_t NOT NULL,
  invoiced_quantity qty_t NOT NULL DEFAULT 0 CHECK (invoiced_quantity >= 0),
  promotion_id      uuid,
  batch_id          uuid,                    -- customer asked for a specific batch
  notes             text,
  UNIQUE (tenant_id, id),
  UNIQUE (sales_order_id, line_no),
  FOREIGN KEY (tenant_id, sales_order_id) REFERENCES sales_orders (tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, variant_id)     REFERENCES product_variants (tenant_id, id),
  FOREIGN KEY (tenant_id, unit_id)        REFERENCES units (tenant_id, id),
  FOREIGN KEY (tenant_id, tax_group_id)   REFERENCES tax_groups (tenant_id, id),
  FOREIGN KEY (tenant_id, promotion_id)   REFERENCES promotions (tenant_id, id),
  FOREIGN KEY (tenant_id, batch_id)       REFERENCES product_batches (tenant_id, id),
  CHECK (invoiced_quantity <= quantity + free_quantity)
);
CREATE INDEX ix_so_items_variant ON sales_order_items (tenant_id, variant_id);

ALTER TABLE product_serials
  ADD FOREIGN KEY (tenant_id, reserved_for_order_id) REFERENCES sales_orders (tenant_id, id);

-- -----------------------------------------------------------------------------
-- Invoices: one table for cash, credit, installment and mixed sales.
-- Draft -> posted (stock + ledger + VAT challan written in the same transaction) -> void.
-- -----------------------------------------------------------------------------
CREATE TABLE invoices (
  id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                   uuid NOT NULL REFERENCES tenants(id),
  invoice_no                  varchar(40),                 -- assigned at posting (gapless)
  invoice_type                varchar(12) NOT NULL DEFAULT 'standard'
                              CHECK (invoice_type IN ('standard', 'pos', 'service', 'export', 'consignment')),
  branch_id                   uuid NOT NULL,
  warehouse_id                uuid,
  customer_id                 uuid NOT NULL,
  sales_order_id              uuid,
  sales_rep_id                uuid,
  price_list_id               uuid,
  -- bill-to snapshot (walk-in customers, legal invoice immutability)
  bill_to_name                varchar(200) NOT NULL,
  bill_to_phone               phone_t,
  bill_to_address             text,
  bill_to_bin                 bin_t,
  bill_to_nid                 nid_t,
  invoice_date                date NOT NULL DEFAULT tenant_today(),
  due_date                    date,
  payment_mode                varchar(12) NOT NULL DEFAULT 'cash'
                              CHECK (payment_mode IN ('cash', 'credit', 'installment', 'mixed')),
  status                      varchar(8) NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'posted', 'void')),
  payment_status              varchar(16) NOT NULL DEFAULT 'unpaid'
                              CHECK (payment_status IN ('unpaid', 'partially_paid', 'paid', 'overpaid')),
  currency                    currency_t NOT NULL DEFAULT 'BDT',
  exchange_rate               fx_rate_t NOT NULL DEFAULT 1,
  subtotal                    amount_t NOT NULL DEFAULT 0,
  discount_total              amount_t NOT NULL DEFAULT 0,
  sd_total                    amount_t NOT NULL DEFAULT 0,
  vat_total                   amount_t NOT NULL DEFAULT 0,
  other_tax_total             amount_t NOT NULL DEFAULT 0,
  shipping_charge             amount_t NOT NULL DEFAULT 0,
  other_charges               amount_t NOT NULL DEFAULT 0,   -- registration fee, installation, handling
  round_off                   amount_t NOT NULL DEFAULT 0,
  grand_total                 amount_t NOT NULL DEFAULT 0 CHECK (grand_total >= 0),
  paid_amount                 amount_t NOT NULL DEFAULT 0 CHECK (paid_amount >= 0),
  due_amount                  numeric(15,2) GENERATED ALWAYS AS (grand_total - paid_amount) STORED,
  cost_total                  amount_t NOT NULL DEFAULT 0,    -- COGS snapshot for margin reports
  vat_challan_id              uuid,
  credit_override_approval_id uuid,
  notes                       text,
  terms                       text,
  custom_fields               jsonb NOT NULL DEFAULT '{}'::jsonb,
  client_ref                  uuid,
  pdf_file_key                text,
  posted_at                   timestamptz,
  posted_by                   uuid REFERENCES users(id),
  voided_at                   timestamptz,
  voided_by                   uuid REFERENCES users(id),
  void_reason                 text,
  created_by                  uuid REFERENCES users(id),
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, invoice_no),
  UNIQUE (tenant_id, client_ref),
  FOREIGN KEY (tenant_id, branch_id)                   REFERENCES branches (tenant_id, id),
  FOREIGN KEY (tenant_id, warehouse_id)                REFERENCES warehouses (tenant_id, id),
  FOREIGN KEY (tenant_id, customer_id)                 REFERENCES customers_dealers (tenant_id, id),
  FOREIGN KEY (tenant_id, sales_order_id)              REFERENCES sales_orders (tenant_id, id),
  FOREIGN KEY (tenant_id, sales_rep_id)                REFERENCES sales_reps (tenant_id, id),
  FOREIGN KEY (tenant_id, price_list_id)               REFERENCES price_lists (tenant_id, id),
  FOREIGN KEY (tenant_id, vat_challan_id)              REFERENCES vat_challans (tenant_id, id),
  FOREIGN KEY (tenant_id, credit_override_approval_id) REFERENCES approval_requests (tenant_id, id),
  CHECK (status = 'draft' OR invoice_no IS NOT NULL),
  CHECK (status <> 'posted' OR posted_at IS NOT NULL),
  CHECK (status <> 'void' OR (voided_at IS NOT NULL AND void_reason IS NOT NULL)),
  CHECK (payment_mode = 'cash' OR due_date IS NOT NULL OR status = 'draft')
);
CREATE INDEX ix_invoices_date ON invoices (tenant_id, invoice_date DESC);
CREATE INDEX ix_invoices_customer ON invoices (tenant_id, customer_id, invoice_date DESC);
CREATE INDEX ix_invoices_branch_date ON invoices (tenant_id, branch_id, invoice_date DESC);
CREATE INDEX ix_invoices_sr_date ON invoices (tenant_id, sales_rep_id, invoice_date DESC);
CREATE INDEX ix_invoices_receivables ON invoices (tenant_id, customer_id, due_date)
  WHERE status = 'posted' AND payment_status IN ('unpaid', 'partially_paid');

CREATE TABLE invoice_items (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid NOT NULL REFERENCES tenants(id),
  invoice_id          uuid NOT NULL,
  line_no             smallint NOT NULL,
  sales_order_item_id uuid,
  variant_id          uuid NOT NULL,
  description         varchar(255),
  warehouse_id        uuid,                     -- line-level override of the header warehouse
  batch_id            uuid,
  unit_id             uuid NOT NULL,
  uom_factor          numeric(18,6) NOT NULL DEFAULT 1 CHECK (uom_factor > 0),
  quantity            qty_t NOT NULL CHECK (quantity > 0),
  free_quantity       qty_t NOT NULL DEFAULT 0 CHECK (free_quantity >= 0),
  base_quantity       numeric(18,4) GENERATED ALWAYS AS (round((quantity + free_quantity) * uom_factor, 4)) STORED,
  unit_price          price_t NOT NULL CHECK (unit_price >= 0),
  discount_pct        pct_t NOT NULL DEFAULT 0,
  discount_amount     amount_t NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
  taxable_amount      amount_t NOT NULL,
  tax_group_id        uuid,
  sd_rate             pct_t NOT NULL DEFAULT 0,
  sd_amount           amount_t NOT NULL DEFAULT 0,
  vat_rate            pct_t NOT NULL DEFAULT 0,
  vat_amount          amount_t NOT NULL DEFAULT 0,
  line_total          amount_t NOT NULL,
  unit_cost           price_t,                  -- COGS per base unit at posting
  promotion_id        uuid,
  warranty_months     smallint,
  custom_fields       jsonb NOT NULL DEFAULT '{}'::jsonb,
  UNIQUE (tenant_id, id),
  UNIQUE (invoice_id, line_no),
  FOREIGN KEY (tenant_id, invoice_id)          REFERENCES invoices (tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, sales_order_item_id) REFERENCES sales_order_items (tenant_id, id),
  FOREIGN KEY (tenant_id, variant_id)          REFERENCES product_variants (tenant_id, id),
  FOREIGN KEY (tenant_id, warehouse_id)        REFERENCES warehouses (tenant_id, id),
  FOREIGN KEY (tenant_id, batch_id)            REFERENCES product_batches (tenant_id, id),
  FOREIGN KEY (tenant_id, unit_id)             REFERENCES units (tenant_id, id),
  FOREIGN KEY (tenant_id, tax_group_id)        REFERENCES tax_groups (tenant_id, id),
  FOREIGN KEY (tenant_id, promotion_id)        REFERENCES promotions (tenant_id, id)
);
CREATE INDEX ix_invoice_items_variant ON invoice_items (tenant_id, variant_id);

-- Which physical units were sold on which line.
-- The partial unique index is the last line of defence against double-selling a serial.
CREATE TABLE invoice_item_serials (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenants(id),
  invoice_id      uuid NOT NULL,
  invoice_item_id uuid NOT NULL,
  serial_id       uuid NOT NULL,
  is_active       boolean NOT NULL DEFAULT true,     -- false after return / void
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (invoice_item_id, serial_id),
  FOREIGN KEY (tenant_id, invoice_id)      REFERENCES invoices (tenant_id, id),
  FOREIGN KEY (tenant_id, invoice_item_id) REFERENCES invoice_items (tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, serial_id)       REFERENCES product_serials (tenant_id, id)
);
CREATE UNIQUE INDEX ux_invoice_item_serials_active ON invoice_item_serials (tenant_id, serial_id) WHERE is_active;

ALTER TABLE product_serials
  ADD FOREIGN KEY (tenant_id, sold_invoice_id) REFERENCES invoices (tenant_id, id);

-- Delivery / gate pass (truck, driver, proof of delivery). With tenant setting
-- inventory.deduct_stock_on = 'delivery' the stock movement is sourced from here.
CREATE TABLE deliveries (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenants(id),
  delivery_no       varchar(40) NOT NULL,
  invoice_id        uuid,
  sales_order_id    uuid,
  warehouse_id      uuid NOT NULL,
  status            varchar(20) NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'dispatched', 'delivered', 'partially_delivered',
                                      'failed', 'returned', 'cancelled')),
  delivery_address  text,
  vehicle_no        varchar(30),
  driver_name       varchar(120),
  driver_phone      phone_t,
  transporter_party_id uuid,
  freight_amount    amount_t NOT NULL DEFAULT 0,
  dispatched_at     timestamptz,
  delivered_at      timestamptz,
  received_by_name  varchar(120),
  proof_file_key    text,
  delivered_lat     numeric(9,6),
  delivered_lng     numeric(9,6),
  notes             text,
  custom_fields     jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_by        uuid REFERENCES users(id),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, delivery_no),
  FOREIGN KEY (tenant_id, invoice_id)           REFERENCES invoices (tenant_id, id),
  FOREIGN KEY (tenant_id, sales_order_id)       REFERENCES sales_orders (tenant_id, id),
  FOREIGN KEY (tenant_id, warehouse_id)         REFERENCES warehouses (tenant_id, id),
  FOREIGN KEY (tenant_id, transporter_party_id) REFERENCES parties (tenant_id, id),
  CHECK (invoice_id IS NOT NULL OR sales_order_id IS NOT NULL)
);
CREATE INDEX ix_deliveries_status ON deliveries (tenant_id, status, created_at DESC);

CREATE TABLE delivery_items (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL REFERENCES tenants(id),
  delivery_id        uuid NOT NULL,
  invoice_item_id    uuid,
  variant_id         uuid NOT NULL,
  batch_id           uuid,
  base_quantity      qty_t NOT NULL CHECK (base_quantity > 0),
  delivered_quantity qty_t NOT NULL DEFAULT 0 CHECK (delivered_quantity >= 0),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, delivery_id)     REFERENCES deliveries (tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, invoice_item_id) REFERENCES invoice_items (tenant_id, id),
  FOREIGN KEY (tenant_id, variant_id)      REFERENCES product_variants (tenant_id, id),
  FOREIGN KEY (tenant_id, batch_id)        REFERENCES product_batches (tenant_id, id),
  CHECK (delivered_quantity <= base_quantity)
);

-- -----------------------------------------------------------------------------
-- In-house EMI / installment sales (motorbikes, electronics, furniture)
-- (Bank card 0% EMI is just a card payment and does not use these tables.)
-- -----------------------------------------------------------------------------
CREATE TABLE emi_plans (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id            uuid NOT NULL REFERENCES tenants(id),
  code                 varchar(30) NOT NULL,
  name                 varchar(120) NOT NULL,
  tenure_count         smallint NOT NULL CHECK (tenure_count > 0),
  frequency            varchar(10) NOT NULL DEFAULT 'monthly' CHECK (frequency IN ('weekly', 'biweekly', 'monthly', 'quarterly')),
  interest_method      varchar(16) NOT NULL DEFAULT 'flat' CHECK (interest_method IN ('zero', 'flat', 'reducing_balance')),
  annual_interest_rate pct_t NOT NULL DEFAULT 0,
  min_down_payment_pct pct_t NOT NULL DEFAULT 0,
  processing_fee_pct   pct_t NOT NULL DEFAULT 0,
  processing_fee_flat  amount_t NOT NULL DEFAULT 0,
  late_fee_type        varchar(16) NOT NULL DEFAULT 'none' CHECK (late_fee_type IN ('none', 'flat', 'pct_once', 'pct_per_day')),
  late_fee_value       numeric(12,4) NOT NULL DEFAULT 0,
  grace_days           smallint NOT NULL DEFAULT 0,
  requires_guarantor   boolean NOT NULL DEFAULT false,
  eligibility          jsonb NOT NULL DEFAULT '{}'::jsonb,   -- {"category_ids":[...],"min_amount":50000}
  is_active            boolean NOT NULL DEFAULT true,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code),
  CHECK (interest_method <> 'zero' OR annual_interest_rate = 0)
);

CREATE TABLE installment_schedules (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL REFERENCES tenants(id),
  schedule_no        varchar(40) NOT NULL,
  invoice_id         uuid NOT NULL,
  customer_id        uuid NOT NULL,
  emi_plan_id        uuid,
  sale_amount        amount_t NOT NULL CHECK (sale_amount > 0),
  down_payment       amount_t NOT NULL DEFAULT 0 CHECK (down_payment >= 0),
  financed_amount    amount_t NOT NULL CHECK (financed_amount > 0),
  interest_total     amount_t NOT NULL DEFAULT 0 CHECK (interest_total >= 0),
  processing_fee     amount_t NOT NULL DEFAULT 0,
  total_payable      amount_t NOT NULL,
  installment_count  smallint NOT NULL CHECK (installment_count > 0),
  frequency          varchar(10) NOT NULL DEFAULT 'monthly',
  first_due_date     date NOT NULL,
  status             varchar(12) NOT NULL DEFAULT 'active'
                     CHECK (status IN ('active', 'completed', 'defaulted', 'rescheduled', 'cancelled', 'written_off')),
  guarantor_party_id uuid,
  guarantor_details  jsonb NOT NULL DEFAULT '{}'::jsonb,   -- NID, relation, address, photo keys
  collateral_notes   text,                                 -- e.g. "Original registration papers held"
  rescheduled_from_id uuid,
  approved_by        uuid REFERENCES users(id),
  custom_fields      jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, schedule_no),
  FOREIGN KEY (tenant_id, invoice_id)          REFERENCES invoices (tenant_id, id),
  FOREIGN KEY (tenant_id, customer_id)         REFERENCES customers_dealers (tenant_id, id),
  FOREIGN KEY (tenant_id, emi_plan_id)         REFERENCES emi_plans (tenant_id, id),
  FOREIGN KEY (tenant_id, guarantor_party_id)  REFERENCES parties (tenant_id, id),
  FOREIGN KEY (tenant_id, rescheduled_from_id) REFERENCES installment_schedules (tenant_id, id),
  CHECK (financed_amount = sale_amount - down_payment),
  CHECK (total_payable = financed_amount + interest_total + processing_fee)
);
CREATE UNIQUE INDEX ux_installment_schedule_live ON installment_schedules (invoice_id)
  WHERE status NOT IN ('rescheduled', 'cancelled');
CREATE INDEX ix_installment_schedules_customer ON installment_schedules (tenant_id, customer_id, status);

CREATE TABLE installment_schedule_items (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid NOT NULL REFERENCES tenants(id),
  schedule_id    uuid NOT NULL,
  installment_no smallint NOT NULL CHECK (installment_no > 0),
  due_date       date NOT NULL,
  principal_due  amount_t NOT NULL CHECK (principal_due >= 0),
  interest_due   amount_t NOT NULL DEFAULT 0 CHECK (interest_due >= 0),
  amount_due     amount_t NOT NULL CHECK (amount_due >= 0),
  late_fee_due   amount_t NOT NULL DEFAULT 0 CHECK (late_fee_due >= 0),
  amount_paid    amount_t NOT NULL DEFAULT 0 CHECK (amount_paid >= 0),
  waived_amount  amount_t NOT NULL DEFAULT 0 CHECK (waived_amount >= 0),
  status         varchar(10) NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'partial', 'paid', 'overdue', 'waived')),
  paid_at        timestamptz,
  last_reminder_at timestamptz,
  UNIQUE (tenant_id, id),
  UNIQUE (schedule_id, installment_no),
  FOREIGN KEY (tenant_id, schedule_id) REFERENCES installment_schedules (tenant_id, id) ON DELETE CASCADE,
  CHECK (amount_due = principal_due + interest_due),
  CHECK (amount_paid + waived_amount <= amount_due + late_fee_due)
);
CREATE INDEX ix_installments_due ON installment_schedule_items (tenant_id, due_date)
  WHERE status IN ('pending', 'partial', 'overdue');      -- nightly overdue marking + SMS reminders

-- -----------------------------------------------------------------------------
-- Sales returns (=> Mushak 6.7 credit note)
-- -----------------------------------------------------------------------------
CREATE TABLE sales_returns (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id              uuid NOT NULL REFERENCES tenants(id),
  return_no              varchar(40),
  invoice_id             uuid,                  -- NULL allowed for returns without a traceable invoice
  customer_id            uuid NOT NULL,
  branch_id              uuid NOT NULL,
  warehouse_id           uuid NOT NULL,
  return_date            date NOT NULL DEFAULT tenant_today(),
  reason                 varchar(24) NOT NULL
                         CHECK (reason IN ('damaged', 'expired', 'wrong_item', 'customer_changed_mind',
                                           'warranty_replacement', 'quality_issue', 'excess_stock', 'other')),
  settlement             varchar(20) NOT NULL DEFAULT 'credit_to_account'
                         CHECK (settlement IN ('credit_to_account', 'cash_refund', 'replacement', 'adjust_installments')),
  status                 varchar(10) NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'approved', 'posted', 'cancelled')),
  subtotal               amount_t NOT NULL DEFAULT 0,
  sd_total               amount_t NOT NULL DEFAULT 0,
  vat_total              amount_t NOT NULL DEFAULT 0,
  total_amount           amount_t NOT NULL DEFAULT 0,
  credit_note_challan_id uuid,
  notes                  text,
  created_by             uuid REFERENCES users(id),
  approved_by            uuid REFERENCES users(id),
  posted_at              timestamptz,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, return_no),
  FOREIGN KEY (tenant_id, invoice_id)             REFERENCES invoices (tenant_id, id),
  FOREIGN KEY (tenant_id, customer_id)            REFERENCES customers_dealers (tenant_id, id),
  FOREIGN KEY (tenant_id, branch_id)              REFERENCES branches (tenant_id, id),
  FOREIGN KEY (tenant_id, warehouse_id)           REFERENCES warehouses (tenant_id, id),
  FOREIGN KEY (tenant_id, credit_note_challan_id) REFERENCES vat_challans (tenant_id, id),
  CHECK (status = 'draft' OR return_no IS NOT NULL)
);
CREATE INDEX ix_sales_returns_customer ON sales_returns (tenant_id, customer_id, return_date DESC);

CREATE TABLE sales_return_items (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenants(id),
  sales_return_id uuid NOT NULL,
  invoice_item_id uuid,
  variant_id      uuid NOT NULL,
  batch_id        uuid,
  serial_id       uuid,                    -- one row per unit for serialized products
  unit_id         uuid NOT NULL,
  uom_factor      numeric(18,6) NOT NULL DEFAULT 1 CHECK (uom_factor > 0),
  quantity        qty_t NOT NULL CHECK (quantity > 0),
  unit_price      price_t NOT NULL,
  sd_amount       amount_t NOT NULL DEFAULT 0,
  vat_amount      amount_t NOT NULL DEFAULT 0,
  line_total      amount_t NOT NULL,
  item_condition  varchar(10) NOT NULL DEFAULT 'good' CHECK (item_condition IN ('good', 'damaged', 'expired', 'defective')),
  restock_warehouse_id uuid,               -- damaged goods -> 'damaged' warehouse
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, sales_return_id)      REFERENCES sales_returns (tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, invoice_item_id)      REFERENCES invoice_items (tenant_id, id),
  FOREIGN KEY (tenant_id, variant_id)           REFERENCES product_variants (tenant_id, id),
  FOREIGN KEY (tenant_id, batch_id)             REFERENCES product_batches (tenant_id, id),
  FOREIGN KEY (tenant_id, serial_id)            REFERENCES product_serials (tenant_id, id),
  FOREIGN KEY (tenant_id, unit_id)              REFERENCES units (tenant_id, id),
  FOREIGN KEY (tenant_id, restock_warehouse_id) REFERENCES warehouses (tenant_id, id),
  CHECK (serial_id IS NULL OR quantity * uom_factor = 1)
);

-- -----------------------------------------------------------------------------
-- Warranty / after-sales claims (electronics, motorbikes, appliances)
-- -----------------------------------------------------------------------------
CREATE TABLE warranty_claims (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid NOT NULL REFERENCES tenants(id),
  claim_no              varchar(40) NOT NULL,
  branch_id             uuid NOT NULL,
  customer_id           uuid NOT NULL,
  variant_id            uuid NOT NULL,
  serial_id             uuid,
  invoice_id            uuid,
  reported_issue        text NOT NULL,
  is_under_warranty     boolean NOT NULL,
  status                varchar(24) NOT NULL DEFAULT 'received'
                        CHECK (status IN ('received', 'diagnosing', 'sent_to_supplier', 'awaiting_parts', 'repaired',
                                          'replaced', 'rejected', 'returned_to_customer', 'closed')),
  resolution            text,
  replacement_serial_id uuid,
  supplier_id           uuid,
  service_charge        amount_t NOT NULL DEFAULT 0,
  received_at           timestamptz NOT NULL DEFAULT now(),
  resolved_at           timestamptz,
  custom_fields         jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_by            uuid REFERENCES users(id),
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, claim_no),
  FOREIGN KEY (tenant_id, branch_id)             REFERENCES branches (tenant_id, id),
  FOREIGN KEY (tenant_id, customer_id)           REFERENCES customers_dealers (tenant_id, id),
  FOREIGN KEY (tenant_id, variant_id)            REFERENCES product_variants (tenant_id, id),
  FOREIGN KEY (tenant_id, serial_id)             REFERENCES product_serials (tenant_id, id),
  FOREIGN KEY (tenant_id, invoice_id)            REFERENCES invoices (tenant_id, id),
  FOREIGN KEY (tenant_id, replacement_serial_id) REFERENCES product_serials (tenant_id, id),
  FOREIGN KEY (tenant_id, supplier_id)           REFERENCES suppliers (tenant_id, id)
);
CREATE INDEX ix_warranty_claims_open ON warranty_claims (tenant_id, status) WHERE status NOT IN ('closed', 'rejected');
CREATE INDEX ix_warranty_claims_serial ON warranty_claims (tenant_id, serial_id);

-- =============================================================================
-- AmarDealer DMS · 06 Procurement: purchase orders (local + import/LC), GRN,
-- landed costs, supplier bills (input VAT), purchase returns (=> Mushak 6.8)
-- =============================================================================

CREATE TABLE purchase_orders (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL REFERENCES tenants(id),
  po_no              varchar(40),
  supplier_id        uuid NOT NULL,
  branch_id          uuid NOT NULL,
  warehouse_id       uuid NOT NULL,                 -- default receiving warehouse
  order_date         date NOT NULL DEFAULT tenant_today(),
  expected_date      date,
  purchase_type      varchar(8) NOT NULL DEFAULT 'local' CHECK (purchase_type IN ('local', 'import')),
  currency           currency_t NOT NULL DEFAULT 'BDT',
  exchange_rate      fx_rate_t NOT NULL DEFAULT 1,
  -- import / letter of credit
  lc_no              varchar(60),
  lc_date            date,
  lc_bank            varchar(120),
  incoterm           varchar(3) CHECK (incoterm IN ('EXW', 'FCA', 'FOB', 'CFR', 'CIF', 'CPT', 'CIP', 'DAP', 'DPU', 'DDP')),
  payment_terms_days smallint NOT NULL DEFAULT 0,
  status             varchar(20) NOT NULL DEFAULT 'draft'
                     CHECK (status IN ('draft', 'pending_approval', 'approved', 'sent', 'partially_received',
                                       'received', 'closed', 'cancelled')),
  subtotal           amount_t NOT NULL DEFAULT 0,
  discount_total     amount_t NOT NULL DEFAULT 0,
  tax_total          amount_t NOT NULL DEFAULT 0,
  grand_total        amount_t NOT NULL DEFAULT 0,
  notes              text,
  custom_fields      jsonb NOT NULL DEFAULT '{}'::jsonb,
  approval_request_id uuid,
  created_by         uuid REFERENCES users(id),
  approved_by        uuid REFERENCES users(id),
  approved_at        timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, po_no),
  FOREIGN KEY (tenant_id, supplier_id)         REFERENCES suppliers (tenant_id, id),
  FOREIGN KEY (tenant_id, branch_id)           REFERENCES branches (tenant_id, id),
  FOREIGN KEY (tenant_id, warehouse_id)        REFERENCES warehouses (tenant_id, id),
  FOREIGN KEY (tenant_id, approval_request_id) REFERENCES approval_requests (tenant_id, id),
  CHECK (status = 'draft' OR po_no IS NOT NULL),
  CHECK (purchase_type = 'local' OR currency IS NOT NULL)
);
CREATE INDEX ix_po_supplier ON purchase_orders (tenant_id, supplier_id, order_date DESC);
CREATE INDEX ix_po_open ON purchase_orders (tenant_id, status) WHERE status IN ('approved', 'sent', 'partially_received');

CREATE TABLE purchase_order_items (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenants(id),
  purchase_order_id uuid NOT NULL,
  line_no           smallint NOT NULL,
  variant_id        uuid NOT NULL,
  description       varchar(255),
  unit_id           uuid NOT NULL,
  uom_factor        numeric(18,6) NOT NULL DEFAULT 1 CHECK (uom_factor > 0),
  quantity          qty_t NOT NULL CHECK (quantity > 0),
  received_quantity qty_t NOT NULL DEFAULT 0 CHECK (received_quantity >= 0),
  unit_price        price_t NOT NULL CHECK (unit_price >= 0),   -- in PO currency
  discount_pct      pct_t NOT NULL DEFAULT 0,
  tax_group_id      uuid,
  tax_amount        amount_t NOT NULL DEFAULT 0,
  line_total        amount_t NOT NULL,
  UNIQUE (tenant_id, id),
  UNIQUE (purchase_order_id, line_no),
  FOREIGN KEY (tenant_id, purchase_order_id) REFERENCES purchase_orders (tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, variant_id)        REFERENCES product_variants (tenant_id, id),
  FOREIGN KEY (tenant_id, unit_id)           REFERENCES units (tenant_id, id),
  FOREIGN KEY (tenant_id, tax_group_id)      REFERENCES tax_groups (tenant_id, id)
);

CREATE TABLE goods_received_notes (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid NOT NULL REFERENCES tenants(id),
  grn_no                varchar(40),
  purchase_order_id     uuid,                     -- NULL = direct receipt without PO
  supplier_id           uuid NOT NULL,
  branch_id             uuid NOT NULL,
  warehouse_id          uuid NOT NULL,
  received_date         date NOT NULL DEFAULT tenant_today(),
  supplier_challan_no   varchar(60),
  supplier_invoice_no   varchar(60),
  supplier_mushak_no    varchar(60),              -- supplier's Mushak 6.3 (input VAT evidence)
  bill_of_entry_no      varchar(60),              -- imports
  vehicle_no            varchar(30),
  currency              currency_t NOT NULL DEFAULT 'BDT',
  exchange_rate         fx_rate_t NOT NULL DEFAULT 1,
  status                varchar(10) NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'posted', 'cancelled')),
  goods_value           amount_t NOT NULL DEFAULT 0,   -- BDT
  landed_cost_total     amount_t NOT NULL DEFAULT 0,   -- BDT, capitalized add-ons
  notes                 text,
  custom_fields         jsonb NOT NULL DEFAULT '{}'::jsonb,
  received_by           uuid REFERENCES users(id),
  posted_at             timestamptz,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, grn_no),
  FOREIGN KEY (tenant_id, purchase_order_id) REFERENCES purchase_orders (tenant_id, id),
  FOREIGN KEY (tenant_id, supplier_id)       REFERENCES suppliers (tenant_id, id),
  FOREIGN KEY (tenant_id, branch_id)         REFERENCES branches (tenant_id, id),
  FOREIGN KEY (tenant_id, warehouse_id)      REFERENCES warehouses (tenant_id, id),
  CHECK (status = 'draft' OR grn_no IS NOT NULL)
);
CREATE INDEX ix_grn_supplier ON goods_received_notes (tenant_id, supplier_id, received_date DESC);
CREATE INDEX ix_grn_po ON goods_received_notes (tenant_id, purchase_order_id);

CREATE TABLE grn_items (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id              uuid NOT NULL REFERENCES tenants(id),
  grn_id                 uuid NOT NULL,
  line_no                smallint NOT NULL,
  purchase_order_item_id uuid,
  variant_id             uuid NOT NULL,
  unit_id                uuid NOT NULL,
  uom_factor             numeric(18,6) NOT NULL DEFAULT 1 CHECK (uom_factor > 0),
  quantity_received      qty_t NOT NULL CHECK (quantity_received > 0),
  quantity_accepted      qty_t NOT NULL CHECK (quantity_accepted >= 0),
  quantity_rejected      qty_t NOT NULL DEFAULT 0 CHECK (quantity_rejected >= 0),
  base_quantity_accepted numeric(18,4) GENERATED ALWAYS AS (round(quantity_accepted * uom_factor, 4)) STORED,
  unit_cost              price_t NOT NULL CHECK (unit_cost >= 0),       -- document currency, per unit_id
  landed_unit_cost       price_t,                                       -- BDT per BASE unit incl. allocated landed cost
  batch_id               uuid,
  location_id            uuid,
  rejection_reason       text,
  UNIQUE (tenant_id, id),
  UNIQUE (grn_id, line_no),
  FOREIGN KEY (tenant_id, grn_id)                 REFERENCES goods_received_notes (tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, purchase_order_item_id) REFERENCES purchase_order_items (tenant_id, id),
  FOREIGN KEY (tenant_id, variant_id)             REFERENCES product_variants (tenant_id, id),
  FOREIGN KEY (tenant_id, unit_id)                REFERENCES units (tenant_id, id),
  FOREIGN KEY (tenant_id, batch_id)               REFERENCES product_batches (tenant_id, id),
  FOREIGN KEY (tenant_id, location_id)            REFERENCES warehouse_locations (tenant_id, id),
  CHECK (quantity_accepted + quantity_rejected = quantity_received)
);
CREATE INDEX ix_grn_items_variant ON grn_items (tenant_id, variant_id);

-- Serials are created at GRN time and point back at the receiving line
ALTER TABLE product_serials
  ADD FOREIGN KEY (tenant_id, grn_item_id) REFERENCES grn_items (tenant_id, id);
CREATE INDEX ix_serials_grn_item ON product_serials (tenant_id, grn_item_id);

-- Import duties & charges capitalized into inventory cost (or recoverable, e.g. import VAT/AT)
CREATE TABLE purchase_landed_costs (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenants(id),
  grn_id            uuid NOT NULL,
  cost_type         varchar(24) NOT NULL
                    CHECK (cost_type IN ('customs_duty', 'regulatory_duty', 'supplementary_duty', 'import_vat',
                                         'advance_income_tax', 'advance_tax', 'freight', 'insurance',
                                         'c_and_f_agent', 'port_charges', 'local_transport', 'bank_charges',
                                         'unloading', 'other')),
  amount            amount_t NOT NULL CHECK (amount >= 0),  -- BDT
  is_recoverable    boolean NOT NULL DEFAULT false,         -- import VAT / AT -> input credit, not inventory cost
  allocation_method varchar(10) NOT NULL DEFAULT 'by_value' CHECK (allocation_method IN ('by_value', 'by_qty', 'by_weight', 'manual')),
  vendor_party_id   uuid,                                   -- C&F agent, transporter, customs
  reference_no      varchar(60),
  notes             text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, grn_id)          REFERENCES goods_received_notes (tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, vendor_party_id) REFERENCES parties (tenant_id, id)
);

CREATE TABLE supplier_bills (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid NOT NULL REFERENCES tenants(id),
  bill_no             varchar(40),                -- internal number
  supplier_id         uuid NOT NULL,
  branch_id           uuid NOT NULL,
  grn_id              uuid,
  purchase_order_id   uuid,
  supplier_invoice_no varchar(60) NOT NULL,
  supplier_mushak_no  varchar(60),
  bill_date           date NOT NULL,
  due_date            date,
  currency            currency_t NOT NULL DEFAULT 'BDT',
  exchange_rate       fx_rate_t NOT NULL DEFAULT 1,
  subtotal            amount_t NOT NULL DEFAULT 0,
  sd_amount           amount_t NOT NULL DEFAULT 0,
  vat_amount          amount_t NOT NULL DEFAULT 0,    -- input VAT claimable on 9.1 return
  vds_amount          amount_t NOT NULL DEFAULT 0,    -- VAT we deduct at source (we issue 6.6)
  ait_amount          amount_t NOT NULL DEFAULT 0,
  total_amount        amount_t NOT NULL DEFAULT 0 CHECK (total_amount >= 0),
  paid_amount         amount_t NOT NULL DEFAULT 0 CHECK (paid_amount >= 0),
  due_amount          numeric(15,2) GENERATED ALWAYS AS (total_amount - paid_amount) STORED,
  status              varchar(8) NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'posted', 'void')),
  payment_status      varchar(16) NOT NULL DEFAULT 'unpaid' CHECK (payment_status IN ('unpaid', 'partially_paid', 'paid')),
  notes               text,
  created_by          uuid REFERENCES users(id),
  posted_at           timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, bill_no),
  UNIQUE (tenant_id, supplier_id, supplier_invoice_no),       -- no double booking of a supplier invoice
  FOREIGN KEY (tenant_id, supplier_id)       REFERENCES suppliers (tenant_id, id),
  FOREIGN KEY (tenant_id, branch_id)         REFERENCES branches (tenant_id, id),
  FOREIGN KEY (tenant_id, grn_id)            REFERENCES goods_received_notes (tenant_id, id),
  FOREIGN KEY (tenant_id, purchase_order_id) REFERENCES purchase_orders (tenant_id, id),
  CHECK (status = 'draft' OR bill_no IS NOT NULL)
);
CREATE INDEX ix_supplier_bills_payables ON supplier_bills (tenant_id, supplier_id, due_date)
  WHERE status = 'posted' AND payment_status <> 'paid';

CREATE TABLE purchase_returns (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid NOT NULL REFERENCES tenants(id),
  return_no             varchar(40),
  supplier_id           uuid NOT NULL,
  grn_id                uuid,
  branch_id             uuid NOT NULL,
  warehouse_id          uuid NOT NULL,
  return_date           date NOT NULL DEFAULT tenant_today(),
  reason                varchar(20) NOT NULL CHECK (reason IN ('damaged', 'defective', 'expired', 'wrong_item', 'excess', 'quality', 'other')),
  status                varchar(10) NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'approved', 'posted', 'cancelled')),
  total_amount          amount_t NOT NULL DEFAULT 0,
  vat_amount            amount_t NOT NULL DEFAULT 0,
  debit_note_challan_id uuid,
  notes                 text,
  created_by            uuid REFERENCES users(id),
  posted_at             timestamptz,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, return_no),
  FOREIGN KEY (tenant_id, supplier_id)           REFERENCES suppliers (tenant_id, id),
  FOREIGN KEY (tenant_id, grn_id)                REFERENCES goods_received_notes (tenant_id, id),
  FOREIGN KEY (tenant_id, branch_id)             REFERENCES branches (tenant_id, id),
  FOREIGN KEY (tenant_id, warehouse_id)          REFERENCES warehouses (tenant_id, id),
  FOREIGN KEY (tenant_id, debit_note_challan_id) REFERENCES vat_challans (tenant_id, id),
  CHECK (status = 'draft' OR return_no IS NOT NULL)
);

CREATE TABLE purchase_return_items (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL REFERENCES tenants(id),
  purchase_return_id uuid NOT NULL,
  grn_item_id        uuid,
  variant_id         uuid NOT NULL,
  batch_id           uuid,
  serial_id          uuid,
  base_quantity      qty_t NOT NULL CHECK (base_quantity > 0),
  unit_cost          price_t NOT NULL,
  vat_amount         amount_t NOT NULL DEFAULT 0,
  line_total         amount_t NOT NULL,
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, purchase_return_id) REFERENCES purchase_returns (tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, grn_item_id)        REFERENCES grn_items (tenant_id, id),
  FOREIGN KEY (tenant_id, variant_id)         REFERENCES product_variants (tenant_id, id),
  FOREIGN KEY (tenant_id, batch_id)           REFERENCES product_batches (tenant_id, id),
  FOREIGN KEY (tenant_id, serial_id)          REFERENCES product_serials (tenant_id, id),
  CHECK (serial_id IS NULL OR base_quantity = 1)
);

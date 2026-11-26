-- =============================================================================
-- AmarDealer DMS · 07 Inventory
--   stock_movements : append-only ledger, single source of truth
--   stock_balances  : projection maintained by trigger (10_business_rules.sql);
--                     CHECK constraint makes overselling impossible at the DB level
-- =============================================================================

CREATE TABLE stock_balances (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL REFERENCES tenants(id),
  warehouse_id     uuid NOT NULL,
  variant_id       uuid NOT NULL,
  batch_id         uuid,                                   -- NULL for untracked / serial-only products
  qty_on_hand      qty_t NOT NULL DEFAULT 0,
  qty_reserved     qty_t NOT NULL DEFAULT 0 CHECK (qty_reserved >= 0),   -- approved sales orders
  qty_available    numeric(18,4) GENERATED ALWAYS AS (qty_on_hand - qty_reserved) STORED,
  avg_unit_cost    price_t NOT NULL DEFAULT 0,             -- moving weighted average, per base unit
  allow_negative   boolean NOT NULL DEFAULT false,         -- copied from warehouses.allow_negative_stock
  reorder_level    qty_t,
  last_movement_at timestamptz,
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  CONSTRAINT uq_stock_balances_key UNIQUE NULLS NOT DISTINCT (tenant_id, warehouse_id, variant_id, batch_id),
  CONSTRAINT stock_balances_non_negative CHECK (allow_negative OR qty_on_hand >= 0),
  FOREIGN KEY (tenant_id, warehouse_id) REFERENCES warehouses (tenant_id, id),
  FOREIGN KEY (tenant_id, variant_id)   REFERENCES product_variants (tenant_id, id),
  FOREIGN KEY (tenant_id, batch_id)     REFERENCES product_batches (tenant_id, id)
);
CREATE INDEX ix_stock_balances_variant ON stock_balances (tenant_id, variant_id);
CREATE INDEX ix_stock_balances_low ON stock_balances (tenant_id, warehouse_id)
  WHERE reorder_level IS NOT NULL AND qty_on_hand <= reorder_level;

CREATE TABLE stock_movements (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenants(id),
  movement_date   date NOT NULL DEFAULT tenant_today(),
  occurred_at     timestamptz NOT NULL DEFAULT now(),
  movement_type   varchar(20) NOT NULL
                  CHECK (movement_type IN ('opening', 'purchase_receipt', 'purchase_return', 'sale', 'sales_return',
                                           'transfer_out', 'transfer_in', 'adjustment_in', 'adjustment_out',
                                           'damage', 'expiry_writeoff', 'internal_consumption', 'sample',
                                           'assembly_in', 'assembly_out', 'production_in', 'production_out',
                                           'consignment_out', 'consignment_in', 'reversal')),
  warehouse_id    uuid NOT NULL,
  location_id     uuid,
  variant_id      uuid NOT NULL,
  batch_id        uuid,
  serial_id       uuid,
  quantity        qty_t NOT NULL CHECK (quantity <> 0),   -- signed, BASE unit: +in / -out
  unit_cost       price_t,                                -- in: purchase/landed cost; out: filled with avg cost by trigger
  balance_after   numeric(18,4),                          -- filled by trigger
  source_doc_type varchar(32) NOT NULL,                   -- invoice, grn, stock_transfer, stock_adjustment, sales_return ...
  source_doc_id   uuid NOT NULL,
  source_line_id  uuid,
  reversal_of_id  uuid,
  notes           text,
  created_by      uuid REFERENCES users(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, warehouse_id)   REFERENCES warehouses (tenant_id, id),
  FOREIGN KEY (tenant_id, location_id)    REFERENCES warehouse_locations (tenant_id, id),
  FOREIGN KEY (tenant_id, variant_id)     REFERENCES product_variants (tenant_id, id),
  FOREIGN KEY (tenant_id, batch_id)       REFERENCES product_batches (tenant_id, id),
  FOREIGN KEY (tenant_id, serial_id)      REFERENCES product_serials (tenant_id, id),
  FOREIGN KEY (tenant_id, reversal_of_id) REFERENCES stock_movements (tenant_id, id),
  CHECK (serial_id IS NULL OR abs(quantity) = 1)
);
CREATE INDEX ix_stock_movements_card ON stock_movements (tenant_id, variant_id, warehouse_id, occurred_at);   -- stock card
CREATE INDEX ix_stock_movements_source ON stock_movements (tenant_id, source_doc_type, source_doc_id);
CREATE INDEX ix_stock_movements_date ON stock_movements (tenant_id, movement_date);
CREATE INDEX ix_stock_movements_serial ON stock_movements (tenant_id, serial_id) WHERE serial_id IS NOT NULL;

-- -----------------------------------------------------------------------------
-- Inter-warehouse / inter-branch transfers (=> Mushak 6.5 when crossing VAT units)
-- -----------------------------------------------------------------------------
CREATE TABLE stock_transfers (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenants(id),
  transfer_no       varchar(40),
  from_warehouse_id uuid NOT NULL,
  to_warehouse_id   uuid NOT NULL,
  transfer_date     date NOT NULL DEFAULT tenant_today(),
  status            varchar(20) NOT NULL DEFAULT 'draft'
                    CHECK (status IN ('draft', 'pending_approval', 'approved', 'in_transit',
                                      'partially_received', 'received', 'cancelled')),
  vehicle_no        varchar(30),
  driver_name       varchar(120),
  driver_phone      phone_t,
  vat_challan_id    uuid,
  notes             text,
  requested_by      uuid REFERENCES users(id),
  approved_by       uuid REFERENCES users(id),
  dispatched_by     uuid REFERENCES users(id),
  received_by       uuid REFERENCES users(id),
  dispatched_at     timestamptz,
  received_at       timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, transfer_no),
  FOREIGN KEY (tenant_id, from_warehouse_id) REFERENCES warehouses (tenant_id, id),
  FOREIGN KEY (tenant_id, to_warehouse_id)   REFERENCES warehouses (tenant_id, id),
  FOREIGN KEY (tenant_id, vat_challan_id)    REFERENCES vat_challans (tenant_id, id),
  CHECK (from_warehouse_id <> to_warehouse_id),
  CHECK (status = 'draft' OR transfer_no IS NOT NULL)
);
CREATE INDEX ix_transfers_in_transit ON stock_transfers (tenant_id, to_warehouse_id, status)
  WHERE status IN ('in_transit', 'partially_received');

CREATE TABLE stock_transfer_items (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL REFERENCES tenants(id),
  stock_transfer_id  uuid NOT NULL,
  line_no            smallint NOT NULL,
  variant_id         uuid NOT NULL,
  batch_id           uuid,
  unit_id            uuid NOT NULL,
  uom_factor         numeric(18,6) NOT NULL DEFAULT 1 CHECK (uom_factor > 0),
  quantity_requested qty_t NOT NULL CHECK (quantity_requested > 0),
  quantity_dispatched qty_t NOT NULL DEFAULT 0 CHECK (quantity_dispatched >= 0),
  quantity_received  qty_t NOT NULL DEFAULT 0 CHECK (quantity_received >= 0),
  unit_cost          price_t,
  UNIQUE (tenant_id, id),
  UNIQUE (stock_transfer_id, line_no),
  FOREIGN KEY (tenant_id, stock_transfer_id) REFERENCES stock_transfers (tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, variant_id)        REFERENCES product_variants (tenant_id, id),
  FOREIGN KEY (tenant_id, batch_id)          REFERENCES product_batches (tenant_id, id),
  FOREIGN KEY (tenant_id, unit_id)           REFERENCES units (tenant_id, id),
  CHECK (quantity_received <= quantity_dispatched)
);

CREATE TABLE stock_transfer_item_serials (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id              uuid NOT NULL REFERENCES tenants(id),
  stock_transfer_item_id uuid NOT NULL,
  serial_id              uuid NOT NULL,
  is_received            boolean NOT NULL DEFAULT false,
  UNIQUE (stock_transfer_item_id, serial_id),
  FOREIGN KEY (tenant_id, stock_transfer_item_id) REFERENCES stock_transfer_items (tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, serial_id)              REFERENCES product_serials (tenant_id, id)
);

-- -----------------------------------------------------------------------------
-- Adjustments & physical counts
-- -----------------------------------------------------------------------------
CREATE TABLE stock_adjustments (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenants(id),
  adjustment_no   varchar(40),
  warehouse_id    uuid NOT NULL,
  adjustment_date date NOT NULL DEFAULT tenant_today(),
  reason_code     varchar(20) NOT NULL
                  CHECK (reason_code IN ('opening_balance', 'physical_count', 'damage', 'expiry', 'theft_loss',
                                         'sample', 'internal_use', 'found', 'correction', 'other')),
  status          varchar(16) NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'pending_approval', 'approved', 'posted', 'cancelled')),
  notes           text,
  approval_request_id uuid,
  created_by      uuid REFERENCES users(id),
  approved_by     uuid REFERENCES users(id),
  posted_at       timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, adjustment_no),
  FOREIGN KEY (tenant_id, warehouse_id)        REFERENCES warehouses (tenant_id, id),
  FOREIGN KEY (tenant_id, approval_request_id) REFERENCES approval_requests (tenant_id, id),
  CHECK (status = 'draft' OR adjustment_no IS NOT NULL)
);

CREATE TABLE stock_adjustment_items (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid NOT NULL REFERENCES tenants(id),
  stock_adjustment_id uuid NOT NULL,
  variant_id          uuid NOT NULL,
  batch_id            uuid,
  serial_id           uuid,
  location_id         uuid,
  qty_system          qty_t,                            -- snapshot for physical counts
  qty_counted         qty_t,
  qty_difference      qty_t NOT NULL CHECK (qty_difference <> 0),   -- signed base quantity
  unit_cost           price_t,
  notes               text,
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, stock_adjustment_id) REFERENCES stock_adjustments (tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, variant_id)          REFERENCES product_variants (tenant_id, id),
  FOREIGN KEY (tenant_id, batch_id)            REFERENCES product_batches (tenant_id, id),
  FOREIGN KEY (tenant_id, serial_id)           REFERENCES product_serials (tenant_id, id),
  FOREIGN KEY (tenant_id, location_id)         REFERENCES warehouse_locations (tenant_id, id),
  CHECK (serial_id IS NULL OR abs(qty_difference) = 1)
);

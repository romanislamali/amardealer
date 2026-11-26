-- =============================================================================
-- AmarDealer DMS · 04 Parties (customers, dealers, suppliers) & field sales force
--
-- One `parties` row per real-world person/company. A party can be a customer AND a
-- supplier at once (common between distributors). Role-specific data lives in
-- customers_dealers / suppliers. The party ledger (payments_ledger) keys on party_id.
-- =============================================================================

CREATE TABLE parties (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL REFERENCES tenants(id),
  party_code       varchar(40) NOT NULL,
  party_kind       varchar(12) NOT NULL DEFAULT 'organization' CHECK (party_kind IN ('individual', 'organization')),
  display_name     varchar(200) NOT NULL,             -- shop / company / person name
  legal_name       varchar(200),
  name_bn          varchar(200),
  contact_person   varchar(120),
  phone            phone_t,
  alt_phone        phone_t,
  email            citext,
  nid              nid_t,                              -- individuals (EMI buyers, retailers)
  bin              bin_t,
  tin              tin_t,
  trade_license_no varchar(50),
  address_line1    varchar(200),
  address_line2    varchar(200),
  geo_area_id      uuid REFERENCES geo_areas(id),
  territory_id     uuid,
  postal_code      varchar(10),
  latitude         numeric(9,6),
  longitude        numeric(9,6),
  is_active        boolean NOT NULL DEFAULT true,
  notes            text,
  custom_fields    jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(custom_fields) = 'object'),
  created_by       uuid REFERENCES users(id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, party_code),
  FOREIGN KEY (tenant_id, territory_id) REFERENCES territories (tenant_id, id)
);
CREATE INDEX ix_parties_search ON parties USING gin (tenant_id, display_name gin_trgm_ops);
CREATE INDEX ix_parties_phone ON parties (tenant_id, phone);
CREATE INDEX ix_parties_territory ON parties (tenant_id, territory_id);

CREATE TABLE party_addresses (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenants(id),
  party_id      uuid NOT NULL,
  address_type  varchar(12) NOT NULL DEFAULT 'shipping' CHECK (address_type IN ('billing', 'shipping', 'registered', 'warehouse')),
  label         varchar(60),
  contact_name  varchar(120),
  contact_phone phone_t,
  address_line1 varchar(200) NOT NULL,
  address_line2 varchar(200),
  geo_area_id   uuid REFERENCES geo_areas(id),
  latitude      numeric(9,6),
  longitude     numeric(9,6),
  is_default    boolean NOT NULL DEFAULT false,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, party_id) REFERENCES parties (tenant_id, id) ON DELETE CASCADE
);

-- Channel tiers: Distributor, Dealer, Sub-dealer, Retailer, Corporate, Walk-in ...
CREATE TABLE customer_groups (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid NOT NULL REFERENCES tenants(id),
  code                  varchar(30) NOT NULL,
  name                  varchar(80) NOT NULL,
  name_bn               varchar(80),
  tier_level            smallint NOT NULL DEFAULT 1,    -- 1 = closest to the company
  default_price_list_id uuid,
  default_credit_limit  amount_t NOT NULL DEFAULT 0 CHECK (default_credit_limit >= 0),
  default_credit_days   smallint NOT NULL DEFAULT 0 CHECK (default_credit_days >= 0),
  default_discount_pct  pct_t NOT NULL DEFAULT 0,
  is_active             boolean NOT NULL DEFAULT true,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code),
  FOREIGN KEY (tenant_id, default_price_list_id) REFERENCES price_lists (tenant_id, id)
);

-- -----------------------------------------------------------------------------
-- Sales force (SR / TSO / ASM / RSM hierarchy)
-- -----------------------------------------------------------------------------
CREATE TABLE sales_reps (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL REFERENCES tenants(id),
  membership_id    uuid,                         -- login account (mobile app); NULL for SRs without app access
  employee_code    varchar(40) NOT NULL,
  full_name        varchar(120) NOT NULL,
  phone            phone_t NOT NULL,
  branch_id        uuid NOT NULL,
  manager_id       uuid,                         -- reporting line
  designation      varchar(40) NOT NULL DEFAULT 'SR',   -- SR, TSO, ASM, RSM, DSM (free text per tenant)
  van_warehouse_id uuid,                         -- van sales: SR carries stock
  commission_pct   pct_t NOT NULL DEFAULT 0,
  joined_on        date,
  is_active        boolean NOT NULL DEFAULT true,
  custom_fields    jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, employee_code),
  UNIQUE (tenant_id, membership_id),
  FOREIGN KEY (tenant_id, membership_id)    REFERENCES tenant_memberships (tenant_id, id),
  FOREIGN KEY (tenant_id, branch_id)        REFERENCES branches (tenant_id, id),
  FOREIGN KEY (tenant_id, manager_id)       REFERENCES sales_reps (tenant_id, id),
  FOREIGN KEY (tenant_id, van_warehouse_id) REFERENCES warehouses (tenant_id, id),
  CHECK (manager_id IS DISTINCT FROM id)
);
CREATE INDEX ix_sales_reps_branch ON sales_reps (tenant_id, branch_id) WHERE is_active;
CREATE INDEX ix_sales_reps_manager ON sales_reps (tenant_id, manager_id);

CREATE TABLE sales_rep_territories (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL REFERENCES tenants(id),
  sales_rep_id uuid NOT NULL,
  territory_id uuid NOT NULL,
  is_primary   boolean NOT NULL DEFAULT true,
  valid_from   date NOT NULL DEFAULT CURRENT_DATE,
  valid_to     date,
  UNIQUE (sales_rep_id, territory_id, valid_from),
  FOREIGN KEY (tenant_id, sales_rep_id) REFERENCES sales_reps (tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, territory_id) REFERENCES territories (tenant_id, id),
  CHECK (valid_to IS NULL OR valid_to >= valid_from)
);
CREATE INDEX ix_srt_territory ON sales_rep_territories (tenant_id, territory_id);

-- Beat plan / route: ordered outlet list visited on given weekdays
CREATE TABLE routes (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL REFERENCES tenants(id),
  territory_id uuid,
  sales_rep_id uuid,
  code         varchar(30) NOT NULL,
  name         varchar(120) NOT NULL,
  visit_days   smallint[] NOT NULL DEFAULT '{}' CHECK (visit_days <@ ARRAY[0,1,2,3,4,5,6]::smallint[]),  -- 0 = Sunday
  is_active    boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code),
  FOREIGN KEY (tenant_id, territory_id) REFERENCES territories (tenant_id, id),
  FOREIGN KEY (tenant_id, sales_rep_id) REFERENCES sales_reps (tenant_id, id)
);

-- -----------------------------------------------------------------------------
-- Customers / dealers with credit control
-- -----------------------------------------------------------------------------
CREATE TABLE customers_dealers (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid NOT NULL REFERENCES tenants(id),
  party_id              uuid NOT NULL,
  customer_group_id     uuid,
  parent_customer_id    uuid,                       -- multi-tier: distributor > dealer > sub-dealer > retailer
  home_branch_id        uuid,
  assigned_sales_rep_id uuid,
  route_id              uuid,
  price_list_id         uuid,                       -- overrides customer_group default
  credit_limit          amount_t NOT NULL DEFAULT 0 CHECK (credit_limit >= 0),
  credit_days           smallint NOT NULL DEFAULT 0 CHECK (credit_days >= 0),
  credit_status         varchar(12) NOT NULL DEFAULT 'active'
                        CHECK (credit_status IN ('active', 'on_hold', 'cash_only', 'blocked')),
  -- maintained ONLY by the payments_ledger trigger (positive = customer owes us, negative = advance)
  current_due_balance   amount_t NOT NULL DEFAULT 0,
  security_deposit      amount_t NOT NULL DEFAULT 0 CHECK (security_deposit >= 0),
  max_discount_pct      pct_t,
  is_vat_exempt         boolean NOT NULL DEFAULT false,
  is_vds_applicable     boolean NOT NULL DEFAULT false,   -- customer withholds VAT at source (Mushak 6.6)
  customer_since        date,
  last_invoice_at       timestamptz,
  last_payment_at       timestamptz,
  is_walk_in            boolean NOT NULL DEFAULT false,   -- shared "Cash Customer" record for POS
  version               integer NOT NULL DEFAULT 1,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, party_id),
  FOREIGN KEY (tenant_id, party_id)              REFERENCES parties (tenant_id, id),
  FOREIGN KEY (tenant_id, customer_group_id)     REFERENCES customer_groups (tenant_id, id),
  FOREIGN KEY (tenant_id, parent_customer_id)    REFERENCES customers_dealers (tenant_id, id),
  FOREIGN KEY (tenant_id, home_branch_id)        REFERENCES branches (tenant_id, id),
  FOREIGN KEY (tenant_id, assigned_sales_rep_id) REFERENCES sales_reps (tenant_id, id),
  FOREIGN KEY (tenant_id, route_id)              REFERENCES routes (tenant_id, id),
  FOREIGN KEY (tenant_id, price_list_id)         REFERENCES price_lists (tenant_id, id),
  CHECK (parent_customer_id IS DISTINCT FROM id)
);
CREATE INDEX ix_customers_sr ON customers_dealers (tenant_id, assigned_sales_rep_id);
CREATE INDEX ix_customers_group ON customers_dealers (tenant_id, customer_group_id);
CREATE INDEX ix_customers_overdue ON customers_dealers (tenant_id, current_due_balance DESC) WHERE current_due_balance > 0;

CREATE TABLE route_customers (
  tenant_id      uuid NOT NULL REFERENCES tenants(id),
  route_id       uuid NOT NULL,
  customer_id    uuid NOT NULL,
  visit_sequence smallint NOT NULL DEFAULT 0,
  PRIMARY KEY (route_id, customer_id),
  FOREIGN KEY (tenant_id, route_id)    REFERENCES routes (tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, customer_id) REFERENCES customers_dealers (tenant_id, id) ON DELETE CASCADE
);

ALTER TABLE product_serials
  ADD FOREIGN KEY (tenant_id, sold_to_customer_id) REFERENCES customers_dealers (tenant_id, id);

CREATE TABLE suppliers (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id               uuid NOT NULL REFERENCES tenants(id),
  party_id                uuid NOT NULL,
  supplier_type           varchar(16) NOT NULL DEFAULT 'manufacturer'
                          CHECK (supplier_type IN ('manufacturer', 'importer', 'distributor', 'wholesaler',
                                                   'service', 'clearing_agent', 'transporter', 'other')),
  is_foreign              boolean NOT NULL DEFAULT false,
  default_currency        currency_t NOT NULL DEFAULT 'BDT',
  payment_terms_days      smallint NOT NULL DEFAULT 0,
  credit_limit_granted    amount_t,                  -- how much credit the supplier gives us
  -- maintained ONLY by the payments_ledger trigger (positive = we owe the supplier)
  current_payable_balance amount_t NOT NULL DEFAULT 0,
  bank_details            jsonb NOT NULL DEFAULT '{}'::jsonb,
  version                 integer NOT NULL DEFAULT 1,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, party_id),
  FOREIGN KEY (tenant_id, party_id) REFERENCES parties (tenant_id, id)
);

-- -----------------------------------------------------------------------------
-- Targets & field activity
-- -----------------------------------------------------------------------------
CREATE TABLE sales_targets (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid NOT NULL REFERENCES tenants(id),
  sales_rep_id   uuid NOT NULL,
  period_start   date NOT NULL,
  period_end     date NOT NULL,
  target_metric  varchar(20) NOT NULL
                 CHECK (target_metric IN ('sales_amount', 'sales_quantity', 'collection_amount',
                                          'new_outlets', 'visits', 'lines_per_call')),
  scope_type     varchar(10) NOT NULL DEFAULT 'all' CHECK (scope_type IN ('all', 'category', 'brand', 'product')),
  scope_id       uuid,
  target_value   numeric(18,4) NOT NULL CHECK (target_value > 0),
  achieved_value numeric(18,4) NOT NULL DEFAULT 0,  -- refreshed by a nightly job
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE NULLS NOT DISTINCT (sales_rep_id, period_start, target_metric, scope_type, scope_id),
  FOREIGN KEY (tenant_id, sales_rep_id) REFERENCES sales_reps (tenant_id, id) ON DELETE CASCADE,
  CHECK (period_end >= period_start),
  CHECK ((scope_type = 'all') = (scope_id IS NULL))
);

CREATE TABLE sr_visits (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id              uuid NOT NULL REFERENCES tenants(id),
  sales_rep_id           uuid NOT NULL,
  customer_id            uuid NOT NULL,
  route_id               uuid,
  visit_date             date NOT NULL DEFAULT tenant_today(),
  checked_in_at          timestamptz NOT NULL,
  checked_out_at         timestamptz,
  check_in_lat           numeric(9,6),
  check_in_lng           numeric(9,6),
  distance_from_outlet_m integer,              -- geofence verification
  outcome                varchar(16) NOT NULL
                         CHECK (outcome IN ('order_taken', 'collection', 'order_and_collection', 'no_order',
                                            'shop_closed', 'owner_absent', 'other')),
  notes                  text,
  photo_file_key         text,
  client_ref             uuid NOT NULL,        -- offline-sync idempotency key generated on the phone
  created_at             timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, client_ref),
  FOREIGN KEY (tenant_id, sales_rep_id) REFERENCES sales_reps (tenant_id, id),
  FOREIGN KEY (tenant_id, customer_id)  REFERENCES customers_dealers (tenant_id, id),
  FOREIGN KEY (tenant_id, route_id)     REFERENCES routes (tenant_id, id)
);
CREATE INDEX ix_sr_visits_rep_date ON sr_visits (tenant_id, sales_rep_id, visit_date DESC);
CREATE INDEX ix_sr_visits_customer ON sr_visits (tenant_id, customer_id, visit_date DESC);

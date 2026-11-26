-- =============================================================================
-- AmarDealer DMS · 03 Product catalog (business-agnostic)
--
-- Flexibility levers (no vertical-specific columns in core tables):
--   product_type        stockable | consumable | service | bundle | digital
--   tracking_mode       none | batch | serial | batch_and_serial
--   units + product_uoms  pcs/carton/dozen/kg/bag/ton/litre/feet with per-product factors
--   variants            any attribute axes (color, size, storage, engine CC, pack size)
--   identifier types    chassis/engine/IMEI1/IMEI2/MAC/key-no/serial, tenant-defined
--   custom fields       typed, per entity, optionally per category, stored in jsonb
-- =============================================================================

CREATE TABLE units (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenants(id),
  code            varchar(20) NOT NULL,               -- pcs, ctn, dz, kg, g, bag, ton, ltr, ml, ft, sqft, set, pair, hr
  name            varchar(60) NOT NULL,
  name_bn         varchar(60),
  unit_category   varchar(12) NOT NULL DEFAULT 'count'
                  CHECK (unit_category IN ('count', 'weight', 'volume', 'length', 'area', 'time', 'other')),
  allows_fraction boolean NOT NULL DEFAULT false,     -- kg: true, pcs: false
  is_active       boolean NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code)
);

CREATE TABLE categories (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES tenants(id),
  parent_id   uuid,
  path        ltree NOT NULL,
  code        varchar(40),
  name        varchar(120) NOT NULL,
  name_bn     varchar(120),
  image_file_key text,
  sort_order  integer NOT NULL DEFAULT 0,
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code),
  FOREIGN KEY (tenant_id, parent_id) REFERENCES categories (tenant_id, id)
);
CREATE INDEX ix_categories_path ON categories USING gist (path);
CREATE INDEX ix_categories_parent ON categories (tenant_id, parent_id);
CREATE TRIGGER trg_categories_path BEFORE INSERT OR UPDATE OF parent_id ON categories
  FOR EACH ROW EXECUTE FUNCTION tree_path_before();
CREATE TRIGGER trg_categories_path_cascade AFTER UPDATE OF parent_id ON categories
  FOR EACH ROW WHEN (OLD.path IS DISTINCT FROM NEW.path) EXECUTE FUNCTION tree_path_cascade();

CREATE TABLE brands (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenants(id),
  code              varchar(40),
  name              varchar(120) NOT NULL,
  manufacturer      varchar(160),
  country_of_origin char(2),
  logo_file_key     text,
  is_active         boolean NOT NULL DEFAULT true,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, name)
);

-- -----------------------------------------------------------------------------
-- Taxes (VAT, Supplementary Duty, AIT, AT, ...) composed into tax groups.
-- BD example: "SD 20% + VAT 15%" => SD (seq 1) then VAT (seq 2, compound on base+SD).
-- -----------------------------------------------------------------------------
CREATE TABLE tax_rates (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid NOT NULL REFERENCES tenants(id),
  code           varchar(30) NOT NULL,
  name           varchar(80) NOT NULL,
  tax_kind       varchar(24) NOT NULL
                 CHECK (tax_kind IN ('vat', 'supplementary_duty', 'turnover_tax', 'advance_tax', 'ait',
                                     'customs_duty', 'regulatory_duty', 'vds', 'other')),
  calculation    varchar(16) NOT NULL DEFAULT 'percentage' CHECK (calculation IN ('percentage', 'fixed_per_unit')),
  rate           pct_t,
  fixed_amount   price_t,
  effective_from date NOT NULL DEFAULT DATE '2000-01-01',
  effective_to   date,
  is_active      boolean NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code, effective_from),
  CHECK ((calculation = 'percentage' AND rate IS NOT NULL) OR (calculation = 'fixed_per_unit' AND fixed_amount IS NOT NULL)),
  CHECK (effective_to IS NULL OR effective_to >= effective_from)
);

CREATE TABLE tax_groups (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid NOT NULL REFERENCES tenants(id),
  code           varchar(30) NOT NULL,
  name           varchar(80) NOT NULL,
  is_exempt      boolean NOT NULL DEFAULT false,
  is_zero_rated  boolean NOT NULL DEFAULT false,     -- exports
  is_active      boolean NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code)
);

CREATE TABLE tax_group_rates (
  tenant_id    uuid NOT NULL REFERENCES tenants(id),
  tax_group_id uuid NOT NULL,
  tax_rate_id  uuid NOT NULL,
  sequence     smallint NOT NULL DEFAULT 1,
  is_compound  boolean NOT NULL DEFAULT false,   -- applied on (base + taxes with lower sequence)
  PRIMARY KEY (tax_group_id, tax_rate_id),
  FOREIGN KEY (tenant_id, tax_group_id) REFERENCES tax_groups (tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, tax_rate_id)  REFERENCES tax_rates (tenant_id, id)
);

-- -----------------------------------------------------------------------------
-- Products (template) -> product_variants (the SKU every transaction references)
-- Simple products get exactly one default variant, so all stock / sales / purchase
-- lines always point at variant_id. No special cases downstream.
-- -----------------------------------------------------------------------------
CREATE TABLE products (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id            uuid NOT NULL REFERENCES tenants(id),
  code                 varchar(64) NOT NULL,
  name                 varchar(255) NOT NULL,
  name_bn              varchar(255),
  short_name           varchar(60),                -- thermal POS receipts
  description          text,
  product_type         varchar(16) NOT NULL DEFAULT 'stockable'
                       CHECK (product_type IN ('stockable', 'consumable', 'service', 'bundle', 'digital')),
  tracking_mode        varchar(20) NOT NULL DEFAULT 'none'
                       CHECK (tracking_mode IN ('none', 'batch', 'serial', 'batch_and_serial')),
  category_id          uuid,
  brand_id             uuid,
  base_unit_id         uuid NOT NULL,              -- stock is always held in the base unit
  -- variant axes: [{"key":"color","label":"Color","values":["Red","Black"]},{"key":"storage",...}]
  variant_attributes   jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(variant_attributes) = 'array'),
  hs_code              varchar(20),                -- customs / VAT classification
  tax_group_id         uuid,
  default_sales_price  price_t,
  default_purchase_price price_t,
  mrp                  price_t,                    -- printed Maximum Retail Price (FMCG, pharma)
  warranty_months      smallint CHECK (warranty_months >= 0),
  warranty_terms       text,
  shelf_life_days      integer CHECK (shelf_life_days > 0),
  expiry_alert_days    integer CHECK (expiry_alert_days >= 0),
  min_sale_qty         qty_t CHECK (min_sale_qty > 0),
  reorder_level        qty_t,
  weight_kg            numeric(12,4),
  is_sellable          boolean NOT NULL DEFAULT true,
  is_purchasable       boolean NOT NULL DEFAULT true,
  is_active            boolean NOT NULL DEFAULT true,
  custom_fields        jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(custom_fields) = 'object'),
  image_file_keys      text[] NOT NULL DEFAULT '{}',
  created_by           uuid REFERENCES users(id),
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code),
  FOREIGN KEY (tenant_id, category_id)  REFERENCES categories (tenant_id, id),
  FOREIGN KEY (tenant_id, brand_id)     REFERENCES brands (tenant_id, id),
  FOREIGN KEY (tenant_id, base_unit_id) REFERENCES units (tenant_id, id),
  FOREIGN KEY (tenant_id, tax_group_id) REFERENCES tax_groups (tenant_id, id),
  CHECK (product_type IN ('stockable', 'consumable') OR tracking_mode = 'none')
);
CREATE INDEX ix_products_search ON products USING gin (tenant_id, name gin_trgm_ops);
CREATE INDEX ix_products_category ON products (tenant_id, category_id) WHERE is_active;
CREATE INDEX ix_products_brand ON products (tenant_id, brand_id) WHERE is_active;
CREATE INDEX ix_products_custom_fields ON products USING gin (custom_fields jsonb_path_ops);

-- Unit conversions per product: 1 carton = 24 pcs, 1 bag = 50 kg, 1 ton = 1000 kg ...
CREATE TABLE product_uoms (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid NOT NULL REFERENCES tenants(id),
  product_id            uuid NOT NULL,
  unit_id               uuid NOT NULL,
  factor_to_base        numeric(18,6) NOT NULL CHECK (factor_to_base > 0),
  is_default_sales      boolean NOT NULL DEFAULT false,
  is_default_purchase   boolean NOT NULL DEFAULT false,
  UNIQUE (tenant_id, id),
  UNIQUE (product_id, unit_id),
  FOREIGN KEY (tenant_id, product_id) REFERENCES products (tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, unit_id)    REFERENCES units (tenant_id, id)
);

CREATE TABLE product_variants (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL REFERENCES tenants(id),
  product_id       uuid NOT NULL,
  sku              varchar(64) NOT NULL,
  name             varchar(255) NOT NULL,           -- "Red / 128GB", "XL / Navy", "150cc / Matte Black"
  variant_options  jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(variant_options) = 'object'),
  is_default       boolean NOT NULL DEFAULT false,
  sales_price      price_t,                         -- overrides product default when set
  purchase_price   price_t,
  mrp              price_t,
  weight_kg        numeric(12,4),
  is_active        boolean NOT NULL DEFAULT true,
  custom_fields    jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(custom_fields) = 'object'),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, sku),
  UNIQUE (tenant_id, product_id, variant_options),
  FOREIGN KEY (tenant_id, product_id) REFERENCES products (tenant_id, id)
);
CREATE UNIQUE INDEX ux_variants_one_default ON product_variants (product_id) WHERE is_default;
CREATE INDEX ix_variants_product ON product_variants (tenant_id, product_id);
CREATE INDEX ix_variants_search ON product_variants USING gin (tenant_id, name gin_trgm_ops);

CREATE TABLE product_barcodes (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id  uuid NOT NULL REFERENCES tenants(id),
  variant_id uuid NOT NULL,
  unit_id    uuid,                       -- barcode on the carton vs the piece
  barcode    varchar(64) NOT NULL,
  barcode_type varchar(12) NOT NULL DEFAULT 'ean13' CHECK (barcode_type IN ('ean13', 'ean8', 'upc', 'code128', 'qr', 'internal')),
  UNIQUE (tenant_id, barcode),
  FOREIGN KEY (tenant_id, variant_id) REFERENCES product_variants (tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, unit_id)    REFERENCES units (tenant_id, id)
);

-- Kits / bundles / combo packs (bike + helmet + registration; gift hampers)
CREATE TABLE product_bundle_items (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id            uuid NOT NULL REFERENCES tenants(id),
  bundle_variant_id    uuid NOT NULL,
  component_variant_id uuid NOT NULL,
  quantity             qty_t NOT NULL CHECK (quantity > 0),
  price_allocation_pct pct_t,            -- revenue split for reporting / VAT
  UNIQUE (bundle_variant_id, component_variant_id),
  FOREIGN KEY (tenant_id, bundle_variant_id)    REFERENCES product_variants (tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, component_variant_id) REFERENCES product_variants (tenant_id, id),
  CHECK (bundle_variant_id <> component_variant_id)
);

-- -----------------------------------------------------------------------------
-- Unit-level tracking: batches (lot/expiry) and serials (one physical unit each)
-- -----------------------------------------------------------------------------

-- Tenant-defined identifier kinds: chassis_no, engine_no, imei_1, imei_2, mac, serial_no, key_no ...
CREATE TABLE serial_identifier_types (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenants(id),
  code              varchar(32) NOT NULL CHECK (code ~ '^[a-z][a-z0-9_]*$'),
  label             varchar(60) NOT NULL,
  label_bn          varchar(60),
  validation_regex  varchar(200),               -- IMEI: ^[0-9]{15}$
  normalize         varchar(16) NOT NULL DEFAULT 'upper' CHECK (normalize IN ('none', 'upper', 'digits_only')),
  check_algorithm   varchar(16) CHECK (check_algorithm IN ('luhn')),  -- IMEI check digit
  print_on_invoice  boolean NOT NULL DEFAULT true,
  sort_order        smallint NOT NULL DEFAULT 0,
  is_active         boolean NOT NULL DEFAULT true,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code)
);

-- Which identifiers a serialized product needs (motorbike: chassis*, engine*, key; phone: imei_1*, imei_2)
CREATE TABLE product_identifier_requirements (
  tenant_id          uuid NOT NULL REFERENCES tenants(id),
  product_id         uuid NOT NULL,
  identifier_type_id uuid NOT NULL,
  is_required        boolean NOT NULL DEFAULT true,
  is_primary         boolean NOT NULL DEFAULT false,   -- becomes product_serials.serial_no
  sort_order         smallint NOT NULL DEFAULT 0,
  PRIMARY KEY (product_id, identifier_type_id),
  FOREIGN KEY (tenant_id, product_id)         REFERENCES products (tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, identifier_type_id) REFERENCES serial_identifier_types (tenant_id, id)
);
CREATE UNIQUE INDEX ux_product_identifier_primary ON product_identifier_requirements (product_id) WHERE is_primary;

CREATE TABLE product_batches (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL REFERENCES tenants(id),
  variant_id       uuid NOT NULL,
  batch_no         varchar(64) NOT NULL,
  manufactured_on  date,
  expires_on       date,
  received_at      timestamptz,
  is_blocked       boolean NOT NULL DEFAULT false,   -- recall / quarantine: cannot be sold
  block_reason     text,
  custom_fields    jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, variant_id, batch_no),
  FOREIGN KEY (tenant_id, variant_id) REFERENCES product_variants (tenant_id, id),
  CHECK (expires_on IS NULL OR manufactured_on IS NULL OR expires_on >= manufactured_on)
);
CREATE INDEX ix_batches_expiry ON product_batches (tenant_id, expires_on) WHERE NOT is_blocked;   -- FEFO + expiry alerts

CREATE TYPE serial_status AS ENUM (
  'in_stock', 'reserved', 'in_transit', 'sold', 'consigned', 'in_repair',
  'defective', 'returned_to_supplier', 'scrapped', 'lost'
);

CREATE TABLE product_serials (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid NOT NULL REFERENCES tenants(id),
  variant_id            uuid NOT NULL,
  batch_id              uuid,
  serial_no             varchar(100) NOT NULL,       -- value of the primary identifier (chassis no / IMEI 1 / S/N)
  status                serial_status NOT NULL DEFAULT 'in_stock',
  warehouse_id          uuid,                        -- current custody; NULL once sold / in transit
  location_id           uuid,
  unit_cost             price_t,                     -- exact landed cost of this unit (specific identification)
  grn_item_id           uuid,                        -- FK added in 06_procurement
  received_at           timestamptz,
  reserved_for_order_id uuid,                        -- FK added in 05_sales
  reserved_until        timestamptz,
  sold_invoice_id       uuid,                        -- FK added in 05_sales
  sold_to_customer_id   uuid,                        -- FK added in 04_parties
  sold_at               timestamptz,
  warranty_starts_on    date,
  warranty_ends_on      date,
  custom_fields         jsonb NOT NULL DEFAULT '{}'::jsonb,  -- color code, model year, BRTA reg no, key no ...
  version               integer NOT NULL DEFAULT 1,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, variant_id, serial_no),
  FOREIGN KEY (tenant_id, variant_id)   REFERENCES product_variants (tenant_id, id),
  FOREIGN KEY (tenant_id, batch_id)     REFERENCES product_batches (tenant_id, id),
  FOREIGN KEY (tenant_id, warehouse_id) REFERENCES warehouses (tenant_id, id),
  FOREIGN KEY (tenant_id, location_id)  REFERENCES warehouse_locations (tenant_id, id),
  CHECK (status NOT IN ('in_stock', 'reserved') OR warehouse_id IS NOT NULL),
  CHECK (status <> 'reserved' OR reserved_for_order_id IS NOT NULL),
  CHECK (status <> 'sold' OR sold_invoice_id IS NOT NULL)
);
-- FIFO auto-pick of available units
CREATE INDEX ix_serials_available ON product_serials (tenant_id, variant_id, warehouse_id, received_at)
  WHERE status = 'in_stock';
CREATE INDEX ix_serials_search ON product_serials USING gin (tenant_id, serial_no gin_trgm_ops);
CREATE INDEX ix_serials_customer ON product_serials (tenant_id, sold_to_customer_id) WHERE sold_to_customer_id IS NOT NULL;

-- All identifiers of a unit; uniqueness per identifier type across the whole tenant
-- (the same chassis number can never be received twice, even under another SKU).
CREATE TABLE product_serial_identifiers (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL REFERENCES tenants(id),
  serial_id          uuid NOT NULL,
  identifier_type_id uuid NOT NULL,
  value              varchar(100) NOT NULL,
  UNIQUE (tenant_id, identifier_type_id, value),
  UNIQUE (serial_id, identifier_type_id),
  FOREIGN KEY (tenant_id, serial_id)          REFERENCES product_serials (tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, identifier_type_id) REFERENCES serial_identifier_types (tenant_id, id)
);
CREATE INDEX ix_serial_identifiers_value ON product_serial_identifiers (tenant_id, value);  -- scan any identifier

-- -----------------------------------------------------------------------------
-- Custom fields: tenant-defined typed attributes for any entity, optionally per category.
-- Values live in the entity's custom_fields jsonb; the API validates against these rows.
-- -----------------------------------------------------------------------------
CREATE TABLE custom_field_definitions (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenants(id),
  entity_type   varchar(32) NOT NULL
                CHECK (entity_type IN ('product', 'product_variant', 'product_serial', 'product_batch',
                                       'party', 'customer', 'supplier', 'sales_order', 'invoice', 'invoice_item',
                                       'purchase_order', 'goods_received_note', 'branch', 'warehouse',
                                       'sales_rep', 'warranty_claim', 'installment_schedule', 'delivery')),
  category_id   uuid,                     -- only show for products in this category subtree
  field_key     varchar(64) NOT NULL CHECK (field_key ~ '^[a-z][a-z0-9_]{0,63}$'),
  label         varchar(80) NOT NULL,
  label_bn      varchar(80),
  data_type     varchar(16) NOT NULL
                CHECK (data_type IN ('text', 'long_text', 'integer', 'decimal', 'boolean', 'date', 'datetime',
                                     'select', 'multi_select', 'email', 'phone', 'url', 'file', 'reference')),
  options       jsonb NOT NULL DEFAULT '[]'::jsonb,     -- select choices [{"value":"red","label":"Red"}]
  default_value jsonb,
  validation    jsonb NOT NULL DEFAULT '{}'::jsonb,     -- {"min":0,"max":9999,"regex":"...","maxLength":50}
  is_required   boolean NOT NULL DEFAULT false,
  is_unique     boolean NOT NULL DEFAULT false,         -- backed by an expression index created on demand
  is_searchable boolean NOT NULL DEFAULT false,
  show_on_print boolean NOT NULL DEFAULT false,         -- print on invoice / challan
  show_in_list  boolean NOT NULL DEFAULT false,
  help_text     text,
  sort_order    smallint NOT NULL DEFAULT 0,
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE NULLS NOT DISTINCT (tenant_id, entity_type, category_id, field_key),
  FOREIGN KEY (tenant_id, category_id) REFERENCES categories (tenant_id, id),
  CHECK (category_id IS NULL OR entity_type IN ('product', 'product_variant', 'product_serial', 'product_batch'))
);

-- -----------------------------------------------------------------------------
-- Pricing: multiple price lists (distributor / dealer / retailer / corporate / branch),
-- quantity breaks and validity windows; promotions with a typed jsonb rule payload.
-- -----------------------------------------------------------------------------
CREATE TABLE price_lists (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL REFERENCES tenants(id),
  code             varchar(30) NOT NULL,
  name             varchar(80) NOT NULL,
  price_list_type  varchar(10) NOT NULL DEFAULT 'sales' CHECK (price_list_type IN ('sales', 'purchase')),
  currency         currency_t NOT NULL DEFAULT 'BDT',
  is_tax_inclusive boolean NOT NULL DEFAULT false,
  branch_id        uuid,                    -- branch-specific pricing
  valid_from       date,
  valid_to         date,
  priority         smallint NOT NULL DEFAULT 0,
  is_default       boolean NOT NULL DEFAULT false,
  is_active        boolean NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code),
  FOREIGN KEY (tenant_id, branch_id) REFERENCES branches (tenant_id, id),
  CHECK (valid_to IS NULL OR valid_from IS NULL OR valid_to >= valid_from)
);
CREATE UNIQUE INDEX ux_price_lists_default ON price_lists (tenant_id, price_list_type) WHERE is_default;

CREATE TABLE price_list_items (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenants(id),
  price_list_id uuid NOT NULL,
  variant_id    uuid NOT NULL,
  unit_id       uuid NOT NULL,
  min_quantity  qty_t NOT NULL DEFAULT 1 CHECK (min_quantity > 0),
  price         price_t NOT NULL CHECK (price >= 0),
  min_price     price_t CHECK (min_price >= 0),     -- floor below which a discount needs approval
  valid_from    date,
  valid_to      date,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE NULLS NOT DISTINCT (price_list_id, variant_id, unit_id, min_quantity, valid_from),
  FOREIGN KEY (tenant_id, price_list_id) REFERENCES price_lists (tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, variant_id)    REFERENCES product_variants (tenant_id, id),
  FOREIGN KEY (tenant_id, unit_id)       REFERENCES units (tenant_id, id)
);
CREATE INDEX ix_price_list_items_lookup ON price_list_items (tenant_id, variant_id, price_list_id);

-- rules examples by promotion_type:
--   percent_discount : {"percent": 5}
--   buy_x_get_y      : {"buy_qty": 10, "get_qty": 1, "get_variant_id": "...", "same_item": true}
--   slab_discount    : {"slabs": [{"min_qty": 50, "percent": 2}, {"min_qty": 100, "percent": 3.5}]}
--   free_gift        : {"min_amount": 50000, "gift_variant_id": "...", "gift_qty": 1}
-- eligibility: {"customer_group_ids": [...], "territory_ids": [...], "branch_ids": [...], "channels": ["sr_app"]}
-- applies_to : {"variant_ids": [...], "category_ids": [...], "brand_ids": [...]}  ({} = everything)
CREATE TABLE promotions (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL REFERENCES tenants(id),
  code             varchar(40) NOT NULL,
  name             varchar(120) NOT NULL,
  description      text,
  promotion_type   varchar(20) NOT NULL
                   CHECK (promotion_type IN ('percent_discount', 'amount_discount', 'buy_x_get_y', 'slab_discount',
                                             'free_gift', 'bundle_price', 'cashback')),
  rules            jsonb NOT NULL CHECK (jsonb_typeof(rules) = 'object'),
  eligibility      jsonb NOT NULL DEFAULT '{}'::jsonb,
  applies_to       jsonb NOT NULL DEFAULT '{}'::jsonb,
  starts_at        timestamptz NOT NULL,
  ends_at          timestamptz,
  priority         smallint NOT NULL DEFAULT 0,
  is_stackable     boolean NOT NULL DEFAULT false,
  max_redemptions  integer CHECK (max_redemptions > 0),
  redemptions_count integer NOT NULL DEFAULT 0,
  budget_amount    amount_t,
  is_active        boolean NOT NULL DEFAULT true,
  created_by       uuid REFERENCES users(id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code),
  CHECK (ends_at IS NULL OR ends_at > starts_at)
);
CREATE INDEX ix_promotions_active ON promotions (tenant_id, starts_at, ends_at) WHERE is_active;

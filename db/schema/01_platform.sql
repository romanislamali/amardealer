-- =============================================================================
-- AmarDealer DMS · 01 Platform (SaaS control plane)
-- Global catalogs, tenants, identity, plans, feature limits, subscriptions, billing
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Global reference catalogs (no tenant_id, read-only to tenants)
-- -----------------------------------------------------------------------------

-- Every limit/toggle the platform can sell. New features = new rows, not new columns.
CREATE TABLE feature_catalog (
  feature_key   varchar(64) PRIMARY KEY CHECK (feature_key ~ '^[a-z][a-z0-9_.]*$'),
  kind          varchar(16) NOT NULL CHECK (kind IN ('limit', 'toggle')),
  reset_period  varchar(16) NOT NULL DEFAULT 'none' CHECK (reset_period IN ('none', 'monthly')),
  description   text NOT NULL
);

-- Onboarding blueprints per vertical (motorbike, electronics, FMCG, pharma, apparel, ...).
-- config carries default modules, settings, identifier types, custom fields, units,
-- categories and roles; the onboarding job copies them into the tenant's own tables,
-- after which the tenant can change anything.
CREATE TABLE industry_templates (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code        varchar(48) NOT NULL UNIQUE,
  name        varchar(120) NOT NULL,
  name_bn     varchar(120),
  description text,
  config      jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(config) = 'object'),
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- Bangladesh administrative geography (division > district > upazila/thana > union/ward)
CREATE TABLE geo_areas (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  parent_id  uuid REFERENCES geo_areas(id),
  level      varchar(20) NOT NULL CHECK (level IN ('country', 'division', 'district', 'upazila',
                                                   'thana', 'city_corporation', 'pourashava', 'union', 'ward')),
  code       varchar(20),                 -- BBS geo-code
  name_en    varchar(120) NOT NULL,
  name_bn    varchar(120),
  UNIQUE (level, code)
);
CREATE INDEX ix_geo_areas_parent ON geo_areas (parent_id);

CREATE TABLE permissions (
  code         varchar(96) PRIMARY KEY CHECK (code ~ '^[a-z_]+(\.[a-z_]+)+$'),  -- e.g. sales.invoice.post
  module       varchar(48) NOT NULL,
  description  text NOT NULL,
  is_sensitive boolean NOT NULL DEFAULT false   -- void invoice, edit price, credit override, export ...
);

-- -----------------------------------------------------------------------------
-- Plans
-- -----------------------------------------------------------------------------
CREATE TYPE billing_interval AS ENUM ('monthly', 'quarterly', 'half_yearly', 'yearly');

CREATE TABLE plans (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code        varchar(40) NOT NULL UNIQUE,
  name        varchar(80) NOT NULL,
  description text,
  trial_days  smallint NOT NULL DEFAULT 14 CHECK (trial_days >= 0),
  is_public   boolean NOT NULL DEFAULT true,     -- false = custom/enterprise plan
  is_active   boolean NOT NULL DEFAULT true,
  sort_order  smallint NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE plan_prices (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id          uuid NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
  billing_interval billing_interval NOT NULL,
  price            amount_t NOT NULL CHECK (price >= 0),
  currency         currency_t NOT NULL DEFAULT 'BDT',
  vat_rate         pct_t NOT NULL DEFAULT 15,      -- VAT on the SaaS fee itself
  is_active        boolean NOT NULL DEFAULT true,
  UNIQUE (plan_id, billing_interval, currency)
);

CREATE TABLE plan_features (
  plan_id     uuid NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
  feature_key varchar(64) NOT NULL REFERENCES feature_catalog(feature_key),
  limit_value bigint CHECK (limit_value >= 0),   -- NULL = unlimited (for kind = 'limit')
  is_enabled  boolean NOT NULL DEFAULT true,
  PRIMARY KEY (plan_id, feature_key)
);

-- -----------------------------------------------------------------------------
-- Tenants (companies)
-- -----------------------------------------------------------------------------
CREATE TYPE tenant_status AS ENUM ('provisioning', 'active', 'read_only', 'suspended', 'closed');

CREATE TABLE tenants (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug                    citext NOT NULL UNIQUE
                          CHECK (slug ~ '^[a-z0-9]([a-z0-9-]{0,46}[a-z0-9])?$'
                                 AND slug NOT IN ('www', 'app', 'admin', 'api', 'static', 'cdn', 'mail',
                                                  'status', 'help', 'docs', 'billing', 'auth')),
  custom_domain           citext UNIQUE,
  legal_name              varchar(200) NOT NULL,
  legal_name_bn           varchar(200),
  trade_name              varchar(200),
  business_model          varchar(30) NOT NULL DEFAULT 'distributor'
                          CHECK (business_model IN ('manufacturer', 'importer', 'distributor', 'dealer',
                                                    'wholesaler', 'retailer', 'service_provider', 'mixed')),
  industry_template_id    uuid REFERENCES industry_templates(id),
  industry_tags           text[] NOT NULL DEFAULT '{}',        -- {motorbike,spare_parts,lubricants}
  -- NBR / legal identity
  bin                     bin_t,
  tin                     tin_t,
  trade_license_no        varchar(50),
  vat_registration_type   varchar(20) NOT NULL DEFAULT 'vat_registered'
                          CHECK (vat_registration_type IN ('vat_registered', 'turnover_tax', 'not_registered')),
  -- contact
  email                   citext,
  phone                   phone_t,
  website                 varchar(200),
  address_line1           varchar(200),
  address_line2           varchar(200),
  geo_area_id             uuid REFERENCES geo_areas(id),
  postal_code             varchar(10),
  country_code            char(2) NOT NULL DEFAULT 'BD',
  -- localization
  timezone                varchar(64) NOT NULL DEFAULT 'Asia/Dhaka',
  base_currency           currency_t NOT NULL DEFAULT 'BDT',
  default_locale          varchar(5) NOT NULL DEFAULT 'en' CHECK (default_locale IN ('en', 'bn')),
  fiscal_year_start_month smallint NOT NULL DEFAULT 7 CHECK (fiscal_year_start_month BETWEEN 1 AND 12), -- BD FY: July–June
  logo_file_key           text,
  -- lifecycle (mirrors subscription state; checked by middleware on every request)
  status                  tenant_status NOT NULL DEFAULT 'provisioning',
  status_reason           text,
  suspended_at            timestamptz,
  closed_at               timestamptz,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_tenants_status ON tenants (status);

-- -----------------------------------------------------------------------------
-- Identity: one global user can belong to many tenants (see tenant_memberships)
-- -----------------------------------------------------------------------------
CREATE TABLE users (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email                citext UNIQUE,
  phone                phone_t UNIQUE,
  password_hash        text,                            -- argon2id; NULL for OTP-only users (field SRs)
  full_name            varchar(150) NOT NULL,
  full_name_bn         varchar(150),
  avatar_file_key      text,
  preferred_locale     varchar(5) NOT NULL DEFAULT 'en' CHECK (preferred_locale IN ('en', 'bn')),
  is_active            boolean NOT NULL DEFAULT true,
  email_verified_at    timestamptz,
  phone_verified_at    timestamptz,
  mfa_enabled          boolean NOT NULL DEFAULT false,
  mfa_secret_encrypted bytea,
  last_login_at        timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CHECK (email IS NOT NULL OR phone IS NOT NULL)
);

CREATE TABLE platform_admins (
  user_id    uuid PRIMARY KEY REFERENCES users(id),
  role       varchar(20) NOT NULL CHECK (role IN ('owner', 'admin', 'billing', 'support', 'readonly')),
  is_active  boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- Effective limits per tenant = plan features + Super Admin overrides.
-- Materialized on subscribe / plan change by sync_tenant_limits_from_plan().
-- -----------------------------------------------------------------------------
CREATE TABLE tenant_feature_limits (
  tenant_id       uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  feature_key     varchar(64) NOT NULL REFERENCES feature_catalog(feature_key),
  limit_value     bigint CHECK (limit_value >= 0),     -- NULL = unlimited
  is_enabled      boolean NOT NULL DEFAULT true,
  source          varchar(10) NOT NULL DEFAULT 'plan' CHECK (source IN ('plan', 'override')),
  override_reason text,
  expires_at      timestamptz,                         -- temporary override (e.g. festival season boost)
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, feature_key),
  CHECK (source = 'plan' OR override_reason IS NOT NULL)
);

-- Metered usage (invoices/month, SMS/month, storage). Lifetime counts (branches,
-- users) are counted live from their tables inside enforce_plan_limit().
CREATE TABLE tenant_usage_counters (
  tenant_id    uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  feature_key  varchar(64) NOT NULL REFERENCES feature_catalog(feature_key),
  period_start date NOT NULL,
  used         bigint NOT NULL DEFAULT 0 CHECK (used >= 0),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, feature_key, period_start)
);

-- Tenant-editable configuration (key/value so new knobs need no migration).
-- Examples: inventory.costing_method, inventory.deduct_stock_on, sales.credit_check_mode,
-- sales.allow_below_min_price, print.invoice_template, modules.enabled ...
CREATE TABLE tenant_settings (
  tenant_id   uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  setting_key varchar(96) NOT NULL CHECK (setting_key ~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+)*$'),
  value       jsonb NOT NULL,
  updated_by  uuid REFERENCES users(id),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, setting_key)
);

-- -----------------------------------------------------------------------------
-- Subscriptions & SaaS billing
--   trialing -> active -> past_due -> suspended -> (active | cancelled -> expired)
-- -----------------------------------------------------------------------------
CREATE TYPE subscription_status    AS ENUM ('trialing', 'active', 'past_due', 'suspended', 'cancelled', 'expired');
CREATE TYPE payment_gateway        AS ENUM ('bkash', 'sslcommerz', 'nagad', 'bank_transfer', 'cash', 'complimentary');
CREATE TYPE gateway_payment_status AS ENUM ('initiated', 'pending_verification', 'succeeded', 'failed',
                                             'rejected', 'cancelled', 'refunded');

CREATE TABLE tenant_payment_methods (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id            uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  gateway              payment_gateway NOT NULL,
  status               varchar(16) NOT NULL DEFAULT 'active' CHECK (status IN ('pending', 'active', 'revoked', 'expired')),
  display_label        varchar(80),           -- "bKash 017XX-XXX678", "Visa •••• 4242"
  gateway_customer_ref varchar(120),
  gateway_token_ref    varchar(255),          -- bKash Tokenized agreementID / SSLCOMMERZ token reference
  token_encrypted      bytea,                 -- envelope-encrypted with KMS key; never plaintext
  is_default           boolean NOT NULL DEFAULT false,
  expires_at           timestamptz,
  created_by           uuid REFERENCES users(id),
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id)
);
CREATE UNIQUE INDEX ux_tenant_payment_methods_default ON tenant_payment_methods (tenant_id) WHERE is_default AND status = 'active';

CREATE TABLE subscriptions (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                 uuid NOT NULL REFERENCES tenants(id),
  plan_id                   uuid NOT NULL REFERENCES plans(id),
  plan_price_id             uuid NOT NULL REFERENCES plan_prices(id),
  status                    subscription_status NOT NULL DEFAULT 'trialing',
  locked_price              amount_t NOT NULL,              -- price agreed at signup (grandfathering)
  currency                  currency_t NOT NULL DEFAULT 'BDT',
  trial_ends_at             timestamptz,
  current_period_start      timestamptz NOT NULL,
  current_period_end        timestamptz NOT NULL,
  grace_period_ends_at      timestamptz,                    -- set on entering past_due
  auto_renew                boolean NOT NULL DEFAULT true,
  cancel_at_period_end      boolean NOT NULL DEFAULT false,
  default_payment_method_id uuid,
  cancelled_at              timestamptz,
  suspended_at              timestamptz,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, default_payment_method_id) REFERENCES tenant_payment_methods (tenant_id, id),
  CHECK (current_period_end > current_period_start),
  CHECK (status <> 'trialing' OR trial_ends_at IS NOT NULL),
  CHECK (status <> 'past_due' OR grace_period_ends_at IS NOT NULL)
);
-- exactly one live subscription per tenant
CREATE UNIQUE INDEX ux_subscriptions_one_live ON subscriptions (tenant_id) WHERE status NOT IN ('cancelled', 'expired');
CREATE INDEX ix_subscriptions_renewal ON subscriptions (status, current_period_end);

CREATE TABLE subscription_status_history (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenants(id),
  subscription_id uuid NOT NULL,
  from_status     subscription_status,
  to_status       subscription_status NOT NULL,
  reason          varchar(64) NOT NULL,    -- payment_succeeded, trial_expired, grace_expired, admin_manual ...
  actor_user_id   uuid REFERENCES users(id),
  occurred_at     timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (tenant_id, subscription_id) REFERENCES subscriptions (tenant_id, id)
);
CREATE INDEX ix_sub_status_history ON subscription_status_history (tenant_id, subscription_id, occurred_at);

CREATE TABLE subscription_invoices (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenants(id),
  subscription_id uuid NOT NULL,
  invoice_no      varchar(40) NOT NULL UNIQUE,        -- platform-wide numbering, e.g. AD-2026-000123
  period_start    timestamptz NOT NULL,
  period_end      timestamptz NOT NULL,
  issue_date      date NOT NULL,
  due_date        date NOT NULL,
  subtotal        amount_t NOT NULL CHECK (subtotal >= 0),
  discount_amount amount_t NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
  vat_rate        pct_t NOT NULL DEFAULT 15,
  vat_amount      amount_t NOT NULL DEFAULT 0,
  total_amount    amount_t NOT NULL CHECK (total_amount >= 0),
  amount_paid     amount_t NOT NULL DEFAULT 0 CHECK (amount_paid >= 0),
  currency        currency_t NOT NULL DEFAULT 'BDT',
  status          varchar(16) NOT NULL DEFAULT 'open'
                  CHECK (status IN ('draft', 'open', 'paid', 'void', 'uncollectible')),
  paid_at         timestamptz,
  voided_at       timestamptz,
  pdf_file_key    text,
  notes           text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, subscription_id) REFERENCES subscriptions (tenant_id, id),
  CHECK (total_amount = subtotal - discount_amount + vat_amount),
  CHECK (status <> 'paid' OR paid_at IS NOT NULL)
);
CREATE INDEX ix_sub_invoices_tenant ON subscription_invoices (tenant_id, issue_date DESC);
CREATE INDEX ix_sub_invoices_open ON subscription_invoices (due_date) WHERE status = 'open';

-- One row per payment attempt: bKash/SSLCOMMERZ callbacks or manual bank-transfer proof.
CREATE TABLE subscription_payments (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id               uuid NOT NULL REFERENCES tenants(id),
  subscription_invoice_id uuid NOT NULL,
  payment_method_id       uuid,
  gateway                 payment_gateway NOT NULL,
  amount                  amount_t NOT NULL CHECK (amount > 0),
  currency                currency_t NOT NULL DEFAULT 'BDT',
  status                  gateway_payment_status NOT NULL DEFAULT 'initiated',
  idempotency_key         uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  gateway_payment_id      varchar(120),        -- bKash paymentID / SSLCOMMERZ sessionkey
  gateway_trx_id          varchar(120),        -- bKash trxID / SSLCOMMERZ bank_tran_id
  -- manual bank transfer
  bank_name               varchar(120),
  bank_reference          varchar(120),
  deposit_date            date,
  proof_file_key          text,
  submitted_by            uuid REFERENCES users(id),
  verified_by             uuid REFERENCES users(id),   -- platform admin
  verified_at             timestamptz,
  rejection_reason        text,
  raw_response            jsonb,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  UNIQUE (gateway, gateway_trx_id),
  FOREIGN KEY (tenant_id, subscription_invoice_id) REFERENCES subscription_invoices (tenant_id, id),
  FOREIGN KEY (tenant_id, payment_method_id) REFERENCES tenant_payment_methods (tenant_id, id),
  CHECK (gateway <> 'bank_transfer' OR status = 'initiated' OR bank_reference IS NOT NULL),
  CHECK (status <> 'rejected' OR rejection_reason IS NOT NULL)
);
CREATE INDEX ix_sub_payments_verify_queue ON subscription_payments (created_at) WHERE status = 'pending_verification';
CREATE INDEX ix_sub_payments_tenant ON subscription_payments (tenant_id, created_at DESC);

-- Raw webhook/IPN inbox: dedupes gateway retries (exactly-once processing).
CREATE TABLE payment_gateway_events (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  gateway          payment_gateway NOT NULL,
  event_id         varchar(160) NOT NULL,
  event_type       varchar(80),
  payload          jsonb NOT NULL,
  signature_valid  boolean NOT NULL,
  received_at      timestamptz NOT NULL DEFAULT now(),
  processed_at     timestamptz,
  processing_error text,
  UNIQUE (gateway, event_id)
);

CREATE TABLE backup_runs (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  backup_type    varchar(16) NOT NULL CHECK (backup_type IN ('full', 'incremental', 'wal_check', 'tenant_export', 'restore_test')),
  tenant_id      uuid REFERENCES tenants(id),       -- set only for per-tenant exports
  status         varchar(12) NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'succeeded', 'failed')),
  storage_uri    text,
  size_bytes     bigint,
  sha256         char(64),
  started_at     timestamptz NOT NULL DEFAULT now(),
  finished_at    timestamptz,
  error          text
);

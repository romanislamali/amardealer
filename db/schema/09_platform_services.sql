-- =============================================================================
-- AmarDealer DMS · 09 Cross-cutting services: attachments, notifications/SMS,
-- transactional outbox for workers, API keys, bulk import jobs
-- =============================================================================

CREATE TABLE attachments (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES tenants(id),
  entity_type varchar(32) NOT NULL,             -- invoice, party, product_serial, grn, warranty_claim ...
  entity_id   uuid NOT NULL,
  file_key    text NOT NULL,                    -- object-storage key: {tenant_id}/{entity_type}/{uuid}.{ext}
  file_name   varchar(255) NOT NULL,
  mime_type   varchar(100) NOT NULL,
  size_bytes  bigint NOT NULL CHECK (size_bytes >= 0),
  category    varchar(40),                      -- nid_front, trade_license, delivery_proof, bank_slip ...
  uploaded_by uuid REFERENCES users(id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id)
);
CREATE INDEX ix_attachments_entity ON attachments (tenant_id, entity_type, entity_id);

-- tenant_id NULL = platform default template; a tenant row with the same key overrides it.
CREATE TABLE notification_templates (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid REFERENCES tenants(id),
  event_key   varchar(64) NOT NULL,             -- invoice.posted, payment.received, installment.due, credit.overdue ...
  channel     varchar(10) NOT NULL CHECK (channel IN ('sms', 'email', 'push', 'whatsapp')),
  locale      varchar(5) NOT NULL DEFAULT 'bn' CHECK (locale IN ('en', 'bn')),
  subject     varchar(200),
  body        text NOT NULL,                    -- "প্রিয় {{customer_name}}, আপনার {{amount}} টাকা জমা হয়েছে।"
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE NULLS NOT DISTINCT (tenant_id, event_key, channel, locale)
);

CREATE TABLE sms_messages (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid NOT NULL REFERENCES tenants(id),
  to_phone            phone_t NOT NULL,
  body                text NOT NULL,
  is_unicode          boolean NOT NULL DEFAULT true,    -- Bangla => UCS-2, 70 chars/segment
  segments            smallint NOT NULL DEFAULT 1,
  message_type        varchar(14) NOT NULL DEFAULT 'transactional' CHECK (message_type IN ('transactional', 'promotional', 'otp')),
  event_key           varchar(64),
  related_entity_type varchar(32),
  related_entity_id   uuid,
  campaign_id         uuid,                              -- bulk campaign grouping
  provider            varchar(30),                       -- SSL Wireless, BulkSMSBD, Infobip ...
  provider_message_id varchar(120),
  status              varchar(12) NOT NULL DEFAULT 'queued'
                      CHECK (status IN ('queued', 'sending', 'sent', 'delivered', 'failed', 'cancelled')),
  attempts            smallint NOT NULL DEFAULT 0,
  error               text,
  scheduled_at        timestamptz,
  sent_at             timestamptz,
  delivered_at        timestamptz,
  created_by          uuid REFERENCES users(id),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id)
);
CREATE INDEX ix_sms_tenant_date ON sms_messages (tenant_id, created_at DESC);
CREATE INDEX ix_sms_pending ON sms_messages (scheduled_at) WHERE status = 'queued';
CREATE INDEX ix_sms_campaign ON sms_messages (tenant_id, campaign_id) WHERE campaign_id IS NOT NULL;

-- Transactional outbox: written in the SAME transaction as the business change;
-- a relay publishes rows to the queue (BullMQ / RabbitMQ) and stamps published_at.
-- Guarantees "invoice committed <=> PDF + SMS job enqueued" with no dual-write gap.
CREATE TABLE outbox_events (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id      uuid NOT NULL REFERENCES tenants(id),
  event_type     varchar(64) NOT NULL,              -- invoice.posted, payment.posted, stock.low ...
  aggregate_type varchar(32) NOT NULL,
  aggregate_id   uuid NOT NULL,
  payload        jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at     timestamptz NOT NULL DEFAULT now(),
  published_at   timestamptz,
  attempts       smallint NOT NULL DEFAULT 0,
  last_error     text
);
CREATE INDEX ix_outbox_unpublished ON outbox_events (id) WHERE published_at IS NULL;

CREATE TABLE api_keys (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL REFERENCES tenants(id),
  name         varchar(80) NOT NULL,
  key_prefix   varchar(12) NOT NULL,              -- shown in UI: "ad_live_3fA9"
  key_hash     char(64) NOT NULL UNIQUE,          -- sha256 of the secret; secret shown once
  scopes       text[] NOT NULL DEFAULT '{}',      -- permission codes
  last_used_at timestamptz,
  expires_at   timestamptz,
  revoked_at   timestamptz,
  created_by   uuid REFERENCES users(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id)
);

-- Bulk onboarding: products, opening stock, serials, customers, opening balances from Excel/CSV
CREATE TABLE import_jobs (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL REFERENCES tenants(id),
  entity_type      varchar(32) NOT NULL
                   CHECK (entity_type IN ('products', 'product_variants', 'opening_stock', 'serials', 'customers',
                                          'suppliers', 'opening_balances', 'price_list_items', 'territories')),
  file_key         text NOT NULL,
  column_mapping   jsonb NOT NULL DEFAULT '{}'::jsonb,
  mode             varchar(8) NOT NULL DEFAULT 'insert' CHECK (mode IN ('insert', 'upsert', 'validate')),
  status           varchar(12) NOT NULL DEFAULT 'queued'
                   CHECK (status IN ('queued', 'validating', 'importing', 'completed', 'failed', 'cancelled')),
  total_rows       integer,
  processed_rows   integer NOT NULL DEFAULT 0,
  failed_rows      integer NOT NULL DEFAULT 0,
  error_report_key text,
  created_by       uuid REFERENCES users(id),
  started_at       timestamptz,
  finished_at      timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id)
);

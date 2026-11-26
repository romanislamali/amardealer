-- =============================================================================
-- AmarDealer DMS · 00 Foundation
-- Extensions, database roles, domains, session-context helpers, generic triggers
-- Target: PostgreSQL 15+ (verified on 18). Run as a superuser / migration owner.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- digest(), gen_random_bytes()
CREATE EXTENSION IF NOT EXISTS citext;     -- case-insensitive email/slug
CREATE EXTENSION IF NOT EXISTS pg_trgm;    -- fuzzy product / party search
CREATE EXTENSION IF NOT EXISTS btree_gin;  -- (tenant_id, name gin_trgm_ops) composite GIN
CREATE EXTENSION IF NOT EXISTS ltree;      -- arbitrary-depth hierarchies (territories, categories)

CREATE SCHEMA IF NOT EXISTS audit;

-- -----------------------------------------------------------------------------
-- Database roles
--   dms_owner    : owns every object, runs migrations. BYPASSRLS. Never used by app code.
--   dms_app      : API runtime. NOBYPASSRLS -> every query is filtered by RLS.
--   dms_worker   : tenant-scoped background jobs (SMS, PDF, imports). NOBYPASSRLS.
--   dms_auth     : identity service (login, workspace switcher, tenant resolver).
--                  BYPASSRLS but GRANTed only a handful of identity tables.
--   dms_platform : Super Admin portal + platform jobs (billing, dunning, backups). BYPASSRLS.
-- BYPASSRLS is a role attribute and is NOT inherited through membership, so these are
-- LOGIN roles; ops sets passwords out-of-band: ALTER ROLE dms_app PASSWORD '...';
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dms_owner')    THEN CREATE ROLE dms_owner    LOGIN BYPASSRLS;   END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dms_app')      THEN CREATE ROLE dms_app      LOGIN NOBYPASSRLS; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dms_worker')   THEN CREATE ROLE dms_worker   LOGIN NOBYPASSRLS; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dms_auth')     THEN CREATE ROLE dms_auth     LOGIN BYPASSRLS;   END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dms_platform') THEN CREATE ROLE dms_platform LOGIN BYPASSRLS;   END IF;
END $$;

-- -----------------------------------------------------------------------------
-- Domains: one definition of "money", "quantity", etc. for the whole schema
-- -----------------------------------------------------------------------------
CREATE DOMAIN amount_t   AS NUMERIC(15,2);                       -- BDT money (document totals, balances)
CREATE DOMAIN price_t    AS NUMERIC(15,4);                       -- unit price / unit cost (per-gram, per-ml pricing)
CREATE DOMAIN qty_t      AS NUMERIC(18,4);                       -- quantities: pcs, kg, litre, ton, metre, sqft
CREATE DOMAIN pct_t      AS NUMERIC(7,4)  CHECK (VALUE >= 0 AND VALUE <= 100);
CREATE DOMAIN fx_rate_t  AS NUMERIC(18,8) CHECK (VALUE > 0);     -- import purchases in USD/CNY/INR
CREATE DOMAIN currency_t AS CHAR(3)       CHECK (VALUE ~ '^[A-Z]{3}$');
CREATE DOMAIN phone_t    AS VARCHAR(16)   CHECK (VALUE ~ '^\+[1-9][0-9]{6,14}$');  -- E.164, e.g. +8801712345678
CREATE DOMAIN bin_t      AS VARCHAR(13)   CHECK (VALUE ~ '^[0-9]{9}([0-9]{4})?$');  -- NBR BIN (9 or 13 digits)
CREATE DOMAIN tin_t      AS VARCHAR(12)   CHECK (VALUE ~ '^[0-9]{12}$');            -- e-TIN
CREATE DOMAIN nid_t      AS VARCHAR(17)   CHECK (VALUE ~ '^([0-9]{10}|[0-9]{13}|[0-9]{17})$');

-- -----------------------------------------------------------------------------
-- Request context. The API sets these with set_config(..., is_local => true)
-- inside every transaction, so they vanish at COMMIT/ROLLBACK and can never
-- leak to the next request that reuses the pooled connection.
-- -----------------------------------------------------------------------------
CREATE FUNCTION current_tenant_id() RETURNS uuid
LANGUAGE sql STABLE PARALLEL SAFE AS
$$ SELECT NULLIF(current_setting('app.current_tenant_id', true), '')::uuid $$;

CREATE FUNCTION current_app_user_id() RETURNS uuid
LANGUAGE sql STABLE PARALLEL SAFE AS
$$ SELECT NULLIF(current_setting('app.current_user_id', true), '')::uuid $$;

-- Business date in the tenant's timezone (Asia/Dhaka unless the tenant says otherwise).
CREATE FUNCTION tenant_today() RETURNS date
LANGUAGE sql STABLE AS
$$ SELECT (now() AT TIME ZONE COALESCE(NULLIF(current_setting('app.tenant_timezone', true), ''), 'Asia/Dhaka'))::date $$;

-- -----------------------------------------------------------------------------
-- Custom SQLSTATEs raised by business-rule triggers (API maps them to HTTP errors)
--   DL001 PLAN_LIMIT_REACHED      DL002 FEATURE_DISABLED     DL003 LIMIT_NOT_CONFIGURED
--   DL010 APPEND_ONLY_VIOLATION   DL020 TENANT_CONTEXT_MISSING
--   DL030 HIERARCHY_INVALID       DL040 NUMBERING_NOT_CONFIGURED
--   DL050 PARTY_BALANCE_NOT_FOUND
-- Constraint names to map: stock_balances_non_negative -> INSUFFICIENT_STOCK,
--   ux_invoice_item_serials_active -> SERIAL_ALREADY_SOLD
-- -----------------------------------------------------------------------------

CREATE FUNCTION set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS
$$ BEGIN NEW.updated_at := now(); RETURN NEW; END $$;

CREATE FUNCTION forbid_mutation() RETURNS trigger
LANGUAGE plpgsql AS
$$
BEGIN
  RAISE EXCEPTION USING
    ERRCODE = 'DL010',
    MESSAGE = format('%I.%I is append-only: %s is not allowed. Post a reversing entry instead.',
                     TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP);
END
$$;

-- -----------------------------------------------------------------------------
-- Generic ltree path maintenance for self-referencing (tenant_id, id, parent_id, path)
-- tables. Gives unlimited-depth hierarchies (Zone > Region > Area > Territory > Route,
-- or Category > Sub-category > ...) with O(1) subtree queries: WHERE path <@ :node_path
-- -----------------------------------------------------------------------------
CREATE FUNCTION tree_path_before() RETURNS trigger
LANGUAGE plpgsql AS
$$
DECLARE
  v_label  text := replace(NEW.id::text, '-', '_');
  v_parent ltree;
BEGIN
  IF NEW.parent_id IS NULL THEN
    NEW.path := text2ltree(v_label);
  ELSE
    IF NEW.parent_id = NEW.id THEN
      RAISE EXCEPTION USING ERRCODE = 'DL030', MESSAGE = 'A node cannot be its own parent';
    END IF;
    EXECUTE format('SELECT path FROM %I.%I WHERE id = $1 AND tenant_id = $2', TG_TABLE_SCHEMA, TG_TABLE_NAME)
      INTO v_parent USING NEW.parent_id, NEW.tenant_id;
    IF v_parent IS NULL THEN
      RAISE EXCEPTION USING ERRCODE = 'DL030', MESSAGE = format('Parent %s not found in this tenant', NEW.parent_id);
    END IF;
    IF v_parent ~ ('*.' || v_label || '.*')::lquery THEN
      RAISE EXCEPTION USING ERRCODE = 'DL030', MESSAGE = 'Moving a node under its own descendant creates a cycle';
    END IF;
    NEW.path := v_parent || text2ltree(v_label);
  END IF;
  RETURN NEW;
END
$$;

-- After a node moves, re-parent its direct children with a no-op update; their
-- BEFORE trigger recomputes their path and this trigger recurses down the subtree.
CREATE FUNCTION tree_path_cascade() RETURNS trigger
LANGUAGE plpgsql AS
$$
BEGIN
  EXECUTE format('UPDATE %I.%I SET parent_id = parent_id WHERE tenant_id = $1 AND parent_id = $2',
                 TG_TABLE_SCHEMA, TG_TABLE_NAME)
    USING NEW.tenant_id, NEW.id;
  RETURN NULL;
END
$$;

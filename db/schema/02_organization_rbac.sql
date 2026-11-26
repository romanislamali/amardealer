-- =============================================================================
-- AmarDealer DMS · 02 Organization structure & RBAC (tenant-scoped)
--
-- Convention for every tenant-scoped table in this schema:
--   * tenant_id uuid NOT NULL, denormalized onto child rows so RLS never needs a join
--   * UNIQUE (tenant_id, id) so children reference (tenant_id, parent_id).
--     Foreign-key checks bypass RLS; composite FKs make a cross-tenant reference
--     impossible even if application code passes another tenant's UUID.
-- =============================================================================

-- Sales/geographic hierarchy with tenant-defined depth and labels:
-- FMCG: National > Zone > Region > Area > Territory > Market
-- Motorbike: Division > Dealer Zone
CREATE TABLE territories (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES tenants(id),
  parent_id   uuid,
  path        ltree NOT NULL,
  level_label varchar(40) NOT NULL,          -- "Zone", "Region", "Area", "Territory" ...
  code        varchar(40) NOT NULL,
  name        varchar(120) NOT NULL,
  name_bn     varchar(120),
  geo_area_id uuid REFERENCES geo_areas(id),
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code),
  FOREIGN KEY (tenant_id, parent_id) REFERENCES territories (tenant_id, id)
);
CREATE INDEX ix_territories_path ON territories USING gist (path);
CREATE INDEX ix_territories_parent ON territories (tenant_id, parent_id);
CREATE TRIGGER trg_territories_path BEFORE INSERT OR UPDATE OF parent_id ON territories
  FOR EACH ROW EXECUTE FUNCTION tree_path_before();
CREATE TRIGGER trg_territories_path_cascade AFTER UPDATE OF parent_id ON territories
  FOR EACH ROW WHEN (OLD.path IS DISTINCT FROM NEW.path) EXECUTE FUNCTION tree_path_cascade();

CREATE TABLE branches (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id            uuid NOT NULL REFERENCES tenants(id),
  parent_branch_id     uuid,                     -- HQ > regional office > branch
  code                 varchar(20) NOT NULL CHECK (code ~ '^[A-Z0-9_-]+$'),  -- used in document numbers {BR}
  name                 varchar(120) NOT NULL,
  name_bn              varchar(120),
  branch_type          varchar(24) NOT NULL DEFAULT 'branch'
                       CHECK (branch_type IN ('head_office', 'regional_office', 'branch', 'showroom', 'depot',
                                              'service_center', 'factory', 'outlet', 'franchise')),
  vat_unit_bin         bin_t,                    -- BIN for unit-registered branches (13-digit)
  is_central_vat_registered boolean NOT NULL DEFAULT true,
  territory_id         uuid,
  phone                phone_t,
  email                citext,
  address_line1        varchar(200),
  address_line2        varchar(200),
  geo_area_id          uuid REFERENCES geo_areas(id),
  latitude             numeric(9,6),
  longitude            numeric(9,6),
  is_active            boolean NOT NULL DEFAULT true,
  custom_fields        jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code),
  FOREIGN KEY (tenant_id, parent_branch_id) REFERENCES branches (tenant_id, id),
  FOREIGN KEY (tenant_id, territory_id) REFERENCES territories (tenant_id, id),
  CHECK (parent_branch_id IS DISTINCT FROM id)
);
CREATE INDEX ix_branches_tenant_active ON branches (tenant_id) WHERE is_active;

CREATE TABLE warehouses (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id            uuid NOT NULL REFERENCES tenants(id),
  branch_id            uuid NOT NULL,
  code                 varchar(20) NOT NULL,
  name                 varchar(120) NOT NULL,
  warehouse_type       varchar(20) NOT NULL DEFAULT 'main'
                       CHECK (warehouse_type IN ('main', 'showroom', 'transit', 'van', 'consignment',
                                                 'damaged', 'quarantine', 'service', 'virtual')),
  is_sellable          boolean NOT NULL DEFAULT true,    -- false for damaged/quarantine
  allow_negative_stock boolean NOT NULL DEFAULT false,
  address_line1        varchar(200),
  geo_area_id          uuid REFERENCES geo_areas(id),
  is_active            boolean NOT NULL DEFAULT true,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code),
  FOREIGN KEY (tenant_id, branch_id) REFERENCES branches (tenant_id, id)
);
CREATE INDEX ix_warehouses_branch ON warehouses (tenant_id, branch_id);

-- Optional bin/rack/shelf locations inside a warehouse
CREATE TABLE warehouse_locations (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL REFERENCES tenants(id),
  warehouse_id uuid NOT NULL,
  parent_id    uuid,
  code         varchar(40) NOT NULL,                 -- "A-01-03"
  name         varchar(120),
  is_active    boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, warehouse_id, code),
  FOREIGN KEY (tenant_id, warehouse_id) REFERENCES warehouses (tenant_id, id),
  FOREIGN KEY (tenant_id, parent_id) REFERENCES warehouse_locations (tenant_id, id)
);

-- -----------------------------------------------------------------------------
-- RBAC: global permission catalog -> per-tenant roles -> memberships (optionally branch-scoped)
-- -----------------------------------------------------------------------------
CREATE TABLE roles (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES tenants(id),
  code        varchar(48) NOT NULL CHECK (code ~ '^[a-z][a-z0-9_]*$'),
  name        varchar(80) NOT NULL,
  description text,
  is_system   boolean NOT NULL DEFAULT false,   -- seeded (owner/admin); cannot be deleted
  data_scope  varchar(16) NOT NULL DEFAULT 'branch'
              CHECK (data_scope IN ('tenant', 'branch', 'territory', 'own')),  -- row visibility inside the tenant
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code)
);

CREATE TABLE role_permissions (
  tenant_id       uuid NOT NULL REFERENCES tenants(id),
  role_id         uuid NOT NULL,
  permission_code varchar(96) NOT NULL REFERENCES permissions(code),
  PRIMARY KEY (role_id, permission_code),
  FOREIGN KEY (tenant_id, role_id) REFERENCES roles (tenant_id, id) ON DELETE CASCADE
);
CREATE INDEX ix_role_permissions_tenant ON role_permissions (tenant_id, role_id);

CREATE TYPE membership_status AS ENUM ('invited', 'active', 'disabled');

CREATE TABLE tenant_memberships (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenants(id),
  user_id           uuid NOT NULL REFERENCES users(id),
  status            membership_status NOT NULL DEFAULT 'invited',
  is_owner          boolean NOT NULL DEFAULT false,
  default_branch_id uuid,
  job_title         varchar(80),
  employee_code     varchar(40),
  invited_by        uuid REFERENCES users(id),
  invited_at        timestamptz,
  joined_at         timestamptz,
  last_active_at    timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, user_id),
  FOREIGN KEY (tenant_id, default_branch_id) REFERENCES branches (tenant_id, id)
);
CREATE INDEX ix_memberships_user ON tenant_memberships (user_id) WHERE status = 'active';   -- workspace switcher
CREATE UNIQUE INDEX ux_memberships_one_owner ON tenant_memberships (tenant_id) WHERE is_owner;

-- branch_id NULL = role applies to all branches; otherwise only to that branch.
CREATE TABLE membership_roles (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenants(id),
  membership_id uuid NOT NULL,
  role_id       uuid NOT NULL,
  branch_id     uuid,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE NULLS NOT DISTINCT (membership_id, role_id, branch_id),
  FOREIGN KEY (tenant_id, membership_id) REFERENCES tenant_memberships (tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, role_id) REFERENCES roles (tenant_id, id),
  FOREIGN KEY (tenant_id, branch_id) REFERENCES branches (tenant_id, id)
);
CREATE INDEX ix_membership_roles_member ON membership_roles (tenant_id, membership_id);

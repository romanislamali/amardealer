-- =============================================================================
-- AmarDealer DMS · full schema entry point
--   psql -v ON_ERROR_STOP=1 -d amardealer -f db/schema.sql
--   psql -v ON_ERROR_STOP=1 -d amardealer -f db/seed/reference_data.sql
-- Each file is also usable as an ordered migration (00 -> 12).
-- =============================================================================
\set ON_ERROR_STOP on
BEGIN;
\ir schema/00_foundation.sql
\ir schema/01_platform.sql
\ir schema/02_organization_rbac.sql
\ir schema/03_catalog.sql
\ir schema/04_parties_sales_force.sql
\ir schema/05_sales.sql
\ir schema/06_procurement.sql
\ir schema/07_inventory.sql
\ir schema/08_finance.sql
\ir schema/09_platform_services.sql
\ir schema/10_business_rules.sql
\ir schema/11_audit.sql
\ir schema/12_security_rls.sql
COMMIT;

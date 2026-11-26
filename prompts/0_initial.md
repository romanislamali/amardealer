Act as a Principal Software Architect and Senior Database Engineer. I am building a multi-tenant Dealership Management System (DMS) SaaS product from scratch, targeting dealerships and distributors in Bangladesh (e.g., automotive/motorbikes, electronics, and FMCG distribution). I am the product owner and will register multiple independent companies onto this platform on a recurring subscription basis.
Design a complete, production-ready system architecture and a normalized PostgreSQL database schema for this SaaS platform.

1. System Architecture Requirements

• Multi-Tenancy Strategy: Use a shared database with strict tenant isolation via PostgreSQL Row-Level Security (RLS) and tenant_id (company_id). Explain how the application middleware sets app.current_tenant_id per request/transaction so data leaks between companies are impossible.
• Tenant Routing & Identity: Support both subdomain routing (://app.com) and a central login workspace switcher, plus a Super Admin portal for me to manage tenants, subscription plans, feature limits, and account suspensions.
• Bangladesh-Specific Localization:
	• Currency in BDT (DECIMAL(15, 2)), timezone handling (Asia/Dhaka), and NBR VAT compliance (Mushak 6.3 challan tracking, BIN/TIN fields).
	• Subscription billing state machine (trial, active, past_due, suspended) supporting automated recurring payments (bKash Tokenized Checkout / SSLCOMMERZ) as well as manual bank transfer verification by the Super Admin.
	• Asynchronous background job architecture (queues/workers) for bulk SMS alerts, invoice PDF generation, and daily off-site backups.

2. Core Functional Modules to Model

Design the architecture and database tables to support:
1. SaaS & Subscription Management: plans, tenants (companies), subscriptions, subscription_invoices, tenant_feature_limits (max branches, max users, max monthly invoices).
2. RBAC & Organization Structure: Multi-branch/warehouse hierarchy (branches, warehouses), users (supporting users belonging to multiple tenants if needed), roles, and granular permissions.
3. Product & Serialized Inventory: products, categories, brands, stock_balances (per warehouse), stock_transfers, and product_serials (for tracking chassis numbers, engine numbers, IMEI, or batch/expiry dates).
4. Dealers, Sales Reps (SR), & Credit Control: customers_dealers (with credit limits and current due balances), sales_reps (field order collection and route/area assignment), sales_orders, invoices (supporting cash, credit/due, and EMI/installment schedules), and payments_ledger.
5. Procurement & Suppliers: suppliers, purchase_orders, and goods_received_notes (GRN).
6. Audit & Compliance: Immutable audit_logs tracking who created, modified, or deleted financial and stock records.

3. Expected Output Format

Please structure your response clearly with:
1. High-Level Architecture Diagram (using ASCII or Mermaid.js) showing client apps, API gateway/tenant resolver, backend services, background workers, Redis cache, and PostgreSQL with RLS.
2. Complete PostgreSQL DDL Script (CREATE TABLE statements):
	• Use UUID primary keys (gen_random_uuid()), proper foreign keys, TIMESTAMPTZ timestamps, and ENUM types or CHECK constraints.
	• Include composite indexes optimized for multi-tenant queries ((tenant_id, ...)).
	• Include explicit PostgreSQL Row-Level Security (RLS) policies (ENABLE ROW LEVEL SECURITY and CREATE POLICY) on tenant-scoped tables.
3. Critical Transaction Flows: Briefly explain the database transaction logic (locking/ACID handling) for:
	• Preventing overselling serialized stock (chassis/IMEI) during concurrent invoicing.
	• Enforcing subscription plan limits (e.g., blocking new branch creation when a tenant hits their plan limit).
If you'd like to customize this prompt further before running it, let me know:
• Your backend framework (e.g., Laravel, Node.js/NestJS, Django, Go) so I can include framework-specific ORM/RLS integration instructions
• Whether you want to focus strictly on vehicle/motorbike dealerships or general FMCG distribution
I can refine the prompt to match your exact codebase.
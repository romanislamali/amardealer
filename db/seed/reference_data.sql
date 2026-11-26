-- =============================================================================
-- AmarDealer DMS · Reference / seed data (global, platform-owned)
--   feature catalog · plans · permissions · industry templates · BD divisions ·
--   default notification templates
-- Idempotent: safe to re-run.
-- =============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- -----------------------------------------------------------------------------
-- Feature catalog
-- -----------------------------------------------------------------------------
INSERT INTO feature_catalog (feature_key, kind, reset_period, description) VALUES
  ('max_branches',          'limit',  'none',    'Active branches / showrooms / depots'),
  ('max_warehouses',        'limit',  'none',    'Active warehouses (incl. van & showroom stock points)'),
  ('max_users',             'limit',  'none',    'Invited + active user seats'),
  ('max_skus',              'limit',  'none',    'Active product variants (SKUs)'),
  ('max_sales_reps',        'limit',  'none',    'Active field sales representatives'),
  ('max_monthly_invoices',  'limit',  'monthly', 'Posted sales invoices per calendar month (tenant timezone)'),
  ('max_monthly_sms',       'limit',  'monthly', 'SMS segments per month'),
  ('max_storage_mb',        'limit',  'none',    'Attachment storage in MB'),
  ('module.serial_tracking','toggle', 'none',    'Chassis / engine / IMEI / serial-number tracking'),
  ('module.batch_expiry',   'toggle', 'none',    'Batch / lot and expiry (FEFO) tracking'),
  ('module.variants',       'toggle', 'none',    'Product variants (size / color / storage ...)'),
  ('module.multi_uom',      'toggle', 'none',    'Multiple units of measure per product'),
  ('module.emi',            'toggle', 'none',    'In-house installment / EMI sales'),
  ('module.sales_force',    'toggle', 'none',    'SR app, routes, visits, targets'),
  ('module.van_sales',      'toggle', 'none',    'Van stock & on-the-spot invoicing'),
  ('module.promotions',     'toggle', 'none',    'Trade schemes & promotions'),
  ('module.mushak',         'toggle', 'none',    'NBR Mushak 6.3/6.5/6.6/6.7/6.8 challans & registers'),
  ('module.import_lc',      'toggle', 'none',    'Import purchases, LC and landed cost'),
  ('module.warranty',       'toggle', 'none',    'Warranty & service claims'),
  ('module.b2b_portal',     'toggle', 'none',    'Dealer self-service ordering portal'),
  ('module.approvals',      'toggle', 'none',    'Configurable approval workflows'),
  ('module.api_access',     'toggle', 'none',    'REST API keys & webhooks'),
  ('module.custom_fields',  'toggle', 'none',    'Tenant-defined custom fields'),
  ('module.custom_domain',  'toggle', 'none',    'Custom domain instead of subdomain')
ON CONFLICT (feature_key) DO UPDATE SET kind = EXCLUDED.kind, reset_period = EXCLUDED.reset_period,
                                        description = EXCLUDED.description;

-- -----------------------------------------------------------------------------
-- Plans (prices in BDT, VAT 15% added on the SaaS invoice)
-- -----------------------------------------------------------------------------
INSERT INTO plans (code, name, description, trial_days, sort_order) VALUES
  ('starter',    'Starter',    'Single showroom / small distributor',            14, 1),
  ('growth',     'Growth',     'Multi-branch dealer or regional distributor',    14, 2),
  ('business',   'Business',   'Large distributor with field force & imports',   14, 3),
  ('enterprise', 'Enterprise', 'Custom limits, SLA, dedicated support',           30, 4)
ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name, description = EXCLUDED.description;

INSERT INTO plan_prices (plan_id, billing_interval, price)
SELECT p.id, v.billing_interval::billing_interval, v.price
  FROM (VALUES
    ('starter',  'monthly',  1500), ('starter',  'yearly',  15000),
    ('growth',   'monthly',  4000), ('growth',   'yearly',  40000),
    ('business', 'monthly',  9000), ('business', 'yearly',  90000),
    ('enterprise','yearly', 250000)
  ) AS v(plan_code, billing_interval, price)
  JOIN plans p ON p.code = v.plan_code
ON CONFLICT (plan_id, billing_interval, currency) DO UPDATE SET price = EXCLUDED.price;

-- limit_value NULL = unlimited
INSERT INTO plan_features (plan_id, feature_key, limit_value, is_enabled)
SELECT p.id, v.feature_key, v.limit_value, v.is_enabled
  FROM (VALUES
    -- starter
    ('starter','max_branches',1,true),      ('starter','max_warehouses',2,true),   ('starter','max_users',3,true),
    ('starter','max_skus',500,true),        ('starter','max_sales_reps',0,true),   ('starter','max_monthly_invoices',500,true),
    ('starter','max_monthly_sms',500,true), ('starter','max_storage_mb',1024,true),
    ('starter','module.serial_tracking',NULL,true), ('starter','module.batch_expiry',NULL,true),
    ('starter','module.variants',NULL,true),        ('starter','module.multi_uom',NULL,true),
    ('starter','module.emi',NULL,false),            ('starter','module.sales_force',NULL,false),
    ('starter','module.van_sales',NULL,false),      ('starter','module.promotions',NULL,false),
    ('starter','module.mushak',NULL,true),          ('starter','module.import_lc',NULL,false),
    ('starter','module.warranty',NULL,true),        ('starter','module.b2b_portal',NULL,false),
    ('starter','module.approvals',NULL,false),      ('starter','module.api_access',NULL,false),
    ('starter','module.custom_fields',NULL,true),   ('starter','module.custom_domain',NULL,false),
    -- growth
    ('growth','max_branches',5,true),        ('growth','max_warehouses',10,true),  ('growth','max_users',15,true),
    ('growth','max_skus',5000,true),         ('growth','max_sales_reps',10,true),  ('growth','max_monthly_invoices',5000,true),
    ('growth','max_monthly_sms',3000,true),  ('growth','max_storage_mb',10240,true),
    ('growth','module.serial_tracking',NULL,true), ('growth','module.batch_expiry',NULL,true),
    ('growth','module.variants',NULL,true),        ('growth','module.multi_uom',NULL,true),
    ('growth','module.emi',NULL,true),             ('growth','module.sales_force',NULL,true),
    ('growth','module.van_sales',NULL,false),      ('growth','module.promotions',NULL,true),
    ('growth','module.mushak',NULL,true),          ('growth','module.import_lc',NULL,false),
    ('growth','module.warranty',NULL,true),        ('growth','module.b2b_portal',NULL,false),
    ('growth','module.approvals',NULL,true),       ('growth','module.api_access',NULL,false),
    ('growth','module.custom_fields',NULL,true),   ('growth','module.custom_domain',NULL,false),
    -- business
    ('business','max_branches',25,true),       ('business','max_warehouses',60,true),  ('business','max_users',75,true),
    ('business','max_skus',50000,true),        ('business','max_sales_reps',100,true), ('business','max_monthly_invoices',50000,true),
    ('business','max_monthly_sms',20000,true), ('business','max_storage_mb',51200,true),
    ('business','module.serial_tracking',NULL,true), ('business','module.batch_expiry',NULL,true),
    ('business','module.variants',NULL,true),        ('business','module.multi_uom',NULL,true),
    ('business','module.emi',NULL,true),             ('business','module.sales_force',NULL,true),
    ('business','module.van_sales',NULL,true),       ('business','module.promotions',NULL,true),
    ('business','module.mushak',NULL,true),          ('business','module.import_lc',NULL,true),
    ('business','module.warranty',NULL,true),        ('business','module.b2b_portal',NULL,true),
    ('business','module.approvals',NULL,true),       ('business','module.api_access',NULL,true),
    ('business','module.custom_fields',NULL,true),   ('business','module.custom_domain',NULL,false),
    -- enterprise: everything unlimited
    ('enterprise','max_branches',NULL,true),     ('enterprise','max_warehouses',NULL,true), ('enterprise','max_users',NULL,true),
    ('enterprise','max_skus',NULL,true),         ('enterprise','max_sales_reps',NULL,true), ('enterprise','max_monthly_invoices',NULL,true),
    ('enterprise','max_monthly_sms',NULL,true),  ('enterprise','max_storage_mb',NULL,true),
    ('enterprise','module.serial_tracking',NULL,true), ('enterprise','module.batch_expiry',NULL,true),
    ('enterprise','module.variants',NULL,true),        ('enterprise','module.multi_uom',NULL,true),
    ('enterprise','module.emi',NULL,true),             ('enterprise','module.sales_force',NULL,true),
    ('enterprise','module.van_sales',NULL,true),       ('enterprise','module.promotions',NULL,true),
    ('enterprise','module.mushak',NULL,true),          ('enterprise','module.import_lc',NULL,true),
    ('enterprise','module.warranty',NULL,true),        ('enterprise','module.b2b_portal',NULL,true),
    ('enterprise','module.approvals',NULL,true),       ('enterprise','module.api_access',NULL,true),
    ('enterprise','module.custom_fields',NULL,true),   ('enterprise','module.custom_domain',NULL,true)
  ) AS v(plan_code, feature_key, limit_value, is_enabled)
  JOIN plans p ON p.code = v.plan_code
ON CONFLICT (plan_id, feature_key) DO UPDATE SET limit_value = EXCLUDED.limit_value, is_enabled = EXCLUDED.is_enabled;

-- -----------------------------------------------------------------------------
-- Permission catalog (module.resource.action)
-- -----------------------------------------------------------------------------
INSERT INTO permissions (code, module, description, is_sensitive) VALUES
  ('settings.company.manage',        'settings',    'Edit company profile, BIN/TIN, logo', true),
  ('settings.config.manage',         'settings',    'Change tenant settings, numbering, custom fields', true),
  ('settings.billing.manage',        'settings',    'View SaaS invoices, pay subscription, change plan', true),
  ('users.member.manage',            'users',       'Invite, disable and assign roles to users', true),
  ('users.role.manage',              'users',       'Create and edit roles & permissions', true),
  ('org.branch.manage',              'org',         'Create/edit branches', false),
  ('org.warehouse.manage',           'org',         'Create/edit warehouses & locations', false),
  ('org.territory.manage',           'org',         'Manage territories and routes', false),
  ('catalog.product.view',           'catalog',     'View products', false),
  ('catalog.product.manage',         'catalog',     'Create/edit products, variants, units, barcodes', false),
  ('catalog.cost.view',              'catalog',     'See purchase cost & margins', true),
  ('pricing.price_list.manage',      'pricing',     'Edit price lists', true),
  ('pricing.promotion.manage',       'pricing',     'Create/edit promotions & schemes', true),
  ('pricing.tax.manage',             'pricing',     'Edit tax rates & groups', true),
  ('inventory.stock.view',           'inventory',   'View stock balances & stock card', false),
  ('inventory.serial.manage',        'inventory',   'Edit serial / chassis / IMEI records', true),
  ('inventory.transfer.create',      'inventory',   'Create stock transfers', false),
  ('inventory.transfer.approve',     'inventory',   'Approve / dispatch transfers', false),
  ('inventory.transfer.receive',     'inventory',   'Receive transfers', false),
  ('inventory.adjustment.create',    'inventory',   'Create stock adjustments / counts', false),
  ('inventory.adjustment.approve',   'inventory',   'Approve & post stock adjustments', true),
  ('customers.customer.view',        'customers',   'View customers / dealers', false),
  ('customers.customer.manage',      'customers',   'Create/edit customers / dealers', false),
  ('customers.credit.manage',        'customers',   'Change credit limit, credit days, credit status', true),
  ('customers.statement.view',       'customers',   'View customer ledger / statement', false),
  ('suppliers.supplier.manage',      'suppliers',   'Create/edit suppliers', false),
  ('sales.order.create',             'sales',       'Create quotations & sales orders', false),
  ('sales.order.approve',            'sales',       'Approve sales orders', false),
  ('sales.invoice.create',           'sales',       'Create draft invoices', false),
  ('sales.invoice.post',             'sales',       'Post invoices (commit stock & ledger)', false),
  ('sales.invoice.void',             'sales',       'Void posted invoices', true),
  ('sales.discount.override',        'sales',       'Discount beyond max / price below min price', true),
  ('sales.credit.override',          'sales',       'Sell beyond credit limit', true),
  ('sales.return.create',            'sales',       'Create sales returns', false),
  ('sales.return.approve',           'sales',       'Approve & post sales returns', true),
  ('sales.delivery.manage',          'sales',       'Manage deliveries / gate passes', false),
  ('sales.installment.manage',       'sales',       'Create & reschedule EMI schedules', true),
  ('sales.installment.waive',        'sales',       'Waive late fees / installments', true),
  ('payments.receipt.create',        'payments',    'Collect money receipts', false),
  ('payments.receipt.void',          'payments',    'Void money receipts', true),
  ('payments.voucher.create',        'payments',    'Pay suppliers / refunds', true),
  ('payments.cheque.manage',         'payments',    'Mark cheques deposited / cleared / bounced', false),
  ('payments.account.manage',        'payments',    'Manage cash / bank / MFS accounts', true),
  ('purchase.order.create',          'purchase',    'Create purchase orders', false),
  ('purchase.order.approve',         'purchase',    'Approve purchase orders', true),
  ('purchase.grn.create',            'purchase',    'Receive goods (GRN)', false),
  ('purchase.grn.post',              'purchase',    'Post GRN into stock', false),
  ('purchase.bill.manage',           'purchase',    'Record supplier bills & landed costs', false),
  ('purchase.return.manage',         'purchase',    'Return goods to suppliers', false),
  ('vat.challan.issue',              'vat',         'Issue / reprint Mushak challans', false),
  ('vat.challan.cancel',             'vat',         'Cancel Mushak challans', true),
  ('vat.report.view',                'vat',         'Mushak 6.1/6.2 registers, 9.1 return workings', false),
  ('field.sales_rep.manage',         'field',       'Manage SRs, targets and assignments', false),
  ('field.visit.create',             'field',       'Check in at outlets (SR app)', false),
  ('field.tracking.view',            'field',       'View SR visits & location trail', false),
  ('warranty.claim.manage',          'warranty',    'Create & process warranty claims', false),
  ('approvals.request.decide',       'approvals',   'Approve / reject pending requests', false),
  ('reports.sales.view',             'reports',     'Sales & margin reports', false),
  ('reports.inventory.view',         'reports',     'Inventory & valuation reports', false),
  ('reports.finance.view',           'reports',     'Receivable / payable ageing, cash book', true),
  ('reports.export',                 'reports',     'Export reports to Excel / PDF', true),
  ('audit.log.view',                 'audit',       'View the audit trail', true),
  ('tools.import.run',               'tools',       'Bulk import from Excel / CSV', true),
  ('tools.sms.send',                 'tools',       'Send bulk SMS campaigns', true),
  ('tools.api_key.manage',           'tools',       'Create / revoke API keys', true)
ON CONFLICT (code) DO UPDATE SET module = EXCLUDED.module, description = EXCLUDED.description,
                                 is_sensitive = EXCLUDED.is_sensitive;

-- -----------------------------------------------------------------------------
-- Industry templates: everything vertical-specific lives here as DATA.
-- The onboarding job copies the chosen template into the tenant's own rows
-- (tenant_settings, units, serial_identifier_types, custom_field_definitions,
-- categories, roles). Tenants can mix templates or change anything afterwards.
-- -----------------------------------------------------------------------------
INSERT INTO industry_templates (code, name, name_bn, description, config) VALUES
('motorbike_automotive', 'Motorbike & Automotive Dealer', 'মোটরবাইক ও অটোমোবাইল ডিলার',
 'Bikes, cars, three-wheelers, spare parts, lubricants. Chassis/engine tracking, EMI, registration.',
 $${
   "modules": ["module.serial_tracking","module.variants","module.emi","module.warranty","module.mushak","module.import_lc","module.approvals"],
   "settings": {
     "inventory.costing_method": "specific_identification",
     "inventory.deduct_stock_on": "invoice",
     "sales.require_serial_on_invoice": true,
     "sales.credit_check_mode": "block",
     "print.invoice_template": "vehicle_sale"
   },
   "units": [{"code":"pcs","name":"Piece","category":"count"},{"code":"set","name":"Set","category":"count"},
             {"code":"ltr","name":"Litre","category":"volume","allows_fraction":true}],
   "identifier_types": [
     {"code":"chassis_no","label":"Chassis No","validation_regex":"^[A-HJ-NPR-Z0-9]{6,20}$","normalize":"upper"},
     {"code":"engine_no","label":"Engine No","normalize":"upper"},
     {"code":"key_no","label":"Key No","normalize":"upper","print_on_invoice":false}
   ],
   "custom_fields": [
     {"entity_type":"product","field_key":"engine_cc","label":"Engine (cc)","data_type":"integer"},
     {"entity_type":"product","field_key":"model_year","label":"Model Year","data_type":"integer"},
     {"entity_type":"product_serial","field_key":"color","label":"Color","data_type":"text","show_on_print":true},
     {"entity_type":"product_serial","field_key":"manufacturing_year","label":"Mfg Year","data_type":"integer","show_on_print":true},
     {"entity_type":"invoice","field_key":"brta_registration_status","label":"BRTA Registration","data_type":"select",
      "options":[{"value":"not_applied","label":"Not applied"},{"value":"applied","label":"Applied"},{"value":"completed","label":"Completed"}]},
     {"entity_type":"invoice","field_key":"registration_no","label":"Registration No","data_type":"text","show_on_print":true},
     {"entity_type":"invoice","field_key":"free_service_coupons","label":"Free Service Coupons","data_type":"integer"}
   ],
   "categories": ["Motorcycles","Scooters","Spare Parts","Lubricants","Helmets & Accessories"],
   "roles": ["owner","admin","showroom_manager","sales_executive","accountant","store_keeper","service_advisor"]
 }$$::jsonb),

('electronics_mobile', 'Electronics & Mobile Distributor', 'ইলেকট্রনিক্স ও মোবাইল ডিস্ট্রিবিউটর',
 'Phones, TVs, appliances, IT. IMEI/serial tracking, variants (color/storage), warranty, EMI.',
 $${
   "modules": ["module.serial_tracking","module.variants","module.emi","module.warranty","module.mushak","module.sales_force","module.promotions"],
   "settings": {
     "inventory.costing_method": "moving_average",
     "inventory.deduct_stock_on": "invoice",
     "sales.require_serial_on_invoice": true,
     "sales.credit_check_mode": "block"
   },
   "units": [{"code":"pcs","name":"Piece","category":"count"},{"code":"box","name":"Box","category":"count"}],
   "identifier_types": [
     {"code":"imei_1","label":"IMEI 1","validation_regex":"^[0-9]{15}$","normalize":"digits_only","check_algorithm":"luhn"},
     {"code":"imei_2","label":"IMEI 2","validation_regex":"^[0-9]{15}$","normalize":"digits_only","check_algorithm":"luhn"},
     {"code":"serial_no","label":"Serial No","normalize":"upper"},
     {"code":"mac","label":"MAC Address","validation_regex":"^([0-9A-F]{2}:){5}[0-9A-F]{2}$","normalize":"upper","print_on_invoice":false}
   ],
   "variant_axes": ["color","storage","ram","screen_size"],
   "custom_fields": [
     {"entity_type":"product","field_key":"btrc_approval_no","label":"BTRC Approval No","data_type":"text"},
     {"entity_type":"product","field_key":"model_no","label":"Model No","data_type":"text","show_on_print":true}
   ],
   "categories": ["Smartphones","Feature Phones","Televisions","Refrigerators","Air Conditioners","Laptops","Accessories"],
   "roles": ["owner","admin","branch_manager","sales_executive","sr","accountant","store_keeper","service_engineer"]
 }$$::jsonb),

('fmcg_distribution', 'FMCG Distribution', 'এফএমসিজি ডিস্ট্রিবিউশন',
 'Food, beverage, personal care, home care. Cartons/pieces, batch & expiry, SR routes, van sales, trade schemes.',
 $${
   "modules": ["module.batch_expiry","module.multi_uom","module.sales_force","module.van_sales","module.promotions","module.mushak","module.approvals"],
   "settings": {
     "inventory.costing_method": "moving_average",
     "inventory.batch_pick_strategy": "fefo",
     "inventory.deduct_stock_on": "delivery",
     "sales.credit_check_mode": "warn",
     "sales.order_source_default": "sr_app",
     "field.visit_geofence_m": 100
   },
   "units": [{"code":"pcs","name":"Piece","category":"count"},{"code":"ctn","name":"Carton","category":"count"},
             {"code":"dz","name":"Dozen","category":"count"},{"code":"pkt","name":"Packet","category":"count"},
             {"code":"kg","name":"Kilogram","category":"weight","allows_fraction":true},
             {"code":"ltr","name":"Litre","category":"volume","allows_fraction":true}],
   "identifier_types": [],
   "custom_fields": [
     {"entity_type":"product","field_key":"pack_size","label":"Pack Size","data_type":"text","show_on_print":true},
     {"entity_type":"product","field_key":"bsti_license_no","label":"BSTI License","data_type":"text"},
     {"entity_type":"customer","field_key":"outlet_type","label":"Outlet Type","data_type":"select",
      "options":[{"value":"grocery","label":"Grocery"},{"value":"pharmacy","label":"Pharmacy"},{"value":"super_shop","label":"Super Shop"},{"value":"wholesale","label":"Wholesale"}]},
     {"entity_type":"customer","field_key":"has_fridge","label":"Has Fridge/Visicooler","data_type":"boolean"}
   ],
   "territory_levels": ["Zone","Region","Area","Territory","Market"],
   "categories": ["Beverages","Snacks","Dairy","Personal Care","Home Care","Edible Oil"],
   "roles": ["owner","admin","distribution_manager","asm","tso","sr","delivery_man","accountant","store_keeper"]
 }$$::jsonb),

('pharmaceuticals', 'Pharmaceutical Distribution', 'ফার্মাসিউটিক্যাল ডিস্ট্রিবিউশন',
 'Medicine, surgical, vet. Mandatory batch & expiry, DGDA fields, near-expiry returns.',
 $${
   "modules": ["module.batch_expiry","module.multi_uom","module.sales_force","module.promotions","module.mushak"],
   "settings": {
     "inventory.costing_method": "moving_average",
     "inventory.batch_pick_strategy": "fefo",
     "inventory.block_expired_sale": true,
     "inventory.near_expiry_days": 90
   },
   "units": [{"code":"strip","name":"Strip","category":"count"},{"code":"box","name":"Box","category":"count"},
             {"code":"btl","name":"Bottle","category":"count"},{"code":"vial","name":"Vial","category":"count"},
             {"code":"pcs","name":"Piece","category":"count"}],
   "identifier_types": [],
   "custom_fields": [
     {"entity_type":"product","field_key":"generic_name","label":"Generic Name","data_type":"text","is_searchable":true,"show_on_print":true},
     {"entity_type":"product","field_key":"strength","label":"Strength","data_type":"text","show_on_print":true},
     {"entity_type":"product","field_key":"dosage_form","label":"Dosage Form","data_type":"select",
      "options":[{"value":"tablet","label":"Tablet"},{"value":"capsule","label":"Capsule"},{"value":"syrup","label":"Syrup"},{"value":"injection","label":"Injection"}]},
     {"entity_type":"product","field_key":"dar_no","label":"DGDA DAR No","data_type":"text"},
     {"entity_type":"customer","field_key":"drug_license_no","label":"Drug License No","data_type":"text","is_required":true}
   ],
   "categories": ["Antibiotics","Analgesics","Cardiovascular","Gastro","Vitamins","Surgical"],
   "roles": ["owner","admin","depot_manager","mpo","sr","accountant","store_keeper"]
 }$$::jsonb),

('apparel_footwear', 'Apparel & Footwear', 'পোশাক ও জুতা',
 'Garments, shoes, textiles. Size x color variant matrix, barcodes, seasonal pricing.',
 $${
   "modules": ["module.variants","module.multi_uom","module.promotions","module.mushak"],
   "settings": {"inventory.costing_method": "moving_average", "pos.enabled": true},
   "units": [{"code":"pcs","name":"Piece","category":"count"},{"code":"pair","name":"Pair","category":"count"},
             {"code":"yd","name":"Yard","category":"length","allows_fraction":true},{"code":"mtr","name":"Metre","category":"length","allows_fraction":true}],
   "identifier_types": [],
   "variant_axes": ["size","color","fit"],
   "custom_fields": [
     {"entity_type":"product","field_key":"fabric","label":"Fabric","data_type":"text"},
     {"entity_type":"product","field_key":"season","label":"Season","data_type":"select",
      "options":[{"value":"eid","label":"Eid"},{"value":"puja","label":"Puja"},{"value":"winter","label":"Winter"},{"value":"summer","label":"Summer"}]}
   ],
   "categories": ["Men","Women","Kids","Footwear","Fabric"],
   "roles": ["owner","admin","store_manager","cashier","accountant","store_keeper"]
 }$$::jsonb),

('building_materials', 'Building Materials', 'নির্মাণ সামগ্রী',
 'Cement, rod/steel, tiles, paint, sanitary. Weight units, truck deliveries, high-credit dealers.',
 $${
   "modules": ["module.multi_uom","module.sales_force","module.mushak","module.approvals","module.batch_expiry"],
   "settings": {"inventory.costing_method": "moving_average", "inventory.deduct_stock_on": "delivery", "sales.credit_check_mode": "block"},
   "units": [{"code":"bag","name":"Bag","category":"count"},{"code":"ton","name":"Ton","category":"weight","allows_fraction":true},
             {"code":"kg","name":"Kilogram","category":"weight","allows_fraction":true},{"code":"sqft","name":"Square Feet","category":"area","allows_fraction":true},
             {"code":"pcs","name":"Piece","category":"count"},{"code":"ltr","name":"Litre","category":"volume","allows_fraction":true},
             {"code":"cft","name":"Cubic Feet","category":"volume","allows_fraction":true}],
   "identifier_types": [],
   "custom_fields": [
     {"entity_type":"product","field_key":"grade","label":"Grade","data_type":"text","show_on_print":true},
     {"entity_type":"delivery","field_key":"truck_capacity_ton","label":"Truck Capacity (ton)","data_type":"decimal"},
     {"entity_type":"invoice","field_key":"project_site","label":"Project / Site","data_type":"text","show_on_print":true}
   ],
   "categories": ["Cement","MS Rod","Tiles","Paint","Sanitary","Brick & Sand"],
   "roles": ["owner","admin","sales_manager","sr","accountant","store_keeper","transport_coordinator"]
 }$$::jsonb),

('agro_inputs', 'Agro Inputs', 'কৃষি উপকরণ',
 'Seed, fertilizer, pesticide, feed, agri-machinery. Batch/expiry, seasonal schemes, dealer credit.',
 $${
   "modules": ["module.batch_expiry","module.multi_uom","module.sales_force","module.promotions","module.mushak","module.serial_tracking"],
   "settings": {"inventory.batch_pick_strategy": "fefo", "sales.credit_check_mode": "warn"},
   "units": [{"code":"kg","name":"Kilogram","category":"weight","allows_fraction":true},{"code":"bag","name":"Bag","category":"count"},
             {"code":"pkt","name":"Packet","category":"count"},{"code":"ltr","name":"Litre","category":"volume","allows_fraction":true},
             {"code":"pcs","name":"Piece","category":"count"}],
   "identifier_types": [{"code":"serial_no","label":"Machine Serial","normalize":"upper"}],
   "custom_fields": [
     {"entity_type":"product","field_key":"crop","label":"Crop","data_type":"multi_select",
      "options":[{"value":"rice","label":"Rice"},{"value":"jute","label":"Jute"},{"value":"potato","label":"Potato"},{"value":"vegetable","label":"Vegetable"}]},
     {"entity_type":"product","field_key":"registration_no","label":"Registration No","data_type":"text"}
   ],
   "categories": ["Seeds","Fertilizer","Pesticide","Animal Feed","Machinery"],
   "roles": ["owner","admin","area_manager","sr","accountant","store_keeper"]
 }$$::jsonb),

('furniture_home', 'Furniture & Home Appliances', 'ফার্নিচার ও গৃহস্থালি',
 'Furniture, kitchenware, appliances. Made-to-order sales orders, delivery & installation, EMI.',
 $${
   "modules": ["module.variants","module.emi","module.warranty","module.mushak","module.serial_tracking"],
   "settings": {"inventory.deduct_stock_on": "delivery", "sales.allow_advance_on_order": true},
   "units": [{"code":"pcs","name":"Piece","category":"count"},{"code":"set","name":"Set","category":"count"}],
   "identifier_types": [{"code":"serial_no","label":"Serial No","normalize":"upper"}],
   "variant_axes": ["material","color","size"],
   "custom_fields": [
     {"entity_type":"sales_order","field_key":"installation_required","label":"Installation Required","data_type":"boolean"},
     {"entity_type":"product","field_key":"dimensions","label":"Dimensions (LxWxH)","data_type":"text","show_on_print":true}
   ],
   "categories": ["Bedroom","Living","Dining","Office","Kitchen Appliances"],
   "roles": ["owner","admin","showroom_manager","sales_executive","accountant","store_keeper","installer"]
 }$$::jsonb),

('general_trading', 'General Trading / Wholesale', 'সাধারণ ব্যবসা / পাইকারি',
 'Neutral starting point for any other product business. Enable modules as needed.',
 $${
   "modules": ["module.multi_uom","module.mushak"],
   "settings": {"inventory.costing_method": "moving_average", "inventory.deduct_stock_on": "invoice", "sales.credit_check_mode": "warn"},
   "units": [{"code":"pcs","name":"Piece","category":"count"},{"code":"box","name":"Box","category":"count"},
             {"code":"kg","name":"Kilogram","category":"weight","allows_fraction":true}],
   "identifier_types": [],
   "custom_fields": [],
   "categories": ["General"],
   "roles": ["owner","admin","manager","sales","accountant","store_keeper"]
 }$$::jsonb)
ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name, name_bn = EXCLUDED.name_bn,
                                 description = EXCLUDED.description, config = EXCLUDED.config, updated_at = now();

-- -----------------------------------------------------------------------------
-- Bangladesh: country + 8 divisions (districts/upazilas loaded from the BBS geo-code file)
-- -----------------------------------------------------------------------------
INSERT INTO geo_areas (level, code, name_en, name_bn) VALUES ('country', 'BD', 'Bangladesh', 'বাংলাদেশ')
ON CONFLICT (level, code) DO NOTHING;

INSERT INTO geo_areas (parent_id, level, code, name_en, name_bn)
SELECT (SELECT id FROM geo_areas WHERE level = 'country' AND code = 'BD'), 'division', v.code, v.name_en, v.name_bn
  FROM (VALUES ('10', 'Barishal', 'বরিশাল'), ('20', 'Chattogram', 'চট্টগ্রাম'), ('30', 'Dhaka', 'ঢাকা'),
               ('40', 'Khulna', 'খুলনা'), ('45', 'Mymensingh', 'ময়মনসিংহ'), ('50', 'Rajshahi', 'রাজশাহী'),
               ('55', 'Rangpur', 'রংপুর'), ('60', 'Sylhet', 'সিলেট')) AS v(code, name_en, name_bn)
ON CONFLICT (level, code) DO NOTHING;

-- -----------------------------------------------------------------------------
-- Platform default notification templates (tenants may override per key/channel/locale)
-- -----------------------------------------------------------------------------
INSERT INTO notification_templates (tenant_id, event_key, channel, locale, body) VALUES
  (NULL, 'invoice.posted',   'sms', 'bn', 'প্রিয় {{customer_name}}, {{company}} থেকে আপনার ইনভয়েস {{invoice_no}} মোট {{amount}} টাকা। বকেয়া: {{due}} টাকা।'),
  (NULL, 'invoice.posted',   'sms', 'en', 'Dear {{customer_name}}, invoice {{invoice_no}} from {{company}}: Tk {{amount}}. Due: Tk {{due}}.'),
  (NULL, 'payment.received', 'sms', 'bn', 'প্রিয় {{customer_name}}, {{amount}} টাকা জমা হয়েছে (রশিদ {{receipt_no}})। বর্তমান বকেয়া: {{due}} টাকা।'),
  (NULL, 'payment.received', 'sms', 'en', 'Dear {{customer_name}}, Tk {{amount}} received (receipt {{receipt_no}}). Balance due: Tk {{due}}.'),
  (NULL, 'installment.due',  'sms', 'bn', 'প্রিয় {{customer_name}}, আপনার কিস্তি {{installment_no}} ({{amount}} টাকা) {{due_date}} তারিখে পরিশোধযোগ্য।'),
  (NULL, 'credit.overdue',   'sms', 'bn', 'প্রিয় {{customer_name}}, আপনার {{overdue_amount}} টাকা বকেয়া মেয়াদোত্তীর্ণ হয়েছে। অনুগ্রহ করে দ্রুত পরিশোধ করুন।'),
  (NULL, 'auth.otp',         'sms', 'bn', '{{company}} লগইন কোড: {{otp}}। কাউকে জানাবেন না।')
ON CONFLICT (tenant_id, event_key, channel, locale) DO NOTHING;

COMMIT;

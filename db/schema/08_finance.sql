-- =============================================================================
-- AmarDealer DMS · 08 Money: cash/bank/MFS accounts, receipts & payments,
-- allocations, and the append-only party ledger (payments_ledger)
-- =============================================================================

CREATE TABLE financial_accounts (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenants(id),
  branch_id       uuid,
  account_type    varchar(16) NOT NULL
                  CHECK (account_type IN ('cash', 'bank', 'mobile_wallet', 'card_terminal', 'cheque_in_hand', 'petty_cash')),
  name            varchar(120) NOT NULL,                -- "Dhaka Showroom Cash", "DBBL CD A/C", "bKash Merchant"
  provider        varchar(40),                          -- bank name / bkash / nagad / rocket / upay
  account_no      varchar(60),
  routing_no      varchar(20),
  currency        currency_t NOT NULL DEFAULT 'BDT',
  opening_balance amount_t NOT NULL DEFAULT 0,
  is_active       boolean NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, branch_id) REFERENCES branches (tenant_id, id)
);

-- Money receipts (inbound, from customers) and payment vouchers (outbound, to suppliers / refunds)
CREATE TABLE payments (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id            uuid NOT NULL REFERENCES tenants(id),
  payment_no           varchar(40),
  direction            varchar(8) NOT NULL CHECK (direction IN ('inbound', 'outbound')),
  party_id             uuid NOT NULL,
  branch_id            uuid NOT NULL,
  financial_account_id uuid,
  payment_date         date NOT NULL DEFAULT tenant_today(),
  method               varchar(16) NOT NULL
                       CHECK (method IN ('cash', 'bank_transfer', 'cheque', 'pay_order', 'bkash', 'nagad', 'rocket',
                                         'upay', 'card', 'sslcommerz', 'npsb', 'beftn', 'rtgs', 'adjustment', 'other')),
  amount               amount_t NOT NULL CHECK (amount > 0),
  currency             currency_t NOT NULL DEFAULT 'BDT',
  exchange_rate        fx_rate_t NOT NULL DEFAULT 1,
  reference_no         varchar(80),                -- MFS trxID / bank ref
  payer_wallet_no      varchar(20),                -- MFS sender number
  cheque_no            varchar(30),
  cheque_date          date,
  cheque_bank          varchar(120),
  cheque_status        varchar(12) CHECK (cheque_status IN ('pending', 'deposited', 'cleared', 'bounced', 'cancelled')),
  status               varchar(18) NOT NULL DEFAULT 'draft'
                       CHECK (status IN ('draft', 'posted', 'pending_clearance', 'bounced', 'void')),
  collected_by_sales_rep_id uuid,                  -- field collection
  collected_lat        numeric(9,6),
  collected_lng        numeric(9,6),
  unallocated_amount   amount_t NOT NULL DEFAULT 0 CHECK (unallocated_amount >= 0),  -- advance / on-account
  notes                text,
  client_ref           uuid,
  created_by           uuid REFERENCES users(id),
  posted_at            timestamptz,
  voided_at            timestamptz,
  void_reason          text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, payment_no),
  UNIQUE (tenant_id, client_ref),
  FOREIGN KEY (tenant_id, party_id)                  REFERENCES parties (tenant_id, id),
  FOREIGN KEY (tenant_id, branch_id)                 REFERENCES branches (tenant_id, id),
  FOREIGN KEY (tenant_id, financial_account_id)      REFERENCES financial_accounts (tenant_id, id),
  FOREIGN KEY (tenant_id, collected_by_sales_rep_id) REFERENCES sales_reps (tenant_id, id),
  CHECK (status = 'draft' OR payment_no IS NOT NULL),
  CHECK (method <> 'cheque' OR (cheque_no IS NOT NULL AND cheque_status IS NOT NULL)),
  CHECK (status <> 'void' OR void_reason IS NOT NULL),
  CHECK (unallocated_amount <= amount)
);
CREATE INDEX ix_payments_party ON payments (tenant_id, party_id, payment_date DESC);
CREATE INDEX ix_payments_date ON payments (tenant_id, branch_id, payment_date DESC);
CREATE INDEX ix_payments_cheques ON payments (tenant_id, cheque_date) WHERE cheque_status IN ('pending', 'deposited');
CREATE INDEX ix_payments_sr ON payments (tenant_id, collected_by_sales_rep_id, payment_date DESC);

-- Knock-off of a payment against invoices / installments / supplier bills
CREATE TABLE payment_allocations (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid NOT NULL REFERENCES tenants(id),
  payment_id          uuid NOT NULL,
  invoice_id          uuid,
  installment_item_id uuid,
  supplier_bill_id    uuid,
  amount              amount_t NOT NULL CHECK (amount > 0),
  allocated_at        timestamptz NOT NULL DEFAULT now(),
  is_reversed         boolean NOT NULL DEFAULT false,
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, payment_id)          REFERENCES payments (tenant_id, id),
  FOREIGN KEY (tenant_id, invoice_id)          REFERENCES invoices (tenant_id, id),
  FOREIGN KEY (tenant_id, installment_item_id) REFERENCES installment_schedule_items (tenant_id, id),
  FOREIGN KEY (tenant_id, supplier_bill_id)    REFERENCES supplier_bills (tenant_id, id),
  CHECK (num_nonnulls(invoice_id, supplier_bill_id) = 1),
  CHECK (installment_item_id IS NULL OR invoice_id IS NOT NULL)
);
CREATE INDEX ix_allocations_payment ON payment_allocations (tenant_id, payment_id);
CREATE INDEX ix_allocations_invoice ON payment_allocations (tenant_id, invoice_id) WHERE invoice_id IS NOT NULL;
CREATE INDEX ix_allocations_bill ON payment_allocations (tenant_id, supplier_bill_id) WHERE supplier_bill_id IS NOT NULL;

-- -----------------------------------------------------------------------------
-- Party sub-ledger. Append-only; corrections are reversing entries.
--   customer: debit increases receivable (invoice), credit decreases it (receipt, return)
--   supplier: credit increases payable (bill),   debit decreases it (payment, return)
-- balance_after and the cached balances on customers_dealers / suppliers are written by
-- the trigger in 10_business_rules.sql under a row lock, so they are always consistent.
-- -----------------------------------------------------------------------------
CREATE TABLE payments_ledger (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenants(id),
  party_id        uuid NOT NULL,
  party_role      varchar(8) NOT NULL CHECK (party_role IN ('customer', 'supplier')),
  branch_id       uuid,
  entry_date      date NOT NULL DEFAULT tenant_today(),
  entry_type      varchar(24) NOT NULL
                  CHECK (entry_type IN ('opening_balance', 'invoice', 'receipt', 'sales_return', 'supplier_bill',
                                        'payment', 'purchase_return', 'credit_note', 'debit_note', 'discount',
                                        'installment_interest', 'late_fee', 'processing_fee', 'cheque_bounce',
                                        'write_off', 'adjustment', 'reversal')),
  debit           amount_t NOT NULL DEFAULT 0 CHECK (debit >= 0),
  credit          amount_t NOT NULL DEFAULT 0 CHECK (credit >= 0),
  balance_after   amount_t,
  source_doc_type varchar(32) NOT NULL,
  source_doc_id   uuid NOT NULL,
  reversal_of_id  uuid,
  description     varchar(255),
  created_by      uuid REFERENCES users(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, party_id)       REFERENCES parties (tenant_id, id),
  FOREIGN KEY (tenant_id, branch_id)      REFERENCES branches (tenant_id, id),
  FOREIGN KEY (tenant_id, reversal_of_id) REFERENCES payments_ledger (tenant_id, id),
  CHECK ((debit = 0) <> (credit = 0))           -- exactly one side is non-zero
);
CREATE INDEX ix_ledger_statement ON payments_ledger (tenant_id, party_id, party_role, entry_date, created_at);
CREATE INDEX ix_ledger_source ON payments_ledger (tenant_id, source_doc_type, source_doc_id);
CREATE UNIQUE INDEX ux_ledger_single_reversal ON payments_ledger (reversal_of_id) WHERE reversal_of_id IS NOT NULL;

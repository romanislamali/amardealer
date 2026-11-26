#!/usr/bin/env bash
# =============================================================================
# Two concurrent sessions race for the same chassis (serial) and the same
# non-serialized stock. Run after smoke_test.sql on the same database.
#   PSQL="psql -h 127.0.0.1 -p 5432 -U postgres -d amardealer_test" ./db/tests/concurrency_oversell.sh
# =============================================================================
set -euo pipefail
PSQL=${PSQL:-"psql -d amardealer_test"}
CTX="SET LOCAL ROLE dms_app; SELECT set_config('app.current_tenant_id','a0000000-0000-4000-8000-000000000001',true);"

# $1 = session label, $2 = seconds to hold the row lock, $3 = COMMIT | ROLLBACK
# (status 'defective' keeps the fixture self-contained; a sale sets 'sold' + invoice id)
claim_serial() {
  $PSQL -qAt -v ON_ERROR_STOP=1 <<SQL
BEGIN;
$CTX
WITH claimed AS (
  UPDATE product_serials SET status = 'defective'
   WHERE serial_no = 'CH0002' AND status = 'in_stock' RETURNING id)
SELECT '$1 claimed ' || count(*) || ' unit(s) at ' || to_char(clock_timestamp(), 'HH24:MI:SS.MS') FROM claimed;
SELECT pg_sleep($2);
$3;
SQL
}

echo "== serial race: S1 claims CH0002 and holds the row lock 2s; S2 tries meanwhile"
claim_serial S1 2 COMMIT | grep claimed &
sleep 0.5
claim_serial S2 0 ROLLBACK | grep claimed
wait

echo "== quantity race: two sessions each try to sell 6 of the 10 litres on hand"
sell_oil() {
  $PSQL -qAt <<SQL 2>&1 | grep -E 'sold|ERROR' || true
BEGIN;
$CTX
INSERT INTO stock_movements (tenant_id, movement_type, warehouse_id, variant_id, quantity, source_doc_type, source_doc_id)
VALUES (current_tenant_id(), 'sale', 'a2000000-0000-4000-8000-000000000001', 'a5000000-0000-4000-8000-000000000002', -6, 'invoice', gen_random_uuid())
RETURNING '$1 sold 6, balance_after=' || balance_after;
SELECT pg_sleep($2);
COMMIT;
SQL
}
sell_oil S1 2 &
sleep 0.5
sell_oil S2 0
wait

$PSQL -qAt -c "SELECT 'final: chassis CH0002 status=' || status FROM product_serials WHERE serial_no='CH0002'" \
           -c "SELECT 'final: oil on hand=' || qty_on_hand FROM stock_balances WHERE variant_id='a5000000-0000-4000-8000-000000000002'"

#!/bin/bash

# ================== User Configuration ==================
CHAIN_STATUS_URL="https://rpc.testnet-02.midnight.network"
CHAIN_STATUS_PAYLOAD='{ "jsonrpc": "2.0", "method": "sidechain_getStatus", "params": [], "id": 1 }'

DB_HOST="localhost"
DB_USER="postgres"
DB_PASSWORD="You_Password"
DB_NAME="cexplorer"
DB_PORT="5432"

CARDANO_NODE_CONTAINER="cardano-node"
TESTNET_MAGIC="2"

QU_HEALTH_URL="http://localhost:1337/health"

REFRESH_INTERVAL=5
# ========================================================

# Export DB password so psql doesn't prompt each time.
export PGPASSWORD="$DB_PASSWORD"

# ------------------ Data Fetch & Parsing ----------------

# 1) QU Health (connectionStatus, version, network)
get_qu_fields() {
  local qu_json
  qu_json=$(curl -s -H 'Accept: application/json' "$QU_HEALTH_URL")
  QU_CONNECTION_STATUS=$(echo "$qu_json" | jq -r '.connectionStatus // "N/A"')
  QU_VERSION=$(echo "$qu_json" | jq -r '.version // "N/A"')
  QU_NETWORK=$(echo "$qu_json" | jq -r '.network // "N/A"')
}

# 2) Cardano Tip (block, epoch, era, hash, slot, slotInEpoch, slotsToEpochEnd, syncProgress)
get_cardano_tip_fields() {
  # Check Docker
  if ! sudo docker info >/dev/null 2>&1; then
    TIP_BLOCK="N/A"
    TIP_EPOCH="N/A"
    TIP_ERA="Docker not running"
    TIP_HASH="N/A"
    TIP_SLOT="N/A"
    TIP_SLOT_IN_EPOCH="N/A"
    TIP_SLOTS_TO_EPOCH_END="N/A"
    TIP_SYNC_PROGRESS="N/A"
    return
  fi

  # Check container
  if ! sudo docker ps --format '{{.Names}}' | grep -q "^${CARDANO_NODE_CONTAINER}\$"; then
    TIP_BLOCK="N/A"
    TIP_EPOCH="N/A"
    TIP_ERA="Container not running"
    TIP_HASH="N/A"
    TIP_SLOT="N/A"
    TIP_SLOT_IN_EPOCH="N/A"
    TIP_SLOTS_TO_EPOCH_END="N/A"
    TIP_SYNC_PROGRESS="N/A"
    return
  fi

  local tip_json
  tip_json=$(sudo docker exec -it "$CARDANO_NODE_CONTAINER" \
    cardano-cli query tip --testnet-magic "$TESTNET_MAGIC" 2>/dev/null)

  # Parse JSON if possible
  if echo "$tip_json" | jq . >/dev/null 2>&1; then
    TIP_BLOCK=$(echo "$tip_json" | jq -r '.block // "N/A"')
    TIP_EPOCH=$(echo "$tip_json" | jq -r '.epoch // "N/A"')
    TIP_ERA=$(echo "$tip_json" | jq -r '.era // "N/A"')
    TIP_HASH=$(echo "$tip_json" | jq -r '.hash // "N/A"')
    TIP_SLOT=$(echo "$tip_json" | jq -r '.slot // "N/A"')
    TIP_SLOT_IN_EPOCH=$(echo "$tip_json" | jq -r '.slotInEpoch // "N/A"')
    TIP_SLOTS_TO_EPOCH_END=$(echo "$tip_json" | jq -r '.slotsToEpochEnd // "N/A"')
    TIP_SYNC_PROGRESS=$(echo "$tip_json" | jq -r '.syncProgress // "N/A"')
  else
    TIP_BLOCK="N/A"
    TIP_EPOCH="N/A"
    TIP_ERA="N/A"
    TIP_HASH="$tip_json"  # store raw text
    TIP_SLOT="N/A"
    TIP_SLOT_IN_EPOCH="N/A"
    TIP_SLOTS_TO_EPOCH_END="N/A"
    TIP_SYNC_PROGRESS="N/A"
  fi
}

# 3) DB Status (sync percent)
get_db_sync_percent() {
  local db_out
  db_out=$(psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -p "$DB_PORT" \
    -c "SELECT 100 * (EXTRACT(EPOCH FROM (MAX(time) AT TIME ZONE 'UTC')) - EXTRACT(EPOCH FROM (MIN(time) AT TIME ZONE 'UTC'))) / (EXTRACT(EPOCH FROM (NOW() AT TIME ZONE 'UTC')) - EXTRACT(EPOCH FROM (MIN(time) AT TIME ZONE 'UTC'))) AS sync_percent FROM block;" 2>/dev/null)
  DB_SYNC=$(echo "$db_out" | grep -Eo '[0-9]+\.[0-9]+' | head -n 1)
  [ -z "$DB_SYNC" ] && DB_SYNC="N/A"
}

# 4) Chain Status (sidechain epoch/slot, mainchain epoch/slot)
get_chain_status_fields() {
  local chain_json
  chain_json=$(curl -s -X POST -H "Content-Type: application/json" \
    -d "$CHAIN_STATUS_PAYLOAD" "$CHAIN_STATUS_URL")

  SIDE_EPOCH=$(echo "$chain_json" | jq -r '.result.sidechain.epoch // "N/A"' 2>/dev/null)
  SIDE_SLOT=$(echo "$chain_json" | jq -r '.result.sidechain.slot // "N/A"' 2>/dev/null)
  MAIN_EPOCH=$(echo "$chain_json" | jq -r '.result.mainchain.epoch // "N/A"' 2>/dev/null)
  MAIN_SLOT=$(echo "$chain_json" | jq -r '.result.mainchain.slot // "N/A"' 2>/dev/null)
}

# 5) Kupo Health (kupo_configuration_indexes, kupo_connection_status, etc.)
get_kupo_fields() {
  local kupo_raw
  kupo_raw=$(curl -s "$KUPO_HEALTH_URL")
  KUPO_CONFIG_INDEXES=$(echo "$kupo_raw" | grep '^kupo_configuration_indexes' | awk '{print $2}')
  KUPO_CONN_STATUS=$(echo "$kupo_raw" | grep '^kupo_connection_status' | awk '{print $2}')
  KUPO_CHECKPOINT=$(echo "$kupo_raw" | grep '^kupo_most_recent_checkpoint' | awk '{print $2}')
  KUPO_NODE_TIP=$(echo "$kupo_raw" | grep '^kupo_most_recent_node_tip' | awk '{print $2}')

  [ -z "$KUPO_CONFIG_INDEXES" ] && KUPO_CONFIG_INDEXES="N/A"
  [ -z "$KUPO_CONN_STATUS" ] && KUPO_CONN_STATUS="N/A"
  [ -z "$KUPO_CHECKPOINT" ] && KUPO_CHECKPOINT="N/A"
  [ -z "$KUPO_NODE_TIP" ] && KUPO_NODE_TIP="N/A"
}

# -------------------- UI Printing --------------------

# Draw a line of '=' across the terminal width, with '|' at each end
draw_equals_line() {
  local width
  width=$(tput cols)
  (( width < 2 )) && width=2
  printf "|"
  printf '%*s' $((width - 2)) '' | tr ' ' '='
  printf "|\n"
}

# Print a blank line with pipes on each side (like an empty row)
print_blank_row() {
  local width
  width=$(tput cols)
  (( width < 2 )) && width=2
  printf "|"
  printf '%*s' $((width - 2)) ''
  printf "|\n"
}

display_dashboard() {
  # Move cursor to top-left without fully clearing the screen
  tput cup 0 0

  # Header with timestamp
  echo "-------------------- Dashboard --------------------"
  echo "Timestamp: $(date)"
  echo "---------------------------------------------------"
  echo

  # 2) QU Health
  echo "==========================================="
  printf "|  Connection Status: %s | version: %s | network: %s\n" \
    "$QU_CONNECTION_STATUS" "$QU_VERSION" "$QU_NETWORK"
  echo "================================================================================="

  # 3) Cardano Tip
  echo
  printf "| Cardano Tip = era: %s\n" "$TIP_ERA"
  printf "| Epoch: %s\t || Block: %s\t|| slot: %s\n" "$TIP_EPOCH" "$TIP_BLOCK" "$TIP_SLOT"
  printf "| SlotInEpoch: %s\t|| SlotsToEpochEnd: %s\t|| SyncProgress: %s %%\n" \
    "$TIP_SLOT_IN_EPOCH" "$TIP_SLOTS_TO_EPOCH_END" "$TIP_SYNC_PROGRESS"
  printf "| hash:\n"
  printf "| %s\n" "$TIP_HASH"
  echo "=================================================================================="

  # 4) DB Status
  echo
  printf "| DB Status: Sync Percent: %s%%\n" "$DB_SYNC"
  echo "=================================================================================="

  # 5) Chain Status
  echo
  printf "| Chain Status:\n"
  printf "| Sidechain:\t, Epoch=%s\t|| Slot=%s\n" "$SIDE_EPOCH" "$SIDE_SLOT"
  printf "| Mainchain:\t, Epoch=%s\t|| Slot=%s\n" "$MAIN_EPOCH" "$MAIN_SLOT"
  echo "=================================================================================="


  # Clear any leftover lines from old output
  tput ed
}

# ------------------- Main Loop -------------------

# Hide cursor; restore on exit
trap "tput cnorm; clear; exit 0" SIGINT SIGTERM
tput civis

while true; do
  # Fetch & parse data
  get_qu_fields
  get_cardano_tip_fields
  get_db_sync_percent
  get_chain_status_fields
  get_kupo_fields

  # Display the updated dashboard
  display_dashboard

  # Sleep before refreshing
  sleep "$REFRESH_INTERVAL"
done

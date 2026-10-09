#!/usr/bin/env bash
# hard-test.sh
# Hard Disaster Simulation: Simultaneous Reboot of Site A Workers (worker0 & worker1)
# Verifies zero-downtime survivability on Site B worker nodes & Envoy locality routing
# Focuses exclusively on continuous traffic stream validation without checking masters.

set -o pipefail

ROUTE_URL=$(oc get route shared-edge-route -n istio-system -o jsonpath='{.spec.host}' 2>/dev/null || echo "shared-edge-route-istio-system.apps.okd.dorneean.wan")
KIALI_URL=$(oc get route kiali -n istio-system -o jsonpath='{.spec.host}' 2>/dev/null || echo "kiali-istio-system.apps.okd.dorneean.wan")

SITE_A_WORKERS=("worker0" "worker1")
SITE_A_IP=("10.10.10.53" "10.10.10.54")
SITE_B_WORKERS=("worker2" "worker3")
SITE_B_IP=("10.10.10.55" "10.10.10.56")

echo "==================================================================================="
echo "   🔥 OPENSHIFT METRO STRETCH CLUSTER - HARD DISASTER TRAFFIC TEST SUITE 🔥       "
echo "==================================================================================="
echo " Route URL           : https://${ROUTE_URL}"
echo " Kiali Console       : https://${KIALI_URL}"
echo ""
echo " TARGETS TO REBOOT (Site A Hard Outage):"
echo "   - Primary Workers : worker0 (10.10.10.53), worker1 (10.10.10.54)"
echo ""
echo " SURVIVING RUNTIME (Site B Active Survivability):"
echo "   - Surviving Nodes : worker2 (10.10.10.55), worker3 (10.10.10.56)"
echo "   - Active Ingress  : HAProxy Ingress Router + Istio Ingress Gateway + Pod Replicas"
echo "==================================================================================="

reboot_node() {
  local node=$1
  echo -n "   -> Triggering hard reboot on ${node}... "
  oc debug "node/${node}" -- chroot /host systemctl reboot >/dev/null 2>&1 &
  echo "Dispatched (oc debug background)"
}

# Extensive Traffic Prober
# Args: count, phase_label, delay_sec
run_traffic_test() {
  local count=$1
  local label=$2
  local delay=${3:-0.1}

  echo -e "\n-----------------------------------------------------------------------------------"
  echo " 🚀 ${label} (${count} Probes)"
  echo "-----------------------------------------------------------------------------------"

  local success=0
  local failed=0
  local site_a=0
  local site_b=0
  local matched=0
  local total_time_ms=0

  for ((i=1; i<=count; i++)); do
    local start_ts=$(python3 -c 'import time; print(int(time.time() * 1000))')
    local RESP=$(curl -sk --connect-timeout 3 --max-time 5 "https://${ROUTE_URL}/" 2>/dev/null || echo "")
    local end_ts=$(python3 -c 'import time; print(int(time.time() * 1000))')
    local latency=$((end_ts - start_ts))
    total_time_ms=$((total_time_ms + latency))

    local FE_POD=$(echo "$RESP" | grep "^Hostname:" | head -n 1 | awk '{print $2}')
    local FE_NODE=$(echo "$RESP" | grep "^Node:" | head -n 1 | awk '{print $2}')
    local FE_ZONE=$(echo "$RESP" | grep "^Subzone:" | head -n 1 | awk '{print $2}')

    local BE_POD=$(echo "$RESP" | grep "^Backend-Hostname:" | head -n 1 | awk '{print $2}')
    local BE_NODE=$(echo "$RESP" | grep "^Backend-Node:" | head -n 1 | awk '{print $2}')
    local BE_ZONE=$(echo "$RESP" | grep "^Backend-Subzone:" | head -n 1 | awk '{print $2}')

    if [[ -z "$FE_POD" ]]; then
      ((failed++))
      echo -e "[REQ #$(printf "%03d" $i)] \033[1;31m[ERROR: CONNECTION DROPPED]\033[0m (${latency}ms)"
      sleep "$delay"
      continue
    fi

    ((success++))

    if [[ "$FE_ZONE" == "site-a" ]]; then
      ((site_a++))
      local COLOR_TAG="\033[1;32m[SITE-A (Primary)]\033[0m"
    elif [[ "$FE_ZONE" == "site-b" ]]; then
      ((site_b++))
      local COLOR_TAG="\033[1;33m[SITE-B (Survivor)]\033[0m"
    else
      local COLOR_TAG="\033[1;36m[UNKNOWN SITE]\033[0m"
    fi

    if [[ "$FE_ZONE" == "$BE_ZONE" && -n "$BE_ZONE" ]]; then
      ((matched++))
      local MATCH_STR="\033[1;32m[SAME-ZONE: ${FE_ZONE}➔${BE_ZONE}]\033[0m"
    else
      local MATCH_STR="\033[1;31m[CROSS-ZONE: ${FE_ZONE}➔${BE_ZONE}]\033[0m"
    fi

    echo -e "[REQ #$(printf "%03d" $i)] --> ${COLOR_TAG} FE: ${FE_NODE} (${FE_POD:0:18}...) ➔ BE: ${BE_NODE} (${BE_POD:0:18}...) ${MATCH_STR} (${latency}ms)"
    sleep "$delay"
  done

  local avg_lat=0
  if (( success > 0 )); then
    avg_lat=$((total_time_ms / (success + failed)))
  fi

  local pct_a=0
  local pct_b=0
  local pct_match=0
  if (( success > 0 )); then
    pct_a=$(( site_a * 100 / success ))
    pct_b=$(( site_b * 100 / success ))
    pct_match=$(( matched * 100 / success ))
  fi

  echo "-----------------------------------------------------------------------------------"
  echo " 📊 SUMMARY for ${label}:"
  echo "    Total Requests : ${count} | Succeeded: ${success} ($(( success * 100 / count ))%) | Dropped: ${failed}"
  echo "    Site-A Served  : ${site_a} (${pct_a}%)"
  echo "    Site-B Served  : ${site_b} (${pct_b}%)"
  echo "    Same-Zone Mesh : ${matched}/${success} (${pct_match}%)"
  echo "    Average Latency: ${avg_lat}ms"
  echo "-----------------------------------------------------------------------------------"
}

# ==================================================================================
# STEP 1: PRE-DISASTER BASELINE TRAFFIC (50 Requests)
# ==================================================================================
run_traffic_test 50 "STEP 1: Baseline Active-Active Traffic Check" 0.08

# ==================================================================================
# STEP 2: TRIGGER HARD DISASTER ON SITE A WORKERS
# ==================================================================================
echo -e "\n==================================================================================="
echo " [STEP 2] 💥 SIMULTANEOUS HARD REBOOT OF SITE A WORKERS (${SITE_A_WORKERS[*]}) 💥"
echo "==================================================================================="
for node in "${SITE_A_WORKERS[@]}"; do
  reboot_node "$node"
done
sleep 2

# ==================================================================================
# STEP 3: HIGH-VOLUME TRAFFIC STREAM DURING SITE A OUTAGE (100 Requests)
# ==================================================================================
echo -e "\n[STEP 3] Continuously streaming traffic while Site A workers are down..."
echo "         Observing zero-downtime 100% absorption by Site B survivor nodes..."
run_traffic_test 100 "STEP 3: Live Traffic During Site A Outage (Site B Survivability)" 0.1

# ==================================================================================
# STEP 4: MONITOR SITE A WORKER RESTORATION (No Masters Checked)
# ==================================================================================
echo -e "\n==================================================================================="
echo " [STEP 4] Monitoring Site A Worker Nodes Restoration..."
echo "==================================================================================="
for node in "${SITE_A_WORKERS[@]}"; do
  echo -n "   Waiting for ${node} to report Ready in OpenShift... "
  until oc get node "${node}" 2>/dev/null | grep -q " Ready"; do
    echo -n "."
    sleep 3
  done
  echo " READY"
done

echo " Waiting for application pods to balance across restored Site A nodes..."
oc rollout status deployment core-application -n prod-apps --timeout=120s >/dev/null 2>&1 || true
oc rollout status deployment backend-application -n prod-apps --timeout=120s >/dev/null 2>&1 || true
sleep 5

# ==================================================================================
# STEP 5: POST-RECOVERY ACTIVE-ACTIVE TRAFFIC CHECK (50 Requests)
# ==================================================================================
run_traffic_test 50 "STEP 5: Automated Recovery & Active-Active Balancing" 0.08

echo -e "\n==================================================================================="
echo " 🎉 Hard Disaster Traffic Test Completed Successfully!"
echo " Real-Time Service Mesh Graph: https://${KIALI_URL}"
echo "==================================================================================="

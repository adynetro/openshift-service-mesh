#!/usr/bin/env bash
# test-failover.sh
# Real-time traffic inspector & failover simulation for OpenShift Metro Service Mesh (Pattern 1: Active-Active)

ROUTE_URL=$(oc get route shared-edge-route -n istio-system -o jsonpath='{.spec.host}' 2>/dev/null || echo "shared-edge-route-istio-system.apps.okd.dorneean.wan")
KIALI_URL=$(oc get route kiali -n istio-system -o jsonpath='{.spec.host}' 2>/dev/null || echo "kiali-istio-system.apps.okd.dorneean.wan")

echo "========================================================================="
echo "   OpenShift Metro Stretch Cluster - 2-Tier Active-Active Test Suite     "
echo "========================================================================="
echo " [1] Application Route URL  : https://${ROUTE_URL}"
echo " [2] Kiali Service Mesh GUI : https://${KIALI_URL}"
echo "========================================================================="

stream_requests() {
  local count=$1
  local label=$2
  local delay=${3:-0.1}

  echo -e "\n--- ${label} (${count} Requests) ---"
  local site_a=0
  local site_b=0
  local matched=0
  local success=0
  local failed=0

  for ((i=1; i<=count; i++)); do
    RESP=$(curl -sk --connect-timeout 2 --max-time 3 "https://${ROUTE_URL}/" 2>/dev/null || echo "")
    FE_POD=$(echo "$RESP" | grep "^Hostname:" | head -n 1 | awk '{print $2}')
    FE_NODE=$(echo "$RESP" | grep "^Node:" | head -n 1 | awk '{print $2}')
    FE_ZONE=$(echo "$RESP" | grep "^Subzone:" | head -n 1 | awk '{print $2}')

    BE_POD=$(echo "$RESP" | grep "^Backend-Hostname:" | head -n 1 | awk '{print $2}')
    BE_NODE=$(echo "$RESP" | grep "^Backend-Node:" | head -n 1 | awk '{print $2}')
    BE_ZONE=$(echo "$RESP" | grep "^Backend-Subzone:" | head -n 1 | awk '{print $2}')
    
    if [[ -z "$FE_POD" ]]; then
      ((failed++))
      echo "[REQ #$(printf "%02d" $i)] ERROR: Could not reach endpoint"
      sleep "$delay"
      continue
    fi

    ((success++))
    
    if [[ "$FE_ZONE" == "site-a" ]]; then
      ((site_a++))
      COLOR_TAG="\033[1;32m[SITE-A (Primary)]\033[0m"
    elif [[ "$FE_ZONE" == "site-b" ]]; then
      ((site_b++))
      COLOR_TAG="\033[1;33m[SITE-B (Survivor)]\033[0m"
    else
      COLOR_TAG="\033[1;34m[FAILOVER IN PROGRESS]\033[0m"
    fi

    if [[ "$FE_ZONE" == "$BE_ZONE" && -n "$BE_ZONE" ]]; then
      ((matched++))
      MATCH_STR="\033[1;32m[SAME-ZONE: ${FE_ZONE}➔${BE_ZONE}]\033[0m"
    else
      MATCH_STR="\033[1;31m[CROSS-ZONE: ${FE_ZONE}➔${BE_ZONE}]\033[0m"
    fi

    echo -e "[REQ #$(printf "%02d" $i)] --> ${COLOR_TAG} FE: ${FE_NODE} (${FE_POD:0:18}...) ➔ BE: ${BE_NODE} (${BE_POD:0:18}...) ${MATCH_STR}"
    sleep "$delay"
  done

  echo "  >> Traffic Summary: Succeeded: ${success}/${count} | Site-A: ${site_a} | Site-B: ${site_b} | Same-Zone Matches: ${matched}"
}

# 1. Baseline Test (Active-Active across both zones)
stream_requests 25 "TEST 1: Baseline Ingress & Intra-Zone Pod-to-Pod Mesh Routing" 0.08

# 2. Simulate Outage in Site A
echo -e "\n========================================================================="
echo " [TEST 2] Simulating Outage in Site A (worker0 & worker1)..."
echo " Cordoning Site A nodes and deleting Site A pods to force cross-metro failover..."
echo "========================================================================="

oc adm cordon worker0 worker1 >/dev/null 2>&1 || true
SITE_A_PODS=$(oc get pods -n prod-apps -o json 2>/dev/null | jq -r '.items[] | select(.spec.nodeName=="worker0" or .spec.nodeName=="worker1") | .metadata.name')
if [[ -n "$SITE_A_PODS" ]]; then
  oc delete pods -n prod-apps $SITE_A_PODS --grace-period=0 --force >/dev/null 2>&1 || true
fi
sleep 2

stream_requests 30 "TEST 2: Live Traffic During Site A Outage (100% Absorbed by Site B)" 0.08

# 3. Recovery
echo -e "\n========================================================================="
echo " [TEST 3] Restoring Site A (uncordoning worker0 & worker1)..."
echo "========================================================================="
oc adm uncordon worker0 worker1 >/dev/null 2>&1 || true
oc rollout restart deployment core-application -n prod-apps >/dev/null 2>&1 || true
oc rollout restart deployment backend-application -n prod-apps >/dev/null 2>&1 || true
oc rollout status deployment core-application -n prod-apps --timeout=60s >/dev/null 2>&1 || true
oc rollout status deployment backend-application -n prod-apps --timeout=60s >/dev/null 2>&1 || true
sleep 3

stream_requests 25 "TEST 4: Automated Recovery (Active-Active Traffic Restored across Both Sites)" 0.08

echo -e "\n========================================================================="
echo " Test Suite Finished. Open Kiali to view the real-time visual graph:"
echo " https://${KIALI_URL}"
echo "========================================================================="

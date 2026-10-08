#!/usr/bin/env bash
# test-connectivity.sh
# Real-time Continuous Connectivity & Health Inspector for OpenShift Metro Service Mesh
# Streams traffic indefinitely (or for N probes) and summarizes stats upon exit (Ctrl+C).

set -o pipefail

# Argument Parsing
# If first argument is a number, run that many probes; otherwise run indefinitely (0 = infinite)
if [[ "$1" =~ ^[0-9]+$ ]]; then
  MAX_PROBES=$1
  DELAY=${2:-0.15}
else
  MAX_PROBES=0 # 0 means indefinite
  DELAY=${1:-0.15}
fi

# Colors
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_BLUE="\033[1;34m"
C_CYAN="\033[1;36m"
C_RED="\033[1;31m"
C_MAGENTA="\033[1;35m"
C_DIM="\033[2m"

# Discover route URLs from cluster
ROUTE_URL=$(oc get route shared-edge-route -n istio-system -o jsonpath='{.spec.host}' 2>/dev/null || echo "shared-edge-route-istio-system.apps.okd.dorneean.wan")
KIALI_URL=$(oc get route kiali -n istio-system -o jsonpath='{.spec.host}' 2>/dev/null || echo "kiali-istio-system.apps.okd.dorneean.wan")
GRAFANA_URL=$(oc get route grafana -n istio-system -o jsonpath='{.spec.host}' 2>/dev/null || echo "grafana-istio-system.apps.okd.dorneean.wan")

echo -e "${C_CYAN}===================================================================================${C_RESET}"
echo -e "${C_BOLD}   🌐 OPENSHIFT METRO STRETCH CLUSTER - CONTINUOUS CONNECTIVITY INSPECTOR 🌐      ${C_RESET}"
echo -e "${C_CYAN}===================================================================================${C_RESET}"
echo -e " [1] Application Ingress Route : https://${ROUTE_URL}"
echo -e " [2] Kiali Service Mesh Console: https://${KIALI_URL}"
echo -e " [3] Grafana Dashboards Route  : https://${GRAFANA_URL}"
if (( MAX_PROBES > 0 )); then
  echo -e " Execution Mode                : ${C_BOLD}Fixed ${MAX_PROBES} Probes${C_RESET} (Delay: ${DELAY}s)"
else
  echo -e " Execution Mode                : ${C_BOLD}${C_GREEN}Continuous (Runs Indefinitely until Ctrl+C)${C_RESET} (Delay: ${DELAY}s)"
fi
echo -e "${C_CYAN}===================================================================================${C_RESET}\n"

# ----------------------------------------------------------------------------------
# SECTION 1: INFRASTRUCTURE & WORKLOAD TOPOLOGY
# ----------------------------------------------------------------------------------
echo -e "${C_BOLD}[STAGE 1] Cluster Topology & Ingress Placement${C_RESET}"

echo -e "\n--- Worker Nodes Topology ---"
oc get nodes -l node-role.kubernetes.io/worker -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[-1].type,ZONE:.metadata.labels.topology\.kubernetes\.io\/zone,SUBZONE:.metadata.labels.topology\.istio\.io\/subzone,INTERNAL-IP:.status.addresses[0].address' 2>/dev/null || oc get nodes -l node-role.kubernetes.io/worker

echo -e "\n--- Ingress Gateway Pods (istio-system) ---"
oc get pods -n istio-system -l app=istio-ingressgateway -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName,IP:.status.podIP' 2>/dev/null || oc get pods -n istio-system -l app=istio-ingressgateway

echo -e "\n--- Application Pods (prod-apps) ---"
oc get pods -n prod-apps -l app=core-app -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[*].ready,NODE:.spec.nodeName,IP:.status.podIP' 2>/dev/null || oc get pods -n prod-apps

# ----------------------------------------------------------------------------------
# SECTION 2: ENDPOINT HTTP STATUS CHECKS
# ----------------------------------------------------------------------------------
echo -e "\n${C_BOLD}[STAGE 2] Checking HTTPS Endpoints Reachability...${C_RESET}"

check_endpoint() {
  local name=$1
  local url=$2
  local http_code=$(curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 5 "$url" 2>/dev/null || echo "000")
  
  if [[ "$http_code" =~ ^(200|302|401|403)$ ]]; then
    echo -e "   -> ${name} [${url}]: ${C_GREEN}ONLINE (HTTP ${http_code})${C_RESET}"
  else
    echo -e "   -> ${name} [${url}]: ${C_RED}FAILED (HTTP ${http_code})${C_RESET}"
  fi
}

check_endpoint "Application Ingress" "https://${ROUTE_URL}/"
check_endpoint "Kiali Mesh Console " "https://${KIALI_URL}/"
check_endpoint "Grafana Dashboard  " "https://${GRAFANA_URL}/"

# ----------------------------------------------------------------------------------
# SECTION 3: CONTINUOUS TRAFFIC PROBING
# ----------------------------------------------------------------------------------
echo -e "\n${C_BOLD}[STAGE 3] Live Traffic Stream (Press Ctrl+C at any time to display summary)...${C_RESET}"
echo -e "-----------------------------------------------------------------------------------"

success_count=0
failed_count=0
site_a_count=0
site_b_count=0
total_latency_ms=0
min_latency_ms=999999
max_latency_ms=0
iteration=0

declare -A pod_hits

print_summary() {
  local total=$((success_count + failed_count))
  if (( total == 0 )); then
    echo -e "\nNo probes executed."
    exit 0
  fi

  local avg_latency_ms=0
  if (( success_count > 0 )); then
    avg_latency_ms=$((total_latency_ms / total))
  else
    min_latency_ms=0
  fi

  local pct_a=0
  local pct_b=0
  if (( success_count > 0 )); then
    pct_a=$(( site_a_count * 100 / success_count ))
    pct_b=$(( site_b_count * 100 / success_count ))
  fi

  echo -e "\n\n${C_CYAN}===================================================================================${C_RESET}"
  echo -e "${C_BOLD}   📊 LIVE CONNECTIVITY & TRAFFIC DISTRIBUTION SUMMARY REPORT 📊                  ${C_RESET}"
  echo -e "${C_CYAN}===================================================================================${C_RESET}"
  echo -e "  Total Requests Probed : ${C_BOLD}${total}${C_RESET}"
  echo -e "  Successful Probes     : ${C_GREEN}${success_count}/${total} ($(( success_count * 100 / total ))%)${C_RESET}"
  echo -e "  Failed / Dropped      : ${C_RED}${failed_count}${C_RESET}"
  echo -e "  Site-A (Primary) Hits : ${C_GREEN}${site_a_count} (${pct_a}%)${C_RESET}"
  echo -e "  Site-B (Survivor) Hits: ${C_YELLOW}${site_b_count} (${pct_b}%)${C_RESET}"
  echo -e "  Latency Profile       : Min: ${min_latency_ms}ms | Avg: ${avg_latency_ms}ms | Max: ${max_latency_ms}ms"
  echo -e "-----------------------------------------------------------------------------------"
  echo -e "  Pod-Level Distribution:"
  for pod in "${!pod_hits[@]}"; do
    local pod_cnt=${pod_hits[$pod]}
    local pod_pct=0
    if (( success_count > 0 )); then
      pod_pct=$(( pod_cnt * 100 / success_count ))
    fi
    echo -e "    • ${pod}: ${pod_cnt} requests (${pod_pct}%)"
  done
  echo -e "${C_CYAN}===================================================================================${C_RESET}"
}

# Trap Ctrl+C (SIGINT) and termination (SIGTERM)
trap 'print_summary; exit 0' INT TERM

while true; do
  ((iteration++))
  
  if (( MAX_PROBES > 0 && iteration > MAX_PROBES )); then
    break
  fi

  TIMESTAMP=$(date +"%H:%M:%S")
  start_ts=$(python3 -c 'import time; print(int(time.time() * 1000))')
  RESP=$(curl -sk --connect-timeout 3 --max-time 5 "https://${ROUTE_URL}/" 2>/dev/null || echo "")
  end_ts=$(python3 -c 'import time; print(int(time.time() * 1000))')
  
  latency=$((end_ts - start_ts))
  total_latency_ms=$((total_latency_ms + latency))
  
  if (( latency < min_latency_ms )); then min_latency_ms=$latency; fi
  if (( latency > max_latency_ms )); then max_latency_ms=$latency; fi

  POD_NAME=$(echo "$RESP" | grep "Hostname:" | awk '{print $2}')

  if [[ -z "$POD_NAME" ]]; then
    ((failed_count++))
    echo -e "[${TIMESTAMP}] [REQ #$(printf "%04d" $iteration)] ${C_RED}[ERROR: CONNECTION DROPPED]${C_RESET} (${latency}ms) ${C_DIM}(A:${site_a_count} B:${site_b_count} Fail:${failed_count})${C_RESET}"
    sleep "$DELAY"
    continue
  fi

  ((success_count++))
  ((pod_hits["$POD_NAME"]++))

  IP_ADDR=$(echo "$RESP" | grep -E "IP: 10\." | head -n 1 | awk '{print $2}')

  if [[ "$IP_ADDR" =~ ^10\.128 || "$IP_ADDR" =~ ^10\.129 ]]; then
    ((site_a_count++))
    COLOR_TAG="${C_GREEN}[SITE-A (Primary)]${C_RESET}"
  elif [[ "$IP_ADDR" =~ ^10\.130 || "$IP_ADDR" =~ ^10\.131 ]]; then
    ((site_b_count++))
    COLOR_TAG="${C_YELLOW}[SITE-B (Survivor)]${C_RESET}"
  else
    COLOR_TAG="${C_CYAN}[PROCESSING]${C_RESET}"
  fi

  echo -e "[${TIMESTAMP}] [REQ #$(printf "%04d" $iteration)] --> ${COLOR_TAG} Pod: ${POD_NAME} | IP: ${IP_ADDR} (${latency}ms) ${C_DIM}(A:${site_a_count} B:${site_b_count})${C_RESET}"
  sleep "$DELAY"
done

print_summary

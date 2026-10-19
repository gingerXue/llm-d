#!/usr/bin/env bash
# Verify a deployed MThreads vLLM 1P1D TP8 service with Mooncake Store.
# Default mode is non-disruptive. Use --restart-decode for Store Get.
set -euo pipefail

NAMESPACE="${NAMESPACE:-llm-d-mt}"
MODEL="${MODEL:-DeepSeek-V4-Flash}"
EPP_SERVICE="${EPP_SERVICE:-pd-disaggregation-epp}"
DECODE_DEPLOYMENT="${DECODE_DEPLOYMENT:-pd-disaggregation-mthreads-deepseek-v4-decode}"
EXPECTED_CLIENTS="${EXPECTED_CLIENTS:-2}"
EPP_LOCAL_PORT="${EPP_LOCAL_PORT:-18080}"
DECODE_LOCAL_PORT="${DECODE_LOCAL_PORT:-18200}"
PROMPT_REPEAT="${PROMPT_REPEAT:-300}"
PROMPT_TAG="${PROMPT_TAG:-$(date +%s)}"
REQUEST_FILE="${REQUEST_FILE:-/tmp/llm-d-${MODEL}-mooncake-request.json}"
SSD_WAIT_SECONDS="${SSD_WAIT_SECONDS:-180}"
RESTART_DECODE=0
PF_PIDS=()
RESPONSE_FILE=""

usage() {
  cat <<'EOF'
Usage: verify_mthreads_1p1d_mooncake_store.sh [--restart-decode]

Default mode verifies readiness, EPP/P2P inference, Store Put and SSD offload write.
--restart-decode additionally restarts Decode and verifies Store Get directly.
Environment overrides: NAMESPACE MODEL EPP_SERVICE DECODE_DEPLOYMENT EXPECTED_CLIENTS
EPP_LOCAL_PORT DECODE_LOCAL_PORT PROMPT_REPEAT PROMPT_TAG REQUEST_FILE SSD_WAIT_SECONDS
EOF
}

purpose() { printf '\n[%s] %s\n' "$1" "$2"; }
die() { echo "ERROR: $*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

cleanup() {
  local pid
  for pid in "${PF_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  [[ -z "$RESPONSE_FILE" ]] || rm -f "$RESPONSE_FILE"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

get_pod() {
  kubectl -n "$NAMESPACE" get pod \
    -l "llm-d.ai/model=${MODEL},llm-d.ai/role=$1" \
    -o jsonpath='{.items[0].metadata.name}'
}

wait_local_http() {
  local url="$1" i
  for i in $(seq 1 30); do
    curl -fsS --max-time 2 "$url" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

wait_local_port() {
  local url="$1" i
  for i in $(seq 1 30); do
    curl -sS --max-time 2 "$url" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

start_port_forward() {
  kubectl -n "$NAMESPACE" port-forward "$1" "$2:$3" \
    >"/tmp/llm-d-mooncake-pf-$2.log" 2>&1 &
  PF_PIDS+=("$!")
}

print_master_metrics() {
  master_metrics
}

master_metrics() {
  kubectl -n mooncake exec "$MASTER" -- sh -c \
    'curl -fsS http://127.0.0.1:9003/metrics' |
    grep -E 'master_(allocated_bytes|allocated_file_size_bytes|total_file_capacity_bytes|key_count|batch_put_end_items_total|put_start_requests_total|put_end_requests_total|get_replica_list_requests_total)|valid_get_nums_|total_get_nums_' |
    grep -vE 'HELP|TYPE' || true
}

print_store_metrics() {
  kubectl -n "$NAMESPACE" exec "$1" -c modelserver -- sh -c \
    "curl -fsS http://127.0.0.1:$2/metrics" |
    grep -E 'mooncake_store_operation_(total|keys_total|bytes_total|failed_keys_total)|prompt_tokens_by_source_total' | grep -vE '^#' || true
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --restart-decode|--store-get) RESTART_DECODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

require_cmd kubectl
require_cmd curl
require_cmd python3

purpose "1/8" "确认 P/D、EPP 和 Mooncake 控制面状态；不修改资源。"
kubectl -n "$NAMESPACE" get pods -l "llm-d.ai/model=${MODEL}" -o wide
kubectl -n "$NAMESPACE" get deploy "$EPP_SERVICE" -o wide
kubectl -n mooncake get pods -o wide
PODP="$(get_pod prefill)"
PODD="$(get_pod decode)"
[[ -n "$PODP" ]] || die "Prefill Pod not found"
[[ -n "$PODD" ]] || die "Decode Pod not found"
kubectl -n "$NAMESPACE" wait --for=condition=Ready pod "$PODP" --timeout=5s >/dev/null || die "Prefill is not Ready"
kubectl -n "$NAMESPACE" wait --for=condition=Ready pod "$PODD" --timeout=5s >/dev/null || die "Decode is not Ready"
MASTER="$(kubectl -n mooncake get pod -l app.kubernetes.io/component=master-store -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$MASTER" ]] || die "Mooncake Master Pod not found"

purpose "2/8" "确认预期数量的 Mooncake Client 均 Ready，保证 Store 数据面可用。"
kubectl -n mooncake get pod -l app.kubernetes.io/component=client -o wide
CLIENT_COUNT="$(kubectl -n mooncake get pod -l app.kubernetes.io/component=client -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' | grep -c '^true$' || true)"
[[ "$CLIENT_COUNT" -ge "$EXPECTED_CLIENTS" ]] || die "expected $EXPECTED_CLIENTS Ready Mooncake Clients, got $CLIENT_COUNT"

purpose "3/8" "记录 Store 和 vLLM 指标基线，用增量判断 Put/Get，而不是只看 HTTP 200。"
MASTER_BASELINE="$(master_metrics)"
echo '--- Mooncake Master baseline ---'; echo "$MASTER_BASELINE"
echo '--- Prefill Store baseline ---'; print_store_metrics "$PODP" 8000
echo '--- Decode Store baseline ---'; print_store_metrics "$PODD" 8200

purpose "4/8" "生成超过一个 KV block 的固定请求，后续 Store Get 使用同一请求。"
python3 -c 'import json,sys; path,model,repeat,tag=sys.argv[1],sys.argv[2],int(sys.argv[3]),sys.argv[4]; prompt=f"Double node Mooncake Store functional validation run {tag} token "*repeat; json.dump({"model":model,"messages":[{"role":"user","content":prompt}],"max_tokens":16,"temperature":0},open(path,"w",encoding="utf-8"))' "$REQUEST_FILE" "$MODEL" "$PROMPT_REPEAT" "$PROMPT_TAG"
echo "Prompt tag: $PROMPT_TAG"
wc -c "$REQUEST_FILE"

purpose "5/8" "通过 EPP 验证 P/D 路由、P2P KV 传输和实际生成。"
start_port_forward "svc/${EPP_SERVICE}" "$EPP_LOCAL_PORT" 80
wait_local_port "http://127.0.0.1:${EPP_LOCAL_PORT}/v1/models" || die "EPP port-forward not ready"
RESPONSE_FILE="$(mktemp)"
HTTP_CODE="$(curl -sS --max-time 600 -H 'Content-Type: application/json' --data-binary "@${REQUEST_FILE}" "http://127.0.0.1:${EPP_LOCAL_PORT}/v1/chat/completions" -o "$RESPONSE_FILE" -w '%{http_code}')"
cat "$RESPONSE_FILE"; echo "HTTP ${HTTP_CODE}"
[[ "$HTTP_CODE" == "200" ]] || die "EPP inference request failed"
echo '--- Prefill P2P logs ---'
kubectl -n "$NAMESPACE" logs "$PODP" -c modelserver --since=15m | grep -E 'POST /v1/chat|KV Transfer metrics|successful transfers|failed transfers|ret=-1|ERROR|Traceback' || true
echo '--- Decode P2P logs ---'
kubectl -n "$NAMESPACE" logs "$PODD" -c modelserver --since=15m | grep -E 'POST /v1/chat|external prefix|external_kv_transfer|failed transfers|ret=-1|ERROR|Traceback' || true

purpose "6/8" "确认 Store Put 和异步 SSD offload 均完成；记录内存、磁盘字节增量。"
BASE_PUT="$(awk '$1 == "master_batch_put_end_items_total" {print $2}' <<< "$MASTER_BASELINE")"
BASE_BYTES="$(awk '$1 == "master_allocated_bytes" {print $2}' <<< "$MASTER_BASELINE")"
BASE_FILE_BYTES="$(awk '$1 == "master_allocated_file_size_bytes" {print $2}' <<< "$MASTER_BASELINE")"
[[ -n "$BASE_PUT" && -n "$BASE_BYTES" && -n "$BASE_FILE_BYTES" ]] || die "missing Master baseline metrics"
for ((elapsed=0; elapsed<=SSD_WAIT_SECONDS; elapsed+=5)); do
  MASTER_AFTER_PUT="$(master_metrics)"
  AFTER_PUT="$(awk '$1 == "master_batch_put_end_items_total" {print $2}' <<< "$MASTER_AFTER_PUT")"
  AFTER_BYTES="$(awk '$1 == "master_allocated_bytes" {print $2}' <<< "$MASTER_AFTER_PUT")"
  AFTER_FILE_BYTES="$(awk '$1 == "master_allocated_file_size_bytes" {print $2}' <<< "$MASTER_AFTER_PUT")"
  if [[ -n "$AFTER_PUT" && -n "$AFTER_BYTES" && -n "$AFTER_FILE_BYTES" ]] &&
    awk -v bp="$BASE_PUT" -v ap="$AFTER_PUT" -v bf="$BASE_FILE_BYTES" \
      -v af="$AFTER_FILE_BYTES" 'BEGIN {exit !(ap > bp && af > bf)}'; then
    break
  fi
  if (( elapsed >= SSD_WAIT_SECONDS )); then
    awk -v before="$BASE_PUT" -v after="$AFTER_PUT" \
      'BEGIN {exit !(after > before)}' || die "Store batch PutEnd did not increase within ${SSD_WAIT_SECONDS}s"
    die "SSD offload bytes did not increase within ${SSD_WAIT_SECONDS}s"
  fi
  sleep 5
done
echo "$MASTER_AFTER_PUT"
echo "PASS: Store write completed (batch PutEnd items: $BASE_PUT -> $AFTER_PUT; allocated bytes: $BASE_BYTES -> $AFTER_BYTES)"
echo "PASS: SSD offload observed (file bytes: $BASE_FILE_BYTES -> $AFTER_FILE_BYTES)"
for client in $(kubectl -n mooncake get pod -l app.kubernetes.io/component=client -o name); do
  printf '%s disk usage: ' "$client"
  kubectl -n mooncake exec "$client" -- du -sh /data/mooncake-offload
done

if (( RESTART_DECODE == 0 )); then
  echo 'Store Get skipped. Re-run with --restart-decode to verify load_get.'
  exit 0
fi

purpose "7/8" "重启 Decode 清空本地 KV，再直连 Decode；这是 Store Get 验证，不是 P2P 验证。"
kubectl -n "$NAMESPACE" rollout restart "deploy/$DECODE_DEPLOYMENT"
kubectl -n "$NAMESPACE" rollout status "deploy/$DECODE_DEPLOYMENT" --timeout=35m
PODD="$(get_pod decode)"
start_port_forward "pod/${PODD}" "$DECODE_LOCAL_PORT" 8200
wait_local_http "http://127.0.0.1:${DECODE_LOCAL_PORT}/health" || die "Decode port-forward not ready"
MASTER_BEFORE_GET="$(master_metrics)"
BASE_VALID_GET="$(awk '$1 == "valid_get_nums_" {print $2}' <<< "$MASTER_BEFORE_GET")"
[[ -n "$BASE_VALID_GET" ]] || die "missing Master valid_get_nums_ baseline"
HTTP_CODE="$(curl -sS --max-time 600 -H 'Content-Type: application/json' --data-binary "@${REQUEST_FILE}" "http://127.0.0.1:${DECODE_LOCAL_PORT}/v1/chat/completions" -o "$RESPONSE_FILE" -w '%{http_code}')"
cat "$RESPONSE_FILE"; echo "HTTP ${HTTP_CODE}"
[[ "$HTTP_CODE" == "200" ]] || die "direct Decode request failed"

purpose "8/8" "确认 Store Get 真实读取 KV，检查 load_get、读取字节数和失败 key。"
echo '--- Decode Store metrics ---'; print_store_metrics "$PODD" 8200
echo '--- Mooncake Master Get metrics ---'; print_master_metrics
MASTER_AFTER_GET="$(master_metrics)"
AFTER_VALID_GET="$(awk '$1 == "valid_get_nums_" {print $2}' <<< "$MASTER_AFTER_GET")"
awk -v before="$BASE_VALID_GET" -v after="$AFTER_VALID_GET" \
  'BEGIN {exit !(after > before)}' || die "Master valid Get did not increase: $BASE_VALID_GET -> $AFTER_VALID_GET"
METRICS="$(kubectl -n "$NAMESPACE" exec "$PODD" -c modelserver -- sh -c 'curl -fsS http://127.0.0.1:8200/metrics')"
if echo "$METRICS" | grep -Eq 'operation="load_get".* [1-9][0-9]*\.?[0-9]*$'; then
  echo 'Decode load_get counter observed.'
else
  echo 'Decode load_get metric unavailable; Master valid_get_nums_ delta is the required evidence.'
fi
if echo "$METRICS" | grep 'mooncake_store_operation_failed_keys_total.*operation="load_get"' | grep -Eq ' [1-9]'; then
  die 'Store load_get reported failed keys'
fi
rm -f "$RESPONSE_FILE"
echo "PASS: Store Get observed by Master ($BASE_VALID_GET -> $AFTER_VALID_GET) with zero reported failed keys."
echo 'Mooncake Store Put/Get verification completed successfully.'

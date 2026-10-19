# MThreads vLLM DeepSeek-V4 双机 1P1D TP=8

该 overlay 以现有 MThreads vLLM 单机 1P1D 配置为基础，生成：

- Prefill：`worker36010`，TP=8，申请 8 个 `mthreads.com/gpu`；
- Decode：`worker36018`，TP=8，申请 8 个 `mthreads.com/gpu`；
- 1P1D 资源参数：Prefill 131072/16/0.80，Decode 131072/64/0.80；两端
  开启 chunked prefill，`max-num-batched-tokens=8192`，Decode 使用
  FULL_DECODE_ONLY capture sizes；
- 模型：`/ipfs/test/models/DeepSeek-V4-Flash-0731-FP8-mt/`；
- served model name：`DeepSeek-V4-Flash`；
- 模型服务镜像：`registry.mthreads.com/mcconline/inference/vllm:v0.28.0-ph1-5.2.0-torch2.11.0.post2-20261001`；
- P/D KV：`MooncakeConnector`，`mooncake_protocol=tcp` 且设置
  `MC_FORCE_TCP=1`；
- 共享 KV Store：`MooncakeStoreConnector`，`MultiConnector`；
- Mooncake Store：standalone-store 模式，TCP 配置，Master 和 Client 资源位于
  `mooncake` namespace。

DeepSeek-V4 的配置包含 MoE 专家，因此两端同时设置了
`--enable-expert-parallel`；这不改变 TP=8 的要求。

## 复测前检查（2026-10-16）

租约未到位时只执行本节和 Dry-run，**不要 apply、扩容或重启占卡 Pod**。
`worker36010` 为专属节点；`worker36018` 的 8 卡租约仍需先确认。当前集群中
`pd-disaggregation-mthreads-vllm-{prefill,decode}` 单机 Qwen3-32B Deployment
占用 `worker36010` 的 GPU，双机 Prefill 启动前须确认归属并将它们缩容到 0。
不要清理其他人的容器或 Pod。

~~~bash
kubectl get nodes worker36010 worker36018 -o wide
kubectl -n llm-d-mt get deploy,pod -o wide
kubectl -n llm-d-mt get deploy \
  pd-disaggregation-mthreads-vllm-prefill \
  pd-disaggregation-mthreads-vllm-decode \
  pd-disaggregation-mthreads-deepseek-v4-prefill \
  pd-disaggregation-mthreads-deepseek-v4-decode
kubectl get ns mooncake --ignore-not-found
~~~

确认两节点上的模型目录均存在、containerd 已有 `post2-20261001` 模型镜像，
`post1-20260915` Master/Client 镜像和 routing-sidecar 镜像；并检查
Pod 网络上的 HTTP 8000/8200、bootstrap 8998、Master 50051、Client 50052
及 Mooncake 动态 TCP 数据端口。仅能连通 8998 不代表 KV 数据传输可用。

## Dry-run

只渲染并校验模型端资源，不创建 Pod：

~~~bash
export REPO_ROOT=$(git rev-parse --show-toplevel)
export NAMESPACE=llm-d-mt
export OVERLAY=${REPO_ROOT}/guides/pd-disaggregation/modelserver/mthreads/vllm/multi-node-1p1d-tp8

kubectl kustomize "${OVERLAY}"
kubectl apply --dry-run=client -n "${NAMESPACE}" -k "${OVERLAY}"
kubectl apply --dry-run=server -n "${NAMESPACE}" -k "${OVERLAY}"
~~~

Mooncake Master 和 Client 资源单独渲染：

~~~bash
export STORE_OVERLAY=${OVERLAY}/mooncake-master-store
kubectl kustomize "${STORE_OVERLAY}"
kubectl apply --dry-run=client -k "${STORE_OVERLAY}"

export CLIENT_OVERLAY=${OVERLAY}/mooncake-client
kubectl kustomize "${CLIENT_OVERLAY}"
kubectl apply --dry-run=client -k "${CLIENT_OVERLAY}"
~~~

如果集群尚未创建 `mooncake` namespace，直接对包含 Namespace 的完整 Master
overlay 做 server dry-run 时，后续 namespaced 资源可能报告 namespace 不存在；
client dry-run 和完整渲染可用于检查资源结构。实际部署时先应用 Master 和 Client
overlay，再应用模型 overlay。

## Actual apply order

以下命令只能在 `worker36018` 的租约到位并完成上述检查后执行。当前 overlay
不会自动导入镜像、申请租约或处理 GPU 资源冲突。Mooncake Client DaemonSet
只调度到 `worker36010` 和 `worker36018`。

~~~bash
kubectl -n llm-d-mt scale deploy \
  pd-disaggregation-mthreads-vllm-prefill \
  pd-disaggregation-mthreads-vllm-decode --replicas=0
kubectl -n llm-d-mt rollout status deploy/pd-disaggregation-mthreads-vllm-prefill --timeout=5m
kubectl -n llm-d-mt rollout status deploy/pd-disaggregation-mthreads-vllm-decode --timeout=5m
kubectl -n llm-d-mt wait --for=delete pod \
  -l 'llm-d.ai/model=Qwen3-32B' --timeout=5m

kubectl apply -k "${STORE_OVERLAY}"
kubectl -n mooncake rollout status deploy/mooncake-master-store --timeout=5m
kubectl apply -k "${CLIENT_OVERLAY}"
kubectl -n mooncake rollout status daemonset/mooncake-client --timeout=5m
kubectl -n mooncake get pods -o wide
kubectl apply -n "${NAMESPACE}" -k "${OVERLAY}"
kubectl -n "${NAMESPACE}" rollout status \
  deploy/pd-disaggregation-mthreads-deepseek-v4-prefill --timeout=30m
kubectl -n "${NAMESPACE}" rollout status \
  deploy/pd-disaggregation-mthreads-deepseek-v4-decode --timeout=30m
~~~

Client 应在两节点各有一个 Ready Pod，Master 日志应显示两个 Client 注册。
应用模型 overlay 会把现存同名 DeepSeek Deployment 从 `replicas=0` 恢复到 1。
模型 Pod 的启动/退出状态应结合日志判断；单纯 rollout 超时不是 KV 传输结论。

本集群的 `llm-d-mt` namespace 已有 optimized-baseline release，其 Envoy
ConfigMap 名为 `envoy`；P/D Router 使用专用 values 避免同名冲突，并把 EPP
调度到已有镜像缓存的 `worker36010`：

~~~bash
helm upgrade --install pd-disaggregation \
  oci://ghcr.io/llm-d/charts/llm-d-router-standalone \
  --version v0 -n "${NAMESPACE}" \
  -f "${REPO_ROOT}/guides/recipes/router/base.values.yaml" \
  -f "${REPO_ROOT}/guides/pd-disaggregation/router/pd-disaggregation.values.yaml" \
  -f "${OVERLAY}/router.values.yaml"
kubectl get pods,inferencepool -n "${NAMESPACE}"
~~~

最后通过 `pd-disaggregation-epp` Service 的 OpenAI 兼容端点发请求。
验收必须看到非空生成 token、正常的 `finish_reason`、EPP 同时发现 Prefill 和
Decode、两端请求日志以及没有 KV transfer 错误；仅 Pod `Running` 或 HTTP 200
不够。直连 `MooncakeConnector` 的 P2P KV 传输不经过 standalone Store，故
Master 的 Put/Get=0 不能单独判定 P/D 失败。

## Mooncake Store 验证流程

本 overlay 使用 `MultiConnector`：`MooncakeConnector` 负责 P/D 直连，
`MooncakeStoreConnector` 负责共享 KV Store。Prefill 必须启用
`--enable-prefix-caching`，否则不会生成可写入 Store 的 KV block。当前配置
使用 TCP、standalone Store 和 bucket 后端 SSD offload：Master/Client 均开启
offload，Client 的本地目录为 `/mnt/mooncake-offload`（Pod 内
`/data/mooncake-offload`），两节点各限制为 20 GiB。当前两端 DRAM 段
各 5 GiB；`offload_on_evict=false`，Master eviction high watermark 为 0.95。
不向 vLLM worker 下发 `root_fs_dir/cluster_id`；该旧式共享目录路径曾导致
TP8 worker 并发重建时出现 `free(): invalid pointer`，并非 standalone Client
的 SSD offload 所必需。

SSD offload、Store Get 和重启恢复是三个独立验收项。当前 Master 镜像内
Mooncake 为 0.3.13。本次开启 snapshot/restore 的对照测试中，Master
报告恢复成功，但恢复后的 `master_key_count=0`，一个 Client 持续报告
`Failed to remount segments: INVALID_PARAMS`。因此当前 overlay 关闭
Master snapshot/restore；**不能用于证明 Master 重启后的 KV 恢复**。
重启 Store 后也应重启两端 vLLM，单凭旧 Pod Ready 不能证明 Store 连接仍可用。

当前 Client 设置 `MOONCAKE_OFFLOAD_BUCKET_KEYS_LIMIT=8`。Mooncake 0.3.13
的 bucket 后端会暂存未凑满的 key；默认 500 key/256 MiB 阈值下，小规模
功能请求虽完成 Put，但可能始终没有生成 SSD 文件，不能据此断定 offload
故障。降低 key 阈值后，独立 Mooncake SDK 测试已验证 Put 后出现 `.bucket`
和 `.meta` 文件、Master 磁盘分配字节增加；清除测试 key 的内存副本后仍可
从磁盘读回相同数据，`file_cache_hit_nums_` 随之增加。此结果**不代替**
vLLM 路径的端到端验证。

1. 检查控制面和客户端注册：

   ```bash
   kubectl -n mooncake get pods -o wide
   kubectl -n mooncake logs deploy/mooncake-master-store --tail=100 \\
     | rg 'Clients:|service_ready|error|segment'
   ```

   Master 应为 `service_ready=true`，并且 Clients 数量为 2。

2. 检查 Store 初始化日志：

   ```bash
   kubectl -n llm-d-mt logs <prefill-or-decode-pod> -c modelserver \\
     | rg 'standalone-store|Registered KV caches|Mooncake KV-load'
   ```

   应看到 `global_segment_size=0`、`Registering KV_Caches` 和
   `Started ... Mooncake KV-load receive thread(s)`。

3. 请求前后采集 Master 指标：

   ```bash
   MASTER=$(kubectl -n mooncake get pod -l \\
     app.kubernetes.io/component=master-store -o jsonpath='{.items[0].metadata.name}')
   kubectl -n mooncake exec "$MASTER" -- \\
     sh -c 'curl -fsS http://127.0.0.1:9003/metrics' | \\
     rg 'master_(allocated_bytes|allocated_file_size_bytes|total_file_capacity_bytes|key_count|batch_put_end_items_total|put_start_requests_total|put_end_requests_total)|total_get_nums_|valid_get_nums_'
   ```

   Store 写入时要求 `master_batch_put_end_items_total` 正向增加，并结合
   vLLM `save_put` keys/bytes 与失败 key。`master_allocated_bytes` 只证明
   分配，未完成的 PutStart 也会增加它；`put_start_requests_total` 和
   `put_end_requests_total` 在当前批量写入路径中均可能为 0。
   真正 Store 读取时
   `total_get_nums_` 与 `valid_get_nums_` 应同步增加。

   SSD 验收还需在异步 offload 完成后看到
   `master_allocated_file_size_bytes > 0`，并核对 Client 挂载目录实际增加
   文件。`master_total_file_capacity_bytes > 0` 只表示 SSD 段已注册，
   不能证明已写盘。重启 Decode 后的 `load_get` 也可能来自 DRAM 副本，
   单独不能证明 SSD 读路径。

4. 检查 vLLM Store 指标：

   ```bash
   kubectl -n llm-d-mt exec <decode-pod> -c modelserver -- \\
     sh -c 'curl -fsS http://127.0.0.1:8200/metrics' | \\
     rg 'vllm:mooncake_store_operation_(total|bytes_total|failed_keys_total)'
   ```

   Prefill 应看到 `operation="save_put"` 的 keys/bytes 增量，Decode 的
   Store 读取应看到 `operation="load_get"` 的 keys/bytes 增量；两端对应的
   `failed_keys_total` 必须保持为 0。只看 `lookup_exists` 不能证明数据已读取。

5. 使用超过一个 KV block 的 prompt 经 EPP 请求，观察 P/D 直连成功传输和
   Store Put。具体写入发生在 Prefill 还是 Decode 需结合各自的 `save_put`
   日志/指标判断。相同请求再次经过 EPP 可能命中 Decode 的本地缓存或
   再次走直连，**不能单凭两次 HTTP 200 判定 Store Get**。记录请求内容，
   重启 Decode 以清空本地 KV 后，将同一请求直接发到 Decode 的 8200 端口，
   观察 `load_get`、`valid_get_nums_` 和失败 key。直连 Decode 是 Store
   读路径测试，不是 P/D 直连测试。`external_kv_transfer` 只能证明
   `MooncakeConnector` 的 P2P 传输，不能替代 Store Put/Get 指标。

   以下命令在部署完成后执行；两次 `port-forward` 分别在独立终端保持运行。
   先记录 Master 与两端 vLLM 指标基线，再执行请求，按前后差值验收：

   ```bash
   python3 -c 'import json; p="Mooncake Store cross node functional validation "*100; print(json.dumps({"model":"DeepSeek-V4-Flash","messages":[{"role":"user","content":p}],"max_tokens":16,"temperature":0}))' \
     > /tmp/llm-d-mt-store-request.json
   kubectl -n llm-d-mt port-forward svc/pd-disaggregation-epp 18080:80
   # 在另一终端：
   curl -sS --max-time 300 -H 'Content-Type: application/json' \
     --data-binary @/tmp/llm-d-mt-store-request.json \
     http://127.0.0.1:18080/v1/chat/completions
   ```

   确认 Prefill `save_put` 大于 0、两端 P2P 无失败传输后，再重启 Decode
   清空其本地 KV。检查新 Pod Ready，直连 Decode 发送**同一个 JSON 文件**：

   ```bash
   kubectl -n llm-d-mt rollout restart \
     deploy/pd-disaggregation-mthreads-deepseek-v4-decode
   kubectl -n llm-d-mt rollout status \
     deploy/pd-disaggregation-mthreads-deepseek-v4-decode --timeout=30m
   kubectl -n llm-d-mt port-forward \
     deploy/pd-disaggregation-mthreads-deepseek-v4-decode 18200:8200
   # 在另一终端：
   curl -sS --max-time 300 -H 'Content-Type: application/json' \
     --data-binary @/tmp/llm-d-mt-store-request.json \
     http://127.0.0.1:18200/v1/chat/completions
   ```

   `load_get` 的 keys/bytes、Master 的 `valid_get_nums_` 必须增加，
   `failed_keys_total{operation="load_get"}` 应为 0。若前一次请求没有
   `save_put`，先排查 prefix caching、请求 token 数与 KV block 大小，
   不应把后一请求的 HTTP 200 视作 Store 验收通过。

## 自动化手动验证脚本

仓库提供了带步骤目的和指标输出的验证脚本：

```bash
# 默认：状态、EPP/P2P 请求、Store Put 和 SSD 写盘；不重启 Pod
scripts/verify_mthreads_1p1d_mooncake_store.sh

# 完整功能验证：额外重启 Decode，并直连验证 Store Get
scripts/verify_mthreads_1p1d_mooncake_store.sh --restart-decode
```

脚本会自动管理本地 port-forward，并在退出时停止它们。默认模式不会
扩缩容、重启或删除 Kubernetes 资源。`--restart-decode` 会实际滚动重启
Decode，须确认 36.18 租约持续有效后再运行。SSD 验收以本次请求前后的
Master 磁盘字节增量为准；历史数据或单独的 SDK 测试不算本次通过。
`--restart-decode` 会重启 Decode，应只在允许中断当前 Decode 请求时使用。

## 2026-10-16 SSD 复测记录

- eager offload：Master `enable_offload=1`，两个 Client `enable_offload=1`，
  两端各注册 20 GiB 磁盘段。4284-token 请求经 EPP 返回 HTTP 200，Decode
  `save_put=703103616` 字节、失败 key 为 0，Master 批量 PutEnd 有 194
  条、DRAM 分配 342718848 字节；等待 300 秒后
  `master_allocated_file_size_bytes=0`，Client 目录无新增数据。
- snapshot/restore 对照：Master 0.3.13 报告成功恢复快照，但恢复后的
  `master_key_count=0`，一个 Client 持续报告
  `Failed to remount segments: INVALID_PARAMS`，磁盘容量指标一度为负。
  关闭 snapshot/restore 并重建 Master/Client 后指标恢复。Store 重建后
  旧 vLLM Pod 虽 Ready，新请求仅出现 PutStart 而无 PutEnd；重启 P/D
  才能重新建立有效连接。
- eviction-triggered offload 对照：临时将 Client DRAM 段调为各 1 GiB，
  Master high watermark 调为 0.20，启用 `offload_on_evict`。7084-token
  请求经 EPP 返回 HTTP 200，Master 出现 `[EVICT-TRIGGER]` 和
  `48 objects deferred for disk offload`，批量 PutEnd 最终只有 120 条；
  等待 180 秒后 `master_allocated_file_size_bytes=0`。测试后已撤销
  低水位/小 DRAM 参数，未保留这个部分写入状态。
- 恢复验证：回到每节点 5 GiB DRAM 段、high watermark 0.95，保持
  SSD offload 启用、snapshot/restore 关闭；重建 Store 和 P/D 后，
  Master/Client、Prefill、Decode、EPP 均 Ready，短请求经 EPP 返回
  HTTP 200。该短请求不构成 Store Put 或 SSD 验收证据。

后续定位到 bucket 后端默认要凑满 500 key 或 256 MiB 才生成文件；此前的
342 MiB 数据分散到两台 Client，单台未达到触发条件。把每个 bucket 的 key
阈值设为 8 后，独立 Mooncake SDK 写入 32 个 1 MiB key，24 个 key
获得磁盘副本，`master_allocated_file_size_bytes` 增至 25165824，
两个 Client 目录出现 `.bucket` 和 `.meta` 文件。另一组测试清除某个 key
的内存副本后，Master 仅返回磁盘副本，读回 1 MiB 内容一致，
`file_cache_hit_nums_` 从 0 增至 2。独立 SSD 写入、读取因此通过。

尚未通过的项目：新阈值下 vLLM 长前缀的 Store Put/SSD 写盘/Decode
Store Get 端到端验证，及 Store 重启后的 KV 恢复。滚动更新 Client 后
Prefill worker 曾退出并重启；重新加载期间，36.18 的 GPU 租约在已成功
续租的情况下从 broker 消失。为避免无租约占卡，已停止 watcher 并删除
双机模型及 Mooncake 资源。**目前双机服务未运行，不能宣称稳定。**
恢复测试须先重新取得 36.18 的有效租约，并确认续租/回收策略；每次
Client 或 Master 滚动更新后，协调重启两端 vLLM 以重建 Store 连接。

36.18 被占用期间，可使用
[`../single-node-1p1d-tp4-ssd`](../single-node-1p1d-tp4-ssd/README.md)
在专属 36.10 上进行 Qwen3-32B TP4+TP4 的 Store/SSD 功能验证。
2026-10-19 的单机结果包括 6k-token Store Put/SSD 写入、受控 Decode
重启后的 Store Get，以及独立 SDK 的磁盘-only 读回和 Store 重启恢复；
进一步通过填充 Store、重启 Decode 后重放固定长前缀，观察到 Master
`file_cache_hit_nums_` 从 2 增至 17，证明单机 vLLM 路径发生 SSD 读取。
这些结果不代表双机 DeepSeek-V4 路径通过。

### Earlier DRAM/P2P check

此前验证记录：overlay 渲染和 server dry-run 通过；Master/Client 启动并注册，
两端出现 Store 初始化日志；两次请求返回 HTTP 200，但请求 prompt 只有 133 tokens，
小于当前 256-token KV block，因此 Master 的 Put/Get 仍为 0；Decode 的
`external_kv_transfer` 从 0 增至 266，说明本轮请求走的是直连 P/D 路径，
不能据此判定 Store 失效。下一轮必须使用超过 256 tokens 的相同 prefix，才能观察
Store Put/Get。随后租约 watcher 因租约过期删除了 `mooncake`
namespace，重启时出现 `Initialize MooncakeDistributedStore failed` 和
`Failed to create client after 20 retries`；该次属于部署生命周期/租约问题，不能
作为 Store 数据路径失败结论。

## Validation status (2026-10-12)

- `worker36010` Prefill TP=8 为 `1/1 Ready`，`worker36018` Decode TP=8 为
  `2/2 Ready`，P/D EPP 为 `2/2 Ready`，两端本轮重启次数为 0；Mooncake Master
  和两个 Client 均为 Ready。
- 两端日志显示 `The Mooncake Transfer Engine is using tcp as its protocol`。
  仅指定 `mooncake_protocol=tcp` 时仍曾出现跨节点
  `MusaTransport: cudaIpcOpenMemHandle failed: invalid argument` 和 Decode
  `Mooncake transfer engine returned -1`；加入 `MC_FORCE_TCP=1` 后，三次请求
  均未复现该错误。
- 经 `pd-disaggregation-epp` Service 的短请求返回 HTTP 200、16 个生成 token，
  耗时 2.69 秒；1291-token prompt 连续两次请求都返回 HTTP 200、32 个生成 token，
  耗时 13.23 秒和 7.14 秒。Prefill 日志显示请求源为 Decode Pod IP，Decode
  日志显示请求源为 EPP Pod IP，两端分别记录了三次 200 响应。这验证了本轮
  TCP P/D 请求路径和实际生成，不代表 RDMA 已验证。
- 之前的 Decode `max-num-batched-tokens=8192` + 禁用 chunked prefill 因小于
  `max-model-len=131072` 启动失败；将 batch 提到 131072 又在 KV profiling
  阶段 OOM。当前启用 chunked prefill、batch=8192、显存利用率=0.80，已通过
  启动和上述请求。
- DeepSeek 冷启动的 TileLang 编译/图预热超过 Deployment 默认 600 秒进度期限，
  当前 `progressDeadlineSeconds=1800`。启动期间以 Pod readiness 和日志判断，
  不要仅依据旧的 `ProgressDeadlineExceeded` condition。
- 本轮未做高并发、故障恢复或 RDMA/RoCE 性能测试。

### Prior checks

- 两台节点上的模型目录已确认存在；
- 两台节点都能访问新模型目录，`config.json` 声明 `model_type=deepseek_v4` 和
  `DeepseekV4ForCausalLM`；
- `post2-20261001` 镜像此前在 36.10 的 Kubernetes containerd 中导入，并在该节点
  完成单节点 TP=8 启动和 HTTP 推理冒烟；本次已在 36.18 启动 Decode；
- Mooncake Master/Client 使用同一 MThreads vLLM 镜像，该镜像已确认包含
  `mooncake_master` 和 `mooncake_client`；
- 本轮参数依据
  [MThreads vLLM-MUSA DeepSeek-V4 Flash 0731 cookbook](https://github.com/MooreThreads/vllm-musa/blob/v0.28.0-dev/docs/cookbook/deepseek/deepseek-v4-flash-731.md)，
  增加 `--kv-cache-dtype=fp8`、`--attention-backend=FLASHMLA`、DSpark 4-token
  speculation、`VLLM_PLUGINS=musa,musa_custom_ops` 和
  `--hf-overrides={"expert_dtype":"fp8"}`；后者使模型使用 FP8 routed experts
  和 DEEPGEMM FP8 MoE backend，绕过此前的 MXFP4 backend 报错；
- Prefill Pod 在 `worker36010` 上为 `1/1 Running`，vLLM 日志出现
  `Starting vLLM server` 和 `Application startup complete`；`/health` 返回 `200`，
  `/v1/models` 返回 served model `DeepSeek-V4-Flash`，一条
  `/v1/chat/completions` 请求返回 `200`；
- Mooncake Master/Client 的 TCP 进程可以启动并注册客户端，Prefill 也完成了
  Mooncake Transfer Engine Scheduler 初始化；Master 指标显示 `Clients: 2`，但
  `Keys: 0` 且 Put/Get 均为 0。此前单节点检查中 Decode 被临时缩容为 0，未产生 P/D 请求，
  因此没有真实 KV transfer 证据；
- 上述仅是此前单机检查结果；双机 TCP 结果见本节开头，仍不能宣称已验证 RDMA/RoCE。

此前在 worker36010 以 Decode=0 的方式验证过 Prefill；本次已进一步完成双机
TCP P/D 实际请求验证。

本次使用 `post2-20261001` 镜像在 `worker36010` 做了单节点 TP=8 启动验证（Decode
临时缩容为 0）：

- `deepseek_v4` 架构已被 vLLM 识别，并进入 `vllm.models.deepseek_v4` 模型构造；
- DeepSeek-V4 FP8 MLA 需要显式设置 `--kv-cache-dtype=fp8`，已加入 Prefill/Decode
  配置；
- 根据 MUSA cookbook 增加 `--hf-overrides={"expert_dtype":"fp8"}`，选择该 checkpoint
  的 FP8 routed-expert 权重；
- 同步增加 `FLASHMLA`、DSpark-4 和 MUSA 多进程环境变量；
- Prefill/Decode 均挂载 `/mnt/mooncake-offload` 到 `/data/mooncake-offload`，供
  `MooncakeStoreConnector` 使用本地 offload 存储；
- 当时只验证了模型权重加载、vLLM HTTP 服务和单请求推理；P/D KV transfer
  尚未验证。双机 TCP 结果见本节开头。

## Previous model test (2026-10-09)

曾以 `/ipfs/models/DeepSeek-V4.1-Flash-FP8/` 在 `worker36010` 和 `worker36018`
实际创建并启动过本 overlay，随后因模型端
启动失败清理了测试资源：

- Mooncake Master 为 `Serving`，两个 Client 均为 `Running`；Master 日志显示已注册
  2 个 Client。Client 日志显示 TCP-only 模式、5 GiB segment 挂载和服务端口启动。
- Prefill/Decode Pod 均按节点调度，MUSA plugin 初始化、TP=8 参数解析和部分 MUSA
  JIT 编译均完成。
- vLLM 在加载模型配置时失败：当前镜像（包括本地检查过的
  `post2-20261001` 候选镜像）中的 Transformers 不识别 `model_type=deepseek_v41`，
  因而不能构造 `DeepseekV41ForCausalLM`。
- 本轮没有进入 vLLM HTTP 服务、Router/EPP 或真实 KV transfer 阶段；不能将本轮
  结果称为端到端推理成功。

该结论仅适用于旧 V4.1 模型。新 V4 模型已在修正 FP8 expert 配置后通过单节点模型
加载和 HTTP 冒烟，但不等同于双机 1P1D 端到端成功。

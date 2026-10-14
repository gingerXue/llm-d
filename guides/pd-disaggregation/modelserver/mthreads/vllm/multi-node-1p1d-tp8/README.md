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

执行前必须确认两台节点都已经导入 vLLM 和 routing-sidecar 镜像，MThreads
container runtime 正常，模型目录存在，并且 Docker 工作负载已释放或已协调 GPU
资源。当前 overlay 不会自动导入镜像，也不会处理 GPU 资源冲突。

~~~bash
kubectl apply -k "${STORE_OVERLAY}"
kubectl apply -k "${CLIENT_OVERLAY}"
kubectl apply -n "${NAMESPACE}" -k "${OVERLAY}"
~~~

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
`--enable-prefix-caching`，否则不会生成可写入 Store 的 KV block。当前第一轮
使用 TCP 和 standalone DRAM Store，Master、Client、vLLM 配置均关闭 SSD offload；
SSD offload 需要单独做 A/B 测试。

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
     rg 'master_(allocated_bytes|put_start_requests_total|put_end_requests_total)|total_get_nums_|valid_get_nums_'
   ```

   真正使用 Store 时，`master_allocated_bytes`、PutStart/PutEnd、
   `total_get_nums_` 和 `valid_get_nums_` 应出现正向增量。

4. 检查 vLLM Store 指标：

   ```bash
   kubectl -n llm-d-mt exec <decode-pod> -c modelserver -- \\
     sh -c 'curl -fsS http://127.0.0.1:8200/metrics' | \\
     rg 'vllm:mooncake_store_operation_(total|bytes_total|failed_keys_total)'
   ```

   `operation_total` 和 `bytes_total` 必须大于 0，
   `failed_keys_total` 必须保持为 0。

5. 使用相同且超过一个 KV block 的 prompt 连续请求两次；第一次观察 Put，
   第二次观察 Get。再将请求发到另一个 vLLM 实例或重启实例，验证跨实例复用。
   `external_kv_transfer` 只能证明直连 `MooncakeConnector`，不能替代上述
   Store Put/Get 指标。

本轮验证记录：overlay 渲染和 server dry-run 通过；Master/Client 启动并注册，
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

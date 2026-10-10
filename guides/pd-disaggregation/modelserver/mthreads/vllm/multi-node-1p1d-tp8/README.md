# MThreads vLLM DeepSeek-V4 双机 1P1D TP=8

该 overlay 以现有 MThreads vLLM 单机 1P1D 配置为基础，生成：

- Prefill：`worker36010`，TP=8，申请 8 个 `mthreads.com/gpu`；
- Decode：`worker36018`，TP=8，申请 8 个 `mthreads.com/gpu`；
- 1P1D 资源参数按 cookbook 对齐：Prefill 131072/16/0.80，Decode
  131072/64/0.95；Prefill 开启 chunked prefill，Decode 使用 FULL_DECODE_ONLY
  capture sizes；
- 模型：`/ipfs/test/models/DeepSeek-V4-Flash-0731-FP8-mt/`；
- served model name：`DeepSeek-V4-Flash`；
- 模型服务镜像：`registry.mthreads.com/mcconline/inference/vllm:v0.28.0-ph1-5.2.0-torch2.11.0.post2-20261001`；
- P/D KV：`MooncakeConnector`，TCP；
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

由于当前集群尚未创建 `mooncake` namespace，直接对包含 Namespace 的完整 Master
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

随后再部署 llm-d Router/EPP 和 InferencePool，最后通过 Router 的 OpenAI
兼容端点发送一条请求。仅 Pod `Running` 或 HTTP 200 不能证明 KV Store/P&D
链路成功，还要检查 Prefill、Decode 和 Mooncake 日志中的 connector 初始化及
实际 KV transfer。

## Validation status

- 两台节点上的模型目录已确认存在；
- 两台节点都能访问新模型目录，`config.json` 声明 `model_type=deepseek_v4` 和
  `DeepseekV4ForCausalLM`；
- `post2-20261001` 镜像已在 36.10 的 Kubernetes containerd 中导入，并在该节点
  完成单节点 TP=8 启动和 HTTP 推理冒烟；36.18 仍需在租约可用后导入其 Kubernetes
  containerd；
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
  `Keys: 0` 且 Put/Get 均为 0。本轮 Decode 被临时缩容为 0，未产生 P/D 请求，
  因此没有真实 KV transfer 证据；
- 当前 overlay 仍是 TCP 配置，不能据此宣称已验证 RDMA、RoCE 或完整双机 1P1D。
  36.18 本轮只有 7 张 broker 可分配卡，无法安全启动 TP8 Decode；双机验证需要
  在资源可用后重新导入镜像并按 cookbook 的 RDMA/HCA 配置运行。

配置已与 cookbook 的 1P1D 参数对齐，并在 worker36010 以 Decode=0 的方式实际启动
了 Prefill；本次 128K/graph profile 的 `/health`、`/v1/models` 和单请求推理均通过。
这仍不是双机 1P1D 端到端验证。

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
- 模型权重加载、vLLM HTTP 服务和单请求推理均已验证；P/D KV transfer 仍待双机
  Decode 实例和真实请求验证。

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

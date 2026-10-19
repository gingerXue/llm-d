# MThreads 单机 1P1D TP4 SSD Store 功能验证

此 overlay 在专属 `worker36010` 上运行 Qwen3-32B Prefill TP4 和 Decode TP4，
沿用双机方案的 Mooncake Master、TCP Client 和 SSD bucket 配置。它用于验证
vLLM Store Put/Get 与 SSD 写盘，不验证跨节点 TCP/RDMA 或 DeepSeek-V4。

部署前确认 36.10 八卡空闲，并暂停双机 lease watcher；两个方案共用
`mooncake` namespace，不可同时重建 Store。按以下顺序部署：

```bash
kubectl apply -k guides/pd-disaggregation/modelserver/mthreads/vllm/multi-node-1p1d-tp8/mooncake-master-store
kubectl -n mooncake rollout status deploy/mooncake-master-store --timeout=5m
kubectl apply -k guides/pd-disaggregation/modelserver/mthreads/vllm/single-node-1p1d-tp4-ssd/mooncake-client
kubectl -n mooncake rollout status ds/mooncake-client --timeout=5m
kubectl apply -n llm-d-mt -k guides/pd-disaggregation/modelserver/mthreads/vllm/single-node-1p1d-tp4-ssd
kubectl -n llm-d-mt rollout status deploy/pd-disaggregation-mthreads-vllm-prefill --timeout=25m
kubectl -n llm-d-mt rollout status deploy/pd-disaggregation-mthreads-vllm-decode --timeout=25m
```

功能测试使用唯一 prompt tag，仅比较本轮指标增量：

```bash
MODEL=Qwen3-32B EXPECTED_CLIENTS=1 \
  DECODE_DEPLOYMENT=pd-disaggregation-mthreads-vllm-decode \
  PROMPT_REPEAT=40 SSD_WAIT_SECONDS=120 \
  scripts/verify_mthreads_1p1d_mooncake_store.sh
```

加 `--restart-decode` 会滚动重启 Decode，再用同一请求直连 Decode 验证
Store Get；这会中断现有请求。`--disable-log-stats` 是当前 vLLM 镜像的
临时规避：`MultiConnector` 的 Prometheus 指标注册缺少
`MooncakeConnector`，默认统计路径会在请求后触发断言。此参数使 vLLM
Store 指标不可用，因此以 Master `batch_put_end_items_total`、
`master_allocated_file_size_bytes` 和 `valid_get_nums_` 的增量验收。
其中 SSD 写盘和 Store Get 是两个独立结论；Store Get 不等于 SSD 命中。

Mooncake 0.3.13 的 TCP lane 在约 1.6k-token 的单请求上曾报
`queue-full rejection`：HTTP 200 但 Master 只有 PutStart、没有 PutEnd。
镜像的传输引擎识别 `MC_TCP_MAX_QUEUED_TRANSFERS_PER_PEER` 和
`MC_TCP_MAX_PENDING_ADMISSIONS_PER_PEER`；本 overlay 暂设为 65535，
双机 TCP overlay 同步设置。它是功能性缓解，不能替代修复传输引擎的
队列生命周期问题，也不能据此推断高并发性能。

2026-10-19 的功能复测结果：初始 809-token 请求完成 48 个 PutEnd，SSD
分配增加约 192 MiB；三轮约 400-token 请求均完成 24 个 PutEnd；原本
queue-full 的约 1.6k-token 请求在设置队列参数后完成 100 个 PutEnd，
约 3k-token 请求完成 188 个，约 6k-token 请求完成 372 个，均出现
本轮 SSD 字节增量。期间 Prefill/Decode 保持 Ready、0 重启。Decode
受控重启后，同一 809-token 请求直连新 Decode 返回 200，Master
`valid_get_nums_` 从 96 增至 144。以上是功能烟测，不是长时间运行、
高并发或性能基线。

进一步的 vLLM SSD 读取验证保留一个固定 tag 的长前缀请求，再写入多个
不同长前缀使 Master `master_evicted_key_count` 增至 1832，并受控重启
Decode 清空 GPU KV。直连新 Decode 重放保留请求（7209 prompt token）
返回 200；Master `valid_get_nums_` 从 3085 增至 3289，
`file_cache_hit_nums_` 从 2 增至 17。这一组增量证明本轮 vLLM 请求
确实从 SSD 读取了被驱逐的 KV，而不只是 Store DRAM 命中。

复现时需保留首次请求的 `REQUEST_FILE`，用不同 `PROMPT_TAG` 填充
Store 至发生内存驱逐，记录 `file_cache_hit_nums_` 基线，重启 Decode，
然后使用 `kubectl exec -i` 把原请求直接发送到 Decode 的 8200 端口；
通过 EPP 重放可能触发新的 Prefill，不能隔离 Store 读取路径。磁盘文件
需保持在 20 GiB 限额内，测试结束不要直接删除宿主机历史数据。

独立 SDK 验证在同一 Client 写入测试 key，等 SSD 副本出现及 5 秒租约
到期，再调用 `batch_replica_clear` 仅清除该 key 的内存副本；此时 Master
只报告磁盘副本，读回 1 MiB 内容一致，`file_cache_hit_nums_` 增加。随后
重启 Master/Client，原磁盘-only key 仍可读回。这验证的是 Store 层的
SSD 读与重启恢复，不等于 vLLM 前缀恢复。

单机测试结束后，将两端 Deployment 缩至 0；删除本 overlay 的 Client
DaemonSet 前先确认没有别的服务依赖它。不要删除宿主机
`/data/mooncake-offload` 的历史文件。

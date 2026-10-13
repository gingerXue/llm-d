# MThreads 1P1D 租约监控服务

`watch_mthreads_1p1d_lease.py` 通过 GPU broker 的 MCP HTTP 接口持续检查
`10.20.36.18` 是否有 8 张空闲 GPU。获得租约后按以下顺序应用资源：

1. Mooncake Master；
2. Mooncake Client；
3. DeepSeek-V4 Prefill/Decode 双机 overlay。

服务进程持续运行并周期性续租。停止服务时默认按逆序删除本服务的 Kubernetes 资源，
然后释放租约。服务不会自动杀 Docker 进程；节点上的 GPU 清理必须单独核对进程和租约归属。

## 安装

```bash
cd /home/xuejingzhi/documents/repo/llm-d
sudo install -D -m 0755 scripts/watch_mthreads_1p1d_lease.py \
  /usr/local/libexec/llm-d/watch_mthreads_1p1d_lease.py
sudo install -D -m 0644 deploy/mthreads-1p1d-lease-watch.service \
  /etc/systemd/system/mthreads-1p1d-lease-watch.service
```

unit 默认以 `xuejingzhi` 用户运行，并使用该用户的 kubeconfig。部署到其他机器或用户时，
应修改 unit 中的 `User`/`Group`，并在环境文件中设置 `KUBECONFIG`。

```bash
sudo install -d -m 0755 /etc/llm-d
sudo tee /etc/llm-d/mthreads-1p1d-lease-watch.env >/dev/null <<'EOF'
GPU_BROKER_POOL=开发资源池
GPU_BROKER_OWNER=llm-d-mt-watch
GPU_BROKER_TASK=DeepSeek-V4 1P1D TP8 validation
MTHREADS_DECODE_NODE=10.20.36.18
MTHREADS_DECODE_GPUS=8
GPU_BROKER_POLL_SECONDS=30
GPU_BROKER_TTL_SECONDS=7200
GPU_BROKER_EXPECTED_MINUTES=120
LLM_D_NAMESPACE=llm-d-mt
LLM_D_CLEANUP_ON_STOP=true
KUBECONFIG=/home/xuejingzhi/.kube/config
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now mthreads-1p1d-lease-watch.service
```

查看状态和日志：

```bash
systemctl status mthreads-1p1d-lease-watch.service
journalctl -u mthreads-1p1d-lease-watch.service -f
```

## 手工验证

不启动服务也可以先渲染 YAML：

```bash
kubectl kustomize guides/pd-disaggregation/modelserver/mthreads/vllm/multi-node-1p1d-tp8
kubectl apply --dry-run=client -n llm-d-mt \
  -k guides/pd-disaggregation/modelserver/mthreads/vllm/multi-node-1p1d-tp8
```

服务只以 broker 的 `gpu_status` 结果作为预检查，最终以 `gpu_acquire` 的原子结果为准；
因此多个 watcher 同时运行时不会根据静态空闲数重复占用 GPU。

只检查资源、不申请租约或创建 Pod：

```bash
LLM_D_CHECK_ONLY=true python3 scripts/watch_mthreads_1p1d_lease.py
```

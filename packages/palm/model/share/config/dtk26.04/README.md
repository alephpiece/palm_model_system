# DTK 26.04 配置

## 双卡四进程启动

此配置已在单节点、两张 BW100、四个 Open MPI rank、`npex=npey=2` 的
非嵌套 PALM `test` 和多层 MG 算例验证。它只改变各 rank 的运行环境，不改变 PALM 的计算源码。

启动 `palmrun` 前，将两张待用卡的容器内 HIP 编号按顺序设为
`HIP_VISIBLE_DEVICES=0,1`。`rank-gpu.sh` 按本地 rank 轮转分配 GPU，并采用单卡可见策略：
在 MPI 初始化前使每个进程只看见目标 GPU。两卡时 rank 0/2 使用第一张卡，rank 1/3 使用第二张卡。主运行命令给 MPI rank 传递 `OMP_NUM_THREADS=8`。
脚本检查单节点四 rank；输入中的 2×2 分解仍须由 `npex`、`npey` 指定。

在当前容器的 `.palm.config.dcu` 中，将运行命令设为：

```text
%execute_command env OMP_NUM_THREADS=8 /opt/mpi-flang/bin/mpirun --allow-run-as-root --mca coll ^hcoll -n {{mpi_tasks}} /workspace/sources/palm_model_system/packages/palm/model/share/config/dtk26.04/rank-gpu.sh ./palm
%execute_command_for_combine /opt/mpi-flang/bin/mpirun --allow-run-as-root --mca coll ^hcoll -n 1 ./combine_plot_fields.x
```

`palmrun` 在不使用 `-O` 时会设置 `OMP_NUM_THREADS=1`。示例在 `mpirun` 前用
`env OMP_NUM_THREADS=8` 覆盖此值，再由 MPI 传给各 rank。还需单独指定输出合并命令：
`palmrun` 默认会对整个主运行命令做字符串替换，
脚本路径中的 `palm_model_system` 也会被误改。输出合并只用一个进程，
不经过四 rank 的包装脚本。

## WS 标量统计归约

`platform/dtk26.04` 已采用 pt/q 统计分片实现。
Workspace 的 `tools/palm/build.py` 默认在 DTK OpenACC 构建中启用。
使用其它构建入口时，在 BW100 OpenACC 构建的 `%cpp_options` 中增加 `-D__palm_ws_sharded_stats`，
重新编译 `advec_ws.f90` 并链接程序即可启用。其它源码不使用此宏。
H100 构建不启用，未使用 OpenACC 的构建也保持原实现。

该实现将原先对每个高度的原子累加分散到 32 个槽，再按高度归并到原统计数组，
保留 RK 子步累积。工作区为调用局部自动数组，以结构化 DATA 区管理设备映射，
占用 `(nzt-nzb) × 32 × sizeof(wp)` 字节，不跨调用缓存。

## WS 动量统计归约

`platform/dtk26.04` 已采用 u/v/w 统计分片及 w 下部统计的 atomic 修复。
Workspace 的 `tools/palm/build.py` 默认在 DTK OpenACC 构建中启用分片。
其它构建入口需在 BW100 OpenACC 的 `%cpp_options` 中加入 `-DPALM_WS_MOMENTUM_SHARDS`，
重新编译并链接程序。H100 和纯 CPU 构建不启用此宏，宏关闭时保留 atomic 修复。

每次调用向 32 个槽累加后归并到已有统计，保留 RK 累积。
u/v 工作区各为 `(nzt-nzb) × 32 × 2 × sizeof(wp)` 字节，w 为其一半，不跨调用缓存。
槽编号在统计更新前计算，保留 DTK 26.04 四 rank 故障的已验证绕过组织。
采用验证覆盖 BW100 GPU 的完整 test、干燥短程和双卡四 rank 短程。
OpenACC 构建运行时关闭加速的 CPU 回退尚未通过验收，不能视为已验证的纯 CPU 构建路径。

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

## 流场统计表面归约

`platform/dtk26.04` 已采用LSM表面统计归约，研究分支 `research/flow-surface-statistics` 保留。
Workspace 的 `tools/palm/build.py` 默认在DTK OpenACC构建中启用。其它构建入口
在BW100 OpenACC构建的 `%cpp_options` 加入 `-DPALM_SURFACE_STATS_REDUCTION` 后重新编译并链接，
六项表面标量与逐土层温湿度采用显式归约，在原有主机交接处并入统计数组。
宏关闭时保持原路径，H100与纯CPU构建不启用此宏。

研究完成BW100 / DTK26.04与H100 / NVHPC25.3单卡单进程test对照。
采用准备另通过BW100双卡四rank、2×2分解的72模拟秒短程验证，
并核对各rank贡献、MPI全局和及归一化统计。H100继续采用宏关闭的原实现。
BW100的土层循环显式 `COPYIN(k)`，避免该组织中FIRSTPRIVATE复用首层的已观察行为。
实现不缓存跨调用数据，不改变USM追加、MPI或归一化顺序。
验证结果及后续采用范围由workspace的流场统计表面归约专题维护。

## 六方程局部启动配置

六方程更新的三个开关只改变 OpenACC 指令，不改变公式、循环边界或数据列表。
使用其它构建入口时，在 `%cpp_options` 中加入相应的 `-D` 选项，并重新编译、链接。

| 开关 | 作用 | BW100 / DTK 26.04 | H100 / NVHPC 25.3 |
| --- | --- | --- | --- |
| `PALM_EQUATION_VECTOR64` | 在状态与历史更新、清零、部分物理项及 TKE 主扩散等 29 个选定区域指定 VL64 | 开 | 关 |
| `PALM_TKE_SHEAR_VECTOR64` | TKE 剪切生产指定 VL64 | 开 | 开 |
| `PALM_Q_UPDATE_COLLAPSE3` | 水汽状态更新采用三维展开 | 开 | 开 |

未定义时保留各区域的原指令；纯 CPU 构建不需要这些宏。
`PALM_EQUATION_VECTOR64` 不代表整个方程模块统一使用该宽度，
也不应直接推广到默认启动与编译资源行为已变化的 DTK 26.10。
验证覆盖两平台单卡 360 模拟秒，以及 BW100 双卡四进程 1800 模拟秒的 `test` 算例。

## GPU FFT 压力路径

DTK 构建可用 `-D__hip_fft` 接入 AMD hipFFT，沿用已有 `poisfft` 的水平有限差分 FFT、
转置和竖直三对角求解。源码的默认压力求解器为 `poisfft`；workspace 的常用性能测试也显式
选择 `psolver = 'poisfft'` 和 `fft_method = 'system-specific'`。
`tools/palm/build.py` 默认为 DTK／NVHPC GPU 构建启用 hipFFT／cuFFT；
`--no-gpu-fft` 可关闭库接入，纯 CPU 构建不启用。MG 仍可通过输入选择。
设备 FFT 要求 OpenACC，初始化会选择 `system-specific` 方法。

在 `%cpp_options` 中加入 `-D__hip_fft`，并在 `%linker_options` 中加入 hipFFT 的库目录、
`-lhipfft -lamdhip64` 及对应运行时搜索路径。例如 DTK 安装于 `/opt/dtk` 时可使用
`-L/opt/dtk/hipfft/lib -Wl,-rpath,/opt/dtk/hipfft/lib -lhipfft -lamdhip64`。
完整重新编译、链接；运行时核对实际加载的库来自目标 DTK 安装。
此接口使用 AMD hipFFT 的指针 handle，不是面向所有 HIP 后端的通用绑定。

H100 沿用 `-D__cuda_fft`，NVHPC 编译启用 `-cuda`，链接启用 `-cuda -cudalib=cufft`。
两个 GPU 后端宏只能选一个，不能同时启用 `__fftw`，也不能用于无 OpenACC 的构建。
运行时关闭 OpenACC 后，显式 `system-specific` 会报错；CPU Temperton/Singleton 路径保留。

GPU 三对角代入按独立水平列并行，列内保留原前后递推公式与临时数组。
它及库接口不改变原 FFT 的边界和零模态处理。选择 FFT 前仍需确认当前离散压力问题可分离；
不能将 masking 算例的验证推广到带内部障碍的非 masking 矩阵。
MG 与 FFT 的近似压力及后续轨迹可能不同，应以同右端残差、压力梯度和应用诊断评价，
不能套用执行改写的逐位或 ULP 对照。本轮适用范围与性能证据由 workspace 的压力求解研究记录维护。

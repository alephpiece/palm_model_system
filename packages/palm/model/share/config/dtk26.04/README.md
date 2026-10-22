# Building and running on BW-series DCUs with DTK 26.04

This directory contains an OpenACC build template for BW-series DCUs with
DTK 26.04, GPU optimizations, and hipFFT support. Run the commands below inside
your container. Adjust the paths and target architecture for your installation,
and set `enable_openacc = .TRUE.` in the case input to run on the GPU.
A separate CPU template uses the same flang toolchain and MPI/NetCDF libraries.
The main walkthrough covers GPU execution. Section 6 describes CPU execution.

## 1. Prepare the environment

Required software: DTK 26.04 (flang, OpenACC, and hipFFT), Open MPI built with
that Fortran toolchain, compatible parallel NetCDF-C and NetCDF-Fortran libraries,
GCC, make, Python 3, and Bash.

The template defaults to BW100 (`gfx936`). For other BW models, update
`--offload-arch` in both the compiler and linker options to match the device.
Use your installation paths in the template and environment variables:

| Software | Example installation path |
| --- | --- |
| DTK | `/opt/dtk-26.04` |
| Open MPI | `/opt/mpi-flang` |
| NetCDF-Fortran | `/opt/netcdf-fortran-flang` |
| Parallel NetCDF-C | `/opt/netcdf-parallel` |
| UCX (if used by MPI) | `/opt/ucx` |

```bash
export PATH=/opt/mpi-flang/bin:/opt/dtk-26.04/llvm/bin:/opt/netcdf-parallel/bin:$PATH
export LD_LIBRARY_PATH=/opt/mpi-flang/lib:/opt/netcdf-fortran-flang/lib:/opt/netcdf-parallel/lib:/opt/ucx/lib:/opt/dtk-26.04/lib:/opt/dtk-26.04/llvm/lib:${LD_LIBRARY_PATH:-}
mpifort --showme:command
flang --version
```

Check that the MPI wrapper uses the intended flang compiler and that the
libraries come from a compatible software stack. In the template,
`--allow-run-as-root` supports containers running as root. The option
`--mca coll ^hcoll` disables the hcoll collective component. Adjust these options for your Open MPI
installation and execution environment.

## 2. Configure and build

Use a writable source directory and a new build directory, both with absolute
paths without spaces. Keep the source directory available during runs.
Use the repository's `palmbuild` and `palmrun` directly for this configuration.
The `install` script builds the generic default configuration.

```bash
export PALM_SOURCE=/path/to/palm_model_system
export PALM_BUILD=/path/to/palm-bw
export PATH="$PALM_SOURCE/packages/palm/model/bin:$PATH"
mkdir -p "$PALM_BUILD/JOBS" "$PALM_BUILD/tmp"
sed -e "s|@SOURCE_ROOT@|$PALM_SOURCE|g" \
    -e "s|@BUILD_ROOT@|$PALM_BUILD|g" \
    "$PALM_SOURCE/packages/palm/model/share/config/dtk26.04/.palm.config.dcu.in" \
    > "$PALM_BUILD/.palm.config.dcu"
cd "$PALM_BUILD"
```

Review the dependency paths, `%local_username` (`root` in the template), and the
build parallelism in `%make_options` in `.palm.config.dcu`, then run:

```bash
palmbuild -v -c dcu
```

The executable is written to `MAKE_DEPOSITORY_dcu/palm`. Use a new build directory
when changing the compiler, optimization macros, or FFT backend to avoid mixing
object files. Switching between MG and FFT in the input does not require a rebuild.

## 3. Prepare the case and select a solver

Place the complete input in `$PALM_BUILD/JOBS/test/INPUT/`. Name the parameter
file `test_p3d` and provide any external data required by the case, such as
`test_static` and `test_dynamic`. Use your actual job name
in place of `test` in the commands and input filenames. Example cases are available in
`packages/palm/model/tests/cases/`.

Edit the following fields in the case's existing namelists:

```fortran
! In &initialization_parameters: GPU FFT path
psolver = 'poisfft',
fft_method = 'system-specific',

! In &runtime_parameters: one GPU, one MPI rank
end_time = 1800.0,
enable_openacc = .TRUE.,
npex = 1,
npey = 1,
```

For MG, set `psolver = 'multigrid'` and choose the levels, iterations, and residual
settings for your case. The template enables GPU FFT support through `__hip_fft`.
The input parameter `psolver` selects which solver to use. Choose the solver to suit the case's
geometry and boundary conditions.

When comparing performance, use the same input, including output formats and
frequencies.

## 4. Run

The examples below run on one server with `OMP_NUM_THREADS=8`:

| Option | Value |
| --- | --- |
| `-O` | OMP threads per MPI rank |
| `-X` | Total MPI ranks × OMP threads per rank |
| `-T` | MPI ranks per node |
| `-w` | Maximum parallel I/O streams |

`-O` sets `OMP_NUM_THREADS`. Configure CPU binding through Open MPI and GPU
assignment as shown below. `-X` does not reserve or bind CPUs.

For one GPU and one MPI rank, keep the template's launch command and run
from the build directory:

```bash
export HIP_VISIBLE_DEVICES=0
palmrun -r test -c dcu -a 'd3#' -X 8 -T 1 -O 8 -w 1 -v -z
```

For two GPUs and four MPI ranks, set both `npex` and `npey` to 2 in the input.
Replace `%execute_command` with the line below, using your source directory
in place of `/absolute/path/to/palm`:

```text
%execute_command /opt/mpi-flang/bin/mpirun --allow-run-as-root --mca coll ^hcoll -n {{mpi_tasks}} /absolute/path/to/palm/packages/palm/model/share/config/dtk26.04/rank-gpu.sh ./palm
```

```bash
export HIP_VISIBLE_DEVICES=0,1
palmrun -r test -c dcu -a 'd3#' -X 32 -T 4 -O 8 -w 4 -v -z
```

`rank-gpu.sh` requires four Open MPI ranks on a single node. It assigns ranks
0 and 2 to the first GPU, and ranks 1 and 3 to the second. Each rank sees one GPU
before MPI initialization, so PALM reports `ACC-devices per node: 1`.
Choose CPU bindings that match the container's available CPUs and NUMA layout.

The launcher and rank scripts must preserve the `OMP_NUM_THREADS` value set
by `-O`. In DTK 26.04, this value also affects the default width of some OpenACC
kernels. Keep `-O` fixed when comparing CPU bindings. It does not enable
source-level OpenMP or set `OMP_NUM_THREADS_OFFLOAD`.

The template runs output merging separately with one MPI rank and
`OMP_NUM_THREADS=1`.

## 5. Check the configuration and results

- Record the source commit, final `.palm.config.dcu`, and build log. Check which MPI, NetCDF, and hipFFT libraries `MAKE_DEPOSITORY_dcu/palm` actually loads.
- A four-rank launch should print four `PALM_DTK_RANK_GPU` messages, with alternating GPU assignments and OMP set to 8.
- `test_header.*` should report the selected solver and process decomposition. In `test_cpu.*`, the FFT path appears as `poisfft` and the MG path as `poismg`.
- Check the run status, final simulation time, and numerical output in `JOBS/test/OUTPUT/`.

The template enables the following optimizations. The full compiler macro list
is in `%cpp_options`.

| Computation | Enabled macros |
| --- | --- |
| WS scalar and momentum statistics | `__palm_ws_sharded_stats`, `PALM_WS_MOMENTUM_SHARDS` |
| Surface, flux, and mixed-moment statistics | `PALM_SURFACE_STATS_REDUCTION`, `PALM_FLOW_FLUX_SHARDS`, `PALM_FLOW_MIXED_SHARDS` |
| Humidity, u/v/potential-temperature, and perturbation-energy statistics | `PALM_FLOW_HUMIDITY_SHARDS`, `PALM_FLOW_UVPT_SHARDS`, `PALM_FLOW_ENERGY_SHARDS` |
| Pressure mean, soil, and TCM | `PALM_PRESSURE_MEAN_SHARDS`, `PALM_SOIL_CONDUCTIVITY_MAPPING`, `PALM_TCM_DIFFUSIVITY_ORGANIZATION` |
| Perturbation-energy mapping and TKE shear terms | `PALM_FLOW_ENERGY_MAPPING`, `PALM_TKE_SHEAR_DIAGONAL`, `PALM_TKE_SHEAR_VECTOR64` |
| Equation vector width and humidity update | `PALM_EQUATION_VECTOR64`, `PALM_Q_UPDATE_COLLAPSE3` |
| GPU FFT | `__hip_fft`, linked with hipFFT. Select only one of `__hip_fft`, `__cuda_fft`, and `__fftw`. |

### FFT execution controls

The template also enables these GPU FFT controls:

| Control | Effect |
| --- | --- |
| `PALM_FFT_TRANSPOSE_VECTOR64`, `PALM_FFT_TRANSPOSE_VECTOR64_REST` | Select `VECTOR_LENGTH(64)` for ten three-dimensional permutation loops. |
| `PALM_FFT_LOCAL_ZX_FUSION` | Combine the first and last permutation chains. |
| `PALM_FFT_LOCAL_MIDDLE_FUSION` | Combine the intermediate XY/YZ permutation chains in both directions. |
| `PALM_FFT_PACK_VECTOR64` | Map independent FFT batches to gangs and spectrum conversion loops to vectors of length 64. |
| `PALM_TRIDIA_VECTOR64` | Select `VECTOR_LENGTH(64)` across independent horizontal columns in the GPU tridiagonal substitution kernel. |

Both fusion controls apply to single-rank GPU FFT with uniform decomposition
outside the Temperton vector path. Other configurations keep the original calls.
The spectrum-conversion control applies to the GPU system-specific FFT path.
The tridiagonal control applies to the OpenACC GPU FFT path and changes the
parallel width across columns while keeping substitution sequential within
each column. The CPU fallback is unchanged.

Remove the corresponding `-D` options and rebuild in a new directory to disable
them. These controls do not change the FFT library or MPI decomposition.

## 6. CPU execution

Use `.palm.config.cpu.in` with the flang and MPI/NetCDF environment described in
section 1. The CPU template uses MPI without OpenACC, GPU FFT libraries, or
source-level OpenMP. Keep CPU and GPU builds in separate directories.

```bash
export PALM_SOURCE=/path/to/palm_model_system
export PALM_BUILD=/path/to/palm-cpu
export PATH="$PALM_SOURCE/packages/palm/model/bin:$PATH"
mkdir -p "$PALM_BUILD/JOBS" "$PALM_BUILD/tmp"
sed -e "s|@SOURCE_ROOT@|$PALM_SOURCE|g" \
    -e "s|@BUILD_ROOT@|$PALM_BUILD|g" \
    "$PALM_SOURCE/packages/palm/model/share/config/dtk26.04/.palm.config.cpu.in" \
    > "$PALM_BUILD/.palm.config.cpu"
cd "$PALM_BUILD"
```

Review the dependency paths, `%local_username`, and `%make_options` in
`.palm.config.cpu`, then build:

```bash
palmbuild -v -c cpu
```

The executable is written to `MAKE_DEPOSITORY_cpu/palm`. Place the complete case
input in `$PALM_BUILD/JOBS/test/INPUT/`, including `test_p3d` and any external
data files required by the case.

For a four-rank MG run, set the following fields in the existing namelists:

```fortran
! In &initialization_parameters:
psolver = 'multigrid',

! In &runtime_parameters:
enable_openacc = .FALSE.,
npex = 2,
npey = 2,
```

For a CPU/GPU comparison, use MG on both sides with the same solver settings,
process decomposition, simulation duration, and output schedule. Run from the
CPU build directory:

```bash
palmrun -r test -c cpu -a 'd3#' -X 4 -T 4 -O 1 -w 4 -v -z
```

This launches four MPI ranks with `OMP_NUM_THREADS=1`, using the template's
ordinary MPI command. Check the run status, solver, process decomposition, and
output in `JOBS/test/`.

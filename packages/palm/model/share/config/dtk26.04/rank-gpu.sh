#!/usr/bin/env bash
# Rank-local settings for the validated single-node, four-rank, two-GPU run.
set -euo pipefail

if (( $# == 0 )) || [[ ${OMPI_COMM_WORLD_SIZE-} != 4 || \
                       ${OMPI_COMM_WORLD_LOCAL_SIZE-} != 4 || \
                       ${OMPI_COMM_WORLD_RANK-} != ${OMPI_COMM_WORLD_LOCAL_RANK-} ]]; then
    printf 'rank-gpu.sh requires one node, four Open MPI ranks and a PALM command\n' >&2
    exit 2
fi

if [[ ${HIP_VISIBLE_DEVICES-} =~ ^([0-9]+),([0-9]+)$ ]]; then
    gpu0=${BASH_REMATCH[1]}
    gpu1=${BASH_REMATCH[2]}
else
    printf 'rank-gpu.sh requires HIP_VISIBLE_DEVICES=<gpu0>,<gpu1>\n' >&2
    exit 2
fi
if [[ $gpu0 == "$gpu1" ]]; then
    printf 'rank-gpu.sh requires two distinct GPU indices\n' >&2
    exit 2
fi

case ${OMPI_COMM_WORLD_RANK-} in
    0|2) device=$gpu0 ;;
    1|3) device=$gpu1 ;;
    *) printf 'rank-gpu.sh requires ranks 0..3\n' >&2; exit 2 ;;
esac

export HIP_VISIBLE_DEVICES=$device
printf 'PALM_DTK_RANK_GPU rank=%s device=%s omp=%s\n' \
    "$OMPI_COMM_WORLD_RANK" "$device" "${OMP_NUM_THREADS-<unset>}" >&2
exec "$@"

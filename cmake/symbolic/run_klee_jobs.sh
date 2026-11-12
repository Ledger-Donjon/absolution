#!/usr/bin/env bash
# Launcher of the ${NAME}_klee target: runs one KLEE command line JOBS times,
# side by side, with every "@JOB@" in job k's arguments replaced by k.
#
#   run_klee_jobs.sh JOBS SEED_SLICE OUT_DIR KLEE_COMMAND [KLEE ARGS...] BITCODE
#
# One job runs in the foreground with its output on the terminal. Several jobs
# each write their output to OUT_DIR/<k>.log; their --output-dir must hold
# "@JOB@" (absolution_add_symbolic_target() makes it OUT_DIR/@JOB@).
#
# SEED_SLICE 0 runs each job as one KLEE process. SEED_SLICE N > 0 runs a job's
# --seed-dir one seed at a time instead, in name order, each alone in its own
# KLEE process (--seed-file) for at most N seconds, until the job's --max-time
# is spent. A seed whose states all end sooner hands its time to the next:
#
#   one process:  [seed 1 | seed 2 | ... | seed 90, one instruction each in turn]
#   slices:       [seed 1, N s] [seed 2, N s] [seed 3, N s] ...
#
# Side by side, a seed whose symbolic bytes keep the solver busy stalls every
# other seed of its process. Each slice writes to --output-dir/slices/<i>; its
# tests then move to --output-dir, numbered on from the slice before, and its
# info is appended to --output-dir/info, so the job's output reads as one run.
#
# A symbolic run is a campaign: it ends when it exhausts --max-time, and the
# watchdog then force-halts any blocked STP query, which makes KLEE exit
# non-zero or get killed. That is not a build failure, so exit codes are only
# reported; SummarizeKleeFindings.cmake fails the build if no job started.
set -u
jobs="${1:?jobs}" slice="${2:?seed slice}" out="${3:?output dir}"
shift 3
# STP recurses deeply on long TLV walks.
ulimit -s unlimited
# A slice shorter than this spends most of it loading the bitcode.
MIN_SLICE=10

# run_sliced KLEE_COMMAND...: one job's command line, @JOB@ already replaced.
run_sliced() {
  local -a cmd=("$@")
  local i io=-1 is=-1 it=-1
  for i in "${!cmd[@]}"; do
    case "${cmd[i]}" in
      --output-dir=*) io=$i ;;
      --seed-dir=*) is=$i ;;
      --max-time=*) it=$i ;;
    esac
  done
  if (( io < 0 || is < 0 || it < 0 )); then
    echo "[absolution] seed slices need --output-dir, --seed-dir and --max-time; running one process"
    "${cmd[@]}"
    return
  fi
  local job_out="${cmd[io]#--output-dir=}" seeds="${cmd[is]#--seed-dir=}"
  local total="${cmd[it]#--max-time=}" start=${SECONDS} base=0 n=0
  local seed left t dir f b num max
  mkdir -p "${job_out}/slices"
  shopt -s nullglob
  for seed in "${seeds}"/*.ktest; do
    left=$(( total - (SECONDS - start) ))
    (( left >= MIN_SLICE )) || break
    t=$(( left < slice ? left : slice ))
    dir="${job_out}/slices/${n}"
    echo "[absolution] seed ${n}: $(basename "${seed}"), ${t}s"
    cmd[io]="--output-dir=${dir}"
    cmd[is]="--seed-file=${seed}"
    cmd[it]="--max-time=${t}"
    "${cmd[@]}"
    echo "[absolution] seed ${n} ended (rc=$?)"
    max=0
    for f in "${dir}"/test[0-9][0-9][0-9][0-9][0-9][0-9].*; do
      b="${f##*/}"
      num=$(( 10#${b:4:6} ))
      (( num > max )) && max=${num}
      mv "${f}" "${job_out}/test$(printf '%06d' $(( base + num )))${b:10}"
    done
    base=$(( base + max ))
    [[ -f "${dir}/info" ]] && { echo "== seed ${n}: ${seed}"; cat "${dir}/info"; } >> "${job_out}/info"
    rm -f "${dir}/assembly.ll" "${dir}/run.istats"
    n=$(( n + 1 ))
  done
  shopt -u nullglob
  echo "[absolution] ${n} seed(s) run one at a time, ${base} test(s) in ${job_out}"
}

run_job() {
  if (( slice > 0 )); then
    run_sliced "$@"
  else
    "$@"
  fi
}

if (( jobs == 1 )); then
  run_job "${@//@JOB@/0}"
  echo "[absolution] KLEE ended (rc=$?); a watchdog kill/timeout is a normal end for a symbolic campaign."
  exit 0
fi

mkdir -p "${out}"
pids=()
for (( k = 0; k < jobs; k++ )); do
  run_job "${@//@JOB@/${k}}" > "${out}/${k}.log" 2>&1 &
  pids+=("$!")
done
echo "[absolution] ${jobs} KLEE jobs running side by side; their output goes to ${out}/<job>.log"
for (( k = 0; k < jobs; k++ )); do
  wait "${pids[k]}"
  echo "[absolution] KLEE job ${k} ended (rc=$?)"
done
echo "[absolution] a watchdog kill/timeout is a normal end for a symbolic campaign."
exit 0

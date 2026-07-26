#!/bin/bash
# =============================================================================
# MetaGLens pipeline utilities, sourced by every stage script.
# Provides logging, status management, and resume helpers.
# =============================================================================
set -Eeuo pipefail

# === Logging ===
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE:-logs/pipeline.log}"; }
log_step() { echo ""; log "======== $* ========"; }

# === Status-file operations ===
init_status_if_missing() {
    if [[ ! -f "${STATUS_FILE}" ]]; then
        log "ERROR: ${STATUS_FILE} not found. Run 00_setup.sh first."
        exit 1
    fi
}

update_step_status() {
    local step="$1"
    local status="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    python3 -c "
import json
with open('${STATUS_FILE}', 'r') as f:
    data = json.load(f)
data['steps']['${step}']['status'] = '${status}'
step_data = data['steps']['${step}']
if '${status}' == 'running':
    step_data['started'] = '${timestamp}'
    step_data['attempts'] = int(step_data.get('attempts', 0)) + 1
elif '${status}' == 'completed':
    step_data['finished'] = '${timestamp}'
    step_data['exit_code'] = 0
elif '${status}' == 'failed':
    step_data['failed_at'] = '${timestamp}'
with open('${STATUS_FILE}', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
"
    log "Pipeline status: ${step} -> ${status}"
}

record_step_failure() {
    local exit_code="$1"
    local line_number="$2"
    local failed_command="$3"
    METAGLENS_STATUS_FILE="${STATUS_FILE}" \
    METAGLENS_STEP_NAME="${STEP_NAME}" \
    METAGLENS_EXIT_CODE="${exit_code}" \
    METAGLENS_LINE_NUMBER="${line_number}" \
    METAGLENS_FAILED_COMMAND="${failed_command}" \
    METAGLENS_LOG_FILE="${LOG_FILE:-}" \
    python3 - <<'PY'
import datetime
import json
import os

status_file = os.environ["METAGLENS_STATUS_FILE"]
step_name = os.environ["METAGLENS_STEP_NAME"]
with open(status_file, "r", encoding="utf-8") as handle:
    data = json.load(handle)

step_data = data["steps"].setdefault(step_name, {})
failure = {
    "timestamp": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "attempt": int(step_data.get("attempts", 0)),
    "exit_code": int(os.environ["METAGLENS_EXIT_CODE"]),
    "line": os.environ["METAGLENS_LINE_NUMBER"],
    "command": os.environ["METAGLENS_FAILED_COMMAND"],
    "log_file": os.environ.get("METAGLENS_LOG_FILE", ""),
}
step_data["exit_code"] = failure["exit_code"]
step_data["last_failure"] = failure
data["last_failure"] = {"stage": step_name, **failure}

with open(status_file, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2, ensure_ascii=False)
PY
}

handle_step_error() {
    local exit_code="${1:-1}"
    local line_number="${2:-unknown}"
    local failed_command="${3:-unknown}"
    trap - ERR
    set +e
    if [[ -n "${STEP_NAME:-}" && -n "${STATUS_FILE:-}" && -f "${STATUS_FILE}" ]]; then
        update_step_status "${STEP_NAME}" "failed"
        record_step_failure "${exit_code}" "${line_number}" "${failed_command}"
    fi
    log "ERROR: Stage ${STEP_NAME:-unknown} failed with exit code ${exit_code} at line ${line_number}."
    log "ERROR: Failed command: ${failed_command}"
    exit "${exit_code}"
}

enable_step_failure_trap() {
    trap 'handle_step_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
}

check_step_completed() {
    local step="$1"
    if [[ -f "${STATUS_FILE}" ]]; then
        local status
        status=$(python3 -c "import json;d=json.load(open('${STATUS_FILE}'));print(d['steps'].get('${step}',{}).get('status','pending'))")
        if [[ "$status" == "completed" ]]; then
            log "Step ${step} already completed — skipping."
            return 1
        fi
    fi
    return 0
}

# Return 0 when a step is part of the selected route, 1 otherwise.
# Steps outside the route are provided by the user directly, so their
# prerequisites are not enforced.
step_in_route() {
    local step="$1"
    if [[ -f "${STATUS_FILE}" ]]; then
        python3 -c "import json,sys;d=json.load(open('${STATUS_FILE}'));sys.exit(0 if '${step}' in d.get('selected_steps',[]) else 1)"
        return $?
    fi
    # No status file yet: assume the step is in scope so callers fail loudly.
    return 0
}

check_prerequisite() {
    local step="$1"
    if [[ ! -f "${STATUS_FILE}" ]]; then
        log "ERROR: pipeline_status.json not found. Run 00_setup.sh first."
        exit 1
    fi
    # Route-aware: only enforce prerequisites that belong to the selected route.
    if ! step_in_route "${step}"; then
        log "Prerequisite '${step}' is not part of this route — skipping prerequisite check."
        return 0
    fi
    local status
    status=$(python3 -c "import json;d=json.load(open('${STATUS_FILE}'));print(d['steps'].get('${step}',{}).get('status','pending'))")
    if [[ "$status" != "completed" ]]; then
        log "ERROR: Prerequisite step '${step}' not completed (status: ${status})."
        log "       Please run ${step}.sh first."
        exit 1
    fi
}

# === run_log.md updates ===
update_run_log_progress() {
    local step="$1"
    local status_icon="$2"
    local start_time="$3"
    local end_time="$4"
    # Update the status and time columns while preserving stage and script columns.
    sed -i "s/| ${step} |[^|]*|[^|]*|[^|]*|/| ${step} | ${status_icon} | ${start_time} | ${end_time} |/" "${RUN_LOG}"
}

append_run_log_section() {
    local content="$1"
    echo "${content}" >> "${RUN_LOG}"
}

# === Parallel execution helpers ===
# Load the parallel plan recorded by 00_setup.sh into shell globals:
#   EXEC_ENV, TOTAL_THREADS, PARALLEL_JOBS, THREADS_PER_JOB
# Falls back to safe single-job defaults when the file or fields are absent.
load_parallel_plan() {
    if [[ -f "${STATUS_FILE}" ]]; then
        eval "$(python3 -c "
import json
d=json.load(open('${STATUS_FILE}'))
p=d.get('parallel',{})
print('EXEC_ENV=%s' % (p.get('exec_env','local')))
print('TOTAL_THREADS=%d' % int(p.get('total_threads', ${THREADS:-1})))
print('PARALLEL_JOBS=%d' % max(1, int(p.get('parallel_jobs', 1))))
print('THREADS_PER_JOB=%d' % max(1, int(p.get('threads_per_job', ${THREADS:-1}))))
")"
    else
        EXEC_ENV="${EXEC_ENV:-local}"
        TOTAL_THREADS="${TOTAL_THREADS:-${THREADS:-1}}"
        PARALLEL_JOBS="${PARALLEL_JOBS:-1}"
        THREADS_PER_JOB="${THREADS_PER_JOB:-${THREADS:-1}}"
    fi
}

# Return the 1-based task index when running as a scheduler array job, else "".
current_task_index() {
    if [[ -n "${SLURM_ARRAY_TASK_ID:-}" ]]; then
        echo "${SLURM_ARRAY_TASK_ID}"
    elif [[ -n "${SGE_TASK_ID:-}" && "${SGE_TASK_ID}" != "undefined" ]]; then
        echo "${SGE_TASK_ID}"
    else
        echo ""
    fi
}

# Echo the samples this invocation should process.
# Under a scheduler array job, restrict to the single indexed sample.
# Usage: mapfile -t RUN_SAMPLES < <(resolve_task_samples "${SAMPLES[@]}")
resolve_task_samples() {
    local all=("$@")
    local idx
    idx="$(current_task_index)"
    if [[ -n "${idx}" ]]; then
        local pos=$((idx - 1))
        if (( pos < 0 || pos >= ${#all[@]} )); then
            log "ERROR: array task index ${idx} is out of range (samples: ${#all[@]})."
            exit 1
        fi
        printf '%s\n' "${all[$pos]}"
    else
        printf '%s\n' "${all[@]}"
    fi
}

# Run a function over items with bounded concurrency (batched pool).
# Usage: run_parallel <max_jobs> <func_name> item1 [item2 ...]
# The function receives one item as $1. Returns nonzero if any invocation fails.
run_parallel() {
    local max_jobs="$1"; shift
    local func="$1"; shift
    (( max_jobs < 1 )) && max_jobs=1
    local rc=0
    local -a batch_pids=()
    local count=0 pid item
    for item in "$@"; do
        "${func}" "${item}" &
        batch_pids+=("$!")
        count=$((count + 1))
        if (( count % max_jobs == 0 )); then
            for pid in "${batch_pids[@]}"; do
                wait "${pid}" || rc=$?
            done
            batch_pids=()
        fi
    done
    for pid in "${batch_pids[@]}"; do
        wait "${pid}" || rc=$?
    done
    return "${rc}"
}


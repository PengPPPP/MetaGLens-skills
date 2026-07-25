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
        status=$(python3 -c "import json;f=open('${STATUS_FILE}');d=json.load(f);print(d['steps']['${step}']['status'])")
        if [[ "$status" == "completed" ]]; then
            log "Step ${step} already completed — skipping."
            return 1
        fi
    fi
    return 0
}

check_prerequisite() {
    local step="$1"
    if [[ -f "${STATUS_FILE}" ]]; then
        local status
        status=$(python3 -c "import json;f=open('${STATUS_FILE}');d=json.load(f);print(d['steps']['${step}']['status'])")
        if [[ "$status" != "completed" ]]; then
            log "ERROR: Prerequisite step '${step}' not completed (status: ${status})."
            log "       Please run ${step}.sh first."
            exit 1
        fi
    else
        log "ERROR: pipeline_status.json not found. Run 00_setup.sh first."
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

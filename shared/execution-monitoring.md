# Execution monitoring and self-repair contract

Apply this contract only after the user authorizes script execution. Permission
to generate or inspect scripts does not authorize execution, scheduler
submission, environment changes, database downloads, or destructive cleanup.

## Before execution

1. Run `bash -n` and reject unresolved `{{...}}` placeholders.
2. Validate required inputs, executables, databases, output paths, available
   storage, and scheduler directives.
3. Record the exact command, script checksum, start time, execution mode,
   process ID or scheduler job ID, and log path.
4. Use two automatic repair attempts per stage unless the user explicitly sets
   a different limit.

## Monitor the active run

Keep the task active until the stage reaches a terminal state. Use short,
non-blocking waits and provide concise progress updates during long runs.

- For local execution, monitor the process exit status,
  `pipeline_status.json`, and the bounded tail of the stage log.
- For SLURM, monitor `squeue` while the job is active, then inspect `sacct`
  state, exit code, elapsed time, and peak memory.
- For SGE, monitor `qstat` while the job is active, then inspect `qacct -j`.
- Treat a quiet log as inconclusive; assemblers and database searches may run
  for long periods without emitting output.
- Treat a stage as successful only when the command exits successfully, the
  status is `completed`, and all expected outputs pass validation.

## Diagnose and repair failures

When a stage fails:

1. Capture the stage, attempt number, exit code, failed command and line,
   scheduler reason, and the last 200 relevant log lines. Check storage,
   memory, permissions, executable versions, database paths, and input
   integrity when relevant.
2. Classify the cause:
   - **Script defect:** syntax, quoting, path resolution, empty globs, incorrect
     flags confirmed against the installed tool, or output-validation logic.
   - **Environment or infrastructure:** missing software or database, network,
     permissions, quota, out-of-memory, wall time, or scheduler policy.
   - **Data or scientific configuration:** malformed or mismatched inputs,
     invalid biological assumptions, or parameter choices that change the
     analysis.
3. Automatically patch only a clearly supported script defect. Make the
   smallest change that addresses the observed error.
4. Do not silently change scientific parameters, raw inputs, environments,
   databases, resource requests, or scheduler policy. Request approval when a
   repair requires any of those changes.
5. Preserve the failed script and evidence before editing. Store repair records
   under `metaglens_results/reports/repairs/{stage}/` and append one JSON object
   per attempt to `reports/repair_log.jsonl`. Include the diagnosis, changed
   lines, validation commands, rerun command, and outcome.
6. Re-run `bash -n`, the relevant preflight checks, and input/output contract
   validation after every patch.
7. Re-run only the failed stage. Do not re-run completed upstream stages unless
   the repair invalidates their outputs and the user approves that expansion.
8. Stop and report the evidence when the same failure signature repeats or two
   automatic repair attempts fail. Never enter an unbounded repair loop.

Do not delete nontrivial outputs to make a retry pass. When a tool requires an
empty output directory, preserve or move aside only that failed stage's partial
output, record the action, and obtain approval if the operation could overwrite
or discard useful results.

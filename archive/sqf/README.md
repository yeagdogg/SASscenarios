# SQF — SAS What-If Scenario Framework

> **ARCHIVED (2026-07-22) — frozen but fully working.** SQF was superseded by
> **WIF** (`wif.sas` at the repo root), a much smaller hook-based kernel that
> can modify *intermediate* tables at any point inside the program — something
> an outside-in wrapper like SQF structurally cannot do. SQF still uniquely
> covers "run the whole untouched program N times with durable per-run audit
> folders and a run registry"; if you ever need that governance trail, this
> archive is ready to use as-is (its 89-assertion test suite was green on the
> work server as of the freeze). No further development is planned here.

Run unlimited what-if scenarios against a production SAS process (~25 input
datasets → main program → outputs) **without ever touching the pristine base
data and without copying tables you didn't change**. Scenarios are defined in
an Excel workbook; every run leaves a complete audit trail (staged inputs,
outputs, the exact generated code, logs, HTML report).

```sas
%include "/server/path/sqf.sas";
%sqf_setup(root=/server/sqf_runs, base=/server/prod_inputs,
           control=/server/sqf/scenario_workbook.xlsx,
           main=/server/prod/main_process.sas);

%run_scenario(scenario=RATEUP)              /* rate_change * 1.05        */
%run_chain(scenario=PROJ5, iterations=5)    /* feed outputs forward 5x   */
%compare_runs(run1=..., run2=...)           /* what changed in outputs   */
```

Typical scenario rows in the workbook:

| scenario | method | target | cell |
|---|---|---|---|
| AGEUP | SET_VALUES | POLICIES | `policy_age = policy_age + 1;` |
| RATEUP | SET_VALUES | RATES | `rate_change = rate_change * &RATE_BUMP.;` |
| FEEDFWD | UPDATE_FROM | POLICIES | keys `POL_ID`, source `RUN:BASELINE.OUT_BALANCE` |

## What's in this repo

| path | what it is |
|---|---|
| [sqf.sas](sqf.sas) | the entire framework — one file, one `%include` |
| [test/test_framework.sas](test/test_framework.sas) | self-contained 60+-assertion smoke suite — run this at work FIRST (edit one path). Uses only synthetic data under WORK |
| [template/scenario_workbook.xlsx](template/scenario_workbook.xlsx) | the control workbook (README sheet + 3 data sheets, dropdowns, Text-formatted cells) |
| [template/csv/](template/csv) | CSV fallback if SAS/ACCESS to PC Files is missing |
| [examples/driver_example.sas](examples/driver_example.sas) | the file you open in Enterprise Guide — edit 4 paths and go |
| [examples/custom_step_example.sas](examples/custom_step_example.sas) | CUSTOM_CODE escape-hatch snippet showing the contract |
| [docs/USER_GUIDE.md](docs/USER_GUIDE.md) | sheets, methods, source grammar, chains, troubleshooting |
| [docs/INTEGRATION.md](docs/INTEGRATION.md) | wiring in YOUR main program + EG/server specifics + deploy checklist |
| [docs/DESIGN.md](docs/DESIGN.md) | invariants, failure semantics, why-not-X |

## How it works (30 seconds)

- Your base folder is mounted **read-only**. Nothing can write to it.
- A run stages modified copies of **only the tables the scenario touches**
  into its own run folder; the main program reads through a concatenated
  library (staged first, base second) so everything else falls through.
- Cell text from Excel is validated, parameter-substituted **as literals**,
  and emitted into a generated `apply.sas` that is kept with the run — you can
  always read exactly what transformed the data.
- Everything is validated + dry-run against zero-row sandboxes before any real
  data is staged. Failures stop the run with the step identified; reruns are
  always safe (staging rebuilds from base every run).

## First run at work

1. Copy this folder somewhere the **SAS server** can read.
2. Open `test/test_framework.sas`, edit the one `%let SQF_HOME=` line, submit.
   Expect `NOTE: [TEST] ALL nn ASSERTIONS PASSED`.
3. Follow the checklist in [docs/INTEGRATION.md](docs/INTEGRATION.md).

Built for SAS 9.4 (Base only; SAS/ACCESS to PC Files needed just for xlsx
control files). Works in PC SAS, Enterprise Guide → server, and batch. No X
commands (NOXCMD-safe), no dependencies.

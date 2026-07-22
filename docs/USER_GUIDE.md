# SQF User Guide

SQF ("SAS what-if scenario framework") runs your production SAS process against
**modified copies** of its inputs, defined declaratively in an Excel workbook.
Your base data is never touched; only the tables a scenario changes are copied.

```
%include "<server-path>/sqf.sas";
%sqf_setup(root=..., base=..., control=..., main=...);
%run_scenario(scenario=RATEUP);
```

## The mental model

- **base** — the folder with your ~25 pristine input datasets. SQF mounts it
  read-only and nothing ever writes there. An error never costs you a re-pull.
- **run** — every `%run_scenario` creates
  `root/scenarios/<SCENARIO>/runs/run_<timestamp>/` containing:

  | folder | contents |
  |---|---|
  | `inputs/` | staged copies of ONLY the tables the scenario modified |
  | `outputs/` | whatever your main program wrote |
  | `gen/` | `validate.sas` + `apply.sas` — the exact generated code that ran |
  | `logs/` | load / validate / dryrun / apply / main / audit logs |
  | `audit/` | audit datasets + `report.html` |
  | `control_snapshot/` | the control sheets (and workbook) as they were at run time |
  | `run_info.sas7bdat` | the durable one-row record of the run |

- Your main program reads through a **concatenated library**: staged copy first,
  base second. Tables the scenario didn't touch fall through to base — no copies
  of the other 20+ tables, ever.
- Runs are **rebuilt from base every time**. Running "age + 1" twice gives you
  age + 1 twice *from base*, not age + 2 — reruns are always safe.

## The control workbook

Three sheets (`template/scenario_workbook.xlsx`; CSV fallback below).

### SCENARIOS
| column | meaning |
|---|---|
| `scenario_id` | letters/digits/underscore, starts with a letter, ≤ 24 chars (it becomes a folder name) |
| `description` | free text, echoed in the audit report |
| `parent_scenario` | optional — the parent's steps run first, then this scenario's ("RATEUP plus aging" = child of RATEUP) |
| `active` | Y/N; `%run_all` runs the Y's. A directly named inactive scenario still runs |
| `notes` | free text |

### STEPS
Steps run in `step_no` order (use 10, 20, 30… so you can insert later).
Parent steps run before child steps.

| column | meaning |
|---|---|
| `scenario_id` | which scenario this step belongs to |
| `step_no` | positive integer, unique within the scenario |
| `active` | Y/N — N is skipped (and recorded as skipped) |
| `method` | one of the seven below |
| `target_table` | the input dataset to modify (must exist in base) |
| `where_clause` | full SAS WHERE syntax (LIKE, BETWEEN, IN, IS MISSING …) |
| `key_vars` | UPDATE_FROM only: space-separated key columns |
| `source` | see the source grammar below |
| `assignments` | SET_VALUES: SAS statements. UPDATE_FROM / REPLACE / APPEND: `target_col=source_col` pairs separated by `;` |
| `options` | `NEWCOLS DROP KEEPEXTRA NOWARN0 ITERS=1|2+|ALL` |
| `notes` | free text |

### PARAMETERS
Named values referenced as `&NAME` in any `where_clause` / `assignments` /
`source` cell. Blank `scenario_id` = global; a row with a `scenario_id`
overrides the global for that scenario (and its children). Built-ins:
`&ITER`, `&RUN_ID`, `&SCENARIO_ID`.

**Substitution is literal and happens before any code runs.** The generated
`gen/apply.sas` contains the actual values — open it and you see exactly what
executed, no macro variables left.

## The seven methods

| method | what it does | example |
|---|---|---|
| `SET_VALUES` | change columns in place | `policy_age = policy_age + 1;` where `region = 'E'` |
| `UPDATE_FROM` | pull values by key from a source table | keys `POL_ID`, source `RUN:BASELINE.OUT_BALANCE`, mapping `balance=balance` |
| `REPLACE_TABLE` | swap the whole input for the source | source `RUN:PRICING.NEW_RATES` |
| `FILTER_ROWS` | keep rows matching the where (or drop them with `DROP`) | where `claim_status ne 'VOID'` |
| `APPEND_ROWS` | add the source's rows (where filters the SOURCE, using source column names) | source `BASE:SHOCK_CLAIMS`, mapping `claim_amount=amt_gross` |
| `COPY_TABLE` | stage an exact copy of the base table | see below |
| `CUSTOM_CODE` | inline your own .sas snippet | source `rescale_reserves.sas` |

Method notes:

- **SET_VALUES** — `assignments` is a verbatim block of SAS statements
  (`;`-separated, `IF/THEN` allowed, any function). New columns are rejected
  unless you add `NEWCOLS` (catches typos). Rows affected are counted and a
  0-row match draws a warning (silence with `NOWARN0`).
- **UPDATE_FROM** — implemented as a hash lookup: target row order is
  preserved, unmatched target rows keep their values, duplicate source keys are
  a hard error. Source columns with the *same name* as target columns update by
  name automatically; mapping pairs handle renames on top of that. The optional
  where_clause is limited to IF-compatible operators (no LIKE/BETWEEN — the
  validator will tell you).
- **REPLACE_TABLE** — after mapping, every base column must be available from
  the source; the result is trimmed to the base schema and column order unless
  `KEEPEXTRA`.
- **COPY_TABLE** — the fix when your main program **sorts or updates one of its
  inputs in place**: without a staged copy that write would hit the read-only
  base and error. It also acts as a "reset to base" if used after other steps.
- **CUSTOM_CODE** — the snippet is inlined into `gen/apply.sas` (fully
  auditable). Contract macro variables: `&SQF_SCENLIB` (write here),
  `&SQF_BASELIB` (read-only), `&SQF_RUNDIR`, `&SQF_ITER`, `&SQF_SCENARIO`,
  `&SQF_RUN_ID`, plus every parameter. See `examples/custom_step_example.sas`.

## Source grammar

```
BASE:TABLE                    a pristine base table
SCEN:TABLE                    this run's staged copy (requires an earlier step on it)
RUN:SCENARIO.TABLE            latest COMPLETED run's OUTPUT table   <- feed-forward
RUN:SCENARIO.TABLE@run_id     a pinned specific run
PREV:TABLE                    previous iteration's output (chains only)
my_snippet.sas                CUSTOM_CODE only; relative to <root>/custom/
```

`RUN:` is how you "use the output values from a previous run as inputs for the
next": run BASELINE once, then have a scenario `REPLACE_TABLE` /
`UPDATE_FROM` its inputs from `RUN:BASELINE.<output table>`. A `RUN:`
reference against a scenario whose latest run was a chain resolves to that
chain's **last completed iteration**.

## Cell rules (the validator enforces all of these)

- Text literals in **single quotes**: `region = 'EAST'`, dates `'01JAN2027'd`.
- `&` and `%` inside single quotes are fine (`'R&D'`, `'5%'`).
- `&NAME` outside quotes must match a parameter or built-in; anything else is
  an error before any data is touched.
- No `%macro`-anything and no `/* comments */` in cells (use `notes`).
- Balanced quotes and parentheses.
- Keep expression columns Text-formatted in Excel (the template already is) so
  autocorrect doesn't smart-quote your apostrophes — SQF also un-smarts them
  defensively.

## Running

```sas
%run_scenario(scenario=RATEUP)                 /* full run                    */
%run_scenario(scenario=RATEUP, mode=VALIDATE)  /* checks + dry run only       */
%run_scenario(scenario=RATEUP, mode=APPLYONLY) /* stage inputs, skip the main */
%run_all()                                     /* every active=Y scenario     */
%run_chain(scenario=PROJ5, iterations=5)       /* feed-forward loop           */
%compare_runs(run1=..., run2=...)              /* output difference digest    */
```

Useful arguments (all optional once `%sqf_setup` ran): `control=`, `base=`,
`root=`, `main=`, `inlib=`/`outlib=` (the libref names your program uses),
`prelude=` (a .sas file %included right before the main program — extra
librefs, options), `html=N`, `onfail=ABORT` (for scheduled batch),
`notes=` (free text stored in run_info).

After a run: `&SQF_LAST_STATUS` (COMPLETED / FAILED / VALIDATION_FAILED /
VALIDATED), `&SQF_LAST_RUN_DIR`, `&SQF_LAST_RUN_ID`. The INLIB/OUTLIB librefs
stay assigned so you can browse the run immediately in EG.

## Chains (multi-period feed-forward)

`%run_chain(scenario=PROJ5, iterations=5)` runs the scenario five times under
one run id, in `iter_01/ … iter_05/` subfolders. Each iteration stages fresh
from base; carry-over is **explicit** via `PREV:` sources — e.g.
`UPDATE_FROM POLICIES` keys `POL_ID` source `PREV:OUT_BALANCE` rolls each
iteration's output balance into the next iteration's input. `PREV:` steps are
skipped automatically at iteration 1; `&ITER` is available in any cell;
`ITERS=1` / `ITERS=2+` control which iterations a step runs in. A
`chain_manifest` dataset in the run folder summarizes the iterations.

## Validation and failure behavior

Before anything is staged, SQF checks: sheet structure, ids, methods, tables
and columns against the real base schemas, key types and source-key uniqueness,
parameter references, quote/paren balance — then **generates and executes a dry
run against zero-row sandboxes** and scans its log. Any error names the
scenario, step and field, and the run stops with nothing staged.

If a step fails at apply time, the run stops at that step (`FAILED`, phase and
step recorded), the run folder keeps all debris for post-mortem, and base is
untouched by construction. Rerunning after a failure is always safe.

## CSV fallback (no SAS/ACCESS to PC Files)

Export/maintain the three sheets as `scenarios.csv`, `steps.csv`,
`parameters.csv` in one folder and pass `control=<that folder>`. Same columns,
same rules; multi-line cells are not supported in CSV. `%sqf_make_template()`
writes starter files. Power users can skip files entirely:
`control_type=DATASET` reads `work.ctl_scenarios/ctl_steps/ctl_parameters`
(that is how the test suite runs).

## Troubleshooting

| symptom | likely cause |
|---|---|
| "Workbook not found" in EG | the path is your PC's, not the server's — move the workbook to a server-visible share |
| "Could not read sheet ... PC Files" | XLSX engine not licensed or workbook open in Excel → use the CSV fallback |
| "Unknown parameter &X" | typo, or the parameter row is scoped to a different scenario |
| 0 rows affected warning | where_clause matched nothing — check values/case (`'E'` vs `'e'`) |
| FAILED phase=MAIN on a zero-step run | your program updates an input in place — add a `COPY_TABLE` step for that table (see docs/INTEGRATION.md) |
| Registry looks stale / RUN: not resolving | `%rebuild_registry()` reconstructs it from the run folders |

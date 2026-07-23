# WIF — hook-based what-if scenarios for SAS

Modify **any table at any point inside a SAS program** — including
intermediates like `work.guidance_100` seconds after they're created —
according to scenarios defined as data (an Excel sheet, a dataset, or five
lines of datalines). Hooks are inert until a scenario is active: safe to
leave in production permanently, like feature flags.

```sas
%include "/server/path/wif.sas";

/* in your program, after any table worth tweaking: */
data work.guidance_100;
    ...
run;
%wif(guidance_100)

/* in your driver: */
%wif_init(scenario=RENEWAL, rules=/server/path/wif_workbook.xlsx);
%include "/server/path/my_program.sas";
%wif_off;  %wif_report;
```

A rule row says what happens at a hook:

| scenario | hook | verb | details |
|---|---|---|---|
| RENEWAL | POLICIES | SET | `policy_age = policy_age + 1;` |
| RENEWAL | GUIDANCE_100 | JOIN | keys `POL_ID`, source `WORK.CARRY`, map `PRIOR_MOD=EXPIRING_MOD`, `ITERS=2+` |
| MKTADJ | RATED | JOIN | keys `NAICS LOB STATE`, source `WORK.MKT_ADJ`, pull `ADJ_FACTOR`, compute `rate = rate * adj_factor;` |

Verbs: **SET** (in-place assignments, preflighted against a zero-row copy so
typos never touch your data), **JOIN** (order-preserving hash left-join +
same-pass computed columns — the bulk-what-if workhorse), **FILTER**,
**APPEND**, **REPLACE**, **CODE** (verbatim escape hatch), **LET**
(parameters). Raw permanent inputs are handled by `hook=INPUT` rules
applied to **staged copies** behind a readonly-nested libref — base data is
physically untouchable. Every application is logged to `work.wif_log` with
rows before/after/affected, and the exact generated code is kept under
`WORK/wif_gen/`.

Multi-run sweeps and renewal/CLV loops are one `%do` loop in a driver —
see `examples/`. Because rules are data, scenario grids can be **generated
programmatically** (a data step emitting SHOCK_001…SHOCK_100).

## What's in this repo

| path | what it is |
|---|---|
| `wif.sas` | the whole kernel — one `%include` |
| `template/wif_workbook.xlsx` | rules workbook template (README + RULES sheets) |
| `test/test_wif.sas` | self-contained test suite (runs entirely under WORK) |
| `examples/wif_driver_example.sas` | the file you open in EG |
| `examples/clv_loop_example.sas` | N-year renewal / CLV loop driver |
| `docs/WIF_GUIDE.md` | the manual: hook placement rules, verbs, authoring, staging, troubleshooting |
| `tools/lint_sas.py` | dev-side linter — checks `%wif()` hook placement too |
| `tools/make_wif_workbook.py` | regenerates the workbook template |
| `archive/sqf/` | the earlier whole-program wrapper framework (frozen, working) — durable per-run audit folders, run registry, chains |

## First run at work

1. `git pull`, copy (or point EG at) `wif.sas` and `test/test_wif.sas` on
   the server.
2. Edit the one `%let WIF_HOME =` line in `test/test_wif.sas`, submit it.
   Red ERROR lines between the "NEGATIVE TESTS" banners are expected (the
   framework rejecting bad rules on purpose); success is the final box:
   `NOTE: [TEST] ALL nn ASSERTIONS PASSED`.
3. Add 2–3 hooks to a copy of your real program, run it with **no scenario
   active**, and PROC COMPARE its outputs against a normal run — they must
   be identical (hooks provably inert).
4. First real scenario: start from `template/wif_workbook.xlsx` or the
   datalines block in `examples/wif_driver_example.sas`.

Read `docs/WIF_GUIDE.md` before placing hooks — the placement rules
(open code only, right after `run;`/`quit;`) are absolute, and
`python tools/lint_sas.py your_program.sas` checks them for you.

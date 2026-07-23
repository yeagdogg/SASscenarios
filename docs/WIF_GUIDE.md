# WIF User Guide

WIF is a hook-based what-if kernel for SAS 9.4. You drop `%wif(tablename)`
hooks into your program right after tables are created; a scenario — a small
**rules table** (Excel sheet, dataset, or datalines) — says what to change at
each hook. With no scenario active, every hook expands to **nothing**: hooks
are safe to leave in production code permanently, like feature flags.

```sas
%include "/server/path/wif.sas";            /* always - see Deployment */

%wif_init(scenario=RENEWAL, rules=/server/path/wif_workbook.xlsx);
%include "/server/path/my_program.sas";     /* its hooks fire as it runs */
%wif_check();                               /* gate: ERROR if anything failed */
%wif_off;
%wif_report;
```

What success looks like in the log (this is what you verify by):

```
NOTE: [WIF] scenario RENEWAL ACTIVE (iter=1, onfail=STOP, 4 rule(s)).
...
NOTE: [WIF] ==== hook GUIDANCE_100 firing: 2 rule(s), scenario RENEWAL, iter 1 (fire 3) ====
NOTE: [WIF] JOIN seq 10 on WORK.GUIDANCE_100 from WORK.CARRY;
NOTE: [WIF] rule seq 10 (JOIN) on WORK.GUIDANCE_100: rows 5240 -> 5240, affected=5108.
NOTE: [WIF] ==== hook GUIDANCE_100 done ====
...
NOTE: [WIF] wif_check: clean (scope=GEN, strict=N).
NOTE: [WIF] scenario RENEWAL deactivated: 4 rule application(s) OK, 0 problem(s).
```

## The mental model

- Your program is untouched except for inert `%wif()` markers at the tables
  you might ever want to tweak. Add them over time; they cost nothing.
- A **rule** = (scenario, hook, verb, details). At `%wif(guidance_100)` the
  kernel looks up rules for hook `GUIDANCE_100` in the active scenario and
  applies them to that table **in place**, right there, mid-program.
- WORK intermediates are rebuilt every run, so in-place modification is safe
  by construction. **Permanent input tables are never modified in place** —
  `hook=INPUT` rules act on staged copies under WORK (see Input staging).
- Everything applied is logged to `work.wif_log` (rows before / after /
  affected), announced with `NOTE: [WIF]` lines in the log you're already
  watching, and the exact generated code is kept under `WORK/wif_gen/` for
  audit.

## Deployment: wif.sas must ALWAYS be compiled

`%include "wif.sas"` must run unconditionally — autoexec, EG project first
node, or the top of the program. An **uncompiled** `%wif` call is an ERROR,
not a no-op (the feature flag lives inside the macro). Include it always;
activate it only when you want it.

## Placing hooks — the commandments

There is no way for WIF to detect a misplaced hook at run time, so these are
absolute:

1. **Open code only**, immediately after a `run;` or `quit;`.
2. **Never inside a DATA step.** The active hook would truncate the step and
   the statements after it would misbehave.
3. **Never between PROC SQL statements.** Hook after the `quit;`.
4. Inside your own macros: only at step boundaries (right after a generated
   `run;`/`quit;`).
5. Inside CALL EXECUTE: only as `call execute('%nrstr(%wif(t))')` — the
   `%nrstr` defers the hook to queue flush, which is a step boundary.
6. Run `python tools/lint_sas.py your_program.sas` after adding hooks — it
   checks placement mechanically (ships in this repo).

`%wif(t)` hooks table `t` (one-level names resolve like SAS: `USER=` option
if set, else WORK). `%wif(t, at=NAME)` fires the rules whose hook is `NAME`
instead — use it when the same table is created twice (hook each site with
its own name), or to run one rule against many tables from a loop:

```sas
%do i = 1 %to 12;
    ... create work.seg_&i ...; run;
    %wif(seg_&i, at=SEGLOOP)      /* rules with hook=SEGLOOP, blank target */
%end;
```

## The rules table

One table, one row per rule. In Excel: the RULES sheet of
`template/wif_workbook.xlsx`. As a dataset: same columns (only `hook` and
`verb` are mandatory — everything else defaults sensibly).

| column | meaning |
|---|---|
| `scenario` | owner scenario. **Blank = global** (applies to every scenario) |
| `hook` | where it fires: a table name, a custom `at=` name, or `INPUT` |
| `seq` | order within the hook (10, 20, 30…; blank = sheet order) |
| `active` | Y/N (blank = Y) |
| `verb` | SET / JOIN / FILTER / APPEND / REPLACE / CODE / ASSERT / SAVE / SORT / DEDUPE / LET |
| `target` | usually blank = the hooked table. INPUT rules need `libref.table` |
| `where_clause` | row condition — see the dialect table below |
| `keys` | JOIN: key columns, `key` or `srckey=targetkey`. SORT/DEDUPE: the by-keys |
| `source` | JOIN/APPEND/REPLACE: the lookup/donor table. **SAVE: the DESTINATION** |
| `columns` | column mapping: `srccol` or `srccol=targetcol`, space-separated |
| `assign` | SET/JOIN: SAS assignments. CODE: the code. LET: the value |
| `options` | `ONCE ITERS=1|2+|ALL NEWCOLS NOWARN0 DROP KEEPEXTRA ALLOWLIB LAST NOMATCH=KEEP|FAIL|DELETE` |
| `notes` | for humans |

### Which WHERE dialect does my clause use?

| verb | dialect | notes |
|---|---|---|
| SET | **either** | IF-syntax runs in one pass; WHERE-only operators (LIKE, BETWEEN, IS MISSING, `<>`) are detected and auto-routed through an order-preserving 4-pass split with real WHERE semantics — `<>` means NOT-EQUAL there |
| JOIN | IF-syntax only | the clause gates the lookup row by row inside the step |
| FILTER / APPEND / ASSERT | full WHERE | LIKE/BETWEEN/IS MISSING all fine |

Rows whose `scenario` or `hook` cell starts with `#` are comments.

### The verbs

- **SET** — change columns in place.
  `assign` is a verbatim block of SAS statements (`;`-separated, IF/THEN and
  functions fine). `where_clause` limits rows: IF-syntax clauses run in one
  pass; clauses using WHERE-only operators are auto-routed through the
  order-preserving split (see the dialect table — 4 passes, so prefer
  IF-syntax on very large tables). Every SET is **preflighted against a
  zero-row copy first**: a typo that would create a new column, or a syntax
  error, is caught **before** your table is touched (`NEWCOLS` permits
  intentional new columns).
- **JOIN** — the workhorse: hash left-join `source` by `keys`.
  Row order preserved, duplicate source keys are a hard error (the step dies
  and the target keeps its previous contents — same-name rewrites only
  replace the table at successful completion). Keys may be renamed across
  sides: `PID=POL_ID` matches source `PID` to target `POL_ID`. `columns`
  pulls source columns in (`ADJ_FACTOR` or `NEW_MOD=SCHED_MOD`); columns you
  list may be new on the target (missing on unmatched rows). `assign`
  computes **in the same pass**, only on matched rows:
  `rate = rate * adj_factor;`. Blank `columns` = update all same-named
  non-key columns. Unmatched rows: `NOMATCH=KEEP` (default) leaves them,
  `NOMATCH=FAIL` aborts with the key values in the ERROR line (the "every
  policy must find a rate" QA case), `NOMATCH=DELETE` drops them
  (semi-join). JOINs are **preflighted** like SET (zero-row hash — typos
  caught before a multi-GB rewrite). Sources bigger than `WIF_MAXHASH`
  (default ~500MB) and view sources are refused at prep.
- **FILTER** — keep rows matching `where_clause` (full WHERE syntax).
  `DROP` option inverts.
- **APPEND** — add the source's rows; `where_clause` filters the **source**
  (full WHERE syntax); `columns` maps names (`AMT_GROSS=CLAIM_AMOUNT`);
  same-named columns map automatically; `NEWCOLS` lets a mapping introduce a
  source-only column (missing on the original rows).
- **REPLACE** — swap the whole table for `source`, trimmed to the target's
  columns and order (`KEEPEXTRA` keeps extras). A source missing a target
  column — or a rename collision — is refused at prep.
- **ASSERT** — a QA gate, never modifies: `where_clause` states the
  condition EVERY row must satisfy (full WHERE syntax). Rows failing it are
  violations: the rule logs FAILED with the count, keeps the first 200
  offenders in `work.wif_viol`, and follows the normal onfail flow. Put one
  after a rating join: `not missing(rate)`.
- **SAVE** — snapshot the hooked table mid-program without modifying it.
  The **destination goes in the `source` column** and may use parameters:
  `RESULTS.SNAP_&WIF_SCENARIO.` — resolved at init and name-validated
  (including the 32-character limit) before anything runs.
- **SORT** — `keys` with `DESCENDING` allowed before a name. (A CODE cell
  can do this too; the verb buys prep-time key validation and, with DEDUPE,
  the keep-latest-per-key pattern.)
- **DEDUPE** — sort by `keys` and keep the FIRST row per key (`LAST` option
  flips it); dropped count is logged. `SORT keys=POL_ID DESCENDING EFF_DATE`
  then `DEDUPE keys=POL_ID` = latest row per policy.
- **CODE** — escape hatch: the `assign` cell is emitted **verbatim** into
  the generated file (full steps allowed — a MERGE, PROC steps, anything).
  `&WIF_TABLE` and `&WIF_HOOK` resolve to the hooked table / hook name. The
  hooked table must still exist afterward (checked).
- **LET** — not a modification: defines a parameter. `target` = name,
  `assign` = value. Scenario-scoped LET beats global LET of the same name.

### Parameters

Reference `&NAME` in `where_clause` / `assign` / `source` cells. Values come
from LET rows and/or `%wif_init(params=rate_bump=0.03|as_of='01JAN2026'd)`
(pipe-separated; params= beats LET). Built-ins: `&WIF_ITER`,
`&WIF_SCENARIO` (plus `&WIF_TABLE`/`&WIF_HOOK` in CODE cells). Substitution
is **literal and happens before any code runs** — the generated file under
`WORK/wif_gen/` shows the actual values. `&` and `%` inside single quotes
are always safe (`'R&D'`, `'5%'`); any other live `&`/`%` outside quotes is
a lint error before anything is touched. Parameter names may not start with
`WIF`.

## Three ways to author rules

**1. Datalines (ad-hoc, zero quoting pain — cell text is data, the macro
processor never sees it, so `&` and `%` are safe as-is).** Two rules of the
road: use **`datalines4` with a `;;;;` terminator** (rule cells contain
semicolons, and a plain `datalines` block ends at the first one — SAS's
documented restriction), and keep this exact column order everywhere:

```sas
data work.rules;
    length scenario $32 hook $32 seq 8 verb $8 target $41 keys $200
           source $41 columns $1000 assign $8000 options $200;
    infile datalines dsd dlm='|' truncover;
    input scenario :$32. hook :$32. seq verb :$8. target :$41. keys :$200.
          source :$41. columns :$1000. assign :$8000. options :$200.;
/* cols: scenario|hook|seq|verb|target|keys|source|columns|assign|options */
datalines4;
RENEWAL|POLICIES|10|SET|||||policy_age = policy_age + 1;|
RENEWAL|GUIDANCE_100|10|JOIN||POL_ID|WORK.CARRY|SCHED_MOD=EXPIRING_MOD||ITERS=2+
;;;;
run;
%wif_init(scenario=RENEWAL, rules=work.rules)
```

**2. The Excel workbook** (`template/wif_workbook.xlsx`) — best for scenario
libraries you maintain over months. Save it where the SAS **server** can
read it; `rules=` takes the path. Keep expression columns Text-formatted
(the template already is).

**3. Programmatically** — rules are data, so **generate them**. A hundred
rate shocks:

```sas
data work.shock_rules;
    length scenario $32 hook $32 seq 8 verb $8 assign $8000;
    do i = 1 to 100;
        scenario = cats('SHOCK_', put(i, z3.));
        hook = 'RATED'; seq = 10; verb = 'SET';
        assign = cats('rate = rate * ', put(1 + i / 100, 8.2), ';');
        output;
    end;
    drop i;
run;
```

(`%wif_rule(...)` sugar appends single rows from open code; put `%nrstr()`
around text containing `&` or `%`.)

## Input staging (`hook=INPUT`)

For the ~25 permanent inputs your program reads directly. Rule of thumb:
**hook if you can, stage only what has no hook point** (a table consumed
straight into PROC SQL joins, say). At `%wif_init`:

1. Each INPUT rule's target (`RAW.RATES` — two-level, mandatory) is copied,
   modified, into `<WORK>/wif_in` (compressed; only targeted tables copied —
   never the other 20+).
2. The libref is repointed as a concatenation: **staged copies first, the
   pristine base second and READONLY**. Reads fall through for unstaged
   tables; any in-place write that falls through to base **fails loudly**
   instead of touching production data.
3. `%wif_off` restores the original libref exactly. If a run is interrupted,
   the next `%wif_init` restores it first (crash recovery).

v1 constraints: the libref must be a **single-path BASE-engine** libname
(no ODBC, no concatenations), assigned before `%wif_init` and not
re-assigned inside your program (if the program assigns its own libnames in
its header, move those to the driver — or pass `inlib=RAW, base=/path` and
let WIF assign it). Staged copies live under WORK: they vanish with the
session, and multi-GB staged tables consume WORK-volume space.

## Multi-run drivers

**Five scenarios, one program, labeled outputs:**

```sas
%let scens = BASE UP5 DOWN5 AGEUP SHOCK;
%macro sweep();
%do i = 1 %to %sysfunc(countw(&scens));
    %wif_run(scenario=%scan(&scens, &i), rules=work.rules,
             main=/server/path/my_program.sas,
             keep=out_final out_summary, outlib=results);
%end;
%mend sweep;
%sweep()
```

`%wif_run` = init → `%include` the program → save each `keep=` table as
`<scenario>_<table>` in `outlib=` → off. (A BASE scenario with zero rules is
a legitimate way to get the untouched baseline through the same pipeline.)

**The renewal / CLV loop** (see `examples/clv_loop_example.sas`): run the
program N times with `iter=&y`; between iterations build a small
carry-forward table from the outputs; rules gated `ITERS=2+` JOIN it back
in. `&WIF_ITER` is available in any cell.

```sas
%do y = 1 %to &years;
    %wif_init(scenario=RENEWAL, rules=work.rules, iter=&y)
    %include "&prog";
    proc sql;  /* next year's starting point, from this year's result */
        create table work.carry as
        select pol_id, sched_mod as prior_mod from work.final_rated;
    quit;
    %wif_save(table=final_rated, as=year&y._rated, lib=results)
    %wif_off
%end;
```

## The log

`work.wif_log` — one row per rule application, per firing:
`gen scenario iter fire hook seq verb target status rows_before rows_after
rows_affected message logged_at`. `%wif_report` prints it. Statuses:

| status | meaning |
|---|---|
| `OK` | applied; counts recorded |
| `FAILED` | rule failed; the message carries the reason AND the last SAS error text; target kept its previous contents (except a post-JOIN column check, which says so) |
| `NO_TABLE` | the hooked table didn't exist at that point — hook placed too early? |
| `SKIP_ITER` / `SKIP_ONCE` | gated by `ITERS=` / already fired with `ONCE` |
| `SKIP_FAIL` | never ran: an earlier rule on the same hook failed under onfail=CONTINUE |
| `SKIP_SYSCC` | session was already in error state; WIF refused to touch anything |

**`%wif_check()`** is the batch gate: call it after `%wif_off` — it ERRORs
(and sets `WIF_RC=1`; `onbad=ABORT` cancels the submit) if the run produced
any FAILED / NO_TABLE / SKIP_SYSCC / SKIP_FAIL rows; `strict=Y` also flags
OK rules that affected 0 rows. **`%wif_status()`** prints the whole state at
a glance (active scenario, rules by hook, staged librefs, log tail).
**`%wif_compare(base=, scen=, tables=, keys=)`** diffs two runs' saved
outputs (`<SCENARIO>_<table>` names from `wif_run keep=`): row counts,
orphan keys both ways, changed-row counts, and per numeric column the
n / sum / mean side by side with deltas over the **key-matched** rows.

`onfail=STOP` (default) cancels the whole submit on any FAILED —
fix-and-resubmit, nothing half-applied silently. `onfail=CONTINUE` logs,
skips that hook's remaining rules, resets the error state, and lets the
program finish.

**A rule affecting 0 rows draws a WARNING** (check values/case: `'E'` ne
`'e'`) — silence per-rule with `NOWARN0`.

## EG session staleness — read this once

**Globals persist across submits in one EG session.** If you ctrl-stop a
scenario run, WIF is still ACTIVE and your next plain submit will fire
hooks. Defenses: every driver ends with `%wif_off` (unconditionally); every
firing announces itself with `NOTE: [WIF]` naming the scenario; if WORK was
cleaned, hooks deactivate themselves with a WARNING. **When in doubt (or
whenever anything is wedged): submit `%wif_reset;`** — it restores/clears
librefs (including orphans), deactivates, clears the error state, and keeps
`work.wif_log`.

## wif_run without a server file: code=

EG programs often live only in the project, with no server path for
`main=`. Wrap the program once in a macro and run it by name:

```sas
%macro my_prog();
    ... your program, hooks included ...
%mend my_prog;             /* submit that once, then: */
%wif_run(scenario=UP5, code=my_prog, rules=work.rules,
         keep=out_final, outlib=results)
```

Caveats of macro-wrapping (they error at YOUR %macro submit, before WIF is
involved): DATALINES cannot live inside a macro, and single-quoted literals
containing `&`/`%` go live inside macro definitions.

## Autohook: instrument a program automatically

```sas
%include "/server/path/tools/wif_autohook.sas";
%wif_autohook(main=/server/path/my_program.sas,
              out=/server/path/my_program_hooked.sas)
```

Writes a SUGGESTED copy with `%wif()` hooks inserted after every step that
creates a WORK table (data steps, `proc sql create table`, `proc sort
out=`, MEANS/SUMMARY `output out=`, TRANSPOSE `out=`) — **the original file
is never touched**. Anything ambiguous (tables created twice, steps inside
macros, views, permanent-library outputs, `run;` sharing a line) becomes a
report row in `work.wif_autohook` with a paste-ready suggestion instead of
an insertion. Review the copy, then verify placement with
`python tools/lint_sas.py <copy>`.

## Performance notes (multi-GB tables)

Passes over the target per rule: SET (IF-syntax) / JOIN / FILTER / REPLACE
= 1; APPEND = 1 (2 when it has a where); DEDUPE = 2; SET with WHERE-only
operators = 4 (the order-preserving split) — prefer IF-syntax clauses on
very large tables. Several SET changes belong in ONE rule: the assign cell
takes multiple statements, and one rule = one pass. JOIN loads the SOURCE
into memory (gated by `WIF_MAXHASH`, default ~500MB) — the multi-GB side
should be the target, never the source. Staged INPUT copies are compressed
(`compress=binary`).

Also one-session-scoped by design: `work.wif_log`, staged inputs, generated
code under `WORK/wif_gen/`. Save anything you want to keep (`%wif_save`, or
copy `wif_log` to a permanent library) before closing the session.

## Troubleshooting

| symptom | likely cause |
|---|---|
| Anything wedged / unsure what state you are in | `%wif_status;` to look, `%wif_reset;` to make it sane |
| Hook did nothing, no NOTE at all | no scenario active (init failed or never ran) — check `&WIF_RC`, rerun `%wif_init` |
| `no applicable rules` NOTE | hook name vs rules `hook` column mismatch (custom `at=`? INPUT vs table name?), or all rules gated by `ITERS=`/`ONCE` |
| `NO_TABLE` | hook fires before the table exists — move it below the creating step |
| Rule FAILED, "data grid" hint | close the EG data grid holding the table open, resubmit |
| `Unknown parameter` at init | typo, LET row in a different scenario, or missing `params=` |
| Workbook not read | path is your PC's, not the server's; or workbook open in Excel — close it or import the sheet to a dataset and pass that |
| Wrong hook fired twice for a re-created table | give each creation site its own `at=` name |
| Staging refused (engine/concat) | v1 stages single-path BASE librefs only — extract to a folder or hook the first WORK table instead |

## Limits (deliberate)

No scenario inheritance (duplicate rows or generate them — rules are data),
no CSV loader (import the sheet to a dataset in EG — that IS dataset mode),
CODE cells only (no snippet files), JOIN sources must be tables (not views)
and fit in memory, no mid-PROC-SQL interception (structurally impossible
for any tool — hook the materialized table between queries). Column
pruning/renaming is a CODE one-liner:
`data &WIF_TABLE.; set &WIF_TABLE.(drop=colx); run;`. The archived SQF
framework (`archive/sqf/`) still covers whole-run orchestration with
durable per-run audit folders if that governance trail is ever needed.

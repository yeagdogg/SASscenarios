# WIF in 30 minutes

WIF lets a **scenario** (a small rules table) modify **any table at any
point inside your SAS program** via inert `%wif(table)` hooks. This page is
the first-Monday path; the full manual is `docs/WIF_GUIDE.md`.

Everything below runs on the SAS **server** (EG): paths are server paths.

## 1. Prove the kernel on your box (5 min)

Open `test/test_wif.sas`, edit the one `%let WIF_HOME =` line, submit.
Red ERROR lines between the **NEGATIVE TESTS** banners are the framework
rejecting bad rules on purpose. Success is the final box:

```
NOTE: [TEST] ALL nn ASSERTIONS PASSED
```

## 2. Hook a COPY of your program (10 min)

```sas
%include "<WIF_HOME>/wif.sas";
%include "<WIF_HOME>/tools/wif_autohook.sas";
%wif_autohook(main=/server/path/my_program.sas,
              out=/server/path/my_program_hooked.sas)
```

Autohook writes a SUGGESTED copy with hooks after every step that creates a
WORK table, and a report (`work.wif_autohook`) of every site it deliberately
left to you. Review the copy. The five placement rules, condensed: hooks
live in **open code**, right after a `run;`/`quit;` — never inside a DATA
step, never between PROC SQL statements, in your own macros only at step
boundaries, in CALL EXECUTE only wrapped in `%nrstr`.

## 3. Prove the hooks change nothing (5 min)

Run the hooked copy with **no scenario active**, then PROC COMPARE its
outputs against a normal run. They must be identical — hooks are inert
until you activate a scenario, so they can stay in the program forever.

## 4. First scenario (5 min)

```sas
data work.rules;
    length scenario $32 hook $32 seq 8 verb $8 target $41 keys $200
           source $41 columns $1000 assign $8000 options $200;
    infile datalines dsd dlm='|' truncover;
    input scenario :$32. hook :$32. seq verb :$8. target :$41. keys :$200.
          source :$41. columns :$1000. assign :$8000. options :$200.;
/* cols: scenario|hook|seq|verb|target|keys|source|columns|assign|options */
datalines4;
FIRST|GUIDANCE_100|10|SET|||||sched_mod = min(sched_mod, 1.25);|
;;;;
run;

%wif_init(scenario=FIRST, rules=work.rules)
%include "/server/path/my_program_hooked.sas";
%wif_check();
%wif_off;
%wif_report;
```

(`datalines4` + `;;;;` because rule cells contain semicolons. For scenario
libraries you maintain over time, use `template/wif_workbook.xlsx` and pass
its server path as `rules=`.)

## 5. Read the log like WIF does

Every firing prints `NOTE: [WIF] ==== hook X firing ====` with per-rule
rows before/after/affected; `work.wif_log` keeps it all; `%wif_status;`
shows the whole state at a glance; `%wif_check();` errors if anything
failed. A rule that affects **0 rows** draws a WARNING — that is usually a
value/case mismatch in a where clause.

## 6. If anything wedges

```sas
%wif_reset;
```

Restores librefs, deactivates hooks, clears the error state, keeps the log.

## Where to next

- Multi-scenario sweeps and the renewal/CLV loop: `examples/`
- Verbs (SET/JOIN/FILTER/APPEND/REPLACE/CODE/ASSERT/SAVE/SORT/DEDUPE),
  parameters, INPUT staging for the raw ~25 inputs: `docs/WIF_GUIDE.md`
- QA gates: an `ASSERT` rule after your rating join
  (`where_clause = not missing(rate)`) fails loudly with a violation sample
- Scenario-vs-baseline diffs: `%wif_compare(base=BASE, scen=UP5,
  tables=out_final, keys=pol_id, lib=results)`

# Integrating your production program with SQF

Goal: your existing SAS process runs **unmodified** (or with one small,
backward-compatible edit) while SQF decides which inputs it sees.

SQF's contract with your program is just two librefs:

- it READS inputs through `INLIB` (or whatever name you pass as `inlib=`),
- it WRITES outputs through `OUTLIB` (or `outlib=`).

Before %including your program, SQF assigns:

```sas
libname SQFBASE "<base folder>" access=readonly;
libname INLIB ("<run>/inputs" SQFBASE);   /* staged copies first, base second */
libname OUTLIB "<run>/outputs";
```

## Step 1 — reconnaissance (5 minutes, at work)

```sas
%include "<path>/sqf.sas";
%sqf_scan_program(main=<path to your main program>)
```

This lists every LIBNAME / %INCLUDE / FILENAME / PROC IMPORT-EXPORT /
hardcoded-path line with line numbers. Three cases:

### Case A — the program has NO libname statements of its own
It expects `INLIB`-style librefs to exist already (assigned by an autoexec or a
wrapper). **Zero edits.** If its libref names aren't INLIB/OUTLIB, just pass
them: `%run_scenario(..., inlib=RAW, outlib=RES)`.

### Case B — the program assigns its own libnames (hardcoded paths)
One-time, backward-compatible edit — wrap each of those libnames in a guard so
a pre-assigned libref wins:

```sas
/* before */
libname INLIB "/prod/data/inputs";

/* after  */
%macro _lib_guard;
%if %sysfunc(libref(INLIB)) ne 0 %then %do;   /* not already assigned? */
    libname INLIB "/prod/data/inputs";        /* production default    */
%end;
%mend;
%_lib_guard
```

Run standalone → identical behavior to today. Run under SQF → SQF's libraries
win. (If the program has many libname statements, hoist them into one
`config_libs.sas` it %includes, and guard there.)

### Case C — one libref used for BOTH reading inputs and writing outputs
Split it: reads keep `INLIB`, final output writes become `OUTLIB`. This is the
only edit with any thought in it — if outputs went to the inputs library, the
next run's rebuild would wipe them. `%sqf_scan_program` + a search for
`data <libref>.` / `proc ... out=<libref>.` finds the write sites.

## The in-place trap (read this one)

Programs that **sort or update one of their own inputs in place** —
`proc sort data=INLIB.claims;`, `proc append base=INLIB.x`,
`data INLIB.x; set INLIB.x; ... run;` with intent to persist — will ERROR under
SQF when that table wasn't staged, because the fall-through copy is the
read-only base. That error is *correct* (it's the framework refusing to let
anything touch base). The fix is one control row per such table:

```
method=COPY_TABLE  target_table=CLAIMS
```

in every scenario that runs the full program (put it in a shared PARENT
scenario so children inherit it). The test suite's dummy program does exactly
this on purpose — test T16 shows you the behavior on your build.

If the program only *sorts* an input for BY-processing, a cleaner long-term
edit is `proc sort data=INLIB.claims out=work.claims;` and read WORK after.

## Extra librefs, formats, autoexec things

If the program needs more than the two librefs (a formats catalog, a lookup
libref, options), put those assignments in a small file and pass
`prelude=<path>.sas` — SQF %includes it right before your program, inside the
same captured log.

## Enterprise Guide specifics

- **All paths are SERVER paths.** Your `C:\...` is invisible to the SAS server.
  Put `sqf.sas`, the workbook, and the root folder on a share the server
  mounts, and use those paths in `%sqf_setup`.
- Forward slashes work on Windows and Unix servers alike — use them everywhere.
- Unix servers are case-sensitive: `/Shared/Data` and `/shared/data` differ.
- The workbook must be CLOSED in Excel when you run (the xlsx engine may not
  read a locked file); SQF falls back to PROC IMPORT and then tells you.
- Logs: SQF redirects the log per phase into `<run>/logs/*.log`. Your EG log
  window shows the orchestration between phases plus the summary box.
- If your shop schedules batch jobs: `onfail=ABORT` makes a failed scenario
  cancel the job stream instead of returning quietly.

## Deployment checklist (first day at work)

1. Copy to a server-visible folder: `sqf.sas`, `test/test_framework.sas`,
   `template/scenario_workbook.xlsx` (or `template/csv/*`),
   `examples/driver_example.sas`, `examples/custom_step_example.sas`.
2. Edit the single `%let SQF_HOME=` line in `test_framework.sas` → submit it.
   Expect `NOTE: [TEST] ALL nn ASSERTIONS PASSED`. This proves librefs,
   read-only enforcement, codegen, registry and audit on YOUR SAS build,
   using synthetic data only.
3. `%sqf_scan_program(main=...)` → apply Case A/B/C above.
4. Create the folder for `root=` and put the workbook somewhere server-visible.
5. Edit `driver_example.sas` paths; define a `BASELINE` scenario (plus
   `COPY_TABLE` rows if step 3 found in-place updates).
6. `%run_scenario(scenario=BASELINE, mode=VALIDATE)` → fix anything it flags.
7. `%run_scenario(scenario=BASELINE)` → PROC COMPARE the run's `outputs/`
   against a known production run of the same data. Identical outputs = the
   harness is wired correctly; every scenario after this is pure upside.
8. Build your first real what-if on the workbook and go.

## FAQ

**Where do my 25 input datasets come from?** Wherever they come from today —
SQF treats the folder you already pull them into as `base=` and never writes
to it. If today's process reads a database directly, add a small one-time
extract step that lands the tables in a folder, and point `base=` there.

**Can two people run scenarios at the same time?** Yes for different runs —
every run stages into its own folder. The central registry is best-effort
under concurrency (file locks on network shares are what they are);
`%rebuild_registry()` reconstructs it from the run folders at any time.

**How do I keep a run forever?** A run folder is self-contained (inputs,
outputs, generated code, logs, audit, control snapshot). Zip or archive the
folder; `%rebuild_registry()` after moving things.

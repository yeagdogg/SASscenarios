# SQF design notes

Why the framework is shaped the way it is, and the invariants that keep it safe.

## Invariants

1. **Base is inviolable.** Three independent layers: (a) `SQFBASE` is assigned
   `ACCESS=READONLY` and the run library concatenates the *libref* (not the raw
   path), so the read-only attribute travels into the concatenation; (b) no
   generated code ever names `SQFBASE` as an output; (c) optionally set the OS
   read-only bit on the base files. Update-opens that fall through to base fail
   loudly instead of corrupting anything (see COPY_TABLE in the user guide).
2. **Copy-on-write.** A run's `inputs/` holds only the tables its scenario
   modifies. Reads resolve staging-first through
   `LIBNAME INLIB ("<run>/inputs" SQFBASE)`; everything else falls through to
   base. Multi-GB tables that a scenario doesn't touch are never copied;
   staged copies are written with `COMPRESS=YES`.
3. **Per-run staging, rebuilt from base every run.** No shared scenario folder:
   reruns can't double-apply deltas, concurrent runs can't collide, failed-run
   debris survives for post-mortem, and each run folder is a complete,
   self-describing artifact.
4. **User text never enters the macro processor.** Cell text flows dataset →
   character scanner → PUT → generated open-code file. Parameters are
   substituted as literals at generation time by a quote-aware scanner; any
   surviving `&`/`%` outside single quotes is a validation error. The generated
   file is therefore 100% literal — reviewable, diffable, re-runnable — and the
   whole class of macro-quoting bugs is dissolved rather than managed.
   Framework macro calls in generated code (`%sqf_step_begin` etc.) carry only
   validated names and numbers.
5. **Validate before touching anything.** Static checks (structure, ids,
   schemas, key uniqueness, hygiene) then a generated dry run against obs=0
   WORK sandboxes with a log-scan gate. Failures name scenario/step/field.
   Nothing stages on failure.
6. **Fail fast, leave evidence, stay alive.** Each generated step is bracketed
   by begin/end macros checking `&SYSCC`; the first failure stops the include
   (`ABORT CANCEL FILE`, with an `OBS=0 NOREPLACE` belt behind it), marks the
   run FAILED with phase+step, and keeps all debris. The framework runs under
   `NOSYNTAXCHECK` (saved/restored) so one error can't flip a batch session
   into the silent OBS=0 death spiral that would corrupt every later run's
   bookkeeping.

## Codegen decisions worth remembering

- **SET_VALUES cannot use a WHERE statement** in the rewrite step (it would
  drop non-matching rows), and an IF guard rejects WHERE-only operators
  (LIKE/CONTAINS/BETWEEN/IS MISSING) while `<>`/`><` silently mean MAX/MIN in
  IF context. The scanner classifies each clause; IF-safe clauses take a fused
  single pass, WHERE-only clauses take an order-preserving split
  (tag `_sqf_seq_`, modify matched branch, interleave back). Misclassification
  degrades to the slower correct path, never to wrong data.
- **UPDATE_FROM is a hash lookup, not a MERGE**: preserves target row order,
  needs no sort, unmatched rows stay untouched by construction, and
  `duplicate:'e'` hard-fails duplicate source keys at runtime behind the
  static uniqueness check. Same-named non-key source columns update by name;
  mapping pairs add renames. Caveat: the source must fit in memory — huge
  sources belong in CUSTOM_CODE as a MERGE.
- **The first step per table fuses the base→staging copy** (reads SQFBASE,
  writes SQFIN) — no separate materialize pass, half the I/O. Later steps on
  the same table read and rewrite the staged copy in step order.
- **CUSTOM_CODE snippets are inlined** into apply.sas between provenance
  banners, never %included by reference: the audit artifact stays
  self-contained.
- **Inheritance is step-list flattening** (parent steps then child's,
  cycle-checked, ≤5 deep), not libname layering — one mechanism, and
  rebuild-per-run idempotency holds.

## Registry model

Source of truth = `run_info.sas7bdat` inside each run folder (written at end
of run). The central `registry/run_events.sas7bdat` is an append-only,
best-effort index (LOCK with retries; a lock failure warns and moves on) used
to resolve `RUN:` references to the latest COMPLETED run. `%rebuild_registry`
reconstructs the index by scanning run folders — the registry can always be
thrown away.

## Audit compare policy

PROC COMPARE is misleading after row counts change (alignment shifts make
everything "differ"), so the audit branches per modified table:

- row count/order preserved (only SET_VALUES / UPDATE_FROM / COPY_TABLE
  touched it) → full PROC COMPARE vs base;
- `key_vars` known → PROC COMPARE with ID after sorting copies;
- otherwise → row-count deltas plus side-by-side numeric summary stats only.

Plus per-step rows-affected, resolved parameters, the control snapshot, an
outputs inventory, the log-scan digest, and `report.html` per run.

## Known limits (v1) and the v2 list

- UPDATE_FROM's optional where_clause is IF-operators only (validated).
- The WHERE-operator classifier and the statement-token lint inspect the cell
  text with quoted literals masked; operator text smuggled in via a PARAMETER
  *value* (e.g. a value of `between 1 and 5`) evades them. The dry run still
  fails such constructs with a clear step id — the diagnostic is just less
  specific.
- Dry-run compiles but cannot execute CUSTOM_CODE / PREV: steps; PREV member
  existence AND schema checks run per iteration before staging, but a CUSTOM
  step's effect on downstream SCEN: readers is approximated with the base
  schema during dry runs.
- Schema checks for SCEN: sources approximate with the base ancestor's schema.
- CSV control files can't hold multi-line cells (the workbook can).
- Registry concurrency is best-effort (see above).
- Sandbox/dryrun table-name mangling uses the first 20 characters of member
  names — two targets identical through 20+ chars would collide in DRY RUN
  only (error surfaces there; rename one).

Deferred to v2: per-table `options=VIEW` zero-copy staging for very large
tables (needs its own safety validation: unsafe when the main program rewrites
inputs or uses POINT=); sample-based (obs≈50) execution dry-run;
`%purge_runs(keep_last=)`; audit report regeneration from stored datasets;
workbook DATA sheet for inline row entry; expression-valued mappings in
UPDATE_FROM; registry HTML dashboard; per-run ZIP archival.

## Why not …

- **… scenario columns appended to the base tables with an "active column"
  switch?** Pollutes pristine base data, can't express row inserts/deletes or
  table swaps, breaks on chained runs, and still needs rename machinery at run
  time.
- **… full per-scenario copies of all inputs?** Storage and time waste; the
  concatenated library gives the same isolation for only the changed tables.
- **… SQL views instead of staged copies?** Zero storage but recomputes per
  read, breaks when the main program rewrites inputs in place, and makes
  debugging a scenario's data much harder. Revisit as v2 opt-in for the
  biggest tables if staging ever feels slow.
- **… Python/pandas for the data manipulation?** Writing .sas7bdat reliably
  from Python isn't a thing; pure SAS runs wherever the SAS server is.

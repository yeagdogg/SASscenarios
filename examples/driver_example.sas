/*=====================================================================================
  SQF DRIVER - the file you actually open in Enterprise Guide and run.
  =====================================================================================
  1. Edit the four paths below (ALL of them as the SAS SERVER sees them - in EG,
     "C:\..." on your PC is NOT visible to the server; use the server/share path).
  2. Submit the whole file once per scenario run.

  First time? Run test/test_framework.sas first - it proves the framework on your
  SAS installation without touching any real data.
=====================================================================================*/

/* ---- one-time per session ---- */
%include "/shared/actuarial/sqf/sqf.sas";            /* the framework            */

%sqf_setup(
    root    = /shared/actuarial/sqf_runs,            /* scenario/run folders land here   */
    base    = /shared/actuarial/prod_inputs,         /* your 25 pristine input datasets  */
    control = /shared/actuarial/sqf/scenario_workbook.xlsx,
    main    = /shared/actuarial/prod/main_process.sas,
    inlib   = INLIB,                                 /* libref your program READS        */
    outlib  = OUTLIB                                 /* libref your program WRITES       */
);

/* ---- not sure how your program refers to its inputs? run this once ---- */
/* %sqf_scan_program(main=/shared/actuarial/prod/main_process.sas)         */

/* ---- sanity-check a scenario without running anything ---- */
/* %run_scenario(scenario=RATEUP, mode=VALIDATE)                           */

/* ---- stage the modified inputs but skip the main program ---- */
/* %run_scenario(scenario=RATEUP, mode=APPLYONLY)                          */

/* ---- the real thing ---- */
%run_scenario(scenario=RATEUP)

/* ---- afterwards ----
   &SQF_LAST_RUN_DIR points at the run folder:
       inputs/   the staged (modified) copies - only tables the scenario touched
       outputs/  what your program produced
       gen/      the exact generated code that transformed the inputs
       logs/     validate / dryrun / apply / main / audit logs
       audit/    audit datasets + report.html
   INLIB / OUTLIB stay assigned so you can browse the run in EG right away.  */

/* ---- other things you will use ----

   Run every active scenario:
       %run_all()

   A 5-year feed-forward projection (steps with PREV: pull from the
   previous iteration's outputs):
       %run_chain(scenario=PROJ5, iterations=5)

   Compare two runs' outputs (paths or run ids):
       %compare_runs(run1=&SQF_LAST_RUN_DIR, run2=<earlier run folder>)

   Rebuild the run index if the registry ever looks stale:
       %rebuild_registry()
*/

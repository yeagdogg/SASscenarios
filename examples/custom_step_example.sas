/*=====================================================================================
  CUSTOM_CODE example snippet
  =====================================================================================
  Place snippets under <root>/custom/ and reference them from the STEPS sheet:
      method = CUSTOM_CODE,  source = rescale_reserves.sas

  The framework INLINES this file into the generated apply program, so what ran is
  always visible in <run>/gen/apply.sas.

  Contract - these macro variables are set for you before the snippet runs:
      &SQF_SCENLIB   libref of this run's staged input copies (write here!)
      &SQF_BASELIB   read-only libref of the pristine base tables
      &SQF_RUNDIR    this run's folder
      &SQF_ITER      iteration number (1 outside %run_chain)
      &SQF_SCENARIO  scenario id       &SQF_RUN_ID   run id
      ...plus every row of the PARAMETERS sheet as &NAME

  Rules of the road:
      * Read from &SQF_BASELIB or &SQF_SCENLIB, write ONLY to &SQF_SCENLIB.
      * If the table was not touched by an earlier step, put a COPY_TABLE step
        before this one (or read &SQF_BASELIB and write &SQF_SCENLIB yourself).
      * Never write to &SQF_BASELIB - it is read-only and that is the point.
=====================================================================================*/

/* Example: rescale reserves by a parameter, floor at zero, and log a count */
data &SQF_SCENLIB..reserves;
    set &SQF_SCENLIB..reserves;      /* staged by an earlier COPY_TABLE step */
    reserve_amt = max(0, reserve_amt * &RESERVE_SCALE);
run;

proc sql noprint;
    select count(*) into :_n_rescaled trimmed from &SQF_SCENLIB..reserves;
quit;
%put NOTE: [CUSTOM] rescaled &_n_rescaled reserve rows by &RESERVE_SCALE (scenario &SQF_SCENARIO, iteration &SQF_ITER);

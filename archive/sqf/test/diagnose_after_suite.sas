/*=====================================================================================
  SQF DIAGNOSTIC - submit in the SAME SAS session, immediately after
  test_framework.sas finishes. Photograph / save everything it prints.
=====================================================================================*/

title "DIAG 1: failed assertions (the bracket text is the diagnostic)";
proc print data=work.t_results noobs;
    where pass = 0;
run;
title;

%put DIAG: TROOT  = &TROOT;
%put DIAG: TCHDIR = &TCHDIR;
%put DIAG: LASTRUN= &SQF_LAST_RUN_DIR;

/* what is ACTUALLY on disk in and under the chain run folder */
%macro diag_ls(path);
%put DIAG: ---------- listing: &path;
data _null_;
    length nm $256;
    rc = filename('_dg', "&path");
    did = dopen('_dg');
    if did <= 0 then put 'DIAG:    (FOLDER DOES NOT EXIST)';
    else do;
        if dnum(did) = 0 then put 'DIAG:    (empty folder)';
        do i = 1 to dnum(did);
            nm = dread(did, i);
            put 'DIAG:    ' nm;
        end;
        rc = dclose(did);
    end;
    rc = filename('_dg');
run;
%mend diag_ls;

%diag_ls(&TCHDIR)
%diag_ls(&TCHDIR/iter_01)
%diag_ls(&TCHDIR/iter_03)

/* what the framework RECORDED as the iteration folders */
libname _dgm "&TCHDIR" access=readonly;
title "DIAG 2: chain manifest - recorded iteration folders";
proc print data=_dgm.chain_manifest noobs; run;
title;
libname _dgm clear;

/* the registry's view of the last few runs */
title "DIAG 3: last 10 registry events";
proc sql outobs=10;
    select event_dt, scenario, event, run_dir
    from SQFREG.run_events
    order by event_dt desc;
quit;
title;

/* dump the notable lines of a run's captured (hidden) log to the
   console log, where a photo can catch them                            */
%macro diag_logdump(log=, tag=);
%if %sysfunc(fileexist(&log)) %then %do;
data _null_;
    infile "&log" lrecl=32767 truncover;
    input;
    length _u $32767;
    _u = upcase(_infile_);
    if _u =: 'ERROR' or _u =: 'WARNING'
       or index(_u, 'STOP EXECUTING') > 0
       or index(_u, 'UNIQUENESS CHECK') > 0
       or index(_u, 'APPARENT') > 0 then
        put "&tag " _infile_;
run;
%end;
%else %put &tag (log not found: &log);
%mend diag_logdump;

/* T17: revalidate the CSV scenario and show the exact findings */
%run_scenario(scenario=CSVAGE, control=&TROOT/csv, mode=VALIDATE, html=N)
title "DIAG 4: CSVAGE validation findings (why T17 refused to run)";
proc print data=work._sqf_verrors noobs; run;
title "DIAG 5: what the CSV loader actually parsed";
proc print data=work._sqf_scenarios noobs; run;
proc print data=work._sqf_steps noobs; run;
title;
%diag_logdump(log=&SQF_LAST_RUN_DIR/logs/load.log,     tag=DIAG-CSV-LOAD:)
%diag_logdump(log=&SQF_LAST_RUN_DIR/logs/validate.log, tag=DIAG-CSV-VAL:)
%diag_logdump(log=&SQF_LAST_RUN_DIR/logs/dryrun.log,   tag=DIAG-CSV-DRY:)

/* T14e: revalidate BADDUP standalone and expose the hidden logs */
data work.ctl_scenarios;
    length scenario_id $32 description $256 parent_scenario $32 active $1 notes $500;
    call missing(of _all_);
    scenario_id = 'BADDUP'; active = 'Y'; output;
run;
data work.ctl_steps;
    length scenario_id $32 step_no 8 active $1 method $16 target_table $32
           where_clause $4000 key_vars $500 source $500 assignments $8000
           options $200 notes $500;
    call missing(of _all_);
    scenario_id = 'BADDUP'; step_no = 10; active = 'Y';
    method = 'UPDATE_FROM'; target_table = 'RATES';
    key_vars = 'REGION RATE_YEAR'; source = 'BASE:DUPSRC';
    assignments = 'rate_change=rate_new';
    output;
run;
data work.ctl_parameters;
    length name $32 value $2000 scenario_id $32 notes $500;
    call missing(of _all_);
    stop;
run;
%run_scenario(scenario=BADDUP, mode=VALIDATE, html=N)
title "DIAG 6: BADDUP standalone validation findings (expect a duplicate-keys error)";
proc print data=work._sqf_verrors noobs; run;
title;
%diag_logdump(log=&SQF_LAST_RUN_DIR/logs/validate.log, tag=DIAG-DUP-VAL:)
%diag_logdump(log=&SQF_LAST_RUN_DIR/logs/dryrun.log,   tag=DIAG-DUP-DRY:)

%put DIAG: done - send a photo of the printed output plus every DIAG line in the log.;

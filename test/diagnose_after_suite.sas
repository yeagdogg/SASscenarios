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

%put DIAG: done - send a photo of the printed output plus any DIAG: lines in the log.;

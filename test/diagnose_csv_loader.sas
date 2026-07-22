/*=====================================================================================
  SQF CSV-LOADER PROBE (for the T17 failure)
  Run in the SAME session as test_framework.sas (it reuses &TROOT and the
  CSV files the suite wrote). Unlike a real run, NOTHING here redirects the
  log - whatever has been silently killing the CSV loader will print its
  ERROR right in the console log. Photograph all red lines + the tables.
=====================================================================================*/

%put PROBE: TROOT = &TROOT;
%put PROBE: csv folder should hold scenarios/steps/parameters.csv:;

data _null_;
    length nm $256;
    rc = filename('_pb', "&TROOT/csv");
    did = dopen('_pb');
    if did <= 0 then put 'PROBE:   (csv folder does not exist!)';
    else do;
        do i = 1 to dnum(did);
            nm = dread(did, i);
            put 'PROBE:   ' nm;
        end;
        rc = dclose(did);
    end;
    rc = filename('_pb');
run;

/* the raw file exactly as SAS reads it (first line hex-dumped: BOM etc) */
data _null_;
    infile "&TROOT/csv/scenarios.csv" lrecl=32767 truncover;
    input;
    if _n_ = 1 then put 'PROBE-HEX1: ' _infile_ $hex64.;
    put 'PROBE-RAW' _n_ ': ' _infile_;
    if _n_ >= 3 then stop;
run;

/* fresh findings store, then the loader - UNCAPTURED, BOTH branches */
data work._sqf_verrors;
    length sev $1 scenario $32 step 8 field $32 message $500;
    call missing(of _all_);
    stop;
run;

%put PROBE: ---- calling sqf_load_control (control_type=CSV, no log redirection) ----;
%sqf_load_control(control=&TROOT/csv, control_type=CSV)
%put PROBE: ---- returned from control_type=CSV call ----;

%put PROBE: ---- calling sqf_load_control (control_type=AUTO, the suite route) ----;
%sqf_load_control(control=&TROOT/csv, control_type=AUTO)
%put PROBE: ---- returned from control_type=AUTO call ----;

%macro probe_print(ds);
%if %sysfunc(exist(&ds)) %then %do;
    title "PROBE: &ds";
    proc print data=&ds noobs; run;
    title;
%end;
%else %put PROBE: &ds DOES NOT EXIST;
%mend probe_print;

%probe_print(work._sqf_raw_scenarios)
%probe_print(work._sqf_scenarios)
%probe_print(work._sqf_raw_steps)
%probe_print(work._sqf_steps)
%probe_print(work._sqf_raw_parameters)
%probe_print(work._sqf_parameters)
%probe_print(work._sqf_verrors)

%put PROBE: done. The first red ERROR above (plus any "will stop executing" line) is the answer.;
%put PROBE: the DOES-NOT-EXIST pattern shows exactly where the loader died:;
%put PROBE:   raw_scenarios missing        = died inside sqf_load_csv_sheet(scenarios);
%put PROBE:   raw ok but _sqf_scenarios missing = died in sqf_type_sheet / sqf_clean_sheet;
%put PROBE:   scenarios ok but raw_steps missing = died between the sheets;

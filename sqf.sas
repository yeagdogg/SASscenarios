/*=====================================================================================
  SQF -- SAS What-If Scenario Framework
  =====================================================================================
  One-file framework for running arbitrary what-if scenarios against a production
  SAS process WITHOUT modifying the pristine base data and WITHOUT copying every
  input table per scenario.

  Core ideas
    * Copy-on-write: each run stages ONLY the tables its scenario modifies into
      <run>/inputs; the main program reads through a concatenated libname
      (staging first, read-only base second), so untouched tables fall through.
    * Scenarios are defined declaratively in an Excel workbook (or CSVs, or plain
      SAS datasets): SCENARIOS / STEPS / PARAMETERS.
    * The framework VALIDATES everything, then GENERATES a fully literal
      gen/apply.sas (no macro triggers from user text survive into it) and
      %includes it. The generated file is the audit artifact.
    * Every run leaves a self-describing folder: inputs, outputs, generated code,
      logs, audit datasets + HTML report, control snapshot, run_info dataset.

  Public API (see docs/USER_GUIDE.md):
    %sqf_setup(root=, base=, control=, main=)
    %run_scenario(scenario=)          %run_chain(scenario=, iterations=)
    %run_all()                        %compare_runs(run1=, run2=)
    %rebuild_registry()               %sqf_make_template(dir=)
    %sqf_scan_program(main=)

  Requirements: Base SAS 9.4. SAS/ACCESS to PC Files only for XLSX control files
  (CSV and DATASET control modes need Base only). No X commands are used (NOXCMD
  safe). Works in PC SAS, Enterprise Guide (code runs on the server -- all paths
  are as the SAS server sees them), and batch.

  Version 1.0.0
=====================================================================================*/

%put NOTE: [SQF] Loading SAS What-If Scenario Framework...;

/*------------------------------------------------------------------
  00. GLOBALS AND DEFAULTS
------------------------------------------------------------------*/
%global
    SQF_VERSION        /* framework version                                   */
    SQF_ROOT           /* root folder for scenarios/registry (server path)    */
    SQF_BASE           /* folder holding the pristine base .sas7bdat files    */
    SQF_CONTROL        /* default control source (xlsx file | csv folder)     */
    SQF_MAIN           /* default path to the main production program         */
    SQF_INLIB          /* libref name the main program reads inputs from      */
    SQF_OUTLIB         /* libref name the main program writes outputs to      */
    SQF_LAST_RUN_ID    /* set by %run_scenario / %run_chain                   */
    SQF_LAST_STATUS    /* COMPLETED | FAILED | VALIDATION_FAILED              */
    SQF_LAST_RUN_DIR   /* full path of the last run folder                    */
    SQF_STOP           /* internal: 1 => generated apply code must stop       */
    SQF_FAIL_PHASE     /* internal: phase of first failure                    */
    SQF_FAIL_STEP      /* internal: step_no of first failure                  */
    SQF_RC             /* internal: last utility return code                  */
    SQF_CONTROL_HASH   /* internal: fingerprint of the loaded control         */
    SQF_DEBUG          /* Y => keep intermediate _sqf_ WORK datasets          */
    /* CUSTOM_CODE contract variables (documented, user-facing)               */
    SQF_SCENLIB SQF_BASELIB SQF_RUNDIR SQF_ITER SQF_SCENARIO SQF_RUN_ID
    ;

%let SQF_VERSION  = 1.0.0;
%let SQF_STOP     = 0;
%let SQF_DEBUG    = %sysfunc(coalescec(&SQF_DEBUG, N));
%let SQF_INLIB    = %sysfunc(coalescec(&SQF_INLIB, INLIB));
%let SQF_OUTLIB   = %sysfunc(coalescec(&SQF_OUTLIB, OUTLIB));
/*------------------------------------------------------------------
  01. UTILITIES
------------------------------------------------------------------*/

/* Normalize a path: backslashes -> forward slashes, strip trailing slash.
   Forward slashes are valid on Windows SAS, Unix SAS, and UNC paths.      */
%macro sqf_norm_path(p);
%local _p;
%let _p = %superq(p);
%if %length(&_p) > 0 %then %do;   /* blank in -> blank out, no fn calls */
    %let _p = %sysfunc(translate(&_p, /, \));
    %if %length(&_p) > 1 %then %do;
        /* both operands quoted: a bare / in an %IF is the DIVISION operator */
        %if "%qsubstr(&_p, %length(&_p), 1)" = "/" %then
            %let _p = %qsubstr(&_p, 1, %eval(%length(&_p)-1));
    %end;
%end;
&_p.
%mend sqf_norm_path;

/* Recursive directory create via DCREATE (no X commands; NOXCMD safe).
   Sets SQF_RC = 0 on success (or already exists), 1 on failure.          */
%macro sqf_mkdir(path);
%local _p _n _i _seg _cur _unc _parent _pl;
%let SQF_RC = 0;
%let _p = %sqf_norm_path(&path);
%if %length(&_p) = 0 %then %do;
    %put ERROR: [SQF] sqf_mkdir called with a blank path.;
    %let SQF_RC = 1;
    %return;
%end;
%if %sysfunc(fileexist(&_p)) %then %return;
%let _unc = 0;
%if %length(&_p) > 2 %then %if "%qsubstr(&_p, 1, 2)" = "//" %then %let _unc = 1;
%let _n = %sysfunc(countw(&_p, /));
%let _cur = ;
%do _i = 1 %to &_n;
    %let _seg = %qscan(&_p, &_i, /);
    %if &_i = 1 %then %do;
        %if &_unc = 1 %then %let _cur = //&_seg;
        %else %if "%qsubstr(&_p, 1, 1)" = "/" %then %let _cur = /&_seg;
        %else %let _cur = &_seg;
    %end;
    %else %let _cur = &_cur/&_seg;
    /* server and share of a UNC path cannot be created -- skip them */
    %if not (&_unc = 1 and &_i <= 2) %then %do;
        %if not %sysfunc(fileexist(&_cur)) %then %do;
            %let _pl = %eval(%length(&_cur) - %length(&_seg) - 1);
            %if &_pl < 1 %then %let _parent = .;
            %else %let _parent = %qsubstr(&_cur, 1, &_pl);
            %let _seg = %sysfunc(dcreate(&_seg, &_parent));
            %if not %sysfunc(fileexist(&_cur)) %then %do;
                %put ERROR: [SQF] Could not create directory: &_cur;
                %let SQF_RC = 1;
                %return;
            %end;
        %end;
    %end;
%end;
%if not %sysfunc(fileexist(&_p)) %then %do;
    %put ERROR: [SQF] Could not create directory: &_p;
    %let SQF_RC = 1;
%end;
%mend sqf_mkdir;

/* Binary-safe file copy (used to snapshot the control workbook).
   Sets SQF_RC = 0/1.                                                      */
%macro sqf_copy_file(from=, to=);
%local _f _t _rc;
%let SQF_RC = 1;
%let _rc = %sysfunc(filename(_f, %sqf_norm_path(&from), disk, recfm=n));
%let _rc = %sysfunc(filename(_t, %sqf_norm_path(&to),   disk, recfm=n));
%if %sysfunc(fexist(&_f)) %then %do;
    %if %sysfunc(fcopy(&_f, &_t)) = 0 %then %let SQF_RC = 0;
%end;
%let _rc = %sysfunc(filename(_f));
%let _rc = %sysfunc(filename(_t));
%if &SQF_RC ne 0 %then %put WARNING: [SQF] Could not copy &from to &to;
%mend sqf_copy_file;

/* Timestamp helpers */
%macro sqf_now();
%sysfunc(strip(%sysfunc(datetime(), datetime20.)))
%mend sqf_now;

%macro sqf_gen_runid();
%local _dt;
%let _dt = %sysfunc(datetime());
run_%sysfunc(datepart(&_dt), yymmddn8.)T%sysfunc(compress(%sysfunc(timepart(&_dt), tod8.), :))
%mend sqf_gen_runid;

/* Save / restore the session options we override. Restore is uncondi-
   tionally called by the orchestrator exit path.                          */
%macro sqf_opts_save();
%global SQF_OPT_OBS SQF_OPT_REPLACE SQF_OPT_SYNTAX SQF_OPT_COMPRESS SQF_OPT_SYSCC;
%let SQF_OPT_OBS      = %sysfunc(getoption(obs));
%let SQF_OPT_REPLACE  = %sysfunc(getoption(replace));
%let SQF_OPT_SYNTAX   = %sysfunc(getoption(syntaxcheck));
%let SQF_OPT_COMPRESS = %sysfunc(getoption(compress));
%let SQF_OPT_SYSCC    = &syscc;
/* survive prior session damage + prevent the batch obs=0 death spiral */
options obs=max replace nosyntaxcheck compress=yes;
%let syscc = 0;
%mend sqf_opts_save;

%macro sqf_opts_restore();
%if %symexist(SQF_OPT_OBS) %then %do;
    %if %length(&SQF_OPT_OBS) > 0 %then %do;
        options obs=&SQF_OPT_OBS &SQF_OPT_REPLACE &SQF_OPT_SYNTAX compress=&SQF_OPT_COMPRESS;
    %end;
%end;
%mend sqf_opts_restore;

/* Route the SAS log to a file / back to default */
%macro sqf_printto(log=);
proc printto log="%sqf_norm_path(&log)" new; run;
%mend sqf_printto;

%macro sqf_printto_off();
proc printto; run;
%mend sqf_printto_off;

/* Scan a captured log file. Appends one row per notable line to &out
   (created if missing) and sets SQF_SCAN_NERR / SQF_SCAN_NWARN.
   Notable = ERROR lines, WARNING lines, suspicious NOTEs. Lines are
   attributed to the last seen "[SQF] STEP n" marker.                      */
%macro sqf_log_scan(log=, phase=, out=work._sqf_logscan);
%global SQF_SCAN_NERR SQF_SCAN_NWARN;
%let SQF_SCAN_NERR  = 0;
%let SQF_SCAN_NWARN = 0;
%if not %sysfunc(fileexist(%sqf_norm_path(&log))) %then %do;
    %put WARNING: [SQF] Log file not found for scanning: &log;
    %return;
%end;
data work._sqf_scan_new;
    length phase $12 sev $1 step 8 line_no 8 text $256 _u $32767;
    retain phase "&phase" step .;
    infile "%sqf_norm_path(&log)" lrecl=32767 truncover;
    input;
    line_no = _n_;
    _u = upcase(_infile_);
    /* track step markers emitted by generated code */
    _m = index(_u, '[SQF] STEP ');
    if _m > 0 then do;
        _s = input(scan(substr(_u, _m + 11), 1, ' '), ?? best32.);
        if not missing(_s) then step = _s;
    end;
    sev = ' ';
    if prxmatch('/^ERROR(:|\s|\d|-)/', _u) then sev = 'E';
    else if prxmatch('/^WARNING(:|\s|\d|-)/', _u) then do;
        /* skip licensing chatter */
        if index(_u, 'EXPIRE') = 0 and index(_u, 'LICENS') = 0 then sev = 'W';
    end;
    else if _u =: 'NOTE:' then do;
        if index(_u, 'UNINITIALIZED')                     > 0 or
           index(_u, 'INVALID DATA')                      > 0 or
           index(_u, 'INVALID ARGUMENT')                  > 0 or
           index(_u, 'INVALID NUMERIC DATA')              > 0 or
           index(_u, 'CONVERTED TO NUMERIC')              > 0 or
           index(_u, 'CONVERTED TO CHARACTER')            > 0 or
           index(_u, 'DIVISION BY ZERO')                  > 0 or
           index(_u, 'MATHEMATICAL OPERATIONS COULD NOT') > 0 or
           index(_u, 'MISSING VALUES WERE GENERATED')     > 0 or
           index(_u, 'REPEATS OF BY VALUES')              > 0 or
           index(_u, 'MERGE STATEMENT HAS MORE THAN ONE') > 0 or
           index(_u, 'LOST CARD')                         > 0 or
           index(_u, 'SAS WENT TO A NEW LINE')            > 0 or
           index(_u, 'W.D FORMAT')                        > 0 or
           index(_u, 'APPARENT SYMBOLIC REFERENCE')       > 0 or
           index(_u, 'APPARENT INVOCATION')               > 0 then sev = 'N';
    end;
    if sev ne ' ' then do;
        text = substr(_infile_, 1, min(length(_infile_), 256));
        output;
    end;
    keep phase sev step line_no text;
run;
proc sql noprint;
    select coalesce(sum(sev='E'),0), coalesce(sum(sev in ('W','N')),0)
        into :SQF_SCAN_NERR trimmed, :SQF_SCAN_NWARN trimmed
        from work._sqf_scan_new;
quit;
proc append base=&out data=work._sqf_scan_new; run;
proc datasets lib=work nolist nowarn; delete _sqf_scan_new; quit;
%mend sqf_log_scan;

/* Content fingerprint of the loaded control datasets: chained MD5 over a
   canonical dump with explicit columns (schemas fixed by the loader).     */
%macro sqf_hash_control();
%let SQF_CONTROL_HASH = ;
data _null_;
    length _h $32 _line $16000;
    retain _h '0';
    set work._sqf_scenarios (in=_a)
        work._sqf_steps     (in=_b)
        work._sqf_parameters(in=_c) end=_eof;
    if _a then
        _line = catx('|', 'S', scenario_id, description, parent_scenario, active, notes);
    else if _b then
        _line = catx('|', 'T', scenario_id, put(step_no, best32.), active, method,
                          target_table, where_clause, key_vars, source,
                          substr(assignments, 1, 8000), options, notes);
    else
        _line = catx('|', 'P', name, value, scenario_id, notes);
    _h = put(md5(catx('~', _h, _line)), $hex32.);
    if _eof then call symputx('SQF_CONTROL_HASH', _h, 'G');
run;
%if %length(&SQF_CONTROL_HASH) = 0 %then %let SQF_CONTROL_HASH = EMPTY;
%mend sqf_hash_control;

/* Drop framework work datasets between runs */
%macro sqf_clean_work();
%if &SQF_DEBUG ne Y %then %do;
    proc datasets lib=work nolist nowarn memtype=(data view);
        delete _sqf_: ;
    quit;
%end;
%mend sqf_clean_work;

/* Observation count -> macro var named by mvar (caller %locals it) */
%macro sqf_nobs(ds=, mvar=);
%local _id _rc;
%let &mvar = .;
%let _id = %sysfunc(open(&ds));
%if &_id > 0 %then %do;
    %let &mvar = %sysfunc(attrn(&_id, nlobs));
    %if &&&mvar = -1 %then %do;
        /* views / where-subsets: count the hard way */
        %let &mvar = 0;
        %do %while(%sysfunc(fetch(&_id)) = 0);
            %let &mvar = %eval(&&&mvar + 1);
        %end;
    %end;
    %let _rc = %sysfunc(close(&_id));
%end;
%mend sqf_nobs;

/* Space-separated variable list of a dataset -> &mvar */
%macro sqf_varlist(ds=, mvar=);
%local _id _rc _i;
%let &mvar = ;
%let _id = %sysfunc(open(&ds));
%if &_id > 0 %then %do;
    %do _i = 1 %to %sysfunc(attrn(&_id, nvars));
        %let &mvar = &&&mvar %sysfunc(varname(&_id, &_i));
    %end;
    %let _rc = %sysfunc(close(&_id));
%end;
%mend sqf_varlist;

/* Variable type (C/N, blank if absent) -> &mvar */
%macro sqf_vartype(ds=, var=, mvar=);
%local _id _rc _n;
%let &mvar = ;
%let _id = %sysfunc(open(&ds));
%if &_id > 0 %then %do;
    %let _n = %sysfunc(varnum(&_id, &var));
    %if &_n > 0 %then %let &mvar = %sysfunc(vartype(&_id, &_n));
    %let _rc = %sysfunc(close(&_id));
%end;
%mend sqf_vartype;

/* Record one validation finding. Message text is passed OUT OF BAND via
   the global SQF_VMSG (set with %let just before the call) so commas,
   quotes and parentheses in messages can never break the macro call.      */
%macro sqf_verr(sev=E, scen=, step=., field=);
%global SQF_VMSG;
data work._sqf_verr_new;
    length sev $1 scenario $32 step 8 field $32 message $500;
    sev = "&sev"; scenario = "&scen"; step = &step; field = "&field";
    message = symget('SQF_VMSG');
run;
proc append base=work._sqf_verrors data=work._sqf_verr_new; run;
proc datasets lib=work nolist nowarn; delete _sqf_verr_new; quit;
%mend sqf_verr;
/*------------------------------------------------------------------
  02. CONTROL LOADER
      Sources: XLSX workbook | folder of CSVs | SAS datasets.
      All paths land in work._sqf_scenarios / _sqf_steps /
      _sqf_parameters with FIXED schemas:

      _sqf_scenarios : scenario_id $32  description $256
                       parent_scenario $32  active $1  notes $500
      _sqf_steps     : scenario_id $32  step_no 8  active $1
                       method $16  target_table $32  where_clause $4000
                       key_vars $500  source $500  assignments $8000
                       options $200  notes $500
      _sqf_parameters: name $32  value $2000  scenario_id $32  notes $500
------------------------------------------------------------------*/

/* Per-sheet expected column metadata (parallel space-separated lists).
   Sets _cols/_typs/_lens/_reqs in the CALLER's scope.                  */
%macro sqf_sheet_meta(sheet);
%if &sheet = SCENARIOS %then %do;
    %let _cols = SCENARIO_ID DESCRIPTION PARENT_SCENARIO ACTIVE NOTES;
    %let _typs = C C C C C;
    %let _lens = 32 256 32 1 500;
    %let _reqs = Y N N N N;
%end;
%else %if &sheet = STEPS %then %do;
    %let _cols = SCENARIO_ID STEP_NO ACTIVE METHOD TARGET_TABLE WHERE_CLAUSE KEY_VARS SOURCE ASSIGNMENTS OPTIONS NOTES;
    %let _typs = C N C C C C C C C C C;
    %let _lens = 32 8 1 16 32 4000 500 500 8000 200 500;
    %let _reqs = Y Y N Y Y N N N N N N;
%end;
%else %do;
    %let _cols = NAME VALUE SCENARIO_ID NOTES;
    %let _typs = C C C C;
    %let _lens = 32 2000 32 500;
    %let _reqs = Y Y N N;
%end;
%mend sqf_sheet_meta;

/* Create an empty dataset with the fixed schema for a sheet            */
%macro sqf_empty_sheet(out=, sheet=);
%local _cols _typs _lens _reqs _i _c;
%sqf_sheet_meta(&sheet)
data &out;
    length
    %do _i = 1 %to %sysfunc(countw(&_cols));
        %let _c = %scan(&_cols, &_i);
        &_c
        %if %scan(&_typs, &_i) = C %then $%scan(&_lens, &_i);
        %else 8;
    %end;
    ;
    call missing(of _all_);
    stop;
run;
%mend sqf_empty_sheet;

/* Coerce a raw sheet into the fixed schema, whatever types arrived.
   Absent optional columns are created blank (with a W finding);
   absent required columns are an E finding.                            */
%macro sqf_type_sheet(raw=, out=, sheet=);
%local _cols _typs _lens _reqs _i _c _t _l _r _id _rc _vn _vt _ren _asn _n;
%sqf_sheet_meta(&sheet)
%let _n = %sysfunc(countw(&_cols));
%let _id = 0;
%if %sysfunc(exist(&raw)) %then %let _id = %sysfunc(open(&raw));
%if &_id <= 0 %then %do;
    %sqf_empty_sheet(out=&out, sheet=&sheet)
    %return;
%end;
%let _ren = ;
%let _asn = ;
%do _i = 1 %to &_n;
    %let _c = %scan(&_cols, &_i);
    %let _t = %scan(&_typs, &_i);
    %let _l = %scan(&_lens, &_i);
    %let _r = %scan(&_reqs, &_i);
    %let _vn = %sysfunc(varnum(&_id, &_c));
    %if &_vn > 0 %then %do;
        %let _vt = %sysfunc(vartype(&_id, &_vn));
        %let _ren = &_ren &_c = _r_&_c;
        %if &_t = C and &_vt = C %then %let _asn = &_asn &_c = strip(_r_&_c)%str(;);
        %else %if &_t = C and &_vt = N %then
            /* numeric-typed cells (incl. dates): keep what the user SAW.
               A missing numeric must become BLANK, not the literal dot -
               the xlsx engine types entirely-empty columns numeric, and
               a '.' in a where/source cell would wreak havoc            */
            %let _asn = &_asn &_c = ifc(missing(_r_&_c), ' ', strip(vvalue(_r_&_c)))%str(;);
        %else %if &_t = N and &_vt = N %then %let _asn = &_asn &_c = _r_&_c%str(;);
        %else %let _asn = &_asn &_c = input(strip(_r_&_c), ?? best32.)%str(;);
    %end;
    %else %do;
        %if &_t = C %then %let _asn = &_asn &_c = ' '%str(;);
        %else %let _asn = &_asn &_c = .%str(;);
        %if &_r = Y %then %do;
            %let SQF_VMSG = Sheet &sheet is missing required column &_c (was it renamed or deleted?).;
            %sqf_verr(sev=E, scen=, field=&_c)
        %end;
        %else %do;
            %let SQF_VMSG = Sheet &sheet has no column &_c%str(;) treating it as all blank.;
            %sqf_verr(sev=W, scen=, field=&_c)
        %end;
    %end;
%end;
%let _rc = %sysfunc(close(&_id));
data &out;
    length
    %do _i = 1 %to &_n;
        %let _c = %scan(&_cols, &_i);
        &_c
        %if %scan(&_typs, &_i) = C %then $%scan(&_lens, &_i);
        %else 8;
    %end;
    ;
    set &raw
    %if %length(&_ren) > 0 %then (rename=(&_ren));
    ;
    &_asn;
    keep
    %do _i = 1 %to &_n;
        %scan(&_cols, &_i)
    %end;
    ;
run;
%mend sqf_type_sheet;

/* Shared cell cleanup: Excel smart characters -> ASCII, control chars
   -> spaces, ghost-row removal, structural-field upcasing.             */
%macro sqf_clean_sheet(ds=, sheet=);
data &ds;
    set &ds;
    array _sqf_txt {*} _character_;
    do _sqf_i = 1 to dim(_sqf_txt);
        /* tabs / CR / LF inside cells -> spaces (a newline inside a
           multi-line Excel cell would otherwise break generated code) */
        _sqf_txt{_sqf_i} = translate(_sqf_txt{_sqf_i}, '202020'x, '090D0A'x);
        /* utf-8 smart quotes / dashes / nbsp -> ASCII. MUST run before
           the single-byte pass: in a UTF-8 session the cp1252 translate
           would otherwise chew the 93/94/A0 bytes inside these multi-
           byte sequences and corrupt the cell                          */
        _sqf_txt{_sqf_i} = tranwrd(_sqf_txt{_sqf_i}, 'E28098'x, '27'x);
        _sqf_txt{_sqf_i} = tranwrd(_sqf_txt{_sqf_i}, 'E28099'x, '27'x);
        _sqf_txt{_sqf_i} = tranwrd(_sqf_txt{_sqf_i}, 'E2809C'x, '22'x);
        _sqf_txt{_sqf_i} = tranwrd(_sqf_txt{_sqf_i}, 'E2809D'x, '22'x);
        _sqf_txt{_sqf_i} = tranwrd(_sqf_txt{_sqf_i}, 'E28093'x, '2D'x);
        _sqf_txt{_sqf_i} = tranwrd(_sqf_txt{_sqf_i}, 'E28094'x, '2D'x);
        _sqf_txt{_sqf_i} = tranwrd(_sqf_txt{_sqf_i}, 'C2A0'x,   '20'x);
        /* cp1252 smart quotes / dashes / nbsp -> ASCII (wlatin1 sessions) */
        _sqf_txt{_sqf_i} = translate(_sqf_txt{_sqf_i}, '272722222D2D20'x, '919293949697A0'x);
        _sqf_txt{_sqf_i} = strip(_sqf_txt{_sqf_i});
    end;
    drop _sqf_i;
%if &sheet = SCENARIOS %then %do;
    if missing(scenario_id) then delete;              /* ghost rows */
    scenario_id     = upcase(scenario_id);
    parent_scenario = upcase(parent_scenario);
    active          = upcase(active);
    if active = ' ' then active = 'Y';
%end;
%else %if &sheet = STEPS %then %do;
    if missing(scenario_id) and missing(method) and missing(target_table)
       and missing(step_no) then delete;              /* ghost rows */
    scenario_id  = upcase(scenario_id);
    method       = upcase(compress(method, '_', 'kad'));
    target_table = upcase(target_table);
    key_vars     = upcase(compbl(key_vars));
    options      = upcase(compbl(options));
    active       = upcase(active);
    if active = ' ' then active = 'Y';
    /* sources with a recognized prefix are structural -> upcase them;
       anything else (CUSTOM_CODE snippet path) keeps its case          */
    if upcase(source) =: 'BASE:' or upcase(source) =: 'SCEN:' or
       upcase(source) =: 'RUN:'  or upcase(source) =: 'PREV:'
        then source = upcase(source);
%end;
%else %do;
    if missing(name) then delete;                     /* ghost rows */
    name        = upcase(name);
    scenario_id = upcase(scenario_id);
%end;
run;
%mend sqf_clean_sheet;

/* ---------- XLSX loader (needs SAS/ACCESS to PC Files) ---------- */
%macro sqf_load_xlsx_sheet(file=, sheet=, out=);
%local _ok _f;
%let _ok = 0;
%let _f  = %sqf_norm_path(&file);
%if %length(&_f) = 0 %then %do;
    %let SQF_VMSG = No workbook path given (control=).;
    %sqf_verr(sev=E, scen=, field=&sheet)
    %return;
%end;
%if not %sysfunc(fileexist(&_f)) %then %do;
    %let SQF_VMSG = Workbook not found: &_f (path must be visible to the SAS SERVER, not just your PC).;
    %sqf_verr(sev=E, scen=, field=&sheet)
    %return;
%end;
libname _sqfxl xlsx "&_f";
%if &syslibrc = 0 %then %do;
    %if %sysfunc(exist(_sqfxl.&sheet)) %then %do;
        data &out; set _sqfxl.&sheet; run;
        %let _ok = 1;
    %end;
    libname _sqfxl clear;
    %if &_ok = 0 %then %do;
        %let SQF_VMSG = Workbook has no sheet named &sheet..;
        %sqf_verr(sev=E, scen=, field=&sheet)
    %end;
%end;
%else %do;
    /* engine unavailable or file locked -- try PROC IMPORT */
    proc import datafile="&_f" dbms=xlsx out=&out replace;
        sheet="&sheet";
        getnames=yes;
    run;
    %if %sysfunc(exist(&out)) %then %let _ok = 1;
    %else %do;
        %let SQF_VMSG = Could not read sheet &sheet from the workbook. Check that SAS/ACCESS to PC Files is licensed, the path is visible to the SAS SERVER, and the workbook is not open in Excel. Fallback: export the sheets as CSV files to a folder and pass control=that-folder.;
        %sqf_verr(sev=E, scen=, field=&sheet)
    %end;
%end;
%mend sqf_load_xlsx_sheet;

/* ---------- CSV loader (Base SAS only) ---------- */
%macro sqf_load_csv_sheet(file=, sheet=, out=);
%local _cols _typs _lens _reqs _n _i _c _hi _pos _f _sqf_csvbad _sqf_hcount;
%sqf_sheet_meta(&sheet)
%let _n = %sysfunc(countw(&_cols));
%let _f = %sqf_norm_path(&file);
%let _sqf_csvbad = 0;
%let _sqf_hcount = 0;
%if %length(&_f) = 0 %then %do;
    %let SQF_VMSG = No CSV path given (control= must be the folder holding the three CSV files).;
    %sqf_verr(sev=E, scen=, field=&sheet)
    %return;
%end;
%if not %sysfunc(fileexist(&_f)) %then %do;
    %let SQF_VMSG = CSV file not found: &_f;
    %sqf_verr(sev=E, scen=, field=&sheet)
    %return;
%end;
/* pre-scan: unbalanced quotes usually mean an embedded newline (not
   supported in CSV mode) or a stray quote                              */
data _null_;
    infile "&_f" lrecl=32767 truncover end=_eof;
    input;
    retain _bad 0;
    if mod(countc(_infile_, '"'), 2) = 1 and _bad = 0 then _bad = _n_;
    if _eof then call symputx('_sqf_csvbad', _bad);
run;
%if &_sqf_csvbad > 0 %then %do;
    %let SQF_VMSG = &sheet CSV line &_sqf_csvbad has unbalanced quotes (embedded newlines are not supported in CSV control files%str(;) use the XLSX workbook for multi-line cells).;
    %sqf_verr(sev=E, scen=, field=&sheet)
    %return;
%end;
/* header row -> column positions */
data _null_;
    infile "&_f" lrecl=32767 truncover obs=1;
    input;
    length _line $32767 _nm $64;
    _line = _infile_;
    if substr(_line, 1, 3) = 'EFBBBF'x then _line = substr(_line, 4);  /* BOM */
    _k = countw(_line, ',', 'qm');
    call symputx('_sqf_hcount', max(_k, 0));
    do _i = 1 to _k;
        _nm = upcase(strip(dequote(strip(scan(_line, _i, ',', 'qm')))));
        /* sanitize to one safe token: a blank header (trailing comma) or
           one with spaces/punctuation must not detonate the macro
           comparisons that map columns to positions                   */
        _nm = compress(_nm, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_', 'k');
        if _nm = ' ' then _nm = cats('_BLANKHDR', _i);
        call symputx(cats('_sqf_h', _i), _nm);
    end;
run;
%if &_sqf_hcount = 0 %then %do;
    %let SQF_VMSG = &sheet CSV appears to be empty (no header row): &_f;
    %sqf_verr(sev=E, scen=, field=&sheet)
    %return;
%end;
/* header presence findings (CSV columns always materialize below, so
   the generic absent-column checks cannot fire for CSV mode)           */
%do _i = 1 %to &_n;
    %let _c = %scan(&_cols, &_i);
    %let _pos = 0;
    %do _hi = 1 %to &_sqf_hcount;
        %if &&_sqf_h&_hi = &_c %then %let _pos = &_hi;
    %end;
    %if &_pos = 0 %then %do;
        %if %scan(&_reqs, &_i) = Y %then %do;
            %let SQF_VMSG = &sheet CSV is missing required column &_c (was the header renamed?).;
            %sqf_verr(sev=E, scen=, field=&_c)
        %end;
        %else %do;
            %let SQF_VMSG = &sheet CSV has no column &_c%str(;) treating it as all blank.;
            %sqf_verr(sev=W, scen=, field=&_c)
        %end;
    %end;
%end;
/* data rows: everything read as text; %sqf_type_sheet converts after  */
data &out;
    length
    %do _i = 1 %to &_n;
        %let _c = %scan(&_cols, &_i);
        &_c
        %if %scan(&_typs, &_i) = N %then $200;
        %else $%scan(&_lens, &_i);
    %end;
        _sqf_f1-_sqf_f&_sqf_hcount $8000;
    infile "&_f" dsd truncover firstobs=2 lrecl=32767;
    input (_sqf_f1-_sqf_f&_sqf_hcount) (:$8000.);
    %do _i = 1 %to &_n;
        %let _c = %scan(&_cols, &_i);
        %let _pos = 0;
        %do _hi = 1 %to &_sqf_hcount;
            %if &&_sqf_h&_hi = &_c %then %let _pos = &_hi;
        %end;
        %if &_pos > 0 %then %do;
            &_c = strip(_sqf_f&_pos);
        %end;
        %else %do;
            &_c = ' ';
        %end;
    %end;
    drop _sqf_f:;
run;
%mend sqf_load_csv_sheet;

/* ---------- entry point ---------- */
/* control_type: AUTO | XLSX | CSV | DATASET
   XLSX  : control = path of .xlsx/.xlsm workbook
   CSV   : control = folder containing scenarios.csv/steps.csv/parameters.csv
   DATASET: ctl_scenarios/ctl_steps/ctl_parameters read from &control_lib  */
%macro sqf_load_control(control=, control_type=AUTO, control_lib=WORK);
%local _t _c _sheet _file _i _lc _raw _ext;
%let _t = %upcase(&control_type);
%let _c = %sqf_norm_path(&control);
%if &_t = AUTO %then %do;
    %if %length(&_c) = 0 %then %let _t = DATASET;
    %else %do;
        /* a folder path has no dot, so the "extension" resolves to the
           WHOLE PATH - its slashes would be read as division operators
           by an unquoted %IF comparison. Quote both operands.          */
        %let _ext = %upcase(%qscan(&_c, -1, .));
        %if "&_ext" = "XLSX" or "&_ext" = "XLSM" %then %let _t = XLSX;
        %else %let _t = CSV;
    %end;
%end;
%global SQF_CONTROL_TYPE;
%let SQF_CONTROL_TYPE = &_t;
%do _i = 1 %to 3;
    %let _sheet = %scan(SCENARIOS STEPS PARAMETERS, &_i);
    %let _lc    = %scan(scenarios steps parameters, &_i);
    %let _raw   = work._sqf_raw_&_lc;
    %if %sysfunc(exist(&_raw)) %then %do;
        proc datasets lib=work nolist nowarn; delete _sqf_raw_&_lc; quit;
    %end;
    %if &_t = XLSX %then %do;
        %sqf_load_xlsx_sheet(file=&_c, sheet=&_sheet, out=&_raw)
    %end;
    %else %if &_t = CSV %then %do;
        %sqf_load_csv_sheet(file=&_c/&_lc..csv, sheet=&_sheet, out=&_raw)
    %end;
    %else %do;
        %if %sysfunc(exist(&control_lib..ctl_&_lc)) %then %do;
            data &_raw; set &control_lib..ctl_&_lc; run;
        %end;
        %else %do;
            %let SQF_VMSG = DATASET control mode: &control_lib..ctl_&_lc not found.;
            %sqf_verr(sev=E, scen=, field=&_sheet)
        %end;
    %end;
    %sqf_type_sheet(raw=&_raw, out=work._sqf_&_lc, sheet=&_sheet)
    %sqf_clean_sheet(ds=work._sqf_&_lc, sheet=&_sheet)
%end;
%sqf_hash_control()
%mend sqf_load_control;
/*------------------------------------------------------------------
  03. RESOLUTION
      * %sqf_flatten    : parent-chain -> ordered effective step list
      * %sqf_scan_cells : parameter substitution + cell hygiene via a
        quote-aware character scanner. User cell text NEVER passes
        through the macro processor; parameters become literal text.

      NOTE ON STRING LITERALS IN THIS FILE: inside a macro definition
      even single-quoted text is scanned for macro triggers, so no
      string constant here may contain an ampersand or percent sign
      followed by a letter. Ampersands are spelled via cats('&',...)
      single-character literals, which are inert.
------------------------------------------------------------------*/

/* Build work._sqf_steps_x (effective steps, exec_order ascending) and
   work._sqf_params_x (resolved parameters) for one scenario.
   Sets global SQF_CHAIN (root ... scenario, space separated).           */
%macro sqf_flatten(scenario=);
%global SQF_CHAIN;
%local _cur _par _depth _i _n _found;
%let SQF_CHAIN = ;
%let _cur = %upcase(&scenario);

/* scenario must exist */
%let _found = 0;
proc sql noprint;
    select count(*) into :_found trimmed
        from work._sqf_scenarios where scenario_id = "&_cur";
quit;
%if &_found = 0 %then %do;
    %let SQF_VMSG = Scenario &_cur is not defined on the SCENARIOS sheet.;
    %sqf_verr(sev=E, scen=&_cur, field=SCENARIO_ID)
    %sqf_empty_sheet(out=work._sqf_steps_x0, sheet=STEPS)
    data work._sqf_steps_x;
        length origin_scenario $32 exec_order 8;
        set work._sqf_steps_x0;
        origin_scenario = ' '; exec_order = .;
    run;
    data work._sqf_params_x;
        length name $32 value $2000 scenario_id $32 notes $500;
        call missing(of _all_); stop;
    run;
    %return;
%end;

/* walk up the parent chain (root ends up first) */
%let SQF_CHAIN = &_cur;
%let _depth = 1;
%do %while (&_depth <= 6);
    %let _par = ;
    proc sql noprint;
        select parent_scenario into :_par trimmed
            from work._sqf_scenarios where scenario_id = "&_cur";
    quit;
    %if %length(&_par) = 0 %then %let _depth = 99;         /* reached root */
    %else %do;
        %if %sysfunc(indexw(&SQF_CHAIN, &_par)) > 0 %then %do;
            %let SQF_VMSG = Scenario inheritance cycle detected: &_par appears twice in the parent chain of %upcase(&scenario).;
            %sqf_verr(sev=E, scen=%upcase(&scenario), field=PARENT_SCENARIO)
            %let _depth = 99;
        %end;
        %else %do;
            %let _found = 0;
            proc sql noprint;
                select count(*) into :_found trimmed
                    from work._sqf_scenarios where scenario_id = "&_par";
            quit;
            %if &_found = 0 %then %do;
                %let SQF_VMSG = Parent scenario &_par (parent of &_cur) is not defined on the SCENARIOS sheet.;
                %sqf_verr(sev=E, scen=&_cur, field=PARENT_SCENARIO)
                %let _depth = 99;
            %end;
            %else %do;
                %let SQF_CHAIN = &_par &SQF_CHAIN;
                %let _cur = &_par;
                %let _depth = %eval(&_depth + 1);
                %if &_depth > 6 %then %do;
                    %let SQF_VMSG = Parent chain of %upcase(&scenario) is deeper than 5 levels.;
                    %sqf_verr(sev=E, scen=%upcase(&scenario), field=PARENT_SCENARIO)
                %end;
            %end;
        %end;
    %end;
%end;
%let _n = %sysfunc(countw(&SQF_CHAIN));

/* effective steps: parent steps first, each block in step_no order */
proc sort data=work._sqf_steps out=work._sqf_steps_s;
    by scenario_id step_no;
run;
data work._sqf_steps_x;
    length origin_scenario $32 exec_order 8;
    set
    %do _i = 1 %to &_n;
        work._sqf_steps_s(where=(scenario_id = "%scan(&SQF_CHAIN, &_i)"))
    %end;
    ;
    origin_scenario = scenario_id;
    exec_order = _n_;
run;

/* resolved parameters: global < root < ... < scenario */
proc sql;
    create table work._sqf_params_r as
    select name, value, scenario_id, notes,
           case scenario_id
               when ' ' then 0
               %do _i = 1 %to &_n;
               when "%scan(&SQF_CHAIN, &_i)" then &_i
               %end;
               else -1
           end as _rank
    from work._sqf_parameters
    where calculated _rank >= 0;
quit;
proc sort data=work._sqf_params_r; by name _rank; run;
data work._sqf_params_x;
    set work._sqf_params_r;
    by name;
    if last.name;
    drop _rank;
run;
%mend sqf_flatten;

/* -------------------------------------------------------------------
   Quote-aware scanner. Reads work._sqf_steps_x, writes:
     work._sqf_steps_r   - steps with where_clause/source/assignments
                           holding LITERAL text (params substituted)
     appends findings to work._sqf_verrors
   Policy (on the POST-substitution text):
     - ampersand-NAME outside single quotes must match a parameter or
       built-in (ITER, RUN_ID, SCENARIO_ID); one trailing dot is eaten
     - any remaining ampersand or percent outside single quotes: error
     - doubled ampersand (indirect reference): error
     - comment tokens: error; unbalanced quotes/parens: error
     - statement-like tokens outside quotes: warning finding
------------------------------------------------------------------- */
%macro sqf_scan_cells(iter=1, runid=, scenario=);
data work._sqf_steps_r(keep=scenario_id step_no active method target_table
                            where_clause key_vars source assignments options
                            notes origin_scenario exec_order where_ops)
     work._sqf_scanerr(keep=sev scenario step field message);
    length sev $1 scenario $32 step 8 field $32 message $500 where_ops $1;
    array _pnm {220} $32   _temporary_;
    array _pvl {220} $2000 _temporary_;
    retain _pc 0;
    if _n_ = 1 then do;
        do _pi = 1 to min(_pn, 217);
            set work._sqf_params_x(keep=name value) point=_pi nobs=_pn;
            _pnm{_pi} = upcase(name);
            _pvl{_pi} = value;
        end;
        _pc = min(_pn, 217);
        if _pn > 217 then do;
            sev='E'; scenario="%upcase(&scenario)"; step=.; field='PARAMETERS';
            message='More than 217 parameters apply to this scenario; reduce the PARAMETERS sheet.';
            output work._sqf_scanerr;
        end;
        _pnm{_pc+1} = 'ITER';        _pvl{_pc+1} = "&iter";
        _pnm{_pc+2} = 'RUN_ID';      _pvl{_pc+2} = "&runid";
        _pnm{_pc+3} = 'SCENARIO_ID'; _pvl{_pc+3} = "%upcase(&scenario)";
        _pc = _pc + 3;
    end;
    set work._sqf_steps_x;
    scenario  = origin_scenario;
    step      = step_no;
    where_ops = 'N';

    length _txt _buf _mbuf $32767 _fld $32 _nm $65 _vv $2000 _ch _nx _ck $1;
    array _tv {3} where_clause source assignments;

    do _ti = 1 to 3;
        _fld = upcase(scan('where_clause source assignments', _ti, ' '));
        _txt = _tv{_ti};
        if lengthn(_txt) = 0 then continue;
        _buf = ''; _mbuf = '';
        _bl = 0;                 /* current buffer length            */
        _st = 0;                 /* 0=outside 1=single-q 2=double-q  */
        _dp = 0;                 /* paren depth outside quotes       */
        _i  = 1;
        _len = lengthn(_txt);
        _ovf = 0;
        do while (_i <= _len);
            _ch = char(_txt, _i);
            _nx = ' ';
            if _i < _len then _nx = char(_txt, _i + 1);

            if _st = 1 then do;                        /* inside '...' */
                if _ch = "'" and _nx = "'" then do;
                    link addq; link addq; _i = _i + 2;
                end;
                else do;
                    if _ch = "'" then _st = 0;
                    link addq;
                    if _st = 0 and _ovf = 0 then substr(_mbuf, _bl, 1) = _ch;
                    _i = _i + 1;
                end;
            end;
            else if _st = 2 then do;                   /* inside "..." */
                if _ch = '"' and _nx = '"' then do;
                    link addq; link addq; _i = _i + 2;
                end;
                else if _ch = '26'x or _ch = '25'x then link trig;
                else do;
                    if _ch = '"' then _st = 0;
                    link addq;
                    if _st = 0 and _ovf = 0 then substr(_mbuf, _bl, 1) = _ch;
                    _i = _i + 1;
                end;
            end;
            else do;                                   /* outside      */
                if _ch = "'" then do; _st = 1; link addv; _i = _i + 1; end;
                else if _ch = '"' then do; _st = 2; link addv; _i = _i + 1; end;
                else if _ch = '26'x or _ch = '25'x then link trig;
                else if _ch = '(' then do; _dp + 1; link addv; _i = _i + 1; end;
                else if _ch = ')' then do;
                    _dp + (-1); link addv; _i = _i + 1;
                    if _dp < 0 then do;
                        sev='E'; field=_fld;
                        message=catx(' ', 'Unbalanced ) in', _fld, 'cell.');
                        output work._sqf_scanerr;
                        _dp = 0;
                    end;
                end;
                else if _ch = '/' and _nx = '*' then do;
                    sev='E'; field=_fld;
                    message=catx(' ', 'Comment tokens are not allowed in', _fld, 'cells; use the NOTES column.');
                    output work._sqf_scanerr;
                    _i = _i + 2;
                end;
                else if _ch = '*' and _nx = '/' then do;
                    sev='E'; field=_fld;
                    message=catx(' ', 'Comment tokens are not allowed in', _fld, 'cells; use the NOTES column.');
                    output work._sqf_scanerr;
                    _i = _i + 2;
                end;
                else do; link addv; _i = _i + 1; end;
            end;
        end;
        if _st ne 0 then do;
            sev='E'; field=_fld;
            message=catx(' ', 'Unbalanced quote in', _fld, 'cell.');
            output work._sqf_scanerr;
        end;
        if _dp ne 0 then do;
            sev='E'; field=_fld;
            message=catx(' ', 'Unbalanced ( in', _fld, 'cell.');
            output work._sqf_scanerr;
        end;
        if _ovf = 1 then do;
            sev='E'; field=_fld;
            message=catx(' ', _fld, 'cell exceeds 32767 characters after parameter substitution.');
            output work._sqf_scanerr;
        end;
        else if lengthn(_buf) > vlength(_tv{_ti}) then do;
            sev='E'; field=_fld;
            message=catx(' ', _fld, 'cell exceeds', put(vlength(_tv{_ti}), best8.-l),
                         'characters after parameter substitution.');
            output work._sqf_scanerr;
        end;
        /* statement-like tokens -> warning finding */
        if prxmatch('/\b(DATA|PROC|LIBNAME|FILENAME|ENDSAS|MERGE|INFILE)\b/i', _mbuf) or
           prxmatch('/\b(RUN|QUIT|OUTPUT|STOP|ABORT|DELETE)\s*;/i', _mbuf) or
           prxmatch('/\bCALL\s+EXECUTE\b/i', _mbuf) then do;
            sev='W'; field=_fld;
            message=catx(' ', _fld, 'cell contains statement-like tokens. Transformations should normally be assignments/conditions only; use CUSTOM_CODE for full steps.');
            output work._sqf_scanerr;
        end;
        /* classify the where clause: does it use WHERE-only operators
           (or operators whose meaning DIFFERS in IF context, like <>)?
           Decides IF-guard vs order-preserving-split codegen.           */
        if _ti = 1 then do;
            if prxmatch('/\b(LIKE|CONTAINS|BETWEEN|SOUNDS)\b|\bIS\s+(NOT\s+)?(NULL|MISSING)\b|\bSAME\s+AND\b|=\*|\?|<>|></i', _mbuf)
                then where_ops = 'Y';
        end;
        _tv{_ti} = _buf;
    end;
    output work._sqf_steps_r;
    return;

  addv:  /* append _ch to buffer, visible in mask */
    if _bl >= 32767 then _ovf = 1;
    else do;
        _bl + 1;
        substr(_buf,  _bl, 1) = _ch;
        substr(_mbuf, _bl, 1) = _ch;
    end;
  return;

  addq:  /* append _ch, masked as blank (inside quotes) */
    if _bl >= 32767 then _ovf = 1;
    else do;
        _bl + 1;
        substr(_buf,  _bl, 1) = _ch;
        substr(_mbuf, _bl, 1) = ' ';
    end;
  return;

  trig:  /* live macro trigger character encountered ('26'x / '25'x) */
    if _ch = '25'x then do;
        sev='E'; field=_fld;
        message=catx(' ', 'Percent sign outside single quotes in', _fld,
                     'cell. Macro triggers are not allowed; quote literals in single quotes or use PARAMETERS / CUSTOM_CODE.');
        output work._sqf_scanerr;
        _i = _i + 1;
    end;
    else if _nx = '26'x then do;
        sev='E'; field=_fld;
        message=catx(' ', 'Doubled ampersand (indirect reference) is not supported in', _fld, 'cell.');
        output work._sqf_scanerr;
        _i = _i + 2;
    end;
    else do;
        /* collect the referenced NAME */
        _j = _i + 1; _nm = '';
        do while (_j <= _len);
            _ck = char(_txt, _j);
            if (_ck >= 'A' and _ck <= 'Z') or (_ck >= 'a' and _ck <= 'z')
               or _ck = '_' or ((_ck >= '0' and _ck <= '9') and _j > _i + 1)
                then do; _nm = cats(_nm, _ck); _j = _j + 1; end;
            else _j = _len + 9999;
        end;
        _k = _i + 1 + lengthn(_nm);               /* first char after name  */
        if lengthn(_nm) = 0 then do;
            sev='E'; field=_fld;
            message=catx(' ', 'Bare ampersand outside single quotes in', _fld,
                         'cell. Quote literal text in single quotes, or reference a defined parameter.');
            output work._sqf_scanerr;
            _i = _i + 1;
        end;
        else do;
            _hit = 0;
            do _pi = 1 to _pc while (_hit = 0);
                if _pnm{_pi} = upcase(_nm) then _hit = _pi;
            end;
            if _hit = 0 then do;
                sev='E'; field=_fld;
                message=catx(' ', cats('Unknown parameter ', '26'x, _nm), 'in', _fld,
                             'cell. Define it on the PARAMETERS sheet.');
                output work._sqf_scanerr;
                _i = _k;
                if _i <= _len then if char(_txt, _i) = '.' then _i = _i + 1;
            end;
            else do;
                _vv = _pvl{_hit};
                _vl = lengthn(_vv);
                if _bl + _vl > 32767 then _ovf = 1;
                else if _vl > 0 then do;
                    substr(_buf,  _bl + 1, _vl) = substr(_vv, 1, _vl);
                    substr(_mbuf, _bl + 1, _vl) = repeat(' ', max(_vl - 1, 0));
                    _bl = _bl + _vl;
                end;
                _i = _k;
                /* one trailing dot delimits the reference, SAS-style */
                if _i <= _len then if char(_txt, _i) = '.' then _i = _i + 1;
            end;
        end;
    end;
  return;
run;

/* second pass: substitution must not have introduced live triggers
   (e.g. a parameter VALUE that itself contains an ampersand).          */
data work._sqf_scanerr2(keep=sev scenario step field message);
    length sev $1 scenario $32 step 8 field $32 message $500;
    set work._sqf_steps_r;
    scenario = origin_scenario;
    step     = step_no;
    length _txt $32767 _fld $32 _ch $1;
    array _tv {3} where_clause source assignments;
    do _ti = 1 to 3;
        _fld = upcase(scan('where_clause source assignments', _ti, ' '));
        _txt = _tv{_ti};
        _st = 0;
        _n2 = lengthn(_txt);
        do _i = 1 to _n2;
            _ch = char(_txt, _i);
            if _st = 1 then do;
                if _ch = "'" then _st = 0;
            end;
            else do;
                if _ch = "'" then _st = 1;
                else if _ch = '26'x or _ch = '25'x then do;
                    sev='E'; field=_fld;
                    message=catx(' ', 'Parameter substitution left a live macro trigger in',
                                 _fld, 'cell (check parameter values for ampersand / percent characters).');
                    output;
                    _i = _n2;         /* one finding per cell is enough */
                end;
            end;
        end;
    end;
run;
proc append base=work._sqf_verrors data=work._sqf_scanerr  force; run;
proc append base=work._sqf_verrors data=work._sqf_scanerr2 force; run;
proc datasets lib=work nolist nowarn; delete _sqf_scanerr _sqf_scanerr2; quit;
%mend sqf_scan_cells;
/*------------------------------------------------------------------
  04. PROCESSED STEPS + STATIC VALIDATION
      %sqf_process_steps : parse source grammar, options tokens and
                           column mappings -> work._sqf_steps_p,
                           work._sqf_maps
      %sqf_validate      : the pre-flight checklist. Findings go to
                           work._sqf_verrors; nothing is staged and
                           nothing runs if any severity=E remains.
------------------------------------------------------------------*/

%macro sqf_process_steps();
data work._sqf_steps_p(keep=scenario_id step_no active method target_table
                            where_clause key_vars source assignments options
                            notes origin_scenario exec_order where_ops
                            src_kind src_scen src_member src_runid src_path
                            opt_newcols opt_drop opt_keepextra opt_nowarn0
                            opt_iters has_where has_assign map_n)
     work._sqf_maps(keep=exec_order step_no origin_scenario map_seq tgt_col src_col)
     work._sqf_perr(keep=sev scenario step field message);
    length sev $1 scenario $32 step 8 field $32 message $500;
    length src_kind $8 src_scen $32 src_member $32 src_runid $64 src_path $500
           opt_newcols opt_drop opt_keepextra opt_nowarn0 8 opt_iters $3
           has_where has_assign 8 map_n 8
           map_seq 8 tgt_col $32 src_col $32;
    set work._sqf_steps_r;
    scenario = origin_scenario;
    step     = step_no;

    /* ---- source grammar ---- */
    src_kind = ' '; src_scen = ' '; src_member = ' '; src_runid = ' '; src_path = ' ';
    length _s $500 _b $500 _tok $40 _pair $200;
    _s = strip(source);
    if _s ne ' ' then do;
        if upcase(_s) =: 'BASE:' then do;
            src_kind = 'BASE';
            src_member = upcase(strip(substr(_s, 6)));
        end;
        else if upcase(_s) =: 'SCEN:' then do;
            src_kind = 'SCEN';
            src_member = upcase(strip(substr(_s, 6)));
        end;
        else if upcase(_s) =: 'PREV:' then do;
            src_kind = 'PREV';
            src_member = upcase(strip(substr(_s, 6)));
        end;
        else if upcase(_s) =: 'RUN:' then do;
            src_kind = 'RUN';
            _b = strip(substr(_s, 5));
            /* RUN:<scenario>.<member>[@<run_id>] */
            _at = index(_b, '@');
            if _at > 0 then do;
                src_runid = strip(substr(_b, _at + 1));
                _b = strip(substr(_b, 1, _at - 1));
            end;
            if countw(_b, '.') = 2 then do;
                src_scen   = upcase(strip(scan(_b, 1, '.')));
                src_member = upcase(strip(scan(_b, 2, '.')));
            end;
            else do;
                sev='E'; field='SOURCE';
                message=catx(' ', 'RUN: source must look like RUN:SCENARIO.TABLE or RUN:SCENARIO.TABLE@run_id, got:', _s);
                output work._sqf_perr;
            end;
        end;
        else do;
            src_kind = 'PATH';                 /* CUSTOM_CODE snippet */
            src_path = _s;
        end;
        if src_kind in ('BASE','SCEN','PREV')
           and not prxmatch('/^[A-Za-z_][A-Za-z0-9_]{0,31}$/', strip(src_member)) then do;
            sev='E'; field='SOURCE';
            message=catx(' ', 'Source table name is not a valid SAS dataset name:', _s);
            output work._sqf_perr;
        end;
        if src_kind = 'RUN' then do;
            if not prxmatch('/^[A-Za-z_][A-Za-z0-9_]{0,31}$/', strip(src_scen))
               or not prxmatch('/^[A-Za-z_][A-Za-z0-9_]{0,31}$/', strip(src_member)) then do;
                sev='E'; field='SOURCE';
                message=catx(' ', 'RUN: source scenario/table is not a valid SAS name:', _s);
                output work._sqf_perr;
            end;
        end;
    end;

    /* ---- options tokens ---- */
    opt_newcols = 0; opt_drop = 0; opt_keepextra = 0; opt_nowarn0 = 0;
    opt_iters = 'ALL';
    do _oi = 1 to countw(options, ' ');
        _tok = upcase(scan(options, _oi, ' '));
        if _tok = 'NEWCOLS' then opt_newcols = 1;
        else if _tok = 'DROP' then opt_drop = 1;
        else if _tok = 'KEEPEXTRA' then opt_keepextra = 1;
        else if _tok = 'NOWARN0' then opt_nowarn0 = 1;
        else if _tok = 'ITERS=1' then opt_iters = '1';
        else if _tok = 'ITERS=2+' then opt_iters = '2+';
        else if _tok = 'ITERS=ALL' then opt_iters = 'ALL';
        else do;
            sev='E'; field='OPTIONS';
            message=catx(' ', 'Unknown OPTIONS token:', _tok,
                         '(valid: NEWCOLS DROP KEEPEXTRA NOWARN0 ITERS=1 ITERS=2+ ITERS=ALL).');
            output work._sqf_perr;
        end;
    end;
    if src_kind = 'PREV' then opt_iters = '2+';   /* implicit */
    /* option applicability */
    if opt_drop = 1 and method ne 'FILTER_ROWS' then do;
        sev='E'; field='OPTIONS';
        message='DROP is only valid for FILTER_ROWS.';
        output work._sqf_perr;
    end;
    if opt_newcols = 1 and method ne 'SET_VALUES' then do;
        sev='E'; field='OPTIONS';
        message='NEWCOLS is only valid for SET_VALUES.';
        output work._sqf_perr;
    end;
    if opt_keepextra = 1 and method ne 'REPLACE_TABLE' then do;
        sev='E'; field='OPTIONS';
        message='KEEPEXTRA is only valid for REPLACE_TABLE.';
        output work._sqf_perr;
    end;

    has_where  = (lengthn(where_clause) > 0);
    has_assign = (lengthn(assignments)  > 0);

    /* a cell filling its column exactly usually means the loader had to
       truncate it - refuse to run on a possibly-mangled expression      */
    if lengthn(where_clause) >= 4000 or lengthn(assignments) >= 8000
       or lengthn(source) >= 500 then do;
        sev='E'; field='CELL';
        message='A cell in this step reaches the storage limit (where 4000 / assignments 8000 / source 500 chars) and was probably truncated at load. Shorten it or move values to PARAMETERS.';
        output work._sqf_perr;
    end;

    /* ---- column mapping pairs (UPDATE_FROM / REPLACE / APPEND) ---- */
    map_n = 0;
    if method in ('UPDATE_FROM','REPLACE_TABLE','APPEND_ROWS') and has_assign then do;
        do _mi = 1 to countw(assignments, ';');
            _pair = strip(scan(assignments, _mi, ';'));
            if _pair ne ' ' then do;
                if count(_pair, '=') ne 1 then do;
                    sev='E'; field='ASSIGNMENTS';
                    message=catx(' ', 'For', method,
                                 'the assignments cell must hold simple target_col=source_col pairs separated by semicolons, got:', _pair);
                    output work._sqf_perr;
                end;
                else do;
                    tgt_col = upcase(strip(scan(_pair, 1, '=')));
                    src_col = upcase(strip(scan(_pair, 2, '=')));
                    if not prxmatch('/^[A-Za-z_][A-Za-z0-9_]{0,31}$/', strip(tgt_col))
                       or not prxmatch('/^[A-Za-z_][A-Za-z0-9_]{0,31}$/', strip(src_col)) then do;
                        sev='E'; field='ASSIGNMENTS';
                        message=catx(' ', 'Column mapping pair is not two valid SAS names:', _pair);
                        output work._sqf_perr;
                    end;
                    else do;
                        map_n = map_n + 1;
                        map_seq = map_n;
                        output work._sqf_maps;
                    end;
                end;
            end;
        end;
    end;
    output work._sqf_steps_p;
run;
proc append base=work._sqf_verrors data=work._sqf_perr force; run;
proc datasets lib=work nolist nowarn; delete _sqf_perr; quit;
%mend sqf_process_steps;

/* -------------------------------------------------------------------
   Static validation. Assumes: control loaded, %sqf_flatten,
   %sqf_scan_cells and %sqf_process_steps have run, SQFBASE assigned.
   chain=1 when called from %run_chain.
------------------------------------------------------------------- */
%macro sqf_validate(scenario=, root=, chain=0);
%local _i _n _ns _r _skip _seen _vcnt _sda _rdir _pth _k _kv _w _tvl _kcat
       _m_method _m_target _m_stepno _m_active _m_origin _m_srckind _m_srcmem
       _m_srcscen _m_srcrunid _m_keys _m_hasw _m_hasa _m_whereops _m_iters
       _m_mapn;

/* resolved RUN: source directories, consumed by %sqf_assign_srclibs
   and by the dry-run sandbox prologue                                   */
data work._sqf_runsrc;
    length exec_order 8 rundir $300;
    call missing(of _all_);
    stop;
run;

/* ---------- sheet-level checks (direct finding rows) ---------- */
proc sort data=work._sqf_scenarios out=work._sqf_scen_s; by scenario_id; run;
data work._sqf_v1(keep=sev scenario step field message);
    length sev $1 scenario $32 step 8 field $32 message $500;
    step = .;
    set work._sqf_scen_s;
    by scenario_id;
    if first.scenario_id and not last.scenario_id then do;
        sev='E'; scenario=scenario_id; field='SCENARIO_ID';
        message='Scenario id appears more than once on the SCENARIOS sheet.';
        output;
    end;
    if not prxmatch('/^[A-Za-z_][A-Za-z0-9_]{0,23}$/', strip(scenario_id)) then do;
        sev='E'; scenario=scenario_id; field='SCENARIO_ID';
        message=catx(' ', 'Scenario id', scenario_id,
            'is not usable: letters/digits/underscore, starting with a letter, max 24 chars (it becomes a folder name).');
        output;
    end;
    if active not in ('Y','N') then do;
        sev='E'; scenario=scenario_id; field='ACTIVE';
        message=catx(' ', 'ACTIVE is', active, '- use Y or N.');
        output;
    end;
    if parent_scenario = scenario_id and scenario_id ne ' ' then do;
        sev='E'; scenario=scenario_id; field='PARENT_SCENARIO';
        message='Scenario lists itself as its parent.';
        output;
    end;
    if parent_scenario ne ' ' then do;
        if 0 then set work._sqf_scen_s(keep=scenario_id rename=(scenario_id=_chk)) nobs=_nn;
        _ok = 0;
        do _p = 1 to _nn while (_ok = 0);
            set work._sqf_scen_s(keep=scenario_id rename=(scenario_id=_chk)) point=_p;
            if _chk = parent_scenario then _ok = 1;
        end;
        if _ok = 0 then do;
            sev='E'; scenario=scenario_id; field='PARENT_SCENARIO';
            message=catx(' ', 'Parent scenario', parent_scenario, 'is not defined on the SCENARIOS sheet.');
            output;
        end;
    end;
run;
proc append base=work._sqf_verrors data=work._sqf_v1 force; run;

/* parameters: names, reserved names, duplicate name+scope */
proc sort data=work._sqf_parameters out=work._sqf_par_s; by name scenario_id; run;
data work._sqf_v2(keep=sev scenario step field message);
    length sev $1 scenario $32 step 8 field $32 message $500;
    step = .; field = 'PARAMETERS';
    set work._sqf_par_s;
    by name scenario_id;
    scenario = scenario_id;
    if not prxmatch('/^[A-Za-z_][A-Za-z0-9_]{0,31}$/', strip(name)) then do;
        sev='E';
        message=catx(' ', 'Parameter name', name, 'is not a valid SAS name.');
        output;
    end;
    else if upcase(name) in ('ITER','RUN_ID','SCENARIO_ID','RUN_TS')
         or upcase(name) =: 'SQF' or upcase(name) =: 'SYS' then do;
        sev='E';
        message=catx(' ', 'Parameter name', name, 'is reserved (built-ins, SQF*, SYS*). Pick another name.');
        output;
    end;
    if first.scenario_id and not last.scenario_id then do;
        sev='E';
        message=catx(' ', 'Parameter', name, 'is defined more than once for the same scope.');
        output;
    end;
run;
proc append base=work._sqf_verrors data=work._sqf_v2 force; run;

/* duplicate step numbers within a scenario (whole sheet) */
proc sql noprint;
    create table work._sqf_v3 as
    select 'E' as sev length=1, scenario_id as scenario length=32,
           step_no as step, 'STEP_NO' as field length=32,
           'Step number appears more than once in this scenario.' as message length=500
    from work._sqf_steps
    where not missing(step_no)
    group by scenario_id, step_no
    having count(*) > 1;
quit;
proc append base=work._sqf_verrors data=work._sqf_v3 force; run;

/* ---------- per-step checks (effective steps of THIS scenario) ---------- */
%let _ns = 0;
%sqf_nobs(ds=work._sqf_steps_p, mvar=_ns)
%if &_ns > 99 %then %do;
    %let SQF_VMSG = More than 99 steps after inheritance flattening%str(;) the framework supports at most 99 per run.;
    %sqf_verr(sev=E, scen=%upcase(&scenario), field=STEPS)
    %let _ns = 0;
%end;
%if &_ns > 0 %then %do;
data _null_;
    set work._sqf_steps_p;
    length _r $8;
    _r = put(_n_, best8.-l);
    call symputx(cats('_m_method_',  _r), method);
    call symputx(cats('_m_target_',  _r), target_table);
    call symputx(cats('_m_stepno_',  _r), put(step_no, best8.-l));
    call symputx(cats('_m_active_',  _r), active);
    /* ids flow into macro-call arguments below: keep them one safe token
       even if the sheet was malformed                                   */
    call symputx(cats('_m_origin_',  _r),
                 coalescec(compress(origin_scenario,
                     'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_', 'k'),
                     'BADID'));
    call symputx(cats('_m_srckind_', _r), src_kind);
    call symputx(cats('_m_srcmem_',  _r), src_member);
    call symputx(cats('_m_srcscen_', _r), src_scen);
    call symputx(cats('_m_srcrunid_',_r), src_runid);
    call symputx(cats('_m_srcpath_', _r), src_path);
    call symputx(cats('_m_keys_',    _r), key_vars);
    call symputx(cats('_m_hasw_',    _r), has_where);
    call symputx(cats('_m_hasa_',    _r), has_assign);
    call symputx(cats('_m_whereops_',_r), where_ops);
    call symputx(cats('_m_iters_',   _r), opt_iters);
    call symputx(cats('_m_mapn_',    _r), map_n);
run;
%end;

%let _seen = ;      /* targets staged by earlier steps (for SCEN:) */
%let _vcnt = 0;     /* count of active steps                       */
%do _r = 1 %to &_ns;
    %let _skip     = 0;
    %let _m_method  = &&_m_method_&_r;
    %let _m_target  = &&_m_target_&_r;
    %let _m_stepno  = &&_m_stepno_&_r;
    %let _m_active  = &&_m_active_&_r;
    %let _m_origin  = &&_m_origin_&_r;
    %let _m_srckind = &&_m_srckind_&_r;
    %let _m_srcmem  = &&_m_srcmem_&_r;
    %let _m_srcscen = &&_m_srcscen_&_r;
    %let _m_srcrunid= &&_m_srcrunid_&_r;
    %let _m_keys    = &&_m_keys_&_r;
    %let _m_hasw    = &&_m_hasw_&_r;
    %let _m_hasa    = &&_m_hasa_&_r;
    %let _m_whereops= &&_m_whereops_&_r;
    %let _m_iters   = &&_m_iters_&_r;
    %let _m_mapn    = &&_m_mapn_&_r;

    %if &_m_active = N %then %let _skip = 1;
    %else %if &_m_active ne Y %then %do;
        %let SQF_VMSG = ACTIVE must be Y or N.;
        %sqf_verr(sev=E, scen=&_m_origin, step=&_m_stepno, field=ACTIVE)
    %end;

    %if &_skip = 0 %then %do;
        %let _vcnt = %eval(&_vcnt + 1);
        /* step number sanity */
        %if &_m_stepno = . or %length(&_m_stepno) = 0 %then %do;
            %let SQF_VMSG = STEP_NO is missing or not a number.;
            %sqf_verr(sev=E, scen=&_m_origin, step=., field=STEP_NO)
            %let _skip = 1;
        %end;
        %else %if %sysevalf(&_m_stepno < 1) or %sysfunc(mod(&_m_stepno, 1)) ne 0 %then %do;
            %let SQF_VMSG = STEP_NO must be a positive integer, got &_m_stepno..;
            %sqf_verr(sev=E, scen=&_m_origin, step=., field=STEP_NO)
            %let _skip = 1;
        %end;
    %end;

    %if &_skip = 0 %then %do;
        /* method recognized? */
        %if not %sysfunc(indexw(SET_VALUES UPDATE_FROM REPLACE_TABLE FILTER_ROWS APPEND_ROWS COPY_TABLE CUSTOM_CODE, &_m_method)) %then %do;
            %let SQF_VMSG = Unknown METHOD "&_m_method" (valid: SET_VALUES UPDATE_FROM REPLACE_TABLE FILTER_ROWS APPEND_ROWS COPY_TABLE CUSTOM_CODE).;
            %sqf_verr(sev=E, scen=&_m_origin, step=&_m_stepno, field=METHOD)
            %let _skip = 1;
        %end;
    %end;

    %if &_skip = 0 %then %do;
        /* target table */
        %if &_m_method ne CUSTOM_CODE %then %do;
            %if %length(&_m_target) = 0 %then %do;
                %let SQF_VMSG = TARGET_TABLE is required for &_m_method..;
                %sqf_verr(sev=E, scen=&_m_origin, step=&_m_stepno, field=TARGET_TABLE)
                %let _skip = 1;
            %end;
            %else %if %length(&_m_target) > 32
                 or not %sysfunc(prxmatch(/^[A-Za-z_][A-Za-z0-9_]*$/, &_m_target)) %then %do;
                %let SQF_VMSG = TARGET_TABLE &_m_target is not a valid SAS dataset name.;
                %sqf_verr(sev=E, scen=&_m_origin, step=&_m_stepno, field=TARGET_TABLE)
                %let _skip = 1;
            %end;
            %else %if not %sysfunc(exist(SQFBASE.&_m_target)) %then %do;
                %let SQF_VMSG = TARGET_TABLE &_m_target does not exist in the base library.;
                %sqf_verr(sev=E, scen=&_m_origin, step=&_m_stepno, field=TARGET_TABLE)
                %let _skip = 1;
            %end;
        %end;
    %end;

    %if &_skip = 0 %then %do;
        /* per-method required / forbidden cells */
        %if &_m_method = SET_VALUES and &_m_hasa = 0 %then %do;
            %let SQF_VMSG = SET_VALUES needs at least one assignment statement in ASSIGNMENTS.;
            %sqf_verr(sev=E, scen=&_m_origin, step=&_m_stepno, field=ASSIGNMENTS)
        %end;
        %if &_m_method = FILTER_ROWS and &_m_hasw = 0 %then %do;
            %let SQF_VMSG = FILTER_ROWS needs a WHERE_CLAUSE.;
            %sqf_verr(sev=E, scen=&_m_origin, step=&_m_stepno, field=WHERE_CLAUSE)
        %end;
        %if (&_m_method = REPLACE_TABLE or &_m_method = COPY_TABLE) and &_m_hasw = 1 %then %do;
            %let SQF_VMSG = WHERE_CLAUSE must be blank for &_m_method..;
            %sqf_verr(sev=E, scen=&_m_origin, step=&_m_stepno, field=WHERE_CLAUSE)
        %end;
        %if (&_m_method = FILTER_ROWS or &_m_method = COPY_TABLE) and &_m_hasa = 1 %then %do;
            %let SQF_VMSG = ASSIGNMENTS must be blank for &_m_method..;
            %sqf_verr(sev=E, scen=&_m_origin, step=&_m_stepno, field=ASSIGNMENTS)
        %end;
        %if &_m_method ne UPDATE_FROM and %length(&_m_keys) > 0 %then %do;
            %let SQF_VMSG = KEY_VARS is only used by UPDATE_FROM.;
            %sqf_verr(sev=E, scen=&_m_origin, step=&_m_stepno, field=KEY_VARS)
        %end;
        %if &_m_method = UPDATE_FROM %then %do;
            %if %length(&_m_keys) = 0 %then %do;
                %let SQF_VMSG = UPDATE_FROM needs KEY_VARS (space-separated key columns).;
                %sqf_verr(sev=E, scen=&_m_origin, step=&_m_stepno, field=KEY_VARS)
                %let _skip = 1;
            %end;
            %else %if &_m_whereops = Y %then %do;
                %let SQF_VMSG = UPDATE_FROM WHERE_CLAUSE cannot use WHERE-only operators (LIKE, CONTAINS, BETWEEN, IS MISSING, <>). Rewrite with IF-compatible operators or apply SET_VALUES flags first.;
                %sqf_verr(sev=E, scen=&_m_origin, step=&_m_stepno, field=WHERE_CLAUSE)
            %end;
        %end;
        /* source requiredness */
        %if %sysfunc(indexw(UPDATE_FROM REPLACE_TABLE APPEND_ROWS CUSTOM_CODE, &_m_method)) %then %do;
            %if %length(&_m_srckind) = 0 %then %do;
                %let SQF_VMSG = &_m_method needs a SOURCE.;
                %sqf_verr(sev=E, scen=&_m_origin, step=&_m_stepno, field=SOURCE)
                %let _skip = 1;
            %end;
        %end;
        %else %if %length(&_m_srckind) > 0 %then %do;
            %let SQF_VMSG = SOURCE must be blank for &_m_method..;
            %sqf_verr(sev=E, scen=&_m_origin, step=&_m_stepno, field=SOURCE)
        %end;
        %if &_m_method = CUSTOM_CODE and &_m_srckind ne PATH and %length(&_m_srckind) > 0 %then %do;
            %let SQF_VMSG = CUSTOM_CODE SOURCE must be a .sas file path, not a table reference.;
            %sqf_verr(sev=E, scen=&_m_origin, step=&_m_stepno, field=SOURCE)
            %let _skip = 1;
        %end;
        %if &_m_srckind = PATH and &_m_method ne CUSTOM_CODE %then %do;
            %let SQF_VMSG = SOURCE must start with BASE: SCEN: RUN: or PREV: for &_m_method..;
            %sqf_verr(sev=E, scen=&_m_origin, step=&_m_stepno, field=SOURCE)
            %let _skip = 1;
        %end;
    %end;

    %if &_skip = 0 %then %do;
        /* resolve the source for schema checks where statically possible */
        %let _sda = ;
        %if &_m_srckind = BASE %then %do;
            %if not %sysfunc(exist(SQFBASE.&_m_srcmem)) %then %do;
                %let SQF_VMSG = Source table &_m_srcmem does not exist in the base library.;
                %sqf_verr(sev=E, scen=&_m_origin, step=&_m_stepno, field=SOURCE)
            %end;
            %else %let _sda = SQFBASE.&_m_srcmem;
        %end;
        %else %if &_m_srckind = SCEN %then %do;
            %if not %sysfunc(indexw(&_seen, &_m_srcmem)) %then %do;
                %let SQF_VMSG = SCEN:&_m_srcmem refers to this run%str(%')s staged copy, but no earlier step targets &_m_srcmem.. Use BASE:&_m_srcmem or add the earlier step.;
                %sqf_verr(sev=E, scen=&_m_origin, step=&_m_stepno, field=SOURCE)
            %end;
            %else %if %sysfunc(exist(SQFBASE.&_m_srcmem)) %then %let _sda = SQFBASE.&_m_srcmem;
        %end;
        %else %if &_m_srckind = RUN %then %do;
            %let _rdir = ;
            %sqf_resolve_run(root=&root, scenario=&_m_srcscen, run_id=&_m_srcrunid, mvar=_rdir)
            %if %length(&_rdir) = 0 %then %do;
                %let SQF_VMSG = No COMPLETED run of scenario &_m_srcscen found in the registry (source RUN:). Run that scenario first, or check the run_id.;
                %sqf_verr(sev=E, scen=&_m_origin, step=&_m_stepno, field=SOURCE)
            %end;
            %else %do;
                libname _sqfv "&_rdir/outputs" access=readonly;
                %if %sysfunc(libref(_sqfv)) ne 0 %then %do;
                    %let SQF_VMSG = Could not open the outputs folder of run &_rdir..;
                    %sqf_verr(sev=E, scen=&_m_origin, step=&_m_stepno, field=SOURCE)
                %end;
                %else %if not %sysfunc(exist(_sqfv.&_m_srcmem)) %then %do;
                    %let SQF_VMSG = Table &_m_srcmem not found in the outputs of the referenced run (&_rdir).;
                    %sqf_verr(sev=E, scen=&_m_origin, step=&_m_stepno, field=SOURCE)
                %end;
                %else %do;
                    %let _sda = _sqfv.&_m_srcmem;
                    data work._sqf_rs1;
                        length exec_order 8 rundir $300;
                        exec_order = &_r;
                        rundir = symget('_rdir');
                    run;
                    proc append base=work._sqf_runsrc data=work._sqf_rs1 force; run;
                    proc datasets lib=work nolist nowarn; delete _sqf_rs1; quit;
                %end;
            %end;
        %end;
        %else %if &_m_srckind = PREV %then %do;
            %if &chain = 0 %then %do;
                %let SQF_VMSG = PREV: sources are only valid inside a chain run%str(;) use RUN: to reference a finished run.;
                %sqf_verr(sev=E, scen=&_m_origin, step=&_m_stepno, field=SOURCE)
            %end;
            /* member existence is checked per-iteration at run time */
        %end;
        %else %if &_m_srckind = PATH %then %do;
            /* CUSTOM_CODE snippet file */
            %let _pth = %sysfunc(translate(%superq(_m_srcpath_&_r), /, \));
            %if %length(&_pth) > 0 %then %do;
                %if not ("%qsubstr(&_pth, 1, 1)" = "/" or %index(&_pth, :) = 2) %then
                    %let _pth = &root/custom/&_pth;
                %if not %sysfunc(fileexist(&_pth)) %then %do;
                    %let SQF_VMSG = CUSTOM_CODE snippet not found: &_pth;
                    %sqf_verr(sev=E, scen=&_m_origin, step=&_m_stepno, field=SOURCE)
                %end;
            %end;
        %end;

        %if &_m_iters = 2+ and &chain = 0 %then %do;
            %let SQF_VMSG = Step has ITERS=2+ but this is a single run%str(;) the step will be skipped.;
            %sqf_verr(sev=W, scen=&_m_origin, step=&_m_stepno, field=OPTIONS)
        %end;

        /* schema checks when both sides are statically known */
        %if %length(&_sda) > 0 %then %do;
            %if &_m_method = UPDATE_FROM %then %do;
                %sqf_check_update_from(r=&_r, srcds=&_sda, scen=&_m_origin, step=&_m_stepno,
                                       target=&_m_target, keys=&_m_keys)
            %end;
            %else %if &_m_method = REPLACE_TABLE %then %do;
                %sqf_check_replace(r=&_r, srcds=&_sda, scen=&_m_origin, step=&_m_stepno, target=&_m_target)
            %end;
            %else %if &_m_method = APPEND_ROWS %then %do;
                %sqf_check_append(r=&_r, srcds=&_sda, scen=&_m_origin, step=&_m_stepno, target=&_m_target)
            %end;
        %end;

        /* reserved column prefix in the target (collides with helpers)
           + generated list-builder width limit for REPLACE/UPDATE      */
        %if &_m_method ne CUSTOM_CODE %then %do;
            %let _tvl = ;
            %sqf_varlist(ds=SQFBASE.&_m_target, mvar=_tvl)
            %let _k = 1;
            %do %while (%length(%scan(&_tvl, &_k)) > 0);
                %let _w = %upcase(%scan(&_tvl, &_k));
                %if %index(&_w, _SQF) = 1 %then %do;
                    %let SQF_VMSG = Base table &_m_target has a column starting with _SQF (reserved for generated helpers): &_w..;
                    %sqf_verr(sev=E, scen=&_m_origin, step=&_m_stepno, field=TARGET_TABLE)
                %end;
                %let _k = %eval(&_k + 1);
            %end;
            %if &_m_method = REPLACE_TABLE or &_m_method = UPDATE_FROM %then %do;
                %if %length(&_tvl) > 0 %then %if %sysfunc(countw(&_tvl)) > 900 %then %do;
                    %let SQF_VMSG = &_m_target has more than 900 columns%str(;) generated column lists for &_m_method could truncate. Use CUSTOM_CODE for this table.;
                    %sqf_verr(sev=E, scen=&_m_origin, step=&_m_stepno, field=TARGET_TABLE)
                %end;
            %end;
        %end;
        /* track staged targets for SCEN: (CUSTOM_CODE may declare one) */
        %if %length(&_m_target) > 0 %then %do;
            %if not %sysfunc(indexw(&_seen, &_m_target)) %then %let _seen = &_seen &_m_target;
        %end;
    %end;

    %if %sysfunc(libref(_sqfv)) = 0 %then %do;
        libname _sqfv clear;
    %end;
%end;

%if &_vcnt = 0 %then %do;
    %let SQF_VMSG = Scenario has no active steps%str(;) this will be a pure baseline run of the main program.;
    %sqf_verr(sev=W, scen=%upcase(&scenario), field=STEPS)
%end;
%mend sqf_validate;

/* ---- schema-check helpers ---- */

%macro sqf_check_update_from(r=, srcds=, scen=, step=, target=, keys=);
%local _k _kv _tt _ts _cnt _cntd _kcat _mn _mi _tc _sc _tt3 _ts3 _svl _w _hit _tt2;
%let _mn = 0;
proc sql noprint;
    select count(*) into :_mn trimmed from work._sqf_maps where exec_order = &r;
quit;
%let _k = 1;
%do %while (%length(%scan(&keys, &_k)) > 0);
    %let _kv = %scan(&keys, &_k);
    %let _tt = ; %let _ts = ;
    %sqf_vartype(ds=SQFBASE.&target, var=&_kv, mvar=_tt)
    %sqf_vartype(ds=&srcds, var=&_kv, mvar=_ts)
    %if %length(&_tt) = 0 %then %do;
        %let SQF_VMSG = Key column &_kv not found in target &target..;
        %sqf_verr(sev=E, scen=&scen, step=&step, field=KEY_VARS)
    %end;
    %if %length(&_ts) = 0 %then %do;
        %let SQF_VMSG = Key column &_kv not found in the source (&srcds).;
        %sqf_verr(sev=E, scen=&scen, step=&step, field=KEY_VARS)
    %end;
    %if %length(&_tt) > 0 and %length(&_ts) > 0 and &_tt ne &_ts %then %do;
        %let SQF_VMSG = Key column &_kv is type &_tt in the target but &_ts in the source.;
        %sqf_verr(sev=E, scen=&scen, step=&step, field=KEY_VARS)
    %end;
    %let _k = %eval(&_k + 1);
%end;
%if &_mn > 0 %then %do;
    data _null_;
        set work._sqf_maps(where=(exec_order = &r));
        call symputx(cats('_map_t_', map_seq), tgt_col);
        call symputx(cats('_map_s_', map_seq), src_col);
    run;
    %do _mi = 1 %to &_mn;
        %let _tc = &&_map_t_&_mi;
        %let _sc = &&_map_s_&_mi;
        %let _tt3 = ; %let _ts3 = ;
        %sqf_vartype(ds=SQFBASE.&target, var=&_tc, mvar=_tt3)
        %sqf_vartype(ds=&srcds, var=&_sc, mvar=_ts3)
        %if %length(&_tt3) = 0 %then %do;
            %let SQF_VMSG = Mapped target column &_tc not found in &target..;
            %sqf_verr(sev=E, scen=&scen, step=&step, field=ASSIGNMENTS)
        %end;
        %if %length(&_ts3) = 0 %then %do;
            %let SQF_VMSG = Mapped source column &_sc not found in the source (&srcds).;
            %sqf_verr(sev=E, scen=&scen, step=&step, field=ASSIGNMENTS)
        %end;
        %if %length(&_tt3) > 0 and %length(&_ts3) > 0 and &_tt3 ne &_ts3 %then %do;
            %let SQF_VMSG = Mapped column types differ: &_tc is &_tt3, &_sc is &_ts3..;
            %sqf_verr(sev=E, scen=&scen, step=&step, field=ASSIGNMENTS)
        %end;
    %end;
%end;
%else %do;
    /* no explicit mapping: overlap by name is required */
    %let _svl = ;
    %sqf_varlist(ds=&srcds, mvar=_svl)
    %let _hit = 0;
    %let _k = 1;
    %do %while (%length(%scan(&_svl, &_k)) > 0);
        %let _w = %upcase(%scan(&_svl, &_k));
        %if not %sysfunc(indexw(%upcase(&keys), &_w)) %then %do;
            %let _tt2 = ;
            %sqf_vartype(ds=SQFBASE.&target, var=&_w, mvar=_tt2)
            %if %length(&_tt2) > 0 %then %let _hit = 1;
        %end;
        %let _k = %eval(&_k + 1);
    %end;
    %if &_hit = 0 %then %do;
        %let SQF_VMSG = UPDATE_FROM with no mapping: the source has no non-key column whose name matches a target column%str(;) nothing would be updated.;
        %sqf_verr(sev=E, scen=&scen, step=&step, field=ASSIGNMENTS)
    %end;
%end;
/* source must be unique by keys. NOTE: no CATX here - PROC SQL, unlike
   the data step, refuses CAT-family functions on numeric arguments, so
   a numeric key would silently break the check. A DISTINCT subquery is
   type-agnostic. The NOTE tracing brackets the check so a silent macro
   death here is visible in the captured validate.log.                  */
%put NOTE: [SQF] uniqueness check begins: source &srcds keys &keys;
%let _kcat = %sysfunc(translate(%sysfunc(compbl(&keys)), %str(,), %str( )));
%let _cnt = 0; %let _cntd = 0;
proc sql noprint;
    select count(*) into :_cnt trimmed from &srcds;
    select count(*) into :_cntd trimmed
        from (select distinct &_kcat from &srcds);
quit;
%put NOTE: [SQF] uniqueness check counts: rows=&_cnt distinct=&_cntd;
%if &_cnt ne &_cntd %then %do;
    %let SQF_VMSG = UPDATE_FROM source (&srcds) is not unique by KEY_VARS &keys: %eval(&_cnt - &_cntd) duplicate key rows. Deduplicate it or add key columns.;
    %sqf_verr(sev=E, scen=&scen, step=&step, field=SOURCE)
%end;
%mend sqf_check_update_from;

%macro sqf_check_replace(r=, srcds=, scen=, step=, target=);
%local _tvl _k _w _st _mn _mi _mapped _tt4;
%let _mn = 0;
proc sql noprint;
    select count(*) into :_mn trimmed from work._sqf_maps where exec_order = &r;
quit;
%if &_mn > 0 %then %do;
    data _null_;
        set work._sqf_maps(where=(exec_order = &r));
        call symputx(cats('_map_t_', map_seq), tgt_col);
        call symputx(cats('_map_s_', map_seq), src_col);
    run;
%end;
%let _tvl = ;
%sqf_varlist(ds=SQFBASE.&target, mvar=_tvl)
%let _k = 1;
%do %while (%length(%scan(&_tvl, &_k)) > 0);
    %let _w = %upcase(%scan(&_tvl, &_k));
    %let _mapped = ;
    %do _mi = 1 %to &_mn;
        %if &&_map_t_&_mi = &_w %then %let _mapped = &&_map_s_&_mi;
    %end;
    %if %length(&_mapped) = 0 %then %let _mapped = &_w;
    %let _st = ;
    %sqf_vartype(ds=&srcds, var=&_mapped, mvar=_st)
    %if %length(&_st) = 0 %then %do;
        %let SQF_VMSG = REPLACE_TABLE source has no column &_mapped needed to fill target column &_w.. Map it in ASSIGNMENTS (target_col=source_col) or fix the source.;
        %sqf_verr(sev=E, scen=&scen, step=&step, field=SOURCE)
    %end;
    %else %do;
        %let _tt4 = ;
        %sqf_vartype(ds=SQFBASE.&target, var=&_w, mvar=_tt4)
        %if &_tt4 ne &_st %then %do;
            %let SQF_VMSG = REPLACE_TABLE type mismatch for target column &_w (target &_tt4, source &_st).;
            %sqf_verr(sev=E, scen=&scen, step=&step, field=SOURCE)
        %end;
    %end;
    %let _k = %eval(&_k + 1);
%end;
%mend sqf_check_replace;

%macro sqf_check_append(r=, srcds=, scen=, step=, target=);
%local _svl _k _w _tt _st _mn _mi _overlap;
%let _mn = 0;
proc sql noprint;
    select count(*) into :_mn trimmed from work._sqf_maps where exec_order = &r;
quit;
%if &_mn > 0 %then %do;
    data _null_;
        set work._sqf_maps(where=(exec_order = &r));
        call symputx(cats('_map_t_', map_seq), tgt_col);
        call symputx(cats('_map_s_', map_seq), src_col);
    run;
    %do _mi = 1 %to &_mn;
        %let _st = ; %let _tt = ;
        %sqf_vartype(ds=&srcds, var=&&_map_s_&_mi, mvar=_st)
        %sqf_vartype(ds=SQFBASE.&target, var=&&_map_t_&_mi, mvar=_tt)
        %if %length(&_st) = 0 %then %do;
            %let SQF_VMSG = APPEND_ROWS mapped source column &&_map_s_&_mi not found in the source.;
            %sqf_verr(sev=E, scen=&scen, step=&step, field=ASSIGNMENTS)
        %end;
        %if %length(&_tt) = 0 %then %do;
            %let SQF_VMSG = APPEND_ROWS mapped target column &&_map_t_&_mi not found in target &target..;
            %sqf_verr(sev=E, scen=&scen, step=&step, field=ASSIGNMENTS)
        %end;
        %if %length(&_st) > 0 and %length(&_tt) > 0 and &_st ne &_tt %then %do;
            %let SQF_VMSG = APPEND_ROWS mapped column types differ (&&_map_t_&_mi is &_tt, &&_map_s_&_mi is &_st).;
            %sqf_verr(sev=E, scen=&scen, step=&step, field=ASSIGNMENTS)
        %end;
    %end;
%end;
/* unmapped source columns sharing a target name must type-match */
%let _svl = ;
%sqf_varlist(ds=&srcds, mvar=_svl)
%let _overlap = 0;
%let _k = 1;
%do %while (%length(%scan(&_svl, &_k)) > 0);
    %let _w = %upcase(%scan(&_svl, &_k));
    %let _tt = ;
    %sqf_vartype(ds=SQFBASE.&target, var=&_w, mvar=_tt)
    %if %length(&_tt) > 0 %then %do;
        %let _overlap = 1;
        %let _st = ;
        %sqf_vartype(ds=&srcds, var=&_w, mvar=_st)
        %if &_st ne &_tt %then %do;
            %let SQF_VMSG = APPEND_ROWS column &_w is type &_tt in the target but &_st in the source.;
            %sqf_verr(sev=E, scen=&scen, step=&step, field=SOURCE)
        %end;
    %end;
    %let _k = %eval(&_k + 1);
%end;
%if &_mn = 0 and &_overlap = 0 %then %do;
    %let SQF_VMSG = APPEND_ROWS: the source shares no column names with &target and no mapping is given%str(;) appended rows would be entirely missing. Map columns in ASSIGNMENTS.;
    %sqf_verr(sev=E, scen=&scen, step=&step, field=ASSIGNMENTS)
%end;
%mend sqf_check_append;

/* Print all findings; sets SQF_NERR / SQF_NWARN globals */
%macro sqf_validate_report();
%global SQF_NERR SQF_NWARN;
%let SQF_NERR = 0;
%let SQF_NWARN = 0;
proc sql noprint;
    select coalesce(sum(sev='E'),0), coalesce(sum(sev in ('W','N')),0)
        into :SQF_NERR trimmed, :SQF_NWARN trimmed
        from work._sqf_verrors;
quit;
%if &SQF_NERR > 0 or &SQF_NWARN > 0 %then %do;
    title "[SQF] Validation findings (E blocks the run)";
    proc print data=work._sqf_verrors noobs;
        var sev scenario step field message;
    run;
    title;
    data _null_;
        length _line $600;
        set work._sqf_verrors;
        _line = catx(' ', ifc(sev='E', 'ERROR: [SQF]', 'WARNING: [SQF]'),
                     'scenario', scenario, 'step', put(step, best8.-l),
                     'field', field, ':', message);
        put _line;
    run;
%end;
%mend sqf_validate_report;
/*------------------------------------------------------------------
  05. CODE GENERATION + STEP MACHINERY
      The generated file is OPEN CODE and 100% literal: user cell text
      is emitted verbatim (parameters already substituted as literals).
      Framework macro CALLS in the generated file carry only validated
      names and numbers - never user text.

      NOTE ON STRING LITERALS: inside a macro body, macro triggers are
      live even in single-quoted strings, so every emitted percent sign
      is built from the '25'x character (variable _pct below). Code
      lines are assembled with || and strip() because catt/catx would
      strip the deliberate spacing out of code fragments.
------------------------------------------------------------------*/

/* Stop the rest of the generated include after a failed step.
   Belt and braces: OBS=0 NOREPLACE neuters any statements that might
   still slip through if ABORT CANCEL FILE is unavailable; options are
   restored by the orchestrator exit path.                              */
%macro sqf_guard();
%if &SQF_STOP = 1 %then %do;
    options obs=0 noreplace;
    data _null_;
        abort cancel file;
    run;
%end;
%mend sqf_guard;

%macro sqf_step_begin(exec=, step=, method=, target=, origin=);
%put NOTE: [SQF] STEP &step BEGIN method=&method target=&target;
data work._sqf_rl_new;
    length exec 8 step 8 origin $32 method $16 target $32 phase $1
           dt 8 aff 8 status $12;
    exec = &exec; step = &step; origin = "&origin"; method = "&method";
    target = "&target"; phase = 'B'; dt = datetime(); aff = .; status = ' ';
    format dt datetime20.;
run;
proc append base=work._sqf_runlog data=work._sqf_rl_new force; run;
proc datasets lib=work nolist nowarn; delete _sqf_rl_new; quit;
%mend sqf_step_begin;

/* mode: CNT | FILTER | APPEND | REPLACE | CUSTOM
   from/to: lib.member literals (validated names) used for pre/post    */
%macro sqf_step_end(exec=, step=, method=, target=, mode=, from=, to=,
                    nowarn0=0, dry=0);
%local _aff _pre _post _stat _cn;
%let _aff = .;
%let _stat = OK;
%if &syscc > 4 %then %do;
    %let _stat = FAILED;
    %let SQF_STOP = 1;
    %let SQF_FAIL_STEP = &step;
    %put ERROR: [SQF] STEP &step FAILED (method=&method target=&target syscc=&syscc). Stopping the scenario apply.;
%end;
%else %do;
    %if &mode = CNT %then %do;
        %let _aff = 0;
        %if %sysfunc(exist(work._sqf_cnt)) %then %do;
            %let _cn = 0;
            %sqf_nobs(ds=work._sqf_cnt, mvar=_cn)
            %if &_cn > 0 %then %do;
                data _null_;
                    set work._sqf_cnt;
                    call symputx('_aff', coalesce(_sqf_aff, 0));
                run;
            %end;
        %end;
    %end;
    %else %if &mode = FILTER or &mode = APPEND or &mode = REPLACE %then %do;
        %let _pre = .;
        %let _post = .;
        %if %sysfunc(exist(work._sqf_pre)) %then %do;
            data _null_;
                set work._sqf_pre;
                call symputx('_pre', n);
            run;
        %end;
        %sqf_nobs(ds=&to, mvar=_post)
        %if &mode = FILTER %then %do;
            %if &_pre ne . and &_post ne . %then %let _aff = %eval(&_pre - &_post);
        %end;
        %else %if &mode = APPEND %then %do;
            %if &_pre ne . and &_post ne . %then %let _aff = %eval(&_post - &_pre);
        %end;
        %else %let _aff = &_post;
    %end;
    /* zero-effect warning (not for dry runs) */
    %if &dry = 0 and &nowarn0 = 0 and &_aff = 0
        and %sysfunc(indexw(CNT FILTER APPEND, &mode)) %then %do;
        %put WARNING: [SQF] STEP &step (&method on &target) affected 0 rows. Check the WHERE_CLAUSE / keys. Add NOWARN0 to OPTIONS to silence this.;
    %end;
%end;
data work._sqf_rl_new;
    length exec 8 step 8 origin $32 method $16 target $32 phase $1
           dt 8 aff 8 status $12;
    exec = &exec; step = &step; origin = ' '; method = "&method";
    target = "&target"; phase = 'E'; dt = datetime(); aff = &_aff;
    status = "&_stat";
    format dt datetime20.;
run;
proc append base=work._sqf_runlog data=work._sqf_rl_new force; run;
proc datasets lib=work nolist nowarn;
    delete _sqf_cnt _sqf_pre _sqf_rl_new;
quit;
%put NOTE: [SQF] STEP &step END status=&_stat rows=&_aff;
%mend sqf_step_end;

%macro sqf_step_skip(exec=, step=, method=, target=, reason=);
%put NOTE: [SQF] STEP &step SKIPPED (&reason) method=&method target=&target;
data work._sqf_rl_new;
    length exec 8 step 8 origin $32 method $16 target $32 phase $1
           dt 8 aff 8 status $12;
    exec = &exec; step = &step; origin = ' '; method = "&method";
    target = "&target"; phase = 'E'; dt = datetime(); aff = .;
    status = "SKIP_&reason";
    format dt datetime20.;
run;
proc append base=work._sqf_runlog data=work._sqf_rl_new force; run;
proc datasets lib=work nolist nowarn; delete _sqf_rl_new; quit;
%mend sqf_step_skip;

/* Dry-run new/changed-column check after a SET_VALUES sandbox step   */
%macro sqf_dry_cols(exec=, step=, origin=, tab=, baseds=, newcols=0);
%local _bvl _svl _k _w _bt _st2;
%let _bvl = ; %let _svl = ;
%sqf_varlist(ds=&baseds, mvar=_bvl)
%sqf_varlist(ds=&tab,    mvar=_svl)
%let _bvl = %upcase(&_bvl);
%let _k = 1;
%do %while (%length(%scan(&_svl, &_k)) > 0);
    %let _w = %upcase(%scan(&_svl, &_k));
    %if not %sysfunc(indexw(&_bvl, &_w)) %then %do;
        %if &newcols = 0 %then %do;
            %let SQF_VMSG = SET_VALUES creates a new column &_w on this table. If intended, add NEWCOLS to OPTIONS%str(;) otherwise fix the column name (typo?).;
            %sqf_verr(sev=E, scen=&origin, step=&step, field=ASSIGNMENTS)
        %end;
    %end;
    %else %do;
        %let _bt = ; %let _st2 = ;
        %sqf_vartype(ds=&baseds, var=&_w, mvar=_bt)
        %sqf_vartype(ds=&tab,    var=&_w, mvar=_st2)
        %if &_bt ne &_st2 %then %do;
            %let SQF_VMSG = SET_VALUES changes the TYPE of column &_w (&_bt to &_st2). That would corrupt downstream logic.;
            %sqf_verr(sev=E, scen=&origin, step=&step, field=ASSIGNMENTS)
        %end;
    %end;
    %let _k = %eval(&_k + 1);
%end;
%mend sqf_dry_cols;

/* -------------------------------------------------------------------
   THE GENERATOR.
   Emits &file from work._sqf_steps_p / work._sqf_maps.
   dryrun=1 : remap to obs=0 WORK sandboxes, skip CUSTOM/PREV steps,
              add %sqf_dry_cols checks after SET_VALUES steps.
   Requires (before calling, both modes): SQFBASE assigned; SQFS<nn>
   assigned for RUN: sources; SQFPREV assigned when iter >= 2.
------------------------------------------------------------------- */
%macro sqf_gen_apply(file=, dryrun=0, iter=1, chain=0, scenario=, runid=);
%local _scup;
%let _scup = %upcase(&scenario);
data _null_;
    file "%sqf_norm_path(&file)" lrecl=32767;
    length _l $32767 _pct $1 _cfr $8;
    retain _pct;
    _pct = '25'x;                       /* the percent character        */
    /* member registry: index -> sandbox naming + staged flag */
    array _mems  {200} $32 _temporary_;
    array _stag  {200} 8   _temporary_;
    retain _mn 0;

    if _n_ = 1 then do;
        _l = "/*==================================================================="; link pl;
        _l = "  GENERATED BY SQF &SQF_VERSION -- DO NOT EDIT (regenerated every run)"; link pl;
        _l = "  scenario=&_scup  run=&runid  iteration=&iter  dryrun=&dryrun"; link pl;
        _l = "  control_hash=&SQF_CONTROL_HASH"; link pl;
        _l = "  This file is fully literal: parameter values are already substituted."; link pl;
        _l = "===================================================================*/"; link pl;
        _l = ' '; link pl;
        _l = _pct || 'put NOTE: [SQF] ' || strip(ifc(&dryrun=1, 'DRYRUN', 'APPLY'))
             || " start scenario=&_scup iter=&iter;"; link pl;
        _l = ' '; link pl;

        /* ---- dry-run prologue: obs=0 sandboxes ---- */
        if &dryrun = 1 then do;
            _l = '/*---- dry-run sandboxes (structure only, obs=0) ----*/'; link pl;
            do _pp = 1 to _pn;
                set work._sqf_steps_p(keep=method target_table src_kind src_member
                                           exec_order active opt_iters
                                      rename=(method=_px_meth target_table=_px_tgt
                                              src_kind=_px_sk src_member=_px_sm
                                              exec_order=_px_ex active=_px_act
                                              opt_iters=_px_it)) point=_pp nobs=_pn;
                /* targets read from base */
                if _px_act = 'Y' and _px_meth ne 'CUSTOM_CODE' and _px_tgt ne ' ' then do;
                    _rm_mem = _px_tgt; link regmem;
                    if _stag{_rm_idx} = . then do;
                        _stag{_rm_idx} = 0;
                        _l = 'data work._sqvb' || put(_rm_idx, z3.) || '_'
                             || strip(substr(_px_tgt, 1, 19))
                             || '; set SQFBASE.' || strip(_px_tgt) || '(obs=0); run;'; link pl;
                    end;
                end;
                /* BASE: sources */
                if _px_act = 'Y' and _px_sk = 'BASE' then do;
                    _rm_mem = _px_sm; link regmem;
                    if _stag{_rm_idx} = . then do;
                        _stag{_rm_idx} = 0;
                        _l = 'data work._sqvb' || put(_rm_idx, z3.) || '_'
                             || strip(substr(_px_sm, 1, 19))
                             || '; set SQFBASE.' || strip(_px_sm) || '(obs=0); run;'; link pl;
                    end;
                end;
                /* RUN: sources -> sandbox from the pre-assigned SQFS libref */
                if _px_act = 'Y' and _px_sk = 'RUN' then do;
                    _l = 'data work._sqvr' || put(_px_ex, z2.) || '_'
                         || strip(substr(_px_sm, 1, 19))
                         || '; set SQFS' || put(_px_ex, z2.) || '.' || strip(_px_sm)
                         || '(obs=0); run;'; link pl;
                end;
            end;
            /* reset staged flags for the main pass */
            do _pp = 1 to 200;
                if _mems{_pp} ne ' ' then _stag{_pp} = 0;
            end;
            _l = ' '; link pl;
        end;
    end;

    set work._sqf_steps_p end=_eof;
    length _from _to _cur _src _schsrc $80 _reason $16 _w2 $32 _sx $8;
    length _klist _dlist _qk _qd _drops _keeps _rens _msrc _mtgt _asn2 _asn3
           _dsopt $8000 _cols $32767 _cfile $500;

    _sx = strip(put(exec_order, best8.));      /* exec as text  */
    length _sn $8;
    _sn = strip(put(step_no, best8.));         /* step as text  */

    /* ---------- skip decisions ---------- */
    _reason = ' ';
    if active ne 'Y' then _reason = 'INACTIVE';
    else if opt_iters = '1' and &iter > 1 then _reason = 'ITERS';
    else if opt_iters = '2+' and &iter = 1 then _reason = 'ITERS';
    else if opt_iters = '2+' and &chain = 0 then _reason = 'ITERS';
    else if src_kind = 'PREV' and &dryrun = 1 then _reason = 'DRYRUN_PREV';
    else if method = 'CUSTOM_CODE' and &dryrun = 1 then _reason = 'DRYRUN_CUSTOM';

    _l = '/*==================================================================*/'; link pl;
    _l = '/*=== STEP ' || _sn || ' (' || strip(origin_scenario) || ') ' || strip(method)
         || ' target=' || strip(coalescec(target_table, 'NONE'))
         || ' exec=' || _sx || ' ===*/'; link pl;

    if _reason ne ' ' then do;
        _l = _pct || 'sqf_step_skip(exec=' || _sx || ', step=' || _sn
             || ', method=' || strip(method)
             || ', target=' || strip(coalescec(target_table, 'NONE'))
             || ', reason=' || strip(_reason) || ')'; link pl;
        /* a skipped CUSTOM step may declare a target that later SCEN:
           steps read; approximate its staged copy with the base schema
           so the rest of the dry run remains checkable                 */
        if _reason = 'DRYRUN_CUSTOM' and target_table ne ' ' then do;
            _rm_mem = target_table; link regmem;
            _l = 'data work._sqvs' || put(_rm_idx, z3.) || '_'
                 || strip(substr(target_table, 1, 19))
                 || '; set SQFBASE.' || strip(target_table) || '(obs=0); run;'; link pl;
            _stag{_rm_idx} = 1;
        end;
        _l = ' '; link pl;
        if _eof then link epilog;
        return;
    end;

    _l = _pct || 'sqf_guard'; link pl;
    _l = _pct || 'sqf_step_begin(exec=' || _sx || ', step=' || _sn
         || ', method=' || strip(method)
         || ', target=' || strip(coalescec(target_table, 'NONE'))
         || ', origin=' || strip(origin_scenario) || ')'; link pl;

    /* ---------- resolve from / to / cur names ---------- */
    if method ne 'CUSTOM_CODE' then do;
        _rm_mem = target_table; link regmem;
        if &dryrun = 1 then do;
            _to = 'work._sqvs' || put(_rm_idx, z3.) || '_' || strip(substr(target_table, 1, 19));
            if _stag{_rm_idx} = 1 then _from = _to;
            else _from = 'work._sqvb' || put(_rm_idx, z3.) || '_' || strip(substr(target_table, 1, 19));
        end;
        else do;
            _to = 'SQFIN.' || strip(target_table);
            if _stag{_rm_idx} = 1 then _from = _to;
            else _from = 'SQFBASE.' || strip(target_table);
        end;
        _cur = _from;   /* current resolved location before this step */
    end;

    /* ---------- resolve source names ----------
       _src    = dataset read by the generated code
       _schsrc = dataset whose SCHEMA is inspected at generation time  */
    _src = ' '; _schsrc = ' ';
    if src_kind = 'BASE' then do;
        if &dryrun = 1 then do;
            _rm_mem = src_member; link regmem;
            _src = 'work._sqvb' || put(_rm_idx, z3.) || '_' || strip(substr(src_member, 1, 19));
        end;
        else _src = 'SQFBASE.' || strip(src_member);
        _schsrc = 'SQFBASE.' || strip(src_member);
    end;
    else if src_kind = 'SCEN' then do;
        _rm_mem = src_member; link regmem;
        if &dryrun = 1 then
            _src = 'work._sqvs' || put(_rm_idx, z3.) || '_' || strip(substr(src_member, 1, 19));
        else _src = 'SQFIN.' || strip(src_member);
        _schsrc = 'SQFBASE.' || strip(src_member);
    end;
    else if src_kind = 'RUN' then do;
        if &dryrun = 1 then
            _src = 'work._sqvr' || put(exec_order, z2.) || '_' || strip(substr(src_member, 1, 19));
        else _src = 'SQFS' || put(exec_order, z2.) || '.' || strip(src_member);
        _schsrc = 'SQFS' || put(exec_order, z2.) || '.' || strip(src_member);
    end;
    else if src_kind = 'PREV' then do;
        _src = 'SQFPREV.' || strip(src_member);
        _schsrc = _src;
    end;

    /* ---------- pre-capture for delta counting ---------- */
    if method in ('FILTER_ROWS','APPEND_ROWS','REPLACE_TABLE','COPY_TABLE') then do;
        _l = 'data work._sqf_pre(keep=n); if 0 then set ' || strip(_cur)
             || ' nobs=_sqf_n; n = _sqf_n; output; stop; run;'; link pl;
    end;

    /* terminal semicolon for verbatim assignment blocks */
    _asn3 = strip(assignments);
    if _asn3 ne ' ' then do;
        if substr(_asn3, lengthn(_asn3), 1) ne ';' then _asn3 = strip(_asn3) || ';';
    end;

    /* =========================== SET_VALUES =========================== */
    if method = 'SET_VALUES' then do;
        if has_where = 0 then do;
            _l = 'data ' || strip(_to) || '(drop=_sqf_aff) work._sqf_cnt(keep=_sqf_aff);'; link pl;
            _l = '    set ' || strip(_from) || ' end=_sqf_eof;'; link pl;
            _l = '    ' || strip(_asn3); link pl;
            _l = '    _sqf_aff + 1;'; link pl;
            _l = '    output ' || strip(_to) || ';'; link pl;
            _l = '    if _sqf_eof then output work._sqf_cnt;'; link pl;
            _l = 'run;'; link pl;
        end;
        else if where_ops = 'N' then do;
            /* IF-safe single pass */
            _l = 'data ' || strip(_to) || '(drop=_sqf_aff) work._sqf_cnt(keep=_sqf_aff);'; link pl;
            _l = '    set ' || strip(_from) || ' end=_sqf_eof;'; link pl;
            _l = '    if (' || strip(where_clause) || ') then do;'; link pl;
            _l = '        ' || strip(_asn3); link pl;
            _l = '        _sqf_aff + 1;'; link pl;
            _l = '    end;'; link pl;
            _l = '    output ' || strip(_to) || ';'; link pl;
            _l = '    if _sqf_eof then output work._sqf_cnt;'; link pl;
            _l = 'run;'; link pl;
        end;
        else do;
            /* WHERE-only operators: order-preserving split */
            _l = 'data work._sqf_all; set ' || strip(_from) || '; _sqf_seq_ = _n_; run;'; link pl;
            _l = 'data work._sqf_m;'; link pl;
            _l = '    set work._sqf_all;'; link pl;
            _l = '    where (' || strip(where_clause) || ');'; link pl;
            _l = '    ' || strip(_asn3); link pl;
            _l = 'run;'; link pl;
            _l = 'data work._sqf_u;'; link pl;
            _l = '    set work._sqf_all;'; link pl;
            _l = '    where not (' || strip(where_clause) || ');'; link pl;
            _l = 'run;'; link pl;
            _l = 'data ' || strip(_to) || '(drop=_sqf_seq_);'; link pl;
            _l = '    set work._sqf_m work._sqf_u;'; link pl;
            _l = '    by _sqf_seq_;'; link pl;
            _l = 'run;'; link pl;
            _l = 'data work._sqf_cnt(keep=_sqf_aff);'; link pl;
            _l = '    if 0 then set work._sqf_m nobs=_sqf_mn;'; link pl;
            _l = '    _sqf_aff = _sqf_mn; output; stop;'; link pl;
            _l = 'run;'; link pl;
            _l = 'proc datasets lib=work nolist nowarn; delete _sqf_all _sqf_m _sqf_u; quit;'; link pl;
        end;
        if &dryrun = 1 then do;
            _l = _pct || 'sqf_dry_cols(exec=' || _sx || ', step=' || _sn
                 || ', origin=' || strip(origin_scenario)
                 || ', tab=' || strip(_to)
                 || ', baseds=SQFBASE.' || strip(target_table)
                 || ', newcols=' || put(opt_newcols, 1.) || ')'; link pl;
        end;
        _l = _pct || 'sqf_step_end(exec=' || _sx || ', step=' || _sn
             || ', method=' || strip(method) || ', target=' || strip(target_table)
             || ', mode=CNT, from=' || strip(_from) || ', to=' || strip(_to)
             || ', nowarn0=' || put(opt_nowarn0, 1.) || ', dry=' || "&dryrun" || ')'; link pl;
    end;

    /* =========================== FILTER_ROWS ========================== */
    else if method = 'FILTER_ROWS' then do;
        _l = 'data ' || strip(_to) || ';'; link pl;
        _l = '    set ' || strip(_from) || ';'; link pl;
        if opt_drop = 1 then do;
            _l = '    where not (' || strip(where_clause) || ');'; link pl;
        end;
        else do;
            _l = '    where (' || strip(where_clause) || ');'; link pl;
        end;
        _l = 'run;'; link pl;
        _l = _pct || 'sqf_step_end(exec=' || _sx || ', step=' || _sn
             || ', method=' || strip(method) || ', target=' || strip(target_table)
             || ', mode=FILTER, from=' || strip(_from) || ', to=' || strip(_to)
             || ', nowarn0=' || put(opt_nowarn0, 1.) || ', dry=' || "&dryrun" || ')'; link pl;
    end;

    /* =========================== COPY_TABLE =========================== */
    else if method = 'COPY_TABLE' then do;
        if &dryrun = 1 then do;
            _l = 'data ' || strip(_to) || '; set work._sqvb' || put(_rm_idx, z3.) || '_'
                 || strip(substr(target_table, 1, 19)) || '(obs=0); run;'; link pl;
        end;
        else do;
            /* always a fresh copy of BASE (also acts as a reset) */
            _l = 'proc copy in=SQFBASE out=SQFIN memtype=data;'; link pl;
            _l = '    select ' || strip(target_table) || ';'; link pl;
            _l = 'run;'; link pl;
        end;
        _l = _pct || 'sqf_step_end(exec=' || _sx || ', step=' || _sn
             || ', method=' || strip(method) || ', target=' || strip(target_table)
             || ', mode=REPLACE, from=' || strip(_from) || ', to=' || strip(_to)
             || ', nowarn0=1, dry=' || "&dryrun" || ')'; link pl;
    end;

    /* =========================== APPEND_ROWS ========================== */
    else if method = 'APPEND_ROWS' then do;
        /* stage the (filtered) source with all its columns available   */
        _l = 'data work._sqf_app;'; link pl;
        _l = '    set ' || strip(_src) || ';'; link pl;
        if has_where = 1 then do;
            _l = '    where (' || strip(where_clause) || ');'; link pl;
        end;
        _l = 'run;'; link pl;
        link app_lists;
        _dsopt = catx(' ', _keeps, _rens);
        _l = 'data ' || strip(_to) || ';'; link pl;
        _l = '    set ' || strip(_from); link pl;
        if _dsopt ne ' ' then do;
            _l = '        work._sqf_app(' || strip(_dsopt) || ');'; link pl;
        end;
        else do;
            _l = '        work._sqf_app;'; link pl;
        end;
        _l = 'run;'; link pl;
        _l = 'proc datasets lib=work nolist nowarn; delete _sqf_app; quit;'; link pl;
        _l = _pct || 'sqf_step_end(exec=' || _sx || ', step=' || _sn
             || ', method=' || strip(method) || ', target=' || strip(target_table)
             || ', mode=APPEND, from=' || strip(_from) || ', to=' || strip(_to)
             || ', nowarn0=' || put(opt_nowarn0, 1.) || ', dry=' || "&dryrun" || ')'; link pl;
    end;

    /* ========================== REPLACE_TABLE ========================= */
    else if method = 'REPLACE_TABLE' then do;
        link rep_lists;
        _l = 'data ' || strip(_to) || ';'; link pl;
        _l = '    retain ' || strip(_cols) || ';'; link pl;
        if _rens ne ' ' then do;
            _l = '    set ' || strip(_src) || '(' || strip(_rens) || ');'; link pl;
        end;
        else do;
            _l = '    set ' || strip(_src) || ';'; link pl;
        end;
        if opt_keepextra = 0 then do;
            _l = '    keep ' || strip(_cols) || ';'; link pl;
        end;
        _l = 'run;'; link pl;
        _l = _pct || 'sqf_step_end(exec=' || _sx || ', step=' || _sn
             || ', method=' || strip(method) || ', target=' || strip(target_table)
             || ', mode=REPLACE, from=' || strip(_from) || ', to=' || strip(_to)
             || ', nowarn0=1, dry=' || "&dryrun" || ')'; link pl;
    end;

    /* ========================== UPDATE_FROM =========================== */
    else if method = 'UPDATE_FROM' then do;
        link upd_lists;
        /* in DRY RUNS the hash loads the REAL source (a pure read that
           happens before anything is staged): duplicate:'e' then
           rejects duplicate source keys at validation time             */
        length _hsrc $80;
        if &dryrun = 1 and src_kind ne 'PREV' then _hsrc = _schsrc;
        else _hsrc = _src;
        _l = 'data ' || strip(_to) || '(drop=_sqf_rc _sqf_aff' || trimn(_drops)
             || ') work._sqf_cnt(keep=_sqf_aff);'; link pl;
        /* declare the TARGET first so shared columns keep the target
           attributes (length/format), then add source-only host vars  */
        _l = '    if 0 then set ' || strip(_from) || ';'; link pl;
        _l = '    if 0 then set ' || strip(_src) || '(keep=' || strip(_klist) || ' '
             || strip(_dlist) || ');'; link pl;
        _l = '    if _n_ = 1 then do;'; link pl;
        _l = '        declare hash _sqf_h(dataset:"' || strip(_hsrc) || '(keep='
             || strip(_klist) || ' ' || strip(_dlist) || ')", duplicate:' || "'e');"; link pl;
        _l = '        _sqf_h.definekey(' || strip(_qk) || ');'; link pl;
        _l = '        _sqf_h.definedata(' || strip(_qd) || ');'; link pl;
        _l = '        _sqf_h.definedone();'; link pl;
        _l = '    end;'; link pl;
        _l = '    set ' || strip(_from) || ' end=_sqf_eof;'; link pl;
        if has_where = 1 then do;
            _l = '    if (' || strip(where_clause) || ') then do;'; link pl;
        end;
        _l = '    _sqf_rc = _sqf_h.find();'; link pl;
        _l = '    if _sqf_rc = 0 then do;'; link pl;
        if _asn2 ne ' ' then do;
            _l = '        ' || strip(_asn2); link pl;
        end;
        _l = '        _sqf_aff + 1;'; link pl;
        _l = '    end;'; link pl;
        if has_where = 1 then do;
            _l = '    end;'; link pl;
        end;
        _l = '    output ' || strip(_to) || ';'; link pl;
        _l = '    if _sqf_eof then output work._sqf_cnt;'; link pl;
        _l = 'run;'; link pl;
        _l = _pct || 'sqf_step_end(exec=' || _sx || ', step=' || _sn
             || ', method=' || strip(method) || ', target=' || strip(target_table)
             || ', mode=CNT, from=' || strip(_from) || ', to=' || strip(_to)
             || ', nowarn0=' || put(opt_nowarn0, 1.) || ', dry=' || "&dryrun" || ')'; link pl;
    end;

    /* ========================== CUSTOM_CODE =========================== */
    else if method = 'CUSTOM_CODE' then do;
        _cfile = translate(src_path, '/', '\');
        if not (substr(_cfile, 1, 1) = '/' or index(_cfile, ':') = 2)
            then _cfile = catx('/', "%sqf_norm_path(&SQF_ROOT)/custom", _cfile);
        _l = '/*---- CUSTOM_CODE inlined from: ' || strip(_cfile) || ' ----*/'; link pl;
        _l = '/*---- contract macro vars: SQF_SCENLIB SQF_BASELIB SQF_RUNDIR SQF_ITER'; link pl;
        _l = '      SQF_SCENARIO SQF_RUN_ID + all PARAMETERS ----*/'; link pl;
        link inline_file;
        _l = '/*---- end CUSTOM_CODE ----*/'; link pl;
        _l = _pct || 'sqf_step_end(exec=' || _sx || ', step=' || _sn
             || ', method=' || strip(method)
             || ', target=' || strip(coalescec(target_table, 'NONE'))
             || ', mode=CUSTOM, from=NONE, to=NONE, nowarn0=1, dry=' || "&dryrun" || ')'; link pl;
    end;

    _l = ' '; link pl;
    if target_table ne ' ' then do;
        _rm_mem = target_table; link regmem;
        _stag{_rm_idx} = 1;             /* target now staged            */
    end;
    if _eof then link epilog;
return;

    /* ---------------- link routines ---------------- */
  pl:
    _ll = lengthn(_l);
    if _ll = 0 then put;
    else put _l $varying32767. _ll;
  return;

  regmem: /* member name -> stable index in the registry arrays */
    _rm_idx = 0;
    do _rj = 1 to _mn while (_rm_idx = 0);
        if _mems{_rj} = _rm_mem then _rm_idx = _rj;
    end;
    if _rm_idx = 0 then do;
        _mn + 1;
        _mems{_mn} = _rm_mem;
        _stag{_mn} = .;
        _rm_idx = _mn;
    end;
  return;

  inline_file: /* inline the CUSTOM snippet via fread/fget (safe on
                  empty files, cannot terminate this data step)         */
    _cfr = ' ';
    _crc = filename(_cfr, strip(_cfile));
    _cfid = fopen(_cfr, 'i', 32767, 'V');
    if _cfid <= 0 then do;
        _l = '/* [SQF] could not open the snippet file at generation time */'; link pl;
    end;
    else do;
        do while (fread(_cfid) = 0);
            _l = ' ';
            _crc = fget(_cfid, _l, 32767);
            link pl;
        end;
        _crc = fclose(_cfid);
    end;
    _crc = filename(_cfr);
  return;

  app_lists: /* APPEND: keep + rename lists (old names, applied together) */
    _keeps = ' '; _rens = ' '; _msrc = ' '; _mtgt = ' ';
    _tid = open('SQFBASE.' || strip(target_table), 'i');
    _sid = open(strip(_schsrc), 'i');
    if _tid > 0 and _sid > 0 then do;
        /* mapped pairs first */
        do _mp = 1 to _mtot;
            set work._sqf_maps(rename=(exec_order=_mx_ex step_no=_mx_st
                               origin_scenario=_mx_or)) point=_mp nobs=_mtot;
            if _mx_ex = exec_order then do;
                _keeps = catx(' ', _keeps, src_col);
                _msrc  = catx(' ', _msrc, upcase(src_col));
                _mtgt  = catx(' ', _mtgt, upcase(tgt_col));
                _rens  = catx(' ', _rens, strip(src_col) || '=' || strip(tgt_col));
            end;
        end;
        /* same-named source columns that exist in the target, minus
           anything already mapped (as source or as rename-target)      */
        do _sv = 1 to attrn(_sid, 'nvars');
            _w2 = upcase(varname(_sid, _sv));
            if varnum(_tid, _w2) > 0
               and indexw(_msrc, _w2) = 0
               and indexw(_mtgt, _w2) = 0 then
                _keeps = catx(' ', _keeps, _w2);
        end;
    end;
    if _tid > 0 then _tid = close(_tid);
    if _sid > 0 then _sid = close(_sid);
    if strip(_keeps) ne ' ' then _keeps = 'keep=' || strip(_keeps);
    else _keeps = ' ';
    if strip(_rens) ne ' ' then _rens = 'rename=(' || strip(_rens) || ')';
    else _rens = ' ';
  return;

  rep_lists: /* REPLACE: base column order + rename map               */
    _cols = ' '; _rens = ' ';
    _tid = open('SQFBASE.' || strip(target_table), 'i');
    if _tid > 0 then do;
        do _sv = 1 to attrn(_tid, 'nvars');
            _cols = catx(' ', _cols, varname(_tid, _sv));
        end;
        _tid = close(_tid);
    end;
    do _mp = 1 to _mtot;
        set work._sqf_maps(rename=(exec_order=_mx_ex step_no=_mx_st
                           origin_scenario=_mx_or)) point=_mp nobs=_mtot;
        if _mx_ex = exec_order then
            _rens = catx(' ', _rens, strip(src_col) || '=' || strip(tgt_col));
    end;
    if strip(_rens) ne ' ' then _rens = 'rename=(' || strip(_rens) || ')';
    else _rens = ' ';
  return;

  upd_lists: /* UPDATE_FROM: key list, data list, drops, assignments  */
    _klist = compbl(key_vars);
    _dlist = ' '; _drops = ' '; _asn2 = ' '; _qk = ' '; _qd = ' ';
    do _kk = 1 to countw(_klist, ' ');
        _qk = catx(',', _qk, "'" || strip(scan(_klist, _kk, ' ')) || "'");
    end;
    _tid = open('SQFBASE.' || strip(target_table), 'i');
    _sid = open(strip(_schsrc), 'i');
    if _tid > 0 and _sid > 0 then do;
        /* mapped pairs: data cols + explicit assignments               */
        do _mp = 1 to _mtot;
            set work._sqf_maps(rename=(exec_order=_mx_ex step_no=_mx_st
                               origin_scenario=_mx_or)) point=_mp nobs=_mtot;
            if _mx_ex = exec_order then do;
                if indexw(upcase(_dlist), upcase(src_col)) = 0 then do;
                    _dlist = catx(' ', _dlist, src_col);
                    _qd = catx(',', _qd, "'" || strip(src_col) || "'");
                end;
                if upcase(src_col) ne upcase(tgt_col) then do;
                    _asn2 = catx(' ', _asn2, strip(tgt_col) || ' = ' || strip(src_col) || ';');
                    /* source-only host var: drop it from the output    */
                    if varnum(_tid, upcase(src_col)) = 0
                       and indexw(upcase(_drops), upcase(src_col)) = 0 then
                        _drops = catx(' ', _drops, src_col);
                end;
            end;
        end;
        /* same-named non-key source columns present in the target      */
        do _sv = 1 to attrn(_sid, 'nvars');
            _w2 = upcase(varname(_sid, _sv));
            if indexw(upcase(_klist), _w2) = 0
               and varnum(_tid, _w2) > 0
               and indexw(upcase(_dlist), _w2) = 0 then do;
                _dlist = catx(' ', _dlist, _w2);
                _qd = catx(',', _qd, "'" || strip(_w2) || "'");
            end;
        end;
    end;
    if _tid > 0 then _tid = close(_tid);
    if _sid > 0 then _sid = close(_sid);
    if strip(_drops) ne ' ' then _drops = ' ' || strip(_drops);
    else _drops = ' ';
  return;

  epilog:
    _l = ' '; link pl;
    _l = _pct || 'put NOTE: [SQF] ' || strip(ifc(&dryrun=1, 'DRYRUN', 'APPLY'))
         || " complete scenario=&_scup iter=&iter;"; link pl;
  return;
run;
%mend sqf_gen_apply;
/*------------------------------------------------------------------
  06. EXECUTION
      %sqf_exec_include : run a file under PROC PRINTTO capture and
                          scan the captured log.
      %sqf_assign_srclibs / %sqf_clear_srclibs : SQFS<nn> librefs for
                          RUN: sources (paths come from validation's
                          work._sqf_runsrc).
      %sqf_set_contract  : macro variables promised to CUSTOM_CODE
                          snippets and chain drivers.
------------------------------------------------------------------*/

%macro sqf_exec_include(file=, log=, phase=);
%sqf_printto(log=&log)
%include "%sqf_norm_path(&file)" / source2 lrecl=32767;
/* a failed step's %sqf_guard belt sets OBS=0 NOREPLACE inside the
   include; re-establish framework options IMMEDIATELY so the log scan
   (an external-file read, also subject to OBS=) and everything after
   see the full picture                                                 */
options obs=max replace nosyntaxcheck;
%sqf_printto_off()
%sqf_log_scan(log=&log, phase=&phase)
%mend sqf_exec_include;

%macro sqf_assign_srclibs();
%local _rs_n _i _lr;
%global SQF_SRCLIBS;
%let SQF_SRCLIBS = ;
%let _rs_n = 0;
%if %sysfunc(exist(work._sqf_runsrc)) %then %do;
    data _null_;
        set work._sqf_runsrc end=_e;
        call symputx(cats('_rs_ex_',  _n_), exec_order);
        call symputx(cats('_rs_dir_', _n_), rundir);
        if _e then call symputx('_rs_n', _n_);
    run;
%end;
%do _i = 1 %to &_rs_n;
    %let _lr = SQFS%sysfunc(putn(&&_rs_ex_&_i, z2.));
    libname &_lr "%superq(_rs_dir_&_i)/outputs" access=readonly;
    %if %sysfunc(libref(&_lr)) = 0 %then %let SQF_SRCLIBS = &SQF_SRCLIBS &_lr;
    %else %put WARNING: [SQF] Could not assign source library &_lr;
%end;
%mend sqf_assign_srclibs;

%macro sqf_clear_srclibs();
%local _i _lr;
%if %symexist(SQF_SRCLIBS) %then %do;
    /* countw of an EMPTY value would collapse to countw() = zero
       arguments and error out - guard the common no-sources case      */
    %if %length(&SQF_SRCLIBS) > 0 %then %do;
        %do _i = 1 %to %sysfunc(countw(&SQF_SRCLIBS));
            %let _lr = %scan(&SQF_SRCLIBS, &_i);
            libname &_lr clear;
        %end;
    %end;
    %let SQF_SRCLIBS = ;
%end;
%mend sqf_clear_srclibs;

/* Contract for CUSTOM_CODE snippets (and general run context).
   Also surfaces every resolved PARAMETER as a global macro variable.  */
%macro sqf_set_contract(scenlib=, baselib=, rundir=, iter=, scenario=, runid=);
%let SQF_SCENLIB  = &scenlib;
%let SQF_BASELIB  = &baselib;
%let SQF_RUNDIR   = %sqf_norm_path(&rundir);
%let SQF_ITER     = &iter;
%let SQF_SCENARIO = %upcase(&scenario);
%let SQF_RUN_ID   = &runid;
%if %sysfunc(exist(work._sqf_params_x)) %then %do;
    data _null_;
        set work._sqf_params_x;
        /* reserved names (SQF- and SYS-prefixed) were rejected at
           validation, so this cannot clobber framework variables      */
        call symputx(name, value, 'G');
    run;
%end;
%mend sqf_set_contract;
/*------------------------------------------------------------------
  07. RUN REGISTRY + RUN_INFO
      Source of truth = run_info.sas7bdat inside each run folder.
      The central registry (registry/run_events.sas7bdat) is an
      append-only, best-effort INDEX used to resolve RUN: references;
      %rebuild_registry reconstructs it from the run folders.
------------------------------------------------------------------*/

%macro sqf_registry_init(root=);
%local _r;
%let _r = %sqf_norm_path(&root);
%sqf_mkdir(&_r/registry)
%if %sysfunc(libref(SQFREG)) ne 0 %then %do;
    libname SQFREG "&_r/registry";
%end;
%if %sysfunc(libref(SQFREG)) = 0 and not %sysfunc(exist(SQFREG.run_events)) %then %do;
    data SQFREG.run_events;
        length event_dt 8 run_id $64 scenario $32 event $20 phase $12 step 8
               run_dir $300 control_hash $32 sysuser $40 note $200;
        format event_dt datetime20.;
        call missing(of _all_);
        stop;
    run;
%end;
%mend sqf_registry_init;

/* Append one event row (best effort - a lock failure never kills the
   run, because run_info in the run folder is the durable record).     */
%macro sqf_register_event(run_id=, scenario=, event=, phase=, step=.,
                          run_dir=, note=);
%local _try _got _rc _svcc;
%let _svcc = &syscc;   /* the registry is best effort: a LOCK/append
                          error here must never fail the run itself   */
%if %sysfunc(libref(SQFREG)) ne 0 %then %do;
    %put WARNING: [SQF] Registry library not assigned%str(;) event &event not recorded (run_info still written).;
    %return;
%end;
data work._sqf_ev1;
    length event_dt 8 run_id $64 scenario $32 event $20 phase $12 step 8
           run_dir $300 control_hash $32 sysuser $40 note $200;
    format event_dt datetime20.;
    event_dt = datetime();
    run_id = "&run_id"; scenario = "%upcase(&scenario)"; event = "&event";
    phase = "&phase"; step = &step;
    run_dir = symget('SQF_LAST_RUN_DIR');
    %if %length(&run_dir) > 0 %then %do;
        run_dir = "%sqf_norm_path(&run_dir)";
    %end;
    control_hash = symget('SQF_CONTROL_HASH');
    sysuser = "&sysuserid";
    note = "&note";
run;
%let _try = 0;
%let _got = 0;
%do %while (&_try < 5 and &_got = 0);
    lock SQFREG.run_events;
    %if &syslckrc = 0 %then %let _got = 1;
    %else %do;
        %let _rc = %sysfunc(sleep(2, 1));
        %let _try = %eval(&_try + 1);
    %end;
%end;
proc append base=SQFREG.run_events data=work._sqf_ev1 force; run;
%if &_got = 1 %then %do;
    lock SQFREG.run_events clear;
%end;
%else %put WARNING: [SQF] Could not lock the registry%str(;) event append was attempted anyway. Run %nrstr(%rebuild_registry)() if the index looks incomplete.;
proc datasets lib=work nolist nowarn; delete _sqf_ev1; quit;
%let syscc = &_svcc;
%mend sqf_register_event;

/* Single-row durable record inside the run folder                     */
%macro sqf_write_runinfo(rundir=, run_id=, scenario=, mode=, status=,
                         fail_phase=, fail_step=., iterations=1, iter_done=0,
                         start_dt=, inlib=, outlib=);
%local _d;
%let _d = %sqf_norm_path(&rundir);
libname _sqri "&_d";
%if %sysfunc(libref(_sqri)) = 0 %then %do;
    data _sqri.run_info;
        length run_id $64 scenario $32 parent_chain $200 mode $10 status $20
               fail_phase $12 fail_step 8 control $300 control_type $8
               control_hash $32 base_path $300 main_path $300
               inlib $8 outlib $8 iterations 8 iter_done 8
               start_dt 8 end_dt 8 sas_version $40 host $40 userid $40
               sqf_version $12 notes $200;
        format start_dt end_dt datetime20.;
        run_id = "&run_id";
        scenario = "%upcase(&scenario)";
        parent_chain = symget('SQF_CHAIN');
        mode = "&mode";
        status = "&status";
        fail_phase = "&fail_phase";
        fail_step = &fail_step;
        control = symget('SQF_RI_CONTROL');
        control_type = symget('SQF_CONTROL_TYPE');
        control_hash = symget('SQF_CONTROL_HASH');
        base_path = symget('SQF_RI_BASE');
        main_path = symget('SQF_RI_MAIN');
        inlib = "&inlib";
        outlib = "&outlib";
        iterations = &iterations;
        iter_done = &iter_done;
        start_dt = &start_dt;
        end_dt = datetime();
        sas_version = "&sysvlong";
        host = "&syshostname";
        userid = "&sysuserid";
        sqf_version = "&SQF_VERSION";
        notes = symget('SQF_RUN_NOTES');
    run;
    libname _sqri clear;
%end;
%else %put WARNING: [SQF] Could not write run_info to &_d;
%mend sqf_write_runinfo;

/* Latest COMPLETED run of a scenario (optionally a pinned run_id).
   Returns the run FOLDER in &mvar (blank if none).                    */
%macro sqf_resolve_run(root=, scenario=, run_id=, mvar=);
%local _hit;
%let &mvar = ;
%if %sysfunc(libref(SQFREG)) ne 0 %then %do;
    %sqf_registry_init(root=&root)
%end;
%if not %sysfunc(exist(SQFREG.run_events)) %then %return;
proc sql noprint;
    select run_dir into :&mvar trimmed
    from SQFREG.run_events
    where scenario = "%upcase(&scenario)"
      and event = 'COMPLETED'
    %if %length(&run_id) > 0 %then %do;
      and upcase(run_id) = "%upcase(&run_id)"
    %end;
    order by event_dt desc;
quit;
%if %length(&&&mvar) > 0 %then %do;
    %if not %sysfunc(fileexist(&&&mvar)) %then %do;
        %put WARNING: [SQF] Registry points at a run folder that no longer exists: &&&mvar (run %nrstr(%rebuild_registry)() to refresh the index).;
        %let &mvar = ;
    %end;
    %else %if not %sysfunc(fileexist(&&&mvar/outputs)) %then %do;
        /* a chain run keeps outputs under iter_NN/ - resolve to the
           last completed iteration                                     */
        %local _cid;
        %let _cid = 0;
        libname _sqrr3 "&&&mvar" access=readonly;
        %if %sysfunc(libref(_sqrr3)) = 0 %then %do;
            %if %sysfunc(exist(_sqrr3.run_info)) %then %do;
                data _null_;
                    set _sqrr3.run_info;
                    call symputx('_cid', coalesce(iter_done, 0));
                run;
            %end;
            libname _sqrr3 clear;
        %end;
        %if &_cid > 0 %then %let &mvar = &&&mvar/iter_%sysfunc(putn(&_cid, z2.));
        %else %let &mvar = ;
    %end;
%end;
%mend sqf_resolve_run;

/* Rebuild the registry index from run_info files on disk              */
%macro rebuild_registry(root=);
%local _r _ns _nr _i _j _sd _rd;
%if %length(&root) = 0 %then %let root = &SQF_ROOT;
%let _r = %sqf_norm_path(&root);
%sqf_registry_init(root=&_r)

/* scenario folders */
data work._sqf_sdirs;
    length name $256;
    _rc = filename('_sqd', "&_r/scenarios");
    _did = dopen('_sqd');
    if _did > 0 then do;
        do _i = 1 to dnum(_did);
            name = dread(_did, _i);
            output;
        end;
        _rc = dclose(_did);
    end;
    _rc = filename('_sqd');
    keep name;
run;
%let _ns = 0;
data _null_;
    set work._sqf_sdirs end=_e;
    call symputx(cats('_sd_', _n_), name);
    if _e then call symputx('_ns', _n_);
run;

data work._sqf_reb;
    length run_id $64 scenario $32 event $20 phase $12 step 8
           run_dir $300 control_hash $32 sysuser $40 note $200 event_dt 8;
    format event_dt datetime20.;
    call missing(of _all_);
    stop;
run;
%do _i = 1 %to &_ns;
    %let _sd = &&_sd_&_i;
    /* run folders under this scenario */
    data work._sqf_rdirs;
        length name $256;
        _rc = filename('_sqd', "&_r/scenarios/&_sd/runs");
        _did = dopen('_sqd');
        if _did > 0 then do;
            do _j = 1 to dnum(_did);
                name = dread(_did, _j);
                output;
            end;
            _rc = dclose(_did);
        end;
        _rc = filename('_sqd');
        keep name;
    run;
    %let _nr = 0;
    data _null_;
        set work._sqf_rdirs end=_e;
        call symputx(cats('_rd_', _n_), name);
        if _e then call symputx('_nr', _n_);
    run;
    %do _j = 1 %to &_nr;
        %let _rd = &&_rd_&_j;
        libname _sqrr "&_r/scenarios/&_sd/runs/&_rd";
        %if %sysfunc(libref(_sqrr)) = 0 %then %do;
            %if %sysfunc(exist(_sqrr.run_info)) %then %do;
                data work._sqf_reb1;
                    length run_id $64 scenario $32 event $20 phase $12 step 8
                           run_dir $300 control_hash $32 sysuser $40 note $200 event_dt 8;
                    format event_dt datetime20.;
                    set _sqrr.run_info;
                    event = status;
                    phase = fail_phase;
                    step = fail_step;
                    run_dir = "&_r/scenarios/&_sd/runs/&_rd";
                    event_dt = coalesce(end_dt, start_dt, datetime());
                    sysuser = userid;
                    note = 'rebuilt from run_info';
                    keep run_id scenario event phase step run_dir control_hash
                         sysuser note event_dt;
                run;
                proc append base=work._sqf_reb data=work._sqf_reb1 force; run;
            %end;
            libname _sqrr clear;
        %end;
    %end;
%end;
proc sort data=work._sqf_reb; by event_dt; run;
data SQFREG.run_events;
    set work._sqf_reb;
run;
%put NOTE: [SQF] Registry rebuilt from run folders under &_r/scenarios.;
proc datasets lib=work nolist nowarn; delete _sqf_sdirs _sqf_rdirs _sqf_reb _sqf_reb1; quit;
%mend rebuild_registry;
/*------------------------------------------------------------------
  08. AUDIT
      Per-run audit datasets under <run>/audit + report.html.
      Compare policy per modified table:
        * row count/order preserved (only SET_VALUES / UPDATE_FROM /
          COPY_TABLE touched it)      -> full PROC COMPARE + samples
        * key_vars known              -> PROC COMPARE with ID
        * otherwise                   -> row counts + side-by-side
                                         numeric summary stats only
------------------------------------------------------------------*/

%macro sqf_audit(rundir=, scenario=, runid=, outlib=, html=Y);
%local _d _nt _t _mem _pres _keys _cmp _i _nnum _haskeys;
%let _d = %sqf_norm_path(&rundir);
%sqf_mkdir(&_d/audit)
libname _sqau "&_d/audit";
%if %sysfunc(libref(_sqau)) ne 0 %then %do;
    %put WARNING: [SQF] Could not open the audit folder%str(;) audit skipped.;
    %return;
%end;

/* ---- steps: pair BEGIN/END rows from the run log ---- */
%if %sysfunc(exist(work._sqf_runlog)) %then %do;
    proc sort data=work._sqf_runlog out=work._sqf_rl_s; by exec phase; run;
    data _sqau.audit_steps;
        length exec step 8 origin $32 method $16 target $32
               start_dt end_dt elapsed_s aff 8 status $12;
        format start_dt end_dt datetime20.;
        retain start_dt origin;
        set work._sqf_rl_s(rename=(origin=_rl_origin));
        by exec;
        if first.exec then do;
            start_dt = .; origin = ' ';
        end;
        if phase = 'B' then do;
            start_dt = dt;
            origin = _rl_origin;
            if first.exec and last.exec then do;
                /* begin without end: step crashed hard */
                end_dt = .; elapsed_s = .; status = 'NO_END';
                output;
            end;
        end;
        else do;
            end_dt = dt;
            elapsed_s = round(end_dt - start_dt, 0.01);
            output;
        end;
        keep exec step origin method target start_dt end_dt elapsed_s aff status;
    run;
%end;
%else %do;
    data _sqau.audit_steps;
        length exec step 8 origin $32 method $16 target $32
               start_dt end_dt elapsed_s aff 8 status $12;
        call missing(of _all_); stop;
    run;
%end;

/* ---- resolved params + steps + findings snapshots ---- */
%if %sysfunc(exist(work._sqf_params_x)) %then %do;
    data _sqau.params_resolved; set work._sqf_params_x; run;
%end;
%if %sysfunc(exist(work._sqf_steps_r)) %then %do;
    data _sqau.steps_resolved; set work._sqf_steps_r; run;
%end;
%if %sysfunc(exist(work._sqf_verrors)) %then %do;
    data _sqau.findings; set work._sqf_verrors; run;
%end;
%if %sysfunc(exist(work._sqf_logscan)) %then %do;
    data _sqau.audit_logscan; set work._sqf_logscan; run;
%end;

/* ---- modified tables inventory + compare policy ---- */
proc sql;
    create table work._sqf_stagetabs as
    select memname from dictionary.tables
    where libname = 'SQFIN' and memtype = 'DATA'
    order by memname;
quit;
data _sqau.audit_tables;
    length table $32 base_nobs base_nvars scen_nobs scen_nvars 8
           rows_preserved $1 key_vars $500 compare_code 8 policy $12;
    call missing(of _all_);
    stop;
run;
data work._sqf_cmpall;
    length table $32 _type_ $8 _var_ $32;
    call missing(of _all_);
    stop;
run;

%let _nt = 0;
data _null_;
    set work._sqf_stagetabs end=_e;
    call symputx(cats('_t_', _n_), memname);
    if _e then call symputx('_nt', _n_);
run;

%do _i = 1 %to &_nt;
    %let _mem = &&_t_&_i;
    /* preservation + keys from the effective steps */
    %let _pres = Y;
    %let _keys = ;
    %if %sysfunc(exist(work._sqf_steps_p)) %then %do;
        data _null_;
            set work._sqf_steps_p(where=(target_table = "&_mem" and active = 'Y'));
            if method in ('FILTER_ROWS','APPEND_ROWS','REPLACE_TABLE','CUSTOM_CODE')
                then call symputx('_pres', 'N');
            if key_vars ne ' ' then call symputx('_keys', key_vars);
        run;
    %end;
    %let _haskeys = %eval(%length(&_keys) > 0);
    %local _bn _bv _sn _sv;
    %let _bn = .; %let _bv = .; %let _sn = .; %let _sv = .;
    %if %sysfunc(exist(SQFBASE.&_mem)) %then %do;
        %sqf_nobs(ds=SQFBASE.&_mem, mvar=_bn)
        proc sql noprint;
            select count(*) into :_bv trimmed from dictionary.columns
            where libname='SQFBASE' and memname="&_mem";
        quit;
    %end;
    %sqf_nobs(ds=SQFIN.&_mem, mvar=_sn)
    proc sql noprint;
        select count(*) into :_sv trimmed from dictionary.columns
        where libname='SQFIN' and memname="&_mem";
    quit;

    %let _cmp = .;
    %if %sysfunc(exist(SQFBASE.&_mem)) %then %do;
        %if &_pres = Y %then %do;
            proc compare base=SQFBASE.&_mem compare=SQFIN.&_mem
                         outstats=work._sqf_cmp1 noprint;
            run;
            %let _cmp = &sysinfo;
        %end;
        %else %if &_haskeys = 1 %then %do;
            proc sort data=SQFIN.&_mem out=work._sqf_cmpc; by &_keys; run;
            proc sort data=SQFBASE.&_mem out=work._sqf_cmpb; by &_keys; run;
            proc compare base=work._sqf_cmpb compare=work._sqf_cmpc
                         outstats=work._sqf_cmp1 noprint;
                id &_keys;
            run;
            %let _cmp = &sysinfo;
            proc datasets lib=work nolist nowarn; delete _sqf_cmpb _sqf_cmpc; quit;
        %end;
        %if %sysfunc(exist(work._sqf_cmp1)) %then %do;
            data work._sqf_cmp1;
                length table $32;
                set work._sqf_cmp1;
                table = "&_mem";
            run;
            proc append base=work._sqf_cmpall data=work._sqf_cmp1 force; run;
            proc datasets lib=work nolist nowarn; delete _sqf_cmp1; quit;
        %end;
        %else %if &_pres = N and &_haskeys = 0 %then %do;
            /* counts + numeric summary only */
            %let _nnum = 0;
            proc sql noprint;
                select count(*) into :_nnum trimmed from dictionary.columns
                where libname='SQFBASE' and memname="&_mem" and type='num';
            quit;
            %if &_nnum > 0 %then %do;
                proc means data=SQFBASE.&_mem noprint;
                    var _numeric_;
                    output out=work._sqf_mb;
                run;
                proc means data=SQFIN.&_mem noprint;
                    var _numeric_;
                    output out=work._sqf_ms;
                run;
                proc transpose data=work._sqf_mb out=work._sqf_mbt(rename=(col1=base_value));
                    by _stat_ notsorted;
                run;
                proc transpose data=work._sqf_ms out=work._sqf_mst(rename=(col1=scen_value));
                    by _stat_ notsorted;
                run;
                proc sql;
                    create table work._sqf_mm1 as
                    select "&_mem" as table length=32,
                           coalescec(a._name_, b._name_) as variable length=32,
                           coalescec(a._stat_, b._stat_) as stat length=8,
                           a.base_value, b.scen_value
                    from work._sqf_mbt a
                         full join work._sqf_mst b
                         on a._name_ = b._name_ and a._stat_ = b._stat_
                    where upcase(coalescec(a._name_, b._name_)) not in ('_TYPE_','_FREQ_');
                quit;
                proc append base=work._sqf_meansall data=work._sqf_mm1 force; run;
                proc datasets lib=work nolist nowarn;
                    delete _sqf_mb _sqf_ms _sqf_mbt _sqf_mst _sqf_mm1;
                quit;
            %end;
        %end;
    %end;

    data work._sqf_at1;
        length table $32 base_nobs base_nvars scen_nobs scen_nvars 8
               rows_preserved $1 key_vars $500 compare_code 8 policy $12;
        table = "&_mem";
        base_nobs = &_bn; base_nvars = &_bv;
        scen_nobs = &_sn; scen_nvars = &_sv;
        rows_preserved = "&_pres";
        key_vars = "&_keys";
        compare_code = &_cmp;
        if rows_preserved = 'Y' then policy = 'FULL';
        else if key_vars ne ' ' then policy = 'BY_KEY';
        else policy = 'STATS_ONLY';
    run;
    proc append base=_sqau.audit_tables data=work._sqf_at1 force; run;
    proc datasets lib=work nolist nowarn; delete _sqf_at1; quit;
%end;

data _sqau.audit_compare; set work._sqf_cmpall; run;
%if %sysfunc(exist(work._sqf_meansall)) %then %do;
    data _sqau.audit_means; set work._sqf_meansall; run;
%end;

/* ---- outputs inventory ---- */
%if %length(&outlib) > 0 %then %do;
    proc sql;
        create table _sqau.audit_outputs as
        select memname as table length=32, nlobs as nobs, nvar as nvars,
               crdate as created format=datetime20.
        from dictionary.tables
        where libname = "%upcase(&outlib)" and memtype = 'DATA'
        order by memname;
    quit;
%end;

/* ---- report ---- */
%if %upcase(&html) = Y %then %do;
    ods html(id=sqf) path="&_d/audit" file="report.html" style=HTMLBlue;
    title1 "SQF run report - scenario %upcase(&scenario) - &runid";
    title2 "Folder: &_d";
    %if %sysfunc(exist(_sqau.findings)) %then %do;
        title3 "Validation findings";
        proc print data=_sqau.findings noobs; run;
    %end;
    title3 "Steps executed";
    proc print data=_sqau.audit_steps noobs; run;
    title3 "Modified input tables (base vs staged)";
    proc print data=_sqau.audit_tables noobs; run;
    %if %sysfunc(exist(_sqau.audit_compare)) %then %do;
        title3 "PROC COMPARE digests (per table / variable)";
        proc print data=_sqau.audit_compare noobs; run;
    %end;
    %if %sysfunc(exist(_sqau.audit_means)) %then %do;
        title3 "Numeric summary, base vs scenario (row structure changed)";
        proc print data=_sqau.audit_means noobs; run;
    %end;
    %if %sysfunc(exist(_sqau.audit_outputs)) %then %do;
        title3 "Run outputs";
        proc print data=_sqau.audit_outputs noobs; run;
    %end;
    %if %sysfunc(exist(_sqau.audit_logscan)) %then %do;
        title3 "Log scan findings";
        proc print data=_sqau.audit_logscan noobs; run;
    %end;
    title;
    ods html(id=sqf) close;
    %put NOTE: [SQF] Audit report: &_d/audit/report.html;
%end;
proc datasets lib=work nolist nowarn; delete _sqf_cmpall _sqf_meansall _sqf_stagetabs _sqf_rl_s; quit;
libname _sqau clear;
%mend sqf_audit;

/* -------------------------------------------------------------------
   %compare_runs: difference digest between two runs' OUTPUT folders.
   run1/run2: a run folder path, or a run_id known to the registry.
------------------------------------------------------------------- */
%macro compare_runs(run1=, run2=, out=work.run_compare, html=N, root=);
%local _d1 _d2 _n _i _mem _rc;
%if %length(&root) = 0 %then %let root = &SQF_ROOT;
%let _d1 = %sqf_norm_path(&run1);
%let _d2 = %sqf_norm_path(&run2);
%if %length(&_d1) = 0 or %length(&_d2) = 0 %then %do;
    %put ERROR: [SQF] compare_runs needs run1= and run2= (run folders or run ids).;
    %return;
%end;
%if %sysfunc(libref(SQFREG)) ne 0 and %length(&root) > 0 %then %do;
    %sqf_registry_init(root=&root)
%end;
%if not %sysfunc(fileexist(&_d1)) %then %do;
    proc sql noprint;
        select run_dir into :_d1 trimmed from SQFREG.run_events
        where upcase(run_id) = "%upcase(&run1)" order by event_dt desc;
    quit;
%end;
%if not %sysfunc(fileexist(&_d2)) %then %do;
    proc sql noprint;
        select run_dir into :_d2 trimmed from SQFREG.run_events
        where upcase(run_id) = "%upcase(&run2)" order by event_dt desc;
    quit;
%end;
/* nested existence checks: macro %IF does not short-circuit and
   fileexist() with a blank argument is itself an error                */
%local _ok;
%let _ok = 1;
%if %length(&_d1) = 0 %then %let _ok = 0;
%else %if not %sysfunc(fileexist(&_d1)) %then %let _ok = 0;
%if %length(&_d2) = 0 %then %let _ok = 0;
%else %if not %sysfunc(fileexist(&_d2)) %then %let _ok = 0;
%if &_ok = 0 %then %do;
    %put ERROR: [SQF] compare_runs could not resolve both runs (&run1 / &run2).;
    %return;
%end;
libname _sqc1 "&_d1/outputs" access=readonly;
libname _sqc2 "&_d2/outputs" access=readonly;
proc sql;
    create table work._sqf_cboth as
    select coalescec(a.memname, b.memname) as memname length=32,
           (a.memname is not null) as in_run1,
           (b.memname is not null) as in_run2,
           a.nlobs as nobs1, b.nlobs as nobs2
    from (select memname, nlobs from dictionary.tables
          where libname='_SQC1' and memtype='DATA') a
         full join
         (select memname, nlobs from dictionary.tables
          where libname='_SQC2' and memtype='DATA') b
         on a.memname = b.memname
    order by memname;
quit;
data &out;
    length table $32 in_run1 in_run2 8 nobs1 nobs2 8 compare_code 8 note $80;
    call missing(of _all_);
    stop;
run;
%let _n = 0;
data _null_;
    set work._sqf_cboth end=_e;
    call symputx(cats('_cb_', _n_), memname);
    call symputx(cats('_c1_', _n_), in_run1);
    call symputx(cats('_c2_', _n_), in_run2);
    call symputx(cats('_o1_', _n_), nobs1);
    call symputx(cats('_o2_', _n_), nobs2);
    if _e then call symputx('_n', _n_);
run;
%do _i = 1 %to &_n;
    %let _mem = &&_cb_&_i;
    %let _rc = .;
    %if &&_c1_&_i = 1 and &&_c2_&_i = 1 %then %do;
        proc compare base=_sqc1.&_mem compare=_sqc2.&_mem noprint;
        run;
        %let _rc = &sysinfo;
    %end;
    data work._sqf_cr1;
        length table $32 in_run1 in_run2 8 nobs1 nobs2 8 compare_code 8 note $80;
        table = "&_mem";
        in_run1 = &&_c1_&_i; in_run2 = &&_c2_&_i;
        nobs1 = &&_o1_&_i; nobs2 = &&_o2_&_i;
        compare_code = &_rc;
        if compare_code = 0 then note = 'identical';
        else if compare_code = . then note = 'only in one run';
        else note = 'DIFFERS (see PROC COMPARE sysinfo bits)';
    run;
    proc append base=&out data=work._sqf_cr1 force; run;
    proc datasets lib=work nolist nowarn; delete _sqf_cr1; quit;
%end;
title "SQF compare_runs: &_d1 vs &_d2";
proc print data=&out noobs; run;
title;
%if %upcase(&html) = Y %then %do;
    ods html(id=sqfc) path="%sysfunc(pathname(WORK))" file="compare_runs.html" style=HTMLBlue;
    proc print data=&out noobs; run;
    ods html(id=sqfc) close;
%end;
libname _sqc1 clear;
libname _sqc2 clear;
proc datasets lib=work nolist nowarn; delete _sqf_cboth; quit;
%mend compare_runs;
/*------------------------------------------------------------------
  09. PUBLIC API
      %sqf_setup       - session defaults
      %run_scenario    - the orchestrator (validate -> stage+apply ->
                         main program -> audit -> register)
      %run_chain       - iterated feed-forward runs (PREV:)
      %run_all         - every active scenario
      %sqf_scan_program- reconnaissance of the production program
      %sqf_make_template - write control-file templates at work
------------------------------------------------------------------*/

%macro sqf_setup(root=, base=, control=, main=, inlib=, outlib=);
%if %length(&root)    > 0 %then %let SQF_ROOT    = %sqf_norm_path(&root);
%if %length(&base)    > 0 %then %let SQF_BASE    = %sqf_norm_path(&base);
%if %length(&control) > 0 %then %let SQF_CONTROL = %sqf_norm_path(&control);
%if %length(&main)    > 0 %then %let SQF_MAIN    = %sqf_norm_path(&main);
%if %length(&inlib)   > 0 %then %let SQF_INLIB   = %upcase(&inlib);
%if %length(&outlib)  > 0 %then %let SQF_OUTLIB  = %upcase(&outlib);
%put NOTE: [SQF] setup: root=&SQF_ROOT;
%put NOTE: [SQF] setup: base=&SQF_BASE;
%put NOTE: [SQF] setup: control=&SQF_CONTROL;
%put NOTE: [SQF] setup: main=&SQF_MAIN;
%put NOTE: [SQF] setup: inlib=&SQF_INLIB outlib=&SQF_OUTLIB;
%if %length(&SQF_ROOT) > 0 %then %do;
    %sqf_mkdir(&SQF_ROOT)
%end;
%mend sqf_setup;

/* ---------------- internal: prep ---------------- */
%macro sqf_prep(scenario=, control=, control_type=, control_lib=, base=,
                root=, main=, mode=, inlib=, outlib=, notes=, chain=0);
%global SQF_PREP SQF_RUNID SQF_RUNROOT SQF_START_DT SQF_MODE_R SQF_SCEN_R
        SQF_INLIB_R SQF_OUTLIB_R SQF_CTLTYPE_R SQF_CTLLIB_R
        SQF_RI_CONTROL SQF_RI_BASE SQF_RI_MAIN SQF_RUN_NOTES SQF_NERR SQF_NWARN;
%let SQF_PREP = FATAL;
%sqf_opts_save()
%let SQF_STOP = 0;
%let SQF_FAIL_PHASE = ;
%let SQF_FAIL_STEP = .;
%let SQF_START_DT = %sysfunc(datetime());
%sqf_clean_work()

/* resolve defaults from session globals */
%let SQF_SCEN_R = %upcase(&scenario);
%if %length(&root)    = 0 %then %let root    = &SQF_ROOT;
%if %length(&base)    = 0 %then %let base    = &SQF_BASE;
%if %length(&control) = 0 %then %let control = &SQF_CONTROL;
%if %length(&main)    = 0 %then %let main    = &SQF_MAIN;
%if %length(&inlib)   = 0 %then %let inlib   = &SQF_INLIB;
%if %length(&outlib)  = 0 %then %let outlib  = &SQF_OUTLIB;
%let root = %sqf_norm_path(&root);
%let base = %sqf_norm_path(&base);
%let SQF_MODE_R    = %upcase(&mode);
%let SQF_INLIB_R   = %upcase(&inlib);
%let SQF_OUTLIB_R  = %upcase(&outlib);
%let SQF_CTLTYPE_R = %upcase(&control_type);
%let SQF_CTLLIB_R  = &control_lib;
%let SQF_RI_CONTROL = %sqf_norm_path(&control);
%let SQF_RI_BASE    = &base;
%let SQF_RI_MAIN    = %sqf_norm_path(&main);
%let SQF_RUN_NOTES  = %superq(notes);
%let SQF_ROOT = &root;   /* codegen + custom paths rely on this        */

/* hard requirements */
%if %length(&SQF_SCEN_R) = 0 %then %do;
    %put ERROR: [SQF] run: scenario= is required.;
    %return;
%end;
%if %length(&root) = 0 or %length(&base) = 0 %then %do;
    %put ERROR: [SQF] run: root= and base= are required (or set them once with sqf_setup).;
    %return;
%end;
%sqf_mkdir(&root)
%if &SQF_RC ne 0 %then %do;
    %put ERROR: [SQF] run: cannot create or reach root folder &root (remember: paths are as the SAS SERVER sees them).;
    %return;
%end;

/* run identity + folders */
%let SQF_RUNID  = %sqf_gen_runid();
%let SQF_RUNROOT = &root/scenarios/&SQF_SCEN_R/runs/&SQF_RUNID;
%if %sysfunc(fileexist(&SQF_RUNROOT)) %then %let SQF_RUNROOT = &SQF_RUNROOT._2;
%sqf_mkdir(&SQF_RUNROOT/control_snapshot)
%if &SQF_RC ne 0 %then %do;
    %put ERROR: [SQF] run: cannot create the run folder under &root/scenarios/&SQF_SCEN_R/runs.;
    %return;
%end;
%if %length(&SQF_RUNROOT) > 200 %then
    %put WARNING: [SQF] Run folder path is %length(&SQF_RUNROOT) characters long%str(;) consider a shorter root to stay clear of path-length limits.;
%let SQF_LAST_RUN_DIR = &SQF_RUNROOT;
%sqf_registry_init(root=&root)

/* findings store */
data work._sqf_verrors;
    length sev $1 scenario $32 step 8 field $32 message $500;
    call missing(of _all_);
    stop;
run;

/* environment findings */
libname SQFBASE "&base" access=readonly;
%if %sysfunc(libref(SQFBASE)) ne 0 %then %do;
    %let SQF_VMSG = Base folder cannot be assigned read-only: &base (as seen by the SAS server).;
    %sqf_verr(sev=E, scen=&SQF_SCEN_R, field=BASE)
%end;
%if &SQF_MODE_R = FULL %then %do;
    /* nested checks: macro %IF does not short-circuit, and fileexist()
       with a blank argument is itself an error                         */
    %if %length(&SQF_RI_MAIN) = 0 %then %do;
        %let SQF_VMSG = mode=FULL needs main= (path to your main program) - or run mode=APPLYONLY.;
        %sqf_verr(sev=E, scen=&SQF_SCEN_R, field=MAIN)
    %end;
    %else %if not %sysfunc(fileexist(&SQF_RI_MAIN)) %then %do;
        %let SQF_VMSG = Main program not found: &SQF_RI_MAIN (pass main= or run mode=APPLYONLY).;
        %sqf_verr(sev=E, scen=&SQF_SCEN_R, field=MAIN)
    %end;
%end;
%if not %sysfunc(indexw(FULL APPLYONLY VALIDATE, &SQF_MODE_R)) %then %do;
    %let SQF_VMSG = mode must be FULL, APPLYONLY or VALIDATE (got &SQF_MODE_R).;
    %sqf_verr(sev=E, scen=&SQF_SCEN_R, field=MODE)
%end;
%if &SQF_INLIB_R = &SQF_OUTLIB_R %then %do;
    %let SQF_VMSG = inlib and outlib must differ (&SQF_INLIB_R) - the framework must keep staged inputs and run outputs apart.;
    %sqf_verr(sev=E, scen=&SQF_SCEN_R, field=INLIB)
%end;
%if %length(&SQF_INLIB_R) > 8 or %length(&SQF_OUTLIB_R) > 8
    or not %sysfunc(prxmatch(/^[A-Za-z_][A-Za-z0-9_]*$/, &SQF_INLIB_R))
    or not %sysfunc(prxmatch(/^[A-Za-z_][A-Za-z0-9_]*$/, &SQF_OUTLIB_R)) %then %do;
    %let SQF_VMSG = inlib/outlib must be valid librefs (max 8 chars).;
    %sqf_verr(sev=E, scen=&SQF_SCEN_R, field=INLIB)
%end;
%if %sysfunc(indexw(SQFBASE SQFIN SQFPREV SQFREG WORK SASHELP SASUSER MAPS, &SQF_INLIB_R))
    or %sysfunc(indexw(SQFBASE SQFIN SQFPREV SQFREG WORK SASHELP SASUSER MAPS, &SQF_OUTLIB_R))
    or %index(&SQF_INLIB_R, SQFS) = 1 or %index(&SQF_OUTLIB_R, SQFS) = 1 %then %do;
    %let SQF_VMSG = inlib/outlib collides with a framework or system libref (SQF*, WORK, SASHELP...). Pick different names.;
    %sqf_verr(sev=E, scen=&SQF_SCEN_R, field=INLIB)
%end;

/* load + flatten under the load log */
%sqf_mkdir(&SQF_RUNROOT/logs)
%sqf_printto(log=&SQF_RUNROOT/logs/load.log)
%sqf_load_control(control=&control, control_type=&SQF_CTLTYPE_R, control_lib=&SQF_CTLLIB_R)
%sqf_flatten(scenario=&SQF_SCEN_R)
%sqf_printto_off()
%let syscc = 0;   /* loader probes may have raised it; findings decide */

/* control snapshot */
libname _sqcs "&SQF_RUNROOT/control_snapshot";
%if %sysfunc(libref(_sqcs)) = 0 %then %do;
    proc copy in=work out=_sqcs memtype=data;
        select _sqf_scenarios _sqf_steps _sqf_parameters;
    run;
    libname _sqcs clear;
%end;
%if &SQF_CONTROL_TYPE = XLSX %then %do;
    %sqf_copy_file(from=&control, to=&SQF_RUNROOT/control_snapshot/workbook.xlsx)
%end;
%else %if &SQF_CONTROL_TYPE = CSV %then %do;
    %sqf_copy_file(from=&control/scenarios.csv,  to=&SQF_RUNROOT/control_snapshot/scenarios.csv)
    %sqf_copy_file(from=&control/steps.csv,      to=&SQF_RUNROOT/control_snapshot/steps.csv)
    %sqf_copy_file(from=&control/parameters.csv, to=&SQF_RUNROOT/control_snapshot/parameters.csv)
%end;
%let SQF_PREP = OK;
%mend sqf_prep;

/* ---------------- internal: one iteration ---------------- */
%macro sqf_iter(iter=1, iterdir=, chain=0, prevdir=, do_validate=1, prelude=, html=Y);
%global SQF_ITER_STATUS;
%local _d _scanerr _pv _pn _i;
%let SQF_ITER_STATUS = FAILED;
%let _d = %sqf_norm_path(&iterdir);
%sqf_mkdir(&_d/inputs)
%sqf_mkdir(&_d/outputs)
%sqf_mkdir(&_d/gen)
%sqf_mkdir(&_d/logs)
%sqf_mkdir(&_d/audit)

/* per-iteration resolution + validation */
%sqf_printto(log=&_d/logs/validate.log)
%sqf_scan_cells(iter=&iter, runid=&SQF_RUNID, scenario=&SQF_SCEN_R)
%sqf_process_steps()
%if &do_validate = 1 %then %do;
    %sqf_validate(scenario=&SQF_SCEN_R, root=&SQF_ROOT, chain=&chain)
%end;
%sqf_printto_off()
%sqf_validate_report()
%if &SQF_NERR > 0 %then %do;
    %let SQF_ITER_STATUS = VALIDATION_FAILED;
    %let SQF_FAIL_PHASE = VALIDATE;
    %put ERROR: [SQF] Validation failed with &SQF_NERR error(s). Nothing was staged%str(;) base data untouched.;
    %return;
%end;
%let syscc = 0;

/* PREV member existence + schema checks for this iteration (cannot be
   known before the previous iteration produced its outputs)           */
%if &iter > 1 and %length(&prevdir) > 0 %then %do;
    libname SQFPREV "%sqf_norm_path(&prevdir)" access=readonly;
    %let _pn = 0;
    data _null_;
        set work._sqf_steps_p(where=(src_kind = 'PREV' and active = 'Y')) end=_e;
        call symputx(cats('_pv_',  _n_), src_member);
        call symputx(cats('_pvm_', _n_), method);
        call symputx(cats('_pvx_', _n_), exec_order);
        call symputx(cats('_pvs_', _n_), put(step_no, best8.-l));
        call symputx(cats('_pvt_', _n_), target_table);
        call symputx(cats('_pvk_', _n_), key_vars);
        call symputx(cats('_pvo_', _n_), origin_scenario);
        if _e then call symputx('_pn', _n_);
    run;
    %do _i = 1 %to &_pn;
        %if not %sysfunc(exist(SQFPREV.&&_pv_&_i)) %then %do;
            %put ERROR: [SQF] Iteration &iter needs PREV:&&_pv_&_i but the previous iteration outputs do not contain it.;
            %let SQF_ITER_STATUS = FAILED;
            %let SQF_FAIL_PHASE = VALIDATE;
            %return;
        %end;
        %else %do;
            %if &&_pvm_&_i = UPDATE_FROM %then %do;
                %sqf_check_update_from(r=&&_pvx_&_i, srcds=SQFPREV.&&_pv_&_i,
                    scen=&&_pvo_&_i, step=&&_pvs_&_i, target=&&_pvt_&_i,
                    keys=&&_pvk_&_i)
            %end;
            %else %if &&_pvm_&_i = REPLACE_TABLE %then %do;
                %sqf_check_replace(r=&&_pvx_&_i, srcds=SQFPREV.&&_pv_&_i,
                    scen=&&_pvo_&_i, step=&&_pvs_&_i, target=&&_pvt_&_i)
            %end;
            %else %if &&_pvm_&_i = APPEND_ROWS %then %do;
                %sqf_check_append(r=&&_pvx_&_i, srcds=SQFPREV.&&_pv_&_i,
                    scen=&&_pvo_&_i, step=&&_pvs_&_i, target=&&_pvt_&_i)
            %end;
        %end;
    %end;
    %if &_pn > 0 %then %do;
        %sqf_validate_report()
        %if &SQF_NERR > 0 %then %do;
            %put ERROR: [SQF] Iteration &iter: PREV: source schema checks failed. Nothing staged for this iteration.;
            %let SQF_ITER_STATUS = FAILED;
            %let SQF_FAIL_PHASE = VALIDATE;
            %return;
        %end;
    %end;
%end;

/* source libraries for RUN: references */
%sqf_assign_srclibs()

/* dry run against obs=0 sandboxes */
%sqf_gen_apply(file=&_d/gen/validate.sas, dryrun=1, iter=&iter, chain=&chain,
               scenario=&SQF_SCEN_R, runid=&SQF_RUNID)
%sqf_exec_include(file=&_d/gen/validate.sas, log=&_d/logs/dryrun.log, phase=DRYRUN)
%sqf_validate_report()
%if &SQF_SCAN_NERR > 0 or &SQF_NERR > 0 or &SQF_STOP = 1 or &syscc > 4 %then %do;
    %let SQF_ITER_STATUS = VALIDATION_FAILED;
    %let SQF_FAIL_PHASE = VALIDATE;
    %put ERROR: [SQF] Dry run failed (&SQF_SCAN_NERR log errors, &SQF_NERR findings, stop=&SQF_STOP). See &_d/logs/dryrun.log and gen/validate.sas. Nothing was staged.;
    %return;
%end;
%let syscc = 0;
%let SQF_STOP = 0;

%if &SQF_MODE_R = VALIDATE %then %do;
    %let SQF_ITER_STATUS = VALIDATED;
    %put NOTE: [SQF] mode=VALIDATE: validation and dry run passed. Nothing staged.;
    %return;
%end;

/* register STARTED once per run */
%if &iter = 1 %then %do;
    %sqf_register_event(run_id=&SQF_RUNID, scenario=&SQF_SCEN_R, event=STARTED,
                        phase=APPLY, note=mode &SQF_MODE_R)
%end;

/* ---- apply ---- */
libname SQFIN "&_d/inputs";
proc datasets lib=work nolist nowarn; delete _sqf_runlog; quit;
%sqf_gen_apply(file=&_d/gen/apply.sas, dryrun=0, iter=&iter, chain=&chain,
               scenario=&SQF_SCEN_R, runid=&SQF_RUNID)
%sqf_set_contract(scenlib=SQFIN, baselib=SQFBASE, rundir=&_d, iter=&iter,
                  scenario=&SQF_SCEN_R, runid=&SQF_RUNID)
%sqf_exec_include(file=&_d/gen/apply.sas, log=&_d/logs/apply.log, phase=APPLY)
%if &SQF_STOP = 1 or &SQF_SCAN_NERR > 0 or &syscc > 4 %then %do;
    %let SQF_ITER_STATUS = FAILED;
    %let SQF_FAIL_PHASE = APPLY;
    %put ERROR: [SQF] Apply phase failed (step &SQF_FAIL_STEP). Debris kept for post-mortem in &_d. Base data untouched.;
    %return;
%end;

/* ---- main program ---- */
%if &SQF_MODE_R = FULL %then %do;
    libname &SQF_INLIB_R ("&_d/inputs" SQFBASE);
    libname &SQF_OUTLIB_R "&_d/outputs";
    %let syscc = 0;
    %sqf_printto(log=&_d/logs/main.log)
    %if %length(&prelude) > 0 %then %do;
        %include "%sqf_norm_path(&prelude)" / source2 lrecl=32767;
    %end;
    %include "&SQF_RI_MAIN" / source2 lrecl=32767;
    %sqf_printto_off()
    %sqf_log_scan(log=&_d/logs/main.log, phase=MAIN)
    %if &syscc > 4 or &SQF_SCAN_NERR > 0 %then %do;
        %let SQF_ITER_STATUS = FAILED;
        %let SQF_FAIL_PHASE = MAIN;
        %put ERROR: [SQF] The main program errored (&SQF_SCAN_NERR log errors, syscc=&syscc). See &_d/logs/main.log.;
        /* still audit what we can, then bail */
        %sqf_audit(rundir=&_d, scenario=&SQF_SCEN_R, runid=&SQF_RUNID,
                   outlib=&SQF_OUTLIB_R, html=&html)
        %return;
    %end;
%end;

/* ---- audit ---- */
%local _aol;
%let _aol = ;
%if &SQF_MODE_R = FULL %then %let _aol = &SQF_OUTLIB_R;
%sqf_printto(log=&_d/logs/audit.log)
%sqf_audit(rundir=&_d, scenario=&SQF_SCEN_R, runid=&SQF_RUNID,
           outlib=&_aol, html=&html)
%sqf_printto_off()
%let syscc = 0;

%let SQF_ITER_STATUS = COMPLETED;
libname SQFIN clear;
%if %sysfunc(libref(SQFPREV)) = 0 %then %do;
    libname SQFPREV clear;
%end;
%mend sqf_iter;

/* ---------------- internal: finish ---------------- */
%macro sqf_finish(status=, iterations=1, iter_done=0, onfail=RETURN);
%sqf_clear_srclibs()
%if %sysfunc(libref(SQFIN)) = 0 %then %do;
    libname SQFIN clear;
%end;
%if %sysfunc(libref(SQFPREV)) = 0 %then %do;
    libname SQFPREV clear;
%end;
%sqf_write_runinfo(rundir=&SQF_RUNROOT, run_id=&SQF_RUNID, scenario=&SQF_SCEN_R,
                   mode=&SQF_MODE_R, status=&status, fail_phase=&SQF_FAIL_PHASE,
                   fail_step=&SQF_FAIL_STEP, iterations=&iterations,
                   iter_done=&iter_done, start_dt=&SQF_START_DT,
                   inlib=&SQF_INLIB_R, outlib=&SQF_OUTLIB_R)
%if &status = VALIDATION_FAILED %then %do;
    %sqf_register_event(run_id=&SQF_RUNID, scenario=&SQF_SCEN_R,
                        event=VALIDATION_FAILED, phase=VALIDATE)
%end;
%else %if &status ne VALIDATED %then %do;
    %sqf_register_event(run_id=&SQF_RUNID, scenario=&SQF_SCEN_R, event=&status,
                        phase=&SQF_FAIL_PHASE, step=&SQF_FAIL_STEP)
%end;
%let SQF_LAST_RUN_ID  = &SQF_RUNID;
%let SQF_LAST_STATUS  = &status;
%let SQF_LAST_RUN_DIR = &SQF_RUNROOT;
%put NOTE: [SQF] ==========================================================;
%put NOTE: [SQF] scenario &SQF_SCEN_R run &SQF_RUNID;
%put NOTE: [SQF] status : &status;
%if %length(&SQF_FAIL_PHASE) > 0 %then
    %put NOTE: [SQF] failed : phase &SQF_FAIL_PHASE step &SQF_FAIL_STEP;
%put NOTE: [SQF] folder : &SQF_RUNROOT;
%put NOTE: [SQF] report : &SQF_RUNROOT/audit/report.html (per iteration for chains);
%put NOTE: [SQF] ==========================================================;
%sqf_opts_restore()
%if %upcase(&onfail) = ABORT and &status ne COMPLETED and &status ne VALIDATED %then %do;
    %put ERROR: [SQF] onfail=ABORT: cancelling the submitted job.;
    %abort cancel;
%end;
%mend sqf_finish;

/* ---------------- public: single run ---------------- */
%macro run_scenario(scenario=, control=, control_type=AUTO, control_lib=WORK,
                    base=, root=, main=, mode=FULL, inlib=, outlib=,
                    prelude=, html=Y, onfail=RETURN, notes=);
%sqf_prep(scenario=&scenario, control=&control, control_type=&control_type,
          control_lib=&control_lib, base=&base, root=&root, main=&main,
          mode=&mode, inlib=&inlib, outlib=&outlib, notes=%superq(notes))
%if &SQF_PREP ne OK %then %do;
    %let SQF_LAST_STATUS = VALIDATION_FAILED;
    %sqf_opts_restore()
    %return;
%end;
%sqf_iter(iter=1, iterdir=&SQF_RUNROOT, chain=0, do_validate=1,
          prelude=&prelude, html=&html)
%sqf_finish(status=&SQF_ITER_STATUS, iterations=1,
            iter_done=%eval(&SQF_ITER_STATUS = COMPLETED), onfail=&onfail)
%mend run_scenario;

/* ---------------- public: chained runs ---------------- */
%macro run_chain(scenario=, iterations=2, control=, control_type=AUTO,
                 control_lib=WORK, base=, root=, main=, mode=FULL,
                 inlib=, outlib=, prelude=, html=Y, onfail=RETURN, notes=);
%local _i _go _done _prev _iterdir;
%if not %sysfunc(prxmatch(/^\d+$/, &iterations)) %then %do;
    %put ERROR: [SQF] run_chain: iterations= must be a positive whole number.;
    %return;
%end;
%if %sysevalf(&iterations < 1) %then %do;
    %put ERROR: [SQF] run_chain: iterations= must be at least 1.;
    %return;
%end;
%sqf_prep(scenario=&scenario, control=&control, control_type=&control_type,
          control_lib=&control_lib, base=&base, root=&root, main=&main,
          mode=&mode, inlib=&inlib, outlib=&outlib, notes=%superq(notes), chain=1)
%if &SQF_PREP ne OK %then %do;
    %let SQF_LAST_STATUS = VALIDATION_FAILED;
    %sqf_opts_restore()
    %return;
%end;
data work._sqf_manifest;
    length iteration 8 status $20 iterdir $300;
    call missing(of _all_);
    stop;
run;
%let _done = 0;
%let _go = 1;
%let _prev = ;
%let _i = 1;
%do %while (&_i <= &iterations and &_go = 1);
    %let _iterdir = &SQF_RUNROOT/iter_%sysfunc(putn(&_i, z2.));
    %put NOTE: [SQF] ---- chain iteration &_i of &iterations ----;
    %sqf_iter(iter=&_i, iterdir=&_iterdir, chain=1, prevdir=&_prev,
              do_validate=%eval(&_i = 1), prelude=&prelude, html=&html)
    data work._sqf_mf1;
        length iteration 8 status $20 iterdir $300;
        iteration = &_i;
        status = "&SQF_ITER_STATUS";
        iterdir = "&_iterdir";
    run;
    proc append base=work._sqf_manifest data=work._sqf_mf1 force; run;
    proc datasets lib=work nolist nowarn; delete _sqf_mf1; quit;
    %if &SQF_ITER_STATUS = COMPLETED %then %do;
        %let _done = &_i;
        %let _prev = &_iterdir/outputs;
    %end;
    %else %if &SQF_ITER_STATUS = VALIDATED %then %do;
        %let _go = 0;   /* mode=VALIDATE checks iteration 1 only */
    %end;
    %else %let _go = 0;
    %let _i = %eval(&_i + 1);
%end;
libname _sqri "&SQF_RUNROOT";
%if %sysfunc(libref(_sqri)) = 0 %then %do;
    data _sqri.chain_manifest; set work._sqf_manifest; run;
    libname _sqri clear;
%end;
%local _final;
%if &SQF_ITER_STATUS = COMPLETED and &_done = &iterations %then %let _final = COMPLETED;
%else %if &SQF_ITER_STATUS = VALIDATED %then %let _final = VALIDATED;
%else %if &SQF_ITER_STATUS = VALIDATION_FAILED %then %let _final = VALIDATION_FAILED;
%else %let _final = FAILED;
%sqf_finish(status=&_final, iterations=&iterations, iter_done=&_done, onfail=&onfail)
%mend run_chain;

/* ---------------- public: run all active scenarios ---------------- */
%macro run_all(control=, control_type=AUTO, control_lib=WORK, base=, root=,
               main=, mode=FULL, inlib=, outlib=, prelude=, html=Y,
               onfail=RETURN, notes=);
%local _n _i _s _nbad;
/* peek at the control to enumerate active scenarios */
data work._sqf_verrors;
    length sev $1 scenario $32 step 8 field $32 message $500;
    call missing(of _all_);
    stop;
run;
%if %length(%superq(control)) = 0 %then %let control = &SQF_CONTROL;
%sqf_load_control(control=&control, control_type=&control_type, control_lib=&control_lib)
%sqf_validate_report()
%let _n = 0;
data _null_;
    set work._sqf_scenarios(where=(active = 'Y')) end=_e;
    call symputx(cats('_s_', _n_), scenario_id);
    if _e then call symputx('_n', _n_);
run;
%if &_n = 0 %then %do;
    %put WARNING: [SQF] run_all: no active scenarios found in the control file (see any findings above).;
    %return;
%end;
/* NOTE: named OUTSIDE the _sqf_ prefix - each %run_scenario cleans
   _sqf_: datasets and would otherwise wipe this accumulator          */
data work.sqf_run_summary;
    length scenario $32 run_id $64 status $20;
    call missing(of _all_);
    stop;
run;
%do _i = 1 %to &_n;
    %let _s = &&_s_&_i;
    %put NOTE: [SQF] ======== run_all: scenario &_s (&_i of &_n) ========;
    %run_scenario(scenario=&_s, control=&control, control_type=&control_type,
                  control_lib=&control_lib, base=&base, root=&root, main=&main,
                  mode=&mode, inlib=&inlib, outlib=&outlib, prelude=&prelude,
                  html=&html, onfail=RETURN, notes=%superq(notes))
    data work.sqf_ar1;
        length scenario $32 run_id $64 status $20;
        scenario = "&_s";
        run_id = symget('SQF_LAST_RUN_ID');
        status = symget('SQF_LAST_STATUS');
    run;
    proc append base=work.sqf_run_summary data=work.sqf_ar1 force; run;
    proc datasets lib=work nolist nowarn; delete sqf_ar1; quit;
%end;
title "[SQF] run_all summary (work.sqf_run_summary)";
proc print data=work.sqf_run_summary noobs; run;
title;
%let _nbad = 0;
proc sql noprint;
    select coalesce(sum(status not in ('COMPLETED','VALIDATED')), 0)
        into :_nbad trimmed from work.sqf_run_summary;
quit;
%if &_nbad > 0 %then %do;
    %put WARNING: [SQF] run_all: &_nbad scenario(s) did not complete - see work.sqf_run_summary.;
    %if %upcase(&onfail) = ABORT %then %do;
        %put ERROR: [SQF] onfail=ABORT: cancelling the submitted job.;
        %abort cancel;
    %end;
%end;
%mend run_all;

/* ---------------- public: scan the production program ---------------- */
%macro sqf_scan_program(main=);
%local _m;
%let _m = %sqf_norm_path(&main);
%if %length(&_m) = 0 %then %let _m = &SQF_MAIN;
%if %length(&_m) = 0 %then %do;
    %put ERROR: [SQF] scan_program: pass main= (or set it once with sqf_setup).;
    %return;
%end;
%if not %sysfunc(fileexist(&_m)) %then %do;
    %put ERROR: [SQF] scan_program: file not found: &_m;
    %return;
%end;
data work.sqf_program_scan;
    length line_no 8 kind $12 text $500;
    infile "&_m" lrecl=32767 truncover;
    input;
    line_no = _n_;
    _u = upcase(left(_infile_));
    kind = ' ';
    if prxmatch('/^\s*LIBNAME\s/i', _infile_) then kind = 'LIBNAME';
    else if index(_u, 'LIBNAME ') > 0 then kind = 'LIBNAME?';
    else if prxmatch('/^\s*FILENAME\s/i', _infile_) then kind = 'FILENAME';
    else if index(_u, 'INCLUDE') > 0 and index(_infile_, '25'x) > 0 then kind = 'INCLUDE';
    else if prxmatch('/PROC\s+(IMPORT|EXPORT)/i', _infile_) then kind = 'IMPORT/EXP';
    else if prxmatch('/["'']([A-Za-z]:[\\\/]|[\\\/][\\\/]|\/[A-Za-z0-9_])/', _infile_)
        then kind = 'PATH';
    if kind ne ' ' then do;
        text = substr(_infile_, 1, min(length(_infile_), 500));
        output;
    end;
    keep line_no kind text;
run;
title "[SQF] scan of %scan(&_m, -1, /) - statements to review before wiring into the framework";
title2 "LIBNAME lines decide whether the guard-pattern edit is needed (see docs/INTEGRATION.md)";
proc print data=work.sqf_program_scan noobs; run;
title;
%mend sqf_scan_program;

/* ---------------- public: write control templates ---------------- */
%macro sqf_make_template(dir=);
%local _d;
%let _d = %sqf_norm_path(&dir);
%if %length(&_d) = 0 %then %let _d = &SQF_ROOT/control;
%sqf_mkdir(&_d)
data _null_;
    file "&_d/scenarios.csv" lrecl=2000;
    put 'scenario_id,description,parent_scenario,active,notes';
    put 'BASELINE,Untouched inputs - reference run,,Y,';
    put 'RATEUP,Rate change scaled by the RATE_BUMP parameter,,Y,uses PARAMETERS';
    put 'RATEUP_AGED,Rate up AND everyone one year older,RATEUP,Y,inherits RATEUP steps';
run;
data _null_;
    file "&_d/steps.csv" lrecl=4000;
    put 'scenario_id,step_no,active,method,target_table,where_clause,key_vars,source,assignments,options,notes';
    put 'RATEUP,10,Y,SET_VALUES,RATES,,,,"rate_change = rate_change * &' 'RATE_BUMP.;",,bump every rate';
    put 'RATEUP_AGED,10,Y,SET_VALUES,POLICIES,"status = ''ACT''",,,"policy_age = policy_age + 1;",,age active policies';
    put 'RATEUP_AGED,20,Y,FILTER_ROWS,POLICIES,"status ne ''LAP''",,,,,drop lapsed policies';
run;
data _null_;
    file "&_d/parameters.csv" lrecl=2000;
    put 'name,value,scenario_id,notes';
    put 'RATE_BUMP,1.05,,global default';
    put 'RATE_BUMP,1.25,RATEUP_AGED,override just for this scenario';
run;
%put NOTE: [SQF] CSV control templates written to &_d;
/* xlsx attempt (needs SAS/ACCESS to PC Files) */
%sqf_load_csv_sheet(file=&_d/scenarios.csv,  sheet=SCENARIOS,  out=work._sqf_t1)
%sqf_load_csv_sheet(file=&_d/steps.csv,      sheet=STEPS,      out=work._sqf_t2)
%sqf_load_csv_sheet(file=&_d/parameters.csv, sheet=PARAMETERS, out=work._sqf_t3)
proc export data=work._sqf_t1 outfile="&_d/scenario_workbook.xlsx" dbms=xlsx replace;
    sheet="SCENARIOS";
run;
proc export data=work._sqf_t2 outfile="&_d/scenario_workbook.xlsx" dbms=xlsx replace;
    sheet="STEPS";
run;
proc export data=work._sqf_t3 outfile="&_d/scenario_workbook.xlsx" dbms=xlsx replace;
    sheet="PARAMETERS";
run;
%if %sysfunc(fileexist(&_d/scenario_workbook.xlsx)) %then
    %put NOTE: [SQF] Workbook template written to &_d/scenario_workbook.xlsx;
%else
    %put NOTE: [SQF] Workbook template could not be written (PC Files engine unavailable?). Use the CSVs.;
%let syscc = 0;
proc datasets lib=work nolist nowarn; delete _sqf_t1 _sqf_t2 _sqf_t3; quit;
%mend sqf_make_template;

%put NOTE: [SQF] SAS What-If Scenario Framework &SQF_VERSION loaded.;
%put NOTE: [SQF] Start with: %nrstr(%sqf_setup)(root=, base=, control=, main=) then %nrstr(%run_scenario)(scenario=).;

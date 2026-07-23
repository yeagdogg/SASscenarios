/*====================================================================
  WIF -- hook-based what-if kernel for SAS 9.4
  ====================================================================
  One %include gives you:

      %wif_init(scenario=..., rules=...)   activate a scenario
      %wif(tablename)                      hook: modify the table in
                                           place per the active rules
      %wif_off                             deactivate + restore
      %wif_report                          print the run log
      %wif_lint / %wif_run / %wif_save / %wif_rule

  With no scenario active every %wif() hook expands to NOTHING --
  hooks are safe to leave in production code permanently.

  IMPORTANT: this file must be %included unconditionally (autoexec or
  top of the program). An uncompiled %wif call is an ERROR, not a
  no-op -- the feature flag lives INSIDE the macro.

  Placement contract for %wif() calls (there is no way to detect a
  violation at macro time -- see docs/WIF_GUIDE.md):
    - open code only, immediately after a run; / quit;
    - never inside a DATA step or between PROC SQL statements
    - inside your own macros only at step boundaries
    - inside CALL EXECUTE only as call execute('<pct>nrstr(<pct>wif(t))')

  Naming: public macros wif*, internal macros _wif_*, work datasets
  work._wif_* (work.wif_log and work.wif_rules are user-facing),
  globals WIF_*. Do not use _wif_-prefixed names in your own code.
====================================================================*/

/* -------- globals bootstrap (idempotent across re-%includes) ------ */
%macro _wif_bootstrap();
%global WIF_ACTIVE WIF_RC WIF_ITER WIF_SCENARIO WIF_ONFAIL WIF_GEN
        WIF_FIRE WIF_GENDIR WIF_MAXHASH WIF_TABLE WIF_HOOK WIF_MSG
        WIF_RULES_SRC WIF_VERSION WIF_UTILRC WIF_AFF WIF_NB WIF_NA
        WIF_OPTS_SAVED WIF_PARAMSTR;
%if %length(&WIF_OPTS_SAVED) = 0 %then %let WIF_OPTS_SAVED = 0;
%if %length(&WIF_ACTIVE) = 0 %then %let WIF_ACTIVE = 0;
%if "&WIF_ACTIVE" ne "1" %then %let WIF_ACTIVE = 0;
%if %length(&WIF_GEN)     = 0 %then %let WIF_GEN     = 0;
%if %length(&WIF_FIRE)    = 0 %then %let WIF_FIRE    = 0;
%if %length(&WIF_ITER)    = 0 %then %let WIF_ITER    = 1;
%if %length(&WIF_ONFAIL)  = 0 %then %let WIF_ONFAIL  = STOP;
%if %length(&WIF_MAXHASH) = 0 %then %let WIF_MAXHASH = 500000000;
%if %length(&WIF_RC)      = 0 %then %let WIF_RC      = 0;
%let WIF_VERSION = 1.1.0;
%put NOTE: [WIF] wif.sas v&WIF_VERSION compiled. WIF_ACTIVE=&WIF_ACTIVE..;
%mend _wif_bootstrap;

/*------------------------------------------------------------------
  01. UTILITIES (ported from SQF, battle-tested at work)
------------------------------------------------------------------*/

/* Normalize a path: backslashes -> forward slashes, strip trailing
   slash. Forward slashes are valid on Windows SAS, Unix SAS, UNC.   */
%macro _wif_path(p);
%local _p;
%let _p = %superq(p);
%if %length(&_p) > 0 %then %do;
    %let _p = %sysfunc(translate(&_p, /, \));
    %if %length(&_p) > 1 %then %do;
        /* both operands quoted: a bare / in an %IF is DIVISION */
        %if "%qsubstr(&_p, %length(&_p), 1)" = "/" %then
            %let _p = %qsubstr(&_p, 1, %eval(%length(&_p)-1));
    %end;
%end;
&_p.
%mend _wif_path;

/* Recursive directory create via DCREATE (no X commands; NOXCMD
   safe). Sets WIF_UTILRC = 0 on success / already exists, 1 fail.   */
%macro _wif_mkdir(path);
%local _p _n _i _seg _cur _unc _parent _pl;
%let WIF_UTILRC = 0;
%let _p = %_wif_path(&path);
%if %length(&_p) = 0 %then %do;
    %put ERROR: [WIF] _wif_mkdir called with a blank path.;
    %let WIF_UTILRC = 1;
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
    /* server and share of a UNC path cannot be created -- skip */
    %if not (&_unc = 1 and &_i <= 2) %then %do;
        %if not %sysfunc(fileexist(&_cur)) %then %do;
            %let _pl = %eval(%length(&_cur) - %length(&_seg) - 1);
            %if &_pl < 1 %then %let _parent = .;
            %else %let _parent = %qsubstr(&_cur, 1, &_pl);
            %let _seg = %sysfunc(dcreate(&_seg, &_parent));
            %if not %sysfunc(fileexist(&_cur)) %then %do;
                %put ERROR: [WIF] Could not create directory: &_cur (check write permission - and that the path is the SAS SERVER%str(%')s, not your PC%str(%')s).;
                %let WIF_UTILRC = 1;
                %return;
            %end;
        %end;
    %end;
%end;
%if not %sysfunc(fileexist(&_p)) %then %do;
    %put ERROR: [WIF] Could not create directory: &_p;
    %let WIF_UTILRC = 1;
%end;
%mend _wif_mkdir;

/* Timestamp for log rows / notes */
%macro _wif_now();
%sysfunc(strip(%sysfunc(datetime(), datetime20.)))
%mend _wif_now;

/* Observation count -> macro var named by mvar (caller %locals it
   or it is one of the WIF_* globals). Views counted the hard way.   */
%macro _wif_nobs(ds=, mvar=);
%local _id _rc;
%let &mvar = .;
%let _id = %sysfunc(open(&ds));
%if &_id > 0 %then %do;
    %let &mvar = %sysfunc(attrn(&_id, nlobs));
    %if &&&mvar = -1 %then %do;
        %let &mvar = 0;
        %do %while(%sysfunc(fetch(&_id)) = 0);
            %let &mvar = %eval(&&&mvar + 1);
        %end;
    %end;
    %let _rc = %sysfunc(close(&_id));
%end;
%mend _wif_nobs;

/* Space-separated variable list of a dataset -> &mvar */
%macro _wif_varlist(ds=, mvar=);
%local _id _rc _i;
%let &mvar = ;
%let _id = %sysfunc(open(&ds));
%if &_id > 0 %then %do;
    %do _i = 1 %to %sysfunc(attrn(&_id, nvars));
        %let &mvar = &&&mvar %sysfunc(varname(&_id, &_i));
    %end;
    %let _rc = %sysfunc(close(&_id));
%end;
%mend _wif_varlist;

/* Variable type (C/N, blank if absent) -> &mvar */
%macro _wif_vartype(ds=, var=, mvar=);
%local _id _rc _n;
%let &mvar = ;
%let _id = %sysfunc(open(&ds));
%if &_id > 0 %then %do;
    %let _n = %sysfunc(varnum(&_id, &var));
    %if &_n > 0 %then %let &mvar = %sysfunc(vartype(&_id, &_n));
    %let _rc = %sysfunc(close(&_id));
%end;
%mend _wif_vartype;

/* Record one lint finding. Message text travels OUT OF BAND via the
   global WIF_MSG (set with %let just before the call) so commas,
   quotes and parentheses in messages can never break the call.      */
%macro _wif_lerr(sev=E, hook=, seq=., field=);
data work._wif_lerr_new;
    length sev $1 hook $32 seq 8 field $32 message $500;
    sev = "&sev"; hook = "&hook"; seq = &seq; field = "&field";
    message = symget('WIF_MSG');
run;
proc append base=work._wif_lerrs data=work._wif_lerr_new; run;
proc datasets lib=work nolist nowarn; delete _wif_lerr_new; quit;
%mend _wif_lerr;

/* Save / restore the session options WIF overrides. NOSYNTAXCHECK
   matters: one batch ERROR otherwise flips OBS=0 syntax-check mode
   and every later step "succeeds" against zero rows.                */
%macro _wif_opts_save();
%global WIF_OPT_OBS WIF_OPT_REPLACE WIF_OPT_SYNTAX WIF_OPTS_SAVED;
/* re-init without wif_off must NOT clobber the user's true settings
   with WIF's own overrides                                          */
%if "&WIF_OPTS_SAVED" ne "1" %then %do;
    %let WIF_OPT_OBS     = %sysfunc(getoption(obs));
    %let WIF_OPT_REPLACE = %sysfunc(getoption(replace));
    %let WIF_OPT_SYNTAX  = %sysfunc(getoption(syntaxcheck));
    %let WIF_OPTS_SAVED  = 1;
%end;
options obs=max replace nosyntaxcheck;
%mend _wif_opts_save;

%macro _wif_opts_restore();
%if %symexist(WIF_OPT_OBS) %then %do;
    %if %length(&WIF_OPT_OBS) > 0 %then %do;
        options obs=&WIF_OPT_OBS &WIF_OPT_REPLACE &WIF_OPT_SYNTAX;
    %end;
%end;
%let WIF_OPTS_SAVED = 0;
%mend _wif_opts_restore;

/* Append one row to work.wif_log. Message via WIF_MSG (out of band).
   The log survives %wif_init resets -- one session = one history.   */
%macro _wif_log(status=, hook=, seq=., verb=, target=, nb=., na=., aff=.);
%if not %sysfunc(exist(work.wif_log)) %then %do;
    data work.wif_log;
        length gen 8 scenario $32 iter 8 fire 8 hook $32 seq 8 verb $8
               target $41 status $12 rows_before 8 rows_after 8
               rows_affected 8 message $300 logged_at 8;
        format logged_at datetime20.;
        stop;
    run;
%end;
data work._wif_log_new;
    length gen 8 scenario $32 iter 8 fire 8 hook $32 seq 8 verb $8
           target $41 status $12 rows_before 8 rows_after 8
           rows_affected 8 message $500 logged_at 8;
    format logged_at datetime20.;
    gen = &WIF_GEN; scenario = "&WIF_SCENARIO"; iter = &WIF_ITER;
    fire = &WIF_FIRE; hook = "&hook"; seq = &seq; verb = "&verb";
    target = "&target"; status = "&status";
    rows_before = &nb; rows_after = &na; rows_affected = &aff;
    message = symget('WIF_MSG');
    logged_at = datetime();
run;
proc append base=work.wif_log data=work._wif_log_new; run;
proc datasets lib=work nolist nowarn; delete _wif_log_new; quit;
%let WIF_MSG = ;
%mend _wif_log;

/*------------------------------------------------------------------
  02. RULES LOADER
      One 13-column rules table, three ways in:
        rules=work.myrules          any dataset (programmatic "meta" mode)
        rules=/path/wb.xlsx         workbook, sheet RULES
        (CSV was cut from v1: EG imports a sheet to a dataset in
         two clicks, which is dataset mode.)
      Blank scenario on a row = GLOBAL = applies to every scenario.
------------------------------------------------------------------*/

/* Canonical schema. cols/typs/lens/reqs are positional lists.
   reqs=Y -> the column must exist in the input.                     */
%macro _wif_rules_meta();
%let _cols = scenario hook seq active verb target where_clause keys
             source columns assign options notes;
%let _typs = C C N C C C C C C C C C C;
%let _lens = 32 32 8 1 8 41 2000 200 41 1000 8000 200 500;
%let _reqs = N Y N N Y N N N N N N N N;
%mend _wif_rules_meta;

%macro _wif_empty_rules(out=);
%local _cols _typs _lens _reqs _i _c;
%_wif_rules_meta()
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
%mend _wif_empty_rules;

/* Coerce an arbitrary input dataset to the canonical schema.
   Numeric-typed cells keep what the user SAW (vvalue), and a
   missing numeric becomes BLANK, never a literal dot.               */
%macro _wif_type_rules(raw=, out=);
%local _cols _typs _lens _reqs _i _c _t _l _r _id _rc _vn _vt _ren _asn _n;
%_wif_rules_meta()
%let _n = %sysfunc(countw(&_cols));
%let _id = 0;
%if %sysfunc(exist(&raw)) %then %let _id = %sysfunc(open(&raw));
%if &_id <= 0 %then %do;
    %_wif_empty_rules(out=&out)
    %return;
%end;
%let _ren = ;
%let _asn = ;
%do _i = 1 %to &_n;
    %let _c = %scan(&_cols, &_i);
    %let _t = %scan(&_typs, &_i);
    %let _r = %scan(&_reqs, &_i);
    %let _vn = %sysfunc(varnum(&_id, &_c));
    %if &_vn > 0 %then %do;
        %let _vt = %sysfunc(vartype(&_id, &_vn));
        %let _ren = &_ren &_c = _r_&_c;
        %if &_t = C and &_vt = C %then %let _asn = &_asn &_c = strip(_r_&_c)%str(;);
        %else %if &_t = C and &_vt = N %then
            %let _asn = &_asn &_c = ifc(missing(_r_&_c), ' ', strip(vvalue(_r_&_c)))%str(;);
        %else %if &_t = N and &_vt = N %then %let _asn = &_asn &_c = _r_&_c%str(;);
        %else %let _asn = &_asn &_c = input(strip(_r_&_c), ?? best32.)%str(;);
    %end;
    %else %do;
        %if &_t = C %then %let _asn = &_asn &_c = ' '%str(;);
        %else %let _asn = &_asn &_c = .%str(;);
        %if &_r = Y %then %do;
            %let WIF_MSG = Rules input has no column &_c (required). Columns: scenario hook seq active verb target where_clause keys source columns assign options notes.;
            %_wif_lerr(sev=E, field=&_c)
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
%mend _wif_type_rules;

/* Cell cleanup: Excel smart characters -> ASCII, control chars ->
   spaces, comment/ghost row removal, structural upcasing, defaults. */
%macro _wif_clean_rules(ds=);
data &ds;
    set &ds;
    array _wif_txt {*} _character_;
    do _wif_i = 1 to dim(_wif_txt);
        /* tabs / CR / LF inside cells -> spaces */
        _wif_txt{_wif_i} = translate(_wif_txt{_wif_i}, '202020'x, '090D0A'x);
        /* utf-8 smart quotes / dashes / nbsp -> ASCII. MUST run
           before the single-byte pass (multi-byte sequences would
           otherwise be corrupted by the cp1252 translate)           */
        _wif_txt{_wif_i} = tranwrd(_wif_txt{_wif_i}, 'E28098'x, '27'x);
        _wif_txt{_wif_i} = tranwrd(_wif_txt{_wif_i}, 'E28099'x, '27'x);
        _wif_txt{_wif_i} = tranwrd(_wif_txt{_wif_i}, 'E2809C'x, '22'x);
        _wif_txt{_wif_i} = tranwrd(_wif_txt{_wif_i}, 'E2809D'x, '22'x);
        _wif_txt{_wif_i} = tranwrd(_wif_txt{_wif_i}, 'E28093'x, '2D'x);
        _wif_txt{_wif_i} = tranwrd(_wif_txt{_wif_i}, 'E28094'x, '2D'x);
        _wif_txt{_wif_i} = tranwrd(_wif_txt{_wif_i}, 'C2A0'x,   '20'x);
        /* cp1252 smart quotes / dashes / nbsp (wlatin1 sessions)    */
        _wif_txt{_wif_i} = translate(_wif_txt{_wif_i}, '272722222D2D20'x, '919293949697A0'x);
        _wif_txt{_wif_i} = strip(_wif_txt{_wif_i});
    end;
    drop _wif_i;
    /* comment rows: first cell of either id column starts with #    */
    if left(scenario) =: '#' then delete;
    if left(hook)     =: '#' then delete;
    /* ghost rows */
    if missing(hook) and missing(verb) and missing(scenario)
       and missing(assign) and missing(source) then delete;
    scenario = upcase(scenario);
    hook     = upcase(hook);
    verb     = upcase(strip(verb));
    target   = upcase(target);
    source   = upcase(source);
    keys     = upcase(compbl(keys));
    options  = upcase(compbl(options));
    active   = upcase(active);
    if active = ' ' then active = 'Y';
run;
/* default seq: sheet order x 10, applied where seq is missing       */
data &ds;
    set &ds;
    if missing(seq) then seq = _n_ * 10;
run;
%mend _wif_clean_rules;

/* XLSX loader: sheet RULES via the xlsx libname engine, PROC IMPORT
   as fallback (engine unavailable / workbook open in Excel).        */
%macro _wif_load_xlsx(file=, out=);
%local _ok _f _svcc;
%let _ok = 0;
%let _f  = %_wif_path(&file);
%if not %sysfunc(fileexist(&_f)) %then %do;
    %let WIF_MSG = Workbook not found: &_f (the path must be visible to the SAS SERVER, not just your PC).;
    %_wif_lerr(sev=E, field=RULES)
    %return;
%end;
/* a failed engine probe poisons SYSCC; if the PROC IMPORT fallback
   then succeeds we must restore, or every later hook would take the
   SKIP_SYSCC gate                                                   */
%let _svcc = &syscc;
libname _wifxl xlsx "&_f";
%if &syslibrc = 0 %then %do;
    %if %sysfunc(exist(_wifxl.RULES)) %then %do;
        data &out; set _wifxl.RULES; run;
        %let _ok = 1;
    %end;
    libname _wifxl clear;
    %if &_ok = 0 %then %do;
        %let WIF_MSG = Workbook has no sheet named RULES. Rename the sheet to RULES, or start from template/wif_workbook.xlsx.;
        %_wif_lerr(sev=E, field=RULES)
    %end;
%end;
%else %do;
    proc import datafile="&_f" dbms=xlsx out=&out replace;
        sheet="RULES";
        getnames=yes;
    run;
    %if %sysfunc(exist(&out)) %then %do;
        %let _ok = 1;
        %let syscc = &_svcc;
        %put NOTE: [WIF] xlsx engine unavailable - PROC IMPORT fallback read the workbook.;
    %end;
    %else %do;
        %let WIF_MSG = Could not read sheet RULES from &_f.. Check SAS/ACCESS to PC Files licensing, that the path is visible to the SAS server, and that the workbook is not open in Excel. Fallback: import the sheet to a dataset in EG and pass rules=that-dataset.;
        %_wif_lerr(sev=E, field=RULES)
    %end;
%end;
%mend _wif_load_xlsx;

/* Load + normalize + scenario-filter. Produces:
     work._wif_rules  rules for &scenario (+ globals), LET rows out
     work._wif_lets   LET rows (param name/value), scenario-specific
                      overriding global on name collisions
   Sets WIF_LOADN (rule count). Errors land in work._wif_lerrs.      */
%macro _wif_load_rules(rules=, scenario=);
%global WIF_LOADN;
%local _r _ext;
%let WIF_LOADN = 0;
%let _r = %superq(rules);
%if %length(&_r) = 0 %then %do;
    %let WIF_MSG = rules= is required (a dataset name or a workbook .xlsx path).;
    %_wif_lerr(sev=E, field=RULES)
    %return;
%end;
%let _ext = %upcase(%qscan(&_r, -1, .));
/* quoted comparisons: a path value would otherwise reach %EVAL      */
%if "&_ext" = "XLSX" or "&_ext" = "XLSM" %then %do;
    %_wif_load_xlsx(file=&_r, out=work._wif_rules_raw)
    %if not %sysfunc(exist(work._wif_rules_raw)) %then %return;
%end;
%else %do;
    %if not %sysfunc(exist(&_r)) %then %do;
        %let WIF_MSG = Rules dataset &_r not found. Check the name (LIBREF.DATASET) and that the step creating it ran in THIS session.;
        %_wif_lerr(sev=E, field=RULES)
        %return;
    %end;
    data work._wif_rules_raw; set &_r; run;
%end;
%_wif_type_rules(raw=work._wif_rules_raw, out=work._wif_rules_all)
%_wif_clean_rules(ds=work._wif_rules_all)

/* keep this scenario + globals; drop active=N (recorded as skipped
   at fire time only if you list them -- keeping the kernel lean)    */
data work._wif_rules work._wif_lets(keep=scenario name value);
    length name $32 value $8000;    /* match the assign column - a LET
                                       value must never truncate silently */
    set work._wif_rules_all;
    where scenario in (' ', "%upcase(&scenario)");
    if active = 'N' then delete;
    if verb = 'LET' then do;
        name  = upcase(strip(target));
        value = strip(assign);
        output work._wif_lets;
        delete;
    end;
    output work._wif_rules;
run;
/* scenario-specific LET wins over global LET on the same name       */
proc sort data=work._wif_lets;
    by name scenario;    /* blank scenario sorts first */
run;
data work._wif_lets;
    set work._wif_lets;
    by name;
    if last.name;
run;
proc sort data=work._wif_rules;
    by hook seq;
run;
%_wif_nobs(ds=work._wif_rules, mvar=WIF_LOADN)
proc datasets lib=work nolist nowarn;
    delete _wif_rules_raw _wif_rules_all;
quit;
%put NOTE: [WIF] Loaded &WIF_LOADN rule(s) for scenario %upcase(&scenario) from &_r..;
%mend _wif_load_rules;

/*------------------------------------------------------------------
  03. LINT + LITERAL PARAMETER SUBSTITUTION
      Cell text NEVER enters the macro processor. Parameters are
      substituted as literals by a quote-aware character scanner;
      the only live references allowed to survive are the built-ins
      WIF_TABLE / WIF_HOOK (whitelisted; resolved at %include time
      from globals the hook sets per firing).
------------------------------------------------------------------*/

/* Build work._wif_params from LET rows + the params= init argument
   + built-ins. params= is pipe-delimited: rate_bump=0.03|as_of='01JAN2026'd
   Precedence (last wins): LET global < LET scenario < params= < built-ins. */
%macro _wif_build_params(scenario=, iter=);
%global WIF_PARAMSTR;
data work._wif_params0;
    length name $32 value $8000 _ord 8;
    set work._wif_lets(keep=name value);
    _ord = 1;
run;
data work._wif_params1;
    length name $32 value $8000 _ord 8 _s $32767 _tok $8200;
    _ord = 2;
    _s = symget('WIF_PARAMSTR');
    if lengthn(_s) > 0 then do _wi = 1 to countw(_s, '|');
        _tok = scan(_s, _wi, '|');
        _wp  = index(_tok, '=');
        if _wp <= 1 then do;
            name  = '_BAD_';
            value = strip(_tok);
            output;
        end;
        else do;
            name  = upcase(strip(substr(_tok, 1, _wp - 1)));
            value = strip(substr(_tok, _wp + 1));
            output;
        end;
    end;
    keep name value _ord;
run;
/* built-ins last so they always win; scenario and iter were
   validated by wif_init before this runs                            */
data work._wif_params2;
    length name $32 value $8000 _ord 8;
    _ord = 3;
    name = 'WIF_ITER';     value = "&iter";              output;
    name = 'WIF_SCENARIO'; value = "%upcase(&scenario)"; output;
    keep name value _ord;
run;
data work._wif_params;
    set work._wif_params0 work._wif_params1 work._wif_params2;
run;
/* bad tokens / reserved names -> lint errors */
data work._wif_perr;
    length sev $1 hook $32 seq 8 field $32 message $500;
    set work._wif_params;
    sev = 'E'; hook = ' '; seq = .; field = 'PARAMS';
    if name = '_BAD_' then do;
        message = catx(' ', 'params= token has no name=value form:', value);
        output;
    end;
    else if _ord < 3 and name =: 'WIF' then do;
        message = catx(' ', 'Parameter name', name,
                       'is reserved (WIF prefix). Rename it.');
        output;
    end;
    else if not nvalid(strip(name), 'v7') then do;
        message = catx(' ', 'Invalid parameter name:', name);
        output;
    end;
    keep sev hook seq field message;
run;
proc append base=work._wif_lerrs data=work._wif_perr force; run;
/* last definition wins */
proc sort data=work._wif_params; by name _ord; run;
data work._wif_params;
    set work._wif_params;
    by name;
    if last.name;
    if name in ('_BAD_') then delete;
    drop _ord;
run;
proc datasets lib=work nolist nowarn;
    delete _wif_params0 _wif_params1 _wif_params2 _wif_perr;
quit;
%mend _wif_build_params;

/* The scanner: walks where_clause / source / assign character by
   character. Outside single quotes it substitutes parameter values
   as literals, whitelists the WIF_TABLE / WIF_HOOK built-ins, and
   flags every other live macro trigger, unbalanced quote/paren and
   comment token. Also classifies where clauses that use WHERE-only
   operators (illegal or DIFFERENT in IF context, like <>).          */
%macro _wif_scan_rules();
data work._wif_rules(keep=scenario hook seq active verb target where_clause
                          keys source columns assign options notes where_ops)
     work._wif_scanerr(keep=sev hook seq field message);
    length sev $1 field $32 message $500 where_ops $1;
    array _pnm {220} $32   _temporary_;
    array _pvl {220} $8000 _temporary_;
    retain _pc 0;
    if _n_ = 1 then do;
        do _pi = 1 to min(_pn, 217);
            set work._wif_params(keep=name value) point=_pi nobs=_pn;
            _pnm{_pi} = upcase(name);
            _pvl{_pi} = value;
        end;
        _pc = min(_pn, 217);
        if _pn > 217 then do;
            sev='E'; field='PARAMS';
            message='More than 217 parameters defined; reduce LET rows / params=.';
            output work._wif_scanerr;
        end;
    end;
    set work._wif_rules;
    where_ops = 'N';

    length _txt _buf _mbuf _ntxt $32767 _fld $32 _nm $65 _vv $8000 _ch _nx _ck $1;
    array _tv {3} where_clause source assign;

    do _ti = 1 to 3;
        _fld = upcase(scan('where_clause source assign', _ti, ' '));
        _txt = _tv{_ti};
        if lengthn(_txt) = 0 then continue;
        _buf = ''; _mbuf = '';
        _bl = 0;                 /* current buffer length            */
        _st = 0;                 /* 0=outside 1=single-q 2=double-q  */
        _dp = 0;                 /* paren depth outside quotes       */
        _i  = 1;
        _len = lengthn(_txt);
        _ovf = 0;
        _nsub = 0;               /* substitutions done in this cell  */
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
                        output work._wif_scanerr;
                        _dp = 0;
                    end;
                end;
                else if _ch = '/' and _nx = '*' then do;
                    sev='E'; field=_fld;
                    message=catx(' ', 'Comment tokens are not allowed in', _fld,
                                 'cells; use the NOTES column.');
                    output work._wif_scanerr;
                    _i = _i + 2;
                end;
                else if _ch = '*' and _nx = '/' then do;
                    sev='E'; field=_fld;
                    message=catx(' ', 'Comment tokens are not allowed in', _fld,
                                 'cells; use the NOTES column.');
                    output work._wif_scanerr;
                    _i = _i + 2;
                end;
                else do; link addv; _i = _i + 1; end;
            end;
        end;
        if _st ne 0 then do;
            sev='E'; field=_fld;
            message=catx(' ', 'Unbalanced quote in', _fld, 'cell.');
            output work._wif_scanerr;
        end;
        if _dp ne 0 then do;
            sev='E'; field=_fld;
            message=catx(' ', 'Unbalanced ( in', _fld, 'cell.');
            output work._wif_scanerr;
        end;
        if _ovf = 1 then do;
            sev='E'; field=_fld;
            message=catx(' ', _fld, 'cell exceeds 32767 characters after parameter substitution.');
            output work._wif_scanerr;
        end;
        else if lengthn(_buf) > vlength(_tv{_ti}) then do;
            sev='E'; field=_fld;
            message=catx(' ', _fld, 'cell exceeds', put(vlength(_tv{_ti}), best8.-l),
                         'characters after parameter substitution.');
            output work._wif_scanerr;
        end;
        /* statement-like tokens -> error, except CODE (full steps
           are the point of CODE)                                    */
        if verb ne 'CODE' then do;
            if prxmatch('/\b(DATA|PROC|LIBNAME|FILENAME|ENDSAS|MERGE|INFILE)\b/i', _mbuf) or
               prxmatch('/\b(RUN|QUIT|OUTPUT|STOP|ABORT|DELETE)\s*;/i', _mbuf) or
               prxmatch('/\bCALL\s+EXECUTE\b/i', _mbuf) then do;
                sev='E'; field=_fld;
                message=catx(' ', _fld, 'cell contains statement-like tokens. Cells hold assignments/conditions only; use a CODE rule for full steps.');
                output work._wif_scanerr;
            end;
        end;
        /* classify where clauses using WHERE-only operators          */
        if _ti = 1 then do;
            if prxmatch('/\b(LIKE|CONTAINS|BETWEEN|SOUNDS)\b|\bIS\s+(NOT\s+)?(NULL|MISSING)\b|\bSAME\s+AND\b|=\*|\?|<>|></i', _mbuf)
                then where_ops = 'Y';
        end;
        _tv{_ti} = _buf;
    end;
    output work._wif_rules;
    return;

  addv:  /* append _ch, visible in the operator-check mask */
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

  addw:  /* append _ch, masked as blank (whitelisted live built-in) */
    if _bl >= 32767 then _ovf = 1;
    else do;
        _bl + 1;
        substr(_buf,  _bl, 1) = _ch;
        substr(_mbuf, _bl, 1) = ' ';
    end;
  return;

  trig:  /* live macro trigger character ('26'x amp / '25'x pct) */
    if _ch = '25'x then do;
        sev='E'; field=_fld;
        message=catx(' ', 'Percent sign outside single quotes in', _fld,
                     'cell. Macro triggers are not allowed; quote literals in single quotes or use a CODE rule.');
        output work._wif_scanerr;
        _i = _i + 1;
    end;
    else if _nx = '26'x then do;
        sev='E'; field=_fld;
        message=catx(' ', 'Doubled ampersand (indirect reference) is not supported in', _fld, 'cell.');
        output work._wif_scanerr;
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
            output work._wif_scanerr;
            _i = _i + 1;
        end;
        else if upcase(_nm) in ('WIF_TABLE', 'WIF_HOOK') then do;
            /* intended live reference; keep it verbatim (with its
               delimiter dot if present) for %include-time resolution */
            _ch = '26'x;              link addw;
            do _wj = 1 to lengthn(_nm);
                _ch = char(_nm, _wj); link addw;
            end;
            _i = _k;
            if _i <= _len then do;
                if char(_txt, _i) = '.' then do;
                    _ch = '.'; link addw;
                    _i = _i + 1;
                end;
            end;
        end;
        else do;
            _hit = 0;
            do _pi = 1 to _pc while (_hit = 0);
                if _pnm{_pi} = upcase(_nm) then _hit = _pi;
            end;
            if _hit = 0 then do;
                sev='E'; field=_fld;
                message=catx(' ', cats('Unknown parameter ', '26'x, _nm), 'in', _fld,
                             'cell. Define it with a LET rule or params=.');
                output work._wif_scanerr;
                _i = _k;
                if _i <= _len then if char(_txt, _i) = '.' then _i = _i + 1;
            end;
            else do;
                /* INJECT the value into the scan stream and RESCAN it:
                   value characters must pass through the same quote /
                   paren state machine and stay VISIBLE to the operator
                   and statement-token checks. (The old splice bypassed
                   both, letting an unbalanced quote or a WHERE-only
                   operator inside a parameter VALUE through the lint.) */
                _vv = _pvl{_hit};
                _vl = lengthn(_vv);
                _k2 = _k;
                /* one trailing dot delimits the reference, SAS-style */
                if _k2 <= _len then if char(_txt, _k2) = '.' then _k2 = _k2 + 1;
                _rl = 0;
                if _k2 <= _len then _rl = _len - _k2 + 1;
                _nsub + 1;
                if _nsub > 200 then do;
                    sev='E'; field=_fld;
                    message=catx(' ', 'More than 200 parameter substitutions in one',
                                 _fld, 'cell - circular LET references?');
                    output work._wif_scanerr;
                    _i = _len + 1;
                end;
                else if _vl + _rl > 32767 then do;
                    _ovf = 1;
                    _i = _len + 1;
                end;
                else do;
                    _ntxt = ' ';
                    if _vl > 0 then substr(_ntxt, 1, _vl) = substr(_vv, 1, _vl);
                    if _rl > 0 then substr(_ntxt, _vl + 1, _rl) = substr(_txt, _k2, _rl);
                    _txt = _ntxt;
                    _len = _vl + _rl;
                    _i = 1;
                end;
            end;
        end;
    end;
  return;
run;

/* second pass: substitution must not have introduced live triggers
   (a parameter VALUE containing an ampersand), except the
   whitelisted built-ins.                                            */
data work._wif_scanerr2(keep=sev hook seq field message);
    length sev $1 field $32 message $500 _nm $65 _ck $1;
    set work._wif_rules;
    length _txt $32767 _fld $32 _ch $1;
    array _tv {3} where_clause source assign;
    do _ti = 1 to 3;
        _fld = upcase(scan('where_clause source assign', _ti, ' '));
        _txt = _tv{_ti};
        _st = 0;
        _n2 = lengthn(_txt);
        _i = 1;
        do while (_i <= _n2);
            _ch = char(_txt, _i);
            if _st = 1 then do;
                if _ch = "'" then _st = 0;
                _i = _i + 1;
            end;
            else if _ch = "'" then do; _st = 1; _i = _i + 1; end;
            else if _ch = '26'x then do;
                /* allow the whitelisted built-ins only */
                _j = _i + 1; _nm = '';
                do while (_j <= _n2);
                    _ck = char(_txt, _j);
                    if (_ck >= 'A' and _ck <= 'Z') or (_ck >= 'a' and _ck <= 'z')
                       or _ck = '_' or ((_ck >= '0' and _ck <= '9') and _j > _i + 1)
                        then do; _nm = cats(_nm, _ck); _j = _j + 1; end;
                    else _j = _n2 + 9999;
                end;
                if upcase(_nm) in ('WIF_TABLE', 'WIF_HOOK') then
                    _i = _i + 1 + lengthn(_nm);
                else do;
                    sev='E'; field=_fld;
                    message=catx(' ', 'Parameter substitution left a live macro trigger in',
                                 _fld, 'cell (check parameter values for ampersand / percent characters).');
                    output;
                    _i = _n2 + 1;
                end;
            end;
            else if _ch = '25'x then do;
                sev='E'; field=_fld;
                message=catx(' ', 'Parameter substitution left a live macro trigger in',
                             _fld, 'cell (check parameter values for ampersand / percent characters).');
                output;
                _i = _n2 + 1;
            end;
            else _i = _i + 1;
        end;
    end;
run;
proc append base=work._wif_lerrs data=work._wif_scanerr  force; run;
proc append base=work._wif_lerrs data=work._wif_scanerr2 force; run;
proc datasets lib=work nolist nowarn; delete _wif_scanerr _wif_scanerr2; quit;
%mend _wif_scan_rules;

/* Structural checks + options parsing, AFTER substitution. Augments
   work._wif_rules with parsed flags the executor reads directly.    */
%macro _wif_check_rules();
data work._wif_rules(keep=scenario hook seq active verb target where_clause
                          keys source columns assign options notes where_ops
                          opt_once opt_iters opt_newcols opt_nowarn0 opt_drop
                          opt_keepextra opt_allowlib opt_last opt_nomatch
                          has_where has_assign has_cols)
     work._wif_ckerr(keep=sev hook seq field message);
    length sev $1 field $32 message $500
           opt_once opt_newcols opt_nowarn0 opt_drop opt_keepextra
           opt_allowlib opt_last 8 opt_iters $8 opt_nomatch $6
           has_where has_assign has_cols 8
           _wif_t _wif_t2 $200 _wif_n $41 _wif_p1 _wif_p2 $32;
    set work._wif_rules;
    opt_once = 0; opt_newcols = 0; opt_nowarn0 = 0; opt_drop = 0;
    opt_keepextra = 0; opt_allowlib = 0; opt_last = 0;
    opt_iters = 'ALL'; opt_nomatch = 'KEEP';
    has_where  = (lengthn(where_clause) > 0);
    has_assign = (lengthn(assign) > 0);
    has_cols   = (lengthn(columns) > 0);

    /* ---- hook name ---- */
    if lengthn(hook) = 0 then do;
        sev='E'; field='HOOK';
        message='Blank hook. Use a table name, INPUT, or a custom hook name.';
        output work._wif_ckerr;
    end;
    else if hook ne 'INPUT' then do;
        if not nvalid(strip(hook), 'v7') or lengthn(hook) > 32 then do;
            sev='E'; field='HOOK';
            message=catx(' ', 'Invalid hook name:', hook,
                         '(letters, digits, underscore; must start with a letter or underscore; max 32).');
            output work._wif_ckerr;
        end;
    end;

    /* ---- verb ---- */
    if verb not in ('SET','JOIN','FILTER','APPEND','REPLACE','CODE',
                    'ASSERT','SAVE','SORT','DEDUPE') then do;
        sev='E'; field='VERB';
        message=catx(' ', 'Unknown verb:', verb,
                     '- use SET JOIN FILTER APPEND REPLACE CODE ASSERT SAVE SORT DEDUPE or LET.');
        output work._wif_ckerr;
    end;

    /* ---- options tokens ---- */
    do _wif_i = 1 to countw(options, ' ');
        _wif_t = scan(options, _wif_i, ' ');
        if _wif_t = 'ONCE' then opt_once = 1;
        else if _wif_t = 'NEWCOLS' then opt_newcols = 1;
        else if _wif_t = 'NOWARN0' then opt_nowarn0 = 1;
        else if _wif_t = 'DROP' then opt_drop = 1;
        else if _wif_t = 'KEEPEXTRA' then opt_keepextra = 1;
        else if _wif_t = 'ALLOWLIB' then opt_allowlib = 1;
        else if _wif_t =: 'ITERS=' then do;
            opt_iters = strip(substr(_wif_t, 7));
            _wif_ok = 0;
            if opt_iters = 'ALL' then _wif_ok = 1;
            else do;
                _wif_t2 = opt_iters;
                if lengthn(_wif_t2) > 1 then do;
                    if substr(_wif_t2, lengthn(_wif_t2), 1) = '+' then
                        _wif_t2 = substr(_wif_t2, 1, lengthn(_wif_t2) - 1);
                end;
                if lengthn(_wif_t2) > 0
                   and lengthn(compress(_wif_t2, '0123456789')) = 0 then _wif_ok = 1;
            end;
            if _wif_ok = 0 then do;
                sev='E'; field='OPTIONS';
                message=catx(' ', 'Bad ITERS= value:', opt_iters, '- use ITERS=1, ITERS=2+, ITERS=ALL.');
                output work._wif_ckerr;
            end;
        end;
        else if _wif_t = 'LAST' then opt_last = 1;
        else if _wif_t =: 'NOMATCH=' then do;
            opt_nomatch = strip(substr(_wif_t, 9));
            if opt_nomatch not in ('KEEP','FAIL','DELETE') then do;
                sev='E'; field='OPTIONS';
                message=catx(' ', 'Bad NOMATCH= value:', opt_nomatch,
                             '- use NOMATCH=KEEP, NOMATCH=FAIL or NOMATCH=DELETE.');
                output work._wif_ckerr;
            end;
        end;
        else do;
            sev='E'; field='OPTIONS';
            message=catx(' ', 'Unknown option token:', _wif_t,
                         '- known: ONCE ITERS= NEWCOLS NOWARN0 DROP KEEPEXTRA ALLOWLIB LAST NOMATCH=.');
            output work._wif_ckerr;
        end;
    end;
    if opt_drop = 1 and verb ne 'FILTER' then do;
        sev='E'; field='OPTIONS';
        message='DROP applies to FILTER rules only.';
        output work._wif_ckerr;
    end;
    if opt_keepextra = 1 and verb ne 'REPLACE' then do;
        sev='E'; field='OPTIONS';
        message='KEEPEXTRA applies to REPLACE rules only.';
        output work._wif_ckerr;
    end;
    if opt_newcols = 1 and verb not in ('SET','JOIN','APPEND') then do;
        sev='E'; field='OPTIONS';
        message='NEWCOLS applies to SET, JOIN and APPEND rules only.';
        output work._wif_ckerr;
    end;
    if opt_last = 1 and verb ne 'DEDUPE' then do;
        sev='E'; field='OPTIONS';
        message='LAST applies to DEDUPE rules only.';
        output work._wif_ckerr;
    end;
    if opt_nomatch ne 'KEEP' and verb ne 'JOIN' then do;
        sev='E'; field='OPTIONS';
        message='NOMATCH= applies to JOIN rules only.';
        output work._wif_ckerr;
    end;
    if opt_nowarn0 = 1 and verb = 'ASSERT' then do;
        sev='E'; field='OPTIONS';
        message='NOWARN0 does not apply to ASSERT (zero violations IS the passing outcome).';
        output work._wif_ckerr;
    end;

    /* ---- per-verb requirement matrix ---- */
    if verb = 'SET' then do;
        if not has_assign then do;
            sev='E'; field='ASSIGN';
            message='SET needs assignment statements in the assign column.';
            output work._wif_ckerr;
        end;
        if lengthn(source) > 0 or lengthn(keys) > 0 or has_cols then do;
            sev='E'; field='SOURCE';
            message='SET uses where_clause + assign only; source/keys/columns must be blank.';
            output work._wif_ckerr;
        end;
        /* where_ops='Y' is fine for SET: codegen auto-routes to the
           order-preserving WHERE-split path, where LIKE/BETWEEN/
           IS MISSING work and <> means NE (real WHERE semantics)     */
    end;
    else if verb = 'JOIN' then do;
        if lengthn(keys) = 0 then do;
            sev='E'; field='KEYS';
            message='JOIN needs key_vars in the keys column.';
            output work._wif_ckerr;
        end;
        if lengthn(source) = 0 then do;
            sev='E'; field='SOURCE';
            message='JOIN needs a source table.';
            output work._wif_ckerr;
        end;
        if has_where and where_ops = 'Y' then do;
            sev='E'; field='WHERE_CLAUSE';
            message='JOIN where clauses use IF syntax (they gate the lookup row by row). Rewrite WHERE-only operators; see the SET message.';
            output work._wif_ckerr;
        end;
    end;
    else if verb = 'FILTER' then do;
        if not has_where then do;
            sev='E'; field='WHERE_CLAUSE';
            message='FILTER needs a where_clause (full WHERE syntax is allowed here).';
            output work._wif_ckerr;
        end;
        if lengthn(source) > 0 or lengthn(keys) > 0 or has_cols or has_assign then do;
            sev='E'; field='SOURCE';
            message='FILTER uses where_clause only; source/keys/columns/assign must be blank.';
            output work._wif_ckerr;
        end;
    end;
    else if verb = 'APPEND' then do;
        if lengthn(source) = 0 then do;
            sev='E'; field='SOURCE';
            message='APPEND needs a source table.';
            output work._wif_ckerr;
        end;
        if lengthn(keys) > 0 or has_assign then do;
            sev='E'; field='KEYS';
            message='APPEND uses source + columns (+ where_clause on the SOURCE); keys/assign must be blank.';
            output work._wif_ckerr;
        end;
    end;
    else if verb = 'REPLACE' then do;
        if lengthn(source) = 0 then do;
            sev='E'; field='SOURCE';
            message='REPLACE needs a source table.';
            output work._wif_ckerr;
        end;
        if has_where or lengthn(keys) > 0 or has_assign then do;
            sev='E'; field='WHERE_CLAUSE';
            message='REPLACE swaps the whole table; where/keys/assign must be blank.';
            output work._wif_ckerr;
        end;
    end;
    else if verb = 'CODE' then do;
        if not has_assign then do;
            sev='E'; field='ASSIGN';
            message='CODE needs the code text in the assign column (snippet files are not supported in v1).';
            output work._wif_ckerr;
        end;
        if lengthn(source) > 0 or lengthn(keys) > 0 or has_cols or has_where then do;
            sev='E'; field='SOURCE';
            message='CODE uses the assign column only; put conditions inside the code.';
            output work._wif_ckerr;
        end;
    end;
    else if verb = 'ASSERT' then do;
        if not has_where then do;
            sev='E'; field='WHERE_CLAUSE';
            message='ASSERT needs a where_clause stating the condition EVERY row must satisfy (full WHERE syntax allowed). Rows failing it are violations.';
            output work._wif_ckerr;
        end;
        if lengthn(source) > 0 or lengthn(keys) > 0 or has_cols or has_assign then do;
            sev='E'; field='SOURCE';
            message='ASSERT uses where_clause only; source/keys/columns/assign must be blank.';
            output work._wif_ckerr;
        end;
    end;
    else if verb = 'SAVE' then do;
        if lengthn(source) = 0 then do;
            sev='E'; field='SOURCE';
            message='SAVE needs the DESTINATION dataset name in the source column (parameters allowed, e.g. a scenario-stamped name).';
            output work._wif_ckerr;
        end;
        if has_where or lengthn(keys) > 0 or has_cols or has_assign then do;
            sev='E'; field='WHERE_CLAUSE';
            message='SAVE uses the source column only (as the destination); where/keys/columns/assign must be blank.';
            output work._wif_ckerr;
        end;
    end;
    else if verb = 'SORT' then do;
        if lengthn(keys) = 0 then do;
            sev='E'; field='KEYS';
            message='SORT needs key variables in the keys column (DESCENDING before a name is allowed).';
            output work._wif_ckerr;
        end;
        if has_where or lengthn(source) > 0 or has_cols or has_assign then do;
            sev='E'; field='WHERE_CLAUSE';
            message='SORT uses keys only; where/source/columns/assign must be blank.';
            output work._wif_ckerr;
        end;
    end;
    else if verb = 'DEDUPE' then do;
        if lengthn(keys) = 0 then do;
            sev='E'; field='KEYS';
            message='DEDUPE needs key variables in the keys column (plain names; add the LAST option to keep the last row per key).';
            output work._wif_ckerr;
        end;
        if has_where or lengthn(source) > 0 or has_cols or has_assign then do;
            sev='E'; field='WHERE_CLAUSE';
            message='DEDUPE uses keys (plus the LAST option) only; where/source/columns/assign must be blank.';
            output work._wif_ckerr;
        end;
    end;

    /* ---- name syntax: target / source / keys / columns ---- */
    if lengthn(target) > 0 then do;
        link ckname;
    end;
    if hook = 'INPUT' then do;
        if lengthn(target) = 0 or countc(target, '.') ne 1 then do;
            sev='E'; field='TARGET';
            message='INPUT rules need a two-level target (libref.table) so WIF knows which library to stage.';
            output work._wif_ckerr;
        end;
        else if upcase(strip(scan(target, 1, '.'))) = 'WORK' then do;
            sev='E'; field='TARGET';
            message='INPUT rules stage PERMANENT inputs behind a readonly base. A WORK table needs no staging - hook it directly where it is created.';
            output work._wif_ckerr;
        end;
        if opt_once = 1 then do;
            sev='E'; field='OPTIONS';
            message='ONCE does not apply to INPUT rules (staging runs once per init by construction).';
            output work._wif_ckerr;
        end;
    end;
    if lengthn(source) > 0 and verb in ('JOIN','APPEND','REPLACE','SAVE') then do;
        _wif_n = source; link cknm2;
        if _wif_ok = 0 then do;
            sev='E'; field='SOURCE';
            message=catx(' ', 'Invalid source table name:', source);
            output work._wif_ckerr;
        end;
    end;
    if verb = 'JOIN' then do _wif_i = 1 to countw(keys, ' ');
        _wif_t = scan(keys, _wif_i, ' ');
        _wif_p1 = scan(_wif_t, 1, '=');
        _wif_p2 = scan(_wif_t, 2, '=');
        if countc(_wif_t, '=') > 1
           or not nvalid(strip(_wif_p1), 'v7')
           or (countc(_wif_t, '=') = 1 and not nvalid(strip(_wif_p2), 'v7')) then do;
            sev='E'; field='KEYS';
            message=catx(' ', 'Bad keys token:', _wif_t,
                         '- use key or srckey=targetkey, space-separated.');
            output work._wif_ckerr;
        end;
    end;
    else if verb in ('SORT','DEDUPE') then do _wif_i = 1 to countw(keys, ' ');
        if not nvalid(strip(scan(keys, _wif_i, ' ')), 'v7') then do;
            sev='E'; field='KEYS';
            message=catx(' ', 'Invalid key variable name:', scan(keys, _wif_i, ' '));
            output work._wif_ckerr;
        end;
    end;
    if has_cols and verb in ('JOIN','APPEND','REPLACE') then do _wif_i = 1 to countw(columns, ' ');
        _wif_t = scan(columns, _wif_i, ' ');
        _wif_p1 = scan(_wif_t, 1, '=');
        _wif_p2 = scan(_wif_t, 2, '=');
        if countc(_wif_t, '=') > 1
           or not nvalid(strip(_wif_p1), 'v7')
           or (countc(_wif_t, '=') = 1 and not nvalid(strip(_wif_p2), 'v7')) then do;
            sev='E'; field='COLUMNS';
            message=catx(' ', 'Bad columns token:', _wif_t,
                         '- use srccol or srccol=targetcol, space-separated.');
            output work._wif_ckerr;
        end;
    end;
    output work._wif_rules;
    return;

  ckname: /* target: one- or two-level valid name */
    _wif_n = target; link cknm2;
    if _wif_ok = 0 then do;
        sev='E'; field='TARGET';
        message=catx(' ', 'Invalid target table name:', target);
        output work._wif_ckerr;
    end;
  return;

  cknm2:  /* _wif_n -> _wif_ok */
    _wif_ok = 1;
    if countc(_wif_n, '.') > 1 then _wif_ok = 0;
    else if countc(_wif_n, '.') = 1 then do;
        if not nvalid(strip(scan(_wif_n, 1, '.')), 'v7') then _wif_ok = 0;
        if not nvalid(strip(scan(_wif_n, 2, '.')), 'v7') then _wif_ok = 0;
        if lengthn(strip(scan(_wif_n, 1, '.'))) > 8 then _wif_ok = 0;
    end;
    else do;
        if not nvalid(strip(_wif_n), 'v7') then _wif_ok = 0;
    end;
  return;
run;
proc append base=work._wif_lerrs data=work._wif_ckerr force; run;

/* duplicate (hook, seq) pairs */
proc sort data=work._wif_rules; by hook seq; run;
data work._wif_dupev(keep=sev hook seq field message);
    length sev $1 field $32 message $500;
    set work._wif_rules;
    by hook seq;
    if not (first.seq and last.seq) and first.seq then do;
        sev='E'; field='SEQ';
        message=catx(' ', 'Duplicate seq', put(seq, best8.-l), 'within hook', hook,
                     '- every rule on a hook needs a distinct seq.');
        output;
    end;
run;
proc append base=work._wif_lerrs data=work._wif_dupev force; run;
proc datasets lib=work nolist nowarn; delete _wif_ckerr _wif_dupev; quit;
%mend _wif_check_rules;

/* Count lint findings -> WIF_LINTE / WIF_LINTW; print when asked.   */
%macro _wif_lint_tally(print=Y);
%global WIF_LINTE WIF_LINTW;
%let WIF_LINTE = 0;
%let WIF_LINTW = 0;
%if %sysfunc(exist(work._wif_lerrs)) %then %do;
    proc sql noprint;
        select coalesce(sum(sev='E'),0), coalesce(sum(sev='W'),0)
            into :WIF_LINTE trimmed, :WIF_LINTW trimmed
            from work._wif_lerrs;
    quit;
%end;
%if &WIF_LINTE > 0 %then %do;
    %put ERROR: [WIF] &WIF_LINTE lint error(s) in the rules. Nothing was staged or modified.;
    %if &print = Y %then %do;
        title '[WIF] rule lint findings';
        proc print data=work._wif_lerrs noobs width=min;
        run;
        title;
    %end;
%end;
%else %if &WIF_LINTW > 0 %then
    %put WARNING: [WIF] &WIF_LINTW lint warning(s) - see work._wif_lerrs.;
%mend _wif_lint_tally;

/*------------------------------------------------------------------
  04. CODE GENERATION + EXECUTION HELPERS
      Every rule becomes a small generated .sas file under
      <WORK>/wif_gen/ (FILE/PUT emission -- cell text never passes
      through the macro processor) which is then %included. The
      debris in wif_gen/ is the audit trail of exactly what ran.
------------------------------------------------------------------*/

/* Snapshot "NAME:TYPE" tokens of a dataset's columns -> &mvar.      */
%macro _wif_snapcols(ds=, mvar=);
%local _id _rc _i;
%let &mvar = ;
%let _id = %sysfunc(open(&ds));
%if &_id > 0 %then %do;
    %do _i = 1 %to %sysfunc(attrn(&_id, nvars));
        %let &mvar = &&&mvar %upcase(%sysfunc(varname(&_id, &_i))):%sysfunc(vartype(&_id, &_i));
    %end;
    %let _rc = %sysfunc(close(&_id));
%end;
%mend _wif_snapcols;

/* Compare &ds against a prior snapshot. New columns are violations
   unless allownew=1 or the name is in expnew=; type changes always
   are. Sets WIF_CDRC (0 ok / 1 violation) + WIF_MSG.                */
%macro _wif_coldiff(snap=, ds=, allownew=0, expnew=);
%global WIF_CDRC;
%local _id _rc _i _nm _ty _tok _old _badnew _badtyp _expu _isexp;
%let WIF_CDRC = 0;
%let _badnew = ;
%let _badtyp = ;
%let _expu = %upcase(&expnew);
%let _id = %sysfunc(open(&ds));
%if &_id <= 0 %then %do;
    %let WIF_CDRC = 1;
    %let WIF_MSG = Could not open &ds for the column check.;
    %return;
%end;
%do _i = 1 %to %sysfunc(attrn(&_id, nvars));
    %let _nm = %upcase(%sysfunc(varname(&_id, &_i)));
    %let _ty = %sysfunc(vartype(&_id, &_i));
    /* find NAME:TYPE or NAME:othertype in the snapshot */
    %if %sysfunc(indexw(&snap, &_nm:&_ty, %str( ))) > 0 %then %do; %end;
    %else %if %sysfunc(indexw(&snap, &_nm:C, %str( ))) > 0
           or %sysfunc(indexw(&snap, &_nm:N, %str( ))) > 0 %then
        %let _badtyp = &_badtyp &_nm;
    %else %do;
        %let _isexp = 0;
        %if %length(&_expu) > 0 %then
            %if %sysfunc(indexw(&_expu, &_nm, %str( ))) > 0 %then %let _isexp = 1;
        %if &allownew = 1 %then %do; %end;
        %else %if &_isexp = 1 %then %do; %end;
        %else %let _badnew = &_badnew &_nm;
    %end;
%end;
%let _rc = %sysfunc(close(&_id));
%if %length(&_badtyp) > 0 %then %do;
    %let WIF_CDRC = 1;
    %let WIF_MSG = Column TYPE changed by this rule:&_badtyp (character/numeric flip is almost always a typo).;
%end;
%else %if %length(&_badnew) > 0 %then %do;
    %let WIF_CDRC = 1;
    %let WIF_MSG = Rule would CREATE new column(s):&_badnew (typo?). Add the NEWCOLS option if intentional.;
%end;
%mend _wif_coldiff;

/* Include one generated file, then immediately re-establish the
   options a failing include can poison (the batch OBS=0 trap).     */
%macro _wif_exec_gen(file=);
%include "%_wif_path(&file)" / source2 lrecl=32767;
options obs=max replace nosyntaxcheck;
%mend _wif_exec_gen;

/* Generate the .sas file for ONE rule (row &rulei of work._wif_todo).
     from=, to=     two-level, validated table names
     gfile=         output path
     mode=          MAIN or PF (SET preflight against obs=0)
     compress=      1 -> staged output gets compress=yes
   Prep introspection happens here (key/type/mapping/size checks);
   on a prep problem nothing usable is emitted and:
     WIF_PREPERR=1, WIF_MSG=reason
   Also sets: WIF_EXPNEW (JOIN mapped-new columns), WIF_HADIDX.      */
%macro _wif_gen_rule(rulei=, gfile=, from=, to=, mode=MAIN, compress=0);
%global WIF_PREPERR WIF_EXPNEW WIF_HADIDX;
%let WIF_PREPERR = 0;
%let WIF_EXPNEW  = ;
%let WIF_HADIDX  = 0;
data _null_;
    length _l $32767 _pc _amp $1;
    _pc  = '25'x;   /* percent  -- never write these literally in    */
    _amp = '26'x;   /* ampersand   strings inside a macro definition */
    _wp = &rulei;
    set work._wif_todo point=_wp nobs=_wn;

    length _perr 8 _pmsg $300;
    _perr = 0; _pmsg = ' ';

    length _sby _lbl $200 _dsopt $600 _atxt $8200;
    length _klist $200 _dlist _keeps _rens _cols $32767 _qk _qd $4000
           _msrc _mtgt _expn $32767 _w2 $32 _tok $200 _s1 _t1 $32;
    length _jto $41 _jfrom0 $12 _jhash0 $8 _jdsopt $600;
    length _kkeep $200 _kput $500 _ddso $600;

    /* ---------- prep: introspect FROM (and SRC when relevant) ----- */
    _fid = open("&from", 'i');
    if _fid <= 0 then do;
        _perr = 1; _pmsg = "Could not open &from at generation time.";
    end;
    else do;
        _sby = attrc(_fid, 'SORTEDBY');
        _lbl = attrc(_fid, 'LABEL');
        if attrn(_fid, 'ISINDEX') = 1 then call symputx('WIF_HADIDX', 1, 'G');
    end;

    _sid = 0;
    if _perr = 0 and verb in ('JOIN', 'APPEND', 'REPLACE') then do;
        _sid = open(strip(source), 'i');
        if _sid <= 0 then do;
            _perr = 1;
            _pmsg = catx(' ', 'Source table', source, 'could not be opened.');
        end;
    end;

    /* ---------- verb-specific prep ---------- */
    if _perr = 0 and verb = 'JOIN' then link jprep;
    if _perr = 0 and verb = 'APPEND' then link aprep;
    if _perr = 0 and verb = 'REPLACE' then link rprep;
    if _perr = 0 and verb = 'SET' then do;
        if has_where = 1 and where_ops = 'Y' then do;
            /* the split path tags rows with _WIF_SEQ_                */
            if varnum(_fid, '_WIF_SEQ_') > 0 then do;
                _perr = 1;
                _pmsg = "&from already has a column named _WIF_SEQ_ - the _wif_ name prefix is reserved by WIF.";
            end;
        end;
    end;
    if _perr = 0 and verb in ('SORT', 'DEDUPE') then link kprep;
    if _perr = 0 and verb = 'SAVE' then link vprep;

    /* assignment text: normalize the terminal semicolon             */
    _atxt = strip(assign);
    if lengthn(_atxt) > 0 then do;
        if substr(_atxt, lengthn(_atxt), 1) ne ';' then _atxt = cats(_atxt, ';');
    end;

    /* output dataset options (order-preserving verbs re-assert sort
       flag + label; APPEND breaks sort order; REPLACE takes source) */
    _dsopt = ' ';
    /* binary compression: actuarial tables are numeric-heavy, where
       RLE (compress=yes) does little and binary does well           */
    if "&compress" = '1' then _dsopt = 'compress=binary';
    if verb in ('SET', 'JOIN', 'FILTER') then do;
        if lengthn(_sby) > 0 then do;
            /* re-assert the sort flag ONLY when the rule provably does
               not touch a sort-key column: a false sortedby= makes a
               later PROC SORT skip itself ("already sorted") and every
               downstream BY-group silently wrong. Losing a valid flag
               costs one re-sort; stamping a false one costs the truth. */
            _sok = 1;
            if verb in ('SET', 'JOIN') then do;
                do _sk = 1 to countw(_sby, ' ');
                    _w2 = upcase(scan(_sby, _sk, ' '));
                    if _w2 ne 'DESCENDING' then do;
                        if lengthn(_atxt) > 0 then do;
                            if prxmatch(cats('/\b', strip(_w2), '\b/i'), _atxt) then _sok = 0;
                        end;
                        if verb = 'JOIN' then do;
                            if indexw(catx(' ', _mtgt, _keeps), _w2) > 0 then _sok = 0;
                        end;
                    end;
                end;
            end;
            if _sok = 1 then _dsopt = catx(' ', _dsopt, 'sortedby=' || strip(_sby));
        end;
    end;
    if verb in ('SET', 'JOIN', 'FILTER', 'APPEND') then do;
        if lengthn(_lbl) > 0 then
            _dsopt = catx(' ', _dsopt, "label='" || tranwrd(strip(_lbl), "'", "''") || "'");
    end;

    if _fid > 0 then _fid = close(_fid);
    if _sid > 0 then _sid = close(_sid);

    if _perr = 1 then do;
        call symputx('WIF_PREPERR', 1, 'G');
        call symputx('WIF_MSG', _pmsg, 'G');
        stop;
    end;

    /* ---------- emit ---------- */
    file "&gfile" lrecl=32767;
    _l = '/*==== [WIF] gen=' || strip(symget('WIF_GEN'))
         || ' iter=' || strip(symget('WIF_ITER'))
         || ' fire=' || strip(symget('WIF_FIRE'))
         || ' hook=' || strip(hook)
         || ' seq=' || strip(put(seq, best8.-l))
         || ' verb=' || strip(verb) || " mode=&mode ====*/"; link pl;
    _l = "/* target: &to   scenario: " || strip(symget('WIF_SCENARIO')) || ' */'; link pl;

    if "&mode" = 'PF' then do;
        if verb = 'JOIN' then do;
            /* JOIN preflight: the same hash join against zero rows on
               BOTH sides. It compiles the mapping and the assign cell
               and creates the definedata host variables, so the
               column check catches typos before any data moves.     */
            _jto = 'work._wif_pf';
            _jfrom0 = '(obs=0)';
            _jhash0 = 'obs=0 ';
            _jcnt = 0;
            _jdsopt = ' ';
            link jemit;
        end;
        else do;
            /* SET preflight: compile + run the rule against zero
               rows; a typo'd column shows up in work._wif_pf, a
               syntax error fails here -- the table is never touched */
            _l = 'data work._wif_pf;'; link pl;
            _l = "    set &from(obs=0);"; link pl;
            if has_where = 1 then do;
                if where_ops = 'Y' then do;
                    /* validate under REAL WHERE parsing, exactly as
                       the split path will run it                     */
                    _l = '    where (' || strip(where_clause) || ');'; link pl;
                    if lengthn(_atxt) > 0 then do;
                        _l = '    ' || strip(_atxt); link pl;
                    end;
                end;
                else do;
                    _l = '    if (' || strip(where_clause) || ') then do;'; link pl;
                    if lengthn(_atxt) > 0 then do;
                        _l = '    ' || strip(_atxt); link pl;
                    end;
                    _l = '    end;'; link pl;
                end;
            end;
            else if lengthn(_atxt) > 0 then do;
                _l = '    ' || strip(_atxt); link pl;
            end;
            _l = 'run;'; link pl;
        end;
    end;

    else if verb = 'SET' then do;
        if has_where = 1 and where_ops = 'Y' then do;
            /* WHERE-only operators (LIKE / BETWEEN / IS MISSING / <>
               as NE): order-preserving split under REAL WHERE
               semantics. Four passes - prefer IF-syntax clauses on
               very large tables.                                     */
            _l = _pc || 'put NOTE: [WIF] SET seq ' || strip(put(seq, best8.-l))
                 || " on &to (hook " || strip(hook) || ', where-split);'; link pl;
            _l = 'data work._wif_all;'; link pl;
            _l = "    set &from;"; link pl;
            _l = '    _wif_seq_ = _n_;'; link pl;
            _l = 'run;'; link pl;
            _l = 'data work._wif_m;'; link pl;
            _l = '    set work._wif_all;'; link pl;
            _l = '    where (' || strip(where_clause) || ');'; link pl;
            _l = '    ' || strip(_atxt); link pl;
            _l = 'run;'; link pl;
            _l = 'data work._wif_u;'; link pl;
            _l = '    set work._wif_all;'; link pl;
            _l = '    where not (' || strip(where_clause) || ');'; link pl;
            _l = 'run;'; link pl;
            if lengthn(_dsopt) > 0 then
                _l = "data &to(" || strip(_dsopt) || ' drop=_wif_seq_);';
            else _l = "data &to(drop=_wif_seq_);";
            link pl;
            _l = '    set work._wif_m work._wif_u;'; link pl;
            _l = '    by _wif_seq_;'; link pl;
            _l = 'run;'; link pl;
            _l = 'data _null_;'; link pl;
            _l = '    if 0 then set work._wif_m nobs=_wif_n;'; link pl;
            _l = "    call symputx('WIF_AFF', _wif_n, 'G');"; link pl;
            _l = '    stop;'; link pl;
            _l = 'run;'; link pl;
            _l = 'proc datasets lib=work nolist nowarn; delete _wif_all _wif_m _wif_u; quit;'; link pl;
        end;
        else do;
            _l = _pc || 'put NOTE: [WIF] SET seq ' || strip(put(seq, best8.-l))
                 || " on &to (hook " || strip(hook) || ');'; link pl;
            _l = "data &to(" || strip(_dsopt) || ' drop=_wif_naff _wif_hit);'; link pl;
            _l = "    set &from end=_wif_eof;"; link pl;
            _l = '    retain _wif_naff 0;'; link pl;
            _l = '    _wif_hit = 0;'; link pl;
            if has_where = 1 then do;
                _l = '    if (' || strip(where_clause) || ') then do;'; link pl;
                _l = '        ' || strip(_atxt); link pl;
                _l = '        _wif_hit = 1;'; link pl;
                _l = '    end;'; link pl;
            end;
            else do;
                _l = '    ' || strip(_atxt); link pl;
                _l = '    _wif_hit = 1;'; link pl;
            end;
            _l = '    _wif_naff + _wif_hit;'; link pl;
            _l = "    if _wif_eof then call symputx('WIF_AFF', _wif_naff, 'G');"; link pl;
            _l = 'run;'; link pl;
        end;
    end;

    else if verb = 'JOIN' then do;
        _l = _pc || 'put NOTE: [WIF] JOIN seq ' || strip(put(seq, best8.-l))
             || " on &to from " || strip(source) || ';'; link pl;
        _jto = "&to";
        _jfrom0 = ' ';
        _jhash0 = ' ';
        _jcnt = 1;
        _jdsopt = _dsopt;
        link jemit;
    end;

    else if verb = 'FILTER' then do;
        _l = _pc || 'put NOTE: [WIF] FILTER seq ' || strip(put(seq, best8.-l))
             || " on &to;"; link pl;
        if lengthn(_dsopt) > 0 then _l = "data &to(" || strip(_dsopt) || ');';
        else _l = "data &to;";
        link pl;
        _l = "    set &from;"; link pl;
        if opt_drop = 1 then do;
            _l = '    where not (' || strip(where_clause) || ');'; link pl;
        end;
        else do;
            _l = '    where (' || strip(where_clause) || ');'; link pl;
        end;
        _l = 'run;'; link pl;
    end;

    else if verb = 'APPEND' then do;
        _l = _pc || 'put NOTE: [WIF] APPEND seq ' || strip(put(seq, best8.-l))
             || " on &to from " || strip(source) || ';'; link pl;
        if has_where = 1 then do;
            /* the copy exists so the WHERE can reference source
               columns that the keep= would drop                     */
            _l = 'data work._wif_app;'; link pl;
            _l = '    set ' || strip(source) || ';'; link pl;
            _l = '    where (' || strip(where_clause) || ');'; link pl;
            _l = 'run;'; link pl;
            if lengthn(_dsopt) > 0 then _l = "data &to(" || strip(_dsopt) || ');';
            else _l = "data &to;";
            link pl;
            _l = "    set &from"; link pl;
            _dsopt = catx(' ', _keeps, _rens);
            if lengthn(_dsopt) > 0 then do;
                _l = '        work._wif_app(' || strip(_dsopt) || ');'; link pl;
            end;
            else do;
                _l = '        work._wif_app;'; link pl;
            end;
            _l = 'run;'; link pl;
            _l = 'proc datasets lib=work nolist nowarn; delete _wif_app; quit;'; link pl;
        end;
        else do;
            /* no WHERE: append straight from the source - one pass  */
            if lengthn(_dsopt) > 0 then _l = "data &to(" || strip(_dsopt) || ');';
            else _l = "data &to;";
            link pl;
            _l = "    set &from"; link pl;
            _dsopt = catx(' ', _keeps, _rens);
            if lengthn(_dsopt) > 0 then do;
                _l = '        ' || strip(source) || '(' || strip(_dsopt) || ');'; link pl;
            end;
            else do;
                _l = '        ' || strip(source) || ';'; link pl;
            end;
            _l = 'run;'; link pl;
        end;
    end;

    else if verb = 'REPLACE' then do;
        _l = _pc || 'put NOTE: [WIF] REPLACE seq ' || strip(put(seq, best8.-l))
             || " of &to by " || strip(source) || ';'; link pl;
        if lengthn(_dsopt) > 0 then _l = "data &to(" || strip(_dsopt) || ');';
        else _l = "data &to;";
        link pl;
        _l = '    retain ' || strip(_cols) || ';'; link pl;
        if lengthn(_rens) > 0 then do;
            _l = '    set ' || strip(source) || '(rename=(' || strip(_rens) || '));'; link pl;
        end;
        else do;
            _l = '    set ' || strip(source) || ';'; link pl;
        end;
        if opt_keepextra = 0 then do;
            _l = '    keep ' || strip(_cols) || ';'; link pl;
        end;
        _l = 'run;'; link pl;
    end;

    else if verb = 'ASSERT' then do;
        /* never modifies: counts rows FAILING the invariant and keeps
           a capped sample in work.wif_viol for inspection            */
        _l = _pc || 'put NOTE: [WIF] ASSERT seq ' || strip(put(seq, best8.-l))
             || " on &to;"; link pl;
        _l = 'data work.wif_viol(drop=_wif_naff);'; link pl;
        _l = '    retain _wif_naff 0;'; link pl;
        _l = "    set &from end=_wif_eof;"; link pl;
        _l = '    where not (' || strip(where_clause) || ');'; link pl;
        _l = '    _wif_naff + 1;'; link pl;
        _l = '    if _wif_naff <= 200 then output;'; link pl;
        _l = "    if _wif_eof then call symputx('WIF_AFF', _wif_naff, 'G');"; link pl;
        _l = 'run;'; link pl;
    end;

    else if verb = 'SAVE' then do;
        /* snapshot the hooked table; the destination came through the
           scanner, so parameters like the scenario name are resolved */
        _l = _pc || 'put NOTE: [WIF] SAVE seq ' || strip(put(seq, best8.-l))
             || ": &to -> " || strip(source) || ';'; link pl;
        _l = 'data ' || strip(source) || ';'; link pl;
        _l = "    set &from;"; link pl;
        _l = 'run;'; link pl;
    end;

    else if verb = 'SORT' then do;
        _l = _pc || 'put NOTE: [WIF] SORT seq ' || strip(put(seq, best8.-l))
             || " on &to by " || strip(compbl(keys)) || ';'; link pl;
        if "&compress" = '1' then _l = "proc sort data=&from out=&to(compress=binary);";
        else _l = "proc sort data=&from out=&to;";
        link pl;
        _l = '    by ' || strip(compbl(keys)) || ';'; link pl;
        _l = 'run;'; link pl;
    end;

    else if verb = 'DEDUPE' then do;
        _l = _pc || 'put NOTE: [WIF] DEDUPE seq ' || strip(put(seq, best8.-l))
             || " on &to by " || strip(compbl(keys)) || ';'; link pl;
        _l = "proc sort data=&from out=work._wif_dd;"; link pl;
        _l = '    by ' || strip(compbl(keys)) || ';'; link pl;
        _l = 'run;'; link pl;
        _ddso = ' ';
        if "&compress" = '1' then _ddso = 'compress=binary';
        _ddso = catx(' ', _ddso, 'sortedby=' || strip(compbl(keys)));
        if lengthn(_lbl) > 0 then
            _ddso = catx(' ', _ddso, "label='" || tranwrd(strip(_lbl), "'", "''") || "'");
        _l = "data &to(" || strip(_ddso) || ');'; link pl;
        _l = '    set work._wif_dd;'; link pl;
        _l = '    by ' || strip(compbl(keys)) || ';'; link pl;
        _w2 = upcase(scan(compbl(keys), countw(compbl(keys), ' '), ' '));
        if opt_last = 1 then _l = '    if last.' || strip(_w2) || ';';
        else _l = '    if first.' || strip(_w2) || ';';
        link pl;
        _l = 'run;'; link pl;
        _l = 'proc datasets lib=work nolist nowarn; delete _wif_dd; quit;'; link pl;
    end;

    else if verb = 'CODE' then do;
        _l = _pc || 'put NOTE: [WIF] CODE seq ' || strip(put(seq, best8.-l))
             || " (contract: WIF_TABLE=&to);"; link pl;
        _l = '/*---- CODE rule text begins (verbatim from the rules table) ----*/'; link pl;
        _l = strip(assign); link pl;
        _l = '/*---- CODE rule text ends ----*/'; link pl;
    end;

    /* a failing include must never leave the session in syntax-check
       mode -- re-establish unconditionally as the last emitted line */
    _l = 'options obs=max replace nosyntaxcheck;'; link pl;
    stop;
    return;

  pl:
    _ll = lengthn(_l);
    if _ll = 0 then put;
    else put _l $varying32767. _ll;
  return;

  kprep: /* SORT / DEDUPE: keys exist in the target; DESCENDING rules */
    do _kk = 1 to countw(compbl(keys), ' ');
        _w2 = upcase(scan(compbl(keys), _kk, ' '));
        if _w2 = 'DESCENDING' then do;
            if verb = 'DEDUPE' then do;
                _perr = 1;
                _pmsg = 'DEDUPE keys take plain names - order rows first with a SORT rule, then DEDUPE.';
                return;
            end;
            if _kk = countw(compbl(keys), ' ') then do;
                _perr = 1;
                _pmsg = 'DESCENDING must be followed by a key variable name.';
                return;
            end;
        end;
        else if varnum(_fid, _w2) = 0 then do;
            _perr = 1;
            _pmsg = catx(' ', 'Key variable', _w2, 'not found in', "&from", '.');
            return;
        end;
    end;
  return;

  vprep: /* SAVE: the destination libref must be assigned            */
    if countc(source, '.') = 1 then do;
        _w2 = upcase(strip(scan(source, 1, '.')));
        if _w2 ne 'WORK' then do;
            if libref(strip(_w2)) ne 0 then do;
                _perr = 1;
                _pmsg = catx(' ', 'SAVE destination libref', _w2,
                             'is not assigned - assign it before wif_init or save to WORK.');
                return;
            end;
        end;
    end;
  return;

  jemit: /* JOIN emission, shared by MAIN (_jcnt=1, real target) and
            PF (_jcnt=0, obs=0 both sides into work._wif_pf) so the
            two can never drift apart                                */
    if _jcnt = 1 then do;
        _l = 'data ' || strip(_jto) || '(' || strip(_jdsopt)
             || ' drop=_wif_rc _wif_naff'
             || ifc(opt_nomatch = 'DELETE', ' _wif_del', '')
             || ');'; link pl;
    end;
    else do;
        _l = 'data ' || strip(_jto) || '(drop=_wif_rc);'; link pl;
    end;
    _l = "    if 0 then set &from;"; link pl;
    _l = '    if 0 then set ' || strip(source) || '(keep=' || strip(_kkeep)
         || ' ' || strip(_keeps); link pl;
    if lengthn(_rens) > 0 then do;
        _l = '        rename=(' || strip(_rens) || ')'; link pl;
    end;
    _l = '        );'; link pl;
    _l = '    if _n_ = 1 then do;'; link pl;
    _l = '        declare hash _wif_h(dataset:"' || strip(source)
         || '(' || strip(_jhash0) || ' keep=' || strip(_kkeep) || ' ' || strip(_keeps);
    if lengthn(_rens) > 0 then
        _l = strip(_l) || ' rename=(' || strip(_rens) || ')';
    _l = strip(_l) || ')", duplicate:' || "'e');"; link pl;
    _l = '        _wif_h.definekey(' || strip(_qk) || ');'; link pl;
    _l = '        _wif_h.definedata(' || strip(_qd) || ');'; link pl;
    _l = '        _wif_h.definedone();'; link pl;
    _l = '    end;'; link pl;
    if _jcnt = 1 then do;
        _l = '    retain _wif_naff 0;'; link pl;
    end;
    _l = "    set &from" || strip(_jfrom0) || ' end=_wif_eof;'; link pl;
    if _jcnt = 1 then do;
        if opt_nomatch = 'DELETE' then do;
            _l = '    _wif_del = 0;'; link pl;
        end;
    end;
    /* mapped-NEW columns are hash host vars, hence auto-retained:
       without this reset an unmatched row would carry the PREVIOUS
       matched row's values instead of missing                        */
    if lengthn(_expn) > 0 then do;
        _l = '    call missing(of ' || strip(_expn) || ');'; link pl;
    end;
    if has_where = 1 then do;
        _l = '    if (' || strip(where_clause) || ') then do;'; link pl;
    end;
    _l = '    _wif_rc = _wif_h.find();'; link pl;
    _l = '    if _wif_rc = 0 then do;'; link pl;
    if lengthn(_atxt) > 0 then do;
        _l = '        ' || strip(_atxt); link pl;
    end;
    if _jcnt = 1 then do;
        _l = '        _wif_naff + 1;'; link pl;
    end;
    _l = '    end;'; link pl;
    if _jcnt = 1 then do;
        if opt_nomatch = 'FAIL' then do;
            /* fail FAST with the key values in the ERROR line; abort
               kills the step, so the same-name rewrite never replaces
               the target (rollback discipline)                       */
            _l = '    if _wif_rc ne 0 then do;'; link pl;
            _l = "        put 'ERROR: [WIF] JOIN NOMATCH=FAIL - no source match for ' "
                 || strip(_kput) || ' _n_=;'; link pl;
            _l = '        abort;'; link pl;
            _l = '    end;'; link pl;
        end;
        else if opt_nomatch = 'DELETE' then do;
            _l = '    if _wif_rc ne 0 then _wif_del = 1;'; link pl;
        end;
    end;
    if has_where = 1 then do;
        _l = '    end;'; link pl;
    end;
    if _jcnt = 1 then do;
        _l = "    if _wif_eof then call symputx('WIF_AFF', _wif_naff, 'G');"; link pl;
        if opt_nomatch = 'DELETE' then do;
            /* delete AFTER the end-of-step symputx, or the count is
               lost when the last row is deleted                      */
            _l = '    if _wif_del then delete;'; link pl;
        end;
    end;
    _l = 'run;'; link pl;
  return;

  jprep: /* JOIN: keys exist both sides with matching types (renames
            allowed: srckey=targetkey); build keep / rename /
            definekey / definedata lists; hash size guard            */
    _qk = ' '; _qd = ' '; _keeps = ' '; _rens = ' ';
    _msrc = ' '; _mtgt = ' '; _expn = ' ';
    _klist = ' '; _kkeep = ' '; _kput = ' ';
    do _kk = 1 to countw(compbl(keys), ' ');
        _tok = scan(compbl(keys), _kk, ' ');
        _s1 = upcase(strip(scan(_tok, 1, '=')));
        if countc(_tok, '=') = 1 then _t1 = upcase(strip(scan(_tok, 2, '=')));
        else _t1 = _s1;
        _tv = varnum(_fid, _t1);      /* target side uses the TARGET name */
        _sv = varnum(_sid, _s1);      /* source side uses the SOURCE name */
        if _tv = 0 or _sv = 0 then do;
            _perr = 1;
            _pmsg = catx(' ', 'JOIN key', _tok, '- needs', _t1, 'in', "&from",
                         'and', _s1, 'in', source, '.');
        end;
        else if vartype(_fid, _tv) ne vartype(_sid, _sv) then do;
            _perr = 1;
            _pmsg = catx(' ', 'JOIN key', _tok, 'is character on one side and numeric on the other.');
        end;
        _klist = catx(' ', _klist, _t1);
        _kkeep = catx(' ', _kkeep, _s1);
        _kput  = catx(' ', _kput, strip(_t1) || '=');
        if _s1 ne _t1 then _rens = catx(' ', _rens, strip(_s1) || '=' || strip(_t1));
        _qk = catx(',', _qk, "'" || strip(_t1) || "'");
    end;
    if _perr = 1 then return;
    if has_cols = 1 then do;
        /* explicit mapping: srccol or srccol=targetcol               */
        do _mp = 1 to countw(columns, ' ');
            _tok = scan(columns, _mp, ' ');
            _s1 = upcase(strip(scan(_tok, 1, '=')));
            if countc(_tok, '=') = 1 then _t1 = upcase(strip(scan(_tok, 2, '=')));
            else _t1 = _s1;
            if varnum(_sid, _s1) = 0 then do;
                _perr = 1;
                _pmsg = catx(' ', 'JOIN columns token', _tok, '- column', _s1,
                             'not found in source', source, '.');
                return;
            end;
            if indexw(_kkeep, _s1) > 0 and _s1 ne _t1 then do;
                _perr = 1;
                _pmsg = catx(' ', 'JOIN cannot rename key variable', _s1,
                             'in the columns mapping - keys are matched, not copied.');
                return;
            end;
            if indexw(_msrc, _s1) > 0 then do;
                _perr = 1;
                _pmsg = catx(' ', 'JOIN columns lists source column', _s1, 'twice.');
                return;
            end;
            if indexw(_klist, _t1) > 0 then do;
                _perr = 1;
                _pmsg = catx(' ', 'JOIN cannot overwrite key variable', _t1, '.');
                return;
            end;
            _msrc = catx(' ', _msrc, _s1);
            _mtgt = catx(' ', _mtgt, _t1);
            _keeps = catx(' ', _keeps, _s1);
            if _s1 ne _t1 then _rens = catx(' ', _rens, strip(_s1) || '=' || strip(_t1));
            _qd = catx(',', _qd, "'" || strip(_t1) || "'");
            if varnum(_fid, _t1) = 0 then _expn = catx(' ', _expn, _t1);
        end;
    end;
    else do;
        /* automatic: same-named non-key source columns present in
           the target                                                */
        do _sv = 1 to attrn(_sid, 'nvars');
            _w2 = upcase(varname(_sid, _sv));
            if indexw(_kkeep, _w2) = 0 then do;
                if varnum(_fid, _w2) > 0 then do;
                    _keeps = catx(' ', _keeps, _w2);
                    _qd = catx(',', _qd, "'" || strip(_w2) || "'");
                end;
            end;
        end;
        if lengthn(_qd) = 0 then do;
            _perr = 1;
            _pmsg = catx(' ', 'JOIN from', source,
                         'finds no shared non-key columns to update; name them in the columns cell.');
            return;
        end;
    end;
    /* hash memory pre-check: logical source size. Views report
       NLOBS=-1, which would silently bypass the guard.               */
    if attrn(_sid, 'NLOBS') < 0 then do;
        _perr = 1;
        _pmsg = catx(' ', 'JOIN source', source,
                     'is a view - its size cannot be pre-checked. Materialize it to a table first (or use a CODE rule).');
        return;
    end;
    _est = attrn(_sid, 'NLOBS') * attrn(_sid, 'LRECL');
    if _est > input(symget('WIF_MAXHASH'), best32.) then do;
        _perr = 1;
        _pmsg = catx(' ', 'JOIN source', source, 'is about',
                     strip(put(_est, comma20.)),
                     'bytes - beyond WIF_MAXHASH. Pre-aggregate it, or use a CODE rule with a sorted MERGE.');
        return;
    end;
    call symputx('WIF_EXPNEW', strip(_expn), 'G');
  return;

  aprep: /* APPEND: keep + rename lists (mapped pairs first, then
            same-named source columns that exist in the target)      */
    _keeps = ' '; _rens = ' '; _msrc = ' '; _mtgt = ' ';
    if has_cols = 1 then do _mp = 1 to countw(columns, ' ');
        _tok = scan(columns, _mp, ' ');
        _s1 = upcase(strip(scan(_tok, 1, '=')));
        if countc(_tok, '=') = 1 then _t1 = upcase(strip(scan(_tok, 2, '=')));
        else _t1 = _s1;
        if varnum(_sid, _s1) = 0 then do;
            _perr = 1;
            _pmsg = catx(' ', 'APPEND columns token', _tok, '- column', _s1,
                         'not found in source', source, '.');
            return;
        end;
        if varnum(_fid, _t1) = 0 then do;
            if opt_newcols = 0 then do;
                _perr = 1;
                _pmsg = catx(' ', 'APPEND maps to', _t1, 'which is not a column of', "&from",
                             '- add the NEWCOLS option if the new column is intentional.');
                return;
            end;
        end;
        _keeps = catx(' ', _keeps, _s1);
        _msrc  = catx(' ', _msrc, _s1);
        _mtgt  = catx(' ', _mtgt, _t1);
        if _s1 ne _t1 then _rens = catx(' ', _rens, strip(_s1) || '=' || strip(_t1));
    end;
    do _sv = 1 to attrn(_sid, 'nvars');
        _w2 = upcase(varname(_sid, _sv));
        if varnum(_fid, _w2) > 0 and indexw(_msrc, _w2) = 0
           and indexw(_mtgt, _w2) = 0 then
            _keeps = catx(' ', _keeps, _w2);
    end;
    if lengthn(strip(_keeps)) = 0 then do;
        _perr = 1;
        _pmsg = catx(' ', 'APPEND source', source,
                     'shares no columns with', "&from",
                     '- map them in the columns cell.');
        return;
    end;
    _keeps = 'keep=' || strip(_keeps);
    if lengthn(_rens) > 0 then _rens = 'rename=(' || strip(_rens) || ')';
  return;

  rprep: /* REPLACE: target column order + renames + completeness    */
    _cols = ' '; _rens = ' '; _msrc = ' '; _mtgt = ' ';
    do _tv = 1 to attrn(_fid, 'nvars');
        _cols = catx(' ', _cols, varname(_fid, _tv));
    end;
    if has_cols = 1 then do _mp = 1 to countw(columns, ' ');
        _tok = scan(columns, _mp, ' ');
        _s1 = upcase(strip(scan(_tok, 1, '=')));
        if countc(_tok, '=') = 1 then _t1 = upcase(strip(scan(_tok, 2, '=')));
        else _t1 = _s1;
        if varnum(_sid, _s1) = 0 then do;
            _perr = 1;
            _pmsg = catx(' ', 'REPLACE columns token', _tok, '- column', _s1,
                         'not found in source', source, '.');
            return;
        end;
        _msrc = catx(' ', _msrc, _s1);
        _mtgt = catx(' ', _mtgt, _t1);
        if _s1 ne _t1 then _rens = catx(' ', _rens, strip(_s1) || '=' || strip(_t1));
    end;
    /* a rename onto a column the source ALSO has collides at run
       time ("variable already exists") - catch it at prep            */
    do _mp = 1 to countw(_mtgt, ' ');
        _w2 = scan(_mtgt, _mp, ' ');
        _s1 = scan(_msrc, _mp, ' ');
        if _w2 ne _s1 then do;
            if varnum(_sid, _w2) > 0 and indexw(_msrc, _w2) = 0 then do;
                _perr = 1;
                _pmsg = catx(' ', 'REPLACE mapping renames', _s1, 'onto', _w2,
                             'but the source also has a column named', _w2,
                             '- map or exclude that source column too.');
                return;
            end;
        end;
    end;
    /* every target column must be available after mapping            */
    do _tv = 1 to attrn(_fid, 'nvars');
        _w2 = upcase(varname(_fid, _tv));
        _ok = 0;
        if indexw(_mtgt, _w2) > 0 then _ok = 1;
        else do;
            _sv = varnum(_sid, _w2);
            if _sv > 0 and indexw(_msrc, _w2) = 0 then _ok = 1;
        end;
        if _ok = 0 then do;
            _perr = 1;
            _pmsg = catx(' ', 'REPLACE source', source, 'does not provide column',
                         _w2, '- map it in the columns cell or fix the source.');
            return;
        end;
    end;
    if lengthn(_rens) > 0 then _rens = strip(_rens);
  return;
run;
%mend _wif_gen_rule;

/*------------------------------------------------------------------
  05. RULE EXECUTION + INPUT STAGING + PUBLIC API
------------------------------------------------------------------*/

/* Restore librefs recorded by staging (called by wif_off AND at the
   top of every wif_init -- crash recovery for interrupted runs).    */
%macro _wif_restore_libs();
%local _n _k _l1 _p1 _r1 _rc;
%if not %sysfunc(exist(work._wif_libsave)) %then %return;
%_wif_nobs(ds=work._wif_libsave, mvar=_n)
%do _k = 1 %to &_n;
    %let _l1 = ;
    %let _p1 = ;
    %let _r1 = ;
    proc sql noprint;
        select libref, path, ro into :_l1 trimmed, :_p1 trimmed, :_r1 trimmed
        from work._wif_libsave where k = &_k;
    quit;
    %if %length(&_l1) > 0 %then %do;
        %if %length(&_p1) > 0 %then %do;
            %if &_r1 = Y %then %do;
                libname &_l1 "&_p1" access=readonly;
            %end;
            %else %do;
                libname &_l1 "&_p1";
            %end;
            %put NOTE: [WIF] libref &_l1 restored to &_p1..;
        %end;
        %else %do;
            libname &_l1 clear;
            %put NOTE: [WIF] libref &_l1 cleared (was assigned by WIF).;
        %end;
    %end;
    %if %sysfunc(libref(_WIFB&_k)) = 0 %then %do;
        libname _WIFB&_k clear;
    %end;
%end;
proc datasets lib=work nolist nowarn; delete _wif_libsave; quit;
%mend _wif_restore_libs;

/* Resolve a (possibly one-level) table reference to LIB.MEM using
   the same rules as SAS: USER= option when set, else WORK.
   Sets &libvar / &memvar / &okvar (1 good, 0 bad name).             */
%macro _wif_resolve(name=, libvar=, memvar=, okvar=);
%local _t _usr;
%let &okvar = 1;
%let _t = %qupcase(%superq(name));
%if %length(&_t) = 0 %then %do;
    %let &okvar = 0;
    %return;
%end;
%if %index(&_t, .) > 0 %then %do;
    %let &libvar = %scan(&_t, 1, .);
    %let &memvar = %scan(&_t, 2, .);
    %if %length(%scan(&_t, 3, .)) > 0 %then %let &okvar = 0;
%end;
%else %do;
    %let _usr = %upcase(%sysfunc(getoption(user)));
    %if %length(&_usr) > 0 %then %let &libvar = &_usr;
    %else %let &libvar = WORK;
    %let &memvar = &_t;
%end;
%if %length(&&&libvar) > 8 %then %let &okvar = 0;
%else %if not %sysfunc(nvalid(&&&libvar, v7)) %then %let &okvar = 0;
%else %if not %sysfunc(nvalid(&&&memvar, v7)) %then %let &okvar = 0;
%mend _wif_resolve;

/* Apply ONE rule (row &rulei of work._wif_todo): preflight (SET),
   generate, %include, post-check, count, log, warn, obey onfail.
   from/to are RESOLVED two-level names supplied by the caller.
   Sets WIF_APRC: 0 = applied, 1 = failed-continue (caller bails the
   remaining rules on this hook). onfail=STOP aborts inside.         */
%macro _wif_apply_rule(rulei=, from=, to=, hook=, compress=0);
%global WIF_APRC;
%local _verb _seq _src _slib _smem _sok _newc _nowarn0 _haswhere _hascols
       _once _snap _gf _pfile _insyscc _failed _aff _rm;
%let WIF_APRC = 0;
%let _insyscc = &syscc;
%let _failed = 0;
%let _verb = ; %let _seq = 0; %let _src = ; %let _newc = 0;
%let _nowarn0 = 0; %let _haswhere = 0; %let _hascols = 0; %let _once = 0;
proc sql noprint;
    select verb, put(seq, best8.-l), source, put(opt_newcols, 1.),
           put(opt_nowarn0, 1.), put(has_where, 1.), put(has_cols, 1.),
           put(opt_once, 1.)
        into :_verb trimmed, :_seq trimmed, :_src trimmed, :_newc trimmed,
             :_nowarn0 trimmed, :_haswhere trimmed, :_hascols trimmed,
             :_once trimmed
        from work._wif_todo where rule_i = &rulei;
quit;
%if %length(&_verb) = 0 %then %do;
    %put ERROR: [WIF] internal: rule &rulei not found in the todo list.;
    %let WIF_APRC = 1;
    %return;
%end;
%let WIF_TABLE = &to;

/* ---- target (from) must exist as DATA ---- */
%if not %sysfunc(exist(&from, DATA)) %then %do;
    %if %sysfunc(exist(&from, VIEW)) %then %do;
        %let WIF_MSG = &from is a VIEW. Materialize it before the hook (a view would just re-derive), or hook the table it feeds.;
        %_wif_log(status=FAILED, hook=&hook, seq=&_seq, verb=&_verb, target=&to)
        %put ERROR: [WIF] rule seq &_seq on &from: target is a VIEW, not a table.;
    %end;
    %else %do;
        %let WIF_MSG = Table &from does not exist at this hook point. Is the hook placed after the step that creates it?;
        %_wif_log(status=NO_TABLE, hook=&hook, seq=&_seq, verb=&_verb, target=&to)
        %put ERROR: [WIF] rule seq &_seq: table &from not found at hook &hook..;
    %end;
    %let _failed = 1;
    %goto fin;
%end;

/* ---- source must exist (JOIN / APPEND / REPLACE) ---- */
%if &_verb = JOIN or &_verb = APPEND or &_verb = REPLACE %then %do;
    %_wif_resolve(name=&_src, libvar=_slib, memvar=_smem, okvar=_sok)
    %if &_sok = 0 %then %do;
        %let WIF_MSG = Bad source table reference: &_src;
        %_wif_log(status=FAILED, hook=&hook, seq=&_seq, verb=&_verb, target=&to)
        %put ERROR: [WIF] rule seq &_seq: bad source reference &_src..;
        %let _failed = 1;
        %goto fin;
    %end;
    %let _src = &_slib..&_smem;
    %if not %sysfunc(exist(&_src, DATA)) %then %if not %sysfunc(exist(&_src, VIEW)) %then %do;
        %let WIF_MSG = Source table &_src not found.;
        %_wif_log(status=FAILED, hook=&hook, seq=&_seq, verb=&_verb, target=&to)
        %put ERROR: [WIF] rule seq &_seq: source &_src not found.;
        %let _failed = 1;
        %goto fin;
    %end;
    /* the resolved source feeds codegen through the todo dataset    */
    proc sql;
        update work._wif_todo set source = "&_src" where rule_i = &rulei;
    quit;
%end;

%_wif_nobs(ds=&from, mvar=WIF_NB)
%_wif_snapcols(ds=&from, mvar=_snap)
%let WIF_AFF = 0;

/* ---- preflight (SET and JOIN): obs=0 sandbox catches typos BEFORE
        any data is touched - a rewrite of a multi-GB table is the
        most expensive place to discover a misspelled column ---- */
%if &_verb = SET or &_verb = JOIN %then %do;
    %let _pfile = &WIF_GENDIR/w&WIF_GEN._i&WIF_ITER._f&WIF_FIRE._r&_seq._pf.sas;
    %_wif_gen_rule(rulei=&rulei, gfile=&_pfile, from=&from, to=&to, mode=PF)
    %if &WIF_PREPERR = 1 %then %do;
        %put ERROR: [WIF] rule seq &_seq (&_verb) failed its pre-checks: %superq(WIF_MSG);
        %_wif_log(status=FAILED, hook=&hook, seq=&_seq, verb=&_verb, target=&to)
        %let _failed = 1;
        %goto fin;
    %end;
    %_wif_exec_gen(file=&_pfile)
    %if &syscc > 4 %then %do;
        %let WIF_MSG = Rule text failed to compile or run in the preflight (see the log above). The table was NOT touched. Last error: %superq(syserrortext);
        %put ERROR: [WIF] rule seq &_seq (&_verb) failed preflight - &to untouched. %superq(WIF_MSG);
        %_wif_log(status=FAILED, hook=&hook, seq=&_seq, verb=&_verb, target=&to)
        %let _failed = 1;
        %goto fin;
    %end;
    %_wif_coldiff(snap=&_snap, ds=work._wif_pf, allownew=&_newc, expnew=&WIF_EXPNEW)
    proc datasets lib=work nolist nowarn; delete _wif_pf; quit;
    %if &WIF_CDRC = 1 %then %do;
        %put ERROR: [WIF] rule seq &_seq (&_verb) rejected by preflight - &to untouched. %superq(WIF_MSG);
        %_wif_log(status=FAILED, hook=&hook, seq=&_seq, verb=&_verb, target=&to)
        %let _failed = 1;
        %goto fin;
    %end;
%end;

/* ---- generate + run the real step ---- */
%let _gf = &WIF_GENDIR/w&WIF_GEN._i&WIF_ITER._f&WIF_FIRE._r&_seq..sas;
%_wif_gen_rule(rulei=&rulei, gfile=&_gf, from=&from, to=&to, mode=MAIN, compress=&compress)
%if &WIF_PREPERR = 1 %then %do;
    %put ERROR: [WIF] rule seq &_seq (&_verb) on &to failed its pre-checks - nothing modified. %superq(WIF_MSG);
    %_wif_log(status=FAILED, hook=&hook, seq=&_seq, verb=&_verb, target=&to)
    %let _failed = 1;
    %goto fin;
%end;
%_wif_exec_gen(file=&_gf)
%if &syscc > 4 %then %do;
    %let WIF_MSG = Rule step failed. A same-name rewrite only replaces the table at successful completion, so &to kept its previous contents. If an EG data grid has it open, close the grid. Last error: %superq(syserrortext);
    %put ERROR: [WIF] rule seq &_seq (&_verb) on &to FAILED - previous contents preserved. %superq(WIF_MSG);
    %_wif_log(status=FAILED, hook=&hook, seq=&_seq, verb=&_verb, target=&to)
    %let _failed = 1;
    %goto fin;
%end;

/* ---- post checks + counts ---- */
%if &_verb = JOIN %then %do;
    %_wif_coldiff(snap=&_snap, ds=&to, allownew=&_newc, expnew=&WIF_EXPNEW)
    %if &WIF_CDRC = 1 %then %do;
        %let WIF_MSG = %superq(WIF_MSG) NOTE: the JOIN itself ran, so &to WAS modified - fix the rule and re-run from a clean state.;
        %put ERROR: [WIF] rule seq &_seq (JOIN) created unexpected columns on &to (typo in the assign cell?). %superq(WIF_MSG);
        %_wif_log(status=FAILED, hook=&hook, seq=&_seq, verb=&_verb, target=&to)
        %let _failed = 1;
        %goto fin;
    %end;
%end;
%if &_verb = CODE %then %do;
    %if not %sysfunc(exist(&to, DATA)) %then %do;
        %let WIF_MSG = CODE rule removed or renamed &to - the hooked table must still exist after the rule.;
        %put ERROR: [WIF] rule seq &_seq (CODE): %superq(WIF_MSG);
        %_wif_log(status=FAILED, hook=&hook, seq=&_seq, verb=&_verb, target=&to)
        %let _failed = 1;
        %goto fin;
    %end;
%end;
%if &_verb = ASSERT %then %let WIF_NA = &WIF_NB;
%else %do;
    %_wif_nobs(ds=&to, mvar=WIF_NA)
%end;
%let _aff = .;
%if &_verb = SET or &_verb = JOIN or &_verb = ASSERT %then %let _aff = &WIF_AFF;
%else %if &_verb = FILTER or &_verb = DEDUPE %then %let _aff = %eval(&WIF_NB - &WIF_NA);
%else %if &_verb = APPEND %then %let _aff = %eval(&WIF_NA - &WIF_NB);
%else %if &_verb = REPLACE %then %let _aff = &WIF_NA;
%else %if &_verb = SAVE %then %let _aff = &WIF_NB;
%if &_verb = ASSERT %then %if &_aff > 0 %then %do;
    %let WIF_MSG = &_aff row(s) violate the assertion - sample (first 200) kept in work.wif_viol. The table itself was NOT modified.;
    %put ERROR: [WIF] ASSERT seq &_seq on &to FAILED: %superq(WIF_MSG);
    %_wif_log(status=FAILED, hook=&hook, seq=&_seq, verb=&_verb, target=&to,
              nb=&WIF_NB, na=&WIF_NA, aff=&_aff)
    %let _failed = 1;
    %goto fin;
%end;
%if &_verb = SET or &_verb = JOIN or &_verb = FILTER or &_verb = APPEND
    or &_verb = DEDUPE or &_verb = SAVE %then %do;
    %if &_aff = 0 and &_nowarn0 = 0 %then
        %put WARNING: [WIF] rule seq &_seq (&_verb) on &to affected 0 rows. Check the where clause / keys (values, case). NOWARN0 silences this.;
%end;
%if &WIF_HADIDX = 1 %then %if &_verb ne ASSERT %then %if &_verb ne SAVE %then
    %put WARNING: [WIF] &to had indexes%str(;) the rewrite removed them. Recreate with PROC DATASETS / INDEX CREATE if downstream code needs them.;
%let WIF_MSG = ;
%if &_verb = SAVE %then %let WIF_MSG = saved to &_src;
%_wif_log(status=OK, hook=&hook, seq=&_seq, verb=&_verb, target=&to,
          nb=&WIF_NB, na=&WIF_NA, aff=&_aff)
%put NOTE: [WIF] rule seq &_seq (&_verb) on &to: rows &WIF_NB -> &WIF_NA, affected=&_aff..;
%if &_once = 1 %then %do;
    data work._wif_fired_new;
        length hook $32 seq 8;
        hook = "&hook"; seq = &_seq;
    run;
    proc append base=work._wif_fired data=work._wif_fired_new; run;
    proc datasets lib=work nolist nowarn; delete _wif_fired_new; quit;
%end;
%return;

%fin:
%if &_failed = 1 %then %do;
    %if &WIF_ONFAIL = STOP %then %do;
        %let WIF_RC = 2;
        %put ERROR: [WIF] onfail=STOP: cancelling the submitted program. Fix the rule and resubmit.;
        %abort cancel;
    %end;
    %let syscc = &_insyscc;
    %let WIF_APRC = 1;
%end;
%mend _wif_apply_rule;

/* The active hook path: gates, todo list, rule loop.                */
%macro _wif_fire(table=, at=);
%local _lib _mem _ok _hk _tgt _n _i _r_tgt _r_allow _tlib _tmem _tok _nskip _bail;
%if not %sysfunc(exist(work._wif_rules)) %then %do;
    %put WARNING: [WIF] Hooks are active but work._wif_rules is gone (WORK cleaned mid-session?). Deactivating - run wif_init again to reactivate.;
    %let WIF_ACTIVE = 0;
    %return;
%end;
%_wif_resolve(name=&table, libvar=_lib, memvar=_mem, okvar=_ok)
%if &_ok = 0 %then %do;
    %put ERROR: [WIF] bad table reference in hook call: %superq(table) - use a plain table name or libref.table.;
    %return;
%end;
%if %length(&at) > 0 %then %let _hk = %qupcase(&at);
%else %let _hk = &_mem;
%if not %sysfunc(nvalid(&_hk, v7)) %then %do;
    %put ERROR: [WIF] bad hook name: &_hk;
    %return;
%end;
%if &_hk = INPUT %then %do;
    %put WARNING: [WIF] the hook name INPUT is reserved for staging rules - rename the table or hook it with at= and a different name. Nothing done.;
    %return;
%end;
%let _tgt = &_lib..&_mem;

/* session already broken? do not destroy the evidence.              */
%if &syscc > 4 %then %do;
    %let WIF_MSG = Session in error state on hook entry (syscc=&syscc). Nothing modified.;
    %_wif_log(status=SKIP_SYSCC, hook=&_hk, target=&_tgt)
    %put WARNING: [WIF] hook &_hk skipped: the session was ALREADY in error state (syscc=&syscc) BEFORE the hook - the failure is upstream in your program. Find the first ERROR above it, fix that, resubmit. wif_reset clears a stuck state.;
    %if &WIF_ONFAIL = STOP %then %do;
        %let WIF_RC = 2;
        %put ERROR: [WIF] onfail=STOP: cancelling the submitted program.;
        %abort cancel;
    %end;
    %return;
%end;

/* build the todo list: this hook, iteration + once gates            */
%if not %sysfunc(exist(work._wif_fired)) %then %do;
    data work._wif_fired;
        length hook $32 seq 8;
        stop;
    run;
%end;
data work._wif_todo work._wif_skip(keep=hook seq verb target why);
    length why $12 rule_i 8;
    retain rule_i 0;
    if _n_ = 1 then do;
        declare hash _f(dataset:'work._wif_fired');
        _f.definekey('hook', 'seq');
        _f.definedone();
    end;
    set work._wif_rules;
    where hook = "&_hk";
    why = ' ';
    if opt_iters ne 'ALL' then do;
        if index(opt_iters, '+') > 0 then do;
            if &WIF_ITER < input(compress(opt_iters, '+'), ?? best32.) then why = 'SKIP_ITER';
        end;
        else do;
            if &WIF_ITER ne input(opt_iters, ?? best32.) then why = 'SKIP_ITER';
        end;
    end;
    if why = ' ' and opt_once = 1 then do;
        if _f.check() = 0 then why = 'SKIP_ONCE';
    end;
    if why = ' ' then do;
        rule_i + 1;
        output work._wif_todo;
    end;
    else output work._wif_skip;
run;
%_wif_nobs(ds=work._wif_skip, mvar=_nskip)
%_wif_nobs(ds=work._wif_todo, mvar=_n)
%if &_n = 0 %then %if &_nskip = 0 %then %do;
    %put NOTE: [WIF] hook &_hk: no applicable rules (scenario &WIF_SCENARIO, iter &WIF_ITER).;
    %return;
%end;
/* this hook has rules to apply or skips to record: it is a firing   */
%let WIF_FIRE = %eval(&WIF_FIRE + 1);

/* record the skips */
%if &_nskip > 0 %then %do;
    data work._wif_skiplog;
        length gen 8 scenario $32 iter 8 fire 8 hook $32 seq 8 verb $8
               target $41 status $12 rows_before 8 rows_after 8
               rows_affected 8 message $500 logged_at 8;
        format logged_at datetime20.;
        set work._wif_skip;
        gen = &WIF_GEN; scenario = "&WIF_SCENARIO"; iter = &WIF_ITER;
        fire = &WIF_FIRE; status = why;
        rows_before = .; rows_after = .; rows_affected = .;
        message = ' '; logged_at = datetime();
        keep gen scenario iter fire hook seq verb target status
             rows_before rows_after rows_affected message logged_at;
    run;
    proc append base=work.wif_log data=work._wif_skiplog force; run;
    proc datasets lib=work nolist nowarn; delete _wif_skiplog _wif_skip; quit;
%end;
%if &_n = 0 %then %do;
    %put NOTE: [WIF] hook &_hk: all rules skipped (scenario &WIF_SCENARIO, iter &WIF_ITER).;
    %return;
%end;

%let WIF_HOOK = &_hk;
%put NOTE: [WIF] ==== hook &_hk firing: &_n rule(s), scenario &WIF_SCENARIO, iter &WIF_ITER (fire &WIF_FIRE) ====;

%let _bail = 0;
%do _i = 1 %to &_n;
    %if &_bail = 0 %then %do;
        %let _r_tgt = ;
        %let _r_allow = 0;
        proc sql noprint;
            select target, put(opt_allowlib, 1.)
                into :_r_tgt trimmed, :_r_allow trimmed
                from work._wif_todo where rule_i = &_i;
        quit;
        /* resolve the rule's target: blank = the hooked table       */
        %if %length(&_r_tgt) = 0 %then %do;
            %let _tlib = &_lib;
            %let _tmem = &_mem;
        %end;
        %else %do;
            %_wif_resolve(name=&_r_tgt, libvar=_tlib, memvar=_tmem, okvar=_ok)
            %if &_ok = 0 %then %do;
                %put ERROR: [WIF] rule &_i on hook &_hk: bad target &_r_tgt;
                %let _bail = 1;
            %end;
        %end;
        %if &_bail = 0 %then %do;
            /* permanent-library guard: WORK (or USER) only, unless
               the rule says ALLOWLIB                                */
            %if &_tlib ne WORK and &_r_allow = 0 %then %do;
                %local _usr2;
                %let _usr2 = %upcase(%sysfunc(getoption(user)));
                %if "&_tlib" ne "&_usr2" %then %do;
                    %let WIF_MSG = Target &_tlib..&_tmem is not in WORK. Hooks modify tables in place - for a permanent library add the ALLOWLIB option to the rule if you REALLY mean it, or copy the table to WORK first.;
                    %_wif_log(status=FAILED, hook=&_hk, verb=, target=&_tlib..&_tmem)
                    %put ERROR: [WIF] refused to modify permanent table &_tlib..&_tmem (no ALLOWLIB).;
                    %if &WIF_ONFAIL = STOP %then %do;
                        %let WIF_RC = 2;
                        %abort cancel;
                    %end;
                    %let _bail = 1;
                %end;
            %end;
        %end;
        %if &_bail = 0 %then %do;
            %_wif_apply_rule(rulei=&_i, from=&_tlib..&_tmem, to=&_tlib..&_tmem,
                             hook=&_hk, compress=0)
            %if &WIF_APRC = 1 %then %do;
                %put WARNING: [WIF] remaining rules on hook &_hk skipped after the failure (onfail=CONTINUE).;
                /* record what never ran - wif_check counts SKIP_FAIL */
                %if &_i < &_n %then %do;
                    data work._wif_skiplog;
                        length gen 8 scenario $32 iter 8 fire 8 hook $32 seq 8
                               verb $8 target $41 status $12 rows_before 8
                               rows_after 8 rows_affected 8 message $500
                               logged_at 8;
                        format logged_at datetime20.;
                        set work._wif_todo;
                        where rule_i > &_i;
                        gen = &WIF_GEN; scenario = "&WIF_SCENARIO";
                        iter = &WIF_ITER; fire = &WIF_FIRE;
                        status = 'SKIP_FAIL';
                        rows_before = .; rows_after = .; rows_affected = .;
                        message = 'skipped: an earlier rule on this hook failed';
                        logged_at = datetime();
                        keep gen scenario iter fire hook seq verb target status
                             rows_before rows_after rows_affected message
                             logged_at;
                    run;
                    proc append base=work.wif_log data=work._wif_skiplog force; run;
                    proc datasets lib=work nolist nowarn; delete _wif_skiplog; quit;
                %end;
                %let _bail = 1;
            %end;
        %end;
    %end;
%end;
proc datasets lib=work nolist nowarn; delete _wif_todo; quit;
%put NOTE: [WIF] ==== hook &_hk done ====;
%mend _wif_fire;

/* THE hook. Inactive = three cheap %IF evaluations, nothing else.   */
%macro wif(table, at=);
%if not %symexist(WIF_ACTIVE) %then %return;
%if %length(&WIF_ACTIVE) = 0 %then %return;
%if &WIF_ACTIVE ne 1 %then %return;
%_wif_fire(table=&table, at=&at)
%mend wif;

/* INPUT staging: apply hook=INPUT rules to copies staged under
   <WORK>/wif_in, then repoint each input libref as a READONLY-nested
   concatenation (staged copy first, pristine base second).          */
%macro _wif_stage(inlib=, base=);
%local _n _i _k _nlibs _lib _pth _ro _eng _nrow _mem _prev _first _fromlib
       _b _ok _t _seq _verb _stagedir;
%_wif_nobs(ds=work._wif_sttodo, mvar=_n)
%if &_n = 0 %then %do;
    %if %length(%superq(base)) > 0 %then
        %put NOTE: [WIF] base= given but no INPUT rules - nothing staged.;
    %return;
%end;

%let _stagedir = %_wif_path(%sysfunc(pathname(work)))/wif_in;
%_wif_mkdir(&_stagedir)
%if &WIF_UTILRC ne 0 %then %do;
    %let WIF_RC = 1;
    %return;
%end;
libname _WIFI "&_stagedir";

/* ---- the librefs involved ---- */
proc sql noprint;
    create table work._wif_stlibs as
    select distinct scan(target, 1, '.') as libref length=8
    from work._wif_sttodo;
quit;
%_wif_nobs(ds=work._wif_stlibs, mvar=_nlibs)

%if %length(%superq(base)) > 0 %then %do;
    /* driver mode: one base path for one nominated libref           */
    %if %length(&inlib) = 0 %then %do;
        %put ERROR: [WIF] base= needs inlib= (the libref your program reads inputs through).;
        %let WIF_RC = 1;
        %return;
    %end;
    %let _b = %_wif_path(&base);
    %if not %sysfunc(fileexist(&_b)) %then %do;
        %put ERROR: [WIF] base folder not found: &_b (as the SAS SERVER sees paths - not your PC).;
        %let WIF_RC = 1;
        %return;
    %end;
    %if &_nlibs > 1 %then %do;
        %put ERROR: [WIF] with inlib=/base= all INPUT rule targets must use the single libref &inlib..;
        %let WIF_RC = 1;
        %return;
    %end;
    proc sql noprint;
        select libref into :_lib trimmed from work._wif_stlibs;
    quit;
    %if %upcase(&_lib) ne %upcase(&inlib) %then %do;
        %put ERROR: [WIF] INPUT rules target libref &_lib but inlib=&inlib..;
        %let WIF_RC = 1;
        %return;
    %end;
    /* remember what to restore: prior assignment if any, else clear.
       READONLY must be captured too - restoring a protected libref
       writable would silently drop the user's write protection.     */
    %local _dro;
    %let _dro = NO;
    %if %sysfunc(libref(&inlib)) = 0 %then %do;
        proc sql noprint;
            select max(readonly) into :_dro trimmed
            from dictionary.libnames
            where libname = "%upcase(&inlib)";
        quit;
    %end;
    data work._wif_libsave;
        length k 8 libref $8 path $500 ro $1;
        k = 1;
        libref = upcase("&inlib");
        path = ' ';
        ro = ifc(upcase(strip(symget('_dro'))) = 'YES', 'Y', 'N');
        if libref(libref) = 0 then do;
            path = pathname(libref);
            /* a concatenation cannot be restored from pathname()    */
            if substr(strip(path), 1, 1) = '(' then path = '?CONCAT?';
        end;
    run;
    %local _chk;
    %let _chk = ;
    proc sql noprint;
        select path into :_chk trimmed from work._wif_libsave;
    quit;
    %if "&_chk" = "?CONCAT?" %then %do;
        %put ERROR: [WIF] libref &inlib is already a concatenation - WIF cannot restore that on wif_off. Clear it first or use a fresh libref.;
        %let WIF_RC = 1;
        proc datasets lib=work nolist nowarn; delete _wif_libsave; quit;
        %return;
    %end;
    libname _WIFB1 "&_b" access=readonly;
    %let _fromlib = _WIFB1;
    %let _k = 1;
%end;
%else %do;
    /* auto mode: repoint the already-assigned libref(s)             */
    data work._wif_libsave;
        length k 8 libref $8 path $500 ro $1;
        stop;
    run;
    %do _i = 1 %to &_nlibs;
        %let _lib = ;
        proc sql noprint;
            select libref into :_lib trimmed
            from work._wif_stlibs(firstobs=&_i obs=&_i);
        quit;
        %if %sysfunc(libref(&_lib)) ne 0 %then %do;
            %put ERROR: [WIF] libref &_lib (INPUT rule target) is not assigned. Assign it first, or use inlib=/base=.;
            %let WIF_RC = 1;
            %return;
        %end;
        %let _nrow = 0;
        %let _eng = ;
        %let _pth = ;
        %let _ro = ;
        proc sql noprint;
            select count(*), max(engine), max(path), max(readonly)
                into :_nrow trimmed, :_eng trimmed, :_pth trimmed, :_ro trimmed
                from dictionary.libnames
                where libname = "%upcase(&_lib)";
        quit;
        %if &_nrow > 1 %then %do;
            %put ERROR: [WIF] libref &_lib is a concatenation - v1 stages single-path BASE librefs only. Point a plain libref at the folder, or hook the first WORK table instead.;
            %let WIF_RC = 1;
            %return;
        %end;
        %if not (%sysfunc(indexw(V9 BASE, &_eng)) > 0) %then %do;
            %put ERROR: [WIF] libref &_lib uses engine &_eng - v1 stages BASE-engine librefs only. Extract the tables to a folder, or hook the first WORK table instead.;
            %let WIF_RC = 1;
            %return;
        %end;
        data work._wif_libsave_add;
            length k 8 libref $8 path $500 ro $1;
            k = &_i;
            libref = "%upcase(&_lib)";
            path = symget('_pth');
            ro = ifc(upcase(strip(symget('_ro'))) = 'YES', 'Y', 'N');
        run;
        proc append base=work._wif_libsave data=work._wif_libsave_add; run;
        proc datasets lib=work nolist nowarn; delete _wif_libsave_add; quit;
        libname _WIFB&_i "&_pth" access=readonly;
    %end;
%end;

/* ---- stage table by table, rule by rule ---- */
%local _bail;
%let _bail = 0;
%let _prev = ;
%do _i = 1 %to &_n;
    %if &_bail = 0 %then %do;
        %let _t = ;
        %let _seq = 0;
        %let _verb = ;
        proc sql noprint;
            select target, put(seq, best8.-l), verb
                into :_t trimmed, :_seq trimmed, :_verb trimmed
                from work._wif_sttodo where rule_i = &_i;
        quit;
        %let _lib = %upcase(%scan(&_t, 1, .));
        %let _mem = %upcase(%scan(&_t, 2, .));
        /* which readonly base libref reads this table               */
        %if %length(%superq(base)) > 0 %then %let _fromlib = _WIFB1;
        %else %do;
            proc sql noprint;
                select cats('_WIFB', put(k, best8.-l)) into :_fromlib trimmed
                from work._wif_libsave where libref = "&_lib";
            quit;
        %end;
        %let _first = 0;
        %if "&_prev" ne "&_lib..&_mem" %then %let _first = 1;
        %let _prev = &_lib..&_mem;
        %if &_first = 1 and &_verb = CODE %then %do;
            /* CODE cannot fuse the base->staging copy; pre-copy     */
            data _WIFI.&_mem(compress=binary);
                set &_fromlib..&_mem;
            run;
            %if &syscc > 4 %then %do;
                %put ERROR: [WIF] could not stage &_lib..&_mem (pre-copy failed).;
                %let WIF_RC = 1;
                %let _bail = 1;
            %end;
            %let _first = 0;
        %end;
        %if &_bail = 0 %then %do;
            /* swap the sttodo row into _wif_todo shape              */
            data work._wif_todo;
                set work._wif_sttodo;
                where rule_i = &_i;
                rule_i = 1;
            run;
            %if &_first = 1 %then %do;
                %_wif_apply_rule(rulei=1, from=&_fromlib..&_mem, to=_WIFI.&_mem,
                                 hook=INPUT, compress=1)
            %end;
            %else %do;
                %_wif_apply_rule(rulei=1, from=_WIFI.&_mem, to=_WIFI.&_mem,
                                 hook=INPUT, compress=1)
            %end;
            %if &WIF_APRC = 1 %then %do;
                %let WIF_RC = 1;
                %let _bail = 1;
            %end;
        %end;
    %end;
%end;

%if &_bail = 1 %then %do;
    %put ERROR: [WIF] INPUT staging failed - restoring librefs, nothing activated.;
    libname _WIFI clear;
    %_wif_restore_libs()
    proc datasets lib=work nolist nowarn; delete _wif_stlibs _wif_todo; quit;
    %return;
%end;

/* ---- repoint the librefs: staged first, readonly base second ---- */
%if %length(%superq(base)) > 0 %then %do;
    libname &inlib ("&_stagedir" _WIFB1);
    %if &syslibrc ne 0 %then %do;
        %put ERROR: [WIF] could not repoint libref &inlib (syslibrc=&syslibrc) - restoring librefs, nothing activated.;
        %let WIF_RC = 1;
        libname _WIFI clear;
        %_wif_restore_libs()
        proc datasets lib=work nolist nowarn; delete _wif_stlibs _wif_todo; quit;
        %return;
    %end;
    %put NOTE: [WIF] libref &inlib now reads staged copies first, then the readonly base &_b..;
%end;
%else %do;
    %do _i = 1 %to &_nlibs;
        %if &_bail = 0 %then %do;
            %let _lib = ;
            proc sql noprint;
                select libref into :_lib trimmed
                from work._wif_libsave where k = &_i;
            quit;
            libname &_lib ("&_stagedir" _WIFB&_i);
            %if &syslibrc ne 0 %then %do;
                %put ERROR: [WIF] could not repoint libref &_lib (syslibrc=&syslibrc) - restoring librefs, nothing activated.;
                %let WIF_RC = 1;
                %let _bail = 1;
            %end;
            %else %put NOTE: [WIF] libref &_lib now reads staged copies first, then its readonly base.;
        %end;
    %end;
    %if &_bail = 1 %then %do;
        libname _WIFI clear;
        %_wif_restore_libs()
        proc datasets lib=work nolist nowarn; delete _wif_stlibs _wif_todo; quit;
        %return;
    %end;
%end;
libname _WIFI clear;
proc datasets lib=work nolist nowarn; delete _wif_stlibs _wif_todo; quit;
%mend _wif_stage;

/*==================================================================
  PUBLIC API
==================================================================*/

/* Activate a scenario. Nothing is modified unless every lint check
   passes; INPUT rules stage during init; everything else fires at
   its %wif() hook. The wrapper guarantees the session options are
   restored when init fails for any reason.                          */
%macro wif_init(scenario=, rules=, iter=1, params=, onfail=STOP,
                inlib=, base=, maxhash=);
%_wif_opts_save()
%_wif_init_core(scenario=%superq(scenario), rules=%superq(rules), iter=&iter,
                params=%superq(params), onfail=&onfail, inlib=&inlib,
                base=&base, maxhash=&maxhash)
%if &WIF_RC ne 0 %then %do;
    %_wif_opts_restore()
%end;
%mend wif_init;

%macro _wif_init_core(scenario=, rules=, iter=, params=, onfail=,
                      inlib=, base=, maxhash=);
%_wif_restore_libs()
%let WIF_ACTIVE = 0;
%let WIF_RC = 0;
%let WIF_MSG = ;
proc datasets lib=work nolist nowarn;
    delete _wif_rules _wif_lets _wif_params _wif_fired _wif_todo
           _wif_skip _wif_sttodo _wif_lerrs _wif_pf _wif_stlibs;
quit;

/* ---- argument validation ---- */
%if %length(%superq(scenario)) = 0 %then %do;
    %put ERROR: [WIF] wif_init needs scenario=.;
    %let WIF_RC = 1;
    %return;
%end;
%if not %sysfunc(nvalid(%superq(scenario), v7)) %then %do;
    %put ERROR: [WIF] bad scenario name: %superq(scenario) (letters, digits, underscore).;
    %let WIF_RC = 1;
    %return;
%end;
%if %length(%superq(scenario)) > 32 %then %do;
    %put ERROR: [WIF] scenario name longer than 32 characters.;
    %let WIF_RC = 1;
    %return;
%end;
%if %length(&iter) = 0 %then %let iter = 1;
%if %sysfunc(notdigit(&iter)) > 0 %then %do;
    %put ERROR: [WIF] iter= must be a positive integer (got &iter).;
    %let WIF_RC = 1;
    %return;
%end;
%if %length(&onfail) = 0 %then %let onfail = STOP;
%let onfail = %upcase(&onfail);
%if &onfail ne STOP and &onfail ne CONTINUE %then %do;
    %put ERROR: [WIF] onfail= must be STOP or CONTINUE.;
    %let WIF_RC = 1;
    %return;
%end;
%if %length(&maxhash) > 0 %then %do;
    %if %sysfunc(notdigit(&maxhash)) = 0 %then %let WIF_MAXHASH = &maxhash;
    %else %put WARNING: [WIF] maxhash= ignored (not a number): &maxhash;
%end;
%let WIF_SCENARIO  = %upcase(&scenario);
%let WIF_ITER      = &iter;
%let WIF_ONFAIL    = &onfail;
%let WIF_PARAMSTR  = %superq(params);
%let WIF_RULES_SRC = %superq(rules);

/* ---- load + lint ---- */
data work._wif_lerrs;
    length sev $1 hook $32 seq 8 field $32 message $500;
    stop;
run;
%_wif_load_rules(rules=%superq(rules), scenario=&scenario)
%if not %sysfunc(exist(work._wif_rules)) %then %do;
    %_wif_lint_tally(print=Y)
    %let WIF_RC = 1;
    %return;
%end;
%_wif_build_params(scenario=&scenario, iter=&iter)
%_wif_scan_rules()
%_wif_check_rules()
%_wif_lint_tally(print=Y)
%if &WIF_LINTE > 0 %then %do;
    %let WIF_RC = 1;
    %return;
%end;

/* ---- generation folder + trackers ---- */
%let WIF_GEN  = %eval(&WIF_GEN + 1);
%let WIF_FIRE = 0;
%let WIF_GENDIR = %_wif_path(%sysfunc(pathname(work)))/wif_gen;
%_wif_mkdir(&WIF_GENDIR)
%if &WIF_UTILRC ne 0 %then %do;
    %let WIF_RC = 1;
    %return;
%end;
data work._wif_fired;
    length hook $32 seq 8;
    stop;
run;

/* ---- INPUT staging ---- */
data work._wif_sttodo;
    length rule_i 8;
    retain rule_i 0;
    set work._wif_rules;
    where hook = 'INPUT';
    rule_i + 1;
run;
proc sort data=work._wif_sttodo; by target seq; run;
data work._wif_sttodo;
    set work._wif_sttodo;
    rule_i = _n_;
run;
%_wif_stage(inlib=&inlib, base=&base)
%if &WIF_RC ne 0 %then %do;
    %put ERROR: [WIF] wif_init failed during INPUT staging.;
    %return;
%end;

%let WIF_ACTIVE = 1;
%put NOTE: [WIF] ============================================================;
%put NOTE: [WIF] scenario &WIF_SCENARIO ACTIVE (iter=&WIF_ITER, onfail=&WIF_ONFAIL, &WIF_LOADN rule(s)).;
%put NOTE: [WIF] hooks will fire as the program runs - wif_off deactivates.;
%put NOTE: [WIF] ============================================================;
%mend _wif_init_core;

/* Deactivate: restore librefs, keep work.wif_log for the post-run
   review, restore session options.                                  */
%macro wif_off();
%local _nok _nbad;
%_wif_restore_libs()
%if "&WIF_ACTIVE" = "1" %then %do;
    %let _nok = 0;
    %let _nbad = 0;
    %if %sysfunc(exist(work.wif_log)) %then %do;
        proc sql noprint;
            select coalesce(sum(status = 'OK'), 0),
                   coalesce(sum(status not in ('OK', 'SKIP_ITER', 'SKIP_ONCE')), 0)
                into :_nok trimmed, :_nbad trimmed
                from work.wif_log where gen = &WIF_GEN;
        quit;
    %end;
    %put NOTE: [WIF] scenario &WIF_SCENARIO deactivated: &_nok rule application(s) OK, &_nbad problem(s). work.wif_log has the detail.;
%end;
%let WIF_ACTIVE = 0;
%_wif_opts_restore()
%mend wif_off;

/* End-of-run gate for batch drivers: ERROR (or ABORT) if anything
   FAILED, went missing, or was skipped by a failure. strict=Y also
   flags OK rules that affected 0 rows (the silent-typo class).      */
%macro wif_check(scope=GEN, onbad=ERROR, strict=N);
%local _bad _warn0 _w;
%if not %sysfunc(exist(work.wif_log)) %then %do;
    %put NOTE: [WIF] wif_check: no wif_log in this session - nothing to check.;
    %return;
%end;
%let _w = %upcase(&scope);
%if &_w ne GEN and &_w ne SESSION %then %let _w = GEN;
%let _bad = 0;
%let _warn0 = 0;
proc sql noprint;
    select coalesce(sum(status in ('FAILED', 'NO_TABLE', 'SKIP_SYSCC', 'SKIP_FAIL')), 0)
        into :_bad trimmed
        from work.wif_log
        %if &_w = GEN %then where gen = &WIF_GEN;
        ;
quit;
%if %upcase(&strict) = Y %then %do;
    proc sql noprint;
        select coalesce(sum(status = 'OK' and rows_affected = 0
                            and verb in ('SET', 'JOIN', 'FILTER', 'APPEND')), 0)
            into :_warn0 trimmed
            from work.wif_log
            %if &_w = GEN %then where gen = &WIF_GEN;
            ;
    quit;
%end;
%if %eval(&_bad + &_warn0) = 0 %then %do;
    %put NOTE: [WIF] wif_check: clean (scope=&_w, strict=%upcase(&strict)).;
    %return;
%end;
title '[WIF] wif_check findings';
proc print data=work.wif_log noobs width=min;
    where (status in ('FAILED', 'NO_TABLE', 'SKIP_SYSCC', 'SKIP_FAIL')
      %if %upcase(&strict) = Y %then %do;
           or (status = 'OK' and rows_affected = 0
               and verb in ('SET', 'JOIN', 'FILTER', 'APPEND'))
      %end;
          )
      %if &_w = GEN %then and gen = &WIF_GEN;
      ;
    var gen scenario iter hook seq verb target status rows_affected message;
run;
title;
%let WIF_RC = 1;
%if %upcase(&strict) = Y %then
    %put ERROR: [WIF] wif_check: &_bad problem row(s) and &_warn0 zero-affected OK row(s) (scope=&_w) - see the findings above before trusting these outputs.;
%else
    %put ERROR: [WIF] wif_check: &_bad problem row(s) (scope=&_w) - see the findings above before trusting these outputs.;
%if %upcase(&onbad) = ABORT %then %do;
    %abort cancel;
%end;
%mend wif_check;

/* Print the run log + a compact summary.                            */
%macro wif_report();
%if not %sysfunc(exist(work.wif_log)) %then %do;
    %put NOTE: [WIF] no wif_log in this session yet.;
    %return;
%end;
title '[WIF] rule applications this session';
proc print data=work.wif_log noobs width=min;
    var gen scenario iter hook seq verb target status
        rows_before rows_after rows_affected message;
run;
title '[WIF] summary by scenario / status';
proc freq data=work.wif_log;
    tables scenario * status / nocum nopercent norow nocol missing;
run;
title;
%mend wif_report;

/* Validate rules without activating anything.                       */
%macro wif_lint(rules=, scenario=, iter=1, params=);
%if "&WIF_ACTIVE" = "1" %then
    %put WARNING: [WIF] wif_lint replaces the loaded rules of the ACTIVE scenario - run wif_init again before the next hooked submit.;
%if %length(%superq(scenario)) = 0 %then %do;
    %put ERROR: [WIF] wif_lint needs scenario= (rules are validated per scenario).;
    %return;
%end;
%let WIF_RC = 0;
%let WIF_PARAMSTR = %superq(params);
data work._wif_lerrs;
    length sev $1 hook $32 seq 8 field $32 message $500;
    stop;
run;
%_wif_load_rules(rules=%superq(rules), scenario=&scenario)
%if %sysfunc(exist(work._wif_rules)) %then %do;
    %_wif_build_params(scenario=&scenario, iter=&iter)
    %_wif_scan_rules()
    %_wif_check_rules()
%end;
%_wif_lint_tally(print=Y)
%if &WIF_LINTE > 0 %then %let WIF_RC = 1;
%else %put NOTE: [WIF] rules lint clean for scenario %upcase(&scenario) (&WIF_LOADN rule(s)).;
%mend wif_lint;

/* Convenience: init -> run the program (main= file or code= compiled
   macro) -> save outputs -> off.                                     */
%macro wif_run(scenario=, main=, code=, rules=, iter=1, params=, keep=,
               outlib=work, onfail=STOP, inlib=, base=);
%local _m _i _w;
%if %length(%superq(rules)) = 0 %then %let rules = %superq(WIF_RULES_SRC);
%wif_init(scenario=&scenario, rules=%superq(rules), iter=&iter,
          params=%superq(params), onfail=&onfail, inlib=&inlib, base=&base)
%if &WIF_RC ne 0 %then %do;
    %put ERROR: [WIF] wif_run(&scenario) aborted: init failed - see the lint findings / ERROR lines printed above.;
    %return;
%end;
%if %length(%superq(code)) > 0 %then %if %length(%superq(main)) > 0 %then %do;
    %put ERROR: [WIF] wif_run: give main= (a program file) OR code= (a compiled macro), not both.;
    %wif_off()
    %return;
%end;
%if %length(%superq(code)) > 0 %then %do;
    /* EG programs often have no server path: wrap the program once
       in a macro definition, submit it, then run it by name         */
    %if %sysmacexist(&code) = 0 %then %do;
        %put ERROR: [WIF] wif_run: code=&code is not a compiled macro. Wrap your program in a macro definition, submit that once, then call wif_run again (see the guide - note DATALINES cannot live inside a macro).;
        %wif_off()
        %return;
    %end;
    %put NOTE: [WIF] running macro &code under scenario %upcase(&scenario)...;
    %unquote(%nrstr(%)&code)
    options obs=max replace nosyntaxcheck;
%end;
%else %do;
    %let _m = %_wif_path(&main);
    %if %length(&_m) = 0 %then %do;
        %put ERROR: [WIF] wif_run needs main= (a program file path) or code= (a compiled macro name).;
        %wif_off()
        %return;
    %end;
    %if not %sysfunc(fileexist(&_m)) %then %do;
        %put ERROR: [WIF] main program not found: &_m (paths must be SAS SERVER paths, not your PC paths).;
        %wif_off()
        %return;
    %end;
    %put NOTE: [WIF] running &_m under scenario %upcase(&scenario)...;
    %include "&_m" / lrecl=32767;
    options obs=max replace nosyntaxcheck;
%end;
%if &syscc > 4 %then %do;
    %put ERROR: [WIF] main program failed under scenario %upcase(&scenario) (syscc=&syscc) - outputs NOT saved. Fix the first ERROR inside the program above and resubmit%str(;) the scenario has been deactivated.;
    %wif_off()
    %if %upcase(&onfail) = STOP %then %do;
        %let WIF_RC = 2;
        %abort cancel;
    %end;
    %return;
%end;
%if %length(&keep) > 0 %then %do _i = 1 %to %sysfunc(countw(&keep, %str( )));
    %let _w = %scan(&keep, &_i, %str( ));
    %wif_save(table=&_w, as=%upcase(&scenario)_&_w, lib=&outlib)
%end;
%wif_off()
%mend wif_run;

/* Snapshot one table (typically an output, per scenario/iteration). */
%macro wif_save(table=, as=, lib=work);
%local _lib _mem _ok;
%_wif_resolve(name=&table, libvar=_lib, memvar=_mem, okvar=_ok)
%if &_ok = 0 %then %do;
    %put ERROR: [WIF] wif_save: bad table reference %superq(table).;
    %return;
%end;
%if not %sysfunc(exist(&_lib..&_mem)) %then %do;
    %put ERROR: [WIF] wif_save: &_lib..&_mem not found. Did the program create it this run? Check work.wif_log and WIF_RC.;
    %return;
%end;
%if %length(%superq(as)) = 0 %then %do;
    %put ERROR: [WIF] wif_save needs as= (the new dataset name).;
    %return;
%end;
%if not %sysfunc(nvalid(%superq(as), v7)) or %length(%superq(as)) > 32 %then %do;
    %put ERROR: [WIF] wif_save: bad as= name %superq(as) (a valid SAS name, max 32 chars - a long scenario plus table name can overflow%str(;) shorten one).;
    %return;
%end;
%if %sysfunc(libref(&lib)) ne 0 %then %do;
    %put ERROR: [WIF] wif_save: libref &lib is not assigned - assign it first with a LIBNAME statement, or use lib=work.;
    %return;
%end;
data &lib..&as;
    set &_lib..&_mem;
run;
%put NOTE: [WIF] saved &_lib..&_mem as &lib..&as (%_wif_now()).;
%mend wif_save;

/* One-glance state: version, activity, rules by hook, staged librefs,
   the last few log rows. Log-first so it photographs well.          */
%macro wif_status();
%local _hl _n _k _l1 _p1 _tail;
%put NOTE: [WIF] ------------------------- status -------------------------;
%put NOTE: [WIF] v&WIF_VERSION  ACTIVE=&WIF_ACTIVE  WIF_RC=&WIF_RC  gen=&WIF_GEN  fires=&WIF_FIRE;
%if "&WIF_ACTIVE" = "1" %then %do;
    %put NOTE: [WIF] scenario=&WIF_SCENARIO  iter=&WIF_ITER  onfail=&WIF_ONFAIL;
    %put NOTE: [WIF] rules source: %superq(WIF_RULES_SRC);
    %if %sysfunc(exist(work._wif_rules)) %then %do;
        %let _hl = ;
        proc sql noprint;
            select catx(':', hook, put(count(*), best8.-l))
                into :_hl separated by '   '
                from work._wif_rules
                group by hook;
        quit;
        %put NOTE: [WIF] rules by hook: &_hl;
    %end;
    %if %sysfunc(exist(work._wif_libsave)) %then %do;
        %_wif_nobs(ds=work._wif_libsave, mvar=_n)
        %do _k = 1 %to &_n;
            %let _l1 = ;
            %let _p1 = ;
            proc sql noprint;
                select libref, path into :_l1 trimmed, :_p1 trimmed
                from work._wif_libsave where k = &_k;
            quit;
            %if %length(&_l1) > 0 %then %do;
                %if %length(%superq(_p1)) > 0 %then
                    %put NOTE: [WIF] staged libref &_l1 (original path: %superq(_p1));
                %else
                    %put NOTE: [WIF] staged libref &_l1 (was unassigned - wif_off will clear it);
            %end;
        %end;
    %end;
%end;
%else %put NOTE: [WIF] INACTIVE - every hook expands to nothing.;
%if %sysfunc(exist(work.wif_log)) %then %do;
    %_wif_nobs(ds=work.wif_log, mvar=_n)
    %let _tail = %sysfunc(max(1, %eval(&_n - 4)));
    title '[WIF] last log rows';
    proc print data=work.wif_log(firstobs=&_tail) noobs width=min;
        var gen scenario iter hook seq verb target status rows_affected message;
    run;
    title;
%end;
%else %put NOTE: [WIF] no rule applications logged this session yet.;
%put NOTE: [WIF] -----------------------------------------------------------;
%mend wif_status;

/* The panic button: whatever state a stopped or wedged run left
   behind, make the session sane again. Keeps work.wif_log.          */
%macro wif_reset();
%local _k;
%_wif_restore_libs()
/* orphan sweep: staging librefs whose tracking dataset was lost     */
%if %sysfunc(libref(_WIFI)) = 0 %then %do;
    libname _WIFI clear;
%end;
%do _k = 1 %to 9;
    %if %sysfunc(libref(_WIFB&_k)) = 0 %then %do;
        libname _WIFB&_k clear;
    %end;
%end;
%let WIF_ACTIVE = 0;
%let WIF_RC = 0;
%let WIF_MSG = ;
proc datasets lib=work nolist nowarn;
    delete _wif_rules _wif_lets _wif_params _wif_fired _wif_todo
           _wif_skip _wif_sttodo _wif_lerrs _wif_pf _wif_stlibs;
quit;
%_wif_opts_restore()
options obs=max replace;
%let syscc = 0;
%put NOTE: [WIF] reset complete - hooks inert, librefs restored/cleared, error state cleared, work.wif_log kept.;
%mend wif_reset;

/* Scenario-vs-baseline output digest: row counts, orphan keys both
   ways, changed-row counts, and per numeric column the n / sum /
   mean side by side with deltas (the number an actuary reads first
   is "how much did total premium move"). Pairs with the
   <SCENARIO>_<table> names that wif_run keep= produces.             */
%macro wif_compare(base=, scen=, tables=, keys=, lib=work,
                   out=work.wif_compare, print=Y);
%local _i _t _b _s _nb _ns _oa _ob _chg _si _kk _kw _ty1 _ty2 _bad;
%if %length(%superq(base)) = 0 or %length(%superq(scen)) = 0
    or %length(%superq(tables)) = 0 or %length(%superq(keys)) = 0 %then %do;
    %put ERROR: [WIF] wif_compare needs base=, scen=, tables= and keys=.;
    %return;
%end;
%if %sysfunc(libref(&lib)) ne 0 %then %do;
    %put ERROR: [WIF] wif_compare: libref &lib is not assigned.;
    %return;
%end;
data &out;
    length table $32 status $10 nobs_base nobs_scen only_base only_scen
           changed_rows identical 8;
    call missing(of _all_);
    stop;
run;
data &out._cols;
    length table $32 column $32 n_base n_scen mean_base mean_scen
           sum_base sum_scen delta_sum pct_delta_sum ndif 8;
    call missing(of _all_);
    stop;
run;
%do _i = 1 %to %sysfunc(countw(&tables, %str( )));
    %let _t = %upcase(%scan(&tables, &_i, %str( )));
    %let _b = &lib..%upcase(&base)_&_t;
    %let _s = &lib..%upcase(&scen)_&_t;
    %let _bad = 0;
    %if not %sysfunc(exist(&_b)) %then %let _bad = 1;
    %if not %sysfunc(exist(&_s)) %then %let _bad = 1;
    %if &_bad = 1 %then %do;
        %put WARNING: [WIF] wif_compare: &_b or &_s not found - table &_t skipped.;
        data work._wif_cmp1;
            length table $32 status $10 nobs_base nobs_scen only_base
                   only_scen changed_rows identical 8;
            table = "&_t"; status = 'MISSING';
            call missing(nobs_base, nobs_scen, only_base, only_scen,
                         changed_rows, identical);
        run;
        proc append base=&out data=work._wif_cmp1 force; run;
    %end;
    %else %do;
        /* keys must exist with matching types on both sides         */
        %do _kk = 1 %to %sysfunc(countw(&keys, %str( )));
            %let _kw = %scan(&keys, &_kk, %str( ));
            %let _ty1 = ;
            %let _ty2 = ;
            %_wif_vartype(ds=&_b, var=&_kw, mvar=_ty1)
            %_wif_vartype(ds=&_s, var=&_kw, mvar=_ty2)
            %if %length(&_ty1) = 0 %then %let _bad = 1;
            %else %if %length(&_ty2) = 0 %then %let _bad = 1;
            %else %if &_ty1 ne &_ty2 %then %let _bad = 1;
        %end;
        %if &_bad = 1 %then %do;
            %put WARNING: [WIF] wif_compare: key &_kw missing or type-mismatched on &_t - table skipped.;
            data work._wif_cmp1;
                length table $32 status $10 nobs_base nobs_scen only_base
                       only_scen changed_rows identical 8;
                table = "&_t"; status = 'BADKEYS';
                call missing(nobs_base, nobs_scen, only_base, only_scen,
                             changed_rows, identical);
            run;
            proc append base=&out data=work._wif_cmp1 force; run;
        %end;
        %else %do;
            proc sort data=&_b out=work._wif_cb; by &keys; run;
            proc sort data=&_s out=work._wif_cs; by &keys; run;
            %_wif_nobs(ds=work._wif_cb, mvar=_nb)
            %_wif_nobs(ds=work._wif_cs, mvar=_ns)
            %let _oa = 0;
            %let _ob = 0;
            data _null_;
                merge work._wif_cb(in=_a keep=&keys)
                      work._wif_cs(in=_b keep=&keys) end=_e;
                by &keys;
                retain _woa _wob 0;
                if _a and not _b then _woa + 1;
                if _b and not _a then _wob + 1;
                if _e then do;
                    call symputx('_oa', _woa);
                    call symputx('_ob', _wob);
                end;
            run;
            proc compare base=work._wif_cb compare=work._wif_cs
                         out=work._wif_cd outnoequal noprint
                         outstats=work._wif_cst;
                id &keys;
            run;
            %let _si = &sysinfo;
            %let syscc = 0;
            %let _chg = 0;
            %_wif_nobs(ds=work._wif_cd, mvar=_chg)
            data work._wif_cmp1;
                length table $32 status $10 nobs_base nobs_scen only_base
                       only_scen changed_rows identical 8;
                table = "&_t"; status = 'OK';
                nobs_base = &_nb; nobs_scen = &_ns;
                only_base = &_oa; only_scen = &_ob;
                changed_rows = &_chg;
                identical = (&_si = 0);
            run;
            proc append base=&out data=work._wif_cmp1 force; run;
            %if %sysfunc(exist(work._wif_cst)) %then %do;
                proc sort data=work._wif_cst; by _var_; run;
                data work._wif_cc;
                    length table $32 column $32;
                    merge work._wif_cst(where=(_type_='N')
                              keep=_var_ _type_ _base_ _comp_
                              rename=(_base_=n_base _comp_=n_scen))
                          work._wif_cst(where=(_type_='MEAN')
                              keep=_var_ _type_ _base_ _comp_
                              rename=(_base_=mean_base _comp_=mean_scen))
                          work._wif_cst(where=(_type_='NDIF')
                              keep=_var_ _type_ _base_
                              rename=(_base_=ndif));
                    by _var_;
                    table = "&_t";
                    column = upcase(_var_);
                    sum_base = mean_base * n_base;
                    sum_scen = mean_scen * n_scen;
                    delta_sum = sum(sum_scen, -sum_base);
                    pct_delta_sum = ifn(sum_base not in (0, .),
                                        100 * delta_sum / sum_base, .);
                    keep table column n_base n_scen mean_base mean_scen
                         sum_base sum_scen delta_sum pct_delta_sum ndif;
                run;
                proc append base=&out._cols data=work._wif_cc force; run;
            %end;
            proc datasets lib=work nolist nowarn;
                delete _wif_cb _wif_cs _wif_cd _wif_cst _wif_cc;
            quit;
        %end;
    %end;
%end;
proc datasets lib=work nolist nowarn; delete _wif_cmp1; quit;
%if %upcase(&print) = Y %then %do;
    title "[WIF] compare: %upcase(&base) vs %upcase(&scen) - tables";
    proc print data=&out noobs width=min; run;
    title "[WIF] compare: %upcase(&base) vs %upcase(&scen) - numeric columns";
    proc print data=&out._cols noobs width=min;
        format mean_base mean_scen sum_base sum_scen delta_sum best12.
               pct_delta_sum 8.2;
    run;
    title;
%end;
%put NOTE: [WIF] wif_compare done: &out (tables) and &out._cols (columns).;
%mend wif_compare;

/* Sugar: append one rule to a rules dataset (default work.wif_rules)
   from open code. For anything beyond a few rules prefer datalines
   or the workbook. Cell text with commas needs %str() around it.    */
%macro wif_rule(scenario=, hook=, seq=, verb=, target=, where=, keys=,
                source=, columns=, assign=, options=, notes=,
                rules=work.wif_rules);
%global WIF_RG1 WIF_RG2 WIF_RG3 WIF_RG4 WIF_RG5 WIF_RG6 WIF_RG7 WIF_RG8
        WIF_RG9 WIF_RG10 WIF_RG11 WIF_RGSEQ;
%let WIF_RGSEQ = %superq(seq);
%let WIF_RG1  = %superq(scenario);
%let WIF_RG2  = %superq(hook);
%let WIF_RG3  = %superq(verb);
%let WIF_RG4  = %superq(target);
%let WIF_RG5  = %superq(where);
%let WIF_RG6  = %superq(keys);
%let WIF_RG7  = %superq(source);
%let WIF_RG8  = %superq(columns);
%let WIF_RG9  = %superq(assign);
%let WIF_RG10 = %superq(options);
%let WIF_RG11 = %superq(notes);
data work._wif_rule_new;
    length scenario $32 hook $32 seq 8 active $1 verb $8 target $41
           where_clause $2000 keys $200 source $41 columns $1000
           assign $8000 options $200 notes $500;
    scenario     = symget('WIF_RG1');
    hook         = symget('WIF_RG2');
    seq          = input(symget('WIF_RGSEQ'), ?? best32.);
    active       = 'Y';
    verb         = symget('WIF_RG3');
    target       = symget('WIF_RG4');
    where_clause = symget('WIF_RG5');
    keys         = symget('WIF_RG6');
    source       = symget('WIF_RG7');
    columns      = symget('WIF_RG8');
    assign       = symget('WIF_RG9');
    options      = symget('WIF_RG10');
    notes        = symget('WIF_RG11');
run;
proc append base=&rules data=work._wif_rule_new force; run;
proc datasets lib=work nolist nowarn; delete _wif_rule_new; quit;
%put NOTE: [WIF] rule appended to &rules (hook %upcase(&hook), verb %upcase(&verb)).;
%mend wif_rule;

/*------------------------------------------------------------------
  06. BOOTSTRAP (open code -- runs once per %include)
------------------------------------------------------------------*/
%_wif_bootstrap()

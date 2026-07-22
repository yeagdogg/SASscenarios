/*=====================================================================================
  SQF SMOKE TEST SUITE
  =====================================================================================
  Fully self-contained: builds its own tiny base tables, writes its own dummy
  "main program", defines scenarios as WORK datasets (DATASET control mode),
  runs the framework end to end, and prints a PASS/FAIL summary to the log.

  TO RUN AT WORK: edit the one %let below, then submit this file.
  Everything is created under the WORK library's folder and disappears when
  the SAS session ends. Your real data is never touched.

  Success looks like:   NOTE: [TEST] ALL nn ASSERTIONS PASSED
=====================================================================================*/

%let SQF_HOME = C:/Users/Johns/PyProjects/SASscenarios;   /* <-- EDIT: folder holding sqf.sas */

%include "&SQF_HOME/sqf.sas";

/* keep one deliberate failure test from flipping batch sessions into
   syntax-check mode for the rest of the suite                          */
options nosyntaxcheck obs=max replace;

/*------------------------------------------------------------------
  Test sandbox under WORK (auto-deleted at session end)
------------------------------------------------------------------*/
%let TROOT = %sysfunc(pathname(work))/sqf_test;
%sqf_mkdir(&TROOT/base)
%sqf_mkdir(&TROOT/gold)
%sqf_mkdir(&TROOT/goldwork)
%sqf_mkdir(&TROOT/golden_out)
%sqf_mkdir(&TROOT/main)
%sqf_mkdir(&TROOT/root/custom)
%sqf_mkdir(&TROOT/csv)
%sqf_mkdir(&TROOT/ctl)

libname TBASE "&TROOT/base";
libname TGOLD "&TROOT/gold";

/*------------------------------------------------------------------
  Synthetic base tables (deterministic)
------------------------------------------------------------------*/
data TBASE.policies;
    length pol_id 8 region $1 gender $1 policy_age 8 premium 8 balance 8
           status $3 eff_date 8;
    format eff_date date9.;
    do pol_id = 1 to 100;
        region = substr('EWNS', mod(pol_id, 4) + 1, 1);
        gender = substr('MF', mod(pol_id, 2) + 1, 1);
        policy_age = 20 + mod(pol_id, 40);
        premium = 1000 + 10 * mod(pol_id, 25);
        balance = 0;
        status = 'ACT';
        if mod(pol_id, 11) = 0 then status = 'LAP';
        eff_date = '01JAN2020'd + pol_id;
        output;
    end;
run;

data TBASE.rates;
    length region $1 rate_year 8 rate_change 8;
    do rate_year = 2025 to 2027;
        do _i = 1 to 4;
            region = substr('EWNS', _i, 1);
            rate_change = 1 + 0.01 * _i + 0.001 * (rate_year - 2025);
            output;
        end;
    end;
    drop _i;
run;

data TBASE.assumptions;
    length factor_name $20 value 8;
    factor_name = 'INT_RATE';   value = 0.04; output;
    factor_name = 'LAPSE_RATE'; value = 0.05; output;
run;

data TBASE.claims;
    length claim_id 8 pol_id 8 clm_year 8 claim_amount 8 claim_status $4;
    _k = 0;
    do pol_id = 5 to 95 by 5;
        do clm_year = 2025 to 2026;
            _k + 1;
            claim_id = 1000 + 37 * _k - 36 * mod(_k, 7);   /* deliberately unsorted */
            claim_amount = 100 * mod(claim_id, 13) + 50;
            claim_status = 'OPEN';
            if mod(claim_id, 5) = 0 then claim_status = 'PAID';
            if mod(claim_id, 17) = 0 then claim_status = 'VOID';
            output;
        end;
    end;
    drop _k;
run;

data TBASE.factors;
    length age_band $5 factor 8;
    age_band = '20-29'; factor = 0.9;  output;
    age_band = '30-39'; factor = 1.0;  output;
    age_band = '40-49'; factor = 1.15; output;
    age_band = '50+';   factor = 1.3;  output;
run;

data TBASE.lapse_hist;
    length year 8 lapse_ct 8;
    do year = 2020 to 2026;
        lapse_ct = 40 + mod(year, 7) * 3;
        output;
    end;
run;

/* extra source tables for APPEND / UPDATE_FROM tests */
data TBASE.shock_claims;
    length claim_idx 8 pol_id 8 clm_year 8 amt_gross 8 claim_status $4;
    do claim_idx = 9001 to 9012;
        pol_id = 5 * (claim_idx - 9000);
        clm_year = 2026 + mod(claim_idx, 2);              /* half are 2027 */
        amt_gross = 5000 + claim_idx - 9000;
        claim_status = 'OPEN';
        output;
    end;
run;

data TBASE.newrates;
    length region $1 rate_year 8 rate_new 8;
    region = 'E'; rate_year = 2025; rate_new = 2.5; output;
    region = 'W'; rate_year = 2025; rate_new = 2.6; output;
run;

data TBASE.dupsrc;
    length region $1 rate_year 8 rate_new 8;
    region = 'E'; rate_year = 2025; rate_new = 2.5; output;
    region = 'E'; rate_year = 2025; rate_new = 9.9; output;   /* duplicate key */
run;

/* golden copy for base-pristine assertions */
proc copy in=TBASE out=TGOLD memtype=data; run;

/*------------------------------------------------------------------
  The dummy "main program" (written to disk like the real thing).
  Reads INLIB, writes OUTLIB. Deliberately sorts one input IN PLACE
  (like many legacy programs do) and re-reads another twice.
------------------------------------------------------------------*/
data _null_;
    file "&TROOT/main/dummy_main.sas" lrecl=1000;
    put 'proc sort data=INLIB.claims; by claim_id; run;';
    put 'data work.m_rates;  set INLIB.rates; run;';
    put 'data work.m_rates2; set INLIB.rates; run;   /* double re-read */';
    put 'data OUTLIB.out_claims; set INLIB.claims; run;';
    put 'proc summary data=INLIB.policies nway;';
    put '    class region;';
    put '    var premium policy_age;';
    put '    output out=OUTLIB.out_policy_sum(drop=_type_ _freq_)';
    put '        sum(premium)=tot_premium mean(policy_age)=avg_age n(premium)=n_pol;';
    put 'run;';
    put 'proc sql;';
    put '    create table OUTLIB.out_summary as';
    put '    select p.region, r.rate_year,';
    put '           sum(round(p.premium * r.rate_change, .01)) as adj_premium';
    put '    from INLIB.policies p, work.m_rates r';
    put "    where p.region = r.region and p.status = 'ACT'";
    put '    group by p.region, r.rate_year';
    put '    order by p.region, r.rate_year;';
    put 'quit;';
    put 'proc sql noprint;';
    put '    select value into :m_int trimmed from INLIB.assumptions';
    put "    where upcase(factor_name) = 'INT_RATE';";
    put 'quit;';
    put 'data OUTLIB.out_balance;';
    put '    set INLIB.policies(keep=pol_id premium balance);';
    put '    balance = round(balance * (1 + &m_int) + premium, .01);';
    put 'run;';
run;

/*------------------------------------------------------------------
  Assertion machinery
------------------------------------------------------------------*/
data work.t_results;
    length id $12 desc $120 pass 8;
    call missing(of _all_);
    stop;
run;

%macro t_rec(id=, desc=, pass=);
data work.t_r1;
    length id $12 desc $120 pass 8;
    id = "&id"; desc = "&desc"; pass = &pass;
run;
proc append base=work.t_results data=work.t_r1 force; run;
proc datasets lib=work nolist nowarn; delete t_r1; quit;
%if &pass ne 1 %then %put ERROR: [TEST] &id FAILED: &desc;
%else %put NOTE: [TEST] &id passed: &desc;
%mend t_rec;

%macro assert_true(flag=, id=, desc=);
%local _p;
%let _p = 0;
%if &flag = 1 %then %let _p = 1;
%t_rec(id=&id, desc=&desc, pass=&_p)
%mend assert_true;

%macro assert_status(expect=, id=, desc=);
%local _p;
%let _p = 0;
%if &SQF_LAST_STATUS = &expect %then %let _p = 1;
%t_rec(id=&id, desc=&desc [got &SQF_LAST_STATUS], pass=&_p)
%mend assert_status;

%macro assert_ds_equal(a=, b=, id=, desc=, idvars=);
%local _p _si;
%let _p = 0;
%let _si = -1;
%if %sysfunc(exist(&a)) and %sysfunc(exist(&b)) %then %do;
    %if %length(&idvars) > 0 %then %do;
        proc sort data=&a out=work._t_a; by &idvars; run;
        proc sort data=&b out=work._t_b; by &idvars; run;
        proc compare base=work._t_a compare=work._t_b noprint;
            id &idvars;
        run;
        %let _si = &sysinfo;
        proc datasets lib=work nolist nowarn; delete _t_a _t_b; quit;
    %end;
    %else %do;
        proc compare base=&a compare=&b noprint; run;
        %let _si = &sysinfo;
    %end;
    %if &_si = 0 %then %let _p = 1;
%end;
%let syscc = 0;
%t_rec(id=&id, desc=&desc [sysinfo=&_si], pass=&_p)
%mend assert_ds_equal;

%macro assert_ds_differ(a=, b=, id=, desc=);
%local _p _si;
%let _p = 0;
%if %sysfunc(exist(&a)) and %sysfunc(exist(&b)) %then %do;
    proc compare base=&a compare=&b noprint; run;
    %let _si = &sysinfo;
    %if &_si ne 0 %then %let _p = 1;
%end;
%let syscc = 0;
%t_rec(id=&id, desc=&desc, pass=&_p)
%mend assert_ds_differ;

%macro assert_base_pristine(id=);
%local _p _mems _i _m _si;
%let _p = 1;
%let _mems = POLICIES RATES ASSUMPTIONS CLAIMS FACTORS LAPSE_HIST SHOCK_CLAIMS NEWRATES DUPSRC;
%do _i = 1 %to %sysfunc(countw(&_mems));
    %let _m = %scan(&_mems, &_i);
    proc compare base=TGOLD.&_m compare=TBASE.&_m noprint; run;
    %let _si = &sysinfo;
    %if &_si ne 0 %then %do;
        %let _p = 0;
        %put ERROR: [TEST] base table &_m was modified! sysinfo=&_si;
    %end;
%end;
%let syscc = 0;
%t_rec(id=&id, desc=base library still pristine, pass=&_p)
%mend assert_base_pristine;

/* helpers around the last run */
%global TLASTDIR;
%macro use_last_run();
%let TLASTDIR = &SQF_LAST_RUN_DIR;
libname TIN  "&TLASTDIR/inputs"  access=readonly;
libname TOUT "&TLASTDIR/outputs" access=readonly;
libname TAUD "&TLASTDIR/audit"   access=readonly;
%mend use_last_run;

%macro drop_run_libs();
%if %sysfunc(libref(TIN))  = 0 %then %do; libname TIN clear;  %end;
%if %sysfunc(libref(TOUT)) = 0 %then %do; libname TOUT clear; %end;
%if %sysfunc(libref(TAUD)) = 0 %then %do; libname TAUD clear; %end;
%mend drop_run_libs;

%macro staged_count(mvar=);
%let &mvar = -1;
%if %sysfunc(libref(TIN)) = 0 %then %do;
    proc sql noprint;
        select count(*) into :&mvar trimmed from dictionary.tables
        where libname = 'TIN' and memtype = 'DATA';
    quit;
%end;
%mend staged_count;

/* blank step template: every test rebuilds ctl_* from these           */
%macro ctl_blank();
data work.ctl_scenarios;
    length scenario_id $32 description $256 parent_scenario $32 active $1 notes $500;
    call missing(of _all_);
    stop;
run;
data work.ctl_steps;
    length scenario_id $32 step_no 8 active $1 method $16 target_table $32
           where_clause $4000 key_vars $500 source $500 assignments $8000
           options $200 notes $500;
    call missing(of _all_);
    stop;
run;
data work.ctl_parameters;
    length name $32 value $2000 scenario_id $32 notes $500;
    call missing(of _all_);
    stop;
run;
%mend ctl_blank;

/*------------------------------------------------------------------
  Framework session defaults
------------------------------------------------------------------*/
%sqf_setup(root=&TROOT/root, base=&TROOT/base, main=&TROOT/main/dummy_main.sas,
           inlib=INLIB, outlib=OUTLIB)

/*==================================================================
  T01  Baseline parity: framework run == direct run of dummy_main
==================================================================*/
libname GWRK "&TROOT/goldwork";
proc copy in=TBASE out=GWRK memtype=data; run;
libname INLIB "&TROOT/goldwork";
libname OUTLIB "&TROOT/golden_out";
%include "&TROOT/main/dummy_main.sas";
libname INLIB clear;
libname OUTLIB clear;
libname GOUT "&TROOT/golden_out";

%ctl_blank()
data work.ctl_scenarios;
    length scenario_id $32 description $256 parent_scenario $32 active $1 notes $500;
    call missing(of _all_);
    scenario_id = 'BASELINE'; description = 'no changes'; active = 'Y'; output;
run;
data work.ctl_steps;
    length scenario_id $32 step_no 8 active $1 method $16 target_table $32
           where_clause $4000 key_vars $500 source $500 assignments $8000
           options $200 notes $500;
    call missing(of _all_);
    scenario_id = 'BASELINE'; step_no = 10; active = 'Y';
    method = 'COPY_TABLE'; target_table = 'CLAIMS'; output;
run;

%run_scenario(scenario=BASELINE, html=N)
%assert_status(expect=COMPLETED, id=T01a, desc=baseline run completes)
%use_last_run()
%global TRUNDIR_T01;
%let TRUNDIR_T01 = &TLASTDIR;
%assert_ds_equal(a=GOUT.out_summary,    b=TOUT.out_summary,    id=T01b, desc=out_summary matches direct run)
%assert_ds_equal(a=GOUT.out_policy_sum, b=TOUT.out_policy_sum, id=T01c, desc=out_policy_sum matches direct run)
%assert_ds_equal(a=GOUT.out_balance,    b=TOUT.out_balance,    id=T01d, desc=out_balance matches direct run)
%assert_ds_equal(a=GOUT.out_claims,     b=TOUT.out_claims,     id=T01e, desc=out_claims matches direct run)
%global TRES;
%let TRES = ;
%sqf_resolve_run(root=&TROOT/root, scenario=BASELINE, mvar=TRES)
%assert_true(flag=%eval(%index(&TRES, &SQF_LAST_RUN_ID) > 0), id=T01f,
             desc=registry resolves latest BASELINE run)
%drop_run_libs()
%assert_base_pristine(id=T01g)

/*==================================================================
  T02  SET_VALUES, IF-safe path + report.html + audit rows-affected
==================================================================*/
%ctl_blank()
data work.ctl_scenarios;
    length scenario_id $32 description $256 parent_scenario $32 active $1 notes $500;
    call missing(of _all_);
    scenario_id = 'AGEUP'; description = 'age +1 in East'; active = 'Y'; output;
run;
data work.ctl_steps;
    length scenario_id $32 step_no 8 active $1 method $16 target_table $32
           where_clause $4000 key_vars $500 source $500 assignments $8000
           options $200 notes $500;
    call missing(of _all_);
    scenario_id = 'AGEUP'; step_no = 10; active = 'Y';
    method = 'SET_VALUES'; target_table = 'POLICIES';
    where_clause = "region = 'E'";
    assignments  = 'policy_age = policy_age + 1;';
    output;
run;

%run_scenario(scenario=AGEUP, mode=APPLYONLY, html=Y)
%assert_status(expect=COMPLETED, id=T02a, desc=AGEUP apply-only completes)
%use_last_run()
data work.exp_pol;
    set TGOLD.policies;
    if region = 'E' then policy_age = policy_age + 1;
run;
%assert_ds_equal(a=work.exp_pol, b=TIN.policies, id=T02b, desc=East ages +1 and row order kept)
%global TSTG;
%staged_count(mvar=TSTG)
%assert_true(flag=%eval(&TSTG = 1), id=T02c, desc=only the modified table is staged [got &TSTG])
%assert_true(flag=%sysfunc(fileexist(&TLASTDIR/audit/report.html)), id=T02d, desc=report.html exists)
%let TAFF = -1;
proc sql noprint;
    select coalesce(sum(aff), -1) into :TAFF trimmed
    from TAUD.audit_steps where step = 10;
quit;
%assert_true(flag=%eval(&TAFF = 25), id=T02e, desc=audit says 25 rows affected [got &TAFF])
%drop_run_libs()
%assert_base_pristine(id=T02f)

/*==================================================================
  T03  SET_VALUES, WHERE-only operators (order-preserving split path)
==================================================================*/
%ctl_blank()
data work.ctl_scenarios;
    length scenario_id $32 description $256 parent_scenario $32 active $1 notes $500;
    call missing(of _all_);
    scenario_id = 'AGELIKE'; active = 'Y'; output;
run;
data work.ctl_steps;
    length scenario_id $32 step_no 8 active $1 method $16 target_table $32
           where_clause $4000 key_vars $500 source $500 assignments $8000
           options $200 notes $500;
    call missing(of _all_);
    scenario_id = 'AGELIKE'; step_no = 10; active = 'Y';
    method = 'SET_VALUES'; target_table = 'POLICIES';
    where_clause = "region like 'E%' and premium between 1000 and 1100";
    assignments  = 'policy_age = policy_age + 5;';
    output;
run;

%run_scenario(scenario=AGELIKE, mode=APPLYONLY, html=N)
%assert_status(expect=COMPLETED, id=T03a, desc=split-path scenario completes)
%use_last_run()
data work.exp_pol3;
    set TGOLD.policies;
    if region =: 'E' and 1000 <= premium <= 1100 then policy_age = policy_age + 5;
run;
%assert_ds_equal(a=work.exp_pol3, b=TIN.policies, id=T03b,
                 desc=LIKE/BETWEEN rows modified and original order preserved)
%drop_run_libs()
%assert_base_pristine(id=T03c)

/*==================================================================
  T04  Parameters, scoping, literal substitution, quote inertness
==================================================================*/
%ctl_blank()
data work.ctl_scenarios;
    length scenario_id $32 description $256 parent_scenario $32 active $1 notes $500;
    call missing(of _all_);
    scenario_id = 'RATEUP2'; active = 'Y'; output;
run;
data work.ctl_steps;
    length scenario_id $32 step_no 8 active $1 method $16 target_table $32
           where_clause $4000 key_vars $500 source $500 assignments $8000
           options $200 notes $500;
    call missing(of _all_);
    scenario_id = 'RATEUP2'; step_no = 10; active = 'Y';
    method = 'SET_VALUES'; target_table = 'RATES';
    /* literal ampersand inside single quotes must stay inert: build the
       cell value as   region ne 'Q&A'   without writing an ampersand
       in this source file                                              */
    where_clause = 'region ne ' || "'Q" || '26'x || "A'";
    assignments  = 'rate_change = rate_change * &RATE_BUMP.;';
    output;
    scenario_id = 'RATEUP2'; step_no = 20; active = 'Y';
    method = 'COPY_TABLE'; target_table = 'CLAIMS';
    where_clause = ' '; assignments = ' ';
    output;
run;
data work.ctl_parameters;
    length name $32 value $2000 scenario_id $32 notes $500;
    call missing(of _all_);
    name = 'RATE_BUMP'; value = '1.10'; scenario_id = ' '; output;      /* global   */
    name = 'RATE_BUMP'; value = '1.25'; scenario_id = 'RATEUP2'; output;/* override */
run;

%run_scenario(scenario=RATEUP2, mode=FULL, html=N)
%assert_status(expect=COMPLETED, id=T04a, desc=parameterized FULL run completes)
%use_last_run()
%global TRUNDIR_T04;
%let TRUNDIR_T04 = &TLASTDIR;
data work.exp_rates;
    set TGOLD.rates;
    rate_change = rate_change * 1.25;
run;
%assert_ds_equal(a=work.exp_rates, b=TIN.rates, id=T04b, desc=scenario override 1.25 wins over global 1.10)
/* generated code is literal: contains 1.25, contains no ampersand-references */
data _null_;
    infile "&TLASTDIR/gen/apply.sas" lrecl=32767 truncover end=_e;
    input;
    retain _has125 0 _hasamp 0;
    if index(_infile_, '* 1.25') > 0 then _has125 = 1;
    if index(_infile_, '26'x || 'RATE_BUMP') > 0 then _hasamp = 1;
    if _e then do;
        call symputx('T04HAS', _has125);
        call symputx('T04AMP', _hasamp);
    end;
run;
%assert_true(flag=&T04HAS, id=T04c, desc=apply.sas contains the literal 1.25)
%assert_true(flag=%eval(&T04AMP = 0), id=T04d, desc=no unresolved parameter reference in apply.sas)
%assert_ds_differ(a=GOUT.out_summary, b=TOUT.out_summary, id=T04e, desc=outputs moved vs baseline)
%drop_run_libs()
%assert_base_pristine(id=T04f)

/*==================================================================
  T05  FILTER_ROWS keep vs DROP
==================================================================*/
%ctl_blank()
data work.ctl_scenarios;
    length scenario_id $32 description $256 parent_scenario $32 active $1 notes $500;
    call missing(of _all_);
    scenario_id = 'CLMKEEP'; active = 'Y'; output;
    scenario_id = 'CLMDROP'; active = 'Y'; output;
run;
data work.ctl_steps;
    length scenario_id $32 step_no 8 active $1 method $16 target_table $32
           where_clause $4000 key_vars $500 source $500 assignments $8000
           options $200 notes $500;
    call missing(of _all_);
    scenario_id = 'CLMKEEP'; step_no = 10; active = 'Y';
    method = 'FILTER_ROWS'; target_table = 'CLAIMS';
    where_clause = "claim_status ne 'VOID'";
    output;
    scenario_id = 'CLMDROP'; step_no = 10; active = 'Y';
    method = 'FILTER_ROWS'; target_table = 'CLAIMS';
    where_clause = "claim_status = 'VOID'";
    options = 'DROP';
    output;
run;

data work.exp_clm;
    set TGOLD.claims;
    where claim_status ne 'VOID';
run;
%run_scenario(scenario=CLMKEEP, mode=APPLYONLY, html=N)
%assert_status(expect=COMPLETED, id=T05a, desc=FILTER keep completes)
%use_last_run()
%assert_ds_equal(a=work.exp_clm, b=TIN.claims, id=T05b, desc=keep-filter result correct)
%drop_run_libs()
%run_scenario(scenario=CLMDROP, mode=APPLYONLY, html=N)
%assert_status(expect=COMPLETED, id=T05c, desc=FILTER DROP completes)
%use_last_run()
%assert_ds_equal(a=work.exp_clm, b=TIN.claims, id=T05d, desc=drop-filter equals keep-filter)
%drop_run_libs()
%assert_base_pristine(id=T05e)

/*==================================================================
  T06  APPEND_ROWS with rename mapping + source-side where
==================================================================*/
%ctl_blank()
data work.ctl_scenarios;
    length scenario_id $32 description $256 parent_scenario $32 active $1 notes $500;
    call missing(of _all_);
    scenario_id = 'SHOCKADD'; active = 'Y'; output;
run;
data work.ctl_steps;
    length scenario_id $32 step_no 8 active $1 method $16 target_table $32
           where_clause $4000 key_vars $500 source $500 assignments $8000
           options $200 notes $500;
    call missing(of _all_);
    scenario_id = 'SHOCKADD'; step_no = 10; active = 'Y';
    method = 'APPEND_ROWS'; target_table = 'CLAIMS';
    source = 'BASE:SHOCK_CLAIMS';
    where_clause = 'clm_year = 2027';
    assignments = 'claim_id=claim_idx; claim_amount=amt_gross';
    output;
run;

%run_scenario(scenario=SHOCKADD, mode=APPLYONLY, html=N)
%assert_status(expect=COMPLETED, id=T06a, desc=APPEND with rename completes)
%use_last_run()
data work.exp_app;
    set TGOLD.claims
        TGOLD.shock_claims(where=(clm_year = 2027)
                           rename=(claim_idx=claim_id amt_gross=claim_amount)
                           keep=claim_idx amt_gross pol_id clm_year claim_status);
run;
%assert_ds_equal(a=work.exp_app, b=TIN.claims, id=T06b, desc=appended rows correct incl rename + filter)
%drop_run_libs()
%assert_base_pristine(id=T06c)

/*==================================================================
  T07  UPDATE_FROM by keys (hash) - matched update, unmatched intact
==================================================================*/
%ctl_blank()
data work.ctl_scenarios;
    length scenario_id $32 description $256 parent_scenario $32 active $1 notes $500;
    call missing(of _all_);
    scenario_id = 'RATEFIX'; active = 'Y'; output;
run;
data work.ctl_steps;
    length scenario_id $32 step_no 8 active $1 method $16 target_table $32
           where_clause $4000 key_vars $500 source $500 assignments $8000
           options $200 notes $500;
    call missing(of _all_);
    scenario_id = 'RATEFIX'; step_no = 10; active = 'Y';
    method = 'UPDATE_FROM'; target_table = 'RATES';
    key_vars = 'REGION RATE_YEAR';
    source = 'BASE:NEWRATES';
    assignments = 'rate_change=rate_new';
    output;
run;

%run_scenario(scenario=RATEFIX, mode=APPLYONLY, html=N)
%assert_status(expect=COMPLETED, id=T07a, desc=UPDATE_FROM completes)
%use_last_run()
data work.exp_rf;
    set TGOLD.rates;
    if region = 'E' and rate_year = 2025 then rate_change = 2.5;
    else if region = 'W' and rate_year = 2025 then rate_change = 2.6;
run;
%assert_ds_equal(a=work.exp_rf, b=TIN.rates, id=T07b, desc=matched rows updated - unmatched and order intact)
%let TAFF7 = -1;
proc sql noprint;
    select coalesce(sum(aff), -1) into :TAFF7 trimmed
    from TAUD.audit_steps where step = 10;
quit;
%assert_true(flag=%eval(&TAFF7 = 2), id=T07c, desc=audit says 2 rows matched [got &TAFF7])
%drop_run_libs()
%assert_base_pristine(id=T07d)

/*==================================================================
  T08  Multiple steps on the same table (later sees earlier)
==================================================================*/
%ctl_blank()
data work.ctl_scenarios;
    length scenario_id $32 description $256 parent_scenario $32 active $1 notes $500;
    call missing(of _all_);
    scenario_id = 'NZERO'; active = 'Y'; output;
run;
data work.ctl_steps;
    length scenario_id $32 step_no 8 active $1 method $16 target_table $32
           where_clause $4000 key_vars $500 source $500 assignments $8000
           options $200 notes $500;
    call missing(of _all_);
    scenario_id = 'NZERO'; step_no = 10; active = 'Y';
    method = 'SET_VALUES'; target_table = 'POLICIES';
    where_clause = "region = 'N'";
    assignments = 'premium = 0;';
    output;
    scenario_id = 'NZERO'; step_no = 20; active = 'Y';
    method = 'FILTER_ROWS'; target_table = 'POLICIES';
    where_clause = 'premium > 0';
    assignments = ' ';
    output;
run;

%run_scenario(scenario=NZERO, mode=APPLYONLY, html=N)
%assert_status(expect=COMPLETED, id=T08a, desc=two-step same-table scenario completes)
%use_last_run()
data work.exp_nz;
    set TGOLD.policies;
    where region ne 'N';
run;
%assert_ds_equal(a=work.exp_nz, b=TIN.policies, id=T08b, desc=step 2 filtered on step 1 result)
%drop_run_libs()
%assert_base_pristine(id=T08c)

/*==================================================================
  T09  REPLACE_TABLE from a previous run's OUTPUT (RUN: + registry)
==================================================================*/
%ctl_blank()
data work.ctl_scenarios;
    length scenario_id $32 description $256 parent_scenario $32 active $1 notes $500;
    call missing(of _all_);
    scenario_id = 'CLMREPL'; active = 'Y'; output;
run;
data work.ctl_steps;
    length scenario_id $32 step_no 8 active $1 method $16 target_table $32
           where_clause $4000 key_vars $500 source $500 assignments $8000
           options $200 notes $500;
    call missing(of _all_);
    scenario_id = 'CLMREPL'; step_no = 10; active = 'Y';
    method = 'REPLACE_TABLE'; target_table = 'CLAIMS';
    source = 'RUN:BASELINE.OUT_CLAIMS';
    output;
run;

%run_scenario(scenario=CLMREPL, mode=APPLYONLY, html=N)
%assert_status(expect=COMPLETED, id=T09a, desc=feed-forward REPLACE_TABLE completes)
%use_last_run()
%assert_ds_equal(a=GOUT.out_claims, b=TIN.claims, id=T09b,
                 desc=input claims replaced by the baseline run output)
%drop_run_libs()
%assert_base_pristine(id=T09c)

/*==================================================================
  T10  CUSTOM_CODE escape hatch (inlined snippet + contract vars)
==================================================================*/
data _null_;
    file "&TROOT/root/custom/double_prem.sas" lrecl=500;
    put 'data &SQF_SCENLIB..policies;';
    put '    set &SQF_SCENLIB..policies;';
    put '    premium = premium * &PREM_MULT;';
    put 'run;';
run;
%ctl_blank()
data work.ctl_scenarios;
    length scenario_id $32 description $256 parent_scenario $32 active $1 notes $500;
    call missing(of _all_);
    scenario_id = 'CUSTX'; active = 'Y'; output;
run;
data work.ctl_steps;
    length scenario_id $32 step_no 8 active $1 method $16 target_table $32
           where_clause $4000 key_vars $500 source $500 assignments $8000
           options $200 notes $500;
    call missing(of _all_);
    scenario_id = 'CUSTX'; step_no = 10; active = 'Y';
    method = 'COPY_TABLE'; target_table = 'POLICIES';
    output;
    scenario_id = 'CUSTX'; step_no = 20; active = 'Y';
    method = 'CUSTOM_CODE'; target_table = 'POLICIES';
    source = 'double_prem.sas';
    output;
run;
data work.ctl_parameters;
    length name $32 value $2000 scenario_id $32 notes $500;
    call missing(of _all_);
    name = 'PREM_MULT'; value = '2'; scenario_id = 'CUSTX'; output;
run;

%run_scenario(scenario=CUSTX, mode=APPLYONLY, html=N)
%assert_status(expect=COMPLETED, id=T10a, desc=CUSTOM_CODE scenario completes)
%use_last_run()
data work.exp_cu;
    set TGOLD.policies;
    premium = premium * 2;
run;
%assert_ds_equal(a=work.exp_cu, b=TIN.policies, id=T10b, desc=custom snippet doubled premium)
data _null_;
    infile "&TLASTDIR/gen/apply.sas" lrecl=32767 truncover end=_e;
    input;
    retain _in 0;
    if index(_infile_, 'end CUSTOM_CODE') > 0 then _in = 1;
    if _e then call symputx('T10IN', _in);
run;
%assert_true(flag=&T10IN, id=T10c, desc=snippet is inlined into apply.sas)
%drop_run_libs()
%assert_base_pristine(id=T10d)

/*==================================================================
  T11  3-iteration chain with PREV: feed-forward
==================================================================*/
%ctl_blank()
data work.ctl_scenarios;
    length scenario_id $32 description $256 parent_scenario $32 active $1 notes $500;
    call missing(of _all_);
    scenario_id = 'CHAIN3'; active = 'Y'; output;
run;
data work.ctl_steps;
    length scenario_id $32 step_no 8 active $1 method $16 target_table $32
           where_clause $4000 key_vars $500 source $500 assignments $8000
           options $200 notes $500;
    call missing(of _all_);
    scenario_id = 'CHAIN3'; step_no = 10; active = 'Y';
    method = 'COPY_TABLE'; target_table = 'CLAIMS';
    output;
    scenario_id = 'CHAIN3'; step_no = 20; active = 'Y';
    method = 'UPDATE_FROM'; target_table = 'POLICIES';
    key_vars = 'POL_ID';
    source = 'PREV:OUT_BALANCE';
    assignments = 'balance=balance';
    output;
run;

%run_chain(scenario=CHAIN3, iterations=3, mode=FULL, html=N)
%assert_status(expect=COMPLETED, id=T11a, desc=3-iteration chain completes)
%let TCHDIR = &SQF_LAST_RUN_DIR;
libname TC3 "&TCHDIR/iter_03/outputs" access=readonly;
data work.exp_bal;
    set TGOLD.policies(keep=pol_id premium balance);
    balance = round(balance * 1.04 + premium, .01);      /* iter 1 */
    balance = round(balance * 1.04 + premium, .01);      /* iter 2 */
    balance = round(balance * 1.04 + premium, .01);      /* iter 3 */
run;
%assert_ds_equal(a=work.exp_bal, b=TC3.out_balance, id=T11b,
                 desc=chained balance equals 3-step compounding, idvars=pol_id)
libname TC3 clear;
libname TCM "&TCHDIR" access=readonly;
%let TCH = -1;
proc sql noprint;
    select coalesce(sum(status = 'COMPLETED'), -1) into :TCH trimmed
    from TCM.chain_manifest;
quit;
%assert_true(flag=%eval(&TCH = 3), id=T11c, desc=manifest shows 3 completed iterations [got &TCH])
libname TCM clear;
libname TA1 "&TCHDIR/iter_01/audit" access=readonly;
%let TSK = -1;
proc sql noprint;
    /* note: the =: truncation operator is not valid in PROC SQL */
    select coalesce(sum(substr(status, 1, 4) = 'SKIP'), -1) into :TSK trimmed
    from TA1.audit_steps where step = 20;
quit;
%assert_true(flag=%eval(&TSK >= 1), id=T11d, desc=PREV step auto-skipped at iteration 1 [got &TSK])
libname TA1 clear;
%assert_base_pristine(id=T11e)

/*==================================================================
  T12  Idempotent rerun + RUN: resolves to the LATEST run
==================================================================*/
%ctl_blank()
data work.ctl_scenarios;
    length scenario_id $32 description $256 parent_scenario $32 active $1 notes $500;
    call missing(of _all_);
    scenario_id = 'AGEUP'; active = 'Y'; output;
run;
data work.ctl_steps;
    length scenario_id $32 step_no 8 active $1 method $16 target_table $32
           where_clause $4000 key_vars $500 source $500 assignments $8000
           options $200 notes $500;
    call missing(of _all_);
    scenario_id = 'AGEUP'; step_no = 10; active = 'Y';
    method = 'SET_VALUES'; target_table = 'POLICIES';
    where_clause = "region = 'E'";
    assignments  = 'policy_age = policy_age + 1;';
    output;
run;
%run_scenario(scenario=AGEUP, mode=APPLYONLY, html=N)
%let TR12A = &SQF_LAST_RUN_DIR;
%run_scenario(scenario=AGEUP, mode=APPLYONLY, html=N)
%let TR12B = &SQF_LAST_RUN_DIR;
%let TID12B = &SQF_LAST_RUN_ID;
libname T12A "&TR12A/inputs" access=readonly;
libname T12B "&TR12B/inputs" access=readonly;
%assert_ds_equal(a=T12A.policies, b=T12B.policies, id=T12a,
                 desc=rerun produces identical staging - no double apply)
libname T12A clear;
libname T12B clear;
%let TRES = ;
%sqf_resolve_run(root=&TROOT/root, scenario=AGEUP, mvar=TRES)
%assert_true(flag=%eval(%index(&TRES, &TID12B) > 0), id=T12b,
             desc=RUN: resolves to the most recent AGEUP run)
%assert_base_pristine(id=T12c)

/*==================================================================
  T13  Inheritance (parent steps first) + cycle rejection
==================================================================*/
%ctl_blank()
data work.ctl_scenarios;
    length scenario_id $32 description $256 parent_scenario $32 active $1 notes $500;
    call missing(of _all_);
    scenario_id = 'PARENT'; active = 'Y'; output;
    scenario_id = 'CHILD'; parent_scenario = 'PARENT'; active = 'Y'; output;
    scenario_id = 'CYCA'; parent_scenario = 'CYCB'; active = 'Y'; output;
    scenario_id = 'CYCB'; parent_scenario = 'CYCA'; active = 'Y'; output;
run;
data work.ctl_steps;
    length scenario_id $32 step_no 8 active $1 method $16 target_table $32
           where_clause $4000 key_vars $500 source $500 assignments $8000
           options $200 notes $500;
    call missing(of _all_);
    scenario_id = 'PARENT'; step_no = 10; active = 'Y';
    method = 'SET_VALUES'; target_table = 'RATES';
    assignments = 'rate_change = rate_change * 1.10;';
    output;
    scenario_id = 'CHILD'; step_no = 10; active = 'Y';
    method = 'SET_VALUES'; target_table = 'POLICIES';
    assignments = 'policy_age = policy_age + 1;';
    output;
run;

%run_scenario(scenario=CHILD, mode=APPLYONLY, html=N)
%assert_status(expect=COMPLETED, id=T13a, desc=child scenario completes)
%use_last_run()
data work.exp_r13;
    set TGOLD.rates;
    rate_change = rate_change * 1.10;
run;
data work.exp_p13;
    set TGOLD.policies;
    policy_age = policy_age + 1;
run;
%assert_ds_equal(a=work.exp_r13, b=TIN.rates,    id=T13b, desc=parent step applied in child run)
%assert_ds_equal(a=work.exp_p13, b=TIN.policies, id=T13c, desc=child step applied on top)
%drop_run_libs()
%put NOTE: [TEST] ================================================================;
%put NOTE: [TEST] NEGATIVE TESTS BEGIN. Every ERROR from here to the END marker is;
%put NOTE: [TEST] DELIBERATE: the suite feeds bad scenarios and asserts that the;
%put NOTE: [TEST] framework rejects each one loudly. Red lines here = tests PASSING.;
%put NOTE: [TEST] ================================================================;
%run_scenario(scenario=CYCA, mode=APPLYONLY, html=N)
%assert_status(expect=VALIDATION_FAILED, id=T13d, desc=inheritance cycle rejected)
%assert_base_pristine(id=T13e)

/*==================================================================
  T14  Validation negatives (each must refuse to run)
==================================================================*/
%macro t14_run(scen=, id=, desc=);
%run_scenario(scenario=&scen, mode=APPLYONLY, html=N)
%local _p _sc;
%let _p = 0;
%if &SQF_LAST_STATUS = VALIDATION_FAILED %then %let _p = 1;
%use_last_run()
%staged_count(mvar=_sc)
%if &_sc > 0 %then %let _p = 0;
%drop_run_libs()
%t_rec(id=&id, desc=&desc [status=&SQF_LAST_STATUS staged=&_sc], pass=&_p)
%mend t14_run;

%ctl_blank()
data work.ctl_scenarios;
    length scenario_id $32 description $256 parent_scenario $32 active $1 notes $500;
    call missing(of _all_);
    scenario_id = 'BADCOL';  active = 'Y'; output;
    scenario_id = 'BADQUO';  active = 'Y'; output;
    scenario_id = 'BADPAR';  active = 'Y'; output;
    scenario_id = 'BADPCT';  active = 'Y'; output;
    scenario_id = 'BADDUP';  active = 'Y'; output;
    scenario_id = 'BADMETH'; active = 'Y'; output;
    scenario_id = 'BADSCEN'; active = 'Y'; output;
    scenario_id = 'BADWOP';  active = 'Y'; output;
run;
data work.ctl_steps;
    length scenario_id $32 step_no 8 active $1 method $16 target_table $32
           where_clause $4000 key_vars $500 source $500 assignments $8000
           options $200 notes $500;
    call missing(of _all_);
    scenario_id='BADCOL'; step_no=10; active='Y'; method='SET_VALUES';
    target_table='POLICIES'; assignments='nonexistant_col = 99;'; output;

    call missing(of _all_);
    scenario_id='BADQUO'; step_no=10; active='Y'; method='SET_VALUES';
    target_table='POLICIES'; where_clause="region = 'E";
    assignments='policy_age = policy_age + 1;'; output;

    call missing(of _all_);
    scenario_id='BADPAR'; step_no=10; active='Y'; method='SET_VALUES';
    target_table='POLICIES';
    assignments='premium = premium * ' || '26'x || 'NOSUCHPARAM;'; output;

    call missing(of _all_);
    scenario_id='BADPCT'; step_no=10; active='Y'; method='SET_VALUES';
    target_table='POLICIES';
    assignments='premium = ' || '25'x || 'eval(1+1);'; output;

    call missing(of _all_);
    scenario_id='BADDUP'; step_no=10; active='Y'; method='UPDATE_FROM';
    target_table='RATES'; key_vars='REGION RATE_YEAR'; source='BASE:DUPSRC';
    assignments='rate_change=rate_new'; output;

    call missing(of _all_);
    scenario_id='BADMETH'; step_no=10; active='Y'; method='FOOBAR';
    target_table='POLICIES'; output;

    call missing(of _all_);
    scenario_id='BADSCEN'; step_no=10; active='Y'; method='UPDATE_FROM';
    target_table='RATES'; key_vars='REGION RATE_YEAR'; source='SCEN:NEWRATES';
    assignments='rate_change=rate_new'; output;

    call missing(of _all_);
    scenario_id='BADWOP'; step_no=10; active='Y'; method='UPDATE_FROM';
    target_table='RATES'; key_vars='REGION RATE_YEAR'; source='BASE:NEWRATES';
    where_clause='rate_year between 2025 and 2026';
    assignments='rate_change=rate_new'; output;
run;

%t14_run(scen=BADCOL,  id=T14a, desc=undeclared new column rejected)
%t14_run(scen=BADQUO,  id=T14b, desc=unbalanced quote rejected)
%t14_run(scen=BADPAR,  id=T14c, desc=unknown parameter rejected)
%t14_run(scen=BADPCT,  id=T14d, desc=percent trigger in cell rejected)
%t14_run(scen=BADDUP,  id=T14e, desc=duplicate source keys rejected)
%t14_run(scen=BADMETH, id=T14f, desc=unknown method rejected)
%t14_run(scen=BADSCEN, id=T14g, desc=SCEN: without earlier step rejected)
%t14_run(scen=BADWOP,  id=T14h, desc=WHERE-only operator in UPDATE_FROM rejected)
%assert_base_pristine(id=T14i)

/*==================================================================
  T15  Base library is write-protected
==================================================================*/
%let syscc = 0;
data SQFBASE.zzz_should_fail;
    x = 1;
run;
%assert_true(flag=%eval(&syscc > 4), id=T15a, desc=write into base library errors out)
%let syscc = 0;
%assert_true(flag=%eval(not %sysfunc(exist(SQFBASE.zzz_should_fail))), id=T15b,
             desc=no dataset landed in base)
%assert_base_pristine(id=T15c)

/*==================================================================
  T16  Empirical: main program's in-place sort vs read-only base
       (zero-step scenario => claims resolves to base through the
       concatenation; the in-place PROC SORT must NOT touch base)
==================================================================*/
%ctl_blank()
data work.ctl_scenarios;
    length scenario_id $32 description $256 parent_scenario $32 active $1 notes $500;
    call missing(of _all_);
    scenario_id = 'EMPTYSCEN'; active = 'Y'; output;
run;
%run_scenario(scenario=EMPTYSCEN, mode=FULL, html=N)
%put NOTE: [TEST] T16 observed status for zero-step FULL run: &SQF_LAST_STATUS (FAILED expected on most builds - the in-place sort is blocked);
%t_rec(id=T16i, desc=informational: zero-step FULL run status is &SQF_LAST_STATUS, pass=1)
%assert_base_pristine(id=T16a)
%let syscc = 0;

/*==================================================================
  T17  CSV control loader (quoted commas, doubled quotes, BOM)
==================================================================*/
data _null_;
    file "&TROOT/csv/scenarios.csv" lrecl=500;
    put 'EFBBBF'x 'scenario_id,description,parent_scenario,active,notes';
    put '# comment rows (first cell starts with #) must be skipped by the loader,,,,';
    put 'CSVAGE,"ages, in the east and west",,Y,"note with ""quotes"""';
run;
data _null_;
    file "&TROOT/csv/steps.csv" lrecl=1000;
    put 'scenario_id,step_no,active,method,target_table,where_clause,key_vars,source,assignments,options,notes';
    put 'CSVAGE,10,Y,SET_VALUES,POLICIES,"region in (''E'',''W'')",,,"policy_age = policy_age + 1;",,';
run;
data _null_;
    file "&TROOT/csv/parameters.csv" lrecl=500;
    put 'name,value,scenario_id,notes';
run;
%run_scenario(scenario=CSVAGE, control=&TROOT/csv, mode=APPLYONLY, html=N)
%assert_status(expect=COMPLETED, id=T17a, desc=CSV-driven scenario completes)
%use_last_run()
data work.exp_csv;
    set TGOLD.policies;
    if region in ('E','W') then policy_age = policy_age + 1;
run;
%assert_ds_equal(a=work.exp_csv, b=TIN.policies, id=T17b, desc=CSV control produced correct staging)
%drop_run_libs()
%assert_base_pristine(id=T17c)

/*==================================================================
  T18  Runtime failure mid-apply: fail fast, session survives
==================================================================*/
%ctl_blank()
data work.ctl_scenarios;
    length scenario_id $32 description $256 parent_scenario $32 active $1 notes $500;
    call missing(of _all_);
    scenario_id = 'BOOM'; active = 'Y'; output;
run;
data work.ctl_steps;
    length scenario_id $32 step_no 8 active $1 method $16 target_table $32
           where_clause $4000 key_vars $500 source $500 assignments $8000
           options $200 notes $500;
    call missing(of _all_);
    scenario_id = 'BOOM'; step_no = 10; active = 'Y';
    method = 'SET_VALUES'; target_table = 'POLICIES';
    /* compiles clean against obs=0, blows up on real rows */
    assignments = 'array _zz{1} premium; _zz{2} = 0;';
    output;
run;
%run_scenario(scenario=BOOM, mode=APPLYONLY, html=N)
%assert_status(expect=FAILED, id=T18a, desc=runtime error fails the run)
%assert_true(flag=%eval(&SQF_FAIL_STEP = 10), id=T18b, desc=failing step identified [got &SQF_FAIL_STEP])
%assert_true(flag=%sysfunc(fileexist(&SQF_LAST_RUN_DIR/logs/apply.log)), id=T18c,
             desc=apply log kept for post-mortem)
%put NOTE: [TEST] ================================================================;
%put NOTE: [TEST] NEGATIVE TESTS END. Errors above were expected rejections.;
%put NOTE: [TEST] ================================================================;
/* session survives: a good scenario still runs afterwards */
%ctl_blank()
data work.ctl_scenarios;
    length scenario_id $32 description $256 parent_scenario $32 active $1 notes $500;
    call missing(of _all_);
    scenario_id = 'AGEUP'; active = 'Y'; output;
run;
data work.ctl_steps;
    length scenario_id $32 step_no 8 active $1 method $16 target_table $32
           where_clause $4000 key_vars $500 source $500 assignments $8000
           options $200 notes $500;
    call missing(of _all_);
    scenario_id = 'AGEUP'; step_no = 10; active = 'Y';
    method = 'SET_VALUES'; target_table = 'POLICIES';
    where_clause = "region = 'E'";
    assignments  = 'policy_age = policy_age + 1;';
    output;
run;
%run_scenario(scenario=AGEUP, mode=APPLYONLY, html=N)
%assert_status(expect=COMPLETED, id=T18d, desc=next run unaffected - session survived the failure)
%assert_base_pristine(id=T18e)

/*==================================================================
  T19  Template writer + XLSX loader (auto-skips without PC Files)
==================================================================*/
%sqf_make_template(dir=&TROOT/ctl)
%assert_true(flag=%sysfunc(fileexist(&TROOT/ctl/steps.csv)), id=T19a, desc=CSV templates written)
%macro t19_xlsx();
%if %sysfunc(fileexist(&TROOT/ctl/scenario_workbook.xlsx)) %then %do;
    %run_scenario(scenario=RATEUP, control=&TROOT/ctl/scenario_workbook.xlsx,
                  mode=APPLYONLY, html=N)
    %assert_status(expect=COMPLETED, id=T19b, desc=XLSX-driven scenario completes)
    %use_last_run()
    data work.exp_t19;
        set TGOLD.rates;
        rate_change = rate_change * 1.05;
    run;
    %assert_ds_equal(a=work.exp_t19, b=TIN.rates, id=T19c, desc=workbook scenario staged correctly)
    %drop_run_libs()
%end;
%else %do;
    %t_rec(id=T19b, desc=SKIPPED - PC Files engine not available for XLSX, pass=1)
%end;
%mend t19_xlsx;
%t19_xlsx()
%assert_base_pristine(id=T19d)

/*==================================================================
  T20  compare_runs digest (baseline vs rate-up)
==================================================================*/
%compare_runs(run1=&TRUNDIR_T01, run2=&TRUNDIR_T04, out=work.crout, html=N)
%let T20A = 0;
%let T20B = 0;
proc sql noprint;
    select coalesce(sum(table = 'OUT_SUMMARY'    and note like 'DIFFERS%'), 0),
           coalesce(sum(table = 'OUT_POLICY_SUM' and note = 'identical'), 0)
        into :T20A trimmed, :T20B trimmed
    from work.crout;
quit;
%assert_true(flag=&T20A, id=T20a, desc=compare_runs flags out_summary as different)
%assert_true(flag=&T20B, id=T20b, desc=compare_runs sees out_policy_sum unchanged)
%assert_base_pristine(id=T20c)

/*==================================================================
  T21  WORK: ad-hoc source table
==================================================================*/
data work.adhoc_rates;
    length region $1 rate_year 8 rate_new 8;
    region = 'N'; rate_year = 2026; rate_new = 7.7; output;
run;
%ctl_blank()
data work.ctl_scenarios;
    length scenario_id $32 description $256 parent_scenario $32 active $1 notes $500;
    call missing(of _all_);
    scenario_id = 'WORKSRC'; active = 'Y'; output;
run;
data work.ctl_steps;
    length scenario_id $32 step_no 8 active $1 method $16 target_table $32
           where_clause $4000 key_vars $500 source $500 assignments $8000
           options $200 notes $500;
    call missing(of _all_);
    scenario_id = 'WORKSRC'; step_no = 10; active = 'Y';
    method = 'UPDATE_FROM'; target_table = 'RATES';
    key_vars = 'REGION RATE_YEAR';
    source = 'WORK:ADHOC_RATES';
    assignments = 'rate_change=rate_new';
    output;
run;
%run_scenario(scenario=WORKSRC, mode=APPLYONLY, html=N)
%assert_status(expect=COMPLETED, id=T21a, desc=WORK: source scenario completes)
%use_last_run()
data work.exp_w21;
    set TGOLD.rates;
    if region = 'N' and rate_year = 2026 then rate_change = 7.7;
run;
%assert_ds_equal(a=work.exp_w21, b=TIN.rates, id=T21b, desc=ad-hoc WORK table drove the update)
%drop_run_libs()
%assert_base_pristine(id=T21c)

/*==================================================================
  SUMMARY
==================================================================*/
proc sql noprint;
    select count(*), coalesce(sum(pass = 1), 0)
        into :TN trimmed, :TP trimmed
    from work.t_results;
quit;
title "[SQF TEST] results";
proc print data=work.t_results noobs; run;
title;
%macro t_summary();
%if &TP = &TN %then %do;
    %put NOTE: [TEST] ==============================================;
    %put NOTE: [TEST] ALL &TN ASSERTIONS PASSED;
    %put NOTE: [TEST] The framework is safe to use on this SAS setup.;
    %put NOTE: [TEST] ==============================================;
%end;
%else %do;
    %put ERROR: [TEST] %eval(&TN - &TP) OF &TN ASSERTIONS FAILED - see work.t_results above.;
    %let syscc = 8;
%end;
%mend t_summary;
%t_summary()

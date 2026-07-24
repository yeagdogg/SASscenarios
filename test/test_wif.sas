/*=====================================================================================
  WIF SMOKE TEST SUITE
  =====================================================================================
  Fully self-contained: builds tiny tables under WORK (plus a throwaway "permanent"
  base folder under the WORK directory for the INPUT-staging tests), defines rules
  as WORK datasets, exercises every verb and guard, and prints a PASS/FAIL summary.

  TO RUN AT WORK: edit the one %let below, then submit this file.
  Nothing outside the WORK folder is created or modified.

  NOTE: several tests INTEND to fail inside the framework (bad rules, duplicate
  keys, readonly writes). Red ERROR lines between the "NEGATIVE TESTS" banners
  are the tests PASSING. Only the final tally box counts:
      NOTE: [TEST] ALL nn ASSERTIONS PASSED
=====================================================================================*/

%let WIF_HOME = C:/Users/Johns/PyProjects/SASscenarios;   /* <-- EDIT: folder holding wif.sas */

%include "&WIF_HOME/wif.sas";

options nosyntaxcheck obs=max replace;

/*------------------------------------------------------------------
  Sandbox + synthetic data
------------------------------------------------------------------*/
%let TROOT = %sysfunc(pathname(work))/wif_test;
%_wif_mkdir(&TROOT/base)
%_wif_mkdir(&TROOT/goldp)
%_wif_mkdir(&TROOT/main)

libname TPERM "&TROOT/base";
libname TGOLDP "&TROOT/goldp";

/* "permanent" inputs for the staging tests */
data TPERM.rates_perm;
    length region $1 rate_year 8 rate_change 8;
    do rate_year = 2026 to 2027;
        do _i = 1 to 4;
            region = substr('EWNS', _i, 1);
            rate_change = 1 + 0.01 * _i + 0.001 * (rate_year - 2026);
            output;
        end;
    end;
    drop _i;
run;
data TPERM.pol_perm;
    length pol_id 8 premium 8;
    do pol_id = 1 to 20;
        premium = 1000 + pol_id;
        output;
    end;
run;
proc copy in=TPERM out=TGOLDP memtype=data; run;

/* golden WORK tables; tests rebuild their targets from these        */
data work.g_policies;
    length pol_id 8 region $1 policy_age 8 premium 8 sched_mod 8 status $3;
    do pol_id = 1 to 100;
        region = substr('EWNS', mod(pol_id, 4) + 1, 1);
        policy_age = 20 + mod(pol_id, 40);
        premium = 1000 + 10 * mod(pol_id, 25);
        sched_mod = round(0.8 + 0.01 * mod(pol_id, 30), .01);
        status = 'ACT';
        if mod(pol_id, 11) = 0 then status = 'LAP';
        output;
    end;
run;
data work.g_rated;
    length pol_id 8 naics $6 lob $3 state $2 rate 8;
    do pol_id = 1 to 60;
        naics = cats('N', put(100 + mod(pol_id, 3), 3.));
        lob = substr('GLPRWC', 2 * mod(pol_id, 3) + 1, 2);
        state = substr('NYNJCT', 2 * mod(pol_id, 3) + 1, 2);
        rate = 100 + pol_id;
        output;
    end;
run;

/* JOIN sources */
data work.carry;                              /* 50 of 100 pols match  */
    length pol_id 8 new_mod 8;
    do pol_id = 2 to 100 by 2;
        new_mod = round(1 + 0.001 * pol_id, .001);
        output;
    end;
run;
data work.samecol;                            /* same-named col update */
    length pol_id 8 sched_mod 8;
    do pol_id = 1 to 10;
        sched_mod = 9.99;
        output;
    end;
run;
data work.dupadj;                             /* duplicate key         */
    length pol_id 8 new_mod 8;
    pol_id = 2; new_mod = 1.111; output;
    pol_id = 2; new_mod = 2.222; output;
run;
data work.mkt_adj;
    length naics $6 lob $3 state $2 adj_factor 8;
    naics = 'N100'; lob = 'GL'; state = 'NY'; adj_factor = 1.10; output;
    naics = 'N101'; lob = 'PR'; state = 'NJ'; adj_factor = 0.95; output;
run;
data work.badkey;                             /* key type mismatch     */
    length pol_id $8 new_mod 8;
    pol_id = '2'; new_mod = 1.5; output;
run;

/* APPEND / REPLACE sources */
data work.shock;
    length pol_id 8 amt_gross 8 region $1 yr 8;
    do pol_id = 101 to 112;
        amt_gross = 5000 + pol_id;
        region = 'E';
        yr = 2026 + mod(pol_id, 2);
        output;
    end;
run;
data work.newver;                             /* REPLACE donor: extra col */
    length pol_id 8 region $1 policy_age 8 premium 8 sched_mod 8 status $3 extra 8;
    set work.g_policies;
    premium = premium + 7;
    extra = 42;
run;
data work.badver;                             /* missing a target col  */
    set work.g_policies(drop=status);
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

%macro assert_ds_equal(a=, b=, id=, desc=, idvars=);
%local _p _si;
%let _p = 0;
%let _si = -1;
%if %sysfunc(exist(&a)) %then %if %sysfunc(exist(&b)) %then %do;
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
%if %sysfunc(exist(&a)) %then %if %sysfunc(exist(&b)) %then %do;
    proc compare base=&a compare=&b noprint; run;
    %let _si = &sysinfo;
    %if &_si ne 0 %then %let _p = 1;
%end;
%let syscc = 0;
%t_rec(id=&id, desc=&desc, pass=&_p)
%mend assert_ds_differ;

/* fetch the LATEST wif_log row for (hook, seq) of the current gen   */
%global TL_STATUS TL_AFF TL_NB TL_NA;
%macro get_log(hook=, seq=);
%let TL_STATUS = _NONE_;
%let TL_AFF = .;
%let TL_NB = .;
%let TL_NA = .;
%if %sysfunc(exist(work.wif_log)) %then %do;
    proc sql noprint;
        select status, put(rows_affected, best8.-l),
               put(rows_before, best8.-l), put(rows_after, best8.-l)
            into :TL_STATUS trimmed, :TL_AFF trimmed,
                 :TL_NB trimmed, :TL_NA trimmed
            from work.wif_log
            where gen = &WIF_GEN and hook = "%upcase(&hook)" and seq = &seq
            having fire = max(fire);
    quit;
%end;
%mend get_log;

%macro assert_log(hook=, seq=, status=, aff=, id=, desc=);
%local _p;
%get_log(hook=&hook, seq=&seq)
%let _p = 0;
%if &TL_STATUS = &status %then %let _p = 1;
%if &_p = 1 %then %if %length(&aff) > 0 %then %do;
    %if &TL_AFF ne &aff %then %let _p = 0;
%end;
%t_rec(id=&id, desc=&desc [got &TL_STATUS aff=&TL_AFF], pass=&_p)
%mend assert_log;

/* rebuild a mutable copy of a golden table                          */
%macro fresh(t);
data work.&t;
    set work.g_&t;
run;
%mend fresh;

%put NOTE: [TEST] ============ WIF suite starting ============;

/*==================================================================
  T01  inactive hooks are inert
==================================================================*/
%fresh(policies)
%wif(policies)
%wif(policies, at=ANYTHING)
%assert_ds_equal(a=work.policies, b=work.g_policies, id=T01a,
    desc=hook with no scenario is a no-op)
%assert_true(flag=%eval(&WIF_ACTIVE = 0), id=T01b, desc=WIF_ACTIVE still 0)

/*==================================================================
  T02  SET: where + assign, affected counts, zero-match warning path
==================================================================*/
data work.r_t02;
    length scenario $32 hook $32 seq 8 verb $8 where_clause $2000 assign $8000 options $200;
    infile datalines dsd dlm='|' truncover;
    input scenario :$32. hook :$32. seq verb :$8. where_clause :$2000. assign :$8000. options :$200.;
datalines4;
BASETEST|POLICIES|10|SET|region = 'E'|policy_age = policy_age + 1;|
BASETEST|POLICIES|20|SET|region = 'Q'|premium = 0;|NOWARN0
;;;;
run;
%fresh(policies)
%wif_init(scenario=BASETEST, rules=work.r_t02, onfail=CONTINUE)
%assert_true(flag=%eval(&WIF_RC = 0 and &WIF_ACTIVE = 1), id=T02a,
    desc=init clean and active)
%wif(policies)
%assert_log(hook=POLICIES, seq=10, status=OK, aff=25, id=T02b,
    desc=SET affected exactly the 25 region-E rows)
%assert_log(hook=POLICIES, seq=20, status=OK, aff=0, id=T02c,
    desc=0-match SET is OK with aff=0)
data work.chk02;
    merge work.policies(rename=(policy_age=age_new))
          work.g_policies(keep=pol_id region policy_age);
    by pol_id;
    bad = 0;
    if region = 'E' and age_new ne policy_age + 1 then bad = 1;
    if region ne 'E' and age_new ne policy_age then bad = 1;
run;
proc sql noprint;
    select coalesce(sum(bad), 99) into :t02bad trimmed from work.chk02;
quit;
%assert_true(flag=%eval(&t02bad = 0), id=T02d, desc=only region E aged)
%wif_off
%assert_true(flag=%eval(&WIF_ACTIVE = 0), id=T02e, desc=wif_off deactivates)
%fresh(policies)
%wif(policies)
%assert_ds_equal(a=work.policies, b=work.g_policies, id=T02f,
    desc=hooks inert again after wif_off)

/*==================================================================
  T03  JOIN: mapping, derived assign, auto-map, order preserved
==================================================================*/
data work.r_t03;
    length scenario $32 hook $32 seq 8 verb $8 keys $200 source $41
           columns $1000 assign $8000;
    infile datalines dsd dlm='|' truncover;
    input scenario :$32. hook :$32. seq verb :$8. keys :$200. source :$41.
          columns :$1000. assign :$8000.;
datalines4;
JOINTEST|POLICIES|10|JOIN|POL_ID|WORK.CARRY|NEW_MOD=SCHED_MOD|premium = premium * 1.01;
JOINTEST|AUTOJ|10|JOIN|POL_ID|WORK.SAMECOL||
JOINTEST|RATED|10|JOIN|NAICS LOB STATE|WORK.MKT_ADJ|ADJ_FACTOR|rate = rate * adj_factor;
;;;;
run;
%fresh(policies)
%wif_init(scenario=JOINTEST, rules=work.r_t03, onfail=CONTINUE)
%wif(policies)
%assert_log(hook=POLICIES, seq=10, status=OK, aff=50, id=T03a,
    desc=JOIN matched the 50 even pol_ids)
data work.chk03;
    merge work.policies(rename=(sched_mod=mod_new premium=prem_new))
          work.g_policies(keep=pol_id sched_mod premium)
          work.carry(in=_c keep=pol_id new_mod);
    by pol_id;
    bad = 0;
    if _c then do;
        if round(mod_new, .0001) ne round(new_mod, .0001) then bad = 1;
        if round(prem_new, .0001) ne round(premium * 1.01, .0001) then bad = 1;
    end;
    else do;
        if mod_new ne sched_mod or prem_new ne premium then bad = 1;
    end;
run;
proc sql noprint;
    select coalesce(sum(bad), 99) into :t03bad trimmed from work.chk03;
quit;
%assert_true(flag=%eval(&t03bad = 0), id=T03b,
    desc=matched rows updated + computed and unmatched untouched)
/* order preserved: pol_id sequence identical without sorting        */
data work.ord_a;
    set work.policies(keep=pol_id);
run;
data work.ord_b;
    set work.g_policies(keep=pol_id);
run;
%assert_ds_equal(a=work.ord_a, b=work.ord_b, id=T03c, desc=JOIN preserves row order)
/* auto-map: blank columns updates the same-named column             */
%fresh(policies)
%wif(policies, at=AUTOJ)
%assert_log(hook=AUTOJ, seq=10, status=OK, aff=10, id=T03d,
    desc=auto-mapped JOIN updated 10 rows)
proc sql noprint;
    select count(*) into :t03e trimmed
    from work.policies where pol_id <= 10 and sched_mod ne 9.99;
quit;
%assert_true(flag=%eval(&t03e = 0), id=T03e, desc=same-named column pulled)
/* mapped-NEW column: unmatched rows must be MISSING, never carry a
   stale value from the previous matched row (hash host vars retain) */
data work.rated;
    set work.g_rated;
run;
%wif(rated)
%assert_log(hook=RATED, seq=10, status=OK, aff=40, id=T03f,
    desc=JOIN matched the 40 rows with adjustment segments)
data work.chk03f;
    set work.rated;
    _m3 = mod(pol_id, 3);
    bad = 0;
    if _m3 = 0 then do;
        if round(rate, .0001) ne round((100 + pol_id) * 1.10, .0001) then bad = 1;
        if adj_factor ne 1.10 then bad = 1;
    end;
    else if _m3 = 1 then do;
        if round(rate, .0001) ne round((100 + pol_id) * 0.95, .0001) then bad = 1;
        if adj_factor ne 0.95 then bad = 1;
    end;
    else do;
        if rate ne 100 + pol_id then bad = 1;
        if not missing(adj_factor) then bad = 1;
    end;
run;
proc sql noprint;
    select coalesce(sum(bad), 99) into :t03g trimmed from work.chk03f;
quit;
%assert_true(flag=%eval(&t03g = 0), id=T03g,
    desc=new mapped column computed on matched rows and MISSING on unmatched)
%wif_off

%put NOTE: [TEST] ======================================================;
%put NOTE: [TEST] == NEGATIVE TESTS BEGIN: red ERROR lines below are  ==;
%put NOTE: [TEST] == EXPECTED - they are the framework REJECTING bad  ==;
%put NOTE: [TEST] == rules on purpose. Only the final tally counts.   ==;
%put NOTE: [TEST] ======================================================;

/*==================================================================
  T04  JOIN failure modes: duplicate source keys roll back; key
       type mismatch refused before touching anything
==================================================================*/
data work.r_t04;
    length scenario $32 hook $32 seq 8 verb $8 keys $200 source $41 columns $1000;
    infile datalines dsd dlm='|' truncover;
    input scenario :$32. hook :$32. seq verb :$8. keys :$200. source :$41. columns :$1000.;
datalines4;
DUPTEST|POLICIES|10|JOIN|POL_ID|WORK.DUPADJ|NEW_MOD=SCHED_MOD
DUPTEST|BADK|10|JOIN|POL_ID|WORK.BADKEY|NEW_MOD=SCHED_MOD
;;;;
run;
%fresh(policies)
%wif_init(scenario=DUPTEST, rules=work.r_t04, onfail=CONTINUE)
%wif(policies)
%assert_log(hook=POLICIES, seq=10, status=FAILED, id=T04a,
    desc=duplicate source keys abort the JOIN)
%assert_ds_equal(a=work.policies, b=work.g_policies, id=T04b,
    desc=failed JOIN left the target byte-identical)
%assert_true(flag=%eval(&syscc <= 4), id=T04c,
    desc=onfail=CONTINUE reset the session state)
%wif(policies, at=BADK)
%assert_log(hook=BADK, seq=10, status=FAILED, id=T04d,
    desc=key type mismatch refused at prep)
%assert_ds_equal(a=work.policies, b=work.g_policies, id=T04e,
    desc=type-mismatch JOIN never touched the target)
%wif_off

/*==================================================================
  T05  lint rejections: WHERE-only operators in SET, unknown param,
       unbalanced quote, statement tokens, unknown verb/option
==================================================================*/
data work.r_t05;
    length scenario $32 hook $32 seq 8 verb $8 where_clause $2000 assign $8000 options $200;
    infile datalines dsd dlm='|' truncover;
    input scenario :$32. hook :$32. seq verb :$8. where_clause :$2000. assign :$8000. options :$200.;
datalines4;
LINTBAD|T1|10|JOIN|region <> 'E'|premium = 0;|
LINTBAD|T2|10|SET||premium = 0;|NOMATCH=FAIL
LINTBAD|T3|10|SET||premium = &NOSUCHPARAM;|
LINTBAD|T5|10|SET||run; delete;|
LINTBAD|T6|10|FROB||x = 1;|
LINTBAD|T7|10|SET||premium = 0;|BOGUSOPT
;;;;
run;
/* the unbalanced-quote plant is built with byte(39) so THIS file
   stays balanced for the dev-side linter while the CELL is broken  */
data work.r_t05x;
    length scenario $32 hook $32 seq 8 verb $8 where_clause $2000 assign $8000 options $200;
    scenario = 'LINTBAD'; hook = 'T4'; seq = 10; verb = 'SET';
    where_clause = ' ';
    assign = 'premium = ' || byte(39) || 'oops;';
    options = ' ';
run;
proc append base=work.r_t05 data=work.r_t05x force; run;
%wif_init(scenario=LINTBAD, rules=work.r_t05, onfail=CONTINUE)
%assert_true(flag=%eval(&WIF_RC = 1 and &WIF_ACTIVE = 0), id=T05a,
    desc=lint refused to activate the bad ruleset)
%assert_true(flag=%eval(&WIF_LINTE >= 7), id=T05b,
    desc=all seven plants found [got &WIF_LINTE])
%let syscc = 0;

/*==================================================================
  T06  SET preflight: typo'd new column refused pre-touch; NEWCOLS
       allows it; typo'd where column also caught
==================================================================*/
data work.r_t06;
    length scenario $32 hook $32 seq 8 verb $8 where_clause $2000 assign $8000 options $200;
    infile datalines dsd dlm='|' truncover;
    input scenario :$32. hook :$32. seq verb :$8. where_clause :$2000. assign :$8000. options :$200.;
datalines4;
PFTEST|POLICIES|10|SET||policy_agee = policy_age + 1;|
PFTEST|OKNEW|10|SET||bonus_flag = 1;|NEWCOLS
PFTEST|BADWHERE|10|SET|regoin = 'E'|premium = 0;|
;;;;
run;
%fresh(policies)
%wif_init(scenario=PFTEST, rules=work.r_t06, onfail=CONTINUE)
%wif(policies)
%assert_log(hook=POLICIES, seq=10, status=FAILED, id=T06a,
    desc=typo new column caught by preflight)
%assert_ds_equal(a=work.policies, b=work.g_policies, id=T06b,
    desc=preflight failure left the table untouched)
%wif(policies, at=OKNEW)
%assert_log(hook=OKNEW, seq=10, status=OK, id=T06c,
    desc=NEWCOLS permits an intentional new column)
proc sql noprint;
    select count(*) into :t06d trimmed
    from dictionary.columns
    where libname = 'WORK' and memname = 'POLICIES' and upcase(name) = 'BONUS_FLAG';
quit;
%assert_true(flag=%eval(&t06d = 1), id=T06d, desc=new column exists after NEWCOLS)
%fresh(policies)
%wif(policies, at=BADWHERE)
%assert_log(hook=BADWHERE, seq=10, status=FAILED, id=T06e,
    desc=typo in the where column caught by preflight)
%assert_ds_equal(a=work.policies, b=work.g_policies, id=T06f,
    desc=bad-where preflight left the table untouched)
%wif_off

%put NOTE: [TEST] ======================================================;
%put NOTE: [TEST] == NEGATIVE TESTS END (more further down)           ==;
%put NOTE: [TEST] ======================================================;

/*==================================================================
  T07  FILTER keep + DROP; APPEND with mapping + source where;
       REPLACE trims / KEEPEXTRA / missing-column refusal
==================================================================*/
data work.r_t07;
    length scenario $32 hook $32 seq 8 verb $8 target $41 where_clause $2000
           source $41 columns $1000 options $200;
    infile datalines dsd dlm='|' truncover;
    input scenario :$32. hook :$32. seq verb :$8. target :$41. where_clause :$2000.
          source :$41. columns :$1000. options :$200.;
datalines4;
VERBS|POLICIES|10|FILTER||status ne 'LAP'|||
VERBS|DROPF|10|FILTER||status = 'LAP'|||DROP
VERBS|APPX|10|APPEND||yr = 2027|WORK.SHOCK|AMT_GROSS=PREMIUM|
VERBS|REPL|10|REPLACE|||WORK.NEWVER||
VERBS|REPLX|10|REPLACE|||WORK.NEWVER||KEEPEXTRA
VERBS|REPLBAD|10|REPLACE|||WORK.BADVER||
;;;;
run;
%fresh(policies)
%wif_init(scenario=VERBS, rules=work.r_t07, onfail=CONTINUE)
%wif(policies)
%assert_log(hook=POLICIES, seq=10, status=OK, aff=9, id=T07a,
    desc=FILTER removed the 9 lapsed rows)
%fresh(policies)
%wif(policies, at=DROPF)
%assert_log(hook=DROPF, seq=10, status=OK, aff=9, id=T07b,
    desc=FILTER DROP removed the same 9 rows)
proc sql noprint;
    select count(*) into :t07c trimmed from work.policies where status = 'LAP';
quit;
%assert_true(flag=%eval(&t07c = 0), id=T07c, desc=lapsed rows gone)

%fresh(policies)
%wif(policies, at=APPX)
%assert_log(hook=APPX, seq=10, status=OK, aff=6, id=T07d,
    desc=APPEND added the 6 yr-2027 shock rows)
proc sql noprint;
    select count(*) into :t07e trimmed
    from work.policies where pol_id > 100 and premium > 5000;
quit;
%assert_true(flag=%eval(&t07e = 6), id=T07e,
    desc=appended rows carry amt_gross into premium)

%fresh(policies)
%wif(policies, at=REPL)
%assert_log(hook=REPL, seq=10, status=OK, id=T07f, desc=REPLACE swapped the table)
proc sql noprint;
    select count(*) into :t07g trimmed
    from dictionary.columns
    where libname = 'WORK' and memname = 'POLICIES' and upcase(name) = 'EXTRA';
quit;
%assert_true(flag=%eval(&t07g = 0), id=T07g, desc=REPLACE trimmed the extra column)
%fresh(policies)
%wif(policies, at=REPLX)
proc sql noprint;
    select count(*) into :t07h trimmed
    from dictionary.columns
    where libname = 'WORK' and memname = 'POLICIES' and upcase(name) = 'EXTRA';
quit;
%assert_true(flag=%eval(&t07h = 1), id=T07h, desc=KEEPEXTRA kept the extra column)
%fresh(policies)
%wif(policies, at=REPLBAD)
%assert_log(hook=REPLBAD, seq=10, status=FAILED, id=T07i,
    desc=REPLACE refused a source missing a target column)
%assert_ds_equal(a=work.policies, b=work.g_policies, id=T07j,
    desc=refused REPLACE left the table untouched)
%wif_off

/*==================================================================
  T08  CODE verb: verbatim step, WIF_TABLE contract
==================================================================*/
data work.r_t08;
    length scenario $32 hook $32 seq 8 verb $8 assign $8000;
    infile datalines dsd dlm='|' truncover;
    input scenario :$32. hook :$32. seq verb :$8. assign :$8000.;
datalines4;
CODET|POLICIES|10|CODE|proc sort data=&WIF_TABLE.; by descending pol_id; run;
;;;;
run;
%fresh(policies)
%wif_init(scenario=CODET, rules=work.r_t08, onfail=CONTINUE)
%wif(policies)
%assert_log(hook=POLICIES, seq=10, status=OK, id=T08a, desc=CODE rule ran)
proc sql noprint;
    select pol_id into :t08b trimmed
    from work.policies(obs=1);
quit;
%assert_true(flag=%eval(&t08b = 100), id=T08b,
    desc=CODE saw the hooked table through WIF_TABLE)
%wif_off

/*==================================================================
  T09  custom at= names, blank target = hooked table across a loop,
       ONCE fires exactly once
==================================================================*/
data work.r_t09;
    length scenario $32 hook $32 seq 8 verb $8 assign $8000 options $200;
    infile datalines dsd dlm='|' truncover;
    input scenario :$32. hook :$32. seq verb :$8. assign :$8000. options :$200.;
datalines4;
LOOPT|SEGLOOP|10|SET|premium = premium * 2;|
LOOPT|POLICIES|10|SET|policy_age = policy_age + 1;|ONCE
;;;;
run;
data work.seg_1; length seg 8 premium 8; seg = 1; premium = 10; run;
data work.seg_2; length seg 8 premium 8; seg = 2; premium = 20; run;
data work.seg_3; length seg 8 premium 8; seg = 3; premium = 30; run;
%fresh(policies)
%wif_init(scenario=LOOPT, rules=work.r_t09, onfail=CONTINUE)
%macro t09_loop();
%local _s;
%do _s = 1 %to 3;
    %wif(seg_&_s, at=SEGLOOP)
%end;
%mend t09_loop;
%t09_loop()
proc sql noprint;
    select sum(premium) into :t09a trimmed
    from (select premium from work.seg_1
          union all select premium from work.seg_2
          union all select premium from work.seg_3);
quit;
%assert_true(flag=%eval(&t09a = 120), id=T09a,
    desc=one rule serviced 3 loop tables via at= and blank target)
%wif(policies)
%wif(policies)
%get_log(hook=POLICIES, seq=10)
%assert_true(flag=%eval("&TL_STATUS" = "SKIP_ONCE"), id=T09b,
    desc=second firing skipped by ONCE)
proc sql noprint;
    select count(*) into :t09c trimmed
    from work.policies p, work.g_policies g
    where p.pol_id = g.pol_id and p.policy_age ne g.policy_age + 1;
quit;
%assert_true(flag=%eval(&t09c = 0), id=T09c, desc=ONCE rule applied exactly once)
%wif_off

/*==================================================================
  T10  missing table + view target statuses
==================================================================*/
data work.r_t10;
    length scenario $32 hook $32 seq 8 verb $8 assign $8000;
    infile datalines dsd dlm='|' truncover;
    input scenario :$32. hook :$32. seq verb :$8. assign :$8000.;
datalines4;
MISST|NO_SUCH_TABLE|10|SET|x = 1;|
MISST|POLVIEW|10|SET|premium = 0;|
;;;;
run;
proc sql;
    create view work.polview as select * from work.g_policies;
quit;
%wif_init(scenario=MISST, rules=work.r_t10, onfail=CONTINUE)
%put NOTE: [TEST] == negative block: the next two hook calls are MEANT to fail ==;
%wif(no_such_table)
%get_log(hook=NO_SUCH_TABLE, seq=10)
%assert_true(flag=%eval("&TL_STATUS" = "NO_TABLE"), id=T10a,
    desc=missing table logged NO_TABLE)
%wif(polview)
%get_log(hook=POLVIEW, seq=10)
%assert_true(flag=%eval("&TL_STATUS" = "FAILED"), id=T10b,
    desc=view target refused with remediation)
%wif_off
%let syscc = 0;

/*==================================================================
  T11  sortedby flag + dataset label survive an in-place SET
==================================================================*/
data work.r_t11;
    length scenario $32 hook $32 seq 8 verb $8 assign $8000;
    infile datalines dsd dlm='|' truncover;
    input scenario :$32. hook :$32. seq verb :$8. assign :$8000.;
datalines4;
SRTT|SRTPOL|10|SET|premium = premium + 1;|
;;;;
run;
proc sort data=work.g_policies out=work.srtpol(label='WIF sort test');
    by region pol_id;
run;
%wif_init(scenario=SRTT, rules=work.r_t11, onfail=CONTINUE)
%wif(srtpol)
%macro t11_check();
%local _id _sby _lbl _rc;
%let _id = %sysfunc(open(work.srtpol));
%let _sby = ;
%let _lbl = ;
%if &_id > 0 %then %do;
    %let _sby = %sysfunc(attrc(&_id, SORTEDBY));
    %let _lbl = %sysfunc(attrc(&_id, LABEL));
    %let _rc = %sysfunc(close(&_id));
%end;
%assert_true(flag=%eval(%length(&_sby) > 0), id=T11a,
    desc=sortedby flag re-asserted [&_sby])
%assert_true(flag=%eval("&_lbl" = "WIF sort test"), id=T11b,
    desc=dataset label re-asserted)
%mend t11_check;
%t11_check()
%wif_off

/*==================================================================
  T12  INPUT staging: modified read-through, base pristine, write
       fall-through blocked, restore on wif_off
==================================================================*/
data work.r_t12;
    length scenario $32 hook $32 seq 8 verb $8 target $41 where_clause $2000 assign $8000;
    infile datalines dsd dlm='|' truncover;
    input scenario :$32. hook :$32. seq verb :$8. target :$41. where_clause :$2000. assign :$8000.;
datalines4;
STAGET|INPUT|10|SET|TRAW.RATES_PERM|rate_year = 2027|rate_change = rate_change * 1.10;
;;;;
run;
libname TRAW "&TROOT/base";
%wif_init(scenario=STAGET, rules=work.r_t12, onfail=CONTINUE)
%assert_true(flag=%eval(&WIF_RC = 0 and &WIF_ACTIVE = 1), id=T12a,
    desc=staging init clean)
%assert_log(hook=INPUT, seq=10, status=OK, aff=4, id=T12b,
    desc=INPUT rule modified the 4 2027 rows in the staged copy)
data work.chk12;
    set TRAW.rates_perm;
run;
data work.chk12g;
    set TGOLDP.rates_perm;
    if rate_year = 2027 then rate_change = rate_change * 1.10;
run;
%assert_ds_equal(a=work.chk12, b=work.chk12g, id=T12c,
    desc=program reads the modified copy through the original libref)
data work.chk12u;
    set TRAW.pol_perm;
run;
%assert_ds_equal(a=work.chk12u, b=TGOLDP.pol_perm, id=T12d,
    desc=unstaged input falls through to base unchanged)
%put NOTE: [TEST] == negative block: the next PROC APPEND is MEANT to fail (readonly base) ==;
data work.addrow;
    length pol_id 8 premium 8;
    pol_id = 999; premium = 1;
run;
proc append base=TRAW.pol_perm data=work.addrow; run;
%macro t12_wcheck();
%assert_true(flag=%eval(&syscc > 4), id=T12e,
    desc=write to an unstaged base table blocked by the readonly nest)
%let syscc = 0;
options obs=max replace nosyntaxcheck;
%mend t12_wcheck;
%t12_wcheck()
%assert_ds_equal(a=TPERM.pol_perm, b=TGOLDP.pol_perm, id=T12f,
    desc=base pol_perm physically pristine)
%assert_ds_equal(a=TPERM.rates_perm, b=TGOLDP.rates_perm, id=T12g,
    desc=base rates_perm physically pristine)
%wif_off
data work.chk12r;
    set TRAW.rates_perm;
run;
%assert_ds_equal(a=work.chk12r, b=TGOLDP.rates_perm, id=T12h,
    desc=wif_off restored the libref to the pristine base)

/*==================================================================
  T13  re-init without wif_off (crash recovery) + repeated init
==================================================================*/
%wif_init(scenario=STAGET, rules=work.r_t12, onfail=CONTINUE)
/* no wif_off - init again straight away                             */
%wif_init(scenario=STAGET, rules=work.r_t12, onfail=CONTINUE)
%assert_true(flag=%eval(&WIF_RC = 0 and &WIF_ACTIVE = 1), id=T13a,
    desc=re-init without wif_off recovers cleanly)
data work.chk13;
    set TRAW.rates_perm;
run;
%assert_ds_equal(a=work.chk13, b=work.chk12g, id=T13b,
    desc=staged read-through correct after recovery re-init)
%wif_off
data work.chk13r;
    set TRAW.rates_perm;
run;
%assert_ds_equal(a=work.chk13r, b=TGOLDP.rates_perm, id=T13c,
    desc=libref restored after recovery cycle)

/*==================================================================
  T14  two-iteration CLV-style loop: ITERS=2+ gating + carry-forward
==================================================================*/
data work.r_t14;
    length scenario $32 hook $32 seq 8 verb $8 keys $200 source $41
           columns $1000 assign $8000 options $200;
    infile datalines dsd dlm='|' truncover;
    input scenario :$32. hook :$32. seq verb :$8. keys :$200. source :$41.
          columns :$1000. assign :$8000. options :$200.;
datalines4;
CLV|TERM|10|SET||||age = age + 1;|
CLV|TERM|20|JOIN|POL_ID|WORK.CLVCARRY|PRIOR_MOD=EXPIRING_MOD||ITERS=2+
;;;;
run;
data work.g_term;
    length pol_id 8 age 8 mod 8 expiring_mod 8;
    do pol_id = 1 to 20;
        age = 30 + mod(pol_id, 10);
        mod = 1.00;
        expiring_mod = .;
        output;
    end;
run;
%macro t14_driver();
%local _y;
%do _y = 1 %to 2;
    data work.term;
        set work.g_term;
    run;
    %wif_init(scenario=CLV, rules=work.r_t14, iter=&_y, onfail=CONTINUE)
    %wif(term)
    /* the "program": reprice the mod, then build the carry-forward  */
    data work.term;
        set work.term;
        mod = round(mod * 0.95 + 0.001 * age, .0001);
    run;
    proc sql;
        create table work.clvcarry as
        select pol_id, mod as prior_mod from work.term;
    quit;
    %wif_save(table=term, as=clv_y&_y, lib=work)
    %wif_off
%end;
%mend t14_driver;
%t14_driver()
%get_log(hook=TERM, seq=20)
proc sql noprint;
    select count(*) into :t14a trimmed
    from work.wif_log
    where hook = 'TERM' and seq = 20 and status = 'SKIP_ITER' and iter = 1;
quit;
%assert_true(flag=%eval(&t14a = 1), id=T14a,
    desc=carry-forward JOIN skipped at iteration 1)
%assert_true(flag=%eval("&TL_STATUS" = "OK"), id=T14b,
    desc=carry-forward JOIN applied at iteration 2)
data work.chk14;
    merge work.clv_y2(rename=(expiring_mod=em2))
          work.clv_y1(keep=pol_id mod rename=(mod=mod1));
    by pol_id;
    bad = (round(em2, .0001) ne round(mod1, .0001));
run;
proc sql noprint;
    select coalesce(sum(bad), 99) into :t14c trimmed from work.chk14;
quit;
%assert_true(flag=%eval(&t14c = 0), id=T14c,
    desc=year 2 expiring mod equals year 1 priced mod)

/*==================================================================
  T15  wif_run: two scenarios via LET + a global rule, outputs saved
==================================================================*/
data work.r_t15;
    length scenario $32 hook $32 seq 8 verb $8 target $41 assign $8000;
    infile datalines dsd dlm='|' truncover;
    input scenario :$32. hook :$32. seq verb :$8. target :$41. assign :$8000.;
datalines4;
|RUNIN|10|SET||premium = premium * &FCT;
UP|||LET|FCT|1.10
DOWN|||LET|FCT|0.90
;;;;
run;
data work.g_runin;
    length pol_id 8 premium 8;
    do pol_id = 1 to 10;
        premium = 100;
        output;
    end;
run;
data _null_;
    file "&TROOT/main/wif_dummy_main.sas" lrecl=500;
    put 'data work.runin; set work.g_runin; run;';
    put '%wif(runin)';
    put 'data work.runout; set work.runin; out_prem = premium; run;';
run;
%wif_run(scenario=UP, main=&TROOT/main/wif_dummy_main.sas,
         rules=work.r_t15, keep=runout, onfail=CONTINUE)
%wif_run(scenario=DOWN, main=&TROOT/main/wif_dummy_main.sas,
         keep=runout, onfail=CONTINUE)
proc sql noprint;
    select coalesce(sum(out_prem), 0) into :t15a trimmed from work.up_runout;
    select coalesce(sum(out_prem), 0) into :t15b trimmed from work.down_runout;
quit;
%assert_true(flag=%eval(&t15a = 1100), id=T15a,
    desc=UP scenario saved with the 1.10 LET factor)
%assert_true(flag=%eval(&t15b = 900), id=T15b,
    desc=DOWN scenario reused rules= from memory with 0.90)
%assert_true(flag=%eval(&WIF_ACTIVE = 0), id=T15c, desc=wif_run left WIF off)

/*==================================================================
  T16  wif_rule sugar + params= + reserved-name rejection + minimal
       programmatic rules table
==================================================================*/
proc datasets lib=work nolist nowarn; delete wif_rules; quit;
%wif_rule(scenario=SUGAR, hook=POLICIES, seq=10, verb=SET,
          assign=%nrstr(premium = premium * &BUMP;))
%fresh(policies)
%wif_init(scenario=SUGAR, rules=work.wif_rules, params=BUMP=2, onfail=CONTINUE)
%wif(policies)
proc sql noprint;
    select count(*) into :t16a trimmed
    from work.policies p, work.g_policies g
    where p.pol_id = g.pol_id and p.premium ne g.premium * 2;
quit;
%assert_true(flag=%eval(&t16a = 0), id=T16a,
    desc=wif_rule sugar + params= applied)
%wif_off
%put NOTE: [TEST] == negative block: reserved parameter name below is MEANT to error ==;
%wif_init(scenario=SUGAR, rules=work.wif_rules, params=WIF_EVIL=1, onfail=CONTINUE)
%assert_true(flag=%eval(&WIF_RC = 1), id=T16b,
    desc=reserved WIF-prefixed parameter rejected)
%let syscc = 0;
/* minimal 3-column programmatic table, no scenario column at all    */
data work.minrules;
    length hook $32 verb $8 assign $8000;
    hook = 'MINI'; verb = 'SET'; assign = 'x = x * 2;';
run;
data work.mini;
    x = 21;
run;
%wif_init(scenario=ANYNAME, rules=work.minrules, onfail=CONTINUE)
%wif(mini)
proc sql noprint;
    select x into :t16c trimmed from work.mini;
quit;
%assert_true(flag=%eval(&t16c = 42), id=T16c,
    desc=minimal blank-scenario rules table works programmatically)
%wif_off

/*==================================================================
  T17  options survive a failure under CONTINUE: later steps still
       run with real data (no OBS=0 poisoning)
==================================================================*/
data work.r_t17;
    length scenario $32 hook $32 seq 8 verb $8 keys $200 source $41 columns $1000;
    infile datalines dsd dlm='|' truncover;
    input scenario :$32. hook :$32. seq verb :$8. keys :$200. source :$41. columns :$1000.;
datalines4;
OPTT|POLICIES|10|JOIN|POL_ID|WORK.NO_SUCH_SOURCE|X=Y
;;;;
run;
%fresh(policies)
%wif_init(scenario=OPTT, rules=work.r_t17, onfail=CONTINUE)
%put NOTE: [TEST] == negative block: missing JOIN source below is MEANT to fail ==;
%wif(policies)
%assert_log(hook=POLICIES, seq=10, status=FAILED, id=T17a,
    desc=missing source failed cleanly)
data work.t17probe;
    do i = 1 to 50;
        output;
    end;
run;
proc sql noprint;
    select count(*) into :t17b trimmed from work.t17probe;
quit;
%assert_true(flag=%eval(&t17b = 50), id=T17b,
    desc=session still processes full data after the failure)
%wif_off
%let syscc = 0;

/*==================================================================
  T18  wif_log schema + wif_report run clean
==================================================================*/
proc sql noprint;
    select count(*) into :t18a trimmed
    from dictionary.columns
    where libname = 'WORK' and memname = 'WIF_LOG'
      and upcase(name) in ('GEN','SCENARIO','ITER','FIRE','HOOK','SEQ','VERB',
                           'TARGET','STATUS','ROWS_BEFORE','ROWS_AFTER',
                           'ROWS_AFFECTED','MESSAGE','LOGGED_AT');
quit;
%assert_true(flag=%eval(&t18a = 14), id=T18a, desc=wif_log schema complete)
%wif_report
%macro t18b_check();
%assert_true(flag=%eval(&syscc <= 4), id=T18b, desc=wif_report ran clean)
%mend t18b_check;
%t18b_check()

/*==================================================================
  T19  SET full-WHERE split: LIKE / BETWEEN / <> handled with real
       WHERE semantics, order preserved
==================================================================*/
data work.r_t19;
    length scenario $32 hook $32 seq 8 verb $8 where_clause $2000 assign $8000;
    infile datalines dsd dlm='|' truncover;
    input scenario :$32. hook :$32. seq verb :$8. where_clause :$2000. assign :$8000.;
datalines4;
SPLITT|POLICIES|10|SET|policy_age between 25 and 30|premium = premium + 1000;
SPLITT|NEQ|10|SET|region <> 'E'|sched_mod = 9;
;;;;
run;
%fresh(policies)
%wif_init(scenario=SPLITT, rules=work.r_t19, onfail=CONTINUE)
proc sql noprint;
    select count(*) into :t19x trimmed
    from work.g_policies where 25 le policy_age le 30;
quit;
%wif(policies)
%assert_log(hook=POLICIES, seq=10, status=OK, aff=&t19x, id=T19a,
    desc=BETWEEN clause applied via the where-split path)
data work.chk19;
    merge work.policies(rename=(premium=prem_new))
          work.g_policies(keep=pol_id policy_age premium);
    by pol_id;
    bad = 0;
    if 25 le policy_age le 30 then do;
        if prem_new ne premium + 1000 then bad = 1;
    end;
    else if prem_new ne premium then bad = 1;
run;
proc sql noprint;
    select coalesce(sum(bad), 99) into :t19b trimmed from work.chk19;
quit;
%assert_true(flag=%eval(&t19b = 0), id=T19b, desc=only the BETWEEN rows changed)
data work.ord19a;
    set work.policies(keep=pol_id);
run;
data work.ord19b;
    set work.g_policies(keep=pol_id);
run;
%assert_ds_equal(a=work.ord19a, b=work.ord19b, id=T19c,
    desc=where-split preserves row order)
%fresh(policies)
%wif(policies, at=NEQ)
%assert_log(hook=NEQ, seq=10, status=OK, aff=75, id=T19d,
    desc=NE-angle operator means NOT-EQUAL under real WHERE semantics)
%wif_off

/*==================================================================
  T20  JOIN preflight: typos caught BEFORE a rewrite
==================================================================*/
data work.r_t20;
    length scenario $32 hook $32 seq 8 verb $8 keys $200 source $41
           columns $1000 assign $8000;
    infile datalines dsd dlm='|' truncover;
    input scenario :$32. hook :$32. seq verb :$8. keys :$200. source :$41.
          columns :$1000. assign :$8000.;
datalines4;
JPF|POLICIES|10|JOIN|POL_ID|WORK.CARRY|NEW_MOD=SCHED_MOD|premiun = premium * 2;
;;;;
run;
%fresh(policies)
%wif_init(scenario=JPF, rules=work.r_t20, onfail=CONTINUE)
%put NOTE: [TEST] == negative block: the next JOIN is MEANT to fail its preflight ==;
%wif(policies)
%assert_log(hook=POLICIES, seq=10, status=FAILED, id=T20a,
    desc=typo in the JOIN assign caught by the obs=0 preflight)
%assert_ds_equal(a=work.policies, b=work.g_policies, id=T20b,
    desc=preflighted JOIN never touched the target)
%wif_off
%let syscc = 0;

/*==================================================================
  T21  ASSERT: hooks as QA gates
==================================================================*/
data work.r_t21;
    length scenario $32 hook $32 seq 8 verb $8 where_clause $2000;
    infile datalines dsd dlm='|' truncover;
    input scenario :$32. hook :$32. seq verb :$8. where_clause :$2000.;
datalines4;
QAT|POLICIES|10|ASSERT|premium > 0
QAT|BADQA|10|ASSERT|sched_mod < 1
;;;;
run;
%fresh(policies)
%wif_init(scenario=QAT, rules=work.r_t21, onfail=CONTINUE)
%wif(policies)
%assert_log(hook=POLICIES, seq=10, status=OK, aff=0, id=T21a,
    desc=passing assertion logs OK with 0 violations)
proc sql noprint;
    select count(*) into :t21x trimmed
    from work.g_policies where not (sched_mod < 1);
quit;
%put NOTE: [TEST] == negative block: the next ASSERT is MEANT to fail ==;
%wif(policies, at=BADQA)
%assert_log(hook=BADQA, seq=10, status=FAILED, aff=&t21x, id=T21b,
    desc=failing assertion counts its violations)
%_wif_nobs(ds=work.wif_viol, mvar=t21v)
%assert_true(flag=%eval(&t21v = %sysfunc(min(&t21x, 200))), id=T21c,
    desc=violation sample kept in work.wif_viol)
%assert_ds_equal(a=work.policies, b=work.g_policies, id=T21d,
    desc=ASSERT never modifies the table)
%wif_off
%let syscc = 0;

/*==================================================================
  T22  JOIN NOMATCH= policies
==================================================================*/
data work.r_t22;
    length scenario $32 hook $32 seq 8 verb $8 keys $200 source $41
           columns $1000 options $200;
    infile datalines dsd dlm='|' truncover;
    input scenario :$32. hook :$32. seq verb :$8. keys :$200. source :$41.
          columns :$1000. options :$200.;
datalines4;
NMT|POLICIES|10|JOIN|POL_ID|WORK.CARRY|NEW_MOD=SCHED_MOD|NOMATCH=DELETE
NMT|FAILJ|10|JOIN|POL_ID|WORK.CARRY|NEW_MOD=SCHED_MOD|NOMATCH=FAIL
;;;;
run;
%fresh(policies)
%wif_init(scenario=NMT, rules=work.r_t22, onfail=CONTINUE)
%wif(policies)
%assert_log(hook=POLICIES, seq=10, status=OK, aff=50, id=T22a,
    desc=NOMATCH=DELETE matched 50 rows)
proc sql noprint;
    select count(*), coalesce(sum(mod(pol_id, 2) = 1), 0)
        into :t22n trimmed, :t22odd trimmed
        from work.policies;
quit;
%assert_true(flag=%eval(&t22n = 50 and &t22odd = 0), id=T22b,
    desc=unmatched rows deleted and matched rows kept)
%fresh(policies)
%put NOTE: [TEST] == negative block: the next JOIN is MEANT to abort (NOMATCH=FAIL) ==;
%wif(policies, at=FAILJ)
%assert_log(hook=FAILJ, seq=10, status=FAILED, id=T22c,
    desc=NOMATCH=FAIL aborts on the first unmatched row)
%assert_ds_equal(a=work.policies, b=work.g_policies, id=T22d,
    desc=aborted JOIN left the target byte-identical)
%wif_off
%let syscc = 0;

/*==================================================================
  T23  JOIN key renames (srckey=targetkey)
==================================================================*/
data work.carry2;
    set work.carry(rename=(pol_id=pid));
run;
data work.r_t23;
    length scenario $32 hook $32 seq 8 verb $8 keys $200 source $41 columns $1000;
    infile datalines dsd dlm='|' truncover;
    input scenario :$32. hook :$32. seq verb :$8. keys :$200. source :$41. columns :$1000.;
datalines4;
KRT|POLICIES|10|JOIN|PID=POL_ID|WORK.CARRY2|NEW_MOD=SCHED_MOD
;;;;
run;
%fresh(policies)
%wif_init(scenario=KRT, rules=work.r_t23, onfail=CONTINUE)
%wif(policies)
%assert_log(hook=POLICIES, seq=10, status=OK, aff=50, id=T23a,
    desc=renamed key matched the 50 even pol_ids)
proc sql noprint;
    select count(*) into :t23b trimmed
    from work.policies p, work.carry c
    where p.pol_id = c.pol_id + 0 and mod(p.pol_id, 2) = 0
      and round(p.sched_mod, .0001) ne round(c.new_mod, .0001);
quit;
%assert_true(flag=%eval(&t23b = 0), id=T23b,
    desc=values pulled through the renamed key)
%wif_off

/*==================================================================
  T24  SORT + DEDUPE (FIRST and LAST)
==================================================================*/
data work.g_hist;
    length pol_id 8 eff 8 val 8;
    do pol_id = 1 to 5;
        do eff = 1 to 3;
            val = eff;
            output;
        end;
    end;
run;
data work.r_t24;
    length scenario $32 hook $32 seq 8 verb $8 keys $200 options $200;
    infile datalines dsd dlm='|' truncover;
    input scenario :$32. hook :$32. seq verb :$8. keys :$200. options :$200.;
datalines4;
DDT|HIST|10|SORT|POL_ID DESCENDING EFF|
DDT|HIST|20|DEDUPE|POL_ID|
DDT|HISTL|10|SORT|POL_ID DESCENDING EFF|
DDT|HISTL|20|DEDUPE|POL_ID|LAST
;;;;
run;
data work.hist;
    set work.g_hist;
run;
%wif_init(scenario=DDT, rules=work.r_t24, onfail=CONTINUE)
%wif(hist)
%assert_log(hook=HIST, seq=20, status=OK, aff=10, id=T24a,
    desc=DEDUPE dropped the 10 non-latest rows)
proc sql noprint;
    select count(*), sum(val) into :t24n trimmed, :t24s trimmed from work.hist;
quit;
%assert_true(flag=%eval(&t24n = 5 and &t24s = 15), id=T24b,
    desc=SORT desc + DEDUPE keeps the latest row per key)
data work.hist;
    set work.g_hist;
run;
%wif(hist, at=HISTL)
proc sql noprint;
    select count(*), sum(val) into :t24c trimmed, :t24d trimmed from work.hist;
quit;
%assert_true(flag=%eval(&t24c = 5 and &t24d = 5), id=T24c,
    desc=the LAST option keeps the other end per key)
%wif_off

/*==================================================================
  T25  SAVE with a parameterized destination
==================================================================*/
data work.r_t25;
    length scenario $32 hook $32 seq 8 verb $8 source $41;
    infile datalines dsd dlm='|' truncover;
    input scenario :$32. hook :$32. seq verb :$8. source :$41.;
datalines4;
SAVET|POLICIES|10|SAVE|WORK.SV_&WIF_SCENARIO.
;;;;
run;
%fresh(policies)
%wif_init(scenario=SAVET, rules=work.r_t25, onfail=CONTINUE)
%wif(policies)
%assert_log(hook=POLICIES, seq=10, status=OK, aff=100, id=T25a,
    desc=SAVE logged the rows written)
%assert_ds_equal(a=work.sv_savet, b=work.g_policies, id=T25b,
    desc=snapshot written under the scenario-stamped name)
%assert_ds_equal(a=work.policies, b=work.g_policies, id=T25c,
    desc=SAVE never modifies the hooked table)
%wif_off

/*==================================================================
  T26  APPEND NEWCOLS + no-WHERE fast path; then a clean wif_check
==================================================================*/
data work.r_t26;
    length scenario $32 hook $32 seq 8 verb $8 source $41 columns $1000 options $200;
    infile datalines dsd dlm='|' truncover;
    input scenario :$32. hook :$32. seq verb :$8. source :$41. columns :$1000. options :$200.;
datalines4;
APPN|POLICIES|10|APPEND|WORK.SHOCK|AMT_GROSS=PREMIUM YR=SHOCK_YR|NEWCOLS
;;;;
run;
%fresh(policies)
%wif_init(scenario=APPN, rules=work.r_t26, onfail=CONTINUE)
%wif(policies)
%assert_log(hook=POLICIES, seq=10, status=OK, aff=12, id=T26a,
    desc=fast-path APPEND added all 12 shock rows)
proc sql noprint;
    select count(*) into :t26b trimmed
    from dictionary.columns
    where libname = 'WORK' and memname = 'POLICIES' and upcase(name) = 'SHOCK_YR';
    select coalesce(sum(shock_yr is not null and pol_id <= 100), 99) into :t26c trimmed
    from work.policies;
quit;
%assert_true(flag=%eval(&t26b = 1 and &t26c = 0), id=T26b,
    desc=NEWCOLS column exists and is missing on the original rows)
%wif_check(scope=GEN)
%assert_true(flag=%eval(&WIF_RC = 0), id=T26c, desc=wif_check clean on a clean gen)
%wif_off

/*==================================================================
  T27  SKIP_FAIL logging + wif_check catches a dirty gen
==================================================================*/
data work.r_t27;
    length scenario $32 hook $32 seq 8 verb $8 keys $200 source $41
           columns $1000 assign $8000;
    infile datalines dsd dlm='|' truncover;
    input scenario :$32. hook :$32. seq verb :$8. keys :$200. source :$41.
          columns :$1000. assign :$8000.;
datalines4;
SKF|POLICIES|10|JOIN|POL_ID|WORK.NO_SUCH_SRC|X=Y|
SKF|POLICIES|20|SET||||premium = 0;
;;;;
run;
%fresh(policies)
%wif_init(scenario=SKF, rules=work.r_t27, onfail=CONTINUE)
%put NOTE: [TEST] == negative block: the next hook is MEANT to fail and skip its second rule ==;
%wif(policies)
%get_log(hook=POLICIES, seq=20)
%assert_true(flag=%eval("&TL_STATUS" = "SKIP_FAIL"), id=T27a,
    desc=rules after a failure are logged SKIP_FAIL)
%wif_check(scope=GEN)
%assert_true(flag=%eval(&WIF_RC = 1), id=T27b,
    desc=wif_check flags the dirty gen)
%wif_off
%let syscc = 0;

/*==================================================================
  T28  wif_status + auto-deactivate + wif_reset
==================================================================*/
data work.r_t28;
    length scenario $32 hook $32 seq 8 verb $8 assign $8000;
    infile datalines dsd dlm='|' truncover;
    input scenario :$32. hook :$32. seq verb :$8. assign :$8000.;
datalines4;
STAT|POLICIES|10|SET|premium = premium + 1;
;;;;
run;
%wif_init(scenario=STAT, rules=work.r_t28, onfail=CONTINUE)
%wif_status
%macro t28_check1();
%assert_true(flag=%eval(&syscc <= 4 and &WIF_ACTIVE = 1), id=T28a,
    desc=wif_status runs clean while active)
%mend t28_check1;
%t28_check1()
proc datasets lib=work nolist nowarn; delete _wif_rules; quit;
%fresh(policies)
%wif(policies)
%assert_true(flag=%eval(&WIF_ACTIVE = 0), id=T28b,
    desc=hooks auto-deactivate when the rules dataset vanished)
%wif_reset
data work.t28probe;
    do i = 1 to 10;
        output;
    end;
run;
proc sql noprint;
    select count(*) into :t28c trimmed from work.t28probe;
quit;
%assert_true(flag=%eval(&WIF_ACTIVE = 0 and &WIF_RC = 0 and &syscc = 0 and &t28c = 10),
    id=T28c, desc=wif_reset leaves a sane session)

/*==================================================================
  T29  wif_run code= (macro-wrapped program, no server file needed)
==================================================================*/
%macro wr_prog();
data work.runin;
    set work.g_runin;
run;
%wif(runin)
data work.runout;
    set work.runin;
    out_prem = premium;
run;
%mend wr_prog;
%wif_run(scenario=UP, code=wr_prog, rules=work.r_t15, keep=runout,
         onfail=CONTINUE)
proc sql noprint;
    select coalesce(sum(out_prem), 0) into :t29a trimmed from work.up_runout;
quit;
%assert_true(flag=%eval(&t29a = 1100), id=T29a,
    desc=wif_run code= ran the macro-wrapped program)
%assert_true(flag=%eval(&WIF_ACTIVE = 0), id=T29b, desc=code= run ended clean)

/*==================================================================
  T30  autohook: fixture program in, suggested copy + report out
==================================================================*/
%include "&WIF_HOME/tools/wif_autohook.sas";
data _null_;
    file "&TROOT/main/ah_fixture.sas" lrecl=500;
    put 'data work.alpha;';
    put '    x = 1;';
    put 'run;';
    put '%wif(alpha)';
    put 'data work.beta;';
    put '    y = 1;';
    put 'run;';
    put 'proc sql;';
    put '    create table work.gamma as select * from work.beta;';
    put 'quit;';
    put 'data work.dup1; a = 1; run;';
    put 'data work.dup2;';
    put '    b = 2;';
    put 'run;';
    put 'data work.dup2;';
    put '    b = 3;';
    put 'run;';
    put 'proc sort data=work.beta out=work.beta_s;';
    put '    by y;';
    put 'run;';
    put 'proc means data=work.beta_s noprint;';
    put '    var y;';
    put '    output out=work.stats mean=;';
    put 'run;';
    put 'data perm.zed;';
    put '    z = 1;';
    put 'run;';
    put '%macro inner();';
    put 'data work.inmac; m = 1; run;';
    put '%mend inner;';
    put 'data work.v1 / view=work.v1;';
    put '    set work.beta;';
    put 'run;';
    put 'proc sql;';
    put '    create table';
    put '        work.delta as';
    put '    select * from work.beta;';
    put '    create table work.eps(compress=yes) as';
    put '    select * from work.beta;';
    put 'quit;';
    put 'proc sql;';
    put '    create table work.zeta as select * from work.beta;';
    put 'data work.eta;';
    put '    set work.beta;';
    put 'run;';
run;
%wif_autohook(main=&TROOT/main/ah_fixture.sas,
              out=&TROOT/main/ah_fixture_hooked.sas)
proc sql noprint;
    select coalesce(sum(action = 'INSERT'), 99) into :t30i trimmed
    from work.wif_autohook;
    select coalesce(sum(action = 'SKIP'), 99) into :t30s trimmed
    from work.wif_autohook;
    select count(*) into :t30d trimmed
    from work.wif_autohook
    where action = 'SKIP' and index(paste, 'at=DUP2_L') > 0;
quit;
%assert_true(flag=%eval(&t30i = 7), id=T30a,
    desc=autohook inserted beta gamma beta_s stats delta eps eta [got &t30i])
%assert_true(flag=%eval(&t30d = 2), id=T30b,
    desc=duplicate-site table got two paste-ready at= suggestions)
%assert_true(flag=%eval(%sysfunc(fileexist(&TROOT/main/ah_fixture_hooked.sas)) = 1),
    id=T30c, desc=suggested copy written)
data work.t30hooks;
    infile "&TROOT/main/ah_fixture_hooked.sas" lrecl=500 truncover;
    input line $500.;
    if index(line, '25'x || 'wif(') = 1;
run;
proc sql noprint;
    select count(*) into :t30h trimmed from work.t30hooks;
quit;
%assert_true(flag=%eval(&t30h = 8), id=T30d,
    desc=copy holds the original hook plus the 7 inserted ones [got &t30h])
proc sql noprint;
    select count(*) into :t30z trimmed
    from work.wif_autohook
    where table = 'ZETA' and action = 'SKIP' and index(reason, 'quit') > 0;
quit;
%assert_true(flag=%eval(&t30z = 1), id=T30e,
    desc=sql block without quit reported instead of silently missed)

/*==================================================================
  T31  wif_compare digest
==================================================================*/
data work.b1_out;
    do pol_id = 1 to 10;
        prem = 100;
        output;
    end;
run;
data work.s1_out;
    set work.b1_out;
    if pol_id <= 3 then prem = 110;
    if pol_id = 10 then delete;
run;
data work.s1_out;
    set work.s1_out end=_e;
    output;
    if _e then do;
        pol_id = 99; prem = 100;
        output;
    end;
run;
%wif_compare(base=B1, scen=S1, tables=OUT, keys=pol_id, lib=work, print=N)
proc sql noprint;
    select nobs_base, nobs_scen, only_base, only_scen, changed_rows
        into :t31nb trimmed, :t31ns trimmed, :t31ob trimmed,
             :t31os trimmed, :t31ch trimmed
        from work.wif_compare where table = 'OUT';
    select round(sum_base), round(sum_scen)
        into :t31sb trimmed, :t31ss trimmed
        from work.wif_compare_cols where table = 'OUT' and column = 'PREM';
quit;
%assert_true(flag=%eval(&t31nb = 10 and &t31ns = 10 and &t31ob = 1 and &t31os = 1
                        and &t31ch = 3), id=T31a,
    desc=table digest: counts orphans and changed rows [&t31nb &t31ns &t31ob &t31os &t31ch])
/* the column digest covers KEY-MATCHED rows (9 here); orphans are
   counted separately in the table digest                            */
%assert_true(flag=%eval(&t31sb = 900 and &t31ss = 930), id=T31b,
    desc=column digest over matched rows: premium 900 -> 930 [&t31sb &t31ss])

/*------------------------------------------------------------------
  Tally
------------------------------------------------------------------*/
proc sql noprint;
    select count(*), coalesce(sum(pass = 0), 0)
        into :t_total trimmed, :t_fails trimmed
        from work.t_results;
quit;
%macro t_summary();
%put NOTE: [TEST] ==================================================;
%if &t_fails = 0 %then %do;
    %put NOTE: [TEST] ALL &t_total ASSERTIONS PASSED;
%end;
%else %do;
    %put ERROR: [TEST] &t_fails OF &t_total ASSERTIONS FAILED;
    title '[TEST] failed assertions';
    proc print data=work.t_results noobs;
        where pass = 0;
    run;
    title;
    %let syscc = 8;
%end;
%put NOTE: [TEST] ==================================================;
%mend t_summary;
%t_summary()

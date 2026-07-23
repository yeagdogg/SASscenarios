/*====================================================================
  WIF renewal / customer-lifetime-value loop.

  Runs the pricing program N times. Each pass:
    - ages the policies one year          (SET, every iteration)
    - carries the prior term's schedule mod in as the expiring mod
      (JOIN from a carry table the driver builds; ITERS=2+ skips it
       on the first pass, when there is no prior term)
  and snapshots the priced output per year.

  Adapt the four %lets and the carry-table SELECT to your tables.
====================================================================*/

%let WIF_SAS = /server/path/wif.sas;
%let MAIN    = /server/path/my_program.sas;
%let RESULTS = /server/path/wif_results;
%let YEARS   = 5;

%include "&WIF_SAS";
libname results "&RESULTS";

data work.clv_rules;
    length scenario $32 hook $32 seq 8 verb $8 target $41 keys $200
           source $41 columns $1000 assign $8000 options $200;
    infile datalines dsd dlm='|' truncover;
    input scenario :$32. hook :$32. seq verb :$8. target :$41. keys :$200.
          source :$41. columns :$1000. assign :$8000. options :$200.;
/* cols: scenario|hook|seq|verb|target|keys|source|columns|assign|options
   (DATALINES4 + ;;;; because rule cells contain semicolons)          */
datalines4;
RENEWAL|POLICIES|10|SET|||||policy_age = policy_age + 1;|
RENEWAL|GUIDANCE_100|10|JOIN||POL_ID|WORK.CARRY|PRIOR_MOD=EXPIRING_MOD||ITERS=2+
RENEWAL|GUIDANCE_100|20|SET|||||rate_change = rate_change * &RATE_DRIFT;|
RENEWAL||10|LET|RATE_DRIFT||||1.03|
;;;;
run;

%macro clv_loop(years=&YEARS);
%local y;
%do y = 1 %to &years;
    %put NOTE: ================== CLV year &y of &years ==================;

    %wif_init(scenario=RENEWAL, rules=work.clv_rules, iter=&y, onfail=STOP)
    %include "&MAIN";

    /* next year's starting point, from this year's priced output    */
    proc sql;
        create table work.carry as
        select pol_id, sched_mod as prior_mod
        from work.final_rated;
    quit;

    %wif_save(table=final_rated, as=year&y._rated, lib=results)
    %wif_off
%end;

/* lifetime view: stack the yearly snapshots                          */
data results.clv_all_years;
    set
    %do y = 1 %to &years;
        results.year&y._rated(in=_y&y)
    %end;
    ;
    %do y = 1 %to &years;
        if _y&y then term_year = &y;
    %end;
run;
%mend clv_loop;

%clv_loop()

title 'Pricing evolution over the policy lifetime';
proc means data=results.clv_all_years mean median n;
    class term_year;
    var sched_mod rate_change premium;
run;
title;

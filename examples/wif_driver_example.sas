/*====================================================================
  WIF driver - the file you open in Enterprise Guide.
  Edit the four %lets, then run section by section.

  Remember: paths are the SAS SERVER's paths, not your PC's.
====================================================================*/

%let WIF_SAS  = /server/path/wif.sas;                 /* the kernel        */
%let RULES    = /server/path/wif_workbook.xlsx;       /* or a dataset name */
%let MAIN     = /server/path/my_program.sas;          /* your program      */
%let RESULTS  = /server/path/wif_results;             /* saved outputs     */

%include "&WIF_SAS";
libname results "&RESULTS";

/*--------------------------------------------------------------------
  0) One-time: your program needs %wif() hooks after the tables you
     care about, e.g. right after guidance_100 is created:

         data work.guidance_100;
             ...
         run;
         %wif(guidance_100)

     Hooks are INERT until %wif_init runs - safe to leave in place.
     Check placement:  python tools/lint_sas.py my_program.sas
--------------------------------------------------------------------*/

/*--------------------------------------------------------------------
  1) Validate the workbook without touching anything
--------------------------------------------------------------------*/
%wif_lint(rules=&RULES, scenario=RENEWAL)

/*--------------------------------------------------------------------
  2) One scenario, step by step (most control)
--------------------------------------------------------------------*/
%wif_init(scenario=RENEWAL, rules=&RULES)
%include "&MAIN";
%wif_save(table=out_final, as=renewal_out_final, lib=results)
%wif_off
%wif_report

/*--------------------------------------------------------------------
  3) Or: several scenarios in one go (each = init -> program -> save
     keep= tables as <SCENARIO>_<table> in outlib= -> off)
--------------------------------------------------------------------*/
%macro sweep();
%local i s;
%let s = BASE UP5 DOWN5 AGEUP SHOCK;
%do i = 1 %to %sysfunc(countw(&s));
    %wif_run(scenario=%scan(&s, &i), rules=&RULES, main=&MAIN,
             keep=out_final, outlib=results, onfail=STOP)
%end;
%mend sweep;
%sweep()
%wif_report

/*--------------------------------------------------------------------
  4) Ad-hoc: rules straight from datalines, no workbook involved
     (text in datalines never touches the macro processor)
--------------------------------------------------------------------*/
data work.quick_rules;
    length scenario $32 hook $32 seq 8 verb $8 keys $200 source $41
           columns $1000 assign $8000 options $200;
    infile datalines dsd dlm='|' truncover;
    input scenario :$32. hook :$32. seq verb :$8. keys :$200. source :$41.
          columns :$1000. assign :$8000. options :$200.;
datalines;
QUICK|GUIDANCE_100|10|SET||||sched_mod = min(sched_mod, 1.25);|
QUICK|RATED|10|JOIN|NAICS LOB STATE|WORK.MKT_ADJ|ADJ_FACTOR|rate = rate * adj_factor;|
;
run;

data work.mkt_adj;         /* the bulk what-if lookup, built in-session */
    length naics $6 lob $3 state $2 adj_factor 8;
    infile datalines dsd dlm='|';
    input naics :$6. lob :$3. state :$2. adj_factor;
datalines;
N100|GL|NY|1.10
N101|PR|NJ|0.95
;
run;

%wif_init(scenario=QUICK, rules=work.quick_rules)
%include "&MAIN";
%wif_off

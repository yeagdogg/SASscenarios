/*====================================================================
  WIF AUTOHOOK - suggest and insert %wif() hooks for a program.
  ====================================================================
  %include this file on demand (wif.sas must already be compiled -
  autohook reuses its utilities), then:

      %wif_autohook(main=/server/path/my_program.sas,
                    out=/server/path/my_program_hooked.sas)

  Reads the program, finds step boundaries that CREATE WORK tables
  (DATA statements, PROC SQL create table, PROC SORT out=, PROC
  MEANS/SUMMARY output out=, PROC TRANSPOSE out=), and writes a
  SUGGESTED copy with %wif(table) lines inserted after the owning
  run;/quit;. The ORIGINAL FILE IS NEVER TOUCHED. Everything the
  detector is not sure about becomes a report row instead of an
  insertion; work.wif_autohook holds the full report.

  Conservative by construction:
    - whitelist detection only (unknown procs are invisible)
    - inserts only when the run;/quit; sits ALONE on its line
    - a table created at 2+ sites is REPORT-ONLY (paste-ready at=
      suggestions are provided; hooking only one site would be wrong)
    - anything inside a %macro definition is report-only
    - views, macro-generated names, permanent-library targets,
      run cancel, implicit step terminations: report-only
  REVIEW the output, then lint it: python tools/lint_sas.py <out>
====================================================================*/

%macro wif_autohook(main=, out=, report=work.wif_autohook, replace=N);
%local _m _o _nins _nskip;
%let _m = %_wif_path(&main);
%let _o = %_wif_path(&out);
%if %length(&_m) = 0 or %length(&_o) = 0 %then %do;
    %put ERROR: [WIF] wif_autohook needs main= (the program) and out= (the suggested copy).;
    %return;
%end;
%if not %sysfunc(fileexist(&_m)) %then %do;
    %put ERROR: [WIF] wif_autohook: program not found: &_m (SAS SERVER path).;
    %return;
%end;
%if "&_m" = "&_o" %then %do;
    %put ERROR: [WIF] wif_autohook: out= must differ from main= - the original is never touched.;
    %return;
%end;
%if %sysfunc(fileexist(&_o)) %then %if %upcase(&replace) ne Y %then %do;
    %put ERROR: [WIF] wif_autohook: &_o already exists - pass replace=Y to overwrite it.;
    %return;
%end;

/* ---------------- pass 1: read ---------------- */
data work._wif_ah_lines;
    length line_no 8 text $32767 ll 8;
    infile "&_m" lrecl=32767 truncover length=_len;
    input text $varying32767. _len;
    line_no = _n_;
    ll = _len;
run;

/* ---------------- pass 2: mask ----------------
   Blank out block comments, star comments, macro comments and string
   contents (positions preserved) so pass 3 sees only real tokens.  */
data work._wif_ah_mask(keep=line_no mtext ll);
    length mtext $32767 _c _n $1;
    retain _st 0 _stmt0 1;  /* _st: 0 code, 1 sq, 2 dq, 3 block cmt, 4 star cmt */
    set work._wif_ah_lines;
    mtext = ' ';
    _i = 1;
    do while (_i <= ll);
        _c = char(text, _i);
        _n = ' ';
        if _i < ll then _n = char(text, _i + 1);
        if _st = 3 then do;                       /* block comment    */
            if _c = '*' and _n = '/' then do;
                _st = 0; _i = _i + 2;
            end;
            else _i = _i + 1;
        end;
        else if _st = 4 then do;                  /* star comment     */
            if _c = ';' then do;
                _st = 0; _stmt0 = 1;
                substr(mtext, _i, 1) = ';';
                _i = _i + 1;
            end;
            else _i = _i + 1;
        end;
        else if _st = 1 then do;                  /* '...'            */
            if _c = "'" then _st = 0;
            _i = _i + 1;
        end;
        else if _st = 2 then do;                  /* "..."            */
            if _c = '"' then _st = 0;
            _i = _i + 1;
        end;
        else do;                                  /* code             */
            if _c = '/' and _n = '*' then do;
                _st = 3; _i = _i + 2;
            end;
            else if _c = "'" then do;
                _st = 1; _i = _i + 1;
            end;
            else if _c = '"' then do;
                _st = 2; _i = _i + 1;
            end;
            else if _stmt0 = 1 and _c = '*' then do;
                _st = 4; _i = _i + 1;             /* star comment     */
            end;
            else if _stmt0 = 1 and _c = '25'x and _n = '*' then do;
                _st = 4; _i = _i + 2;             /* macro comment    */
            end;
            else do;
                substr(mtext, _i, 1) = _c;
                if _c = ';' then _stmt0 = 1;
                else if _c ne ' ' then _stmt0 = 0;
                _i = _i + 1;
            end;
        end;
    end;
run;

/* ---------------- pass 3: classify ----------------
   Rebuild statements from the masked text and walk them with the
   pending-until-own-run discipline.                                 */
data work._wif_ah_ev(keep=line table hook action reason paste);
    length line 8 table $41 hook $32 action $8 reason $200 paste $200;
    length _stmt _left $10000 _c $1 _w _nm $80 _pcw $1 _procname $16;
    array _pmem {32} $41 _temporary_;             /* pending members  */
    array _pline {32} 8 _temporary_;              /* their stmt lines */
    array _sqlm {64} $41 _temporary_;             /* sql pending set  */
    array _sqll {64} 8 _temporary_;
    retain _np 0 _nsql 0 _depth 0 _insql 0 _inmeans 0 _sl 0 _bl 0
           _procname ' ' _ninc 0;
    _pcw = '25'x;
    set work._wif_ah_mask end=_eof;

    /* a statement continuing from the previous line needs a space at
       the boundary, or its tokens FUSE across lines ("create table"
       + newline + "work.x" became CREATE TABLEWORK.X and silently
       failed every prefix match)                                     */
    if _bl > 0 and _bl < 10000 then do;
        _bl + 1;
        substr(_stmt, _bl, 1) = ' ';
    end;
    _i = 1;
    do while (_i <= ll);
        _c = char(mtext, _i);
        if _c = ';' then do;
            _stmt = compbl(upcase(strip(_stmt)));
            if _sl = 0 then _sl = line_no;
            link stmt;
            _stmt = ' ';
            _bl = 0;
            _sl = 0;
        end;
        else if _c ne ' ' or _bl > 0 then do;
            if _sl = 0 and _c ne ' ' then _sl = line_no;
            if _bl < 10000 then do;
                _bl + 1;
                substr(_stmt, _bl, 1) = _c;
            end;
        end;
        _i = _i + 1;
    end;
    if _eof then do;
        do _k = 1 to _np;
            line = _pline{_k}; table = _pmem{_k}; hook = ' ';
            action = 'SKIP'; paste = ' ';
            reason = 'file ended before an explicit run; - add one, or hook manually';
            output;
        end;
        do _k = 1 to _nsql;
            if _sqlm{_k} ne ' ' then do;
                line = _sqll{_k}; table = _sqlm{_k}; hook = ' ';
                action = 'SKIP'; paste = ' ';
                reason = 'file ended before quit; - add one, or hook manually';
                output;
            end;
        end;
        if _ninc > 0 then do;
            line = .; table = ' '; hook = ' '; action = 'INFO'; paste = ' ';
            reason = catx(' ', put(_ninc, best8.-l),
                'open-code INCLUDE statement(s) seen - run autohook on the included file(s) too');
            output;
        end;
    end;
    return;

  stmt: /* classify one completed statement (upcased, compbl)        */
    if _stmt = ' ' then return;
    /* existing hook calls have no semicolon of their own, so they
       ride at the FRONT of the next statement: record and excise
       them, then classify what remains                              */
    do while (index(_stmt, _pcw || 'WIF(') > 0);
        _j = index(_stmt, _pcw || 'WIF(');
        _j2 = _j + 5;
        _nm = ' ';
        do while (_j2 <= lengthn(_stmt));
            _c = char(_stmt, _j2);
            if _c in (',', ')') then _j2 = _j2 + 100000;
            else do;
                if _c ne ' ' then _nm = cats(_nm, _c);
                _j2 = _j2 + 1;
            end;
        end;
        _j2 = index(substr(_stmt, _j), ')');
        if _j2 = 0 then _j2 = lengthn(_stmt) - _j + 1;
        _j2 = _j + _j2 - 1;                       /* abs pos of ')'   */
        if lengthn(_nm) > 0 then do;
            line = _sl; table = upcase(_nm); hook = ' '; action = 'HOOKED';
            reason = 'existing hook call'; paste = ' ';
            output;
        end;
        _left = ' ';
        if _j > 1 then _left = substr(_stmt, 1, _j - 1);
        if _j2 < lengthn(_stmt) then
            _stmt = compbl(strip(catx(' ', _left, substr(_stmt, _j2 + 1))));
        else _stmt = compbl(strip(_left));
    end;
    _bl = lengthn(_stmt);
    if _stmt = ' ' then return;
    /* macro definition depth                                        */
    if _stmt =: _pcw || 'MACRO ' then do;
        _depth + 1;
        return;
    end;
    if _stmt =: _pcw || 'MEND' then do;
        if _depth > 0 then _depth = _depth - 1;
        return;
    end;
    if _stmt =: _pcw || 'INCLUDE' and _depth = 0 then do;
        _ninc + 1;
        return;
    end;
    /* RUN / QUIT terminators                                        */
    if _stmt = 'RUN' or _stmt =: 'RUN ' then do;
        if _stmt = 'RUN CANCEL' then do;
            do _k = 1 to _np;
                line = _pline{_k}; table = _pmem{_k}; hook = ' ';
                action = 'SKIP'; paste = ' ';
                reason = 'step ends with run cancel - nothing materializes';
                output;
            end;
            _np = 0; _inmeans = 0; _procname = ' ';
            return;
        end;
        link flushrun;
        return;
    end;
    if _stmt = 'QUIT' then do;
        if _insql = 1 then link flushsql;
        _insql = 0;
        _inmeans = 0;
        _procname = ' ';
        if _np > 0 then do;                       /* data pendings at
                                                     a quit are stray */
            do _k = 1 to _np;
                line = _pline{_k}; table = _pmem{_k}; hook = ' ';
                action = 'SKIP'; paste = ' ';
                reason = 'step has no explicit run; before quit; - add run; then hook';
                output;
            end;
            _np = 0;
        end;
        return;
    end;
    /* a new DATA/PROC statement implicitly terminates a pending step
       - and an open PROC SQL block. Without a quit; line there is no
       safe insertion point, so sql pendings become report rows.      */
    if _stmt =: 'DATA ' or _stmt = 'DATA' or _stmt =: 'PROC ' then do;
        if _insql = 1 then do;
            do _k = 1 to _nsql;
                if _sqlm{_k} ne ' ' then do;
                    line = _sqll{_k}; table = _sqlm{_k}; hook = ' ';
                    action = 'SKIP'; paste = ' ';
                    reason = 'sql block has no explicit quit; - add quit; then hook';
                    output;
                end;
            end;
            _nsql = 0;
            _insql = 0;
        end;
        if _np > 0 then do;
            do _k = 1 to _np;
                line = _pline{_k}; table = _pmem{_k}; hook = ' ';
                action = 'SKIP'; paste = ' ';
                reason = 'step has no explicit run; (implicitly terminated) - add run; then hook';
                output;
            end;
            _np = 0;
        end;
        _inmeans = 0;
        _procname = ' ';
    end;
    /* DATA statement: collect output member names                    */
    if _stmt =: 'DATA ' then do;
        if index(_stmt, 'VIEW=') > 0 and index(_stmt, '/') > 0 then do;
            line = _sl; table = scan(_stmt, 2, ' (/'); hook = ' ';
            action = 'SKIP'; paste = ' ';
            reason = 'data step VIEW - WIF refuses views; hook the step that materializes it';
            output;
            return;
        end;
        _j = 6;                                   /* after 'DATA '    */
        _nm = ' ';
        do while (_j <= _bl + 1);
            _c = ' ';
            if _j <= _bl then _c = char(_stmt, _j);
            if _c = '(' then do;                  /* skip ds options  */
                _pd = 1;
                do while (_j < _bl and _pd > 0);
                    _j = _j + 1;
                    if char(_stmt, _j) = '(' then _pd + 1;
                    else if char(_stmt, _j) = ')' then _pd = _pd - 1;
                end;
                _j = _j + 1;
            end;
            else if _c = '/' then _j = _bl + 2;   /* options region   */
            else if _c = ' ' then do;
                if lengthn(_nm) > 0 then link addpend;
                _nm = ' ';
                _j = _j + 1;
            end;
            else do;
                _nm = cats(_nm, _c);
                _j = _j + 1;
            end;
        end;
        return;
    end;
    /* PROC statements                                                */
    if _stmt =: 'PROC ' then do;
        _procname = scan(_stmt, 2, ' ');
        if _procname = 'SQL' then do;
            _insql = 1;
            return;
        end;
        if _procname = 'SORT' then do;
            _nm = ' ';
            _j = index(_stmt, ' OUT=');
            if _j > 0 then _nm = scan(substr(_stmt, _j + 5), 1, ' (');
            _w = ' ';
            _j = index(_stmt, ' DATA=');
            if _j > 0 then _w = scan(substr(_stmt, _j + 6), 1, ' (');
            if lengthn(_nm) = 0 then do;
                line = _sl; table = coalescec(_w, '_LAST_'); hook = ' ';
                action = 'SKIP'; paste = ' ';
                reason = 'in-place proc sort - no new table; hook the creation site instead';
                output;
            end;
            else if upcase(_nm) = upcase(_w) then do;
                line = _sl; table = _nm; hook = ' ';
                action = 'SKIP'; paste = ' ';
                reason = 'proc sort out= equals data= (in-place) - hook the creation site instead';
                output;
            end;
            else do;
                link addpend2;
            end;
            return;
        end;
        if _procname in ('MEANS', 'SUMMARY') then do;
            _inmeans = 1;
            return;
        end;
        if _procname = 'TRANSPOSE' then do;
            _j = index(_stmt, ' OUT=');
            if _j > 0 then do;
                _nm = scan(substr(_stmt, _j + 5), 1, ' (');
                link addpend2;
            end;
            return;
        end;
        return;
    end;
    /* OUTPUT OUT= inside proc means/summary                          */
    if _inmeans = 1 and _stmt =: 'OUTPUT' then do;
        _j = index(_stmt, 'OUT=');
        if _j > 0 then do;
            _nm = scan(substr(_stmt, _j + 4), 1, ' (');
            link addpend2;
        end;
        return;
    end;
    /* PROC SQL statements                                            */
    if _insql = 1 then do;
        if _stmt =: 'CREATE TABLE ' then do;
            /* strip trailing dataset options: create table x(compress=yes) as ... */
            _nm = scan(scan(_stmt, 3, ' '), 1, '(');
            link addsql;
            return;
        end;
        if _stmt =: 'CREATE VIEW ' then do;
            line = _sl; table = scan(_stmt, 3, ' '); hook = ' ';
            action = 'SKIP'; paste = ' ';
            reason = 'sql VIEW - WIF refuses views; hook a materialized table instead';
            output;
            return;
        end;
        if _stmt =: 'DROP TABLE ' then do;
            _nm = upcase(scan(_stmt, 3, ' ,'));
            do _k = 1 to _nsql;
                if _sqlm{_k} = _nm then _sqlm{_k} = ' ';
            end;
            return;
        end;
    end;
    return;

  addpend2: /* pending candidate from a proc-form name in _nm        */
    if lengthn(_nm) = 0 then return;
    link addpend;
    _nm = ' ';
  return;

  addpend: /* validate + queue one member name from _nm              */
    if upcase(_nm) = '_NULL_' then return;
    if index(_nm, '26'x) > 0 then do;
        line = _sl; table = _nm; hook = ' '; action = 'SKIP'; paste = ' ';
        reason = 'macro-generated table name - hook it inside your macro at a step boundary';
        output;
        return;
    end;
    if countc(_nm, '.') = 1 then do;
        if upcase(scan(_nm, 1, '.')) ne 'WORK' then do;
            line = _sl; table = _nm; hook = ' '; action = 'SKIP'; paste = ' ';
            reason = 'permanent-library output - hooks modify in place; hook deliberately with ALLOWLIB if you really mean it';
            output;
            return;
        end;
        _nm = scan(_nm, 2, '.');
    end;
    else if countc(_nm, '.') > 1 then return;
    if _depth > 0 then do;
        line = _sl; table = _nm; hook = ' '; action = 'SKIP'; paste = ' ';
        reason = 'inside a macro definition - add hooks manually at generated step boundaries';
        output;
        return;
    end;
    if _np < 32 then do;
        _np + 1;
        _pmem{_np} = upcase(_nm);
        _pline{_np} = _sl;
    end;
  return;

  addsql: /* sql create table pending (set semantics)                */
    if index(_nm, '26'x) > 0 then do;
        line = _sl; table = _nm; hook = ' '; action = 'SKIP'; paste = ' ';
        reason = 'macro-generated table name - hook it manually';
        output;
        return;
    end;
    if countc(_nm, '.') = 1 then do;
        if upcase(scan(_nm, 1, '.')) ne 'WORK' then do;
            line = _sl; table = _nm; hook = ' '; action = 'SKIP'; paste = ' ';
            reason = 'permanent-library output - not auto-hooked';
            output;
            return;
        end;
        _nm = scan(_nm, 2, '.');
    end;
    else if countc(_nm, '.') > 1 then return;
    if _depth > 0 then do;
        line = _sl; table = _nm; hook = ' '; action = 'SKIP'; paste = ' ';
        reason = 'inside a macro definition - hook manually';
        output;
        return;
    end;
    _nm = upcase(_nm);
    do _k = 1 to _nsql;                           /* set semantics    */
        if _sqlm{_k} = _nm then return;
    end;
    if _nsql < 64 then do;
        _nsql + 1;
        _sqlm{_nsql} = _nm;
        _sqll{_nsql} = _sl;
    end;
  return;

  flushrun: /* RUN; seen - pendings become inserts if it owns a line */
    if _np = 0 then do;
        _inmeans = 0;
        _procname = ' ';
        return;
    end;
    _alone = (prxmatch('/^\s*run\s*;\s*$/i', mtext) > 0);
    do _k = 1 to _np;
        line = line_no; table = _pmem{_k}; hook = _pmem{_k};
        if _alone then do;
            action = 'INSERT'; reason = 'work table created by this step';
            paste = ' ';
        end;
        else do;
            action = 'SKIP';
            reason = 'run; shares its line with other code - split the line, or paste the hook manually';
            paste = _pcw || 'wif(' || strip(lowcase(_pmem{_k})) || ')';
        end;
        output;
    end;
    _np = 0;
    _inmeans = 0;
    _procname = ' ';
  return;

  flushsql: /* QUIT; seen - sql pendings                             */
    _alone = (prxmatch('/^\s*quit\s*;\s*$/i', mtext) > 0);
    do _k = 1 to _nsql;
        if _sqlm{_k} ne ' ' then do;
            line = line_no; table = _sqlm{_k}; hook = _sqlm{_k};
            if _alone then do;
                action = 'INSERT'; reason = 'sql table created in this block';
                paste = ' ';
            end;
            else do;
                action = 'SKIP';
                reason = 'quit; shares its line with other code - split the line, or paste the hook manually';
                paste = _pcw || 'wif(' || strip(lowcase(_sqlm{_k})) || ')';
            end;
            output;
        end;
    end;
    _nsql = 0;
  return;
run;

/* ---------------- resolve duplicates + already-hooked ------------- */
proc sql;
    create table work._wif_ah_dup as
    select table from work._wif_ah_ev
    where action = 'INSERT'
    group by table
    having count(*) > 1;
    create table work._wif_ah_hkd as
    select distinct upcase(table) as table length=41 from work._wif_ah_ev
    where action = 'HOOKED';
quit;
data &report;
    length line 8 table $41 action $8 reason $200 paste $200;
    if _n_ = 1 then do;
        declare hash _d(dataset:'work._wif_ah_dup');
        _d.definekey('table');
        _d.definedone();
        declare hash _h(dataset:'work._wif_ah_hkd');
        _h.definekey('table');
        _h.definedone();
    end;
    set work._wif_ah_ev;
    where action ne 'HOOKED';
    if action = 'INSERT' then do;
        if _d.check() = 0 then do;
            action = 'SKIP';
            reason = 'created at more than one site - hook each site with its own at= name';
            paste = '25'x || 'wif(' || strip(lowcase(table)) || ', at='
                    || strip(table) || '_L' || strip(put(line, best8.-l)) || ')';
        end;
        else if _h.check() = 0 then do;
            action = 'SKIP';
            reason = 'already hooked elsewhere in the program';
            paste = ' ';
        end;
    end;
    keep line table action reason paste;
run;
proc sort data=&report; by line; run;

/* ---------------- emit the suggested copy ------------------------- */
proc sql noprint;
    create table work._wif_ah_ins as
    select line, table from &report
    where action = 'INSERT'
    order by line, table;
quit;
data _null_;
    length _hl $80;
    merge work._wif_ah_lines(in=_a)
          work._wif_ah_ins(rename=(line=line_no) in=_b);
    by line_no;
    file "&_o" lrecl=32767;
    if _a and first.line_no then put text $varying32767. ll;
    if _b then do;
        _hl = '25'x || 'wif(' || strip(lowcase(table)) || ')';
        put _hl $varying80. 80;
    end;
run;
data _null_;
    file "&_o" mod lrecl=32767;
    put ' ';
    put '/*====================================================================';
    put "  [WIF autohook] SUGGESTED COPY generated from: &_m";
    put '  Review before use. Hooks are inert until a scenario is active.';
    put '  Verify placement:  python tools/lint_sas.py <this file>';
    put '====================================================================*/';
run;

/* ---------------- report ------------------------------------------ */
%let _nins = 0;
%let _nskip = 0;
proc sql noprint;
    select coalesce(sum(action = 'INSERT'), 0),
           coalesce(sum(action = 'SKIP'), 0)
        into :_nins trimmed, :_nskip trimmed
        from &report;
quit;
title "[WIF autohook] &_m";
proc print data=&report noobs width=min;
run;
title;
%put NOTE: [WIF] autohook: &_nins hook(s) inserted, &_nskip site(s) report-only.;
%put NOTE: [WIF] suggested copy: &_o;
%put NOTE: [WIF] REVIEW the copy, then verify placement with tools/lint_sas.py before using it.;
%if &_nins = 0 %then
    %put WARNING: [WIF] autohook inserted nothing - mostly macro-generated steps? See the report for the reasons.;
proc datasets lib=work nolist nowarn;
    delete _wif_ah_lines _wif_ah_mask _wif_ah_ev _wif_ah_dup _wif_ah_hkd
           _wif_ah_ins;
quit;
%mend wif_autohook;

%put NOTE: [WIF] wif_autohook compiled - see the header of tools/wif_autohook.sas for usage.;

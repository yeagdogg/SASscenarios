"""Static lint for the SQF SAS sources.

Checks (no SAS available locally, so this is the syntax safety net):
  1. /* */ comment balance; stray */ outside a comment
  2. quote parity at EOF (%-escaped quotes inside macro text ignored)
  3. %macro / %mend pairing and name agreement
  4. %do / %end balance within each macro
  5. THE macro-trigger trap: & or % followed by a letter/underscore
     inside a SINGLE-quoted literal within a %macro body (single quotes
     do NOT protect macro triggers inside macros)
  6. paren balance outside strings/comments (per file, informational)
  7. lines exceeding 32760 bytes
  8. %wif( hook placement: a hook must sit at a step boundary -- the
     statement before it must be run; / quit; / a %-statement -- never
     inside a DATA step or between PROC SQL statements (WIF kernel)
  9. raw ';' inside %put message text (the %put terminates there and
     the rest becomes stray tokens); %str(;) / %nrstr(;) are allowed
 10. semicolons inside plain DATALINES/CARDS data (SAS ends the block
     at the FIRST ';' anywhere in the data; DATALINES4 required)
"""
import re
import sys

path = sys.argv[1]
src = open(path, encoding="utf-8", errors="replace").read()
lines = src.split("\n")

errors = []
warnings = []

# ---------- pass 1: char scan for comments/strings ----------
IN_CODE, IN_COMMENT, IN_SQ, IN_DQ = 0, 1, 2, 3
state = IN_CODE
line_no = 1
paren = 0
sq_start = dq_start = cm_start = None
macro_stack = []  # (name, line, do_depth)
cur_string = []
string_line = None

# collected single-quoted strings with their (line, in_macro) context
sq_strings = []

i = 0
n = len(src)
while i < n:
    ch = src[i]
    nxt = src[i + 1] if i + 1 < n else ""
    if ch == "\n":
        line_no += 1
        i += 1
        continue
    if state == IN_CODE:
        if ch == "/" and nxt == "*":
            state = IN_COMMENT
            cm_start = line_no
            i += 2
            continue
        if ch == "*" and nxt == "/":
            errors.append(f"line {line_no}: '*/' outside any comment")
            i += 2
            continue
        if ch == "'":
            # %' is a macro-quoted literal quote, not a string opener
            if i > 0 and src[i - 1] == "%":
                i += 1
                continue
            state = IN_SQ
            sq_start = line_no
            cur_string = []
            string_line = line_no
            i += 1
            continue
        if ch == '"':
            if i > 0 and src[i - 1] == "%":
                i += 1
                continue
            state = IN_DQ
            dq_start = line_no
            i += 1
            continue
        if ch == "(":
            paren += 1
        elif ch == ")":
            paren -= 1
        i += 1
        continue
    if state == IN_COMMENT:
        if ch == "*" and nxt == "/":
            state = IN_CODE
            i += 2
            continue
        i += 1
        continue
    if state == IN_SQ:
        if ch == "'" and nxt == "'":
            cur_string.append("''")
            i += 2
            continue
        if ch == "'":
            sq_strings.append((string_line, "".join(cur_string)))
            state = IN_CODE
            i += 1
            continue
        cur_string.append(ch)
        i += 1
        continue
    if state == IN_DQ:
        if ch == '"' and nxt == '"':
            i += 2
            continue
        if ch == '"':
            state = IN_CODE
            i += 1
            continue
        i += 1
        continue

if state == IN_COMMENT:
    errors.append(f"EOF: unclosed comment opened at line {cm_start}")
if state == IN_SQ:
    errors.append(f"EOF: unclosed single quote opened at line {sq_start}")
if state == IN_DQ:
    errors.append(f"EOF: unclosed double quote opened at line {dq_start}")
if paren != 0:
    warnings.append(f"EOF: net paren balance {paren:+d} (outside strings/comments)")

# ---------- pass 2: statement-level structure (comments/strings stripped) ----------
# rebuild a stripped copy where comments and string contents are blanked
out = []
state = IN_CODE
i = 0
while i < n:
    ch = src[i]
    nxt = src[i + 1] if i + 1 < n else ""
    if state == IN_CODE:
        if ch == "/" and nxt == "*":
            state = IN_COMMENT
            out.append("  ")
            i += 2
            continue
        if ch == "'" and not (i > 0 and src[i - 1] == "%"):
            state = IN_SQ
            out.append("'")
            i += 1
            continue
        if ch == '"' and not (i > 0 and src[i - 1] == "%"):
            state = IN_DQ
            out.append('"')
            i += 1
            continue
        out.append(ch)
        i += 1
        continue
    if state == IN_COMMENT:
        if ch == "*" and nxt == "/":
            state = IN_CODE
            out.append("  ")
            i += 2
            continue
        out.append("\n" if ch == "\n" else " ")
        i += 1
        continue
    if state == IN_SQ:
        if ch == "'" and nxt == "'":
            out.append("  ")
            i += 2
            continue
        if ch == "'":
            state = IN_CODE
            out.append("'")
            i += 1
            continue
        out.append("\n" if ch == "\n" else " ")
        i += 1
        continue
    if state == IN_DQ:
        if ch == '"' and nxt == '"':
            out.append("  ")
            i += 2
            continue
        if ch == '"':
            state = IN_CODE
            out.append('"')
            i += 1
            continue
        out.append("\n" if ch == "\n" else " ")
        i += 1
        continue
stripped = "".join(out)

macro_ranges = []  # (name, start_line, end_line)
stack = []
do_stack = []
for m in re.finditer(r"%(macro|mend|do|end|if|then|else)\b\s*([A-Za-z_][A-Za-z0-9_]*)?", stripped, re.I):
    kw = m.group(1).lower()
    name = (m.group(2) or "").lower()
    ln = stripped.count("\n", 0, m.start()) + 1
    if kw == "macro":
        stack.append((name, ln))
        do_stack.append(0)
    elif kw == "mend":
        if not stack:
            errors.append(f"line {ln}: %mend without %macro")
        else:
            mname, mline = stack.pop()
            depth = do_stack.pop()
            if depth != 0:
                errors.append(f"macro %{mname} (line {mline}): %do/%end imbalance {depth:+d}")
            if name and name != mname:
                errors.append(f"line {ln}: %mend {name} closes %macro {mname} (line {mline})")
            macro_ranges.append((mname, mline, ln))
    elif kw == "do":
        if do_stack:
            do_stack[-1] += 1
        else:
            errors.append(f"line {ln}: %do in open code")
    elif kw == "end":
        if do_stack:
            do_stack[-1] -= 1
            if do_stack[-1] < 0:
                errors.append(f"line {ln}: %end without %do in macro {stack[-1][0] if stack else '?'}")
                do_stack[-1] = 0
        else:
            errors.append(f"line {ln}: %end in open code")
for mname, mline in stack:
    errors.append(f"%macro {mname} (line {mline}) never closed with %mend")

def in_macro(ln):
    return any(s <= ln <= e for _, s, e in macro_ranges)

# ---------- check 5: macro triggers inside single-quoted literals in macros ----------
trig = re.compile(r"[&%][A-Za-z_]")
for ln, content in sq_strings:
    if not in_macro(ln):
        continue
    m = trig.search(content)
    if m:
        errors.append(
            f"line {ln}: single-quoted literal inside a macro contains a LIVE "
            f"macro trigger '{m.group(0)}': {content[:70]!r}"
        )

# ---------- check 6b: bare arithmetic-operator operands in macro comparisons ----------
# In %IF/%EVAL a bare / (or //) after a comparison operator is parsed as
# ARITHMETIC, not as a character. Must be written "..." = "/" (both quoted).
# Only the CONDITION region (between %if/%while and %then/close-paren) counts;
# a %let after %then may legally assign text containing = / sequences.
bare_op = re.compile(r"(?:^|[^<>^~=])(=|\bne\b|\beq\b|\^=|~=)\s*(//|/)(?!\*)", re.I)
for m in re.finditer(r"%if\b(.*?)%then", stripped, re.I | re.S):
    cond = m.group(1)
    mm = bare_op.search(cond)
    if mm:
        ln = stripped.count("\n", 0, m.start(1) + mm.start()) + 1
        errors.append(
            f"line {ln}: bare '{mm.group(2)}' operand in a macro %IF comparison "
            f"(parsed as division by %EVAL) - quote both sides: \"...\" = \"/\""
        )
for m in re.finditer(r"%do\s+%?(?:while|until)\s*\(([^()]*(?:\([^()]*\)[^()]*)*)\)", stripped, re.I | re.S):
    cond = m.group(1)
    mm = bare_op.search(cond)
    if mm:
        ln = stripped.count("\n", 0, m.start(1) + mm.start()) + 1
        errors.append(
            f"line {ln}: bare '{mm.group(2)}' operand in a macro %WHILE comparison "
            f"(parsed as division by %EVAL) - quote both sides: \"...\" = \"/\""
        )

# ---------- check 7 ----------
for idx, l in enumerate(lines, 1):
    if len(l) > 32760:
        errors.append(f"line {idx}: exceeds 32760 bytes")

# ---------- check 8: %wif( hook placement ----------
# The hook expands to open-code steps when active; placed mid-step it
# corrupts the surrounding step. Accept a hook only when the previous
# statement is run; / quit; / a %-statement (%mend, %let, %wif_init,
# another %wif, ...), or nothing (file start). String contents are
# already blanked in `stripped`, so call execute('%nrstr(%wif(t))')
# never matches here.
wif_call = re.compile(r"%wif\s*\(", re.I)
for m in wif_call.finditer(stripped):
    prev = stripped[: m.start()].rstrip()
    ln = stripped.count("\n", 0, m.start()) + 1
    if prev == "":
        continue
    if prev.endswith(")"):
        # a preceding macro invocation without trailing semicolon
        # (%wif_init(...), %fresh(x), ...) is a statement boundary;
        # a bare f(a) without % and without ; is still mid-statement
        if re.search(r"%[A-Za-z_]\w*\s*\([^;]*$", prev):
            continue
        errors.append(
            f"line {ln}: %wif( hook does not follow a step boundary "
            f"(previous text ends with ')') - place hooks right after run;/quit;"
        )
        continue
    if prev.endswith(";"):
        last_stmt = prev[:-1].split(";")[-1].strip().lower()
        if last_stmt in ("run", "quit") or last_stmt.startswith("%"):
            continue
        errors.append(
            f"line {ln}: %wif( hook placed after statement '{last_stmt[:50]};' - "
            f"hooks are open-code only, right after run;/quit;, never inside a "
            f"DATA step or between PROC SQL statements"
        )
        continue
    errors.append(
        f"line {ln}: %wif( hook not preceded by a completed statement - "
        f"place hooks right after run;/quit;"
    )

# ---------- check 9: raw ';' inside %put message text ----------
# A %put statement terminates at its first ';'; anything after it on
# the line becomes stray tokens (the class behind 12 shipped defects).
# %str(;) / %nrstr(;) are the sanctioned escapes and are masked first.
masked_put = re.sub(r"%n?r?str\(\s*;\s*\)", "<SEMI>", stripped, flags=re.I)
put_ok_tail = re.compile(r"%(end|else|do|mend|if|put|let|return|goto|abort)\b", re.I)
for m in re.finditer(r"%put\b", masked_put, re.I):
    seg_end = masked_put.find("\n", m.start())
    if seg_end == -1:
        seg_end = len(masked_put)
    seg = masked_put[m.start():seg_end]
    semi = seg.find(";")
    if semi == -1:
        continue  # %put terminator on a later line - out of scope
    tail = seg[semi + 1:].strip()
    if tail and not put_ok_tail.match(tail):
        ln = masked_put.count("\n", 0, m.start()) + 1
        errors.append(
            f"line {ln}: raw ';' inside %put message text - the %put ends at that "
            f"';' and the rest becomes stray tokens; write %str(;) or reword with '-'"
        )

# ---------- check 10: semicolons inside plain DATALINES data ----------
# SAS ends a datalines;/cards; block at the FIRST semicolon anywhere in
# the data (documented restriction). DATALINES4 (terminated by ';;;;')
# exists precisely for semicolon-bearing data, e.g. WIF rule cells.
dl_open = re.compile(r"^\s*(datalines|cards)\s*;\s*$", re.I)
stripped_lines = stripped.split("\n")
li = 0
while li < len(stripped_lines):
    if dl_open.match(stripped_lines[li]):
        lj = li + 1
        while lj < len(lines):
            raw = lines[lj]
            if ";" in raw:
                if raw.strip() == ";":
                    break  # clean terminator, no embedded semicolons
                errors.append(
                    f"line {lj + 1}: semicolon inside DATALINES data - SAS ends the "
                    f"block at the FIRST ';' anywhere in the data; use datalines4 "
                    f"with a ';;;;' terminator"
                )
                break
            lj += 1
        li = lj
    li += 1

print(f"== lint {path}: {len(lines)} lines, {len(macro_ranges)} macros ==")
for e in errors:
    print("ERROR:", e)
for w in warnings:
    print("WARN :", w)
if not errors:
    print("clean: no errors")
sys.exit(1 if errors else 0)

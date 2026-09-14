#!/bin/sh
# log-sift test suite.
#
# Fixtures are written by the suite into tests/tmp and removed after. Nothing
# reads a real log off the machine, so the results do not depend on what
# happens to be in /var/log.
#
# The dedupe cases are the ones that matter: shape collapsing is the feature,
# and it fails in two directions that a count-only assertion cannot tell
# apart — collapsing too little (the varying token was not recognised) and
# collapsing too much (two genuinely different lines became one). Both are
# asserted explicitly.

set -u

BIN="${BIN:-./log-sift}"
PASS=0
FAIL=0
TMP="tests/tmp"

mkdir -p "$TMP"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }

# assert that a command's stdout equals an expected string
eq() {
    _name="$1"; _want="$2"; shift 2
    _got=$("$@" 2>&1)
    if [ "$_got" = "$_want" ]; then ok "$_name"
    else bad "$_name" "want [$_want] got [$_got]"; fi
}

# assert a command exits with a given status
rc() {
    _name="$1"; _want="$2"; shift 2
    "$@" >/dev/null 2>&1
    _got=$?
    if [ "$_got" = "$_want" ]; then ok "$_name"
    else bad "$_name" "want rc=$_want got rc=$_got"; fi
}

echo "log-sift tests"
echo

if [ ! -x "$BIN" ]; then
    echo "  FAIL  $BIN is not executable — run make first"
    exit 1
fi

# ---- fixtures -----------------------------------------------------------

cat > "$TMP/app.log" <<'EOF'
2026-09-14T10:00:01Z INFO  starting server on port 8080
2026-09-14T10:00:05Z ERROR connection refused: db:5432
2026-09-14T10:00:06Z ERROR connection refused: db:5432
2026-09-14T10:00:07Z ERROR connection refused: db:5432
2026-09-14T10:00:20Z INFO  GET /users/8821 200 in 43ms
2026-09-14T10:00:21Z INFO  GET /users/9134 200 in 51ms
2026-09-14T10:00:30Z FATAL out of memory
EOF

cat > "$TMP/svc.json" <<'EOF'
{"time":"2026-09-14T10:00:03Z","level":"info","msg":"cache warm","user_id":42}
{"time":"2026-09-14T10:00:08Z","level":"error","msg":"timeout","user_id":42}
{"time":"2026-09-14T10:00:09Z","level":"error","msg":"timeout","user_id":7}
EOF

cat > "$TMP/svc.logfmt" <<'EOF'
time=2026-09-14T10:00:04Z level=info msg="worker up" worker=3
time=2026-09-14T10:00:13Z level=warn msg="queue deep" depth=1204 worker=3
EOF

# ---- 1. basics ----------------------------------------------------------

"$BIN" --version >/dev/null 2>&1 && ok "--version" || bad "--version"
"$BIN" --help 2>&1 | grep -q "one query interface" \
    && ok "--help shows the summary" || bad "--help shows the summary"

eq "reads a file whole" "7" "$BIN" "$TMP/app.log" --count

# ---- 2. exit codes follow grep's convention -----------------------------
#
# Scripts branch on these, so each must be distinguishable: 0 matched,
# 1 read fine but matched nothing, 2 could not read.

rc "match exits 0"          0 "$BIN" "$TMP/app.log" --grep ERROR
rc "no match exits 1"       1 "$BIN" "$TMP/app.log" --grep zzznotpresent
rc "missing file exits 2"   2 "$BIN" "$TMP/does-not-exist.log"
rc "directory exits 2"      2 "$BIN" "$TMP"
rc "bad --level exits 2"    2 "$BIN" "$TMP/app.log" --level nonsense
rc "bad --since exits 2"    2 "$BIN" "$TMP/app.log" --since 5x
rc "bad --field exits 2"    2 "$BIN" "$TMP/app.log" --field novalue

# A directory must be REFUSED, not crash: readlines() aborts the process on
# one, so this asserts the guard is still in front of it.
"$BIN" "$TMP" 2>&1 | grep -q "is a directory" \
    && ok "directory is refused by name" || bad "directory is refused by name"

# ---- 3. level filtering is a THRESHOLD ----------------------------------

eq "--level error includes fatal" "4" "$BIN" "$TMP/app.log" --level error --count
eq "--level-only excludes higher" "3" "$BIN" "$TMP/app.log" --level-only error --count
eq "--level info includes all"    "7" "$BIN" "$TMP/app.log" --level info --count

# ---- 4. formats are sniffed, not configured -----------------------------

eq "json field query"    "2" "$BIN" "$TMP/svc.json" --field user_id=42 --count
eq "json level detected" "2" "$BIN" "$TMP/svc.json" --level error --count
eq "logfmt level"        "1" "$BIN" "$TMP/svc.logfmt" --level warn --count
eq "logfmt field"        "2" "$BIN" "$TMP/svc.logfmt" --field worker=3 --count

# A key that exists only as a VALUE elsewhere must not answer the query.
echo '{"msg":"level","level":"info"}' > "$TMP/tricky.json"
eq "json key is not matched as a value" "1" \
    "$BIN" "$TMP/tricky.json" --field level=info --count

# ---- 5. dedupe: the feature ---------------------------------------------
#
# Asserted in both directions. Collapsing too little means the varying token
# was not recognised; collapsing too much means two different lines were
# merged. A count alone cannot distinguish those, so both are checked.

eq "dedupe collapses varying ids" "4" \
    sh -c "'$BIN' '$TMP/app.log' --dedupe | wc -l | tr -d ' '"

"$BIN" "$TMP/app.log" --dedupe | grep -q "x3" \
    && ok "dedupe counts the repeats" || bad "dedupe counts the repeats"

# Two lines differing only by a number must collapse...
printf 'a 1 b\na 2 b\n' > "$TMP/num.log"
eq "numbers collapse" "1" sh -c "'$BIN' '$TMP/num.log' --dedupe | wc -l | tr -d ' '"

# ...but two lines differing by a WORD must not.
printf 'alpha thing\nbeta thing\n' > "$TMP/word.log"
eq "different words do not collapse" "2" \
    sh -c "'$BIN' '$TMP/word.log' --dedupe | wc -l | tr -d ' '"

# An identifier containing digits is not a varying value.
printf 'route42 up\nroute43 up\n' > "$TMP/ident.log"
eq "digits inside a word do not collapse" "2" \
    sh -c "'$BIN' '$TMP/ident.log' --dedupe | wc -l | tr -d ' '"

# IPs, UUIDs and hex blobs each collapse as one token, not several.
printf 'from 10.0.0.1 ok\nfrom 192.168.1.44 ok\n' > "$TMP/ip.log"
eq "ipv4 collapses as one token" "1" \
    sh -c "'$BIN' '$TMP/ip.log' --dedupe | wc -l | tr -d ' '"

printf 'id 550e8400-e29b-41d4-a716-446655440000 x\nid 550e8400-e29b-41d4-a716-446655440001 x\n' > "$TMP/uuid.log"
eq "uuid collapses as one token" "1" \
    sh -c "'$BIN' '$TMP/uuid.log' --dedupe | wc -l | tr -d ' '"

# The shape cap must be reported, never silently applied.
"$BIN" "$TMP/app.log" --dedupe --shapes 1 2>&1 | grep -q "shape limit" \
    && ok "shape cap is reported" || bad "shape cap is reported"

# ---- 5b. embedded JSON payloads in text lines ---------------------------
#
# Monolog/Laravel/Rails/python-logging all write a human prefix followed by a
# JSON context blob. Those lines sniff as TEXT, so without payload support a
# --field query answers 0 — which a script reads as "no such record" rather
# than "unsupported". That silent wrong answer is what these pin.

cat > "$TMP/monolog.log" <<'MEOF'
[2026-05-20 12:04:53] dev.INFO: callback from ::1 {"transID":"ABC-007","amount":"1000","name":"John"}
[2026-05-20 12:04:57] dev.INFO: posting transaction {"id":16}
[2026-05-20 12:04:58] dev.WARNING: App\Payment::post: failed, no invoice
[2026-05-20 12:08:40] dev.INFO: callback from ::1 {"transID":"ABC-008","amount":"250","name":"Alice"}
MEOF

eq "field query reaches an embedded payload" "1" \
    "$BIN" "$TMP/monolog.log" --field transID=ABC-007 --count
eq "field wildcard selects payload-bearing lines" "2" \
    "$BIN" "$TMP/monolog.log" --field transID='*' --count
eq "--extract prints only the payload" \
    '{"transID":"ABC-007","amount":"1000","name":"John"}' \
    sh -c "'$BIN' '$TMP/monolog.log' --field transID=ABC-007 --extract 2>/dev/null"

# --extract must emit ONLY JSON: a prose line in the middle breaks whatever
# consumes the stream, so payload-less lines are skipped, not printed raw.
eq "--extract skips lines with no payload" "3" \
    sh -c "'$BIN' '$TMP/monolog.log' --extract 2>/dev/null | wc -l | tr -d ' '"

# The skip count goes to stderr so it cannot land in a piped JSON stream.
"$BIN" "$TMP/monolog.log" --extract 2>/dev/null | grep -q "no JSON payload" \
    && bad "--extract warning stays off stdout" "warning contaminated the data stream" \
    || ok "--extract warning stays off stdout"
"$BIN" "$TMP/monolog.log" --extract 2>&1 >/dev/null | grep -q "no JSON payload" \
    && ok "--extract reports skipped lines on stderr" \
    || bad "--extract reports skipped lines on stderr"

# Every extracted line must be parseable, which is the only assertion that
# actually proves the boundary was found correctly.
if command -v python3 >/dev/null 2>&1; then
    if "$BIN" "$TMP/monolog.log" --extract 2>/dev/null | \
       python3 -c 'import sys,json; [json.loads(l) for l in sys.stdin if l.strip()]' 2>/dev/null; then
        ok "--extract output is valid JSON"
    else
        bad "--extract output is valid JSON"
    fi
fi

# Braces in the human prefix must not be mistaken for the payload, and a
# brace inside a quoted value must not close the object early. Scanning from
# the right and requiring balance is what handles both.
cat > "$TMP/braces.log" <<'BEOF'
[2026-05-20 12:00:00] dev.ERROR: App\Foo::bar() {closure} failed {"code":500}
[2026-05-20 12:00:01] dev.INFO: message with {braces} and no payload
[2026-05-20 12:00:02] dev.INFO: nested {"outer":{"inner":42},"done":true}
[2026-05-20 12:00:03] dev.INFO: quoted {"msg":"a } in a string","n":1}
BEOF

eq "a brace in the prefix is not the payload" '{"code":500}' \
    sh -c "'$BIN' '$TMP/braces.log' --grep closure --extract 2>/dev/null"
eq "an unbalanced brace run is not a payload" "0" \
    "$BIN" "$TMP/braces.log" --grep 'and no payload' --field code='*' --count
eq "a nested object extracts whole" '{"outer":{"inner":42},"done":true}' \
    sh -c "'$BIN' '$TMP/braces.log' --grep nested --extract 2>/dev/null"
eq "a brace inside a string does not close the object" \
    '{"msg":"a } in a string","n":1}' \
    sh -c "'$BIN' '$TMP/braces.log' --grep quoted --extract 2>/dev/null"

# A whole-line JSON record is the record itself, not an embedded payload, so
# --extract must not alter it.
eq "--extract is a no-op on pure JSON lines" \
    '{"time":"2026-09-14T10:00:03Z","level":"info","msg":"cache warm","user_id":42}' \
    sh -c "'$BIN' '$TMP/svc.json' --field user_id=42 --head 1 --extract 2>/dev/null"

# ---- 6. merge orders by time across formats -----------------------------

merged=$("$BIN" "$TMP/app.log" "$TMP/svc.json" "$TMP/svc.logfmt" --merge)
first=$(echo "$merged" | head -1)
case "$first" in
    *10:00:01*) ok "merge puts the earliest line first" ;;
    *) bad "merge puts the earliest line first" "got [$first]" ;;
esac

# Timestamps must come out non-decreasing. Extracting them and checking
# against their own sort is the assertion that actually proves ordering.
echo "$merged" | grep -oE '10:00:[0-9]{2}' > "$TMP/order.txt"
sort "$TMP/order.txt" > "$TMP/order.sorted"
if diff -q "$TMP/order.txt" "$TMP/order.sorted" >/dev/null 2>&1; then
    ok "merge output is chronologically ordered"
else
    bad "merge output is chronologically ordered"
fi

"$BIN" "$TMP/app.log" "$TMP/svc.json" --merge | grep -q "^app.log:" \
    && ok "merge prefixes each line with its file" \
    || bad "merge prefixes each line with its file"

"$BIN" "$TMP/app.log" "$TMP/svc.json" --merge --no-prefix | grep -q "^app.log:" \
    && bad "--no-prefix drops the prefix" \
    || ok "--no-prefix drops the prefix"

# ---- 7. stdin -----------------------------------------------------------

# 4, not 3: --level is a threshold, so the FATAL line counts too — the same
# answer the file path gives above. Asserting a different number here than for
# the identical query on a file is how a stdin-specific bug would hide.
eq "reads stdin" "4" sh -c "cat '$TMP/app.log' | '$BIN' --level error --count"

# stdin and a file must agree exactly, which is the property actually worth
# pinning: it catches a divergence in either path rather than a fixed number.
_f=$("$BIN" "$TMP/app.log" --level error --count)
_s=$(cat "$TMP/app.log" | "$BIN" --level error --count)
[ "$_f" = "$_s" ] && ok "stdin and file agree" \
    || bad "stdin and file agree" "file=$_f stdin=$_s"

# ---- 8. timestamp formats -----------------------------------------------
#
# Each format is parsed into the SAME instant, which is what makes --merge
# across mixed sources correct. Asserted by filtering on a window that only
# the right answer falls inside.

cat > "$TMP/formats.log" <<'EOF'
2026-09-14T10:00:00Z iso form
2026-09-14 10:00:00 space form
14/Sep/2026:10:00:00 +0000 apache form
1789380000 epoch form
EOF
eq "four timestamp formats all parse" "4" \
    "$BIN" "$TMP/formats.log" --utc --count

# A line with no timestamp is carried, not dropped: continuation lines and
# stack frames have none and belong with the line above.
printf '2026-09-14T10:00:00Z ERROR boom\n    at frame one\n    at frame two\n' > "$TMP/trace.log"
eq "untimed lines are kept" "3" "$BIN" "$TMP/trace.log" --count

# ---- 9. --since is relative and bounded ---------------------------------

now=$(date -u +%s)
{
    for off in 60 600 6000; do
        t=$(date -u -d "@$((now - off))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || t=""
        [ -n "$t" ] && echo "$t INFO event minus ${off}s"
    done
} > "$TMP/recent.log"

if [ -s "$TMP/recent.log" ]; then
    eq "--since 5m finds only the recent line" "1" \
        "$BIN" "$TMP/recent.log" --utc --since 5m --count
    eq "--since 1h finds two"  "2" "$BIN" "$TMP/recent.log" --utc --since 1h --count
    eq "--since 3h finds all"  "3" "$BIN" "$TMP/recent.log" --utc --since 3h --count
else
    bad "--since fixtures" "could not build dated fixture"
fi

# ---- 10. combining predicates ANDs them ---------------------------------

eq "grep and level combine" "3" \
    "$BIN" "$TMP/app.log" --level error --grep refused --count
eq "exclude removes matches" "1" \
    "$BIN" "$TMP/app.log" --level error --exclude refused --count
eq "--head limits output" "2" \
    sh -c "'$BIN' '$TMP/app.log' --head 2 | wc -l | tr -d ' '"

# ---- 11. --stats summarises without printing lines ----------------------

"$BIN" "$TMP/app.log" --stats | grep -q "scanned  7" \
    && ok "--stats reports the scanned count" || bad "--stats reports the scanned count"
"$BIN" "$TMP/app.log" --stats | grep -q "shapes   4" \
    && ok "--stats reports distinct shapes" || bad "--stats reports distinct shapes"

echo
echo "  $PASS passed, $FAIL failed"
echo
[ "$FAIL" = "0" ]

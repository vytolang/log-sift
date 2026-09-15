# log-sift

One query interface over whatever format the log happens to be in.

```sh
log-sift app.log --dedupe          # collapse the noise
log-sift app.log --level error --since 1h
log-sift *.log --merge             # interleave by timestamp
```

JSON lines, logfmt and plain text are recognised automatically. You do not
tell it the format and you do not write a different query per file.

## The point: --dedupe

Real logs are the same few events repeated thousands of times, each copy
carrying a different id, duration or address. `sort | uniq -c` finds nothing,
because no two lines are identical.

`--dedupe` collapses by **shape** — the line with its varying tokens replaced:

```
  x3  2026-09-14T10:00:05Z ERROR connection refused: db:5432  [13:00:05-13:00:07]
  x3  2026-09-14T10:00:10Z WARN  slow query 1240ms user=99  [13:00:10-13:00:12]
  x3  2026-09-14T10:00:20Z INFO  GET /users/8821 200 in 43ms  [13:00:20-13:00:22]
   1  2026-09-14T10:00:01Z INFO  starting server on port 8080
   1  2026-09-14T10:00:02Z INFO  connected to db at 10.0.0.5
   1  2026-09-14T10:00:30Z FATAL out of memory
```

What is printed is a **real line from the log**, not a synthesised pattern
with placeholders in it, so you can copy it and search for it. The bracketed
window is what turns a count into a diagnosis: 4,000 in two seconds is a
storm, 4,000 across a day is background noise.

Measured on a 500,000-line, 28 MB log with five underlying event types:

| | time | peak RSS | answer |
|---|---|---|---|
| `log-sift --dedupe` | 1.2 s | 104 MB | the 5 real shapes, 100,000 each |
| `sort \| uniq -c \| sort -rn` | 2.0 s | 78 MB | top hit "10" — useless |

The exact-match pipeline is slower *and* cannot see past the timestamp.

Numbers, IPv4 addresses, UUIDs, hex blobs and embedded timestamps are each
recognised as one token. Digits inside an identifier are not: `route42` and
`route43` stay separate, because they are different routes.

## Install

### From source

Needs the [Vyto compiler](https://github.com/vytolang/vyto). Vyto compiles to
C and shells out to a host C compiler, so there is no other toolchain.

```sh
git clone https://github.com/vytolang/log-sift
cd log-sift
make && make install          # -> ~/.local/bin
```

`make` finds `vytoc` on your `PATH`, or via `$VYTO_HOME`, or you can point at
a checkout: `make VYTO_ROOT=/path/to/vyto`. `PREFIX` and `DESTDIR` work as
usual.

**A package root contains packages**, so this has to sit inside one — `make`
derives the root as the parent directory.

## Use

### Filter

```sh
log-sift app.log --level error       # error and above — it is a threshold
log-sift app.log --level-only warn   # exactly warn
log-sift app.log --since 30m --until 5m
log-sift app.log --grep timeout -i
log-sift app.log --exclude healthcheck
```

Durations are relative only: `30m`, `2h`, `1d`, `1w`. Absolute times are
deliberately not accepted — `--since 10:30` is ambiguous about the day and the
zone in a way that silently produces the wrong window.

### Query fields

```sh
log-sift svc.json   --field user_id=42
log-sift svc.logfmt --field worker=3 --field level=error
log-sift svc.json   --field request_id='*'      # key present, any value
```

Works on JSON lines and logfmt. Nested objects are not addressable —
`user.id` will not resolve.

### Logs that are text wrapped around JSON

Monolog, Laravel, Rails and Python's `logging` all write a human prefix
followed by a JSON context blob:

```
[2026-05-20 12:04:53] app.INFO: Received payment callback from IP: ::1 {"txnId":"TXN-007","amount":"1000","status":"confirmed"}
```

Those lines are text *and* structured at once. `--field` reads into the
payload, and `--extract` prints the payload alone:

```sh
log-sift app.log --field txnId=TXN-007        # finds it
log-sift app.log --field txnId='*' --extract  # just the JSON
```

```json
{"txnId":"TXN-007","amount":"1000","status":"confirmed"}
```

which pipes straight into `jq`, `python -m json.tool`, or a database loader.

The payload is the trailing object that **closes at the end of the line**, so
braces in the prefix are not mistaken for it — a PHP `{closure}`, a
`{placeholder}`, a brace in prose — and neither is a `}` inside a quoted
value. Lines with no payload are skipped by `--extract` rather than printed
raw, since one prose line in the middle breaks whatever consumes the stream;
the number skipped is reported on **stderr**, so it never lands in the data.

### Merge

```sh
log-sift app.log svc.json worker.logfmt --merge
```

Interleaves by timestamp across formats, prefixing each line with its file.
Mixed zones normalise, because every format is parsed to an instant before
anything is compared.

A line with no timestamp inherits the previous line's, so a stack trace stays
attached to the error that produced it instead of being sorted to the front.

### Summarise

```sh
log-sift app.log --stats
```

```
files    1
scanned  12
matched  12

FATAL    1
ERROR    3
WARN     3
INFO     5

span     13:00:01 - 13:00:30

shapes   6 distinct (--dedupe to collapse)
```

## Exit status

Follows grep's convention, so scripts can branch without parsing output:

| | |
|---|---|
| `0` | matched something |
| `1` | read fine, matched nothing |
| `2` | could not read, or the query was malformed |

```sh
if log-sift app.log --level fatal --since 5m -c >/dev/null; then
    page_someone
fi
```

## What it is not

**It is not a faster grep.** Measured on the same 500,000-line file, `grep -c
ERROR` takes 0.01 s against log-sift's 0.65 s — roughly 65× — because grep
runs Boyer-Moore over a mapped file while log-sift parses a timestamp,
determines a level and locates any JSON payload on every line. If a substring
is all you need, use grep.

Reach for this when you want shape collapsing, cross-format merging, or a
field query — the things grep structurally cannot do.

## Timestamp formats

Recognised at the start of a line, or from a `time`/`ts`/`@timestamp` field in
structured logs:

| | |
|---|---|
| ISO 8601 | `2026-09-14T10:23:01Z`, `+02:00`, fractional seconds |
| date-time | `2026-09-14 10:23:01` |
| syslog | `Sep 14 10:23:01` |
| Apache/nginx | `14/Sep/2026:10:23:01 +0000` |
| epoch | `1789381381` |

syslog omits the year, which is its enduring design mistake. The year is taken
from the file's mtime, so a rotated log keeps its real year rather than being
stamped with today's; a December line read in January is dated to the old year
rather than eleven months ahead.

Zone-less timestamps are read as local time. `--utc` changes that, which is
what you want for a log shipped from another machine.

## Tests

```sh
make test
```

55 checks over fixtures the suite writes itself, so results never depend on
what is in `/var/log`. The dedupe cases assert in **both** directions —
collapsing too little and collapsing too much are different bugs and a count
alone cannot tell them apart.

The shape-boundary rule, the merge ordering and the payload scanner were each
fault-injected to confirm the suite fails when they break. Two of those found
a weak test rather than a weak implementation:

- The first merge assertion passed with sorting **disabled entirely**, because
  it only checked the first line. It now compares the whole timestamp sequence
  against its own sort.
- The payload scanner's direction turned out not to matter. Requiring the
  object to close at end-of-line means at most one offset per line can
  qualify, so scanning from either end gives the same answer — verified by
  running the suite with the loop reversed. The comment that claimed otherwise
  was corrected rather than left standing.

## Licence

MIT.

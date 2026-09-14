/* log-sift — the two things the Vyto builtins do not cover.
 *
 * Both are about stdin, which has no binding in the standard library: there
 * is no way to read it and no way to ask whether it is a terminal.  Without
 * the second, `log-sift` with no arguments either blocks forever on a
 * terminal or refuses to work in a pipe; it has to be able to tell.
 */

#include <stdio.h>
#include <string.h>

#ifndef _WIN32
#include <unistd.h>
#endif

/* Read all of stdin into `buf`, NUL-terminated.  Returns the byte count.
 *
 * Stops at `cap - 1` bytes rather than growing: this is a filter, and a
 * stream bigger than the cap is a file the caller should have named directly
 * so it can be read without buffering.  Truncating loudly is not possible
 * here -- the caller compares the result against the cap to notice. */
int ls_read_stdin(char *buf, int cap) {
    if (!buf || cap <= 1) return 0;
    size_t total = 0;
    size_t want = (size_t)cap - 1;
    while (total < want) {
        size_t n = fread(buf + total, 1, want - total, stdin);
        if (n == 0) break;
        total += n;
    }
    buf[total] = '\0';
    return (int)total;
}

int ls_stdin_isatty(void) {
#ifdef _WIN32
    return 0;
#else
    return isatty(STDIN_FILENO) ? 1 : 0;
#endif
}

/* Flush stdout.
 *
 * stdout is block-buffered whenever it is not a terminal, so a --follow
 * stream piped into anything else emits nothing until the buffer fills, and
 * a follow is normally ended by a signal that discards it. */
void ls_flush(void) { fflush(stdout); }

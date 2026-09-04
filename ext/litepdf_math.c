// Math rendering glue: converts a LaTeX expression to UTF-8 text art
// using the optional GPL-3 libtexprintf (ext/libtexprintf). Compiled
// unconditionally; without WITH_TEXMATH the conversion reports
// "unsupported" and callers fall back to their own styling.
//
// texstring mutates the expression in place while scanning, so the
// conversion always works on a writable copy — never on the buffer the
// caller owns.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef WITH_TEXMATH
#include "texprintf.h"
#endif

char* litepdf_render_math(const char* latex)
{
#ifdef WITH_TEXMATH
    static int root_font_done = 0;
    if (!latex || !*latex)
    {
        return NULL;
    }
    if (!root_font_done)
    {
        /* Plain text letters: the embedded mono fonts lack the plane-1
         * math alphanumeric codepoints that the mathnormal style
         * emits. */
        SetRootFont("text");
        root_font_done = 1;
    }
    char* copy = strdup(latex);
    if (!copy)
    {
        return NULL;
    }
    char* art = texstring(copy);
    free(copy);
    if (!art || texerror_state() != 0)
    {
        if (art)
        {
            texfree(art);
        }
        return NULL;
    }
    /* Hand over a buffer the caller can release with plain free. */
    char* out = strdup(art);
    texfree(art);
    return out;
#else
    (void)latex;
    return NULL;
#endif
}

void litepdf_free(void* ptr)
{
    free(ptr);
}

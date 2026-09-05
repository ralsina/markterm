# Hyphenation pattern data

Plain TeX pattern files from the `hyph-utf8` collection
(https://github.com/hyphenation/tex-hyphen), fetched from
`hyph-utf8/tex/generic/hyph-utf8/patterns/txt/`. The `.pat.txt`
files hold the patterns, the `.hyp.txt` files hold exceptions
(words whose only allowed breaks are the ones written in the file,
or no breaks at all).

The shard embeds these files at compile time (`{{ read_file }}`),
so the compiled binary needs no data files at runtime.

## hyph-en-us

- Source: `patterns/txt/hyph-en-us.pat.txt` and `hyph-en-us.hyp.txt`
- Version: 2005-05-30 (ushyphmax)
- Author: Gerard D.C. Kuiken
- Licence (verbatim from `hyph-en-us.tex`):

  > Copyright (C) 1990, 2004, 2005 Gerard D.C. Kuiken
  >
  > Copying and distribution of this file, with or without modification,
  > are permitted in any medium without royalty provided the copyright
  > notice and this notice are preserved.

- Minimum fragment lengths: 2 before the first break, 3 after the last.

## hyph-es

- Source: `patterns/txt/hyph-es.pat.txt` (the collection ships no
  Spanish exceptions file)
- Version: 5.0 2019-09-24
- Author: Javier Bezos, CervanTeX
- Licence: MIT/X11, copyright (C) 1993, 1997, 2001-2019 Javier Bezos,
  CervanTeX (full text in `hyph-es.tex` in the collection above).
- Minimum fragment lengths: 2 before the first break, 2 after the last.

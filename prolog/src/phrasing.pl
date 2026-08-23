:- module(phrasing, [plural/3, agree/4, quantity/3, article/3,
                     listed/2, listed_and/2, segments_phrase/2, segments_phrase/3]).

/** <module> The small amount of English every rule module needs.

    The rules write their own messages and check details, right next to the
    arithmetic they describe. That meant the same few phrases were rewritten in
    every file, and the count and the noun were formatted separately often
    enough that "1 international departures" reached the report more than once.
    So the phrases live here instead. Nothing in this module knows anything
    about the fare.

    Rule of thumb: a message that needs a number and a noun together wants
    quantity/3, not plural/3 plus its own format string.
*/

%! plural(+N, +Word, -Form) is det.
%  Adds a regular -s and nothing more. Anything harder is agree/4's job.
plural(1, Word, Word) :- !.
plural(_, Word, Plural) :- atom_concat(Word, s, Plural).

%! agree(+N, +Singular, +Plural, -Form) is det.
%  Agreement that an -s cannot handle: is/are, it/them, this/these. Both forms
%  are written out rather than worked out, because the alternative is a table of
%  English irregulars that this program has no business owning.
agree(1, Singular, _, Singular) :- !.
agree(_, _, Plural, Plural).

%! quantity(+N, +Word, -Atom) is det.
%  "1 stopover", "3 stopovers". The count and the noun are formatted together
%  for one reason: so they cannot disagree.
quantity(N, Word, Atom) :-
    plural(N, Word, Form),
    format(atom(Atom), '~w ~w', [N, Form]).

%! article(+Word, +Case, -Atom) is det.
%  "a Business fare", "an Economy fare". Case is `lower` or `upper`, depending
%  on whether the phrase starts a sentence.
%
%  The test looks at the first letter, not the first sound. That is the wrong
%  rule for English in general and the right one for every word this program
%  puts after an article: cabin names, continent names, and the words `error`
%  and `airport`. Going by sound would need a pronunciation table, which this
%  program has no business owning -- the same call made about irregular plurals
%  in agree/4.
article(Word, Case, Phrase) :-
    sub_atom(Word, 0, 1, _, First),
    downcase_atom(First, Lower),
    (   memberchk(Lower, [a, e, i, o, u]) -> Article0 = an ; Article0 = a ),
    (   Case == upper
    ->  upcase_first(Article0, Article)
    ;   Article = Article0
    ),
    format(atom(Phrase), '~w ~w', [Article, Word]).

upcase_first(a,  'A').
upcase_first(an, 'An').

%! listed(+Items, -Atom) is det.
%  A comma-separated list, or `none` when there is nothing in it. Printing `[]`
%  inside a sentence reads as a missing value rather than an empty set.
listed([], none) :- !.
listed(Items, Atom) :- atomic_list_concat(Items, ', ', Atom).

%! listed_and(+Items, -Atom) is det.
%  The same list written out in English: "A", "A and B", "A, B and C". Prose
%  wants this one; a field of comma-separated values wants listed/2.
listed_and([], none) :- !.
listed_and([One], One) :- !.
listed_and(Items, Atom) :-
    append(Front, [Last], Items),
    atomic_list_concat(Front, ', ', Head),
    format(atom(Atom), '~w and ~w', [Head, Last]).

%! segments_phrase(+Numbers, -Atom) is det.
%  "segment 4", "segments 4 and 9".
segments_phrase(Ns, Atom) :- segments_phrase(Ns, lower, Atom).

%! segments_phrase(+Numbers, +Case, -Atom) is det.
%  Case is `lower` or `upper`, depending on whether the phrase starts a
%  sentence. A message that opens with the segments it is about wants `upper`.
%  Enough messages do that capitalising by hand at each one had started to go
%  wrong.
segments_phrase(Ns, Case, Atom) :-
    length(Ns, Count),
    ( Case == upper -> Stem = 'Segment' ; Stem = 'segment' ),
    plural(Count, Stem, Word),
    listed_and(Ns, List),
    format(atom(Atom), '~w ~w', [Word, List]).

:- module(r00_continents, []).

/** <module> Section 0 -- continent count and fare basis.

    Mostly information, with one hard constraint. The fare basis table starts at
    three continents, so an itinerary that touches fewer than three has no
    published fare and cannot be a oneworld Explorer at all.
*/

:- use_module('../annotate').
:- use_module('../pricing').
:- use_module('../phrasing').
:- use_module('../../data/limits').

:- multifile validate:violation/2.
:- multifile validate:check/2.

validate:check(A, chk(continent_count, '0', 'Continent count', Detail,
                      [too_few_continents, via_asia_counted])) :-
    continent_count(A, Continents, N),
    limit(min_continents, Min),
    quantity(N, 'continent', Count),
    maplist(continent_name, Continents, Named),
    listed_and(Named, List),
    format(atom(Detail),
           'The journey visits ~w: ~w. The fare needs at least ~w.',
           [Count, List, Min]).

validate:violation(A, v(too_few_continents, '0', error, Msg,
                        [count(N), min(Min), continents(Cs)])) :-
    continent_count(A, Cs, N),
    limit(min_continents, Min),
    N < Min,
    quantity(N, 'continent', Visited),
    maplist(continent_name, Cs, Named),
    listed_and(Named, List),
    format(atom(Msg),
           'The journey visits only ~w: ~w. The fare needs at least ~w.',
           [Visited, List, Min]).

% There is no "too many continents" rule, on purpose. The fare table stops at
% six and the continent list has exactly six members, so no itinerary can go
% over. Such a rule could never fire, and would look like coverage it does not
% give. The real point it was reaching for is that the fare table must cover
% every count the geography can produce, and test/test_rules.pl asserts that,
% which is where it belongs.

% Section 0: a nonstop or surface sector between the South West Pacific and
% Europe/Middle East is priced as travel via Asia. That adds a continent the
% itinerary never lands in. Saying so out loud stops the continent count looking
% like a mistake to the reader.
validate:violation(A, v(via_asia_counted, '0', warning, Msg, [segments([N])])) :-
    via_asia_sector(A, N),
    format(atom(Msg),
           'Segment ~w runs directly between the South West Pacific and Europe/Middle East, which is priced as travel via Asia; Asia is counted as a continent for the fare basis.',
           [N]).

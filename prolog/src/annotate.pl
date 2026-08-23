:- module(annotate,
          [ annotate/2,
            ann_seg/2,
            ann_flight/4,
            ann_point/2,
            ann_visits/2,
            ann_segment_count/2,
            od_surface_gap/1,
            ann_airport/2,
            collapse/2
          ]).

/** <module> The derived-facts pass.

    annotate/2 runs once, before any rule, and adds to the raw itinerary
    everything the rules need: continents, traffic conferences, ocean crossings,
    and whether each intermediate point is a stopover or a transfer. Without it,
    some twenty-five rules would each work out the same geography again. With
    it, most rule bodies are two or three goals long.

    It is eager and pure. It returns a term, asserts nothing and tables nothing,
    which is what makes the validator safe to call from several HTTP worker
    threads at once.
*/

:- use_module(geo).
:- use_module(itinerary).
:- use_module('../data/limits').

%! annotate(+Itin, -A) is det.
annotate(Itin, A) :-
    maplist(annotate_segment, Itin.segments, Segs),
    points(Segs, Points),
    continent_sequence(Segs, Continents),
    tc_sequence(Segs, TCs),
    visited_set(Segs, Visited),
    A = ann{ origin: Itin.origin,
             cabin: Itin.cabin,
             passengers: Itin.passengers,
             members: Itin.members,
             mode: Itin.mode,
             input_errors: Itin.errors,
             segments: Segs,
             points: Points,
             continents: Continents,
             tcs: TCs,
             visited: Visited }.

% --- per segment -----------------------------------------------------------

annotate_segment(S, A) :-
    From = S.from, To = S.to,
    geo_of(From, FC, FR, FCont, FZone, FTc),
    geo_of(To,   TC, TR, TCont, TZone, TTc),
    (   ocean_of(FTc, TTc, Ocean) -> true ; Ocean = unknown ),
    intercontinental(FCont, TCont, Inter),
    international(FC, TC, From, To, Intl),
    A = aseg{ n: S.n, type: S.type, from: From, to: To,
              marketing: S.marketing, operating: S.operating, flight: S.flight,
              dep: S.dep, arr: S.arr, stop: S.stop,
              booking_class: S.booking_class,
              fare_family: S.fare_family,
              from_country: FC, to_country: TC,
              from_region: FR,  to_region: TR,
              from_cont: FCont, to_cont: TCont,
              from_zone: FZone, to_zone: TZone,
              from_tc: FTc,     to_tc: TTc,
              intercontinental: Inter,
              international: Intl,
              ocean: Ocean }.

% An airport we cannot resolve gives `unknown` fields instead of failing, so an
% itinerary with one bad code still gets validated everywhere else. Every rule
% that reads a geography field insists on a real value first.
geo_of(A, Country, Region, Cont, Zone, TC) :-
    (   airport_known(A)
    ->  airport_country(A, Country),
        airport_region(A, Region),
        airport_continent(A, Cont),
        (   airport_zone(A, Zone) -> true ; Zone = none ),
        (   airport_tc(A, TC) -> true ; TC = unknown )
    ;   Country = unknown, Region = unknown, Cont = unknown,
        Zone = unknown, TC = unknown
    ).

ocean_of(FTc, TTc, Ocean) :-
    FTc \== unknown, TTc \== unknown,
    (   tc_ocean(FTc, TTc) -> ocean_name(FTc, TTc, Ocean) ; Ocean = none ).

tc_ocean(F, T) :- ocean_name(F, T, _).
ocean_name(tc1, tc2, atlantic).
ocean_name(tc2, tc1, atlantic).
ocean_name(tc1, tc3, pacific).
ocean_name(tc3, tc1, pacific).

intercontinental(F, T, unknown) :- ( F == unknown ; T == unknown ), !.
intercontinental(F, F, false) :- !.
intercontinental(_, _, true).

% 4(f) NOTE: travel between the USA and Canada is not counted as international.
international(FC, TC, _, _, unknown) :- ( FC == unknown ; TC == unknown ), !.
international(C, C, _, _, false) :- !.
international(_, _, From, To, false) :- domestic_us_canada(From, To), !.
international(_, _, _, _, true).

% --- intermediate points ---------------------------------------------------

% There is a point between each pair of consecutive segments. The origin
% (before segment 1) and the final arrival (after segment N) are not
% intermediate points, so they can never be stopovers.
points(Segs, Points) :-
    findall(P, point(Segs, P), Points).

point(Segs, Pt) :-
    append(_, [A, B|_], Segs),
    Airport = A.to,
    ground_minutes(A, B, Mins),
    surface_adjacent(A, B, Surface),
    derived_kind(A, B, Airport, Mins, Surface, Derived),
    declared_kind(A, Declared),
    effective_kind(Surface, Declared, Derived, Kind),
    Pt = pt{ after: A.n, airport: Airport, continent: A.to_cont,
             ground_minutes: Mins, kind: Kind,
             declared: Declared, derived: Derived, surface: Surface }.

ground_minutes(A, B, Mins) :-
    (   dt_minutes_between(A.arr, B.dep, M)
    ->  Mins = M
    ;   Mins = unknown
    ).

surface_adjacent(A, B, Surface) :-
    (   ( A.type == surface ; B.type == surface )
    ->  Surface = true
    ;   Surface = false
    ).

%! declared_kind(+ArrivingSegment, -Kind) is det.
%  What the traveller said about the point this segment arrives at: either the
%  `X/` of fare-construction notation, or a JSON segment's `stop` field.
declared_kind(A, Kind) :-
    (   stop_kind(A.stop)
    ->  Kind = A.stop
    ;   Kind = unknown
    ).

% Rule 3015 never says what separates a stopover from a transfer, so this is our
% convention:
%
%   * A point next to a surface sector is a stopover. Surface travel is at the
%     passenger's expense (4(g)) and breaks the flown journey.
%   * Otherwise, more than 24 hours on the ground. The limit drops to 4 hours
%     when both neighbouring sectors are domestic within the USA or Canada.
%   * With no timestamps the answer is `indeterminate`. That carries through to
%     rule 8 as an `indeterminate` violation rather than a quiet pass.
%
% Both thresholds live in data/limits.pl, where they can be audited.
derived_kind(_, _, _, _, true, stopover) :- !.
derived_kind(_, _, _, unknown, _, indeterminate) :- !.
derived_kind(A, B, Airport, Mins, _, Kind) :-
    threshold_hours(A, B, Airport, Hours),
    Limit is Hours * 60,
    ( Mins > Limit -> Kind = stopover ; Kind = transfer ).

%! effective_kind(+Surface, +Declared, +Derived, -Kind) is det.
%
%  A declaration beats the clock. The traveller knows what was booked, and a
%  routing-only itinerary has no clock to read anyway. A declaration does not
%  beat a surface sector: 4(g) surface travel is at the passenger's own expense
%  and breaks the flown journey whatever anyone calls it. When the two disagree,
%  rule 8 reports the disagreement rather than settling it quietly.
effective_kind(true, _, Derived, Derived) :- !.
effective_kind(_, unknown, Derived, Derived) :- !.
effective_kind(_, Declared, _, Declared).

threshold_hours(A, B, Airport, Hours) :-
    (   airport_country(Airport, C), memberchk(C, ['US', 'CA']),
        A.international == false,
        B.international == false
    ->  limit(stopover_hours_domestic_us_ca, Hours)
    ;   limit(stopover_hours_international, Hours)
    ).

% --- itinerary-level sequences ---------------------------------------------

continent_sequence(Segs, Seq) :-
    raw_sequence(Segs, from_cont, to_cont, Raw),
    collapse(Raw, Seq).

tc_sequence(Segs, Seq) :-
    raw_sequence(Segs, from_tc, to_tc, Raw),
    collapse(Raw, Seq).

raw_sequence([], _, _, []) :- !.
raw_sequence(Segs, FromKey, ToKey, Raw) :-
    findall(V, ( member(S, Segs), get_dict(FromKey, S, V) ), Froms),
    last(Segs, Last),
    get_dict(ToKey, Last, End),
    append(Froms, [End], Raw).

%! collapse(+List, -Collapsed) is det.
%  Drops repeats that sit next to each other. This is what turns a 12-segment
%  itinerary into the short traffic-conference cycle that 4(a), 4(b) and 4(c)
%  are checked against.
collapse([], []).
collapse([X], [X]) :- !.
collapse([X, X|T], R) :- !, collapse([X|T], R).
collapse([X|T], [X|R]) :- collapse(T, R).

visited_set(Segs, Visited) :-
    findall(C, ( member(S, Segs),
                 ( C = S.from_cont ; C = S.to_cont ),
                 C \== unknown ),
            Cs),
    sort(Cs, Visited).

% --- accessors used by rule modules ----------------------------------------

ann_seg(A, S) :- member(S, A.segments).

%! ann_flight(+A, -N, -From, -To) is nondet.
%  Flight segments only. Surface sectors are left out because 4(i) and the 4(h)
%  free-segment caps are about flights.
ann_flight(A, N, From, To) :-
    ann_seg(A, S),
    S.type == flight,
    N = S.n, From = S.from, To = S.to.

ann_point(A, P) :- member(P, A.points).

%! ann_airport(+A, -Airport) is nondet.
%  Each distinct point of the journey, once. A rule that asks "does the
%  itinerary include X" must use this instead of walking the segments.
%  Otherwise an airport that is both an arrival and the next departure reports
%  its violation twice.
ann_airport(A, Airport) :-
    findall(P, ( ann_seg(A, S), ( P = S.from ; P = S.to ) ), Ps),
    sort(Ps, Distinct),
    member(Airport, Distinct).

ann_visits(A, C) :- memberchk(C, A.visited).

%! ann_segment_count(+A, -N) is det.
%  Every segment the itinerary lists, and nothing else. The origin-destination
%  gap is *not* counted, even though 4(h) says "including surface segments
%  between any 2 airports" and the gap does sit between 2 airports.
%
%  It was counted here for a while, on that reading. What settles it the other
%  way is the price of that reading. 4(c) lets the journey end away from the
%  origin, and neither 4(c) nor 4(h) says that taking the permission also costs
%  a segment. Counting the gap would cap an open-jaw journey at 15 flights while
%  a closed loop gets 16 -- a real penalty pulled out of a clause that never
%  mentions open jaws. The surface segments 4(h) is talking about are 4(g)'s
%  intermediate ones, which are sectors of the journey. The gap is the part of
%  the world the ticket deliberately leaves out.
%
%  Real tickets agree. A 16-flight CAI-...-DOH with a 4(c)(b) Middle East open
%  jaw prices, and it could not if the gap counted.
%
%  The gap is still reported, by r04's free-segment check and od_gap_clause/2,
%  because a traveller reading a count of 16 should be able to see which 16.
%
%  Two airports of one metropolitan city count as one point, so LHR out and LGW
%  back is not a gap. See geo:place_key/2.
ann_segment_count(A, N) :-
    length(A.segments, N).

%! od_surface_gap(+A) is semidet.
od_surface_gap(A) :-
    A.segments \== [],
    A.origin \== unknown,
    last(A.segments, Last),
    \+ same_place(Last.to, A.origin).

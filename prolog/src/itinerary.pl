:- module(itinerary,
          [ build_itinerary/7,
            itinerary_mode/1,
            stop_kind/1,
            dt_stamp/2,
            dt_iso/2,
            dt_words/2,
            dt_days_between/3,
            dt_minutes_between/3,
            dt_months_between/3,
            dt_plus_months/3,
            dt_beyond_months/3
          ]).

/** <module> Raw segment list -> canonical itinerary term.

    Two kinds of input problem are handled differently, on purpose:

      * Malformed input, such as something that is not an object or a date that
        will not parse, throws from the reader in io/json_in.pl and comes back
        as an HTTP 400.
      * Input that is well formed but cannot be resolved, such as an unknown
        IATA code, a gap between consecutive segments, or an arrival before its
        departure, becomes an ordinary `error` violation in the itinerary's
        `errors` field. The UI then shows it inline beside the rule violations.

    All times are local, and nothing here needs a timezone database. Ground time
    is the gap between an arrival and the next departure *at the same airport*,
    so subtracting two local timestamps is exactly right. Rules 6 and 7 do
    compare timestamps at different airports, but only by day and by month. So
    the stamps below are computed at a fixed zero UTC offset. The arithmetic
    stays deterministic and nothing pretends to know a real offset.
*/

:- use_module(geo).
:- use_module('../data/limits').

%! itinerary_mode(?Mode) is nondet.
%
%  `full` means the itinerary carries a calendar. Connections are classified
%  from timestamps, and rules 6 and 7 apply. `routing` means it does not: the
%  route and the declared stop kinds are all there is. Rules 6 and 7 then have
%  nothing to measure and are reported as not checked rather than undecidable.
%  See validate.pl for why that difference is not a quiet pass.
itinerary_mode(full).
itinerary_mode(routing).

%! stop_kind(?Kind) is nondet.
%  What a traveller can say about an intermediate point, with no timestamps
%  involved. `transfer` is the `X/` of fare-construction notation.
stop_kind(transfer).
stop_kind(stopover).

%! build_itinerary(+Origin, +Cabin, +Passengers, +Members, +Mode, +RawSegs, -Itin) is det.
%
%  Origin may be `unknown`, in which case it comes from the first segment.
%  RawSegs is a list of rseg(N, Type, From, To, Marketing, Operating, Flight,
%  Dep, Arr, Stop, BookingClass, FareFamily). Every field except Type, From and
%  To may be `unknown`. Stop says what kind of point the segment *arrives* at.
%  BookingClass is the 5(b) RBD the segment is sold in. FareFamily is the
%  carrier's branded fare, which only the earning side reads.
build_itinerary(Origin0, Cabin, Passengers, Members, Mode, RawSegs, Itin) :-
    number_segments(RawSegs, 1, Segs, NumErrs),
    resolve_origin(Origin0, Segs, Origin, OriginErrs),
    maplist(segment_errors, Segs, SegErrsL),
    continuity_errors(Segs, ContErrs),
    append([NumErrs, OriginErrs, ContErrs | SegErrsL], Errors0),
    sort(Errors0, Errors),
    Itin = itin{ origin: Origin,
                 cabin: Cabin,
                 passengers: Passengers,
                 members: Members,
                 mode: Mode,
                 segments: Segs,
                 errors: Errors }.

% Position in the list is what counts. An `n` that disagrees with it is reported
% rather than quietly obeyed, because renumbering the itinerary would make every
% later violation cite the wrong segment.
number_segments([], _, [], []).
number_segments([R|Rs], I, [S|Ss], Errs) :-
    R = rseg(N, Type, From0, To0, Mkt, Op, Flt, Dep, Arr, Stop, Class, Family),
    place(From0, From),
    place(To0, To),
    S = seg{ n: I, type: Type, from: From, to: To,
             marketing: Mkt, operating: Op, flight: Flt,
             dep: Dep, arr: Arr, stop: Stop,
             booking_class: Class, fare_family: Family },
    (   ( N == unknown ; N == I )
    ->  Errs = Errs1
    ;   format(atom(M),
               'Segment listed in position ~w carries number ~w; segments must be numbered consecutively from 1.',
               [I, N]),
        Errs = [v(input_error, input, error, M, [segments([I]), given(N)])|Errs1]
    ),
    I1 is I + 1,
    number_segments(Rs, I1, Ss, Errs1).

% From here on, a metropolitan city code stands for its representative airport.
% So `NYC` and `JFK` are one place to 4(i) and to the geography.
place(Given, Place) :-
    downcase_atom(Given, Lower),
    resolve_place(Lower, Place).

resolve_origin(unknown, [S|_], Origin, []) :- !, Origin = S.from.
resolve_origin(unknown, [], unknown, []) :- !.
% Compared as places, not as codes. Fares are written in city codes -- see
% data/cities.pl -- so `LON` against a segment leaving LGW is the normal way to
% state an origin, not a contradiction. 4(c), 4(d) and 4(i) all ask "is this the
% same point?" through same_place/2, so an origin that did not would be the one
% spot in the program where LHR and LGW are two places.
%
% Getting this wrong costs more than one wrong message. A single input error
% withholds the whole check register (see validate.pl), so a routing written the
% way fares are written would come back with nothing measured at all.
resolve_origin(Given0, Segs, Origin, Errs) :-
    place(Given0, Declared),
    (   Segs = [S|_]
    ->  (   same_place(S.from, Declared)
        %  Keep the itinerary's own departure point rather than the
        %  representative airport the code resolved to. That way nothing
        %  downstream -- a message, the map, the annotations -- names an airport
        %  the traveller never used.
        ->  Origin = S.from, Errs = []
        ;   Origin = Declared,
            origin_mismatch(Given0, S.from, Err),
            Errs = [Err]
        )
    ;   Origin = Declared, Errs = []
    ).

% Report the code the way it was given. Naming the resolved airport instead used
% to accuse the traveller of writing LHR when they had written LON.
origin_mismatch(Given, From, v(input_error, input, error, M,
                               [segments([1]), pair(UG-UF)])) :-
    iata(Given, UG),
    iata(From, UF),
    format(atom(M),
           'Declared origin ~w does not match the departure point of segment 1 (~w).',
           [UG, UF]).

segment_errors(S, Errs) :-
    findall(E, segment_error(S, E), Errs).

segment_error(S, v(input_error, input, error, M, [segments([N]), airport(U)])) :-
    N = S.n,
    (   A = S.from ; A = S.to ),
    \+ airport_known(A),
    iata(A, U),
    format(atom(M), 'Segment ~w references ~w, which is not a known airport with scheduled service.',
           [N, U]).
% These are local wall-clock times, so an eastbound trans-Pacific sector really
% does arrive at an earlier clock time than it left: NRT 17:00 arrives LAX 10:00
% on the same calendar day. Only a jump backwards wider than the whole span of
% world time zones (UTC+14 to UTC-12) has to be a data error rather than a date
% line crossing.
segment_error(S, v(input_error, input, error, M, [segments([N]), hours(Hours)])) :-
    N = S.n,
    dt_minutes_between(S.dep, S.arr, Minutes),
    limit(max_local_time_regression_hours, Max),
    Limit is -Max * 60,
    Minutes < Limit,
    Hours is truncate(-Minutes / 60),
    format(atom(M),
           'Segment ~w arrives ~w hours before it departs, which no time zone difference explains.',
           [N, Hours]).
segment_error(S, v(input_error, input, error, M, [segments([N]), airport(U)])) :-
    N = S.n,
    A = S.from,
    A == S.to,
    iata(A, U),
    format(atom(M), 'Segment ~w departs from and arrives at the same point (~w).', [N, U]).

% The journey has to be one connected chain. A surface sector between two
% airports is itself a segment, and 4(h) counts it, so a gap is always an error.
continuity_errors(Segs, Errs) :-
    findall(E, continuity_error(Segs, E), Errs).

continuity_error(Segs, v(input_error, input, error, M, [segments([I, J]), pair(UT-UF)])) :-
    append(_, [A, B|_], Segs),
    To = A.to, From = B.from,
    To \== From,
    I = A.n, J = B.n,
    iata(To, UT), iata(From, UF),
    format(atom(M),
           'Segment ~w arrives at ~w but segment ~w departs from ~w; the journey must be continuous (add a surface sector).',
           [I, UT, J, UF]).
% Time has to run forward across the join, not just place. Both stamps are read
% at the same airport, and so in the same time zone. That is what makes this
% comparison exact, and why it needs none of the date-line tolerance that
% segment_error/2 has to allow within a sector. It is also why the airports must
% match before the comparison is worth making: two clocks in unknown, different
% zones prove nothing, and that case is already the gap error above.
%
% Left unchecked, a negative ground time reaches derived_kind/6 in annotate.pl,
% which reads anything at or below the threshold as a transfer. Segments entered
% out of order would then be quietly reclassified instead of reported, and rule 8
% would count its stopovers from points the traveller never stopped at.
continuity_error(Segs, v(input_error, input, error, M,
                         [segments([I, J]), airport(U), minutes(Minutes)])) :-
    append(_, [A, B|_], Segs),
    A.to == B.from,
    dt_minutes_between(A.arr, B.dep, Raw),
    Raw < 0,
    Minutes is round(-Raw),
    I = A.n, J = B.n,
    iata(A.to, U),
    format(atom(M),
           'Segment ~w departs ~w before segment ~w has arrived there; the journey must run forward in time.',
           [J, U, I]).

% --- time helpers ----------------------------------------------------------

%! dt_stamp(+Dt, -Stamp) is semidet.
%  Fails for `unknown`. That is what carries a missing timestamp through to the
%  `indeterminate` severity instead of to a quiet pass.
dt_stamp(dt(Y, Mo, D, H, Mi), Stamp) :-
    date_time_stamp(date(Y, Mo, D, H, Mi, 0.0, 0, -, -), Stamp).

%! dt_iso(+Dt, -Atom) is det.
dt_iso(unknown, unknown) :- !.
dt_iso(dt(Y, Mo, D, H, Mi), A) :-
    format(atom(A), '~|~`0t~d~4+-~|~`0t~d~2+-~|~`0t~d~2+T~|~`0t~d~2+:~|~`0t~d~2+',
           [Y, Mo, D, H, Mi]).

%! dt_words(+Dt, -Atom) is det.
%  "1 September 2027". The ISO form is right for a field and wrong inside a
%  sentence, where the reader has to decode it before carrying on.
dt_words(unknown, unknown) :- !.
dt_words(dt(Y, Mo, D, _, _), A) :-
    month_name(Mo, Month),
    format(atom(A), '~d ~w ~d', [D, Month, Y]).

month_name(1,  'January').    month_name(2,  'February').
month_name(3,  'March').      month_name(4,  'April').
month_name(5,  'May').        month_name(6,  'June').
month_name(7,  'July').       month_name(8,  'August').
month_name(9,  'September').  month_name(10, 'October').
month_name(11, 'November').   month_name(12, 'December').

%! dt_minutes_between(+From, +To, -Minutes) is semidet.
dt_minutes_between(From, To, Minutes) :-
    dt_stamp(From, A),
    dt_stamp(To, B),
    Minutes is (B - A) / 60.

%! dt_days_between(+From, +To, -Days) is semidet.
dt_days_between(From, To, Days) :-
    dt_minutes_between(From, To, M),
    Days is M / 1440.

%! dt_months_between(+From, +To, -Months) is semidet.
%  Calendar months, not 30-day units. Rule 7's "12 months" is a calendar
%  period, so 1 Sep 2026 -> 1 Sep 2027 is exactly 12, and legal.
%
%  This truncates, so it answers "how many whole months?" and NOT "is the
%  deadline past?". 1 Sep 2026 -> 20 Sep 2027 is twelve whole months and
%  nineteen days over. Use dt_beyond_months/3 to test a limit; use this one to
%  say how long the journey ran.
dt_months_between(dt(Y1, M1, D1, H1, Mi1), dt(Y2, M2, D2, H2, Mi2), Months) :-
    Whole is (Y2 - Y1) * 12 + (M2 - M1),
    (   [D2, H2, Mi2] @< [D1, H1, Mi1]   % day-of-month has not come round yet
    ->  Months is Whole - 1
    ;   Months = Whole
    ).

%! dt_plus_months(+From, +N, -To) is det.
%  The same clock time N calendar months later. Where the target month is
%  shorter the day is clamped to its last one, so 31 Jan plus one month is
%  28 Feb, and 29 Feb plus twelve months is 28 Feb.
dt_plus_months(dt(Y, M, D, H, Mi), N, dt(Y2, M2, D2, H, Mi)) :-
    Total is Y * 12 + (M - 1) + N,
    Y2 is Total // 12,
    M2 is Total mod 12 + 1,
    days_in_month(Y2, M2, Last),
    D2 is min(D, Last).

days_in_month(Y, 2, Days) :- !, ( leap_year(Y) -> Days = 29 ; Days = 28 ).
days_in_month(_, M, 30) :- memberchk(M, [4, 6, 9, 11]), !.
days_in_month(_, _, 31).

leap_year(Y) :-
    0 is Y mod 4,
    (   0 is Y mod 100
    ->  0 is Y mod 400
    ;   true
    ).

%! dt_beyond_months(+From, +To, +N) is semidet.
%  True when To falls strictly after the N-month anniversary of From. This is
%  the test a calendar limit needs. Comparing truncated month counts instead
%  would let anything short of a thirteenth whole month through.
dt_beyond_months(From, To, N) :-
    dt_plus_months(From, N, Deadline),
    dt_minutes_between(Deadline, To, Minutes),
    Minutes > 0.

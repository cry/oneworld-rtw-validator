:- module(ops,
          [ rtw_do/3,
            rtw_render/5,
            known_op/1,
            input_dict/2,
            op_error_reply/3,
            op_failed_reply/2
          ]).

/** <module> The operations, once.

    Every front end that is not a person answers the same short list of named
    operations: a JSON dict in, a JSON dict out. `wasm.pl` had this table first,
    because the browser needs a way in that names an operation rather than a
    goal. `mcp.pl` needs exactly the same thing for exactly the same reason, and
    a second copy of it would be a second place for the two to disagree about
    what `earn` means.

    So the table lives here and both load it. Like `server.pl`, this file holds
    no rule logic: every predicate it calls is one the CLI calls too.

    This is a module, and it names the modules it uses rather than relying on
    `load.pl` having put them in `user`. `wasm.pl` and `mcp.pl` are not modules,
    for their own reasons; this file being one is what keeps those reasons from
    spreading.
*/

:- use_module('../data/booking_codes').
:- use_module(annotate).
:- use_module(validate).
:- use_module(pricing).
:- use_module(geo).
:- use_module(explain).
:- use_module('io/json_in').
:- use_module('io/json_out').
:- use_module('io/route_out').
:- use_module('io/earn_out').
:- use_module('earn/kernel').
:- use_module('earn/registry').
:- use_module('earn/explain').
:- use_module(library(apply)).
:- use_module(library(lists)).
:- use_module(library(yall)).

% SWI 10 moved JSON out of the HTTP package. `library(json)` does not exist on
% 9.x, and `library(http/json)` prints a deprecation notice on 10.x. Asking
% which one is present is the only way to stay quiet on both. cli.pl and wasm.pl
% ask the same question; the WebAssembly build has only the first, because the
% HTTP package is not part of it.
:- if(exists_source(library(json))).
:- use_module(library(json)).
:- else.
:- use_module(library(http/json)).
:- endif.

%! known_op(?Op) is nondet.
%  In the order a caller meets them: the three that answer a question about a
%  journey, then the two that describe the ruleset, then the lookup.
known_op(validate).
known_op(earn).
known_op(classes).
known_op(routing).
known_op(ruleset).
known_op(programs).
known_op(airports).

%! rtw_do(+Op, +In, -Out) is semidet.
%  In is JSON text or a dict; Out is a dict. Throws input_error(Message) for
%  anything the caller can fix. Failing rather than throwing is a bug, and the
%  front ends report it as one -- see op_failed_reply/2.
%
%  The unknown-operation case is decided here rather than in a last clause of
%  run_op/3, so that every clause below has a distinct atom in its first
%  argument and the call is indexed. A catch-all clause would leave a
%  choicepoint behind every successful operation.
rtw_do(Op, In, Out) :-
    (   known_op(Op)
    ->  run_op(Op, In, Out)
    ;   format(atom(M), 'There is no "~w" operation.', [Op]),
        throw(input_error(M))
    ).

run_op(validate, In, Out) :-
    validate_pipeline(In, _, Out).

% As on the server, this exists so a client never has to write a routing
% itself. Doing so would create a second definition of the grammar, and the
% only one with no test behind it.
run_op(routing, In, _{ route: Route }) :-
    input_dict(In, Dict),
    itinerary_from_json(Dict, Itin),
    annotate(Itin, A),
    (   annotated_route(A, Route)
    ->  true
    ;   no_routing_message(A, Message),
        throw(input_error(Message))
    ).

run_op(ruleset, _, Out) :-
    ruleset_json(Out).

% The earning side, which runs no fare rules. A journey that cannot be sold can
% still be priced, and a valid one can be unpriceable.
run_op(earn, In, Out) :-
    earn_pipeline(In, _, Out).

run_op(classes, In, Out) :-
    input_dict(In, Dict),
    itinerary_from_json(Dict, Itin),
    annotate(Itin, A),
    classes_json(A, Out).

run_op(programs, _, Out) :-
    programs_json(Out).

run_op(airports, In, _{ query: Q, results: Results }) :-
    input_dict(In, Dict),
    (   get_dict(q, Dict, Q0), atom_string(Q, Q0)
    ->  true
    ;   throw(input_error('An airport search needs a "q".'))
    ),
    (   get_dict(limit, Dict, L), integer(L) -> Limit = L ; Limit = 20 ),
    Capped is max(1, min(Limit, 100)),
    (   Q == ''
    ->  Results = []
    ;   airport_search(Q, Capped, Codes),
        maplist(airport_json, Codes, Results)
    ).

% --- the same answer, written for a person ---------------------------------

%! rtw_render(+Op, +In, +Opts, -Dict, -Text) is semidet.
%
%  Both renderings of one run, for the two operations this repository already
%  has a text renderer for. Opts is passed to explain/3, so `checks(true)` here
%  means what `--checks` means on the CLI.
%
%  It exists because src/explain.pl reads the report *term* and
%  src/io/json_out.pl reads the same term, and a caller that wants both would
%  otherwise have to validate twice and hope the two runs agreed. Fails for any
%  other operation, whose text is a line about a dict rather than a rendering of
%  a term, and thus belongs to the front end asking for it.
rtw_render(validate, In, Opts, Dict, Text) :-
    validate_pipeline(In, Report, Dict),
    with_output_to(string(Text), explain(Report, current_output, Opts)).
rtw_render(earn, In, _, Dict, Text) :-
    earn_pipeline(In, Report, Dict),
    with_output_to(string(Text), explain_earn(Report, current_output)).

% One pipeline per question, with two entry points each. rtw_do/3 throws the
% term away; rtw_render/5 renders it as well. Neither runs the rules twice.
validate_pipeline(In, Report, Dict) :-
    input_dict(In, D),
    itinerary_from_json(D, Itin),
    validate_annotated(Itin, Report, A),
    annotations_json(A, Annotations),
    report_json(Report, _{ annotations: Annotations }, Dict).

earn_pipeline(In, Report, Dict) :-
    input_dict(In, D),
    (   get_dict(programs, D, List), is_list(List)
    ->  maplist([V, P]>>atom_string(P, V), List, Asked)
    ;   Asked = []
    ),
    resolve_programs(Asked, Programs),
    itinerary_from_json(D, Itin),
    annotate(Itin, A),
    earn(A, Programs, Report),
    earn_json(Report, Dict).

% --- which classes the fare books into -------------------------------------

% The projection of section 5(b) that answers "which code do I ask an inventory
% system for", one sector at a time. It runs no fare rules, which is why it is
% its own operation rather than a field on the report: `routing` is its own for
% the same reason.
%
% The codes come from data/booking_codes.pl, through the same two predicates
% src/earn/presumed.pl reads and in the same order -- the fare basis narrows the
% answer where there is one, and the cabin is the fallback where there is not.
% Business is the only cabin with two columns, so it is the only one the
% narrowing changes, and there it is the difference between one code and two.
classes_json(A, _{ cabin: Cabin,
                   fareBasis: BasisOut,
                   basisSource: Source,
                   segments: Segments }) :-
    Cabin = A.cabin,
    fare(A, Fare),
    (   Fare.basis == none
    ->  BasisOut = null, Source = cabin
    ;   BasisOut = Fare.basis, Source = 'fare basis'
    ),
    findall(S, ann_seg(A, S), Segs),
    maplist(segment_classes(A, Fare.basis), Segs, Segments).

segment_classes(_, _, S, _{ n: S.n, from: Upper, to: UpperTo,
                            marketingCarrier: null,
                            classes: [], alternates: [],
                            reason: 'A surface sector is not sold in a booking class.' }) :-
    S.type == surface, !,
    upcase_atom(S.from, Upper),
    upcase_atom(S.to, UpperTo).
segment_classes(A, Basis, S, _{ n: S.n, from: Upper, to: UpperTo,
                                marketingCarrier: CarrierOut,
                                classes: Classes,
                                alternates: Alternates,
                                reason: Reason }) :-
    upcase_atom(S.from, Upper),
    upcase_atom(S.to, UpperTo),
    Carrier = S.marketing,
    (   Carrier == unknown
    ->  CarrierOut = null
    ;   upcase_atom(Carrier, CarrierOut)
    ),
    (   Carrier == unknown
    ->  Classes = [], Alternates = [],
        Reason = 'No marketing carrier is named, and 5(b) is read against the carrier that sells the fare.'
    ;   \+ carrier_has_codes(Carrier)
    ->  Classes = [], Alternates = [],
        format(atom(Reason), 'Section 5(b) publishes no row for ~w.', [CarrierOut])
    ;   applicable_codes(A, Basis, S, Carrier, Classes),
        alternate_codes(A, S, Carrier, Alternates),
        Reason = null
    ).

% The applicable codes, and nothing conditional. An economy fare's premium
% economy code belongs here rather than among the alternates: section 12 sells
% premium economy as a per-sector surcharge over an economy fare rather than as
% a fare basis of its own, so it is a code an economy Explorer fare books into.
% src/rules/r05_booking.pl reads it as applicable for the same reason.
applicable_codes(A, Basis, S, Carrier, Codes) :-
    (   Basis \== none,
        basis_classes(Carrier, S.from_country, S.to_country, Basis, Base)
    ->  true
    ;   explorer_classes(Carrier, S.from_country, S.to_country, A.cabin, Base)
    ),
    (   A.cabin == economy, premium_economy_code(Carrier, Pe)
    ->  append(Base, [Pe], All)
    ;   All = Base
    ),
    sort(All, Sorted),
    maplist([C, U]>>upcase_atom(C, U), Sorted, Codes).

% The codes the notes of 5(b) allow only where something is true about the
% flight that an itinerary cannot show. They are kept out of `classes` because
% the applicable code is the one the fare is sold in; a caller broadening a
% search may ask for these as well, and a caller checking a ticket may not.
%
% One note is deliberately missing. "For flights where First or Business Class
% is not offered or available, passengers may travel in a lower class" falls
% through the column order, and which column is lower than which is a reading of
% the rule rather than a row of the table. That reading lives in
% src/rules/r05_booking.pl and stays there; a second copy here is exactly the
% drift this file exists to avoid. A client that wants it reads `bookingCodes`
% off the ruleset and falls through the columns itself.
alternate_codes(A, S, Carrier, Alternates) :-
    findall(_{ code: Upper, note: Note },
            ( alternate(A, S, Carrier, Code, Note),
              upcase_atom(Code, Upper) ),
            Alternates0),
    sort(Alternates0, Alternates).

alternate(A, _, Carrier, Code, business_alternate) :-
    A.cabin == business,
    business_alternate_code(Carrier, Code).
alternate(A, _, _, Code, first_alternate) :-
    A.cabin == first,
    first_alternate_code(Code).
% Written "for services within the Middle East", so it is a fact about the
% sector rather than the carrier. Both endpoints have to be in the zone.
alternate(A, S, Carrier, Code, middle_east) :-
    A.cabin == business,
    middle_east_business_code(Carrier, Code),
    S.from_zone == middle_east,
    S.to_zone == middle_east.

% --- input and failure -----------------------------------------------------

%! input_dict(+In, -Dict) is det.
%  Accepts a dict as it stands, so a caller that already parsed the request does
%  not pay to serialise it again. value_string_as(string) matches what the
%  server asks http_read_json_dict for, so an itinerary reaching the rules
%  through any front end is built from exactly the same term shapes.
input_dict(In, In) :- is_dict(In), !.
input_dict(In, Dict) :-
    catch(atom_json_dict(In, Dict, [value_string_as(string)]), _,
          throw(input_error('Request body must be JSON.'))),
    (   is_dict(Dict)
    ->  true
    ;   throw(input_error('Request body must be a JSON object.'))
    ).

%! op_error_reply(+Error, -Status, -Dict) is det.
%  The mapping server.pl uses, minus the two cases that need an HTTP request to
%  happen at all: there is no request body here to be too large, and no time
%  limit, because a caller that is not a socket stops a runaway query itself.
%
%  The exception term travels in `detail`. server.pl hides it and keeps its own
%  mapping, because an unauthenticated caller over a socket is not owed a
%  description of the validator's internals. The two callers here -- the browser
%  and the MCP server -- run on the reader's own machine, where there is nobody
%  else to hide it from, and where the reader is the only person who can report
%  the bug. mcp.pl writes it to stderr as well, because it has one.
op_error_reply(input_error(Message), 400,
               _{ error: 'invalid_request', message: Message }) :- !.
op_error_reply(Error, 500,
               _{ error: 'internal_error',
                  message: 'The validator failed on this request.',
                  detail: Detail }) :-
    term_to_atom(Error, Detail).

%! op_failed_reply(+Op, -Dict) is det.
%  An operation that merely failed. A predicate that failed where it should have
%  succeeded is a bug in a rule, so it is reported as one rather than left to
%  show up as a call that never resolved.
op_failed_reply(Op, _{ error: 'internal_error',
                       message: 'The validator failed on this request.',
                       detail: Detail }) :-
    format(atom(Detail), 'rtw_do(~w, ...) failed without raising an error.', [Op]).

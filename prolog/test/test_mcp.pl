:- module(test_mcp, []).

/** <module> The MCP front end.

    Two questions, and the second is the one that matters.

    The first is whether this file speaks the protocol: a message in, the right
    shape of message out, and the two kinds of failure kept apart. A malformed
    itinerary is a tool result with isError set, because a model can read that
    and try again. An unknown method is a JSON-RPC error, because it cannot.

    The second is whether `classes` agrees with the rule that reads the same
    table. It is a projection of section 5(b), and 5(b) is also read by
    src/rules/r05_booking.pl in the other direction. Two readings of one table
    are exactly the kind of thing that drifts, and the answer here is not to
    compare the two implementations -- that would only assert they are the same
    code -- but to close the loop: book every sector in the class this tool
    names, validate the result, and require that 5(b) passes. If the tool ever
    names a class the rule rejects, the search it was written to drive would be
    a search for space the fare cannot use.
*/

:- use_module(library(plunit)).
:- if(exists_source(library(json))).
:- use_module(library(json)).
:- else.
:- use_module(library(http/json)).
:- endif.
:- use_module(support).
:- use_module('../src/mcp').
:- use_module('../src/ops').
:- use_module('../src/io/json_in').
:- use_module('../src/annotate').
:- use_module('../src/validate').

% --- helpers ---------------------------------------------------------------

% A request as it arrives off the wire: every value a string, because that is
% what the reader is asked for.
request(Method, Params, _{ jsonrpc: "2.0", id: 1, method: Method, params: Params }).

reply(Method, Params, Reply) :-
    request(Method, Params, Msg),
    reply_for(Msg, Reply).

result(Method, Params, Result) :-
    reply(Method, Params, Reply),
    (   get_dict(result, Reply, Result)
    ->  true
    ;   throw(expected_a_result_but_got(Reply))
    ).

error_code(Method, Params, Code) :-
    reply(Method, Params, Reply),
    Code = Reply.error.code.

call_tool(Name, Args, Result) :-
    result("tools/call", _{ name: Name, arguments: Args }, Result).

% --- the protocol ----------------------------------------------------------

:- begin_tests(mcp_protocol).

test(discover_names_its_versions_and_itself) :-
    result("server/discover", _{}, R),
    assertion(R.resultType == complete),
    findall(V, protocol_version(V), Versions),
    assertion(R.supportedVersions == Versions),
    assertion(get_dict(tools, R.capabilities, _)),
    assertion(get_dict(resources, R.capabilities, _)),
    Info = R.'_meta'.'io.modelcontextprotocol/serverInfo',
    assertion(Info.name == 'oneworld-rtw-planner').

% A client of the older era settles the version once, in the handshake, and has
% no way to ask again. So a version this server answers is echoed back.
test(initialize_echoes_a_version_it_answers) :-
    result("initialize", _{ protocolVersion: "2025-06-18" }, R),
    assertion(R.protocolVersion == '2025-06-18').

% And one it does not answer gets the newest it does, rather than an error the
% client could not act on.
test(initialize_offers_its_own_when_the_asked_for_one_is_unknown) :-
    result("initialize", _{ protocolVersion: "1999-01-01" }, R),
    assertion(protocol_version(R.protocolVersion)).

% The modern era states the version on every request instead.
test(an_unanswerable_version_is_refused_with_the_list_that_is_answerable) :-
    request("tools/list",
            _{ '_meta': _{ 'io.modelcontextprotocol/protocolVersion': "1900-01-01" } },
            Msg),
    reply_for(Msg, Reply),
    assertion(Reply.error.code == -32022),
    findall(V, protocol_version(V), Versions),
    assertion(Reply.error.data.supported == Versions),
    assertion(Reply.error.data.requested == '1900-01-01').

% A request that names no version at all is from the older era and is answered,
% not refused. Refusing it would break every client that finished a handshake.
test(a_request_naming_no_version_is_answered) :-
    result("tools/list", _{}, R),
    assertion(is_list(R.tools)).

test(a_notification_draws_no_reply) :-
    \+ reply_for(_{ jsonrpc: "2.0", method: "notifications/initialized" }, _).

test(an_unknown_method_is_a_protocol_error) :-
    error_code("frobnicate", _{}, Code),
    assertion(Code == -32601).

test(ping_is_answered) :-
    result("ping", _{}, R),
    assertion(is_dict(R)).

:- end_tests(mcp_protocol).

% --- the tools -------------------------------------------------------------

:- begin_tests(mcp_tools).

% Every operation the other front ends answer is reachable here, under the same
% name. One vocabulary across the CLI subcommands, the HTTP paths, the browser
% ops and these.
test(every_operation_is_a_tool_of_the_same_name) :-
    findall(Op, known_op(Op), Ops),
    findall(Name, tool(Name, _, _, _), Names),
    msort(Ops, Sorted), msort(Names, Sorted).

test(every_tool_declares_a_usable_schema) :-
    forall(tool(Name, Title, Description, Schema),
           ( assertion(Name \== ''),
             assertion(Title \== ''),
             atom_length(Description, L),
             assertion(L > 40),
             assertion(Schema.type == object) )).

% A schema has to survive being written out and read back, or a client sees a
% tool it cannot call.
test(every_schema_round_trips_as_json) :-
    forall(tool(_, _, _, Schema),
           ( atom_json_dict(Atom, Schema, [as(atom), width(0)]),
             atom_json_dict(Atom, Back, [value_string_as(string)]),
             assertion(is_dict(Back)) )).

test(tools_list_carries_every_tool) :-
    result("tools/list", _{}, R),
    findall(Name, tool(Name, _, _, _), Names),
    findall(N, ( member(T, R.tools), atom_string(N, T.name) ), Listed),
    msort(Names, Sorted), msort(Listed, Sorted).

test(an_unknown_tool_is_a_protocol_error) :-
    error_code("tools/call", _{ name: "frobnicate", arguments: _{} }, Code),
    assertion(Code == -32602).

% Input the caller can fix comes back as a result, not as a protocol error. A
% model can read the first and try again; the second reads to it as a broken
% transport.
test(malformed_input_is_a_tool_error_not_a_protocol_error) :-
    call_tool("validate", _{ route: "LHR-BA" }, R),
    assertion(R.isError == true),
    R.content = [C|_],
    assertion(C.type == text),
    assertion(C.text \== '').

test(giving_both_forms_is_refused) :-
    call_tool("validate",
              _{ route: "LHR-BA-JFK-BA-LHR",
                 segments: [_{ from: "LHR", to: "JFK" }] },
              R),
    assertion(R.isError == true).

test(every_tool_answers_over_a_fixture) :-
    fixture(lhr_classic, Dict),
    forall(member(Name-Args,
                  [ "validate"-Dict, "earn"-Dict, "classes"-Dict, "routing"-Dict,
                    "airports"-_{ q: "sydney" },
                    "ruleset"-_{}, "programs"-_{} ]),
           ( call_tool(Name, Args, R),
             assertion(R.isError == false),
             assertion(R.content = [_|_]),
             assertion(get_dict(structuredContent, R, _)) )).

% The register is four times the length of the verdict it supports, and the
% annotations are coordinates a reader cannot use. Both are off unless asked
% for. The routing is the one line of the annotations that is worth having, so
% it is promoted rather than withheld.
test(a_verdict_carries_neither_the_register_nor_the_map_unless_asked) :-
    fixture(lhr_classic, Dict),
    call_tool("validate", Dict, R),
    S = R.structuredContent,
    assertion(\+ get_dict(checks, S, _)),
    assertion(\+ get_dict(annotations, S, _)),
    assertion(get_dict(routing, S, _)),
    assertion(get_dict(verdict, S, _)),
    assertion(get_dict(fare, S, _)).

test(the_register_comes_back_when_it_is_asked_for) :-
    fixture(lhr_classic, Dict),
    call_tool("validate", Dict.put(checks, true), R),
    assertion(get_dict(checks, R.structuredContent, [_|_])).

test(the_map_comes_back_when_it_is_asked_for) :-
    fixture(lhr_classic, Dict),
    call_tool("validate", Dict.put(annotations, true), R),
    assertion(get_dict(annotations, R.structuredContent, _)).

% The text is the point of the split: it is what a reader reads, and it is two
% orders of magnitude smaller than the report behind it.
test(the_text_is_shorter_than_the_report) :-
    fixture(lhr_classic, Dict),
    call_tool("validate", Dict, R),
    R.content = [C|_],
    atom_json_dict(Json, R.structuredContent, [as(atom), width(0)]),
    atom_length(C.text, TextLength),
    atom_length(Json, JsonLength),
    assertion(TextLength < JsonLength).

:- end_tests(mcp_tools).

% --- the resources ---------------------------------------------------------

:- begin_tests(mcp_resources).

test(every_resource_reads) :-
    forall(resource(Uri, _, _, Mime),
           ( result("resources/read", _{ uri: Uri }, R),
             R.contents = [C|_],
             assertion(C.uri == Uri),
             assertion(C.mimeType == Mime),
             assertion(C.text \== '') )).

test(resources_list_carries_every_resource) :-
    result("resources/list", _{}, R),
    findall(U, resource(U, _, _, _), Uris),
    findall(U, ( member(X, R.resources), atom_string(U, X.uri) ), Listed),
    msort(Uris, Sorted), msort(Listed, Sorted).

test(an_unknown_resource_is_a_protocol_error) :-
    error_code("resources/read", _{ uri: "rtw://nothing" }, Code),
    assertion(Code == -32602).

% The transcription is what makes a citation checkable. A resource that reads
% back empty would leave every violation pointing at nothing.
test(the_tariff_transcription_is_the_tariff_transcription) :-
    result("resources/read", _{ uri: "rtw://rules" }, R),
    R.contents = [C|_],
    assertion(sub_string(C.text, _, _, _, "3015")).

:- end_tests(mcp_resources).

% --- classes agrees with the rule ------------------------------------------

:- begin_tests(mcp_classes).

% The load-bearing test. Book every sector in a class `classes` names, run the
% validator over the result, and require that section 5(b) does not fire. This
% asserts the property the tool exists for rather than the code that implements
% it: a search driven by these codes finds space the fare can actually use.
test(booking_the_classes_it_names_satisfies_rule_5b) :-
    fixture_names(Names),
    forall(( member(Name, Names), classable(Name, Dict, Classed) ),
           ( itinerary_from_json(Classed, Itin),
             validate(Itin, report(_, Violations, _, _, _)),
             (   memberchk(v(booking_code, _, _, Message, _), Violations)
             ->  throw(rule_5b_rejected(Name, Message, Dict))
             ;   true
             ) )).

% Only fixtures written as segments can carry a class at all. A routing has
% nowhere to write one, which is the same reason 5(b) reads `n/a` over one.
classable(Name, Dict, Classed) :-
    fixture(Name, Dict),
    get_dict(segments, Dict, _),
    rtw_do(classes, Dict, Classes),
    inject_classes(Dict, Classes, Classed),
    Classed \== Dict.

inject_classes(Dict, Classes, Classed) :-
    findall(N-Code,
            ( member(S, Classes.segments),
              S.classes = [Code|_],
              N = S.n ),
            Pairs),
    Pairs \== [],
    maplist(inject_class(Pairs), Dict.segments, Segments),
    Classed = Dict.put(segments, Segments).

% The nth segment gets the first class 5(b) names for it. Segments the tool
% could not price -- a surface sector, an unnamed carrier, a carrier 5(b) has no
% row for -- are left exactly as they were.
inject_class(Pairs, Segment, Out) :-
    (   get_dict(n, Segment, N),
        memberchk(N-Code, Pairs)
    ->  Out = Segment.put(bookingClass, Code)
    ;   Out = Segment
    ).

% An alternate is a code the notes allow only where something about the flight
% is true that an itinerary cannot show. It is never also an applicable code:
% the two answer different questions, and a caller checking a ticket wants only
% the first.
test(an_alternate_is_never_also_applicable) :-
    fixture_names(Names),
    forall(( member(Name, Names),
             fixture(Name, Dict),
             rtw_do(classes, Dict, Classes),
             member(S, Classes.segments),
             member(A, S.alternates) ),
           ( memberchk(A.code, S.classes)
           ->  throw(alternate_is_also_applicable(Name, S.n, A.code))
           ;   true )).

% The exception is written "for services within the Middle East", so both ends
% have to be in the zone. A Doha to Bangkok sector is not within it.
test(the_middle_east_alternate_needs_both_ends_in_the_zone) :-
    rtw_do(classes,
           _{ route: "LHR-QR-DOH-QR-BAH-QR-X/DOH-QR-BKK-CX-HKG-CX-LHR",
              cabin: "business" },
           Classes),
    forall(member(S, Classes.segments),
           ( middle_east_offered(S)
           ->  assertion(memberchk(S.n, [2, 3]))
           ;   assertion(\+ memberchk(S.n, [2, 3])) )).

middle_east_offered(S) :-
    member(A, S.alternates),
    A.note == middle_east,
    !.

% Business is the only cabin 5(b) publishes two columns for, so the fare basis
% is the only thing that can narrow it, and it is the only place the narrowing
% shows. Three continents publishes a basis; two does not.
test(a_published_basis_narrows_business_to_one_column) :-
    rtw_do(classes,
           _{ route: "LHR-BA-JFK-AA-X/LAX-JL-NRT-CX-HKG-QR-X/DOH-QR-LHR",
              cabin: "business" },
           Narrowed),
    assertion(Narrowed.fareBasis == 'DONE3'),
    forall(member(S, Narrowed.segments), assertion(S.classes == ['D'])),
    rtw_do(classes,
           _{ route: "LHR-QR-DOH-QR-BKK-CX-HKG-CX-LHR", cabin: "business" },
           Wide),
    assertion(Wide.fareBasis == null),
    forall(member(S, Wide.segments), assertion(S.classes == ['D', 'I'])).

% An economy fare buys premium economy through section 12's per-sector
% surcharge rather than a fare basis of its own, so the premium code is one an
% economy fare books into. QR publishes none, and gets none invented for it.
test(an_economy_fare_books_into_the_premium_economy_code_too) :-
    rtw_do(classes,
           _{ route: "LHR-BA-JFK-AA-X/LAX-JL-NRT-CX-HKG-QR-X/DOH-QR-LHR",
              cabin: "economy" },
           Classes),
    forall(( member(S, Classes.segments), S.marketingCarrier == 'BA' ),
           assertion(S.classes == ['L', 'T'])),
    forall(( member(S, Classes.segments), S.marketingCarrier == 'QR' ),
           assertion(S.classes == ['L'])).

% A sector the table cannot price says why, and never comes back as an empty
% list with nothing to explain it.
test(a_sector_with_no_row_says_so_rather_than_returning_nothing) :-
    rtw_do(classes,
           _{ segments: [ _{ n: 1, from: "LHR", to: "JFK" },
                          _{ n: 2, from: "JFK", to: "LHR", carrier: "BA" } ] },
           Classes),
    Classes.segments = [First, Second],
    assertion(First.classes == []),
    assertion(First.reason \== null),
    assertion(Second.classes \== []),
    assertion(Second.reason == null).

test(a_surface_sector_is_not_sold_in_a_class) :-
    rtw_do(classes,
           _{ segments: [ _{ n: 1, from: "LHR", to: "JFK", carrier: "BA" },
                          _{ n: 2, type: "surface", from: "JFK", to: "BOS" } ] },
           Classes),
    Classes.segments = [_, Surface],
    assertion(Surface.classes == []),
    assertion(Surface.marketingCarrier == null),
    assertion(Surface.reason \== null).

:- end_tests(mcp_classes).

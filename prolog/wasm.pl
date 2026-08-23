% wasm.pl -- entry point for the browser build.
%
% The same rules the server runs, reached from JavaScript instead of over HTTP.
% prolog/tools/build_image.mjs consults this file inside SWI-Prolog compiled to
% WebAssembly and saves the result as web/rtw.pvm. web/worker.js then boots that
% image and calls rtw_call/4. Nothing here decides anything about a fare. Like
% server.pl, this file only renders the same report/3 term, and every predicate
% it calls is one the server calls too.
%
% This is not a module, for the same reason load.pl is not: a query from the
% JavaScript side runs in `user`, and predicates defined in a module would not
% be visible there unless every call named the module.
%
% Two facts about the WebAssembly build shape this file.
%
% *A saved image has no autoloading.* Only what was compiled in exists, so a
% goal put together in the browser cannot reach library predicates. Even
% member/2 raises an existence error. That is why rtw_call/4 is the only way in:
% the browser names an operation, never a goal. It also means every library this
% file needs must be imported right here, at build time, where a mistake breaks
% the build instead of the first request.
%
% *library(http/json) is missing*, because the HTTP package is not part of the
% build. library(json) is there and has the same predicates. cli.pl already
% picks between the two, so the same conditional is reused here rather than
% written a second way.

:- ensure_loaded(load).

:- if(exists_source(library(json))).
:- use_module(library(json)).
:- else.
:- use_module(library(http/json)).
:- endif.

:- use_module(library(apply)).
:- use_module(library(lists)).
:- use_module(library(yall)).

%! rtw_call(+Op, +InText, -Status, -OutText) is det.
%
%  One operation per server endpoint, sharing the same names: `validate`,
%  `routing`, `ruleset`, `airports`, `earn` and `programs`. InText and OutText
%  are JSON text. Status is the status the server would have replied with: 200,
%  400 for input the caller can fix, or 500 for a bug in a rule. Sending the
%  status back beats making the browser guess at failure from the shape of the
%  body, and it keeps the two front ends describing the same failure the same
%  way.
%
%  This is total and deterministic. An operation that throws and an operation
%  that merely fails both come back as a reply. A predicate that failed where it
%  should have succeeded is a bug in a rule, so it is reported as one. Letting
%  the query fail instead would show up in the browser as a call that never
%  resolved, which is the least useful way for a bug to appear.
rtw_call(Op, In, Status, Out) :-
    catch(( rtw_do(Op, In, Dict) -> Status = 200 ; failed_reply(Op, Status, Dict) ),
          Error,
          error_reply(Error, Status, Dict)),
    atom_json_dict(Out, Dict, [as(atom), width(0)]).

% width(0) turns off the line breaking atom_json_dict does by default. Without
% it, any message long enough to wrap arrives with newlines inside it.

rtw_do(validate, In, Out) :-
    input_dict(In, Dict),
    itinerary_from_json(Dict, Itin),
    validate_annotated(Itin, Report, A),
    annotations_json(A, Annotations),
    report_json(Report, _{ annotations: Annotations }, Out).

% As on the server, this exists so the browser never writes a routing itself.
% Doing so would create a second definition of the grammar, and the only one
% with no test behind it.
rtw_do(routing, In, _{ route: Route }) :-
    input_dict(In, Dict),
    itinerary_from_json(Dict, Itin),
    annotate(Itin, A),
    (   annotated_route(A, Route)
    ->  true
    ;   no_routing_message(A, Message),
        throw(input_error(Message))
    ).

rtw_do(ruleset, _, Out) :-
    ruleset_json(Out).

% The earning side, which runs no fare rules. Same two names the server uses.
rtw_do(earn, In, Out) :-
    input_dict(In, Dict),
    (   get_dict(programs, Dict, List), is_list(List)
    ->  maplist([V, P]>>atom_string(P, V), List, Asked)
    ;   Asked = []
    ),
    resolve_programs(Asked, Programs),
    itinerary_from_json(Dict, Itin),
    annotate(Itin, A),
    earn(A, Programs, Report),
    earn_json(Report, Out).

rtw_do(programs, _, Out) :-
    programs_json(Out).

rtw_do(airports, In, _{ query: Q, results: Results }) :-
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

rtw_do(Op, _, _) :-
    \+ memberchk(Op, [validate, routing, ruleset, airports, earn, programs]),
    format(atom(M), 'There is no "~w" operation.', [Op]),
    throw(input_error(M)).

% value_string_as(string) matches what the server asks http_read_json_dict for,
% so an itinerary reaching the rules through the browser is built from exactly
% the same term shapes as one that arrived over the wire.
input_dict(In, Dict) :-
    catch(atom_json_dict(In, Dict, [value_string_as(string)]), _,
          throw(input_error('Request body must be JSON.'))).

%! error_reply(+Error, -Status, -Dict) is det.
%
%  The same mapping server.pl uses, minus the two cases that need an HTTP
%  request to happen at all. There is no request body here to be too large, and
%  no time limit, because the browser stops a runaway validation by killing the
%  worker.
%
%  One difference from the server is on purpose. The server hides the exception
%  term, because an unauthenticated caller is not owed a description of the
%  validator's internals, and logs it where an operator can read it. There is no
%  such boundary here: the caller is the page itself, running on the reader's own
%  machine, and there is no server-side log to send the term to. So the term
%  travels in `detail` and the worker prints it to the console, which is the only
%  place a bug found in the browser can be reported from.
error_reply(input_error(Message), 400,
            _{ error: 'invalid_request', message: Message }) :- !.
error_reply(Error, 500,
            _{ error: 'internal_error',
               message: 'The validator failed on this request.',
               detail: Detail }) :-
    term_to_atom(Error, Detail).

failed_reply(Op, 500,
             _{ error: 'internal_error',
                message: 'The validator failed on this request.',
                detail: Detail }) :-
    format(atom(Detail), 'rtw_do(~w, ...) failed without raising an error.', [Op]).

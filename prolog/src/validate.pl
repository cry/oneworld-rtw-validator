:- module(validate,
          [ validate/2,
            validate_annotated/3,
            violation/2,
            not_checked/2,
            check/2,
            severity_rank/2,
            verdict_of/2,
            citation_key/2
          ]).

/** <module> The findall driver and the rule registry.

    Each rule is a clause of violation/2 that *succeeds when the rule is
    broken*, binding a term that describes the breakage. That inversion is the
    single most important design decision in this codebase. The obvious shape,
    `valid(I) :- rule1(I), rule2(I), ...`, gives a bare "no" and explains
    nothing. Backtracking over violation/2 instead lists every violation of
    every rule in one pass, and each one carries its own evidence.

    Violation shape:

        v(RuleId, Citation, Severity, Message, Evidence)

    Severity is one of:

      error          definitely invalid
      warning        probably invalid, or subject to carrier discretion
      indeterminate  cannot be decided from the input

    `indeterminate` exists so an itinerary entered without timestamps is never
    reported clean. It is not a passing grade.

    A second registry, not_checked/2, covers rules the *mode* puts out of reach,
    as opposed to rules missing a piece of data. A routing-only itinerary has no
    calendar at all, so rules 6 and 7 have nothing to measure. Calling that
    `indeterminate` would make every routing-only check indeterminate and empty
    the word of its meaning, so those rules are listed in the report as not
    checked instead. The difference: `indeterminate` means "this rule needs
    something you left out", and not_checked means "this rule cannot be answered
    from the kind of input you gave". Neither is a pass, and both are printed.

        nc(RuleId, Citation, Reason)

    A third registry, check/2, is the counterpart to both. It states what each
    rule *measured*, whether or not the rule was broken. "No rule was broken" is
    a claim about coverage that a reader has no way to audit, and a cap the
    itinerary sits one under is exactly what a fare-construction tool gets asked
    about. A check clause reports the measurement and nothing else:

        chk(CheckId, Citation, Label, Detail, Covers)
        chk_na(CheckId, Citation, Label, Reason)

    Covers names the violation ids this measurement decides. A check clause
    never states the *outcome*. validate_ann/2 works that out from the
    violations the same run produced, so a check can never disagree with the
    verdict printed above it. chk_na is for a rule nothing in the itinerary
    touches, such as 4(l) on a journey with no Australian sectors. That is not
    the same as a rule that passed, and not the same as one that could not be
    run.

        check(CheckId, Citation, Label, Outcome, Detail)

    Outcome is pass, fail, warning, indeterminate, not_checked or
    not_applicable.
*/

:- use_module(annotate).
:- use_module(pricing).

:- multifile violation/2.
:- discontiguous violation/2.

:- multifile not_checked/2.
:- discontiguous not_checked/2.

:- multifile check/2.
:- discontiguous check/2.

%! validate(+Itin, -Report) is det.
validate(Itin, Report) :-
    annotate(Itin, A),
    validate_ann(A, Report).

%! validate_annotated(+Itin, -Report, -Annotated) is det.
%  The same result, but it also hands back the annotation pass so a caller can
%  serialize it alongside the report. The web UI needs that to draw the route
%  and to show why a rule fired.
validate_annotated(Itin, Report, A) :-
    annotate(Itin, A),
    validate_ann(A, Report).

validate_ann(A, report(Verdict, Violations, Fare, Skipped, Checks)) :-
    findall(V, violation(A, V), Found),
    append(A.input_errors, Found, All),
    sort(All, Deduped),
    order_for_display(Deduped, Violations),
    verdict_of(Violations, Verdict),
    findall(NC, not_checked(A, NC), Skipped0),
    sort(Skipped0, Skipped1),
    order_not_checked(Skipped1, Skipped),
    checks_of(A, Violations, Skipped, Checks),
    fare(A, Fare).

% --- the check register ----------------------------------------------------

% An itinerary with an airport we cannot resolve, or a gap between two segments,
% is not yet the itinerary anyone asked about. Rules measured over it would
% report caps and counts for a journey the reader never submitted. Sixteen lines
% of "ok" under two input errors is the most misleading thing this report could
% say, so the register is held back until the input parses.
checks_of(A, _, _, []) :-
    A.input_errors \== [],
    !.
% list_to_set/2 rather than sort/2, and a sort key made of the citation alone.
% Within one rule the checks then come out in the order the rule module declares
% them, which is the order the rule text reads in. Sorting by check id instead
% would put 4(h)'s free-segment caps before its segment count.
checks_of(A, Violations, Skipped, Checks) :-
    findall(C, check(A, C), Raw),
    list_to_set(Raw, Distinct),
    maplist(check_outcome(Violations, Skipped), Distinct, Decided),
    order_checks(Decided, Checks).

check_outcome(_, _, chk_na(Id, Citation, Label, Reason),
              check(Id, Citation, Label, not_applicable, Reason)) :- !.
check_outcome(Violations, Skipped, chk(Id, Citation, Label, Detail, Covers),
              check(Id, Citation, Label, Outcome, Detail)) :-
    check_status(Violations, Skipped, Covers, Outcome).

% Worst first, so a check that covers both an error and a warning reads as
% failed.
check_status(Violations, _, Covers, Outcome) :-
    findall(Rank-Severity,
            ( member(v(Rule, _, Severity, _, _), Violations),
              memberchk(Rule, Covers),
              severity_rank(Severity, Rank) ),
            Ranked),
    Ranked \== [],
    !,
    keysort(Ranked, [_-Worst|_]),
    outcome_of(Worst, Outcome).
check_status(_, Skipped, Covers, not_checked) :-
    member(nc(Rule, _, _), Skipped),
    memberchk(Rule, Covers),
    !.
check_status(_, _, _, pass).

outcome_of(error,         fail).
outcome_of(indeterminate, indeterminate).
outcome_of(warning,       warning).

%! severity_rank(?Severity, ?Rank) is nondet.
severity_rank(error,         0).
severity_rank(indeterminate, 1).
severity_rank(warning,       2).

%! verdict_of(+Violations, -Verdict) is det.
%  Warnings on their own do not make an itinerary invalid. A rule that could not
%  be decided does block a `valid` verdict, though.
verdict_of(Vs, invalid) :-
    memberchk(v(_, _, error, _, _), Vs), !.
verdict_of(Vs, indeterminate) :-
    memberchk(v(_, _, indeterminate, _, _), Vs), !.
verdict_of(_, valid).

% sort/2 above orders by rule id. That is stable, but it is not how anyone wants
% to read a report. Show the worst first, then follow itinerary order.
order_for_display(Vs, Sorted) :-
    map_list_to_pairs(display_key, Vs, Pairs),
    keysort(Pairs, Keyed),
    pairs_values(Keyed, Sorted).

% sort/2 above orders these by rule id too, but the reader expects rule order.
order_not_checked(NCs, Sorted) :-
    map_list_to_pairs([nc(R, C, _), Key-R]>>citation_key(C, Key), NCs, Pairs),
    keysort(Pairs, Keyed),
    pairs_values(Keyed, Sorted).

% keysort/2 is stable, so ties keep declaration order.
order_checks(Cs, Sorted) :-
    map_list_to_pairs([check(_, C, _, _, _), Key]>>citation_key(C, Key), Cs, Pairs),
    keysort(Pairs, Keyed),
    pairs_values(Keyed, Sorted).

%! citation_key(+Citation, -Key) is det.
%  Rule order, not alphabetical order. Citations are atoms such as '4(a),4(b)'
%  and '15'. Sorted as plain text, rule 15 lands between rule 0 and rule 4.
citation_key(Citation, Number-Citation) :-
    atom_codes(Citation, Codes),
    leading_digits(Codes, Digits),
    (   Digits == []
    ->  Number = 999
    ;   number_codes(Number, Digits)
    ).

leading_digits([C|T], [C|Ds]) :- code_type(C, digit), !, leading_digits(T, Ds).
leading_digits(_, []).

% The citation goes through citation_key/2 for the same reason it does in the two
% orderings above. Compared as text, rule 15 sorts between rule 0 and rule 4, so
% two violations at the same severity on the same segment used to come out in
% ASCII order of their citation rather than in rule order.
display_key(v(Rule, Citation, Severity, _, Evidence), key(Rank, Seg, Key, Rule)) :-
    severity_rank(Severity, Rank),
    citation_key(Citation, Key),
    (   memberchk(segments([S|_]), Evidence)
    ->  Seg = S
    ;   Seg = 0
    ).

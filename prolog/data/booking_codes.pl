:- module(booking_codes,
          [ booking_code/4,
            booking_column/1,
            column_name/2,
            cabin_column/2,
            sector_scope/3,
            explorer_classes/5,
            basis_classes/5,
            premium_economy_code/2,
            business_alternate_code/2,
            first_alternate_code/1,
            middle_east_business_code/2,
            carrier_has_codes/1
          ]).

/** <module> Section 5(b) booking codes.

    The class an Explorer fare books into, for each carrier and cabin. Like every
    other table here, it carries no logic. src/rules/r05_booking.pl decides what
    a code being present or absent means.

    There are two columns for business, because section 5(b) publishes two. DONE*
    is the fare basis this validator reports -- see data/limits.pl: IONE3 is
    offered in select markets only -- and IONE3 is the other. A ticket in either
    column is booked in a code the rule names, so both count as the applicable
    code for a business fare, and the report says which is which.

    Scope is `any` unless the carrier publishes separate domestic rows, which
    only AY, JL and NU do. Scope turns on whether a sector stays inside one
    country. It deliberately does not use annotate.pl's `international` field,
    which carries 4(f)'s "travel between USA and Canada is not counted as
    international" exception and would read a Helsinki-Stockholm sector as
    domestic for a reason that has nothing to do with this rule.
*/

%! booking_column(?Column) is nondet.
%  In fare order, with the lowest cabin last. That is the order the alternates
%  below fall back through.
booking_column(first).
booking_column(business_done).
booking_column(business_ione3).
booking_column(economy).

%! column_name(?Column, ?Name) is nondet.
%  How a column is written inside a sentence. The atoms are table keys, and
%  nobody says "business_done" out loud.
column_name(first,          'First').
column_name(business_done,  'Business on a DONE fare').
column_name(business_ione3, 'Business on an IONE3 fare').
column_name(economy,        'Economy').

% "| Carrier / service | First | Business — DONE* | Business — IONE3 | Economy |"
%
% Written one row at a time, rather than as a group of carriers sharing a row.
% A carrier moving column is then a one-line diff, and a reader can check any
% single carrier against the rule text without unpicking a grouping.
term_expansion(row(Carriers, Scope, First, DoneB, IoneB, Economy), Facts) :-
    findall(booking_code(C, Scope, Column, Code),
            ( member(C, Carriers),
              member(Column-Code, [ first-First, business_done-DoneB,
                                    business_ione3-IoneB, economy-Economy ]) ),
            Facts).

:- discontiguous booking_code/4.

row([aa, ba, cx, mh, qf, qr], any,           a, d, i, l).
row([as, at, fj, ib, rj, ul], any,           d, d, i, l).
row([ay],                     international, d, d, i, l).
row([ay],                     domestic,      y, y, y, l).
row([jl],                     international, a, d, i, l).
row([nu],                     international, e, e, e, l).
row([jl, nu],                 domestic,      a, d, i, l).
row([wy],                     any,           a, d, i, l).

%! carrier_has_codes(?Carrier) is nondet.
%  True when 5(b) publishes a row for this carrier at all. Every 4(j) eligible
%  carrier has one. An affiliate flying under its parent's code does not, and
%  neither does JQ or QQ.
carrier_has_codes(C) :- booking_code(C, _, _, _), !.

%! cabin_column(?Cabin, ?Column) is nondet.
%  A fare's cabin mapped onto the columns of the table. Business has two, because
%  the table publishes two: this validator reports the DONE one, and IONE3 exists
%  in select markets. See data/limits.pl.
cabin_column(first,    first).
cabin_column(business, business_done).
cabin_column(business, business_ione3).
cabin_column(economy,  economy).

%! sector_scope(+FromCountry, +ToCountry, -Scope) is det.
%  Which row of the table a sector is read against. A sector that starts and ends
%  in one country is on that carrier's domestic network.
%
%  This deliberately does not use annotate.pl's `international` field. That field
%  carries 4(f)'s USA/Canada exception, which has nothing to do with which 5(b)
%  row a Finnish or Japanese domestic flight is sold under.
sector_scope(From, To, Scope) :-
    (   From \== unknown, From == To
    ->  Scope = domestic
    ;   Scope = international
    ).

%! explorer_classes(+Carrier, +FromCountry, +ToCountry, +Cabin, -Codes) is det.
%  Every code an Explorer fare in this cabin books into, on this carrier and this
%  kind of sector. The applicable codes only, not the alternates the notes allow
%  in a stated case, which turn on what the flight offers.
%
%  This is what lets the earning side answer a sector whose class was not given.
%  The fare says which class it is sold in, so an itinerary that named a cabin
%  has said more than it looks like it has. src/rules/r05_booking.pl reads the
%  same projection in the other direction, to decide whether a class that *was*
%  given is one of these.
explorer_classes(Carrier, From, To, Cabin, Codes) :-
    carrier_scope(Carrier, From, To, Scope),
    findall(Code,
            ( cabin_column(Cabin, Column), booking_code(Carrier, Scope, Column, Code) ),
            Codes0),
    sort(Codes0, Codes).

%! basis_classes(+Carrier, +FromCountry, +ToCountry, +Basis, -Codes) is semidet.
%  The same projection, narrowed to the column the *reported fare basis* names.
%  It fails where the basis names no column, which happens when fewer than three
%  continents left the itinerary with no published basis at all.
%
%  Only business has two columns, so this only ever narrows a business fare. And
%  there it is the difference between a presumption and a guess. 5(b) heads its
%  columns "Business — DONE*" and "Business — IONE3", which are fare bases rather
%  than cabins. So a DONE4 fare books into the DONE column, and the IONE3 column
%  describes a fare this itinerary is not. Asking for both, as the cabin does,
%  gives two codes that can earn in two different categories on the same carrier,
%  and then refuses to price a sector over an ambiguity the fare basis at the top
%  of the same report had already settled.
%
%  Rule 5(b) itself keeps the cabin projection above, and has to. A ticket
%  presented in either column is booked in a code the rule names, whatever basis
%  this validator reports.
basis_classes(Carrier, From, To, Basis, Codes) :-
    basis_column(Basis, Column),
    carrier_scope(Carrier, From, To, Scope),
    findall(Code, booking_code(Carrier, Scope, Column, Code), Codes0),
    sort(Codes0, Codes),
    Codes \== [].

%! basis_column(+Basis, -Column) is semidet.
%  'DONE4' names the DONE column. The fare bases in data/limits.pl and the column
%  headings in 5(b) are the same four forms, and that is no coincidence: the
%  column is which fare it is.
basis_column(Basis, Column) :-
    atom(Basis),
    sub_atom(Basis, 0, 4, _, Form),
    basis_form_column(Form, Column).

basis_form_column('AONE', first).
basis_form_column('DONE', business_done).
basis_form_column('IONE', business_ione3).
basis_form_column('LONE', economy).

% A carrier that publishes separate domestic rows is read against the one the
% sector falls in; everyone else has a single `any` row.
carrier_scope(Carrier, From, To, Scope) :-
    sector_scope(From, To, Wanted),
    (   booking_code(Carrier, Wanted, _, _)
    ->  Scope = Wanted
    ;   Scope = any
    ).

%! premium_economy_code(?Carrier, ?Code) is nondet.
%  The second table in 5(b). Premium economy is not a fare basis of its own --
%  section 12 sells it as a per-sector surcharge over an economy fare, which is
%  what src/pricing.pl prices -- so these are the codes an economy Explorer fare
%  books into when that surcharge is paid.
premium_economy_code(aa, p).   % AA Premium Economy
premium_economy_code(ba, t).   % BA World Traveller Plus
premium_economy_code(ib, t).   % IB Premium Economy
premium_economy_code(cx, r).   % CX Premium Economy
premium_economy_code(qf, r).   % QF Premium Economy
premium_economy_code(jl, e).   % JL Premium Economy
premium_economy_code(nu, e).   % NU Premium Economy
premium_economy_code(rj, w).   % RJ Premium Economy

%! business_alternate_code(?Carrier, ?Code) is nondet.
%  "Passengers travelling on DONE* Business Class fares may book B Class
%  (except AA) or H Class on AA."
business_alternate_code(aa, h) :- !.
business_alternate_code(C, b) :- carrier_has_codes(C).

%! first_alternate_code(?Code) is nondet.
%  "Where the applicable booking class for the lower class is not available,
%  passengers travelling on First Class fares may book Y Class."
first_alternate_code(y).

%! middle_east_business_code(?Carrier, ?Code) is nondet.
%  "EXCEPTION: For services within the Middle East, where no Business Class is
%  offered, Business Class passengers may book and travel in A Class on QR,
%  subject to availability. This provision does not apply on any flight where
%  Business Class exists but is unavailable for booking."
%
%  The second sentence is why this is a flag and not a pass: the itinerary can
%  show a sector inside the Middle East and cannot show whether that particular
%  flight has a business cabin.
middle_east_business_code(qr, a).

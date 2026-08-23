:- module(overrides,
          [ continent_override/4,
            zone_override/4,
            urals_longitude/1,
            hawaii_region/1
          ]).

/** <module> Sub-country geography the fare rule needs.

    Everything here exists because a country-level table cannot express it.
*/

%! urals_longitude(-Degrees) is det.
%  Section 0 splits Russia at the Urals. The range runs close to the 60th
%  meridian, so longitude is a workable stand-in. The CSV's own `continent`
%  column cannot be used here: it files Astrakhan and Grozny as Asia, though both
%  are well west of the Urals, and it disagrees with itself within Bashkortostan.
urals_longitude(60.0).

%! continent_override(+Country, +Region, +Longitude, -Continent) is semidet.
%  Chukotka reaches past the antimeridian into negative longitudes. Every part of
%  European Russia sits between roughly 20E and 60E, so a negative longitude can
%  only be the Far East.
continent_override('RU', _Region, Lon, asia) :-
    number(Lon),
    (   urals_longitude(U), Lon >= U
    ;   Lon < 0
    ),
    !.
continent_override('RU', _Region, _Lon, europe_middle_east).

%! zone_override(+Country, +Region, +Longitude, -Zone) is semidet.
%  Russia west of the Urals is named in the Europe zone. The eastern part is
%  Asia, so it has no Europe/Middle East zone at all. The continent is resolved
%  first and then compared. Passing europe_middle_east in as an argument would
%  skip the Asia clause on head unification and wrongly succeed.
zone_override('RU', Region, Lon, europe) :-
    continent_override('RU', Region, Lon, Continent),
    Continent == europe_middle_east.

%! hawaii_region(?IsoRegion) is nondet.
%  4(b) bars backtracking between Hawaii and other points in North America. That
%  is the one place the rule reaches inside a continent. For every other purpose,
%  Hawaii stays in North America.
hawaii_region('US-HI').

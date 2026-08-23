:- module(countries,
          [ country_continent/2,
            country_zone/2,
            country_known/1,
            countries_in/2
          ]).

/** <module> ISO country -> fare-rule continent.

    The base taxonomy here is the *IATA area* geography, not physical geography,
    because that is what Rule 3015 section 0 is written against. The rule's own
    parentheticals confirm it. "Europe (including Algeria, Morocco, Russia west
    of the Urals and Tunisia)" is exactly the IATA Europe area, and "Middle East
    (including Egypt, Libya and Sudan)" is the IATA Middle East area with Libya
    moved across.

    That is why the `continent` column in the OurAirports CSV must not be used:
    it holds physical geography. It puts Honolulu in Oceania, where the fare rule
    needs North America (see 4(b)); Dubai and Amman in Asia, where the fare rule
    needs Europe/Middle East; and Casablanca in Africa, where the fare rule needs
    Europe.

    Russia is not listed below. data/overrides.pl splits it at the Urals by
    longitude.
*/

% Group declarations expand into country_continent/2 facts at load time, so a
% lookup is a first-argument indexed match rather than a scan down a list.
term_expansion(continent_group(Cont, List), Facts) :-
    findall(country_continent(C, Cont), member(C, List), Facts).
term_expansion(zone_group(Zone, List), Facts) :-
    findall(country_zone(C, Zone), member(C, List), Facts).

:- discontiguous country_continent/2.
:- discontiguous country_zone/2.

% --- TC1 -------------------------------------------------------------------

% Section 0: "The continent of North America includes the Caribbean, Central
% America and Panama."
continent_group(north_america,
    [ 'CA','US','MX','GL','PM','BM','UM',
      'AG','AI','AW','BB','BL','BQ','BS','CU','CW','DM','DO','GD','GP','HT',
      'JM','KN','KY','LC','MF','MQ','MS','PR','SX','TC','TT','VC','VG','VI',
      'BZ','CR','GT','HN','NI','PA','SV'
    ]).

continent_group(south_america,
    [ 'AR','BO','BR','CL','CO','EC','FK','GF','GY','PE','PY','SR','UY','VE' ]).

% --- TC2 -------------------------------------------------------------------

% Europe/Middle East is one continent with two zones. The split is tracked
% separately because three things need it: 4(c)(b), on surface sectors within
% the Middle East; 4(e)'s closing sentence, which says "Europe" two lines after
% writing "Europe/Middle East" in full, and means the zone; and the section 12
% "sectors within Middle East" surcharge band.
continent_group(europe_middle_east,
    [ 'AD','AL','AM','AT','AZ','BA','BE','BG','BY','CH','CY','CZ','DE','DK',
      'DZ','EE','ES','FI','FO','FR','GB','GE','GG','GI','GR','HR','HU','IE',
      'IM','IS','IT','JE','LI','LT','LU','LV','MA','MC','MD','ME','MK','MT',
      'NL','NO','PL','PT','RO','RS','SE','SI','SJ','SK','SM','TN','TR','UA',
      'VA','XK',
      'AE','BH','EG','IL','IQ','IR','JO','KW','LB','LY','OM','PS','QA','SA',
      'SD','SY','YE'
    ]).

zone_group(europe,
    [ 'AD','AL','AM','AT','AZ','BA','BE','BG','BY','CH','CY','CZ','DE','DK',
      'DZ','EE','ES','FI','FO','FR','GB','GE','GG','GI','GR','HR','HU','IE',
      'IM','IS','IT','JE','LI','LT','LU','LV','MA','MC','MD','ME','MK','MT',
      'NL','NO','PL','PT','RO','RS','SE','SI','SJ','SK','SM','TN','TR','UA',
      'VA','XK'
    ]).

zone_group(middle_east,
    [ 'AE','BH','EG','IL','IQ','IR','JO','KW','LB','LY','OM','PS','QA','SA',
      'SD','SY','YE'
    ]).

% South Sudan stays in Africa. The rule text names only Sudan.
continent_group(africa,
    [ 'AO','BF','BI','BJ','BW','CD','CF','CG','CI','CM','CV','DJ','EH','ER',
      'ET','GA','GH','GM','GN','GQ','GW','KE','KM','LR','LS','MG','ML','MR',
      'MU','MW','MZ','NA','NE','NG','RE','RW','SC','SH','SL','SN','SO','SS',
      'ST','SZ','TD','TG','TZ','UG','YT','ZA','ZM','ZW'
    ]).

% --- TC3 -------------------------------------------------------------------

% Section 0: "The continent of Asia includes Kazakhstan, Kyrgyzstan, Russia
% east of the Urals, Tajikistan, Turkmenistan and Uzbekistan."
continent_group(asia,
    [ 'AF','BD','BN','BT','CN','HK','ID','IN','JP','KG','KH','KP','KR','KZ',
      'LA','LK','MM','MN','MO','MV','MY','NP','PH','PK','SG','TH','TJ','TL',
      'TM','TW','UZ','VN'
    ]).

% Cocos (CC) and Christmas Island (CX) are Australian external territories.
% Grouping them with Australia keeps PER-CCK and PER-XCH domestic, instead of
% making them look like intercontinental departures.
continent_group(south_west_pacific,
    [ 'AS','AU','CC','CK','CX','FJ','FM','GU','KI','MH','MP','NC','NF','NR',
      'NU','NZ','PF','PG','PW','SB','TO','TV','VU','WF','WS'
    ]).

%! country_known(?ISO) is nondet.
country_known(C) :- country_continent(C, _).

%! countries_in(+Continent, -Sorted) is det.
countries_in(Cont, Sorted) :-
    findall(C, country_continent(C, Cont), Cs),
    sort(Cs, Sorted).

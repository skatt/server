%% -*- mode: nitrogen -*-
-module (info_tournaments).
-compile(export_all).
-include_lib("nitrogen_core/include/wf.hrl").
-include("gettext.hrl").
-include("setup.hrl").

main() ->
    #template { file=code:priv_dir(nsp_srv)++"/templates/bare.html" }.

title() -> webutils:title(?MODULE).

body() ->
    #template{file=code:priv_dir(nsp_srv)++"/templates/info_page.html"}.

content() -> 
    [
        info_gifts:menu(),
        case site_utils:detect_language() of
            "en" -> en();
            "tr" -> tr()
        end
    ].

tr() ->
    #template { file=code:priv_dir(nsp_srv)++"/templates/info_tournaments_tr.html" }.

en() ->
    #template { file=code:priv_dir(nsp_srv)++"/templates/info_tournaments_en.html" }.

api_event(Name, Tag, Args)->
  webutils:api_event(Name, Tag, Args).

event(Any)->
    webutils:event(Any).

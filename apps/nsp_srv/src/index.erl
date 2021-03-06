-module (index).
-compile(export_all).

-include_lib("nitrogen_core/include/wf.hrl").

-include("gettext.hrl").
-include("elements/records.hrl").
-include("setup.hrl").

main() -> #template { file=code:priv_dir(nsp_srv)++"/templates/base.html"}.

title() -> "Kakaranet Okey".

body() ->
  case wf:depickle(wf:q(x)) of
    Url when is_list(Url) ->
      case wf:user() of
        undefined -> wf:redirect(?_U("/login"));
        _User ->
          Dashboard = ?_U("/wall"),
          case Url of
            "" -> wf:redirect(Dashboard);
            _  -> wf:redirect_from_login(Dashboard)
          end
      end;
    _ -> no_need_to_login
  end,
  case wf:q(message) of
    undefined -> ok;
    Message -> show_message(Message)
  end,
  % gproc:reg({p,g,self()},case wf:user() of undefined -> "undefined"; X -> X end),
  Ctrls = case site_utils:detect_language() of
    "tr" -> ["Gifts", "Tournaments", "Be Social!", "MatchMaker", "HEMEN KATILIN"];
    _ -> ["Gifts", "Tournaments", "Be Social!", "MatchMaker"]
  end,
  [
  #panel{class="page-content", body=[
    #panel{class=slideshow, body="<img width=\"960\" height=\"352\" src=\"/images/slides/"++site_utils:detect_language()++"/slide1.png\">"},
    #panel{class=btns, body=[
      #link{text=?_T("More Info"), class="btn-dark", url=?_U("/info/gifts")}, %Detaylı Bilgi
      #link{text=?_T("LET'S PLAY!"), class="btn-yellow", url=?_U("/login/register")} %ÜYE OL!
    ]}
  ]},
  #panel{class="slideshow-control", body=[
    #panel{class="page-content", body=[
    #list{class=switcher, body=[#listitem{body=#link{text=?_T(L)}} || L <- Ctrls]},
    #list{class=pager, body=[
      #listitem{body=#link{class=prev, text="prev"}},
      #listitem{body=#link{class=next, text="next"}}
    ]}]}
  ]},
  #panel{class="page-content", body=webutils:quick_nav(true)}
  ].

%event(show_register) ->
%    wf:redirect(?_U("/login/register"));

event(Other) ->
  webutils:event(Other).

api_event(fbAutoLogin, Tag, Args)->
  case wf:q(message) of
    undefined -> fb_utils:api_event(fbAutoLogin, Tag, Args);
    _ -> skip
  end;
api_event(Name, Tag, Args)->
  webutils:api_event(Name, Tag, Args).

show_message(Message) ->
    Decoded = site_utils:base64_decode_from_url(Message),
    Element = webutils:lightbox_panel_template(simple_lightbox, [
        #h1{class="head", text=?_T("System message")},
        #panel{class=holder, body=[
            #panel{body=Decoded}, #br{},
            #cool_button{text=?_T("OK"), delegate=login, postback=hide_simpe_lightbox},
            #grid_clear{}
        ]}
    ]),
    wf:update(simple_panel, Element),
    wf:wire(simple_lightbox, #show{}).

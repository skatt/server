-module(nitrogen_cowboy).
-include_lib("nitrogen_core/include/wf.hrl").
-include("common.hrl").
-export([init/3, handle/2, terminate/2]).

-record(state, {headers, body}).

init({_Transport, http}, Req, Opts) ->
    Headers = proplists:get_value(headers, Opts, []),
    Body = proplists:get_value(body, Opts, "http_handler"),
    {ok, Req, #state{headers=Headers, body=Body}}.

handle(Req, _Opts) ->
    RequestBridge = simple_bridge:make_request(cowboy_request_bridge, {Req,code:priv_dir(nsw_srv)++"/static/"}), 
    ResponseBridge = simple_bridge:make_response(cowboy_response_bridge, RequestBridge),
    nitrogen:init_request(RequestBridge, ResponseBridge),
    nitrogen:handler(path_query_handler, []),
%    nitrogen:handler(dynamic_route_handler, []),
    nitrogen:handler(i18n_route_handler, []),
%    nitrogen:handler(nsw_srv_to_nitrogen_config_handler, []),
    {ok, NewReq} = nitrogen:run(),
    {ok, NewReq, _Opts}.

terminate(_Req, _State) ->
    ok.

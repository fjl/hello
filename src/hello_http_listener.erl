% Copyright (c) 2010-2011 by Travelping GmbH <info@travelping.com>

% Permission is hereby granted, free of charge, to any person obtaining a
% copy of this software and associated documentation files (the "Software"),
% to deal in the Software without restriction, including without limitation
% the rights to use, copy, modify, merge, publish, distribute, sublicense,
% and/or sell copies of the Software, and to permit persons to whom the
% Software is furnished to do so, subject to the following conditions:

% The above copyright notice and this permission notice shall be included in
% all copies or substantial portions of the Software.

% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
% DEALINGS IN THE SOFTWARE.

% @private
-module(hello_http_listener).
-behaviour(hello_binding).
-export([listener_childspec/2, listener_key/1, binding_key/1, url_for_log/1]).

%% http utils used by other listeners
-export([lookup_binding/4, unslash/1, default_port/1, server_header/0, req_transport_params/1]).
-export([process/3]).

-behaviour(cowboy_http_handler).
-export([init/3, handle/2, terminate/3]).

-include("internal.hrl").
-include("transport.hrl").
-include_lib("ex_uri/include/ex_uri.hrl").

%% --------------------------------------------------------------------------------
%% -- hello_binding callbacks
listener_childspec(ChildID, #binding{ip = IP, port = Port}) ->
    Acceptors = 30,
    TransOpts = [{port, default_port(Port)}, {ip, IP}],
    Dispatch = cowboy_router:compile([{'_', [{'_', ?MODULE, []}]}]),
    ProtoOpts = [{env, [{dispatch, Dispatch}]}],
    ranch:child_spec(ChildID, Acceptors, ranch_tcp, TransOpts, cowboy_protocol, ProtoOpts).

listener_key(#binding{ip = IP, port = Port}) ->
    hello_registry:listener_key(IP, default_port(Port)).

binding_key(#binding{host = Host, port = Port, path = Path}) ->
    {list_to_binary(Host), default_port(Port), unslash(Path)}.

url_for_log(#binding{url = URL}) ->
    list_to_binary(ex_uri:encode(URL)).

%% --------------------------------------------------------------------------------
%% -- request handling (callbacks for cowboy_http_handler)
init({tcp, http}, Req, _) ->
    {Port, Req1} = cowboy_req:port(Req),
    {Path, Req2} = cowboy_req:path(Req1),
    {Host, Req3} = cowboy_req:host(Req2),
    case hello_registry:lookup_cowboy_handler(Host, Port, Path) of
        {ok, _, {Mod, Args}} ->
            case Mod:init({tcp, http}, Req3, Args) of
                {ok, Req4, State} ->
                    {ok, Req4, {ext_handler, Mod, State}};
                Other ->
                    Other
            end;
        {error, not_found} ->
            {ok, Req3, undefined}
    end.

handle(Req, {ext_handler, Mod, State}) ->
    case Mod:handle(Req, State) of
        {ok, Req1, NewState} ->
            {ok, Req1, {ext_handler, Mod, NewState}};
        Other ->
            Other
    end;
handle(Req, State) ->
    {Method, Req1} = cowboy_req:method(Req),
    case lists:member(Method, [<<"PUT">>, <<"POST">>]) of
        true ->
            {Port, Req3} = cowboy_req:port(Req1),
            {Path, Req4} = cowboy_req:path(Req3),
            {Host, Req5} = cowboy_req:host(Req4),
            PathList     = unslash(Path),
            case lookup_binding(?MODULE, Host, Port, PathList) of
                {ok, Binding} ->
                    process(Binding, Req, State);
                {error, not_found} ->
                    {ok, Req6} = cowboy_req:reply(404, server_header(), Req5),
                    {ok, Req6, undefined}
            end;
        false ->
            {ok, Req2} = cowboy_req:reply(405, server_header(), Req1),
            {ok, Req2, undefined}
    end.

terminate(Reason, Req, {ext_handler, Mod, State}) ->
    Mod:terminate(Reason, Req, State);
terminate(_Reason, _Req, _State) ->
    ok.

process(Binding, Req, State) ->
    {Peer, Req1} = cowboy_req:peer(Req),
    {TransportParams, Req6} = req_transport_params(Req1),
    Handler = hello_binding:start_handler(Binding, Peer, self(), TransportParams),
    {ok, Body, Req7} = cowboy_req:body(Req6),
    hello_binding:incoming_message(Handler, Body),
    Req8 = cowboy_req:compact(Req7),
    handle_first_transport_message(Req8, Handler, State).

handle_first_transport_message(Req1, Handler, State) ->
    receive
        #hello_msg{handler = Handler, message = Message, closed = true} ->
            %% optimization: don't do chunked TE if there is only a single reply
            %% i.e. for simple stateless calls
            {ok, Req2} = cowboy_req:reply(200, json_headers(), Message, Req1),
            {ok, Req2, State};
        #hello_msg{handler = Handler, message = Message} ->
            {ok, Req2} = cowboy_req:chunked_reply(200, json_headers(), Req1),
            cowboy_req:chunk(Message, Req2),
            http_chunked_loop(Handler, Req2, State);
        #hello_closed{handler = Handler} ->
            {ok, Req1, State}
    end.

http_chunked_loop(Handler, Request, State) ->
    receive
        #hello_closed{handler = Handler} ->
            {ok, Request, State};
        #hello_msg{handler = Handler, message = Message, closed = Closed} ->
            cowboy_req:chunk(Message, Request),
            if
                Closed ->
                    http_chunked_loop(Handler, Request, State);
                true ->
                    {ok, Request, State}
            end
    end.

json_headers() ->
    {ok, Vsn} = application:get_key(hello, vsn),
    [{<<"Content-Type">>, <<"application/json">>},
     {<<"Server">>, erlang:list_to_binary("hello/" ++ Vsn)}].

server_header() ->
    {ok, Vsn} = application:get_key(hello, vsn),
    [{<<"Server">>, erlang:list_to_binary("hello/" ++ Vsn)}].

req_transport_params(Req1) ->
    {{PeerIP, PeerPort}, Req2} = cowboy_req:peer(Req1),
    {ProxyPeerIP, Req3} = proxy_peer_ip(Req2),
    {QSVals, Req4} = cowboy_req:qs_vals(Req3),
    {Cookies, Req5} = cowboy_req:cookies(Req4),
    TransportParams = [{peer_ip, PeerIP},
                       {peer_port, PeerPort},
                       {real_peer_ip, ProxyPeerIP},
                       {query_params, QSVals},
                       {cookie_params, Cookies}],
    {TransportParams, Req5}.

proxy_peer_ip(Req1) ->
    case cowboy_req:parse_header(<<"x-forwarded-for">>, Req1, []) of
        {ok, [Client | _], Req2} ->
            {Client, Req2};
        {_, _, Req2} ->
            {{PeerIP, _Port}, Req3} = cowboy_req:peer(Req2),
            {PeerIP, Req3}
    end.

lookup_binding(Module, Host, Port, PathList) ->
    case hello_registry:lookup_binding(Module, {Host, Port, PathList}) of
        {error, not_found} ->
            hello_registry:lookup_binding(Module, {<<"0.0.0.0">>, Port, PathList});
        Result ->
            Result
    end.

unslash(Path) ->
    [S || S <- re:split(Path, <<"/">>, [{return, binary}]), S /= <<>>].

default_port(undefined) -> 80;
default_port(Port)      -> Port.

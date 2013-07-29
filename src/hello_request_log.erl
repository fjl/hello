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
-module(hello_request_log).

-export([open/2, close/1, open_bad_requests/1, close_bad_requests/0, request/5,
         bad_request/5]).

-include("internal.hrl").

-type endpoint() :: atom() | pid().
-type resp() :: 'ok' | {'error', term()}.

-callback open(CallbackModule :: module(),
               Owner :: pid()) -> resp().
-callback open_bad_requests(Owner :: pid()) -> resp().
-callback close(CallbackModule :: module()) -> resp().
-callback close_bad_requests() -> resp().
-callback request(CallbackModule    :: module(),
                  Handler           :: atom(),
                  Endpoint          :: endpoint(),
                  Request           :: hello_proto:request(),
                  Response          :: hello_proto:response()) -> resp().
-callback bad_request(CallbackModule    :: module(),
                      Handler           :: atom(),
                      Endpoint          :: endpoint(),
                      Message           :: binary(),
                      Response          :: hello_proto:response()) -> resp().

-define(MOD, (get_handler())).

%% --------------------------------------------------------------------------------
%% -- API
-spec open(module(), pid()) -> resp().
open(CallbackModule, Owner) ->
    ?MOD:open(CallbackModule, Owner).

-spec open_bad_requests(pid()) -> resp().
open_bad_requests(Owner) ->
    ?MOD:open_bad_requests(Owner).

-spec close(module()) -> resp().
close(CallbackModule) ->
    ?MOD:close(CallbackModule).

-spec close_bad_requests() -> resp().
close_bad_requests() ->
    ?MOD:close_bad_requests().

-spec request(module(), atom(), endpoint(), hello_proto:request(),
              hello_proto:response()) -> resp().
request(CallbackModule, Handler, Endpoint, Request, Response) ->
    ?MOD:request(CallbackModule, Handler, Endpoint, Request, Response).

-spec bad_request(module(), atom(), endpoint(), binary(),
                  hello_proto:response()) -> resp().
bad_request(CallbackModule, Handler, Endpoint, Message, Response) ->
    ?MOD:bad_request(CallbackModule, Handler, Endpoint, Message, Response).

%% --------------------------------------------------------------------------------
%% -- Helpers

get_handler() ->
    case application:get_env(hello, log_handler) of
        undefined -> ?DEFAULT_LOG_HANDLER;
        {ok, Handler} when is_atom(Handler) -> Handler
    end.

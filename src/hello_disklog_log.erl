-module(hello_disklog_log).
-behaviour(hello_request_log).

-export([open/2, close/1, open_bad_requests/1, close_bad_requests/0, request/5,
         bad_request/5]).

-include("internal.hrl").

%% --------------------------------------------------------------------------------
%% -- API
open(CallbackModule, Owner) ->
    Name         = reg_key(CallbackModule),
    %% create the log dir
    {ok, LogDir} = application:get_env(hello, request_log_dir),
    ok = filelib:ensure_dir(filename:join(LogDir, ".")),
    File         = filename:join(LogDir, atom_to_list(CallbackModule) ++ ".log"),
    LogOptions   = [{name, Name}, {linkto, Owner}, {file, File}, {format, external}, {type, halt}],

    %% disk_log does reference counting internally, so we can open the log each time.
    %% the log will be closed when the last endpoint terminates.
    case disk_log:open(LogOptions) of
        {ok, _Log} ->
            ok;
        {repaired, _Log, _Recovered, _Badbytes} ->
            ok;
        {error, Error} ->
            {error, Error}
    end.

open_bad_requests(Owner) ->
    open(bad_requests, Owner).

close(CallbackModule) ->
    disk_log:close(reg_key(CallbackModule)).

close_bad_requests() ->
    close(bad_requests).

request(CallbackModule, Handler, Endpoint, Request, Response) ->
    Date = cowboy_clock:rfc1123(),
    Msg = <<Date/binary, " ", (fmt_handler(Handler))/binary, " ", Endpoint/binary, "\n",
            (fmt_request(Request))/binary, (fmt_response(Response))/binary, "\n">>,
    disk_log:blog(reg_key(CallbackModule), Msg).

bad_request(CallbackModule, Handler, Endpoint, Message, Response) ->
    Date = cowboy_clock:rfc1123(),
    Msg = <<Date/binary,
            " ", (atom_to_binary(CallbackModule, latin1))/binary,
            " ", (fmt_handler(Handler))/binary,
            " ", Endpoint/binary, "\n",
            (escape_badreq(Message))/binary, "\n",
            (fmt_response(Response))/binary>>,
    disk_log:blog(reg_key(bad_requests), Msg).

%% --------------------------------------------------------------------------------
%% -- helpers
-compile({inline,reg_key/1}).
reg_key(Module) ->
    {hello_request_log, Module}.

fmt_handler(Pid) ->
    list_to_binary(pid_to_list(Pid)).

fmt_request(#request{reqid = undefined, method = Method, params = Params}) ->
    <<"{\"method\":", (hello_json:encode(Method))/binary,
      ",\"params\":", (hello_json:encode(Params))/binary, "}\n">>;
fmt_request(#request{reqid = ReqId, method = Method, params = Params}) ->
    <<"{\"id\":", (hello_json:encode(ReqId))/binary,
      ",\"method\":", (hello_json:encode(Method))/binary,
      ",\"params\":", (hello_json:encode(Params))/binary, "}\n">>;
fmt_request(#batch_request{requests = Requests}) ->
    lists:foldl(fun (Req, Acc) ->
                        <<Acc/binary, "\t", (fmt_request(Req))/binary>>
                end, <<"Batch Request:\n">>, Requests).

fmt_response(ignore) ->
    <<>>;
fmt_response(#response{reqid = ReqId, result = Result}) ->
    <<"{\"id\":", (hello_json:encode(ReqId))/binary,
      ",\"result\":", (hello_json:encode(Result))/binary, "}\n">>;
fmt_response(#error{reqid = ReqId, code = Code, message = Message, data = Data}) ->
    <<"{\"id\":", (hello_json:encode(ReqId))/binary,
      (maybe_undefined(<<",\"code\":">>, Code))/binary,
      (maybe_undefined(<<",\"message\":">>, Message))/binary,
      (maybe_undefined(<<",\"data\": ">>, Data))/binary, "}\n">>;
fmt_response(#batch_response{responses = Responses}) ->
    lists:foldl(fun (Resp, Acc) ->
                        <<Acc/binary, "\t", (fmt_response(Resp))/binary>>
                end, <<"Batch Response:\n">>, Responses).

-compile([{inline, maybe_undefined/2}]).
maybe_undefined(_Key, undefined) -> <<>>;
maybe_undefined(Key, Value) -> <<Key/binary, (hello_json:encode(Value))/binary>>.

-compile([{inline, escape_badreq/1}]).
escape_badreq(Message) ->
    << <<(escape_byte(Byte))/binary>> || <<Byte>> <= Message >>.

-compile([{inline, escape_byte/1}]).
escape_byte(Byte) when Byte < 16 ->
    <<"\\x0", (<< <<Chr:8>> || Chr <- integer_to_list(Byte, 16) >>)/binary>>;
escape_byte(Byte) when Byte < 32; Byte > 126 ->
    <<"\\x", (<< <<Chr:8>> || Chr <- integer_to_list(Byte, 16) >>)/binary>>;
escape_byte($\\) ->
    <<"\\\\">>;
escape_byte($") ->
    <<"\\\"">>;
escape_byte(Byte) ->
    <<Byte>>.

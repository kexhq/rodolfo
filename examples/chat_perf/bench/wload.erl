#!/usr/bin/env escript
%%! -smp enable
%% wload.erl — multi-process WebSocket saturating loader for the chat rooms.
%%
%% Why not Node: bench.mjs/bench2.mjs run all N connections through one
%% process, so the generator's event loop caps out (~250% CPU observed) while
%% the server idles on slow-client backpressure. Here every connection is its
%% own BEAM process across all schedulers; each keeps local counters and a
%% local latency histogram, so there is no central receive bottleneck. The
%% coordinator only exchanges tiny control messages.
%%
%%   escript wload.erl --port 3000 --clients 1000 --proto delta \
%%       --senders 20 --soak 15 --payload 1024
%%   escript wload.erl --selftest   # no sockets, verifies codec + handshake
-mode(compile).

-define(GUID, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").
-define(JOIN_TIMEOUT_MS, 90000).
-define(DRAIN_TIMEOUT_MS, 30000).
-define(HIST_BOUNDS_US,
        [100,250,500,750,1000,1500,2000,3000,4000,5000,7500,10000,
         25000,50000,100000,250000,500000,1000000,2000000,5000000]).

-record(cfg, {port = 3000, clients = 10, rung = "10", proto = delta,
              senders = 1, flood = 200, soak = 0, payload = 90,
              wave = 0, wavegap = 0, sync = false,
              paced = 30, gap = 100}).

main(Args) ->
    case lists:member("--selftest", Args) of
        true -> selftest();
        false ->
            case lists:member("--probe", Args) of
                true -> probe(parse_args(Args, #cfg{}));
                false -> run(parse_args(Args, #cfg{}))
            end
    end.

%% Single-connection debugger: prints the raw handshake reply head and
%% the first frames the server sends after join. Exits 0 when joined.
probe(Cfg) ->
    Name = "wprobe0",
    Path = ["/chat?token=let-me-in&name=", Name],
    case gen_tcp:connect("127.0.0.1", Cfg#cfg.port,
                         [binary, {packet, raw}, {active, false}], 15000) of
        {error, Reason} ->
            io:format("PROBE connect failed: ~p~n", [Reason]),
            halt(1);
        {ok, Sock} ->
            Key = base64:encode(crypto:strong_rand_bytes(16)),
            Req = ["GET ", Path, " HTTP/1.1\r\n",
                   "Host: 127.0.0.1:", integer_to_list(Cfg#cfg.port), "\r\n",
                   "Upgrade: websocket\r\n",
                   "Connection: Upgrade\r\n",
                   "Sec-WebSocket-Key: ", Key, "\r\n",
                   "Sec-WebSocket-Version: 13\r\n\r\n"],
            ok = gen_tcp:send(Sock, Req),
            case gen_tcp:recv(Sock, 0, 15000) of
                {error, Reason} ->
                    io:format("PROBE recv failed: ~p~n", [Reason]),
                    halt(1);
                {ok, Resp} ->
                    Head = binary:part(Resp, 0, min(300, byte_size(Resp))),
                    io:format("PROBE status: ~s~n", [hd(binary:split(Resp, <<"\r\n">>))]),
                    io:format("PROBE head: ~p~n", [Head]),
                    io:format("PROBE accept-ok: ~p~n",
                              [extract_header(Resp, <<"sec-websocket-accept">>) =:= accept_key(Key)]),
                    probe_frames(Sock, Resp, Name, 0)
            end
    end.

probe_frames(_Sock, _Carry, _Name, 8) ->
    io:format("PROBE done (8 frames shown)~n"),
    halt(0);
probe_frames(Sock, Carry, Name, N) ->
    {ok, Frames, Rest} = decode_frames(carry_rest(Carry), []),
    case Frames of
        [] ->
            case gen_tcp:recv(Sock, 0, 10000) of
                {error, Reason} ->
                    io:format("PROBE frame-recv failed after ~p frames: ~p~n", [N, Reason]),
                    halt(1);
                {ok, More} -> probe_frames(Sock, More, Name, N)
            end;
        _ ->
            [io:format("PROBE frame: ~p~n", [F]) || F <- Frames],
            Joined = lists:any(fun({text, L}) -> L =:= iolist_to_binary(["* ", Name, " joined"]);
                                  (_) -> false end, Frames),
            case Joined of
                true ->
                    io:format("PROBE JOINED~n"),
                    probe_send(Sock, Name);
                false -> probe_frames(Sock, Rest, Name, N + length(Frames))
            end
    end.

probe_send(Sock, Name) ->
    Msg = iolist_to_binary([Name, ": #1 t", integer_to_list(mono_us()), " hello-probe"]),
    io:format("PROBE sending ~p bytes: ~p~n", [byte_size(Msg), Msg]),
    ok = gen_tcp:send(Sock, encode_client_text(<<"#1 t000 hello-probe">>)),
    probe_echo(Sock, 0).

probe_echo(_Sock, 6) ->
    io:format("PROBE no echo seen, giving up~n"),
    halt(1);
probe_echo(Sock, N) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {error, Reason} ->
            io:format("PROBE echo-recv failed: ~p~n", [Reason]),
            halt(1);
        {ok, Data} ->
            {ok, Frames, _} = decode_frames(Data, []),
            [io:format("PROBE echo-frame: ~p~n", [F]) || F <- Frames],
            case lists:any(fun({text, L}) -> binary:match(L, <<"hello-probe">>) =/= nomatch;
                              (_) -> false end, Frames) of
                true -> io:format("PROBE ECHO OK~n"), halt(0);
                false -> probe_echo(Sock, N + 1)
            end
    end.

carry_rest(Bin) ->
    case binary:match(Bin, <<"\r\n\r\n">>) of
        {Pos, Len} -> binary:part(Bin, Pos + Len, byte_size(Bin) - Pos - Len);
        nomatch -> Bin
    end.

%% ---------------------------------------------------------------- args

parse_args([], C) -> C;
parse_args(["--port", V | R], C) -> parse_args(R, C#cfg{port = list_to_integer(V)});
parse_args(["--clients", V | R], C) ->
    parse_args(R, C#cfg{clients = list_to_integer(V), rung = V});
parse_args(["--rung", V | R], C) -> parse_args(R, C#cfg{rung = V});
parse_args(["--proto", "classic" | R], C) -> parse_args(R, C#cfg{proto = classic});
parse_args(["--proto", _ | R], C) -> parse_args(R, C#cfg{proto = delta});
parse_args(["--senders", V | R], C) -> parse_args(R, C#cfg{senders = list_to_integer(V)});
parse_args(["--flood", V | R], C) -> parse_args(R, C#cfg{flood = list_to_integer(V), soak = 0});
parse_args(["--soak", V | R], C) -> parse_args(R, C#cfg{soak = list_to_integer(V)});
parse_args(["--payload", V | R], C) -> parse_args(R, C#cfg{payload = list_to_integer(V)});
parse_args(["--wave", V | R], C) -> parse_args(R, C#cfg{wave = list_to_integer(V)});
parse_args(["--wavegap", V | R], C) -> parse_args(R, C#cfg{wavegap = list_to_integer(V)});
parse_args(["--sync" | R], C) -> parse_args(R, C#cfg{sync = true});
parse_args(["--paced", V | R], C) -> parse_args(R, C#cfg{paced = list_to_integer(V)});
parse_args(["--gap", V | R], C) -> parse_args(R, C#cfg{gap = list_to_integer(V)});
parse_args(["--probe" | R], C) -> parse_args(R, C);
parse_args([Unknown | R], C) ->
    io:format(standard_error, "wload: ignoring unknown arg ~s~n", [Unknown]),
    parse_args(R, C).

%% ---------------------------------------------------------------- selftest

selftest() ->
    %% RFC 6455 §1.3 handshake vector.
    <<"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=">> =
        accept_key(<<"dGhlIHNhbXBsZSBub25jZQ==">>),
    %% Frame codec round-trips: empty, tiny, 125/126-boundary, 16-bit
    %% extended, and 64-bit extended lengths.
    lists:foreach(
      fun(N) ->
              Payload = binary:copy(<<"x">>, N),
              Wire = iolist_to_binary(encode_client_text(Payload)),
              {ok, [{text, Dec}], <<>>} = decode_frames(Wire, []),
              Payload = Dec
      end, [0, 5, 125, 126, 300, 65535, 66000]),
    %% Unmasked server frame decodes too.
    {ok, [{text, <<"hi">>}], <<>>} =
        decode_frames(<<16#81, 2, "hi">>, []),
    %% Control frames are classified, not mistaken for data.
    {ok, [{ping, <<"p">>}], <<>>} =
        decode_frames(<<16#89, 1, "p">>, []),
    %% Send-timestamp extraction from flood payloads, including the
    %% negative monotonic readings this host produces.
    {ok, 123456789} = extract_ts(<<"b1u3: #42 t123456789 xxxxx">>),
    {ok, -42} = extract_ts(<<"w0: #7 t-42 xx">>),
    nomatch = extract_ts(<<"* w0 joined">>),
    aggtest(),
    io:format("SELFTEST OK~n"),
    halt(0).

%% Exercises the coordinator's poll/collect/merge/percentile/JSON path
%% with fake clients — no sockets involved.
aggtest() ->
    N = 50,
    Pids = [spawn(fun() -> fake_client(I) end) || I <- lists:seq(1, N)],
    Joined = lists:zip(lists:seq(1, N), Pids),
    true = poll_counts(Joined, N * 10, 5000),
    0 = sum_sent(Joined),
    Stats = stop_all(Joined),
    N = length(Stats),
    Rep = summarize_phase(Stats, N * 10, true, #{}),
    0 = maps:get(loss, Rep),
    Got = maps:get(deliveries_ok, Rep),
    true = (Got =:= N * 10),
    true = maps:get(p95, maps:get(per_delivery_latency_ms, Rep)) >= 0.5,
    [P ! {teardown} || {_, P} <- Joined],
    ok.

fake_client(I) ->
    receive
        {report_count, From} ->
            From ! {count, self(), 10},
            fake_client(I);
        {report_sent, From} ->
            From ! {sent_count, self(), 0},
            fake_client(I);
        {stop_phase, From} ->
            D = 400 + I * 10,
            From ! {phase_stats, self(),
                    #{deliveries => 10, hist => hist_add(D, zero_hist()),
                      sum => 10 * D, min => D, max => D,
                      last_recv => 2000000 + I, sent => 0, send_errors => 0,
                      first_send => 1000000, closed => false}},
            fake_client(I);
        {teardown} ->
            exit(normal)
    end.

%% ---------------------------------------------------------------- codec

accept_key(Key) ->
    base64:encode(crypto:hash(sha, [Key, ?GUID])).

%% Client-to-server text frame (always masked per RFC 6455 §5.3).
encode_client_text(Payload) ->
    Len = byte_size(Payload),
    Mask = crypto:strong_rand_bytes(4),
    <<M1, M2, M3, M4>> = Mask,
    Masked = mask(Payload, M1, M2, M3, M4, 0, <<>>),
    Hdr = case Len of
              N when N < 126 -> <<16#81, (16#80 bor N)>>;
              N when N < 65536 -> <<16#81, (16#80 bor 126), N:16>>;
              N -> <<16#81, (16#80 bor 127), N:64>>
          end,
    [Hdr, Mask, Masked].

mask(<<>>, _, _, _, _, _, Acc) -> Acc;
mask(<<B, Rest/binary>>, M1, M2, M3, M4, I, Acc) ->
    M = case I rem 4 of 0 -> M1; 1 -> M2; 2 -> M3; 3 -> M4 end,
    mask(Rest, M1, M2, M3, M4, I + 1, <<Acc/binary, (B bxor M)>>).

%% Returns {ok, [{text|ping|pong|close, binary()}], Rest}.
decode_frames(Bin, Acc) -> decode_frames(Bin, Acc, []).

decode_frames(Bin, _Acc, Out) when byte_size(Bin) < 2 ->
    {ok, lists:reverse(Out), Bin};
decode_frames(<<FinOp:8, MaskLen:8, Rest/binary>> = All, _Acc, Out) ->
    Len0 = MaskLen band 16#7F,
    Masked = (MaskLen band 16#80) =/= 0,
    Op = FinOp band 16#0F,
    case ext_len(Len0, Rest) of
        more -> {ok, lists:reverse(Out), All};
        {Len, R1} ->
            Skip = Len + (case Masked of true -> 4; false -> 0 end),
            case byte_size(R1) < Skip of
                true -> {ok, lists:reverse(Out), All};
                false ->
                    {Payload, R2} = case Masked of
                        false -> split_binary(R1, Len);
                        true ->
                            <<M1, M2, M3, M4, RMasked/binary>> = R1,
                            {M, RR} = split_binary(RMasked, Len),
                            {mask(M, M1, M2, M3, M4, 0, <<>>), RR}
                    end,
                    Kind = case Op of
                               16#1 -> text; 16#2 -> text;
                               16#8 -> close; 16#9 -> ping; 16#A -> pong;
                               _ -> other
                           end,
                    %% Continuations (0x0) are appended to the previous text.
                    case {Op, Out} of
                        {16#0, [{text, Prev} | T]} ->
                            decode_frames(R2, [], [{text, <<Prev/binary, Payload/binary>>} | T]);
                        _ ->
                            decode_frames(R2, [], [{Kind, Payload} | Out])
                    end
            end
    end.

ext_len(Len0, Rest) when Len0 < 126 -> {Len0, Rest};
ext_len(126, Rest) when byte_size(Rest) >= 2 ->
    <<N:16, R/binary>> = Rest, {N, R};
ext_len(127, Rest) when byte_size(Rest) >= 8 ->
    <<N:64, R/binary>> = Rest, {N, R};
ext_len(_, _) -> more.

%% Flood payloads look like "<name>: #<n> t<mono_us> <pad>", where the
%% timestamp is a (possibly negative) monotonic microsecond clock reading.
%% Returns {ok, Ts}, or nomatch when the line is not a flood delivery.
extract_ts(Line) ->
    case binary:match(Line, <<" t">>) of
        nomatch -> nomatch;
        {Pos, _} ->
            Rest = binary:part(Line, Pos + 2, byte_size(Line) - Pos - 2),
            {ok, parse_ts(Rest)}
    end.

parse_ts(<<$-, Rest/binary>>) -> -digits(Rest, 0);
parse_ts(Rest) -> digits(Rest, 0).

digits(<<C, R/binary>>, Acc) when C >= $0, C =< $9 ->
    digits(R, Acc * 10 + (C - $0));
digits(_, Acc) -> Acc.

%% ---------------------------------------------------------------- handshake

connect(Path, Host, Port) ->
    SockOpts = [binary, {packet, raw}, {active, false}, {nodelay, true},
                {recbuf, 1 bsl 20}, {sndbuf, 1 bsl 20}, {keepalive, true}],
    case gen_tcp:connect(Host, Port, SockOpts, 15000) of
        {error, Reason} -> {error, Reason};
        {ok, Sock} -> handshake(Sock, Path, Port)
    end.

handshake(Sock, Path, Port) ->
    Key = base64:encode(crypto:strong_rand_bytes(16)),
    Req = ["GET ", Path, " HTTP/1.1\r\n",
           "Host: 127.0.0.1:", integer_to_list(Port), "\r\n",
           "Upgrade: websocket\r\n",
           "Connection: Upgrade\r\n",
           "Sec-WebSocket-Key: ", Key, "\r\n",
           "Sec-WebSocket-Version: 13\r\n\r\n"],
    case gen_tcp:send(Sock, Req) of
        {error, Reason} -> gen_tcp:close(Sock), {error, Reason};
        ok ->
            case read_headers(Sock, <<>>) of
                {error, Reason} -> gen_tcp:close(Sock), {error, Reason};
                {ok, Resp} ->
                    case binary:match(Resp, <<" 101 ">>) of
                        nomatch -> gen_tcp:close(Sock), {error, no_101};
                        _ ->
                            Want = accept_key(Key),
                            case extract_header(Resp, <<"sec-websocket-accept">>) of
                                Got when Got =:= Want -> {ok, Sock};
                                _ -> gen_tcp:close(Sock), {error, bad_accept}
                            end
                    end
            end
    end.

read_headers(Sock, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        {_, _} -> {ok, Acc};
        nomatch ->
            case gen_tcp:recv(Sock, 0, 15000) of
                {ok, More} -> read_headers(Sock, <<Acc/binary, More/binary>>);
                {error, Reason} -> {error, Reason}
            end
    end.

extract_header(Resp, Name) ->
    Prefix = string:lowercase(binary_to_list(Name)) ++ ":",
    Lines = binary:split(Resp, <<"\r\n">>, [global]),
    find_header(Lines, Prefix).

find_header([], _) -> <<>>;
find_header([L | Rest], Prefix) ->
    %% Compare the prefix case-insensitively but slice the value out of the
    %% ORIGINAL line: header values (base64 here) are case-sensitive.
    S = string:lowercase(binary_to_list(binary:part(L, 0, min(byte_size(L), length(Prefix))))),
    case S =:= Prefix of
        true ->
            V = binary:part(L, length(Prefix), byte_size(L) - length(Prefix)),
            list_to_binary(string:trim(binary_to_list(V)));
        false -> find_header(Rest, Prefix)
    end.

%% ---------------------------------------------------------------- client

%% Per-connection process. Owns one socket for its whole lifetime; all
%% delivery counting and latency bucketing is local, so the coordinator
%% never sees per-message traffic.
client(Coord, Idx, Name, Cfg) ->
    T0 = mono_ms(),
    Port = Cfg#cfg.port,
    Path = ["/chat?token=let-me-in&name=", uri_encode(Name)],
    case connect(Path, "127.0.0.1", Port) of
        {error, Reason} ->
            Coord ! {join_failed, self(), Reason},
            exit(normal);
        {ok, Sock} ->
            inet:setopts(Sock, [{active, 100}]),
            case await_join(Sock, Name, Cfg, <<>>) of
                {error, Reason} ->
                    Coord ! {join_failed, self(), Reason},
                    exit(normal);
                {ok, Rest} ->
                    Coord ! {joined, self(), mono_ms() - T0},
                    S0 = mono_ms(),
                    Sync = maybe_sync(Coord, Sock, Name, Cfg, Rest),
                    Coord ! {synced, self(), maps:get(pages, Sync),
                             maps:get(miss, Sync), mono_ms() - S0},
                    idle(Coord, Idx, Name, Cfg, Sock, Rest, Sync)
            end
    end,
    ok.

uri_encode(Name) -> uri_string:quote(Name).

await_join(Sock, Name, Cfg, Buf) ->
    Deadline = mono_ms() + ?JOIN_TIMEOUT_MS,
    await_join(Sock, Name, Cfg, Buf, Deadline).

await_join(Sock, Name, Cfg, Buf, Deadline) ->
    receive
        {tcp, Sock, Data} ->
            B = <<Buf/binary, Data/binary>>,
            {Lines, Rest} = take_frames(B),
            case joined_yet(Lines, Name, Cfg#cfg.proto) of
                true -> {ok, Rest};
                false -> await_join(Sock, Name, Cfg, Rest, Deadline)
            end;
        {tcp_passive, Sock} ->
            inet:setopts(Sock, [{active, 100}]),
            await_join(Sock, Name, Cfg, Buf, Deadline);
        {tcp_closed, Sock} -> {error, closed_before_join};
        {tcp_error, Sock, R} -> {error, R}
    after 5000 ->
        case mono_ms() > Deadline of
            true -> {error, join_timeout};
            false -> await_join(Sock, Name, Cfg, Buf, Deadline)
        end
    end.

joined_yet([], _, _) -> false;
joined_yet([{text, L} | T], Name, classic) ->
    BN = list_to_binary(Name),
    case L of
        <<"$users:", R/binary>> ->
            lists:member(BN, binary:split(R, <<",">>, [global])) orelse
                joined_yet(T, Name, classic);
        _ -> joined_yet(T, Name, classic)
    end;
joined_yet([{text, L} | T], Name, delta) ->
    Want = iolist_to_binary(["* ", Name, " joined"]),
    (L =:= Want) orelse joined_yet(T, Name, delta);
joined_yet([_ | T], Name, Proto) -> joined_yet(T, Name, Proto).

%% take_frames parses complete WS frames out of Buf, returning only text
%% lines plus leftover bytes (ping/pong/close are handled in phase_loop).
take_frames(Bin) ->
    {ok, Frames, Rest} = decode_frames(Bin, []),
    {filter_text(Frames), Rest}.

filter_text(Frames) ->
    [{text, P} || {text, P} <- Frames].

maybe_sync(_Coord, _Sock, _Name, #cfg{sync = false}, _Rest) -> #{pages => 0, miss => false};
maybe_sync(_Coord, Sock, Name, #cfg{sync = true, proto = delta}, Rest) ->
    ok = gen_tcp:send(Sock, encode_client_text(<<"$roster:1">>)),
    collect_pages(Sock, Name, Rest, sets:new(), 0, mono_ms() + 60000);
maybe_sync(_Coord, _Sock, _Name, _Cfg, _Rest) ->
    #{pages => 0, miss => false}.

collect_pages(Sock, Name, Buf, Seen, Pages, Deadline) ->
    receive
        {tcp, Sock, Data} ->
            B = <<Buf/binary, Data/binary>>,
            {Lines, Rest} = take_frames(B),
            collect_lines(Lines, Sock, Name, Rest, Seen, Pages, Deadline);
        {tcp_passive, Sock} ->
            inet:setopts(Sock, [{active, 100}]),
            collect_pages(Sock, Name, Buf, Seen, Pages, Deadline);
        _ ->
            #{pages => Pages, miss => true}
    after 5000 ->
        case mono_ms() > Deadline of
            true -> #{pages => Pages, miss => true};
            false -> collect_pages(Sock, Name, Buf, Seen, Pages, Deadline)
        end
    end.

collect_lines([], Sock, Name, Rest, Seen, Pages, Deadline) ->
    collect_pages(Sock, Name, Rest, Seen, Pages, Deadline);
collect_lines([{text, L} | T], Sock, Name, Rest, Seen, Pages, Deadline) ->
    case parse_users(L) of
        {Pg, Pgs, Names} ->
            S2 = lists:foldl(fun(N, S) -> sets:add_element(N, S) end, Seen, Names),
            case Pg < Pgs of
                true ->
                    ok = gen_tcp:send(Sock, encode_client_text(
                        iolist_to_binary(["$roster:", integer_to_list(Pg + 1)]))),
                    collect_lines(T, Sock, Name, Rest, S2, Pages + 1, Deadline);
                false ->
                    #{pages => Pages + 1,
                      miss => not sets:is_element(list_to_binary(Name), S2)}
            end;
        nomatch ->
            collect_lines(T, Sock, Name, Rest, Seen, Pages, Deadline)
    end.

parse_users(<<"$users:", R/binary>>) ->
    case binary:split(R, <<":">>) of
        [PgPgs, NamesB] ->
            case binary:split(PgPgs, <<"/">>) of
                [PgB, PgsB] ->
                    {binary_to_integer(PgB), binary_to_integer(PgsB),
                     binary:split(NamesB, <<",">>, [global])};
                _ -> nomatch
            end;
        _ -> nomatch
    end;
parse_users(_) -> nomatch.

idle(Coord, Idx, Name, Cfg, Sock, Buf, Sync) ->
    receive
        {go_phase, Phase, IsSender, Spec} ->
            St = new_phase_stats(),
            St2 = case IsSender of
                      true -> blast(Coord, Sock, Name, Cfg, Phase, Spec, St);
                      false -> St
                  end,
            phase_loop(Coord, Idx, Name, Cfg, Sock, Buf, Sync, Phase, Spec, St2);
        {teardown} ->
            catch gen_tcp:close(Sock),
            exit(normal)
    end.

%% The sender blast: count-mode sends K messages; soak-mode sends until
%% the deadline or an end_sending notice. Inbox is polled every 64 sends
%% so a soak stop lands promptly; receives queue and are counted after.
blast(Coord, Sock, Name, _Cfg, _Phase, Spec, St) ->
    PadSize = maps:get(payload, Spec),
    case maps:get(mode, Spec) of
        {count, K, GapMs} -> blast_count(Sock, Name, PadSize, K, GapMs, St, 0);
        {soak, DeadlineUs} -> blast_soak(Coord, Sock, Name, PadSize, DeadlineUs, St, 0)
    end.

blast_count(_, _, _, 0, _, St, _) -> St;
blast_count(Sock, Name, PadSize, K, GapMs, St, N) ->
    St2 = send_one(Sock, Name, PadSize, St, N),
    case GapMs > 0 of
        true -> timer:sleep(GapMs);
        false -> ok
    end,
    blast_count(Sock, Name, PadSize, K - 1, GapMs, St2, N + 1).

blast_soak(Coord, Sock, Name, PadSize, DeadlineUs, St, N) ->
    St2 = send_one(Sock, Name, PadSize, St, N),
    Next = N + 1,
    Stop = case Next rem 64 of
               0 -> check_stop(Coord);
               _ -> mono_us() >= DeadlineUs
           end,
    case Stop of
        true -> St2;
        false -> blast_soak(Coord, Sock, Name, PadSize, DeadlineUs, St2, Next)
    end.

check_stop(Coord) ->
    receive
        {end_sending, Coord} -> true
    after 0 ->
        false
    end.

send_one(Sock, Name, PadSize, St, N) ->
    Ts = mono_us(),
    Msg = flood_line(Name, N, Ts, PadSize),
    case gen_tcp:send(Sock, encode_client_text(Msg)) of
        ok -> St#{sent => maps:get(sent, St) + 1,
                  first_send => min_opt(maps:get(first_send, St), Ts)};
        {error, _} -> St#{send_errors => maps:get(send_errors, St) + 1}
    end.

flood_line(Name, N, Ts, PadSize) ->
    Head = iolist_to_binary([Name, ": #", integer_to_list(N),
                             " t", integer_to_list(Ts), " "]),
    Pad = max(0, PadSize - byte_size(Head)),
    <<Head/binary, (binary:copy(<<"x">>, Pad))/binary>>.

min_opt(undefined, B) -> B;
min_opt(A, B) when A < B -> A;
min_opt(_, B) -> B.

max_opt(undefined, B) -> B;
max_opt(A, B) when A > B -> A;
max_opt(_, B) -> B.

new_phase_stats() ->
    #{deliveries => 0, hist => zero_hist(), sum => 0,
      min => undefined, max => undefined, last_recv => undefined,
      sent => 0, send_errors => 0, first_send => undefined,
      closed => false}.

zero_hist() -> lists:duplicate(length(?HIST_BOUNDS_US) + 1, 0).

hist_add(Us, Hist) -> hist_add(Us, Hist, ?HIST_BOUNDS_US).

hist_add(Us, [H | T], [B | _]) when Us =< B -> [H + 1 | T];
hist_add(Us, [H | T], [_ | Bs]) -> [H | hist_add(Us, T, Bs)];
hist_add(_, [H | T], []) -> [H + 1 | T].

phase_loop(Coord, Idx, Name, Cfg, Sock, Buf, Sync, Phase, Spec, St) ->
    receive
        {tcp, Sock, Data} ->
            B = <<Buf/binary, Data/binary>>,
            {ok, Frames, Rest} = decode_frames(B, []),
            St2 = handle_frames(Frames, Sock, St),
            phase_loop(Coord, Idx, Name, Cfg, Sock, Rest, Sync, Phase, Spec, St2);
        {tcp_passive, Sock} ->
            inet:setopts(Sock, [{active, 100}]),
            phase_loop(Coord, Idx, Name, Cfg, Sock, Buf, Sync, Phase, Spec, St);
        {tcp_closed, Sock} ->
            phase_loop(Coord, Idx, Name, Cfg, Sock, Buf, Sync, Phase, Spec,
                       St#{closed => true});
        {report_count, From} ->
            From ! {count, self(), maps:get(deliveries, St)},
            phase_loop(Coord, Idx, Name, Cfg, Sock, Buf, Sync, Phase, Spec, St);
        {end_sending, _From} ->
            %% Fire-and-forget: the blast already finished, and sent counts
            %% are collected separately via report_sent, so no reply here —
            %% a reply would leave a stale sent_count for collect_sent.
            phase_loop(Coord, Idx, Name, Cfg, Sock, Buf, Sync, Phase, Spec, St);
        {report_sent, From} ->
            From ! {sent_count, self(), maps:get(sent, St)},
            phase_loop(Coord, Idx, Name, Cfg, Sock, Buf, Sync, Phase, Spec, St);
        {stop_phase, From} ->
            From ! {phase_stats, self(), St},
            idle(Coord, Idx, Name, Cfg, Sock, Buf, Sync);
        {teardown} ->
            catch gen_tcp:close(Sock),
            exit(normal)
    end.

handle_frames([], _, St) -> St;
handle_frames([{text, P} | T], Sock, St) ->
    Now = mono_us(),
    St2 = case extract_ts(P) of
              {ok, Ts} ->
                  D = Now - Ts,
                  St#{deliveries => maps:get(deliveries, St) + 1,
                      hist => hist_add(D, maps:get(hist, St)),
                      sum => maps:get(sum, St) + D,
                      min => min_opt(maps:get(min, St), D),
                      max => max_opt(maps:get(max, St), D),
                      last_recv => max_opt(maps:get(last_recv, St), Now)};
              nomatch -> St
          end,
    handle_frames(T, Sock, St2);
handle_frames([{ping, P} | T], Sock, St) ->
    catch gen_tcp:send(Sock, [<<16#8A, (byte_size(P))>>, P]),
    handle_frames(T, Sock, St);
handle_frames([{close, _} | T], Sock, St) ->
    catch gen_tcp:send(Sock, <<16#88, 0>>),
    handle_frames(T, Sock, St#{closed => true});
handle_frames([_ | T], Sock, St) ->
    handle_frames(T, Sock, St).

%% ---------------------------------------------------------------- coordinator

run(Cfg) ->
    N = Cfg#cfg.clients,
    Rung = Cfg#cfg.rung,
    Names = [lists:concat(["w", Rung, "u", I]) || I <- lists:seq(0, N - 1)],
    TStart = mono_ms(),
    TJoin0 = mono_ms(),
    %% Preload crypto before 1000 sockets eat every fd (emfile cascade).
    _ = crypto:strong_rand_bytes(16),
    phase_log("spawning", N),
    Pids = spawn_clients(Names, Cfg),
    {Joined, Failed, JoinLats, Early} = wait_join(Pids, mono_ms() + ?JOIN_TIMEOUT_MS),
    JoinWall = mono_ms() - TJoin0,
    Ok = length(Joined),
    phase_log("joined", Ok),
    %% {synced,...} messages that arrived during the join storm are
    %% re-queued so the sync wait below sees every client exactly once.
    [self() ! M || M <- Early],
    SyncRep = case Cfg#cfg.sync of
                  true -> wait_sync(Ok, 0, 0, [], 60000);
                  false -> #{clients => 0, pages_fetched => 0, misses => 0,
                             per_client => null}
              end,
    PacedRep = case Cfg#cfg.paced > 0 andalso Ok > 0 of
                   true -> phase_log("paced-start", 0),
                           R = run_paced(Joined, Cfg, Ok),
                           phase_log("paced-done", 0), R;
                   false -> null
               end,
    FloodRep = case Ok > 0 of
                   true -> phase_log("flood-start", 0),
                           R2 = run_flood(Joined, Cfg, Ok),
                           phase_log("flood-done", 0), R2;
                   false -> null
               end,
    [P ! {teardown} || {_, P} <- Joined],
    timer:sleep(1000),
    Out = #{tool => <<"wload">>, rung => list_to_binary(Rung),
            clients => N, port => Cfg#cfg.port,
            proto => atom_to_binary(Cfg#cfg.proto),
            senders => min(Cfg#cfg.senders, Ok),
            payload_bytes => Cfg#cfg.payload,
            join => #{ok => Ok, failed => Failed,
                      wall_ms => JoinWall,
                      per_client => cstats(JoinLats)},
            roster_sync => SyncRep,
            paced => PacedRep,
            flood => FloodRep,
            wall_total_s => (mono_ms() - TStart) / 1000,
            ok => Ok > 0},
    io:format("~s~n", [json:encode(Out)]),
    halt(0).

spawn_clients(Names, Cfg) ->
    spawn_clients(Names, Cfg, 0, []).

spawn_clients([], _, _, Acc) -> lists:reverse(Acc);
spawn_clients(Names, Cfg, Idx, Acc) ->
    Wave = Cfg#cfg.wave,
    {Batch, Rest} = case Wave > 0 of
                        true -> lists:split(min(Wave, length(Names)), Names);
                        false -> {Names, []}
                    end,
    Pids = [spawn_monitored_client(Idx + I, Nm, Cfg)
            || {I, Nm} <- lists:zip(lists:seq(0, length(Batch) - 1), Batch)],
    case Rest of
        [] -> lists:reverse(Pids, Acc);
        _ -> timer:sleep(Cfg#cfg.wavegap),
             spawn_clients(Rest, Cfg, Idx + length(Batch), lists:reverse(Pids, Acc))
    end.

spawn_monitored_client(Idx, Name, Cfg) ->
    Coord = self(),
    Pid = spawn(fun() -> client(Coord, Idx, Name, Cfg) end),
    erlang:monitor(process, Pid),
    {Idx, Pid}.

%% Rem is the outstanding [{Idx,Pid}] spawn list. Returns
%% {Joined::[{Idx,Pid}], Failed, JoinLats, EarlySync}.
wait_join(Rem, Deadline) ->
    wait_join_loop(Rem, [], 0, [], [], Deadline).

wait_join_loop([], Joined, Failed, Lats, Early, _) ->
    {Joined, Failed, Lats, Early};
wait_join_loop(Rem, Joined, Failed, Lats, Early, Deadline) ->
    receive
        {joined, Pid, Ms} ->
            Idx = proplists:get_value(Pid, [{P, I} || {I, P} <- Rem], 0),
            wait_join_loop(lists:keydelete(Pid, 2, Rem), [{Idx, Pid} | Joined],
                           Failed, [Ms | Lats], Early, Deadline);
        {synced, _, _, _, _} = M ->
            wait_join_loop(Rem, Joined, Failed, Lats, [M | Early], Deadline);
        {join_failed, Pid, _} ->
            wait_join_loop(lists:keydelete(Pid, 2, Rem), Joined,
                           Failed + 1, Lats, Early, Deadline);
        {'DOWN', _, process, Pid, _} ->
            case lists:keyfind(Pid, 2, Rem) of
                false ->
                    wait_join_loop(Rem, Joined, Failed, Lats, Early, Deadline);
                _ ->
                    wait_join_loop(lists:keydelete(Pid, 2, Rem), Joined,
                                   Failed + 1, Lats, Early, Deadline)
            end
    after 1000 ->
        case mono_ms() > Deadline of
            true -> {Joined, Failed + length(Rem), Lats, Early};
            false -> wait_join_loop(Rem, Joined, Failed, Lats, Early, Deadline)
        end
    end.

wait_sync(Want, Got, Pages, Misses, Timeout) ->
    T0 = mono_ms(),
    wait_sync_loop(Want, Got, Pages, Misses, T0 + Timeout).

wait_sync_loop(Want, Got, Pages, Misses, _Deadline) when Got >= Want ->
    #{clients => Got, pages_fetched => Pages, misses => Misses};
wait_sync_loop(Want, Got, Pages, Misses, Deadline) ->
    case mono_ms() > Deadline of
        true -> #{clients => Got, pages_fetched => Pages, misses => Misses,
                  timed_out => true};
        false ->
            receive
                {synced, _From, P, M, _} when is_integer(P) ->
                    Miss = case M of true -> 1; false -> 0 end,
                    wait_sync_loop(Want, Got + 1, Pages + P, Misses + Miss,
                                   Deadline);
                {synced, From, P, M, _} ->
                    io:format(standard_error,
                              "WLOAD bad-sync from=~p pages=~p miss=~p~n",
                              [From, P, M]),
                    wait_sync_loop(Want, Got + 1, Pages, Misses, Deadline)
            after 1000 ->
                wait_sync_loop(Want, Got, Pages, Misses, Deadline)
            end
    end.

%% Note: clients also emit {synced,...} when sync is disabled (pages=0);
%% the sync wait is skipped then, and those messages sit in the mailbox.
%% drain_synced/0 discards them before phase polling so counts stay clean.
drain_synced() ->
    receive
        {synced, _, _, _, _} -> drain_synced()
    after 0 -> ok
    end.

run_paced(Joined, Cfg, Ok) ->
    drain_synced(),
    K = Cfg#cfg.paced,
    Spec = #{mode => {count, K, Cfg#cfg.gap}, payload => Cfg#cfg.payload},
    [{_, Sender} | _] = Joined,
    [P ! {go_phase, paced, P =:= Sender, Spec} || {_, P} <- Joined],
    Expected = K * Ok,
    Done = poll_counts(Joined, Expected, K * Cfg#cfg.gap + 15000),
    Stats = stop_all(Joined),
    summarize_phase(Stats, Expected, Done, #{rate_per_s => K / (K * Cfg#cfg.gap / 1000)}).

run_flood(Joined, Cfg, Ok) ->
    drain_synced(),
    S = min(Cfg#cfg.senders, Ok),
    Sorted = lists:sort(Joined),
    Senders = [P || {_, P} <- lists:sublist(Sorted, S)],
    case Cfg#cfg.soak > 0 of
        true ->
            Deadline = mono_us() + Cfg#cfg.soak * 1000000,
            Spec = #{mode => {soak, Deadline}, payload => Cfg#cfg.payload},
            [P ! {go_phase, flood, lists:member(P, Senders), Spec} || {_, P} <- Joined],
            timer:sleep(Cfg#cfg.soak * 1000),
            [P ! {end_sending, self()} || P <- Senders],
            timer:sleep(2000),
            Sent = sum_sent(Joined),
            Expected = Sent * Ok,
            Done = poll_counts(Joined, Expected, ?DRAIN_TIMEOUT_MS),
            Stats = stop_all(Joined),
            summarize_phase(Stats, Expected, Done, #{soak_s => Cfg#cfg.soak, sent => Sent});
        false ->
            K = Cfg#cfg.flood,
            Spec = #{mode => {count, K, 0}, payload => Cfg#cfg.payload},
            [P ! {go_phase, flood, lists:member(P, Senders), Spec} || {_, P} <- Joined],
            Expected = K * S * Ok,
            Done = poll_counts(Joined, Expected, 120000),
            Stats = stop_all(Joined),
            summarize_phase(Stats, Expected, Done, #{})
    end.

poll_counts(Joined, Expected, TimeoutMs) ->
    poll_counts(Joined, Expected, mono_ms() + TimeoutMs, 0).

poll_counts(_, Expected, _, Total) when Total >= Expected -> true;
poll_counts(Joined, Expected, Deadline, _) ->
    case mono_ms() > Deadline of
        true -> false;
        false ->
            [P ! {report_count, self()} || {_, P} <- Joined],
            Total = collect_counts(length(Joined), 0),
            case Total >= Expected of
                true -> true;
                false -> timer:sleep(200), poll_counts(Joined, Expected, Deadline, Total)
            end
    end.

collect_counts(0, Acc) -> Acc;
collect_counts(N, Acc) ->
    receive
        {count, _, C} -> collect_counts(N - 1, Acc + C);
        {synced, _, _, _, _} -> collect_counts(N, Acc);
        {phase_stats, _, _} -> collect_counts(N, Acc)
    after 5000 -> Acc
    end.

sum_sent(Joined) ->
    [P ! {report_sent, self()} || {_, P} <- Joined],
    collect_sent(length(Joined), 0).

collect_sent(0, Acc) -> Acc;
collect_sent(N, Acc) ->
    receive
        {sent_count, _, C} -> collect_sent(N - 1, Acc + C);
        {synced, _, _, _, _} -> collect_sent(N, Acc);
        {count, _, _} -> collect_sent(N, Acc)
    after 5000 -> Acc
    end.

stop_all(Joined) ->
    [P ! {stop_phase, self()} || {_, P} <- Joined],
    collect_stats(length(Joined), []).

collect_stats(0, Acc) -> Acc;
collect_stats(N, Acc) ->
    receive
        {phase_stats, _, St} -> collect_stats(N - 1, [St | Acc]);
        {synced, _, _, _, _} -> collect_stats(N, Acc);
        {count, _, _} -> collect_stats(N, Acc)
    after 10000 -> Acc
    end.

summarize_phase(StatsList, Expected, Completed, Extra) ->
    {Hist, Sum, Min, Max, Got, First, Last, Sent, SErr} =
        lists:foldl(
          fun(St, {H, Su, Mi, Ma, G, F, L, Se, E}) ->
                  H2 = lists:zipwith(fun(A, B) -> A + B end, H, maps:get(hist, St)),
                  {H2, Su + maps:get(sum, St),
                   min_opt(Mi, maps:get(min, St)), max_opt(Ma, maps:get(max, St)),
                   G + maps:get(deliveries, St),
                   min_opt(F, maps:get(first_send, St)),
                   max_opt(L, maps:get(last_recv, St)),
                   Se + maps:get(sent, St), E + maps:get(send_errors, St)}
          end, {zero_hist(), 0, undefined, undefined, 0, undefined, undefined, 0, 0}, StatsList),
    WallS = case {First, Last} of
                {undefined, _} -> 0.0;
                {_, undefined} -> 0.0;
                {F, L} when L > F -> (L - F) / 1000000;
                _ -> 0.0
            end,
    Lat = latency_stats(Hist, Got, Sum, Min, Max),
    Base = #{completed => Completed, timed_out => not Completed,
             wall_s => round3(WallS),
             msgs_per_s => rate(Sent, WallS),
             fanout_deliveries_per_s => round(Got / max(WallS, 0.001)),
             deliveries_ok => Got, deliveries_expected => Expected,
             loss => Expected - Got,
             send_errors => SErr,
             per_delivery_latency_ms => Lat},
    maps:merge(Base, Extra).

rate(_, Wall) when Wall =< 0 -> 0.0;
rate(Sent, Wall) -> round3(Sent / Wall).

round3(F) -> round(F * 1000) / 1000.

latency_stats(Hist, Total, Sum, Min, Max) when Total > 0 ->
    Q = fun(P) -> pct(Hist, Total, P) end,
    Mean = Sum / Total,
    #{n => Total, p50 => Q(0.5), p95 => Q(0.95), p99 => Q(0.99),
      max => us_ms(Max), min => us_ms(or_zero(Min)), mean => round3(Mean / 1000)};
latency_stats(_, _, _, _, _) -> null.

or_zero(undefined) -> 0;
or_zero(V) -> V.

us_ms(Us) -> round3(Us / 1000).

%% First histogram upper-bound (ms) whose cumulative share exceeds Q.
pct(Hist, Total, Q) ->
    pct(Hist, ?HIST_BOUNDS_US, Total * Q, 0).

pct([H | _], [B | _], Need, Acc) when Acc + H >= Need -> round3(B / 1000);
pct([H | T], [_ | Bs], Need, Acc) -> pct(T, Bs, Need, Acc + H);
pct([_], [], _, _) -> round3(lists:last(?HIST_BOUNDS_US) * 2 / 1000);
pct([], [], _, _) -> 0.0.

cstats([]) -> null;
cstats(L) ->
    S = lists:sort(L),
    N = length(S),
    #{n => N, p50 => lists:nth(N div 2 + 1, S),
      p95 => lists:nth(min(N, trunc(0.95 * N) + 1), S),
      p99 => lists:nth(min(N, trunc(0.99 * N) + 1), S),
      max => lists:last(S), min => hd(S)}.

phase_log(What, N) ->
    io:format(standard_error, "WLOAD ~s n=~p t=~p~n", [What, N, mono_ms()]).

%% ---------------------------------------------------------------- time

mono_us() -> erlang:monotonic_time(microsecond).
mono_ms() -> erlang:monotonic_time(millisecond).

% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(ddoc_cache_entry_test).


-export([
    recover/1
]).


-include_lib("couch/include/couch_db.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("ddoc_cache_test.hrl").


recover(<<"foo">>) ->
    timer:sleep(30000);

recover(DbName) ->
    {ok, {DbName, such_custom}}.


start_couch() ->
    Ctx = ddoc_cache_tutil:start_couch(),
    meck:new(ddoc_cache_ev, [passthrough]),
    Ctx.


stop_couch(Ctx) ->
    meck:unload(),
    ddoc_cache_tutil:stop_couch(Ctx).


check_entry_test_() ->
    {
        setup,
        fun start_couch/0,
        fun stop_couch/1,
        {with, [
            fun cancel_and_replace_opener/1,
            fun condenses_access_messages/1,
            fun kill_opener_on_terminate/1,
            fun open_dead_entry/1,
            fun handles_bad_messages/1,
            fun handles_code_change/1
        ]}
    }.


cancel_and_replace_opener(_) ->
    Key = {ddoc_cache_entry_custom, {<<"foo">>, ?MODULE}},
    true = ets:insert_new(?CACHE, #entry{key = Key}),
    {ok, Entry} = ddoc_cache_entry:start_link(Key),
    Opener1 = element(4, sys:get_state(Entry)),
    Ref1 = erlang:monitor(process, Opener1),
    gen_server:cast(Entry, refresh),
    receive {'DOWN', Ref1, _, _, _} -> ok end,
    Opener2 = element(4, sys:get_state(Entry)),
    ?assert(Opener2 /= Opener1),
    ?assert(is_process_alive(Opener2)),
    % Clean up after ourselves
    unlink(Entry),
    ddoc_cache_entry:shutdown(Entry).


condenses_access_messages({DbName, _}) ->
    meck:reset(ddoc_cache_ev),
    Key = {ddoc_cache_entry_custom, {DbName, ?MODULE}},
    true = ets:insert(?CACHE, #entry{key = Key}),
    {ok, Entry} = ddoc_cache_entry:start_link(Key),
    erlang:suspend_process(Entry),
    lists:foreach(fun(_) ->
        gen_server:cast(Entry, accessed)
    end, lists:seq(1, 100)),
    erlang:resume_process(Entry),
    meck:wait(1, ddoc_cache_ev, event, [accessed, Key], 1000),
    ?assertError(
            timeout,
            meck:wait(2, ddoc_cache_ev, event, [accessed, Key], 100)
        ),
    unlink(Entry),
    ddoc_cache_entry:shutdown(Entry).


kill_opener_on_terminate(_) ->
    Pid = spawn(fun() -> receive _ -> ok end end),
    ?assert(is_process_alive(Pid)),
    St = {st, key, val, Pid, waiters, ts},
    ?assertEqual(ok, ddoc_cache_entry:terminate(normal, St)),
    ?assert(not is_process_alive(Pid)).


open_dead_entry({DbName, _}) ->
    Pid = spawn(fun() -> ok end),
    Key = {ddoc_cache_entry_custom, {DbName, ?MODULE}},
    ?assertEqual(recover(DbName), ddoc_cache_entry:open(Pid, Key)).


handles_bad_messages(_) ->
    CallExpect = {stop, {bad_call, foo}, {bad_call, foo}, baz},
    CastExpect = {stop, {bad_cast, foo}, bar},
    InfoExpect = {stop, {bad_info, foo}, bar},
    ?assertEqual(CallExpect, ddoc_cache_entry:handle_call(foo, bar, baz)),
    ?assertEqual(CastExpect, ddoc_cache_entry:handle_cast(foo, bar)),
    ?assertEqual(InfoExpect, ddoc_cache_entry:handle_info(foo, bar)).


handles_code_change(_) ->
    CCExpect = {ok, bar},
    ?assertEqual(CCExpect, ddoc_cache_entry:code_change(foo, bar, baz)).
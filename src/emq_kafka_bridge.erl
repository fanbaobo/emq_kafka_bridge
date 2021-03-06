%%--------------------------------------------------------------------
%% Copyright (c) 2015-2017 Feng Lee <feng@emqtt.io>.
%%
%% Modified by Ramez Hanna <rhanna@iotblue.net>
%% 
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emq_kafka_bridge).

-include("emq_kafka_bridge.hrl").

-include_lib("emqttd/include/emqttd.hrl").

-include_lib("emqttd/include/emqttd_protocol.hrl").

-include_lib("emqttd/include/emqttd_internal.hrl").

-import(string,[concat/2]).
-import(lists,[nth/2]). 

-export([load/1, unload/0]).

%% Hooks functions

-export([on_client_connected/3, on_client_disconnected/3]).

% -export([on_client_subscribe/4, on_client_unsubscribe/4]).

% -export([on_session_created/3, on_session_subscribed/4, on_session_unsubscribed/4, on_session_terminated/4]).

-export([on_message_publish/2, on_message_delivered/4, on_message_acked/4]).


%% Called when the plugin application start
load(Env) ->
	ekaf_init([Env]),
    emqttd:hook('client.connected', fun ?MODULE:on_client_connected/3, [Env]),
    emqttd:hook('client.disconnected', fun ?MODULE:on_client_disconnected/3, [Env]),
    emqttd:hook('message.publish', fun ?MODULE:on_message_publish/2, [Env]),
    emqttd:hook('message.delivered', fun ?MODULE:on_message_delivered/4, [Env]),
    emqttd:hook('message.acked', fun ?MODULE:on_message_acked/4, [Env]).

on_client_connected(ConnAck, Client, _Env) ->
    % io:format("client ~s connected, connack: ~w~n", [ClientId, ConnAck]),
    % produce_kafka_payload(mochijson2:encode([
    %     {type, <<"event">>},
    %     {status, <<"connected">>},
    %     {deviceId, ClientId}
    % ])),
    % produce_kafka_payload(<<"event">>, Client),
    {ok, Event} = format_event(connected, Client),
    produce_kafka_payload(Event),
    {ok, Client}.

on_client_disconnected(Reason, _Client, _Env) ->
    % io:format("client ~s disconnected, reason: ~w~n", [ClientId, Reason]),
    % Message = mochijson2:encode([
    %     {type, },
    %     {status, <<"disconnected">>},
    %     {deviceId, ClientId}
    % ]),
    % produce_kafka_payload(<<"event">>, _Client),
    {ok, Event} = format_event(disconnected, _Client),
    produce_kafka_payload(Event),	
    ok.

%% transform message and return
on_message_publish(Message = #mqtt_message{topic = <<"$SYS/", _/binary>>}, _Env) ->
    {ok, Message};

on_message_publish(Message, _Env) ->
    % io:format("publish message : ~s~n", [emqttd_message:format(Message)]),
    {ok, Payload} = format_payload(Message),
    produce_kafka_payload(Payload),	
    {ok, Message}.

on_message_delivered(ClientId, Username, Message, _Env) ->
    % io:format("delivered to client(~s/~s): ~s~n", [Username, ClientId, emqttd_message:format(Message)]),
    {ok, Message}.

on_message_acked(ClientId, Username, Message, _Env) ->
    % io:format("client(~s/~s) acked: ~s~n", [Username, ClientId, emqttd_message:format(Message)]),
    {ok, Message}.

ekaf_init(_Env) ->
    {ok, BrokerValues} = application:get_env(emq_kafka_bridge, broker),
    KafkaHost = proplists:get_value(host, BrokerValues),
    KafkaPort = proplists:get_value(port, BrokerValues),
    KafkaPartitionStrategy= proplists:get_value(partitionstrategy, BrokerValues),
    KafkaPartitionWorkers= proplists:get_value(partitionworkers, BrokerValues),
    application:set_env(ekaf, ekaf_bootstrap_broker,  {KafkaHost, list_to_integer(KafkaPort)}),
    application:set_env(ekaf, ekaf_partition_strategy, KafkaPartitionStrategy),
    application:set_env(ekaf, ekaf_per_partition_workers, KafkaPartitionWorkers),
    application:set_env(ekaf, ekaf_buffer_ttl, 10),
    application:set_env(ekaf, ekaf_max_downtime_buffer_size, 5),
    % {ok, _} = application:ensure_all_started(kafkamocker),
    {ok, _} = application:ensure_all_started(gproc),
    % {ok, _} = application:ensure_all_started(ranch),    
    {ok, _} = application:ensure_all_started(ekaf).

format_event(Action, Client) ->
    Event = [{action, Action},
                {device_id, Client#mqtt_client.client_id},
                {username, Client#mqtt_client.username}],
    {ok, Event}.

format_payload(Message) ->
    {ClientId, Username} = format_from(Message#mqtt_message.from),
    Payload = [{action, message_publish},
                  {device_id, ClientId},
                  {username, Username},
                  {topic, Message#mqtt_message.topic},
                  {payload, Message#mqtt_message.payload},
                  {ts, emqttd_time:now_secs(Message#mqtt_message.timestamp)}],
    {ok, Payload}.

format_from({ClientId, Username}) ->
    {ClientId, Username};
format_from(From) when is_atom(From) ->
    {a2b(From), a2b(From)};
format_from(_) ->
    {<<>>, <<>>}.

a2b(A) -> erlang:atom_to_binary(A, utf8).

%% Called when the plugin application stop
unload() ->
    emqttd:unhook('client.connected', fun ?MODULE:on_client_connected/3),
    emqttd:unhook('client.disconnected', fun ?MODULE:on_client_disconnected/3),
    % emqttd:unhook('client.subscribe', fun ?MODULE:on_client_subscribe/4),
    % emqttd:unhook('client.unsubscribe', fun ?MODULE:on_client_unsubscribe/4),
    % emqttd:unhook('session.subscribed', fun ?MODULE:on_session_subscribed/4),
    % emqttd:unhook('session.unsubscribed', fun ?MODULE:on_session_unsubscribed/4),
    emqttd:unhook('message.publish', fun ?MODULE:on_message_publish/2),
    emqttd:unhook('message.delivered', fun ?MODULE:on_message_delivered/4),
    emqttd:unhook('message.acked', fun ?MODULE:on_message_acked/4).

produce_kafka_payload(Message) ->
    Topic = <<"Processing">>,
    Payload = iolist_to_binary(mochijson2:encode(Message)),
    ekaf:produce_async_batched(Topic, Payload).
    % ekaf:produce_async(Topic, Payload).
	% io:format("send to kafka payload topic: ~s, data: ~s~n", [Topic, Payload]),
	% {ok, KafkaValue} = application:get_env(emq_kafka_bridge, broker),
	% Topic = proplists:get_value(payloadtopic, KafkaValue),
    % lager:debug("send to kafka payload topic: ~s, data: ~s~n", [Topic, Message]),
    

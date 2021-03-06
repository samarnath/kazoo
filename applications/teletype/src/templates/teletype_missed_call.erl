%%%-------------------------------------------------------------------
%%% @copyright (C) 2017, 2600Hz Inc
%%% @doc
%%%
%%% @end
%%% @contributors
%%%-------------------------------------------------------------------
-module(teletype_missed_call).

-export([init/0
        ,handle_missed_call/1
        ]).

-include("teletype.hrl").

-define(MOD_CONFIG_CAT, <<(?NOTIFY_CONFIG_CAT)/binary, ".missed_call">>).

-define(TEMPLATE_ID, <<"missed_call">>).

-define(TEMPLATE_MACROS
       ,kz_json:from_list(
          [?MACRO_VALUE(<<"missed_call.reason">>, <<"missed_call_reasom">>, <<"Missed Call Reason">>, <<"Reason why the call is terminated without been bridged or left a voicemail message">>)
           | ?DEFAULT_CALL_MACROS
           ++ ?USER_MACROS
           ++ ?COMMON_TEMPLATE_MACROS
          ]
         )
       ).

-define(TEMPLATE_SUBJECT, <<"Missed call from {{caller_id.name}} ({{caller_id.number}})">>).
-define(TEMPLATE_CATEGORY, <<"sip">>).
-define(TEMPLATE_NAME, <<"Missed Call">>).

-define(TEMPLATE_TO, ?CONFIGURED_EMAILS(?EMAIL_ORIGINAL)).
-define(TEMPLATE_FROM, teletype_util:default_from_address(?MOD_CONFIG_CAT)).
-define(TEMPLATE_CC, ?CONFIGURED_EMAILS(?EMAIL_SPECIFIED, [])).
-define(TEMPLATE_BCC, ?CONFIGURED_EMAILS(?EMAIL_SPECIFIED, [])).
-define(TEMPLATE_REPLY_TO, teletype_util:default_reply_to(?MOD_CONFIG_CAT)).

-spec init() -> 'ok'.
init() ->
    kz_util:put_callid(?MODULE),
    teletype_templates:init(?TEMPLATE_ID, [{'macros', ?TEMPLATE_MACROS}
                                          ,{'subject', ?TEMPLATE_SUBJECT}
                                          ,{'category', ?TEMPLATE_CATEGORY}
                                          ,{'friendly_name', ?TEMPLATE_NAME}
                                          ,{'to', ?TEMPLATE_TO}
                                          ,{'from', ?TEMPLATE_FROM}
                                          ,{'cc', ?TEMPLATE_CC}
                                          ,{'bcc', ?TEMPLATE_BCC}
                                          ,{'reply_to', ?TEMPLATE_REPLY_TO}
                                          ]),
    teletype_bindings:bind(<<"missed_call">>, ?MODULE, 'handle_missed_call').

-spec handle_missed_call(kz_json:object()) -> 'ok'.
handle_missed_call(JObj) ->
    'true' = kapi_notifications:missed_call_v(JObj),
    kz_util:put_callid(JObj),

    %% Gather data for template
    DataJObj = kz_json:normalize(JObj),

    AccountId = kz_json:get_value(<<"account_id">>, DataJObj),
    case teletype_util:is_notice_enabled(AccountId, JObj, ?TEMPLATE_ID) of
        'false' -> teletype_util:notification_disabled(DataJObj, ?TEMPLATE_ID);
        'true' -> process_req(DataJObj)
    end.

-spec process_req(kz_json:object()) -> 'ok'.
process_req(DataJObj) ->
    teletype_util:send_update(DataJObj, <<"pending">>),

    Macros = [{<<"system">>, teletype_util:system_params()}
             ,{<<"account">>, teletype_util:account_params(DataJObj)}
             ,{<<"missed_call">>,  build_missed_call_data(DataJObj)}
              | teletype_util:build_call_data(DataJObj, 'undefined')
             ],

    %% Populate templates
    RenderedTemplates = teletype_templates:render(?TEMPLATE_ID, Macros, DataJObj),

    AccountId = kz_json:get_value(<<"account_id">>, DataJObj),
    {'ok', TemplateMetaJObj} = teletype_templates:fetch_notification(?TEMPLATE_ID, AccountId),

    Subject =
        teletype_util:render_subject(
          kz_json:find(<<"subject">>, [DataJObj, TemplateMetaJObj], ?TEMPLATE_SUBJECT), Macros
         ),

    Emails = teletype_util:find_addresses(DataJObj, TemplateMetaJObj, ?MOD_CONFIG_CAT),

    case teletype_util:send_email(Emails, Subject, RenderedTemplates) of
        'ok' -> teletype_util:send_update(DataJObj, <<"completed">>);
        {'error', Reason} -> teletype_util:send_update(DataJObj, <<"failed">>, Reason)
    end.

-spec build_missed_call_data(kz_json:object()) -> kz_proplist().
build_missed_call_data(DataJObj) ->
    [{<<"reason">>, missed_call_reason(DataJObj)}
    ,{<<"is_bridged">>, kz_term:is_true(kz_json:get_value(<<"call_bridged">>, DataJObj))}
    ,{<<"is_message_left">>, kz_term:is_true(kz_json:get_value(<<"message_left">>, DataJObj))}
    ].

-spec missed_call_reason(kz_json:object()) -> ne_binary().
missed_call_reason(DataJObj) ->
    missed_call_reason(DataJObj, kz_json:get_ne_binary_value([<<"notify">>, <<"hangup_cause">>], DataJObj)).

-spec missed_call_reason(kz_json:object(), api_ne_binary()) -> ne_binary().
missed_call_reason(_DataJObj, 'undefined') -> <<"no voicemail message was left">>;
missed_call_reason(_DataJObj, HangupCause) -> binary:replace(HangupCause, <<"_">>, <<" ">>, [global]).

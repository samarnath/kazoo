-module(kz_ast_util).

-export([module_ast/1
        ,add_module_ast/3

        ,ast_to_list_of_binaries/1
        ,binary_match_to_binary/1
        ,smash_snake/1

        ,schema_path/1
        ,api_path/1
        ,ensure_file_exists/1
        ,create_schema/1
        ,schema_to_table/1
        ,load_ref_schema/1

        ,project_apps/0, app_modules/1
        ]).

-include_lib("kazoo_ast/include/kz_ast.hrl").
-include_lib("kazoo_stdlib/include/kz_types.hrl").
-include_lib("kazoo_stdlib/include/kazoo_json.hrl").
-include_lib("kazoo_amqp/src/api/kapi_dialplan.hrl").
-include_lib("kazoo_amqp/src/api/kapi_call.hrl").

-type ast() :: [erl_parse:abstract_form()].
-type abstract_code() :: {'raw_abstract_v1', ast()}.

-export_type([abstract_code/0
             ,ast/0
             ]).

-define(SCHEMA_SECTION, <<"#### Schema\n\n">>).
-define(SUB_SCHEMA_SECTION_HEADER, <<"#####">>).

-spec module_ast(atom()) -> {atom(), abstract_code()} | 'undefined'.
module_ast(M) ->
    case code:which(M) of
        'non_existing' -> 'undefined';
        'preloaded' -> 'undefined';
        Beam ->
            {'ok', {Module, [{'abstract_code', AST}]}} = beam_lib:chunks(Beam, ['abstract_code']),
            {Module, AST}
    end.

-spec add_module_ast(module_ast(), module(), abstract_code()) -> module_ast().
add_module_ast(ModAST, Module, {'raw_abstract_v1', Attributes}) ->
    F = fun(A, Acc) -> add_module_ast_fold(A, Module, Acc) end,
    lists:foldl(F, ModAST, Attributes).

-spec add_module_ast_fold(ast(), module(), module_ast()) -> module_ast().
add_module_ast_fold(?AST_FUNCTION(F, Arity, Clauses), Module, #module_ast{functions=Fs}=Acc) ->
    Acc#module_ast{functions=[{Module, F, Arity, Clauses}|Fs]};
add_module_ast_fold(?AST_RECORD(Name, Fields), _Module, #module_ast{records=Rs}=Acc) ->
    Acc#module_ast{records=[{Name, Fields}|Rs]};
add_module_ast_fold(_Other, _Module, Acc) ->
    Acc.

-spec ast_to_list_of_binaries(erl_parse:abstract_expr()) -> ne_binaries().
ast_to_list_of_binaries(ASTList) ->
    ast_to_list_of_binaries(ASTList, []).

ast_to_list_of_binaries(?APPEND(First, Second), Binaries) ->
    ast_to_list_of_binaries(Second, ast_to_list_of_binaries(First, Binaries));
ast_to_list_of_binaries(?EMPTY_LIST, Binaries) ->
    lists:reverse(Binaries);
ast_to_list_of_binaries(?MOD_FUN_ARGS('kapi_dialplan', 'optional_bridge_req_headers', []), Binaries) ->
    ?OPTIONAL_BRIDGE_REQ_HEADERS ++ Binaries;
ast_to_list_of_binaries(?MOD_FUN_ARGS('kapi_dialplan', 'optional_bridge_req_endpoint_headers', []), Binaries) ->
    ?OPTIONAL_BRIDGE_REQ_ENDPOINT_HEADERS ++ Binaries;
ast_to_list_of_binaries(?MOD_FUN_ARGS('kapi_call', 'optional_call_event_headers', []), Binaries) ->
    ?OPTIONAL_CALL_EVENT_HEADERS ++ Binaries;
ast_to_list_of_binaries(?LIST(?LIST(_, _)=H, T), Binaries) ->
    ast_to_list_of_binaries(T, [ast_to_list_of_binaries(H) | Binaries]);
ast_to_list_of_binaries(?LIST(H, T), Binaries) ->
    ast_to_list_of_binaries(T, [binary_match_to_binary(H) | Binaries]).

-spec binary_match_to_binary(erl_parse:abstract_expr()) -> binary().
binary_match_to_binary(?ATOM(A)) -> kz_term:to_binary(A);
binary_match_to_binary(?BINARY_STRING(V)) ->
    kz_term:to_binary(V);
binary_match_to_binary(?BINARY_MATCH(Match)) ->
    binary_match_to_binary(Match);
binary_match_to_binary(?FUN_ARGS(atom_to_binary, [?ATOM(Atom), ?ATOM(utf8)])) ->
    atom_to_binary(Atom, utf8);
binary_match_to_binary(Match) when is_list(Match) ->
    iolist_to_binary(
      [binary_part_to_binary(BP) || BP <- Match]
     ).

binary_part_to_binary(?BINARY_STRING(V)) -> V;
binary_part_to_binary(?SUB_BINARY(V)) -> V;
binary_part_to_binary(?BINARY_MATCH(Ms)) -> binary_match_to_binary(Ms).

%% user_auth -> User Auth
-spec smash_snake(ne_binary()) -> iolist().
smash_snake(BaseName) ->
    case binary:split(BaseName, <<"_">>, ['global']) of
        [Part] -> format_name_part(Part);
        [H|Parts] ->
            [format_name_part(H)
             | [[<<" ">>, format_name_part(Part)] || Part <- Parts]
            ]
    end.

-spec format_name_part(ne_binary()) -> ne_binary().
format_name_part(<<"api">>) -> <<"API">>;
format_name_part(<<"ip">>) -> <<"IP">>;
format_name_part(<<"auth">>) -> <<"Authentication">>;
format_name_part(Part) ->
    kz_binary:ucfirst(Part).

-spec schema_path(binary()) -> file:filename_all().
schema_path(Base) ->
    case filename:join([code:priv_dir('crossbar')
                       ,<<"couchdb">>
                       ,<<"schemas">>
                       ,Base
                       ]) of
        <<"/", _/binary>> = Path -> Path;
        Path -> <<"./", Path/binary>>
    end.

-spec api_path(binary()) -> file:filename_all().
api_path(Base) ->
    filename:join([code:priv_dir('crossbar')
                  ,<<"api">>
                  ,Base
                  ]).

-spec ensure_file_exists(binary()) -> 'ok' | {'ok', any()}.
ensure_file_exists(Path) ->
    case filelib:is_regular(Path) of
        'false' -> create_schema(Path);
        'true' -> 'ok'
    end.

-spec create_schema(binary()) -> {'ok', any()}.
create_schema(Path) ->
    Skel = schema_path(<<"skel.json">>),
    {'ok', _} = file:copy(Skel, Path).

-spec project_apps() -> [atom()].
project_apps() ->
    Core = siblings_of('kazoo'),
    Apps = siblings_of('sysconf'),
    Core ++ Apps.

siblings_of(App) ->
    [dir_to_app_name(Dir)
     || Dir <- filelib:wildcard(filename:join([code:lib_dir(App), "..", "*"])),
        filelib:is_dir(Dir)
    ].

dir_to_app_name(Dir) ->
    kz_term:to_atom(filename:basename(Dir), 'true').

-spec app_modules(atom()) -> [atom()].
app_modules(App) ->
    case application:get_key(App, 'modules') of
        {'ok', Modules} -> Modules;
        'undefined' ->
            'ok' = application:load(App),
            app_modules(App)
    end.


-define(TABLE_ROW(Key, Description, Type, Default, Required)
       ,[kz_binary:join([Key, Description, Type, Default, Required]
                       ,<<" | ">>
                       )
        ,$\n
        ]
       ).
-define(TABLE_HEADER
       ,[?TABLE_ROW(<<"Key">>, <<"Description">>, <<"Type">>, <<"Default">>, <<"Required">>)
        ,?TABLE_ROW(<<"---">>, <<"-----------">>, <<"----">>, <<"-------">>, <<"--------">>)
        ]).

-spec schema_to_table(ne_binary() | kz_json:object()) -> iolist().
schema_to_table(<<"#/definitions/", _/binary>>=_S) -> [];
schema_to_table(Schema=?NE_BINARY) ->
    case kz_json_schema:fload(Schema) of
        {'ok', JObj} -> schema_to_table(JObj);
        {'error', 'not_found'} ->
            io:format("failed to find ~s~n", [Schema]),
            throw({'error', 'no_schema'})
    end;
schema_to_table(SchemaJObj) ->
    [Table|RefTables] = schema_to_table(SchemaJObj, []),
    [?SCHEMA_SECTION, Table, "\n\n"
    ,cb_api_endpoints:ref_tables_to_doc(RefTables), "\n\n"
    ].

schema_to_table(SchemaJObj, BaseRefs) ->
    Description = kz_json:get_binary_value(<<"description">>, SchemaJObj, <<>>),
    Properties = kz_json:get_json_value(<<"properties">>, SchemaJObj, kz_json:new()),
    PlusPatternProperties =
        kz_json:merge(kz_json:get_json_value(<<"patternProperties">>, SchemaJObj, kz_json:new())
                     ,Properties
                     ),
    F = fun (K, V, Acc) -> property_to_row(SchemaJObj, K, V, Acc) end,
    {Reversed, RefSchemas} = kz_json:foldl(F, {[], BaseRefs}, PlusPatternProperties),

    OneOfs = kz_json:get_value(<<"oneOf">>, SchemaJObj, []),
    OneOfRefs = lists:foldl(fun one_of_to_row/2, RefSchemas, OneOfs),
    WithSubRefs = include_sub_refs(OneOfRefs),

    [schema_description(Description), [?TABLE_HEADER, Reversed], "\n"]
        ++ [{RefSchemaName, RefTable}
            || RefSchemaName <- WithSubRefs,
               BaseRefs =:= [],
               (RefSchema = load_ref_schema(RefSchemaName)) =/= 'undefined',
               (RefTable = schema_to_table(RefSchema, WithSubRefs)) =/= []
           ].

-spec schema_description(binary()) -> iodata().
schema_description(<<>>) -> <<>>;
schema_description(Description) -> [Description, "\n\n"].

include_sub_refs(Refs) ->
    lists:usort(lists:foldl(fun include_sub_ref/2, [], Refs)).

include_sub_ref(?NE_BINARY = Ref, Acc) ->
    case props:is_defined(Ref, Acc) of
        'true' -> Acc;
        'false' ->
            include_sub_ref(Ref, [Ref | Acc], load_ref_schema(Ref))
    end;
include_sub_ref(RefSchema, Acc) ->
    include_sub_ref(kz_doc:id(RefSchema), Acc).

include_sub_ref(_Ref, Acc, 'undefined') -> Acc;
include_sub_ref(_Ref, Acc, SchemaJObj) ->
    kz_json:foldl(fun include_sub_refs_from_schema/3, Acc, SchemaJObj).

include_sub_refs_from_schema(<<"properties">>, ValueJObj, Acc) ->
    kz_json:foldl(fun include_sub_refs_from_schema/3, Acc, ValueJObj);
include_sub_refs_from_schema(<<"patternProperties">>, ValueJObj, Acc) ->
    kz_json:foldl(fun include_sub_refs_from_schema/3, Acc, ValueJObj);
include_sub_refs_from_schema(<<"oneOf">>, Values, Acc) ->
    lists:foldl(fun(JObj, Acc0) ->
                        kz_json:foldl(fun include_sub_refs_from_schema/3, Acc0, JObj)
                end
               ,Acc
               ,Values
               );
include_sub_refs_from_schema(<<"$ref">>, Ref, Acc) ->
    include_sub_ref(Ref, Acc);
include_sub_refs_from_schema(_Key, Value, Acc) ->
    case kz_json:is_json_object(Value) of
        'false' -> Acc;
        'true' ->
            kz_json:foldl(fun include_sub_refs_from_schema/3, Acc, Value)
    end.

-spec load_ref_schema(ne_binary()) -> api_object().
load_ref_schema(SchemaName) ->
    File = schema_path(<<SchemaName/binary, ".json">>),
    case file:read_file(File) of
        {'ok', SchemaBin} -> kz_json:decode(SchemaBin);
        {'error', _E} -> 'undefined'
    end.

one_of_to_row(Option, Refs) ->
    maybe_add_ref(Refs, Option).

-spec property_to_row(kz_json:object(), ne_binary() | ne_binaries(), kz_json:object(), {iodata(), ne_binaries()}) ->
                             {iodata(), ne_binaries()}.
property_to_row(SchemaJObj, Name=?NE_BINARY, Settings, {_, _}=Acc) ->
    property_to_row(SchemaJObj, [Name], Settings, Acc);
property_to_row(SchemaJObj, Names, Settings, {Table, Refs}) ->
    SchemaType =
        try schema_type(Settings)
        catch 'throw':'no_type' ->
                io:format("no schema type in ~s for path ~p: ~p~n"
                         ,[kz_doc:id(SchemaJObj), Names, Settings]
                         ),
                cell_wrap('undefined')
        end,

    maybe_sub_properties_to_row(SchemaJObj
                               ,kz_json:get_ne_value(<<"type">>, Settings)
                               ,Names
                               ,Settings
                               ,{[?TABLE_ROW(cell_wrap(kz_binary:join(Names, <<".">>))
                                            ,kz_json:get_ne_binary_value(<<"description">>, Settings, <<" ">>)
                                            ,SchemaType
                                            ,cell_wrap(kz_json:get_value(<<"default">>, Settings))
                                            ,cell_wrap(is_row_required(Names, SchemaJObj))
                                            )
                                  | Table
                                 ]
                                ,maybe_add_ref(Refs, Settings)
                                }
                               ).

-spec maybe_add_ref(ne_binaries(), kz_json:object()) -> ne_binaries().
maybe_add_ref(Refs, Settings) ->
    case kz_json:get_ne_binary_value(<<"$ref">>, Settings) of
        'undefined' -> Refs;
        Ref -> lists:usort([Ref | Refs])
    end.

-spec is_row_required([ne_binary() | nonempty_string()], kz_json:object()) -> boolean().
is_row_required(Names=[_|_], SchemaJObj) ->
    Path = lists:flatten(
             [case Key of
                  "[]" -> [<<"items">>];
                  _ ->
                      NewSize = byte_size(Key) - 2,
                      case Key of
                          <<"/", Regex:NewSize/binary, "/">> -> [<<"patternProperties">>, Regex];
                          _ -> [<<"properties">>, Key]
                      end
              end
              || Key <- lists:droplast(Names)
             ] ++ [<<"required">>]
            ),
    case lists:last(Names) of
        "[]" -> false;
        Name ->
            ARegexSize = byte_size(Name) - 2,
            lists:member(case Name of
                             <<"/", ARegex:ARegexSize/binary, "/">> -> ARegex;
                             _ -> Name
                         end
                        ,kz_json:get_list_value(Path, SchemaJObj, [])
                        )
    end.

schema_type(Settings) ->
    case schema_type(Settings, kz_json:get_ne_value(<<"type">>, Settings)) of
        <<"[", _/binary>>=Type -> Type;
        Type -> cell_wrap(Type)
    end.

schema_type(Settings, 'undefined') ->
    case kz_json:get_ne_binary_value(<<"$ref">>, Settings) of
        'undefined' ->
            maybe_schema_type_from_enum(Settings);
        Def ->
            schema_ref_type(Def)
    end;
schema_type(Settings, <<"array">>) ->
    schema_array_type(Settings);
schema_type(Settings, <<"string">>) ->
    case kz_json:get_value(<<"enum">>, Settings) of
        L when is_list(L) -> schema_enum_type(L);
        _ -> schema_string_type(Settings)
    end;
schema_type(Settings, Types) when is_list(Types) ->
    kz_binary:join([schema_type(Settings, Type) || Type <- Types], <<" | ">>);
schema_type(_Settings, Type) -> <<Type/binary, "()">>.

maybe_schema_type_from_enum(Settings) ->
    case kz_json:get_list_value(<<"enum">>, Settings) of
        L when is_list(L) -> schema_enum_type(L);
        'undefined' ->
            maybe_schema_type_from_oneof(Settings)
    end.

maybe_schema_type_from_oneof(Settings) ->
    case kz_json:get_list_value(<<"oneOf">>, Settings) of
        'undefined' ->
            throw('no_type');
        OneOf ->
            SchemaTypes = [schema_type(OneOfJObj, kz_json:get_ne_value(<<"type">>, OneOfJObj))
                           || OneOfJObj <- OneOf
                          ],
            kz_binary:join(SchemaTypes, <<" | ">>)
    end.

schema_ref_type(Def) ->
    <<"[#/definitions/", Def/binary, "](#", (to_anchor_link(Def))/binary, ")">>.

schema_array_type(Settings) ->
    case kz_json:get_ne_value([<<"items">>, <<"type">>], Settings) of
        'undefined' -> schema_array_type_from_ref(Settings);
        Type ->
            ItemType = schema_type(kz_json:get_value(<<"items">>, Settings), Type),
            <<"array(", ItemType/binary, ")">>
    end.

schema_array_type_from_ref(Settings) ->
    case kz_json:get_ne_binary_value([<<"items">>, <<"$ref">>], Settings) of
        'undefined' -> <<"array()">>;
        Ref -> ["array(", schema_ref_type(Ref), ")"]
    end.

schema_enum_type(L) ->
    <<"string('", (kz_binary:join(L, <<"' | '">>))/binary, "')">>.

schema_string_type(Settings) ->
    case {kz_json:get_integer_value(<<"minLength">>, Settings)
         ,kz_json:get_integer_value(<<"maxLength">>, Settings)
         }
    of
        {'undefined', 'undefined'} -> <<"string()">>;
        {'undefined', MaxLength} -> <<"string(0..", (kz_term:to_binary(MaxLength))/binary, ")">>;
        {MinLength, 'undefined'} -> <<"string(", (kz_term:to_binary(MinLength))/binary, "..)">>;
        {Length, Length} -> <<"string(", (kz_term:to_binary(Length))/binary, ")">>;
        {MinLength, MaxLength} -> <<"string(", (kz_term:to_binary(MinLength))/binary, "..", (kz_term:to_binary(MaxLength))/binary, ")">>
    end.

to_anchor_link(Bin) ->
    binary:replace(Bin, <<".">>, <<>>).

cell_wrap('undefined') -> <<" ">>;
cell_wrap([]) -> <<"`[]`">>;
cell_wrap(L) when is_list(L) -> [<<"`[\"">>, kz_binary:join(L, <<"\", \"">>), <<"\"]`">>];
cell_wrap(<<>>) -> <<"\"\"">>;
cell_wrap(?EMPTY_JSON_OBJECT) -> <<"`{}`">>;
cell_wrap(Type) ->
    [<<"`">>, kz_term:to_binary(Type), <<"`">>].

maybe_sub_properties_to_row(SchemaJObj, <<"object">>, Names, Settings, {_,_}=Acc0) ->
    lists:foldl(fun(Key, {_,_}=Acc1) ->
                        maybe_object_properties_to_row(SchemaJObj, Key, Acc1, Names, Settings)
                end
               ,Acc0
               ,[<<"properties">>, <<"patternProperties">>]
               );
maybe_sub_properties_to_row(SchemaJObj, <<"array">>, Names, Settings, {Table, Refs}) ->
    case kz_json:get_ne_value([<<"items">>, <<"type">>], Settings) of
        <<"object">> = Type ->
            maybe_sub_properties_to_row(SchemaJObj
                                       ,Type
                                       ,Names ++ ["[]"]
                                       ,kz_json:get_value(<<"items">>, Settings, kz_json:new())
                                       ,{Table, Refs}
                                       );
        <<"string">> = Type ->
            {[?TABLE_ROW(cell_wrap(kz_binary:join(Names ++ ["[]"], <<".">>))
                        ,<<" ">>
                        ,cell_wrap(<<Type/binary, "()">>)
                        ,<<" ">>
                        ,cell_wrap(is_row_required(Names, SchemaJObj))
                        )
              | Table
             ]
            ,Refs
            };
        _Type -> {Table, Refs}
    end;
maybe_sub_properties_to_row(_SchemaJObj, _Type, _Keys, _Settings, Acc) ->
    Acc.

maybe_object_properties_to_row(SchemaJObj, Key, Acc0, Names, Settings) ->
    kz_json:foldl(fun(Name, SubSettings, Acc1) ->
                          property_to_row(SchemaJObj, Names ++ [maybe_regex_name(Key, Name)], SubSettings, Acc1)
                  end
                 ,Acc0
                 ,kz_json:get_value(Key, Settings, kz_json:new())
                 ).

maybe_regex_name(<<"patternProperties">>, Name) ->
    <<"/", Name/binary, "/">>;
maybe_regex_name(_Key, Name) ->
    Name.

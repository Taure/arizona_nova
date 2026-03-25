-module(arizona_nova_static).
-moduledoc """
Serves static assets from arizona_core's priv directory.

Routes like `/arizona/assets/js/:file` are served from
`code:priv_dir(arizona_core)/static/assets/js/`.
""".

-export([serve_js/1]).

-spec serve_js(cowboy_req:req()) ->
    {status, integer()} | {status, integer(), map(), iodata()}.
serve_js(Req) ->
    Bindings = maps:get(bindings, Req, #{}),
    File = maps:get(<<"file">>, Bindings, undefined),
    case File of
        undefined -> {status, 404};
        _ -> serve_file([~"js", File])
    end.

serve_file(PathParts) ->
    case lists:any(fun(P) -> P =:= <<"..">> orelse P =:= ".." end, PathParts) of
        true ->
            {status, 403};
        false ->
            PrivDir = code:priv_dir(arizona_core),
            FullPath = filename:join([PrivDir, "static", "assets" | PathParts]),
            case file:read_file(FullPath) of
                {ok, Content} ->
                    ContentType = mime_type(FullPath),
                    Headers = #{
                        <<"content-type">> => ContentType,
                        <<"cache-control">> => <<"public, max-age=3600">>
                    },
                    {status, 200, Headers, Content};
                {error, _} ->
                    {status, 404}
            end
    end.

mime_type(Path) ->
    Ext = unicode:characters_to_list(filename:extension(Path)),
    case Ext of
        ".js" -> <<"application/javascript">>;
        ".mjs" -> <<"application/javascript">>;
        ".css" -> <<"text/css">>;
        ".map" -> <<"application/json">>;
        _ -> <<"application/octet-stream">>
    end.

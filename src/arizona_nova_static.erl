-module(arizona_nova_static).
-moduledoc """
Serves static assets from arizona_core's priv directory.

Handles requests to `/arizona/assets/[...]` by reading files from
`code:priv_dir(arizona_core)/static/assets/`.
""".

-export([serve/1]).

-spec serve(cowboy_req:req()) ->
    {status, integer(), map(), iodata()}.
serve(Req) ->
    Path = cowboy_req:path(Req),
    Prefix = arizona_nova:prefix(),
    PrefixLen = byte_size(Prefix) + byte_size(<<"/assets/">>),
    RelPath = binary:part(Path, PrefixLen, byte_size(Path) - PrefixLen),
    %% Prevent path traversal
    case binary:match(RelPath, <<"..">>) of
        nomatch ->
            serve_file(RelPath);
        _ ->
            {status, 403}
    end.

serve_file(RelPath) ->
    PrivDir = code:priv_dir(arizona_core),
    FullPath = filename:join([PrivDir, "static", "assets", RelPath]),
    case file:read_file(FullPath) of
        {ok, Content} ->
            ContentType = mime_type(FullPath),
            {status, 200, #{<<"content-type">> => ContentType, <<"cache-control">> => <<"public, max-age=3600">>}, Content};
        {error, _} ->
            {status, 404}
    end.

mime_type(Path) ->
    case filename:extension(Path) of
        ".js" -> <<"application/javascript">>;
        ".mjs" -> <<"application/javascript">>;
        ".css" -> <<"text/css">>;
        ".map" -> <<"application/json">>;
        ".html" -> <<"text/html">>;
        ".json" -> <<"application/json">>;
        ".txt" -> <<"text/plain">>;
        _ -> <<"application/octet-stream">>
    end.

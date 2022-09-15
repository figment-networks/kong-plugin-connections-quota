# kong-plugin-connections-quota

Kong plugin to make sure user can have a limited number of total and concurrent connections.

## Concurrent vs. Per-unit rate limits

"Concurrent" connections is a misnomer in this plugin, because it's actually only affecting the number of websocket connections. This was implemented purposefully to handle APIs that support both websockets and standard HTTP connections. We needed a way to differentiate between the two and restrict them independently.

**TODO**: Implement a separate websocket configuration for limiting active websocket connections and use "concurrent" as a limit of the total number of connections.

## Cache Expiration

When incrementing or decrementing the number of concurrent connections in the Redis cache, we use an expiration of 1 month for the value. This is because it's possible for websocket connections to run for several days, or even weeks, before they are refreshed with a new connection. We don't want the value to be lost in the meantime.

## Testing

To run lint and tests install
[kong-pongo](https://github.com/Kong/kong-pongo#installation)
(tooling to run kong plugin tests)

```sh
$ pongo lint
```

```sh
$ KONG_VERSION=nightly pongo run
```

## Releasing
Plugin versions are uploaded to
[luarocks.org](https://luarocks.org/modules/figment/kong-plugin-connections-quota)

To release a new plugin version (run from main branch):
```sh
# Install lua-cjson if missing
$ luarocks remove lua-cjson
$ luarocks install lua-cjson 2.1.0-1 #https://github.com/mpx/lua-cjson/issues/56#issuecomment-394764240

# Bump version, rename rockspec but DO NOT create a Git tag and DO NOT publish to github and luarocks.org
$ make release VERSION=X.Y.Z DRY=1

# Bump version, rename rockspec, create a Git tag, and publish to luarocks.org
$ make release VERSION=X.Y.Z
```

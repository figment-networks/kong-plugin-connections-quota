local helpers = require "spec.helpers"

local PLUGIN_NAME = "connections-quota"
local redis_host  = helpers.redis_host
local redis_port  = 6379
local schema_def = require("kong.plugins."..PLUGIN_NAME..".schema")
local v = helpers.validate_plugin_config_schema

describe("Plugin: " .. PLUGIN_NAME .. " (schema), ", function()
  it("minimal conf validates", function()
    local minimal_conf = {
      policy = "redis",
      redis_host = redis_host,
      redis_port = redis_port
    }
    assert(v(minimal_conf, schema_def))
  end)

  it("service config test", function()
    local minimal_conf = {
      policy = "redis",
      redis_host = redis_host,
      redis_port = redis_port,
      services_limits = {
        ["avalanche--fuji--rpc.datahub.figment.io"] = {
          ["second"] = 10
        }
      }
    }
    assert(v(minimal_conf, schema_def))
  end)
end)

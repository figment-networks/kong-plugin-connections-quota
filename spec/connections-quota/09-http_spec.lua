local helpers = require "spec.helpers"
local cjson = require "cjson"
local client = require "resty.websocket.client"

local PLUGIN_NAME = "connections-quota"
local auth_key    = "kong"
local auth_key2   = "godzilla"
local redis_host  = helpers.redis_host
local redis_port  = 6379
local strategy    = "postgres"

describe("HTTP [#" .. strategy .. "]", function()
  local proxy_client

  lazy_setup(function()
    local bp = helpers.get_db_utils(strategy, {
      "routes",
      "services",
      "plugins",
      "consumers",
      "keyauth_credentials",
    }, { PLUGIN_NAME })

    -- http route
    local route1 = bp.routes:insert {
      hosts = { "test1.com" },
    }

    bp.plugins:insert {
      name = PLUGIN_NAME,
      route = { id = route1.id },
      config = {
        minute = 1,
        limit = 1,
        policy = "redis",
        redis_host = redis_host,
        redis_port = redis_port
      }
    }

    assert(helpers.start_kong({
      database   = strategy,
      nginx_conf = "spec/fixtures/custom_nginx.template",
      plugins = "bundled," .. PLUGIN_NAME,
    }))
  end)

  lazy_teardown(function()
    helpers.stop_kong(nil, true)
  end)

  local function open_socket(uri, auth_key)
    local wc = assert(client:new())
    assert(wc:connect(uri, {
      headers = { "apikey:" .. auth_key }
    }))
    return wc
  end

  before_each(function()
    proxy_client = helpers.proxy_client()
  end)

  after_each(function()
    if proxy_client then proxy_client:close() end
  end)

  it("sends headers", function()
    local res = proxy_client:get("/status/200", {
      headers = {
        Host = "test1.com"
      },
    })

    assert.res_status(200, res)
    assert.equal('1', res.headers["X-Quota-Limit-Minute"])
    assert.equal('0', res.headers["X-Quota-Remaining-Minute"])
    assert.equal(nil, res.headers["X-Concurrent-Quota-Limit"])
    assert.equal(nil, res.headers["X-Concurrent-Quota-Remaining"])

    res = proxy_client:get("/status/200", {
      headers = {
        Host = "test1.com"
      },
    })
    assert.equal('1', res.headers["X-Quota-Limit-Minute"])
    assert.equal('0', res.headers["X-Quota-Remaining-Minute"])
    assert.res_status(429, res)
  end)
end)

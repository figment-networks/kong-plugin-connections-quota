local helpers = require "spec.helpers"

local PLUGIN_NAME = "connections-quota"
local redis_host  = helpers.redis_host
local redis_port  = 6379
local strategy    = "postgres"
local auth_key    = "kong_http"

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

    local service = bp.services:insert {
      name = "http"
    }

    bp.routes:insert {
      hosts = { "test1.com" },
      service     = service,
    }

    bp.plugins:insert {
      name = "key-auth",
      service = { id = service.id },
      config = {
        key_names =  { "apikey", "Authorization", "X-Api-Key" },
        hide_credentials = false,
      }
    }

    local consumer = bp.consumers:insert {
      username = "bob"
    }

    bp.keyauth_credentials:insert {
      key      = auth_key,
      consumer = { id = consumer.id },
    }

    bp.plugins:insert {
      name = PLUGIN_NAME,
      consumer = { id = consumer.id },
      config = {
        hour = 10,
        limit = 1,
        policy = "redis",
        redis_host = redis_host,
        redis_port = redis_port,
        services_limits = {
          ['test1.com'] = {
            hour = 1
          }
        }
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

  before_each(function()
    proxy_client = helpers.proxy_client()
  end)

  after_each(function()
    if proxy_client then proxy_client:close() end
  end)

  it("sends headers", function()
    local res = proxy_client:get("/status/200", {
      headers = {
        Host = "test1.com",
        apikey = auth_key
      },
    })

    assert.res_status(200, res)
    assert.equal('1', res.headers["X-Quota-Limit-Hour"])
    assert.equal('0', res.headers["X-Quota-Remaining-Hour"])
    assert.equal(nil, res.headers["X-Concurrent-Quota-Limit"])
    assert.equal(nil, res.headers["X-Concurrent-Quota-Remaining"])

    res = proxy_client:get("/status/200", {
      headers = {
        Host = "test1.com",
        apikey = auth_key
      },
    })
    assert.equal('1', res.headers["X-Quota-Limit-Hour"])
    assert.equal('0', res.headers["X-Quota-Remaining-Hour"])
    assert.res_status(429, res)
  end)
end)

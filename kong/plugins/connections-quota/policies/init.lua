local local_strategy = require "kong.plugins.connections-quota.policies.strategy.local"
local redis_strategy = require "kong.plugins.connections-quota.policies.strategy.redis"

local null = ngx.null
local fmt = string.format

local EMPTY_UUID = "00000000-0000-0000-0000-000000000000"
local CONCURRENT_CONNECTIONS_QUOTA = "concurrent-connections-quota"
local TOTAL_CONNECTIONS_QUOTA = "ratelimit"

local function get_service_and_route_ids(conf)
  conf = conf or {}

  local service_id = conf.service_id
  local route_id   = conf.route_id

  if not service_id or service_id == null then
    service_id = EMPTY_UUID
  end

  if not route_id or route_id == null then
    route_id = EMPTY_UUID
  end

  return service_id, route_id
end

local get_local_key = function(key_type, conf, identifier, period, period_date)
  local service_id, route_id = get_service_and_route_ids(conf)

  if not period or period == null then
    period = EMPTY_UUID
  end

  if not period_date or period_date == null then
    period_date = EMPTY_UUID
  end

  return fmt("%s:%s:%s:%s:%s:%s", key_type, route_id, service_id, identifier, period_date, period)
end

return {
  ["local"] = local_strategy(get_local_key, CONCURRENT_CONNECTIONS_QUOTA, TOTAL_CONNECTIONS_QUOTA),
  ["redis"] = redis_strategy(get_local_key, CONCURRENT_CONNECTIONS_QUOTA, TOTAL_CONNECTIONS_QUOTA)
}

local kong = kong
local timestamp = require "kong.tools.timestamp"
local shm = ngx.shared.kong_rate_limiting_counters
local EXPIRATIONS = require "kong.plugins.connections-quota.expiration"

local strategy = function (get_local_key, CONCURRENT_CONNECTIONS_QUOTA, TOTAL_CONNECTIONS_QUOTA)
  local function increment_concurrent_quota(conf, identifier, value)
    local cache_key = get_local_key(CONCURRENT_CONNECTIONS_QUOTA, conf, identifier)
    local newval, err = shm:incr(cache_key, value, 0)
    if not newval then
      kong.log.err("could not increment counter: ", err)
      return nil, err
    end

    return true
  end

  local function increment_total_quota(conf, limits, identifier, current_timestamp, value)
    local periods = timestamp.get_timestamps(current_timestamp)
    for period, period_date in pairs(periods) do
      if limits[period] then
        local cache_key = get_local_key(TOTAL_CONNECTIONS_QUOTA, conf, identifier, period, period_date)
        local newval, err = shm:incr(cache_key, value, 0, EXPIRATIONS[period])
        if not newval then
          kong.log.err("could not increment counter for period '", period, "': ", err)
          return nil, err
        end
      end
    end

    return true
  end

  local function concurrent_usage(conf, identifier)
    local cache_key = get_local_key(CONCURRENT_CONNECTIONS_QUOTA, conf, identifier)

    local current_metric, err = shm:get(cache_key)
    if err then
      return nil, err
    end

    if current_metric == nil or current_metric < 0 then
      current_metric = 0
      shm:set(cache_key, 0)
    end

    return current_metric or 0
  end

  local function total_usage(conf, identifier, period, current_timestamp)
    local periods = timestamp.get_timestamps(current_timestamp)
    local cache_key = get_local_key(TOTAL_CONNECTIONS_QUOTA, conf, identifier, period, periods[period])

    local current_metric, err = shm:get(cache_key)
    if err then
      return nil, err
    end

    return current_metric or 0
  end

  return {
    increment_concurrent_count = function(conf, identifier, value, limits, current_timestamp)
      local ok, err = increment_concurrent_quota(conf, identifier, value)
      if not ok then
        return nil, err
      end

      return true
    end,
    increment_total_count = function(conf, identifier, value, limits, current_timestamp)
      local ok, err = increment_total_quota(conf, limits, identifier, current_timestamp, value)
      if not ok then
        return nil, err
      end

      return true
    end,
    decrement = function(conf, identifier, value)
      local cache_key = get_local_key(CONCURRENT_CONNECTIONS_QUOTA, conf, identifier)
      local newval, err = shm:incr(cache_key, -1*value, 0) -- no shm:decr sadly
      if not newval then
        kong.log.err("could not increment counter: ", err)
        return nil, err
      end

      return true
    end,
    concurrent_usage = function(conf, identifier)
      local concurrent_usage_metric = concurrent_usage(conf, identifier)

      return concurrent_usage_metric
    end,
    total_usage = function(conf, identifier, period, current_timestamp)
      local total_usage_metric = total_usage(conf, identifier, period, current_timestamp)

      return total_usage_metric
    end
  }
end

return strategy

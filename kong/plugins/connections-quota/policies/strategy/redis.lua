local kong = kong
local reports = require "kong.reports"
local redis = require "resty.redis"
local timestamp = require "kong.tools.timestamp"
local null = ngx.null
local EXPIRATIONS = require "kong.plugins.connections-quota.expiration"

local strategy = function (get_local_key, CONCURRENT_CONNECTIONS_QUOTA, TOTAL_CONNECTIONS_QUOTA)

  local EXPIRATION = 10*60
  local sock_opts = {}

  local function is_present(str)
    return str and str ~= "" and str ~= null
  end

  local function get_redis_connection(conf)
    local red = redis:new()
    red:set_timeout(conf.redis_timeout)
    -- use a special pool name only if redis_database is set to non-zero
    -- otherwise use the default pool name host:port
    sock_opts.pool = conf.redis_database and
    conf.redis_host .. ":" .. conf.redis_port ..
    ":" .. conf.redis_database
    local ok, err = red:connect(conf.redis_host, conf.redis_port,
    sock_opts)
    if not ok then
      kong.log.err("failed to connect to Redis: ", err)
      return nil, err
    end

    local times, err = red:get_reused_times()
    if err then
      kong.log.err("failed to get connect reused times: ", err)
      return nil, err
    end

    if times == 0 then
      if is_present(conf.redis_password) then
        local ok, err = red:auth(conf.redis_password)
        if not ok then
          kong.log.err("failed to auth Redis: ", err)
          return nil, err
        end
      end

      if conf.redis_database ~= 0 then
        -- Only call select first time, since we know the connection is shared
        -- between instances that use the same redis database

        local ok, err = red:select(conf.redis_database)
        if not ok then
          kong.log.err("failed to change Redis database: ", err)
          return nil, err
        end
      end
    end

    reports.retrieve_redis_version(red)

    return red
  end

  local function increment_concurrent_quota(red, conf, identifier, service_group, value)
    local cache_key = get_local_key(CONCURRENT_CONNECTIONS_QUOTA, conf, identifier, service_group)

    red:init_pipeline()
    red:incrby(cache_key, value)
    red:expire(cache_key, EXPIRATION)

    local _, err = red:commit_pipeline()
    if err then
      kong.log.err("failed to commit pipeline in Redis: ", err)
      return nil, err
    end

    return true
  end

  local function increment_total_quota(red, conf, limits, identifier, service_group, current_timestamp, value)
    local keys = {}
    local expirations = {}
    local idx = 0
    local periods = timestamp.get_timestamps(current_timestamp)
    for period, period_date in pairs(periods) do
      if limits[period] then
        local cache_key = get_local_key(TOTAL_CONNECTIONS_QUOTA, conf, identifier, service_group, period, period_date)
        local exists, err = red:exists(cache_key)
        if err then
          kong.log.err("failed to query Redis: ", err)
          return nil, err
        end

        idx = idx + 1
        keys[idx] = cache_key
        if not exists or exists == 0 then
          expirations[idx] = EXPIRATIONS[period]
        end
      end
    end

    red:init_pipeline()
    for i = 1, idx do
      red:incrby(keys[i], value)
      if expirations[i] then
        red:expire(keys[i], expirations[i])
      end
    end

    local _, err = red:commit_pipeline()
    if err then
      kong.log.err("failed to commit pipeline in Redis: ", err)
      return nil, err
    end

    return true
  end

  local function concurrent_usage(red, conf, identifier, service_group)
    local cache_key = get_local_key(CONCURRENT_CONNECTIONS_QUOTA, conf, identifier, service_group)

    local current_metric, err = red:get(cache_key)
    if err then
      return nil, err
    end

    if current_metric == null or current_metric == nil or tonumber(current_metric) < 0 then
      current_metric = 0
      red:init_pipeline()
      red:set(cache_key, 0)
      local _, err = red:commit_pipeline()
      if err then
        kong.log.err("failed to commit pipeline in Redis: ", err)
      end
    end

    return current_metric or 0
  end

  local function total_usage(red, conf, identifier, service_group, period, current_timestamp)
    local periods = timestamp.get_timestamps(current_timestamp)
    local cache_key = get_local_key(TOTAL_CONNECTIONS_QUOTA, conf, identifier, service_group, period, periods[period])

    local current_metric, err = red:get(cache_key)
    if err then
      return nil, err
    end

    if current_metric == null then
      current_metric = nil
    end

    return current_metric or 0
  end

  return {
    increment_concurrent_count = function(conf, identifier, service_group, value, limits, current_timestamp)
      local red, err = get_redis_connection(conf)
      if not red then
        kong.log.err("!!! failed to connect to Redis: ", err)
        return nil, err
      end

      local ok, err = increment_concurrent_quota(red, conf, identifier, service_group, value)
      if not ok then
        return nil, err
      end

      local ok, err = red:set_keepalive(10000, 100)
      if not ok then
        kong.log.err("failed to set Redis keepalive: ", err)
      end

      return true
    end,
    increment_total_count = function(conf, identifier, service_group, value, limits, current_timestamp)
      local red, err = get_redis_connection(conf)
      if not red then
        kong.log.err("!!! failed to connect to Redis: ", err)
        return nil, err
      end

      local ok, err = increment_total_quota(red, conf, limits, identifier, service_group, current_timestamp, value)
      if not ok then
        return nil, err
      end

      local ok, err = red:set_keepalive(10000, 100)
      if not ok then
        kong.log.err("failed to set Redis keepalive: ", err)
      end

      return true
    end,
    decrement = function(conf, identifier, service_group, value)
      local red, err = get_redis_connection(conf)
      if not red then
        kong.log.err("failed to connect to Redis: ", err)
        return nil, err
      end

      local cache_key = get_local_key(CONCURRENT_CONNECTIONS_QUOTA, conf, identifier, service_group)

      red:init_pipeline()
      red:decrby(cache_key, value)
      red:expire(cache_key, EXPIRATION)

      local _, err = red:commit_pipeline()
      if err then
        kong.log.err("failed to commit pipeline in Redis: ", err)
        return nil, err
      end

      local ok, err = red:set_keepalive(10000, 100)
      if not ok then
        kong.log.err("failed to set Redis keepalive: ", err)
        return nil, err
      end

      return true
    end,
    concurrent_usage = function(conf, identifier, service_group)
      local red, err = get_redis_connection(conf)
      if not red then
        kong.log.err("failed to connect to Redis: ", err)
        return nil, err
      end

      local concurrent_usage_metric = concurrent_usage(red, conf, identifier, service_group)

      local ok, err = red:set_keepalive(10000, 100)
      if not ok then
        kong.log.err("failed to set Redis keepalive: ", err)
        return nil, err
      end

      return concurrent_usage_metric
    end,
    total_usage = function(conf, identifier, service_group, period, current_timestamp)
      local red, err = get_redis_connection(conf)
      if not red then
        kong.log.err("failed to connect to Redis: ", err)
        return nil, err
      end

      local total_usage_metric = total_usage(red, conf, identifier, service_group, period, current_timestamp)

      local ok, err = red:set_keepalive(10000, 100)
      if not ok then
        kong.log.err("failed to set Redis keepalive: ", err)
        return nil, err
      end

      return total_usage_metric
    end
  }
end

return strategy

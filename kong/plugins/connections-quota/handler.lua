local policies = require "kong.plugins.connections-quota.policies"
local timestamp = require "kong.tools.timestamp"

local kong = kong
local kong_request = kong.request
local max = math.max
local floor = math.floor
local time = ngx.time
local timer_at = ngx.timer.at

local ConnectionsQuotaHandler = {
   PRIORITY = 901,
   VERSION = "0.1.7",
}

local EMPTY = {}
local EXPIRATIONS = require "kong.plugins.connections-quota.expiration"
local CONCURRENCY_RATELIMIT_LIMIT     = "X-Concurrent-Quota-Limit"
local CONCURRENCY_RATELIMIT_REMAINING = "X-Concurrent-Quota-Remaining"

local TOTAL_QUOTA_RATELIMIT_LIMIT     = "Quota-Limit"
local TOTAL_QUOTA_RATELIMIT_REMAINING = "Quota-Remaining"
local TOTAL_QUOTA_RATELIMIT_RESET     = "Quota-Reset"
local TOTAL_QUOTA_RETRY_AFTER         = "Retry-After"

local TOTAL_QUOTA_X_RATELIMIT_LIMIT = {
  second = "X-Quota-Limit-Second",
  minute = "X-Quota-Limit-Minute",
  hour   = "X-Quota-Limit-Hour",
  day    = "X-Quota-Limit-Day",
  month  = "X-Quota-Limit-Month",
  year   = "X-Quota-Limit-Year",
}

local TOTAL_QUOTA_X_RATELIMIT_REMAINING = {
  second = "X-Quota-Remaining-Second",
  minute = "X-Quota-Remaining-Minute",
  hour   = "X-Quota-Remaining-Hour",
  day    = "X-Quota-Remaining-Day",
  month  = "X-Quota-Remaining-Month",
  year   = "X-Quota-Remaining-Year",
}

local function get_identifier(conf)
  local identifier= (kong.client.get_consumer() or
                    kong.client.get_credential() or
                    EMPTY).id
  return identifier or kong.client.get_forwarded_ip()
end

local function get_service_group(conf)
  local host = kong.request.get_host()
  local service_group = ''

  if conf.services_limits and conf.services_limits[host] then
    service_group = conf.services_limits[host].service_group
  end

  return service_group
end

local function increment_total_count(premature, conf, identifier, service_group, value, ...)
  if premature then
    return
  end

  policies[conf.policy].increment_total_count(conf, identifier, service_group, value, ...)
end

local function increment_concurrent_count(premature, conf, identifier, service_group, value, ...)
  if premature then
    return
  end

  policies[conf.policy].increment_concurrent_count(conf, identifier, service_group, value, ...)
end

local function decrement(premature, conf, identifier, service_group, value)
  if premature then
    return
  end

  policies[conf.policy].decrement(conf, identifier, service_group, value)
end

local function fetch_limits(conf)
  local host = kong.request.get_host()
  local limits = conf

  if conf.services_limits and conf.services_limits[host] then
    limits = conf.services_limits[host]
  end

  return {
    second = limits.second,
    minute = limits.minute,
    hour = limits.hour,
    day = limits.day,
    month = limits.month,
    year = limits.year,
  }
end

local function fetch_concurrent_limit(conf)
  local host = kong.request.get_host()
  local limit = conf.limit

  if conf.services_limits and conf.services_limits[host] then
    limit = conf.services_limits[host].limit
  end

  return limit
end

local function get_concurrent_usage(conf, identifier, service_group)
  local stop = false
  local limit = fetch_concurrent_limit(conf)

  local current_usage, err = policies[conf.policy].concurrent_usage(conf, identifier, service_group)
  if err then
    return nil, nil, err
  end

  -- What is the current usage for the configured limit name?
  local remaining = limit - current_usage

  -- Recording usage
  local usage = {
    remaining = remaining,
  }

  if remaining <= 0 then
    stop = true
  end

  return usage, stop
end

local function check_concurrent_quota(conf, identifier, service_group)
  kong.ctx.plugin.decrement_on_log = true
  kong.ctx.plugin.identifier = identifier
  kong.ctx.plugin.service_group = service_group
  local fault_tolerant = conf.fault_tolerant

  local limit = fetch_concurrent_limit(conf)

  local usage, stop, err = get_concurrent_usage(conf, identifier, service_group)
  if err then
    if not fault_tolerant then
      return error(err)
    end

    kong.log.err("failed to get usage: ", tostring(err))
  end

  if usage then
    -- Adding headers
    if not conf.hide_client_headers then
      local current_remaining = usage.remaining
      if not stop then
        current_remaining = current_remaining - 1
      end
      current_remaining = max(0, current_remaining)

      kong.ctx.plugin.headers[CONCURRENCY_RATELIMIT_LIMIT] = limit
      kong.ctx.plugin.headers[CONCURRENCY_RATELIMIT_REMAINING] = current_remaining
    end

    -- If limit is exceeded, terminate the request
    if stop then
      kong.ctx.plugin.decrement_on_log = false
      return kong.response.error(429, "API rate limit exceeded")
    end
  end
end

local function get_total_usage(conf, identifier, service_group, current_timestamp, limits)
  local usage = {}
  local stop

  for period, limit in pairs(limits) do
    local current_usage, err = policies[conf.policy].total_usage(conf, identifier, service_group, period, current_timestamp)
    if err then
      return nil, nil, err
    end

    -- What is the current usage for the configured limit name?
    local remaining = limit - current_usage

    -- Recording usage
    usage[period] = {
      limit = limit,
      remaining = remaining,
    }

    if remaining <= 0 then
      stop = period
    end
  end

  return usage, stop
end

local function check_total_quota(conf, identifier, service_group, current_timestamp, limits)
  -- Consumer is identified by ip address or authenticated_credential id
  local fault_tolerant = conf.fault_tolerant

  local usage, stop, err = get_total_usage(conf, identifier, service_group, current_timestamp, limits)
  if err then
    if not fault_tolerant then
      return error(err)
    end

    kong.log.err("failed to get usage: ", tostring(err))
  end

  if usage then
    -- Adding headers
    local reset
    if not conf.hide_client_headers then
      local timestamps
      local limit
      local window
      local remaining
      for k, v in pairs(usage) do
        local current_limit = v.limit
        local current_window = EXPIRATIONS[k]
        local current_remaining = v.remaining
        if stop == nil or stop == k then
          current_remaining = current_remaining - 1
        end
        current_remaining = max(0, current_remaining)

        if not limit or (current_remaining < remaining)
                     or (current_remaining == remaining and
                         current_window > window)
        then
          limit = current_limit
          window = current_window
          remaining = current_remaining

          if not timestamps then
            timestamps = timestamp.get_timestamps(current_timestamp)
          end

          reset = max(1, window - floor((current_timestamp - timestamps[k]) / 1000))
        end

        kong.ctx.plugin.headers[TOTAL_QUOTA_X_RATELIMIT_LIMIT[k]] = current_limit
        kong.ctx.plugin.headers[TOTAL_QUOTA_X_RATELIMIT_REMAINING[k]] = current_remaining
      end

      kong.ctx.plugin.headers[TOTAL_QUOTA_RATELIMIT_LIMIT] = limit
      kong.ctx.plugin.headers[TOTAL_QUOTA_RATELIMIT_REMAINING] = remaining
      kong.ctx.plugin.headers[TOTAL_QUOTA_RATELIMIT_RESET] = reset
    end

    -- If limit is exceeded, terminate the request
    if stop then
      return kong.response.error(429, "API rate limit exceeded", {
        [TOTAL_QUOTA_RETRY_AFTER] = reset
      })
    end
  end
end

function ConnectionsQuotaHandler:access(conf)
  kong.ctx.plugin.headers = {}
  local current_timestamp = time() * 1000
  local service_group = get_service_group(conf)
  local identifier = get_identifier(conf)
  local limits = fetch_limits(conf)
  local err
  local websocket_connection = kong_request.get_header('Upgrade') == 'websocket'

  if not websocket_connection then
    err = check_total_quota(conf, identifier, service_group, current_timestamp, limits)

    if err then
      return err
    end

    local ok
    ok, err = timer_at(0, increment_total_count, conf, identifier, service_group, 1, limits, current_timestamp)

    if not ok then
      kong.log.err("failed to create timer: ", err)
    end
  end

  if websocket_connection then
    err = check_concurrent_quota(conf, identifier, service_group)

    if err then
      return err
    end

    local ok
    ok, err = timer_at(0, increment_concurrent_count, conf, identifier, service_group, 1, limits, current_timestamp)

    if not ok then
      kong.log.err("failed to create timer: ", err)
    end
  end
end

function ConnectionsQuotaHandler:header_filter(_)
  local headers = kong.ctx.plugin.headers
  if headers then
    kong.response.set_headers(headers)
  end
end

function ConnectionsQuotaHandler:log(conf)
  if kong.ctx.plugin.decrement_on_log then
    local identifier = kong.ctx.plugin.identifier
    local service_group = kong.ctx.plugin.service_group
    local ok, err = timer_at(0, decrement, conf, identifier, service_group, 1)
    if not ok then
      kong.log.err("failed to create decrement timer: ", err)
    end
  end
end

return ConnectionsQuotaHandler

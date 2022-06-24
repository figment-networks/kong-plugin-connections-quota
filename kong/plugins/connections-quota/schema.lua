local typedefs = require "kong.db.schema.typedefs"

local ORDERED_PERIODS = { "second", "minute", "hour", "day", "month", "year"}

local function validate_periods_order(config)
  for i, lower_period in ipairs(ORDERED_PERIODS) do
    local v1 = config[lower_period]
    if type(v1) == "number" then
      for j = i + 1, #ORDERED_PERIODS do
        local upper_period = ORDERED_PERIODS[j]
        local v2 = config[upper_period]
        if type(v2) == "number" and v2 < v1 then
          return nil, string.format("The limit for %s(%.1f) cannot be lower than the limit for %s(%.1f)",
                                    upper_period, v2, lower_period, v1)
        end
      end
    end
  end

  return true
end

return {
  name = "connections-quota",
  fields = {
    { protocols = typedefs.protocols_http },
    { config = {
      type = "record",
      fields = {
        { second = { type = "number", gt = 0 }, },
        { minute = { type = "number", gt = 0 }, },
        { hour = { type = "number", gt = 0 }, },
        { day = { type = "number", gt = 0 }, },
        { month = { type = "number", gt = 0 }, },
        { year = { type = "number", gt = 0 }, },
        { limit = {
          type = "number",
          default = 10,
          required = true,
          gt = 0
        }, },
        { services_limits = {
           type = "map",
           keys = { type = "string" },
           values = {
              type = "map",
              keys = { type = "string" },
              values = { type = "number", gt = 0 },
           },
           required = false
        }, },
        { limit_by = {
          type = "string",
          default = "consumer",
          one_of = { "consumer", "credential" },
        }, },
        { policy = {
          type = "string",
          default = "redis",
          len_min = 0,
          one_of = { "local", "redis" },
        }, },
        { fault_tolerant = { type = "boolean", default = true }, },
        { redis_host = typedefs.host },
        { redis_port = typedefs.port({ default = 6379 }), },
        { redis_username = { type = "string", referenceable = true }, },
        { redis_password = { type = "string", len_min = 0, referenceable = true }, },
        { redis_timeout = { type = "number", default = 5000, }, },
        { redis_database = { type = "integer", default = 0 }, },
        { redis_ssl = { type = "boolean", required = true, default = false, }, },
        { redis_ssl_verify = { type = "boolean", required = true, default = false }, },
        { hide_client_headers = { type = "boolean", default = false }, },
      },
      custom_validator = validate_periods_order,
    },
  },
},
entity_checks = {
  { at_least_one_of = { "config.second", "config.minute", "config.hour", "config.day", "config.month", "config.year", "config.limit" } },
  { conditional = {
    if_field = "config.policy", if_match = { eq = "redis" },
    then_field = "config.redis_host", then_match = { required = true },
  } },
  { conditional = {
    if_field = "config.policy", if_match = { eq = "redis" },
    then_field = "config.redis_port", then_match = { required = true },
  } },
  { conditional = {
    if_field = "config.policy", if_match = { eq = "redis" },
    then_field = "config.redis_timeout", then_match = { required = true },
  } },
},
}

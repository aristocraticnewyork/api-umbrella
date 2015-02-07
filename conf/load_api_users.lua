local _M = {}

local inspect = require "inspect"
local bson = require "resty-mongol.bson"
local lock = require "resty.lock"
local mongol = require "resty-mongol"
local std_table = require "std.table"
local types = require "pl.types"
local utils = require "utils"

local cache_computed_settings = utils.cache_computed_settings
local clone_select = std_table.clone_select
local get_utc_date = bson.get_utc_date
local invert = std_table.invert
local is_empty = types.is_empty
local set_packed = utils.set_packed

local lock = lock:new("my_locks", {
  ["timeout"] = 0,
})

local api_users = ngx.shared.api_users

local delay = 0.01 -- in seconds
local new_timer = ngx.timer.at
local log = ngx.log
local ERR = ngx.ERR

local function do_check()
  local elapsed, err = lock:lock("load_api_users")
  if err then
    return
  end

  local conn = mongol()
  conn:set_timeout(1000)

  local ok, err = conn:connect("127.0.0.1", 27017)
  if not ok then
    log(ERR, "connect failed: "..err)
  end

  local db = conn:new_db_handle("api_umbrella_test")
  local col = db:get_col("api_users")

  local last_fetched_time = api_users:get("last_updated_at") or 0

  local r = col:find({
    updated_at = {
      ["$gt"] = get_utc_date(last_fetched_time),
    },
  })
  r:sort({ updated_at = -1 })
  for i , v in r:pairs() do
    if i == 1 then
      api_users:set("last_updated_at", v["updated_at"])
    end

    local user = clone_select(v, {
      "disabled_at",
      "throttle_by_ip",
    })

    -- Ensure IDs get stored as strings, even if Mongo ObjectIds are in use.
    user["id"] = tostring(v["_id"])

    -- Invert the array of roles into a hashy table for more optimized
    -- lookups (so we can just check if the key exists, rather than
    -- looping over each value).
    if v["roles"] then
      user["roles"] = invert(v["roles"])
    end

    if user["throttle_by_ip"] == false then
      user["throttle_by_ip"] = nil
    end

    if v["settings"] then
      user["settings"] = clone_select(v["settings"], {
        "allowed_ips",
        "allowed_referers",
        "rate_limit_mode",
        "rate_limits",
      })

      if is_empty(user["settings"]) then
        user["settings"] = nil
      else
        cache_computed_settings(user["settings"])
      end
    end

    set_packed(api_users, v["api_key"], user)
  end

  conn:set_keepalive(10000, 5)

  local ok, err = lock:unlock()
  if not ok then
    ngx.log(ngx.ERR, "failed to unlock: ", err)
  end
end

local function check(premature)
  if premature then
    return
  end

  local ok, err = pcall(do_check)
  if not ok then
    ngx.log(ngx.ERR, "failed to run api fetch cycle: ", err)
  end

  local ok, err = new_timer(delay, check)
  if not ok then
    if err ~= "process exiting" then
      ngx.log(ngx.ERR, "failed to create timer: ", err)
    end

    return
  end
end

function _M.spawn()
  local ok, err = new_timer(0, check)
  if not ok then
    log(ERR, "failed to create timer: ", err)
    return
  end
end

return _M

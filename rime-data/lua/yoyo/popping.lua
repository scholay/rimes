-- yoyo顶功处理器

local yoyo = require "yoyo.yoyo"

local processor = {}

---@class PoppingConfig
---@field when string
---@field match string
---@field accept string
---@field prefix number
---@field strategy string

---@class PoppingEnv: Env
---@field popping PoppingConfig[]
---@field processing boolean

--- 策略映射
local strategies = {
  pop = "pop",
  append = "append",
  conditional = "conditional"
}

---@param env PoppingEnv
function processor.init(env)
  env.processing = false
  
  -- 解析顶功配置
  local config = env.engine.schema.config
  local popping_config = config:get_list("speller/popping")
  if not popping_config then
    return
  end
  
  ---@type PoppingConfig[]
  env.popping = {}
  for i = 1, popping_config.size do
    local item = popping_config:get_at(i - 1)
    if not item then goto continue end
    local value = item:get_map()
    if not value then goto continue end
    local popping = {
      when = value:get_value("when") and value:get_value("when"):get_string(),
      match = value:get_value("match"):get_string(),
      accept = value:get_value("accept"):get_string(),
      prefix = value:get_value("prefix") and value:get_value("prefix"):get_int(),
      strategy = value:get_value("strategy") and value:get_value("strategy"):get_string()
    }
    if popping.strategy ~= nil and strategies[popping.strategy] == nil then
      yoyo.errorf("Invalid popping strategy: %s", popping.strategy)
      goto continue
    end
    table.insert(env.popping, popping)
    ::continue::
  end
end

---@param key_event KeyEvent
---@param env PoppingEnv
function processor.func(key_event, env)
  if env.processing then
    return yoyo.kNoop
  end
  
  local context = env.engine.context
  if key_event:release() or key_event:alt() or key_event:ctrl() or key_event:caps() then
    return yoyo.kNoop
  end
  
  local incoming = utf8.char(key_event.keycode)
  local input = yoyo.current(context)
  if not input then
    return yoyo.kNoop
  end

  for _, rule in ipairs(env.popping or {}) do
    -- 检查规则条件
    if rule.when and not context:get_option(rule.when) then
      goto continue
    end
    if not rime_api.regex_match(input, rule.match) then
      goto continue
    end
    if not rime_api.regex_match(incoming, rule.accept) then
      goto continue
    end
    
    -- 处理不同策略
    if rule.strategy == strategies.append then
      goto finish
    elseif rule.strategy == strategies.conditional then
      context:push_input(incoming)
      if context:has_menu() then
        context:pop_input(1)
        goto finish
      end
      context:pop_input(1)
    end
    
    -- 处理前缀
    if rule.prefix then
      context:pop_input(input:len() - rule.prefix)
    end
    
    -- 执行顶屏
    if context:has_menu() then
      context:confirm_current_selection()
      context:commit()
      break
    end
    -- 处理前缀
    if rule.prefix then
      context:push_input(input:sub(rule.prefix + 1))
    end
    ::continue::
  end
  
  ::finish::
  return yoyo.kNoop
end

return processor

-- 纯码元上屏处理器：使用 Ctrl 键提交当前输入的纯码元
-- 例如：未上屏的输入是"[pp]=P"，按下Ctrl键后，只上屏"ppP"

local yoyo = require "yoyo.yoyo"
local processor = {}

---@param env Env
function processor.init(env)
  env.processing = false
end

---@param key_event KeyEvent
---@param env Env
function processor.func(key_event, env)
  if env.processing then return yoyo.kNoop end
  
  -- 只处理纯Ctrl键按下事件
  if not key_event:release() and key_event:ctrl() and not (key_event:alt() or key_event:shift() or key_event:caps()) then
    local context = env.engine.context
    local input = yoyo.current(context)
    
    -- 检查并处理有效输入
    if input and input ~= "" then
      local cleaned = input:gsub("[-=_+%[%]%(%)]", "")
      if cleaned and cleaned ~= "" then
        env.processing = true
        -- 清空当前输入并提交清理后的编码
        context:clear()
        env.engine:commit_text(cleaned)
        
        env.processing = false
        return yoyo.kAccepted
      end
    end
  end
  
  return yoyo.kNoop
end

return processor
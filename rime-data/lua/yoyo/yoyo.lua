local yoyo = {
    kRejected = 0,
    kAccepted = 1,
    kNoop = 2,
    kVoid = "kVoid",
    kGuess = "kGuess",
    kSelected = "kSelected",
    kConfirmed = "kConfirmed",
    kNull = "kNull",     -- 空節點
    kScalar = "kScalar", -- 純數據節點
    kList = "kList",     -- 列表節點
    kMap = "kMap",       -- 字典節點
    kShift = 0x1,
    kLock = 0x2,
    kControl = 0x4,
    kAlt = 0x8,
}

--- 取出输入中当前正在翻译的一部分（返回光标前最后一个分词的完整编码，比如“nihao”会返回“hao”）
---@param context Context
function yoyo.current(context)
    local segment = context.composition:toSegmentation():back()
    if not segment then
        return nil
    end
    return context.input:sub(segment.start + 1, segment._end)
end

---格式化 Info 日志
---@param format string|number
function yoyo.infof(format, ...)
    log.info(string.format(format, ...))
end

---格式化 Warn 日志
---@param format string|number
function yoyo.warnf(format, ...)
    log.warning(string.format(format, ...))
end

---格式化 Error 日志
---@param format string|number
function yoyo.errorf(format, ...)
    log.error(string.format(format, ...))
end

return yoyo

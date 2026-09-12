--- @param str string
--- @return string
local function escape_string(str)
    -- Parenthesized to truncate gsub's second return (replacement count) to nothing, rather than
    -- assigning it to an undeclared `_` — that was an implicit global write, not a local discard.
    str = (str:gsub("\\", "\\\\"):gsub("\n", "\\n"):gsub('"', '\\"'))
    return str
end

--- @param names string[]
--- @param values (string|number|boolean)[]
--- @return string
--- @overload fun(names:nil, values:nil): string
local function labels_to_key(names, values)
    if names == nil and values == nil then
        return ""
    end

    assert(#names == #values, "The numbers of label names and label values differ")

    local result = {}
    for i = 1, #names do
        local name = names[i]
        local value = tostring(values[i])

        table.insert(result, name .. "=\"" .. escape_string(value) .. "\"")
    end

    if #result == 0 then
        return ""
    end

    return "{" .. table.concat(result, ",") .. "}"
end

--- @param value number
--- @return string
local function metric_to_string(value)
    if value == math.huge then
        return "+Inf"
    elseif value == -math.huge then
        return "-Inf"
    elseif value ~= value then
        return "NaN"
    else
        return tostring(value)
    end
end

-- ###

--- @param id string
local function validate_id(id)
    for _ in id:gmatch("%s") do
        error("Parameter `id` must not contain spaces, but it is `" .. id .. "`")
    end
end

-- ###

--- @class Gauge
--- @field id string
--- @field name string
--- @field observations number[]
--- @field label_names? string[]
local Gauge = {}
Gauge.__index = Gauge

--- @param id string
--- @param name string
--- @param label_names? string[]
--- @return Gauge
function Gauge.new(id, name, label_names)
    validate_id(id)

    local observations_cache = storage.registry[id]

    local obj = {
        id = id,
        name = name,
        observations = observations_cache or {},
        label_names = label_names,
    }

    setmetatable(obj, Gauge)

    return obj
end

--- @param num number
--- @param label_values? (string|number|boolean)[]
function Gauge:set(num, label_values)
    local label_key = labels_to_key(self.label_names, label_values)
    self.observations[label_key] = num

    storage.registry[self.id] = self.observations
end

--- @param num number
--- @param label_values? (string|number|boolean)[]
function Gauge:increment_by(num, label_values)
    assert(num >= 0, "Tried to increment by a negative value")

    local label_key = labels_to_key(self.label_names, label_values)
    local old_num = self.observations[label_key] or 0
    self.observations[label_key] = old_num + num

    storage.registry[self.id] = self.observations
end

--- @param num number
--- @param label_values? (string|number|boolean)[]
function Gauge:decrement_by(num, label_values)
    assert(num >= 0, "Tried to decrement by a negative value")

    local label_key = labels_to_key(self.label_names, label_values)
    local old_num = self.observations[label_key] or 0
    self.observations[label_key] = old_num - num

    storage.registry[self.id] = self.observations
end

function Gauge:collect_metrics()
    local result = {}

    table.insert(result, "# HELP " .. self.id .. " " .. escape_string(self.name))
    table.insert(result, "# TYPE " .. self.id .. " gauge")

    if next(self.observations) == nil then
        table.insert(result, self.id .. " 0")
    end

    for label_key, observation in pairs(self.observations) do
        local str = self.id .. label_key .. " " .. metric_to_string(observation)
        table.insert(result, str)
    end

    return result
end

-- ###

--- @class Counter
--- @field id string
--- @field name string
--- @field observations number[]
--- @field label_names? string[]
local Counter = {}
Counter.__index = Counter

--- @param id string
--- @param name string
--- @param label_names? string[]
--- @return Counter
function Counter.new(id, name, label_names)
    validate_id(id)

    local observations_cache = storage.registry[id]

    local obj = {
        id = id,
        name = name,
        observations = observations_cache or {},
        label_names = label_names,
    }

    setmetatable(obj, Counter)

    return obj
end

--- @param num number
--- @param label_values? (string|number|boolean)[]
function Counter:set(num, label_values)
    local label_key = labels_to_key(self.label_names, label_values)
    local old_num = self.observations[label_key] or 0

    assert(num >= old_num, "Tried to decrement a counter")

    self.observations[label_key] = num

    storage.registry[self.id] = self.observations
end

--- @param num number
--- @param label_values? (string|number|boolean)[]
function Counter:increment_by(num, label_values)
    assert(num >= 0, "Tried to increment by a negative value")

    local label_key = labels_to_key(self.label_names, label_values)
    local old_num = self.observations[label_key] or 0
    self.observations[label_key] = old_num + num

    storage.registry[self.id] = self.observations
end

function Counter:collect_metrics()
    local result = {}

    table.insert(result, "# HELP " .. self.id .. " " .. escape_string(self.name))
    table.insert(result, "# TYPE " .. self.id .. " counter")

    if next(self.observations) == nil then
        table.insert(result, self.id .. " 0")
    end

    for label_key, observation in pairs(self.observations) do
        local str = self.id .. label_key .. " " .. metric_to_string(observation)
        table.insert(result, str)
    end

    return result
end

-- ###

--- @class Registry
--- @field id_prefix string
--- @field collectors (Gauge|Counter)[]
local Registry = {}
Registry.__index = Registry

--- @param id_prefix? string
--- @return Registry
function Registry.new(id_prefix)
    local obj = {
        id_prefix = id_prefix or "",
        collectors = {},
    }

    setmetatable(obj, Registry)

    return obj
end

--- @param id string
--- @param name string
--- @param labels? string[]
--- @return Gauge
function Registry:new_gauge(id, name, labels)
    local id_long = self.id_prefix .. id

    if self.collectors[id_long] ~= nil then
        error("Collector id `" .. id_long .. "` is already registered")
    end

    local collector = Gauge.new(id_long, name, labels)
    self.collectors[id_long] = collector
    return collector
end

--- @param id string
--- @param name string
--- @param labels? string[]
--- @return Counter
function Registry:new_counter(id, name, labels)
    local id_long = self.id_prefix .. id

    if self.collectors[id_long] ~= nil then
        error("Collector id `" .. id_long .. "` is already registered")
    end

    local collector = Counter.new(id_long, name, labels)
    self.collectors[id_long] = collector
    return collector
end

function Registry:collect_metrics()
    local result = {}
    for _, collector in pairs(self.collectors) do
        for _, metric in ipairs(collector:collect_metrics()) do
            table.insert(result, metric)
        end
        table.insert(result, "")
    end

    return table.concat(result, "\n") .. "\n"
end

-- ###

return {
    Registry = Registry,
}

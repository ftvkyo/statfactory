local prometheus = require("lib/prometheus/prometheus")

local registry = prometheus.Registry.new("factorio_")

local gauges = {}
local counters = {}

local function collect_metrics()
    helpers.write_file("statfactory/game.prom", registry:collect_metrics(), false)
end

--- @overload fun(event:EventData.on_player_joined_game)
--- @overload fun(event:EventData.on_player_left_game)
--- @overload fun(event:EventData.on_player_removed)
--- @overload fun(event:EventData.on_player_kicked)
--- @overload fun(event:EventData.on_player_banned)
--- @overload fun(event:EventData.on_player_unbanned)
local function on_player_change(_event)
    gauges.players_connected:set(#game.connected_players)
    gauges.players_total:set(#game.players)
end

--- @param event EventData.on_player_died
local function on_player_died(event)
    local player = game.get_player(event.player_index)
    if player ~= nil then
        counters.player_deaths:increment_by(1, { player.force.name, player.name })
    end
end

--- Only tiles placeable by an item (concrete, stone-path, landfill, etc.)
--- count as "pavement". Natural terrain tiles are never placed this way, so
--- this also guards `pavement_tiles_seen` against ever recording one -
--- `refresh_area_paved` recounts a tracked tile across the whole surface,
--- and a natural tile slipping in there would misreport most of the map.
--- @param tile_name string
--- @return boolean
local function is_pavement_tile(tile_name)
    local proto = prototypes.tile[tile_name]
    return proto ~= nil and next(proto.items_to_place_this or {}) ~= nil
end

--- @param surface_index uint
--- @param tile_name string
local function mark_pavement_tile_seen(surface_index, tile_name)
    if not is_pavement_tile(tile_name) then
        return
    end

    local seen = storage.pavement_tiles_seen[surface_index]
    if seen == nil then
        seen = {}
        storage.pavement_tiles_seen[surface_index] = seen
    end

    seen[tile_name] = true
end

--- @overload fun(event:EventData.on_player_built_tile)
--- @overload fun(event:EventData.on_robot_built_tile)
local function on_tile_built(event)
    local tile = event.tile
    local surface = game.get_surface(event.surface_index)
    if surface ~= nil then
        gauges.area_paved:increment_by(#event.tiles, { surface.name, tile.name })
        mark_pavement_tile_seen(event.surface_index, tile.name)
    end
end

--- @overload fun(event:EventData.on_player_mined_tile)
--- @overload fun(event:EventData.on_robot_mined_tile)
local function on_tile_mined(event)
    local surface = game.get_surface(event.surface_index)
    if surface ~= nil then
        for _, tile in ipairs(event.tiles) do
            gauges.area_paved:decrement_by(1, { surface.name, tile.old_tile.name })
            mark_pavement_tile_seen(event.surface_index, tile.old_tile.name)
        end
    end
end

--- Recounts tracked pavement tiles from live game state, correcting any
--- drift from tile destruction that bypasses the built/mined tile events
--- (e.g. nukes, reactor explosions - see on_18000th_tick).
--- @param surface LuaSurface
local function refresh_area_paved(surface)
    local seen = storage.pavement_tiles_seen[surface.index]
    if seen == nil then
        return
    end

    for tile_name, _ in pairs(seen) do
        local count = surface.count_tiles_filtered({ name = tile_name })
        gauges.area_paved:set(count, { surface.name, tile_name })
    end
end

--- @param event EventData.on_rocket_launched
local function on_rocket_launched(event)
    local silo = event.rocket_silo
    if silo ~= nil then
        counters.rockets_launched:increment_by(1, { silo.surface.name, silo.force.name })
    end
end

--- @param event EventData.on_research_finished
local function on_research_finished(event)
    counters.researches_finished:increment_by(1, { event.research.force.name })
end

--- @param force LuaForce
local function refresh_research(force)
    local current = force.current_research
    local previous_name = storage.current_research[force.name]

    if current ~= nil then
        if previous_name ~= nil and previous_name ~= current.name then
            gauges.research_progress:set(0, { force.name, previous_name })
        end
        gauges.research_progress:set(force.research_progress, { force.name, current.name })
        storage.current_research[force.name] = current.name
    elseif previous_name ~= nil then
        gauges.research_progress:set(0, { force.name, previous_name })
        storage.current_research[force.name] = nil
    end
end

--- @param surface LuaSurface
local function refresh_pollution(surface)
    local pollution = surface:get_total_pollution()
    gauges.pollution:set(pollution, { surface.name })

    local pollution_statistics = game.get_pollution_statistics(surface)

    for name, num in pairs(pollution_statistics.input_counts) do
        gauges.pollution_produced:set(num, { surface.name, name })
    end

    for name, num in pairs(pollution_statistics.output_counts) do
        gauges.pollution_consumed:set(num, { surface.name, name })
    end
end

--- @param surface LuaSurface
local function refresh_evolution(surface)
    local enemy = game.forces["enemy"]

    if enemy ~= nil then
        local evolution = enemy.get_evolution_factor(surface)
        gauges.evolution:set(evolution, { surface.name })

        local evolution_by_killing_spawners = enemy.get_evolution_factor_by_killing_spawners(surface)
        gauges.evolution_by_cause:set(evolution_by_killing_spawners, { surface.name, "killing_spawners" })

        local evolution_by_pollution = enemy.get_evolution_factor_by_pollution(surface)
        gauges.evolution_by_cause:set(evolution_by_pollution, { surface.name, "pollution" })

        local evolution_by_time = enemy.get_evolution_factor_by_time(surface)
        gauges.evolution_by_cause:set(evolution_by_time, { surface.name, "time" })
    end
end

--- @param surface LuaSurface
local function refresh_kills(surface)
    for _, force in pairs(game.forces) do
        local kill_statistics = force.get_kill_count_statistics(surface)

        for entity_name, num in pairs(kill_statistics.output_counts) do
            gauges.kills:set(num, { surface.name, force.name, entity_name })
        end
    end
end

--- @param surface LuaSurface
local function refresh_production(surface)
    for _, force in pairs(game.forces) do
        local item_statistics = force.get_item_production_statistics(surface)

        for name, num in pairs(item_statistics.input_counts) do
            gauges.item_produced:set(num, { surface.name, force.name, name })
        end

        for name, num in pairs(item_statistics.output_counts) do
            gauges.item_consumed:set(num, { surface.name, force.name, name })
        end

        local fluid_statistics = force.get_fluid_production_statistics(surface)

        for name, num in pairs(fluid_statistics.input_counts) do
            gauges.fluid_produced:set(num, { surface.name, force.name, name })
        end

        for name, num in pairs(fluid_statistics.output_counts) do
            gauges.fluid_consumed:set(num, { surface.name, force.name, name })
        end
    end
end

--- Every 1 second. Reads (get_*_statistics, get_total_pollution, evolution getters) are cheap
--- lookups of Factorio's own pre-aggregated counters, not recomputation, so refreshing all of this
--- every second — rather than the previous 10-second tier — costs nothing worth measuring.
--- @param _event NthTickEventData
local function on_60th_tick(_event)
    counters.ticks_played:set(game.tick)

    for _, surface in pairs(game.surfaces) do
        if surface.pollutant_type ~= nil then
            refresh_pollution(surface)
            refresh_evolution(surface)
        end

        refresh_kills(surface)
        refresh_production(surface)
    end

    for _, force in pairs(game.forces) do
        refresh_research(force)
    end

    collect_metrics()
end

--- Every 5 minutes. Corrects area_paved drift from tile destruction that
--- bypasses the built/mined tile events (nukes, reactor explosions, etc.).
--- @param _event NthTickEventData
local function on_18000th_tick(_event)
    for _, surface in pairs(game.surfaces) do
        refresh_area_paved(surface)
    end
end

local function load()
    gauges.players_connected = registry:new_gauge("players_connected", "Players connected")
    gauges.players_total = registry:new_gauge("players_total", "Players total")

    gauges.area_paved = registry:new_gauge("area_paved", "Area paved", { "surface", "tile" })

    gauges.pollution = registry:new_gauge("pollution", "Pollution level", { "surface" })
    gauges.pollution_produced = registry:new_gauge("pollution_produced", "Pollution produced", { "surface", "name" })
    gauges.pollution_consumed = registry:new_gauge("pollution_consumed", "Pollution consumed", { "surface", "name" })

    gauges.evolution = registry:new_gauge("evolution", "Evolution factor", { "surface" })
    gauges.evolution_by_cause = registry:new_gauge("evolution_by_cause", "Evolution factor by cause", { "surface", "cause" })

    gauges.kills = registry:new_gauge("kills", "Kills", { "surface", "force", "entity" })

    gauges.item_produced = registry:new_gauge("item_produced", "Items produced", { "surface", "force", "name" })
    gauges.item_consumed = registry:new_gauge("item_consumed", "Items consumed", { "surface", "force", "name" })
    gauges.fluid_produced = registry:new_gauge("fluid_produced", "Fluids produced", { "surface", "force", "name" })
    gauges.fluid_consumed = registry:new_gauge("fluid_consumed", "Fluids consumed", { "surface", "force", "name" })

    counters.ticks_played = registry:new_counter("ticks_played", "Ticks passed")
    counters.player_deaths = registry:new_counter("player_deaths", "Player deaths", { "force", "name" })

    counters.rockets_launched = registry:new_counter("rockets_launched", "Rockets launched", { "surface", "force" })
    counters.researches_finished = registry:new_counter("researches_finished", "Researches finished", { "force" })

    gauges.research_progress = registry:new_gauge("research_progress", "Progress of the current research", { "force", "technology" })

    collect_metrics()
end

local function init()
    if not storage.registry then
        storage.registry = {}
    end

    if not storage.pavement_tiles_seen then
        storage.pavement_tiles_seen = {}
    end

    if not storage.current_research then
        storage.current_research = {}
    end

    load()

    -- Populate player counts immediately instead of waiting for the first
    -- join/leave event; `game` isn't available yet in `load()` on the
    -- `on_load` path, so this can only happen here on `on_init`.
    on_player_change()
end

script.on_event(defines.events.on_player_joined_game, on_player_change)
script.on_event(defines.events.on_player_left_game, on_player_change)
script.on_event(defines.events.on_player_removed, on_player_change)
script.on_event(defines.events.on_player_kicked, on_player_change)
script.on_event(defines.events.on_player_banned, on_player_change)
script.on_event(defines.events.on_player_unbanned, on_player_change)

script.on_event(defines.events.on_player_died, on_player_died)

script.on_event(defines.events.on_player_built_tile, on_tile_built)
script.on_event(defines.events.on_robot_built_tile, on_tile_built)

script.on_event(defines.events.on_player_mined_tile, on_tile_mined)
script.on_event(defines.events.on_robot_mined_tile, on_tile_mined)

script.on_event(defines.events.on_rocket_launched, on_rocket_launched)
script.on_event(defines.events.on_research_finished, on_research_finished)

script.on_nth_tick(60, on_60th_tick)
script.on_nth_tick(18000, on_18000th_tick)

script.on_init(init)

-- `load()` only reads `storage` (available here) and calls `helpers.write_file`
-- (safe outside of game-state context); it never touches `game`, which is nil
-- during `on_load`. See https://lua-api.factorio.com/latest/classes/LuaBootstrap.html#on_load
script.on_load(load)

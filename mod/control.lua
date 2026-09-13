local prometheus = require("lib/prometheus/prometheus")

local registry = prometheus.Registry.new("factorio_")

local gauges = {}
local counters = {}

--- Built once: defines.train_state's values are the union `train.state` returns, so a
--- lookup by value gives the label name without hardcoding the member list or
--- recomputing it on every poll.
local train_state_names = {}
for name, value in pairs(defines.train_state) do
    train_state_names[value] = name
end

--- Same idea as train_state_names, for space platforms.
local platform_state_names = {}
for name, value in pairs(defines.space_platform_state) do
    platform_state_names[value] = name
end

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

--- Concepts/Color.html: channels are floats in [0,1], UNLESS any channel is > 1, in which
--- case every channel (including alpha) is meant to be read as [0,255] instead - so the
--- scale can't be assumed from range alone without checking every channel first. Alpha is
--- read but not applied: the docs note colors are usually stored pre-multiplied by alpha,
--- but a player's identity color is always fully opaque in practice, so un-multiplying
--- would be complexity with nothing to correct.
--- @param color Color
--- @return string
local function color_to_hex(color)
    local r = color.r or 0
    local g = color.g or 0
    local b = color.b or 0
    local a = color.a or 1

    if r <= 1 and g <= 1 and b <= 1 and a <= 1 then
        r = r * 255
        g = g * 255
        b = b * 255
    end

    r = math.floor(math.min(math.max(r, 0), 255) + 0.5)
    g = math.floor(math.min(math.max(g, 0), 255) + 0.5)
    b = math.floor(math.min(math.max(b, 0), 255) + 0.5)

    return string.format("#%02x%02x%02x", r, g, b)
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

--- Seconds since the previous train arrived at a station, plus (if this train had a
--- recorded departure) the trip/wait time for the leg that just finished. Deliberately
--- never labels by train id: ids get reassigned on every couple/decouple, and
--- Prometheus observations here never expire, so a per-train label would leak an
--- ever-growing series set over a long save. `storage.train_trip` keys on train id
--- internally only, as scratch bookkeeping, never as a label.
---
--- `train_trip_time`/`train_wait_time` also carry the train's `group` (LuaTrain.group,
--- real API since 2.0's Trains-GUI grouping - LuaSchedule.group confirms it's not just a
--- GUI concept): station names alone aren't a safe route identity on a base with several
--- groups, since backer_name can be, and commonly is, reused - both across multiple
--- physical stops feeding one logical destination (see train_stops) and, in principle,
--- across two unrelated groups that happen to name a stop the same thing. `group` doesn't
--- help disambiguate identically-named *physical* stops (that's inherent to using
--- backer_name at all, not something a train-side label can fix), but it does stop two
--- different groups' routes from being silently averaged into one series if they ever
--- share a from/to name pair. `train_arrival_time` deliberately does NOT carry `group` -
--- it means "how often does any train show up here", and fragmenting that by group would
--- defeat the point. Captured once into storage.train_trip at leg start, not re-read from
--- train.group at completion, so a mid-trip reassignment can't retroactively relabel a leg
--- that already started.
--- @param event EventData.on_train_changed_state
local function on_train_changed_state(event)
    local train = event.train
    local carriage = train.carriages[1]
    if carriage == nil then
        return
    end
    local surface = carriage.surface

    if train.state == defines.train_state.wait_station and train.station ~= nil then
        local station_name = train.station.backer_name

        local arrivals = storage.train_last_arrival[surface.name]
        if arrivals == nil then
            arrivals = {}
            storage.train_last_arrival[surface.name] = arrivals
        end

        local previous_tick = arrivals[station_name]
        if previous_tick ~= nil then
            gauges.train_arrival_time:set((event.tick - previous_tick) / 60, { surface.name, station_name })
        end
        arrivals[station_name] = event.tick

        local trip = storage.train_trip[train.id]
        if trip ~= nil and trip.departed_tick ~= nil then
            gauges.train_trip_time:set(
                (event.tick - trip.departed_tick) / 60,
                { surface.name, trip.from, station_name, trip.group }
            )
            gauges.train_wait_time:set(trip.wait_accum / 60, { surface.name, trip.from, station_name, trip.group })
        end
        -- `group` is captured now (not re-read from `train.group` at completion) so a
        -- mid-trip reassignment can't retroactively relabel a leg that already started.
        storage.train_trip[train.id] = { from = station_name, wait_accum = 0, group = train.group or "" }
    end

    if event.old_state == defines.train_state.wait_station and train.state ~= defines.train_state.wait_station then
        local trip = storage.train_trip[train.id]
        if trip ~= nil then
            trip.departed_tick = event.tick
        end
    end

    if train.state == defines.train_state.wait_signal then
        local trip = storage.train_trip[train.id]
        if trip ~= nil then
            trip.wait_started = event.tick
        end
    end

    if event.old_state == defines.train_state.wait_signal and train.state ~= defines.train_state.wait_signal then
        local trip = storage.train_trip[train.id]
        if trip ~= nil and trip.wait_started ~= nil then
            trip.wait_accum = trip.wait_accum + (event.tick - trip.wait_started)
            trip.wait_started = nil
        end
    end
end

--- @param cargo_pod LuaEntity
--- @return table<string, uint>
local function snapshot_cargo_contents(cargo_pod)
    local counts = {}
    local inventory = cargo_pod.get_inventory(defines.inventory.cargo_unit)
    if inventory == nil then
        return counts
    end

    for _, item in pairs(inventory.get_contents()) do
        counts[item.name] = (counts[item.name] or 0) + item.count
    end
    return counts
end

--- Snapshots contents at launch and credits items_launched immediately - the ascend
--- event itself is the "did it actually leave" signal. The snapshot is kept, keyed by
--- unit_number, so on_cargo_pod_delivered_cargo can credit items_delivered from what was
--- launched rather than re-reading the pod's inventory, which delivery may have already
--- emptied by the time that event fires. A pod destroyed before delivery (rocket
--- explodes, no path, etc.) leaves its snapshot in storage forever - a small,
--- session-bounded leak, and also exactly the launched-but-never-delivered gap this
--- metric pair exists to surface.
--- @param event EventData.on_cargo_pod_finished_ascending
local function on_cargo_pod_finished_ascending(event)
    local cargo_pod = event.cargo_pod
    if cargo_pod == nil or not cargo_pod.valid then
        return
    end

    local origin = cargo_pod.cargo_pod_origin
    local surface = (origin ~= nil and origin.valid) and origin.surface or cargo_pod.surface
    local force = cargo_pod.force

    local contents = snapshot_cargo_contents(cargo_pod)
    storage.cargo_pod_contents[cargo_pod.unit_number] = contents

    for name, count in pairs(contents) do
        counters.items_launched:increment_by(count, { surface.name, force.name, name })
    end
end

--- @param event EventData.on_cargo_pod_delivered_cargo
local function on_cargo_pod_delivered_cargo(event)
    local cargo_pod = event.cargo_pod
    if cargo_pod == nil or not cargo_pod.valid then
        return
    end

    local contents = storage.cargo_pod_contents[cargo_pod.unit_number]
    storage.cargo_pod_contents[cargo_pod.unit_number] = nil
    if contents == nil then
        return
    end

    local surface = cargo_pod.surface
    local force = cargo_pod.force

    for name, count in pairs(contents) do
        counters.items_delivered:increment_by(count, { surface.name, force.name, name })
    end
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

--- Exposes each player's identity color (LuaPlayer.color - tints their character,
--- buildings and vehicles; distinct from chat_color, which only colors chat text) as a
--- hex label, so a Grafana "Config from query results" transform can read it and color
--- other panels' per-player series to match, instead of hand-maintaining a static color
--- override per player. The gauge's numeric value carries no meaning of its own (always 1
--- for the active hex, 0 for a superseded one) - the hex label is the payload. Same
--- remember-and-zero-the-old-value pattern as refresh_research: colors rarely change, so
--- this is a poll rather than wiring the dedicated on_player_color_changed event, and
--- polling means an existing save upgrading to this version backfills every known
--- player's color on its very first tick rather than only from their next change.
local function refresh_player_colors()
    for _, player in pairs(game.players) do
        local hex = color_to_hex(player.color)
        local previous_hex = storage.player_color[player.name]

        if previous_hex ~= hex then
            if previous_hex ~= nil then
                gauges.player_color:set(0, { player.force.name, player.name, previous_hex })
            end
            gauges.player_color:set(1, { player.force.name, player.name, hex })
            storage.player_color[player.name] = hex
        end
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

--- Zeroes every state first so a state that drops to 0 trains is reported as 0, not
--- left at its last nonzero value (same reasoning as refresh_research zeroing the
--- technology it just switched away from). Surfaces a stuck/congested rail network
--- (high no_path/wait_signal/destination_full) at a glance. Space-platform surfaces
--- simply have no trains, so this is unconditional for every surface like
--- refresh_kills/refresh_production above, not gated on pollutant_type.
--- @param surface LuaSurface
local function refresh_trains(surface)
    local counts = {}
    for _, name in pairs(train_state_names) do
        counts[name] = 0
    end

    for _, train in pairs(game.train_manager.get_trains({ surface = surface })) do
        local name = train_state_names[train.state]
        counts[name] = counts[name] + 1
    end

    for name, count in pairs(counts) do
        gauges.train_state:set(count, { surface.name, name })
    end
end

--- Counts physical train-stop entities per backer_name (several physical stops commonly
--- share one logical name, e.g. three "Iron Ore Pickup" stops feeding one route - this
--- reports how many, which is also the reader's cue that train_arrival_time/
--- train_trip_time/train_wait_time above are aggregated across every physical stop
--- sharing that name, not naming a single entity). Same seen-names-zeroed pattern as
--- mark_pavement_tile_seen/refresh_area_paved: a name renamed or removed must read back
--- as 0, not linger at its last nonzero count.
--- @param surface LuaSurface
local function refresh_train_stops(surface)
    local counts = {}
    for _, stop in pairs(surface.find_entities_filtered({ type = "train-stop" })) do
        local name = stop.backer_name
        counts[name] = (counts[name] or 0) + 1
    end

    local seen = storage.train_stop_names_seen[surface.index]
    if seen == nil then
        seen = {}
        storage.train_stop_names_seen[surface.index] = seen
    end

    for name, _ in pairs(counts) do
        seen[name] = true
    end

    for name, _ in pairs(seen) do
        gauges.train_stops:set(counts[name] or 0, { surface.name, name })
    end
end

--- Labelled by platform per-object rather than aggregated like refresh_trains: platforms
--- are few and, unlike trains, don't get a fresh id on every couple/decouple, so a
--- per-platform label doesn't risk the series-count leak that ruled out a per-train label
--- above. Keyed on `index`, not `name`: LuaSpacePlatform's own doc page calls `index` "the
--- unique index of this space platform" but makes no such claim for `name`, so two
--- platforms sharing a name (unrenamed defaults, or two players choosing the same string)
--- would otherwise silently merge into one series. `name` is still included as a
--- human-readable label - it just isn't what identifies the row. `force.platforms`
--- includes platforms pending deletion, hence the `valid` check.
--- @param force LuaForce
local function refresh_platforms(force)
    for _, platform in pairs(force.platforms) do
        if platform.valid then
            for _, name in pairs(platform_state_names) do
                gauges.platform_state:set(0, { platform.index, platform.name, name })
            end
            gauges.platform_state:set(1, { platform.index, platform.name, platform_state_names[platform.state] })
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
        refresh_trains(surface)
        refresh_train_stops(surface)
    end

    for _, force in pairs(game.forces) do
        refresh_research(force)
        refresh_platforms(force)
    end

    refresh_player_colors()

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

    gauges.train_state = registry:new_gauge("train_state", "Trains by state", { "surface", "state" })
    gauges.train_stops = registry:new_gauge("train_stops", "Physical train stop entities by name", { "surface", "name" })
    gauges.train_arrival_time = registry:new_gauge(
        "train_arrival_time",
        "Seconds since the previous train arrived at a station",
        { "surface", "station" }
    )
    gauges.train_trip_time = registry:new_gauge(
        "train_trip_time",
        "Seconds for a train to travel between two stations",
        { "surface", "from", "to", "group" }
    )
    gauges.train_wait_time = registry:new_gauge(
        "train_wait_time",
        "Seconds a train spent waiting at a signal during a trip",
        { "surface", "from", "to", "group" }
    )

    counters.items_launched = registry:new_counter("items_launched", "Items launched via cargo pod", { "surface", "force", "name" })
    counters.items_delivered =
        registry:new_counter("items_delivered", "Items delivered via cargo pod", { "surface", "force", "name" })

    gauges.platform_state = registry:new_gauge(
        "platform_state",
        "Space platforms by state (1 = active state, 0 = inactive)",
        { "index", "name", "state" }
    )

    gauges.player_color = registry:new_gauge(
        "player_color",
        "Player identity color as a #rrggbb hex label (1 = active hex, 0 = superseded)",
        { "force", "name", "hex" }
    )

    collect_metrics()
end

--- Create any `storage` field a fresh save doesn't have yet. Safe to call whenever
--- `storage` may be missing something `load()`/the refresh functions assume exists —
--- `init` (a brand new save) and `on_configuration_changed` (an existing save catching
--- up to a newer mod version) are both such times, but this must never itself call
--- `load()`: `on_load` already runs unconditionally before `on_configuration_changed`
--- fires on every startup, and `load()` is not idempotent — the vendored prometheus
--- library errors on registering the same collector id twice.
local function backfill_storage()
    if not storage.registry then
        storage.registry = {}
    end

    if not storage.pavement_tiles_seen then
        storage.pavement_tiles_seen = {}
    end

    if not storage.current_research then
        storage.current_research = {}
    end

    if not storage.train_last_arrival then
        storage.train_last_arrival = {}
    end

    if not storage.train_trip then
        storage.train_trip = {}
    end

    if not storage.cargo_pod_contents then
        storage.cargo_pod_contents = {}
    end

    if not storage.train_stop_names_seen then
        storage.train_stop_names_seen = {}
    end

    if not storage.player_color then
        storage.player_color = {}
    end
end

local function init()
    backfill_storage()

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

script.on_event(defines.events.on_train_changed_state, on_train_changed_state)

script.on_event(defines.events.on_cargo_pod_finished_ascending, on_cargo_pod_finished_ascending)
script.on_event(defines.events.on_cargo_pod_delivered_cargo, on_cargo_pod_delivered_cargo)

script.on_nth_tick(60, on_60th_tick)
script.on_nth_tick(18000, on_18000th_tick)

script.on_init(init)

-- `on_load` only fires for a save that already exists, so it can never backfill a
-- `storage` field added by a later mod version the way `init`'s guards do. An existing
-- save that predates a field (e.g. `storage.current_research`, added in 0.0.4) keeps
-- hitting `nil` on it forever unless something re-runs those guards after an upgrade.
-- `on_configuration_changed` is that something — but only `backfill_storage`, not the
-- whole of `init`: `on_load` (below) already ran `load()` moments earlier in the same
-- startup, and calling it again here would double-register every collector.
script.on_configuration_changed(backfill_storage)

-- `load()` only reads `storage` (available here) and calls `helpers.write_file`
-- (safe outside of game-state context); it never touches `game`, which is nil
-- during `on_load`. See https://lua-api.factorio.com/latest/classes/LuaBootstrap.html#on_load
script.on_load(load)

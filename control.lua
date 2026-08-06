local MOD = "yuki-bridge"
local OUT_FILE = "yuki/events.ndjson"
local PROTOCOL_VERSION = 3
local REQUEST_ID_MAX_LEN = 64
local MAPGEN_SNAPSHOT_TRIGGERS = {
    initialized = "initialized",
    configuration_changed = "configuration_changed",
    surface_created = "surface_created",
    surface_deleted = "surface_deleted",
    surface_imported = "surface_imported",
    surface_renamed = "surface_renamed",
}

local function mod_version()
    return script.active_mods[MOD] or "unknown"
end

local function ensure_stream_state()
    if type(storage.yuki_bridge_sequence) ~= "number" then
        storage.yuki_bridge_sequence = 0
    end

    if type(storage.yuki_bridge_stream_id) ~= "string" or storage.yuki_bridge_stream_id == "" then
        storage.yuki_bridge_stream_id = string.format("%s-%d-%d", MOD, game.tick, game.ticks_played)
    end
end

local function protocol_metadata()
    return {
        schema_version = PROTOCOL_VERSION,
        mod = MOD,
        mod_version = mod_version(),
        tick = game.tick,
    }
end

local function reply_player(command, message)
    if command.player_index then
        local player = game.get_player(command.player_index)
        if player then
            player.print("[Yuki] " .. message)
        end
    end
end

local function command_response(command, action, request_id, ok, result, error_message)
    local response = protocol_metadata()
    response.kind = "command_result"
    response.command = action
    response.request_id = request_id
    response.ok = ok

    if result ~= nil then
        response.result = result
    end

    if error_message ~= nil then
        response.error = error_message
    end

    rcon.print(helpers.table_to_json(response))

    if command.player_index then
        reply_player(command, ok and "Done!" or error_message)
    end
end

local function clean(value, max_len)
    value = tostring(value or "")
    value = value:gsub("[\r\n]", " ")

    if max_len and #value > max_len then
        value = value:sub(1, max_len)
    end

    return value
end

local function player_name(player_index)
    if not player_index then
        return nil
    end

    local player = game.get_player(player_index)
    return player and player.name or nil
end

local function get_player_chat_color(name)
    local player = game.get_player(name)

    if player and player.valid then
        return player.chat_color
    end

    return nil
end

local function position_summary(position)
    if not position then
        return nil
    end

    return {
        x = position.x or position[1],
        y = position.y or position[2],
    }
end

local function entity_summary(entity)
    if not entity or not entity.valid then
        return nil
    end

    return {
        name = entity.name,
        type = entity.type,
        force = entity.force and entity.force.name or nil,
        surface = entity.surface and entity.surface.name or nil,
        position = entity.position and position_summary(entity.position) or nil,
    }
end

local function emit(kind, data)
    ensure_stream_state()

    data = data or {}
    storage.yuki_bridge_sequence = storage.yuki_bridge_sequence + 1

    data.schema_version = PROTOCOL_VERSION
    data.kind = kind
    data.tick = game.tick
    data.mod = MOD
    data.mod_version = mod_version()
    data.stream_id = storage.yuki_bridge_stream_id
    data.sequence = storage.yuki_bridge_sequence
    data.event_id = string.format("%s:%d", data.stream_id, data.sequence)

    local line = helpers.table_to_json(data)

    log("[Yuki] " .. line)

    helpers.write_file(OUT_FILE, line .. "\n", true, 0)

    return data
end

local function valid_request_id(value)
    return value:match("^[%w][%w._:-]*$") ~= nil
end

local function parse_command(raw)
    local request_id, command_text = raw:match("^%-%-request%-id%s+(%S+)%s+(.+)$")

    if request_id then
        if #request_id > REQUEST_ID_MAX_LEN then
            return nil, nil, nil, "Request ID must be 64 characters or fewer."
        end

        if not valid_request_id(request_id) then
            return nil, nil, nil, "Request ID must use only letters, digits, '.', '_', ':', or '-'."
        end
    elseif raw:match("^%-%-request%-id") then
        return nil, nil, nil, "Usage: --request-id <id> must be followed by a Yuki command."
    else
        command_text = raw
    end

    local action, rest = command_text:match("^(%S+)%s*(.*)$")
    return action, rest, request_id, nil
end

local function bridge_say(raw, request_id)
    raw = clean(raw, 1200)

    local speaker, message = raw:match("^([^|]+)|(.+)$")
    if not speaker or not message then
        return false, "Usage: /yuki say Speaker|message"
    end

    speaker = clean(speaker, 64)
    message = clean(message, 500)

    if message == "" then
        return false, "Message is empty"
    end

    local color = get_player_chat_color(speaker)

    if color then
        game.print(speaker .. ": " .. message, { color = color })
    else
        game.print(speaker .. ": " .. message)
    end

    local emitted = emit("bridge_message", {
        source = "rcon",
        speaker = speaker,
        message = message,
        matched_player = color ~= nil,
        request_id = request_id,
    })

    return true, {
        event_id = emitted.event_id,
        speaker = speaker,
        matched_player = color ~= nil,
    }
end

local function surface_summary(surface)
    local planet = nil

    if surface.planet and surface.planet.valid then
        planet = surface.planet.name
    end

    return {
        name = surface.name,
        index = surface.index,
        planet = planet,
        platform = surface.platform and surface.platform.valid and surface.platform.name or nil,
    }
end

local function autoplace_controls_summary(controls)
    local summaries = {}

    for name, control in pairs(controls) do
        table.insert(summaries, {
            name = name,
            frequency = control.frequency,
            size = control.size,
            richness = control.richness,
        })
    end

    table.sort(summaries, function(left, right)
        return left.name < right.name
    end)

    return summaries
end

local function starting_points_summary(points)
    local summaries = {}

    for _, point in ipairs(points) do
        table.insert(summaries, position_summary(point))
    end

    return summaries
end

local function mapgen_surface_summary(surface)
    local settings = surface.map_gen_settings

    return {
        surface = surface_summary(surface),
        map_exchange_string = surface.get_map_exchange_string(),
        settings = {
            seed = settings.seed,
            width = settings.width,
            height = settings.height,
            starting_area = settings.starting_area,
            starting_points = starting_points_summary(settings.starting_points),
            peaceful_mode = settings.peaceful_mode,
            no_enemies_mode = settings.no_enemies_mode,
            default_enable_all_autoplace_controls = settings.default_enable_all_autoplace_controls,
            autoplace_controls = autoplace_controls_summary(settings.autoplace_controls),
        },
    }
end

local function all_mapgen()
    local surfaces = {}

    for _, surface in pairs(game.surfaces) do
        table.insert(surfaces, mapgen_surface_summary(surface))
    end

    table.sort(surfaces, function(left, right)
        return left.surface.index < right.surface.index
    end)

    return { surfaces = surfaces }
end

local function emit_mapgen_snapshot(trigger)
    local snapshot = all_mapgen()
    snapshot.trigger = trigger
    emit("mapgen_snapshot", snapshot)
end

local function evolution_for_force(force_name)
    local force = game.forces[force_name]

    if not force then
        return nil, "Unknown force: " .. force_name
    end

    local surfaces = {}

    for _, surface in pairs(game.surfaces) do
        table.insert(surfaces, {
            surface = surface_summary(surface),
            evolution = {
                total = force.get_evolution_factor(surface),
                pollution = force.get_evolution_factor_by_pollution(surface),
                time = force.get_evolution_factor_by_time(surface),
                spawner_kills = force.get_evolution_factor_by_killing_spawners(surface),
            },
        })
    end

    return { force = force.name, surfaces = surfaces }, nil
end

local function all_evolution()
    local forces = {}

    for _, force in pairs(game.forces) do
        local result = evolution_for_force(force.name)
        table.insert(forces, result)
    end

    return { kind = "evolution", tick = game.tick, forces = forces }
end

local function respond_with_event(command, action, request_id, kind, payload)
    payload.by = player_name(command.player_index) or "rcon"
    payload.request_id = request_id

    local emitted = emit(kind, payload)
    command_response(command, action, request_id, true, emitted, nil)
end

local function respond_with_error(command, action, request_id, error_message)
    emit("error", {
        command = action,
        error = error_message,
        by = player_name(command.player_index) or "rcon",
        request_id = request_id,
    })
    command_response(command, action, request_id, false, nil, error_message)
end

local function capabilities()
    return {
        schema_version = PROTOCOL_VERSION,
        event_envelope = {
            "schema_version",
            "event_id",
            "stream_id",
            "sequence",
            "tick",
            "mod",
            "mod_version",
            "kind",
        },
        commands = {
            "capabilities",
            "say",
            "evolution",
        },
        events = {
            "bridge_message",
            "chat",
            "error",
            "evolution",
            "mapgen_snapshot",
            "player_died",
            "research_finished",
        },
        automatic_events = {
            mapgen_snapshot = {
                delivery = "event_stream",
                triggers = {
                    MAPGEN_SNAPSHOT_TRIGGERS.initialized,
                    MAPGEN_SNAPSHOT_TRIGGERS.configuration_changed,
                    MAPGEN_SNAPSHOT_TRIGGERS.surface_created,
                    MAPGEN_SNAPSHOT_TRIGGERS.surface_deleted,
                    MAPGEN_SNAPSHOT_TRIGGERS.surface_imported,
                    MAPGEN_SNAPSHOT_TRIGGERS.surface_renamed,
                },
            },
        },
        request_correlation = {
            argument = "--request-id <id>",
            id_pattern = "^[A-Za-z0-9][A-Za-z0-9._:-]*$",
            max_id_length = REQUEST_ID_MAX_LEN,
            response_field = "request_id",
            event_field = "request_id",
        },
        factorio_version = script.active_mods.base or "unknown",
    }
end

local function initialize_bridge()
    ensure_stream_state()
    emit_mapgen_snapshot(MAPGEN_SNAPSHOT_TRIGGERS.initialized)
end

local function register_mapgen_snapshot_event(event_id, trigger)
    script.on_event(event_id, function()
        emit_mapgen_snapshot(trigger)
    end)
end

script.on_init(initialize_bridge)
script.on_configuration_changed(function()
    emit_mapgen_snapshot(MAPGEN_SNAPSHOT_TRIGGERS.configuration_changed)
end)
register_mapgen_snapshot_event(defines.events.on_surface_created, MAPGEN_SNAPSHOT_TRIGGERS.surface_created)
register_mapgen_snapshot_event(defines.events.on_surface_deleted, MAPGEN_SNAPSHOT_TRIGGERS.surface_deleted)
register_mapgen_snapshot_event(defines.events.on_surface_imported, MAPGEN_SNAPSHOT_TRIGGERS.surface_imported)
register_mapgen_snapshot_event(defines.events.on_surface_renamed, MAPGEN_SNAPSHOT_TRIGGERS.surface_renamed)

commands.add_command("yuki", "Yuki bridge command: capabilities/say/evolution", function(command)
    local param = clean(command.parameter or "", 1500)
    local action, rest, request_id, parse_error = parse_command(param)

    if parse_error then
        command_response(command, "unknown", nil, false, nil, parse_error)
        return
    end

    if action == "capabilities" then
        command_response(command, action, request_id, true, capabilities(), nil)
        return
    end

    if action == "mapgen" then
        command_response(
            command,
            action,
            request_id,
            false,
            nil,
            "Map generation settings are published automatically as mapgen_snapshot events. Do not use /c or /silent-command."
        )
        return
    end

    if action == "say" then
        local ok, result = bridge_say(rest, request_id)
        if ok then
            command_response(command, action, request_id, true, result, nil)
        else
            command_response(command, action, request_id, false, nil, result)
        end
        return
    end

    if action == "evolution" then
        local force_name = clean(rest, 64)
        local payload

        if force_name == "" then
            force_name = "enemy"
        end

        if force_name == "all" then
            payload = all_evolution()
        else
            local result, err = evolution_for_force(force_name)
            if not result then
                respond_with_error(command, action, request_id, err)
                return
            end

            payload = {
                kind = "evolution",
                tick = game.tick,
                force = result.force,
                surfaces = result.surfaces,
            }
        end

        respond_with_event(command, action, request_id, "evolution", payload)

        return
    end

    command_response(
        command,
        action or "unknown",
        request_id,
        false,
        nil,
        "Usage: /yuki [--request-id <id>] capabilities | say Speaker|message | evolution [enemy|all|force]"
    )
end)

script.on_event(defines.events.on_player_died, function(event)
    local player = game.get_player(event.player_index)

    emit("player_died", {
        player = player and player.name or nil,
        player_index = event.player_index,
        surface = player and player.surface and player.surface.name or nil,
        position = player and player.position and position_summary(player.position) or nil,
        cause = entity_summary(event.cause),
    })
end)

script.on_event(defines.events.on_research_finished, function(event)
    local research = event.research

    emit("research_finished", {
        technology = research and research.name or nil,
        localised_name = research and research.localised_name or nil,
        level = research and research.level or nil,
        force = research and research.force and research.force.name or nil,
        by_script = event.by_script,
    })
end)

script.on_event(defines.events.on_console_chat, function(event)
    emit("chat", {
        source = "factorio",
        player = player_name(event.player_index) or "server",
        player_index = event.player_index,
        message = clean(event.message, 500),
    })
end)

local MOD = "yuki-bridge"
local OUT_FILE = "yuki/events.ndjson"

local function reply(command, message)
    rcon.print(message)

    if command.player_index then
        local player = game.get_player(command.player_index)
        if player then
            player.print("[Yuki] " .. message)
        end
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

local function entity_summary(entity)
    if not entity or not entity.valid then
        return nil
    end

    return {
        name = entity.name,
        type = entity.type,
        force = entity.force and entity.force.name or nil,
        surface = entity.surface and entity.surface.name or nil,
        position = entity.position and { x = entity.position.x, y = entity.position.y } or nil,
    }
end

local function emit(kind, data)
    data = data or {}
    data.kind = kind
    data.tick = game.tick
    data.mod = MOD

    local line = helpers.table_to_json(data)

    log("[Yuki] " .. line)

    helpers.write_file(OUT_FILE, line .. "\n", true, 0)
end

local function print_rcon(data)
    rcon.print(helpers.table_to_json(data))
end

local function bridge_say(raw)
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

    game.print(speaker .. ": " .. message)

    emit("bridge_message", { source = "rcon", speaker = speaker, message = message })

    return true, "ok"
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

commands.add_command("yuki", "Yuki bridge command: say/evolution", function(command)
    local param = clean(command.parameter or "", 1500)
    local action, rest = param:match("^(%S+)%s*(.*)$")

    if action == "say" then
        local ok, result = bridge_say(rest)
        reply(command, result)
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
                reply(command, err)

                emit("error", {
                    command = "evolution",
                    error = err,
                    by = player_name(command.player_index) or "rcon",
                })
                return
            end

            payload = {
                kind = "evolution",
                tick = game.tick,
                force = result.force,
                surfaces = result.surfaces,
            }
        end

        payload.by = player_name(command.player_index) or "rcon"

        print_rcon(payload)

        emit("evolution", payload)

        if command.player_index then
            reply(command, "Done!")
        end

        return
    end

    rcon.print("Usage: /yuki say Speaker|message | /yuki evolution [enemy|all|force]")
end)

script.on_event(defines.events.on_player_died, function(event)
    local player = game.get_player(event.player_index)

    emit("player_died", {
        player = player and player.name or nil,
        player_index = event.player_index,
        surface = player and player.surface and player.surface.name or nil,
        position = player and player.position and { x = player.position.x, y = player.position.y } or nil,
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

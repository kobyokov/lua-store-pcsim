-- ============================================================================
-- 2D CS-LIKE MULTIPLAYER FFA v9 • V5 BASE + JOIN FIX
--
-- СЕТЕВОЙ ПРОТОТИП ДЛЯ PC SIMULATOR LUA API
--
-- Возможности:
--   * Первый активный экземпляр становится хостом.
--   * Остальные автоматически подключаются через localhost_send/receive.
--   * Лобби показывает случайный ник и полный system_id каждого ПК.
--   * Кнопка START доступна только хосту.
--   * Во время матча новые подключения получают "Катка уже идёт".
--   * Режим FFA: один патрон убивает, затем игрок возрождается.
--   * Большая карта и камера, следующая за локальным игроком.
--   * Левый джойстик: движение. Правый: прицел + автоматический огонь.
--   * Хост рассчитывает движение, пули, попадания, смерти и респавны.
--   * v8 основана напрямую на быстрой v5: без input queue/replay/ACK.
--   * Клиент мгновенно двигает только визуальную позицию своего игрока.
--   * Старые JOIN-пакеты после старта не перетирают игровые STATE-пакеты.
--
-- ВАЖНО:
--   localhost API документирует только отправку строки в канал и чтение строки
--   из канала. Поэтому протокол использует:
--     1) общий канал маяка хоста;
--     2) общий канал заявок JOIN;
--     3) отдельный входной канал для каждого клиента;
--     4) отдельный выходной канал для каждого клиента.
--
--   Пакеты имеют счётчики. Один и тот же пакет можно читать несколько раз, но
--   повторно он не применяется. Клиенты регулярно повторяют JOIN/INPUT, чтобы
--   общий односообщенческий канал не терял игроков при одновременной отправке.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- НАСТРОЙКИ
-- ---------------------------------------------------------------------------
local START_W = 1280
local START_H = 720
local WORLD_W = 3600
local WORLD_H = 2400
local PROTOCOL_VERSION = "CSFFA9"
local ROOT_CHANNEL = "cs2d_ffa_multiplayer_v9"
local HOST_BEACON_CHANNEL = ROOT_CHANNEL .. "_host_beacon"
local JOIN_CHANNEL = ROOT_CHANNEL .. "_join"

local DISCOVERY_SECONDS = 2.4
local HOST_BEACON_INTERVAL = 0.50
local JOIN_INTERVAL = 0.65
local LOBBY_SEND_INTERVAL = 0.45
local INPUT_SEND_INTERVAL = 0.08
local STATE_SEND_INTERVAL = 0.12
local CLIENT_TIMEOUT = 5.0
local HOST_TIMEOUT = 3.0

local FIXED_DT = 1 / 30

-- Разные подсистемы обновляются с разной частотой.
-- Физика остаётся 30 Гц, но тяжёлая карта/UI/сеть больше не выполняются каждый кадр.
local PERF = {
    network_interval = 1 / 20,
    world_interval = 1 / 12,
    aim_interval = 1 / 15,
    hud_interval = 0.25,
    lobby_interval = 0.25,
    camera_threshold = 2.0,
    collision_cell = 300,
    wall_cells = {},
    bullet_scale_key = nil,
    aim_scale_key = nil,
    scoreboard_cache = {},
    hud_cache = {},
    next_network = 0,
    next_world = 0,
    next_aim = 0,
    next_hud = 0,
    next_lobby = 0,
    last_camera_x = -999999,
    last_camera_y = -999999
}
local PLAYER_RADIUS = 20
local PLAYER_SPEED = 285
local BULLET_SPEED = 1050
local BULLET_LIFETIME = 2.1
local FIRE_INTERVAL = 0.24
local RESPAWN_SECONDS = 2.6
local MAX_PLAYERS = 12
local MAX_BULLETS = 32

local OFFSCREEN = -20000

-- ---------------------------------------------------------------------------
-- ОКНО
-- ---------------------------------------------------------------------------
local win = create_window("2D CS • MULTIPLAYER FFA v9 • JOIN FIX", START_W, START_H)
win:set_bg_color(7, 10, 14, 255)
win:set_title_color(12, 16, 22, 255)
win:set_title_text_color(230, 238, 245, 255)
win:set_border_color(43, 55, 69, 255)
win:set_border_size(1)

local view_w = START_W
local view_h = START_H
local ui_scale = 1

-- ---------------------------------------------------------------------------
-- ЦВЕТА
-- ---------------------------------------------------------------------------
local C = {
    floor = {15, 20, 26, 255},
    floor_alt = {19, 25, 32, 255},
    grid = {31, 41, 52, 115},
    grid_major = {44, 57, 70, 145},

    wall_shadow = {0, 0, 0, 125},
    wall = {63, 73, 85, 255},
    wall_top = {95, 107, 121, 255},
    wall_edge = {40, 47, 56, 255},
    crate = {111, 80, 48, 255},
    crate_top = {148, 108, 64, 255},
    crate_cross = {70, 48, 29, 220},

    zone_a = {196, 73, 68, 42},
    zone_b = {62, 131, 210, 42},
    zone_text_a = {255, 135, 126, 190},
    zone_text_b = {126, 191, 255, 190},

    local_player = {69, 230, 178, 255},
    local_outer = {27, 121, 99, 255},
    local_core = {220, 255, 244, 255},

    remote_player = {236, 114, 83, 255},
    remote_outer = {126, 49, 38, 255},
    remote_core = {255, 226, 215, 255},

    dead = {92, 101, 112, 190},
    shadow = {0, 0, 0, 135},

    bullet = {255, 229, 143, 255},
    impact = {255, 174, 67, 255},
    aim = {255, 205, 84, 215},
    aim_end = {255, 239, 171, 255},

    hud = {8, 12, 17, 225},
    hud_border = {48, 63, 78, 230},
    text = {229, 237, 244, 255},
    muted = {142, 158, 174, 255},
    green = {75, 224, 168, 255},
    yellow = {255, 196, 79, 255},
    red = {255, 104, 94, 255},
    blue = {91, 169, 255, 255},

    lobby_dim = {4, 6, 9, 225},
    lobby_panel = {14, 19, 26, 255},
    lobby_inner = {20, 27, 35, 255},
    lobby_row = {27, 35, 44, 255},
    lobby_row_host = {35, 69, 59, 255},

    joy_base = {31, 41, 52, 180},
    joy_inner = {55, 69, 84, 125},
    joy_ring = {105, 127, 149, 105},
    joy_knob = {101, 125, 147, 230},
    joy_move = {70, 226, 173, 245},
    joy_aim = {255, 190, 72, 245}
}

-- ---------------------------------------------------------------------------
-- БАЗОВЫЕ УТИЛИТЫ
-- ---------------------------------------------------------------------------
local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function length(x, y)
    return math.sqrt(x * x + y * y)
end

local function normalize(x, y)
    local len = length(x, y)
    if len < 0.00001 then
        return 0, 0, 0
    end
    return x / len, y / len, len
end

local function lerp(a, b, t)
    return a + (b - a) * t
end

local function set_color(element, color)
    element:set_color(color[1], color[2], color[3], color[4])
end

local function make_image(x, y, w, h, rounding, color)
    local image = win:add_raw_image(x, y, w, h)
    set_color(image, color)
    image:set_rounding(rounding or 0)
    return image
end

local function make_label(text, x, y, w, h, size, color, align, style)
    local label = win:add_label(text, x, y)
    label:set_size(w, h)
    label:set_font_size(size)
    label:set_color(color[1], color[2], color[3], color[4])
    label:set_align(align or "left")
    label:set_font_style(style or "normal")
    label:set_raycast(false)
    return label
end

local function hide_element(element)
    element:set_position(OFFSCREEN, OFFSCREEN)
end

function set_text_cached(element, cache, key, value)
    if cache[key] ~= value then
        cache[key] = value
        element:set_text(value)
    end
end

local function point_in_rect(px, py, rect)
    return px >= rect.x and px <= rect.x + rect.w and
           py >= rect.y and py <= rect.y + rect.h
end

local function circle_hits_rect(cx, cy, radius, rect)
    local nearest_x = clamp(cx, rect.x, rect.x + rect.w)
    local nearest_y = clamp(cy, rect.y, rect.y + rect.h)
    local dx = cx - nearest_x
    local dy = cy - nearest_y
    return dx * dx + dy * dy < radius * radius
end

local function split(text, separator)
    local result = {}
    if text == nil then
        return result
    end

    local start_index = 1
    while true do
        local found_start, found_end = string.find(text, separator, start_index, true)
        if found_start == nil then
            table.insert(result, string.sub(text, start_index))
            break
        end

        table.insert(result, string.sub(text, start_index, found_start - 1))
        start_index = found_end + 1
    end

    return result
end

local function join(parts, separator)
    local output = ""
    for i = 1, #parts do
        if i > 1 then
            output = output .. separator
        end
        output = output .. tostring(parts[i])
    end
    return output
end

local function bool_number(value)
    if value then
        return "1"
    end
    return "0"
end

local function number_bool(value)
    return value == "1"
end

local function format_number(value)
    return string.format("%.2f", value or 0)
end

local function short_id(id)
    local text = tostring(id or "unknown")
    local len = string.len(text)
    if len <= 10 then
        return text
    end
    return string.sub(text, len - 9)
end

local function channel_to_client(id)
    return ROOT_CHANNEL .. "_to_" .. tostring(id)
end

local function channel_from_client(id)
    return ROOT_CHANNEL .. "_from_" .. tostring(id)
end

-- ---------------------------------------------------------------------------
-- ЛОКАЛЬНАЯ ЛИЧНОСТЬ ИГРОКА
-- ---------------------------------------------------------------------------
local self_id = tostring(system_id())
local self_id_short = short_id(self_id)

local NICK_WORDS = {
    "Viper", "Raven", "Ghost", "Falcon", "Pixel", "Blaze",
    "Nova", "Frost", "Cobra", "Mantis", "Vector", "Raptor",
    "Echo", "Bolt", "Nitro", "Orbit", "Shadow", "Quartz"
}

local nick_word = NICK_WORDS[math.random(1, #NICK_WORDS)]
local nick_suffix_start = math.max(1, string.len(self_id_short) - 1)
local local_nick = nick_word .. tostring(math.random(10, 99)) .. string.upper(string.sub(self_id_short, nick_suffix_start))
local local_nonce = self_id_short .. "_" .. tostring(math.random(1000, 9999))

-- ---------------------------------------------------------------------------
-- СЕТЕВОЕ СОСТОЯНИЕ
-- ---------------------------------------------------------------------------
local role = "discovering"       -- discovering / host / client / rejected
local phase = "discovering"      -- discovering / lobby / match / rejected
local discovery_started_at = time()
local local_host_started_at = discovery_started_at

local host_id = nil
local host_nick = nil
local host_session = nil
local host_started_at = nil
local host_heartbeat = 0
local last_beacon_send_at = -100
local last_fresh_beacon_at = -100

local observed_beacons = {}

local join_counter = 0
local last_join_send_at = -100
local input_counter = 0
local last_input_send_at = -100
local last_host_packet_seq = -1
local last_host_packet_at = -100

-- Эти поля лежат в PERF, чтобы не превышать лимит Lua на количество локальных
-- переменных в главной функции большого скрипта.
PERF.joined_lobby = false
PERF.last_beacon_phase = "discovering"
PERF.rejected_join_counters = {}

local host_packet_seq = 0
local last_lobby_send_at = -100
local last_state_send_at = -100
local match_started_at = 0
local match_id = ""

local rejected_reason = ""

-- ---------------------------------------------------------------------------
-- КАРТА МИРА
-- ---------------------------------------------------------------------------
local wall_defs = {}
local walls = {}
local decorations = {}

local function add_wall(x, y, w, h, kind)
    table.insert(wall_defs, {
        x = x,
        y = y,
        w = w,
        h = h,
        kind = kind or "wall"
    })
end

-- Внешние границы
add_wall(0, 0, WORLD_W, 70, "wall")
add_wall(0, WORLD_H - 70, WORLD_W, 70, "wall")
add_wall(0, 0, 70, WORLD_H, "wall")
add_wall(WORLD_W - 70, 0, 70, WORLD_H, "wall")

-- Верхняя часть карты
add_wall(520, 70, 70, 420, "wall")
add_wall(920, 70, 70, 620, "wall")
add_wall(1390, 330, 420, 70, "wall")
add_wall(1780, 70, 70, 640, "wall")
add_wall(2250, 250, 500, 70, "wall")
add_wall(2700, 70, 70, 490, "wall")
add_wall(3150, 70, 70, 510, "wall")
add_wall(70, 570, 480, 70, "wall")
add_wall(760, 760, 620, 70, "wall")
add_wall(2020, 690, 590, 70, "wall")
add_wall(2920, 660, 610, 70, "wall")

-- Центральные коридоры
add_wall(360, 930, 650, 70, "wall")
add_wall(1070, 700, 70, 520, "wall")
add_wall(1330, 930, 640, 70, "wall")
add_wall(1770, 760, 70, 470, "wall")
add_wall(2090, 980, 610, 70, "wall")
add_wall(2660, 790, 70, 520, "wall")
add_wall(2960, 1040, 570, 70, "wall")
add_wall(70, 1260, 510, 70, "wall")
add_wall(810, 1230, 700, 70, "wall")
add_wall(1660, 1260, 640, 70, "wall")
add_wall(2490, 1320, 660, 70, "wall")

-- Нижняя часть карты
add_wall(430, 1450, 70, 500, "wall")
add_wall(880, 1390, 70, 550, "wall")
add_wall(1270, 1560, 520, 70, "wall")
add_wall(1800, 1390, 70, 730, "wall")
add_wall(2190, 1510, 570, 70, "wall")
add_wall(2700, 1450, 70, 550, "wall")
add_wall(3160, 1500, 70, 500, "wall")
add_wall(70, 1990, 600, 70, "wall")
add_wall(780, 2110, 690, 70, "wall")
add_wall(1970, 2100, 650, 70, "wall")
add_wall(2870, 2050, 660, 70, "wall")

-- Небольшие укрытия и ящики
add_wall(260, 290, 120, 120, "crate")
add_wall(680, 250, 130, 130, "crate")
add_wall(1170, 180, 120, 120, "crate")
add_wall(2050, 170, 145, 145, "crate")
add_wall(2910, 310, 130, 130, "crate")
add_wall(3310, 260, 120, 120, "crate")

add_wall(170, 780, 140, 140, "crate")
add_wall(610, 1040, 130, 130, "crate")
add_wall(1210, 1120, 115, 115, "crate")
add_wall(1910, 830, 130, 130, "crate")
add_wall(2340, 1120, 145, 145, "crate")
add_wall(2810, 920, 125, 125, "crate")
add_wall(3290, 1220, 135, 135, "crate")

add_wall(220, 1590, 130, 130, "crate")
add_wall(610, 1730, 145, 145, "crate")
add_wall(1060, 1450, 120, 120, "crate")
add_wall(1480, 1800, 140, 140, "crate")
add_wall(2040, 1710, 125, 125, "crate")
add_wall(2450, 1880, 140, 140, "crate")
add_wall(2890, 1650, 120, 120, "crate")
add_wall(3340, 1810, 130, 130, "crate")

local spawn_points = {
    {x = 210,  y = 190},
    {x = 1160, y = 520},
    {x = 2240, y = 150},
    {x = 3370, y = 170},

    {x = 220,  y = 1110},
    {x = 1260, y = 1070},
    {x = 2360, y = 870},
    {x = 3380, y = 900},

    {x = 220,  y = 2200},
    {x = 1120, y = 2250},
    {x = 2290, y = 2260},
    {x = 3380, y = 2210}
}

-- Пространственный индекс стен: коллизия проверяет только соседние ячейки,
-- а не все объекты карты для каждого игрока, луча и шага пули.

function wall_cell_key(cx, cy)
    return tostring(cx) .. ":" .. tostring(cy)
end

for wall_index = 1, #wall_defs do
    local wall = wall_defs[wall_index]
    local min_cx = math.floor(wall.x / PERF.collision_cell)
    local max_cx = math.floor((wall.x + wall.w) / PERF.collision_cell)
    local min_cy = math.floor(wall.y / PERF.collision_cell)
    local max_cy = math.floor((wall.y + wall.h) / PERF.collision_cell)

    for cy = min_cy, max_cy do
        for cx = min_cx, max_cx do
            local key = wall_cell_key(cx, cy)
            local cell = PERF.wall_cells[key]
            if cell == nil then
                cell = {}
                PERF.wall_cells[key] = cell
            end
            table.insert(cell, wall_index)
        end
    end
end

local function collides_world(x, y, radius)
    if x - radius < 70 or y - radius < 70 or
       x + radius > WORLD_W - 70 or y + radius > WORLD_H - 70 then
        return true
    end

    local min_cx = math.floor((x - radius) / PERF.collision_cell)
    local max_cx = math.floor((x + radius) / PERF.collision_cell)
    local min_cy = math.floor((y - radius) / PERF.collision_cell)
    local max_cy = math.floor((y + radius) / PERF.collision_cell)

    for cy = min_cy, max_cy do
        for cx = min_cx, max_cx do
            local cell = PERF.wall_cells[wall_cell_key(cx, cy)]
            if cell ~= nil then
                for i = 1, #cell do
                    if circle_hits_rect(x, y, radius, wall_defs[cell[i]]) then
                        return true
                    end
                end
            end
        end
    end

    return false
end

local function move_with_collision(player, dx, dy)
    local next_x = player.x + dx
    if not collides_world(next_x, player.y, PLAYER_RADIUS) then
        player.x = next_x
    end

    local next_y = player.y + dy
    if not collides_world(player.x, next_y, PLAYER_RADIUS) then
        player.y = next_y
    end
end

-- Лёгкое клиентское предсказание. Оно двигает только визуальную позицию
-- собственного игрока и НЕ создаёт очередей команд, replay, ACK-пакетов
-- или дополнительных таймеров. Авторитетные x/y по-прежнему приходят от хоста.
local function move_render_with_collision(player, dx, dy)
    local render_x = player.render_x or player.x
    local render_y = player.render_y or player.y

    local next_x = render_x + dx
    if not collides_world(next_x, render_y, PLAYER_RADIUS) then
        render_x = next_x
    end

    local next_y = render_y + dy
    if not collides_world(render_x, next_y, PLAYER_RADIUS) then
        render_y = next_y
    end

    player.render_x = render_x
    player.render_y = render_y
end

local function ray_distance_to_wall(start_x, start_y, dir_x, dir_y, maximum)
    local distance = 24
    local step = 12

    while distance <= maximum do
        local x = start_x + dir_x * distance
        local y = start_y + dir_y * distance

        if collides_world(x, y, 2) then
            return math.max(20, distance - step)
        end

        distance = distance + step
    end

    return maximum
end

-- ---------------------------------------------------------------------------
-- ФОНОВАЯ СЦЕНА И КАРТА
-- ---------------------------------------------------------------------------
local floor = make_image(0, 0, view_w, view_h, 0, C.floor)
local floor_alt = make_image(0, 0, view_w, view_h, 0, C.floor_alt)
floor_alt:set_opacity(0.30)

local vertical_grid = {}
local horizontal_grid = {}

for i = 1, 28 do
    local color = C.grid
    if i % 5 == 0 then
        color = C.grid_major
    end
    table.insert(vertical_grid, make_image(0, 0, 1, view_h, 0, color))
end

for i = 1, 18 do
    local color = C.grid
    if i % 5 == 0 then
        color = C.grid_major
    end
    table.insert(horizontal_grid, make_image(0, 0, view_w, 1, 0, color))
end

local zone_a = make_image(0, 0, 270, 230, 24, C.zone_a)
local zone_b = make_image(0, 0, 270, 230, 24, C.zone_b)
local zone_a_label = make_label("A", 0, 0, 270, 230, 70, C.zone_text_a, "center", "bold")
local zone_b_label = make_label("B", 0, 0, 270, 230, 70, C.zone_text_b, "center", "bold")

for i = 1, #wall_defs do
    local def = wall_defs[i]
    local body_color = C.wall
    local top_color = C.wall_top

    if def.kind == "crate" then
        body_color = C.crate
        top_color = C.crate_top
    end

    local object = {
        def = def,
        shadow = make_image(0, 0, def.w, def.h, 7, C.wall_shadow),
        body = make_image(0, 0, def.w, def.h, 7, body_color),
        top = make_image(0, 0, def.w, 8, 7, top_color),
        edge = make_image(0, 0, 4, def.h, 2, C.wall_edge),
        cross_h = nil,
        cross_v = nil
    }

    if def.kind == "crate" then
        object.cross_h = make_image(0, 0, def.w - 20, 6, 3, C.crate_cross)
        object.cross_v = make_image(0, 0, 6, def.h - 20, 3, C.crate_cross)
    end

    table.insert(walls, object)
end

-- ---------------------------------------------------------------------------
-- ИГРОКИ, ПУЛИ И СОСТОЯНИЕ МАТЧА
-- ---------------------------------------------------------------------------
local host_players = {}
local host_order = {}
local client_players = {}
local bullets = {}
local next_bullet_id = 1

local local_input = {
    move_x = 0,
    move_y = 0,
    aim_x = 1,
    aim_y = 0,
    fire = false
}

local function new_player(id, nick)
    return {
        id = tostring(id),
        nick = tostring(nick),
        x = spawn_points[1].x,
        y = spawn_points[1].y,
        render_x = spawn_points[1].x,
        render_y = spawn_points[1].y,
        aim_x = 1,
        aim_y = 0,
        move_x = 0,
        move_y = 0,
        fire = false,
        alive = true,
        score = 0,
        deaths = 0,
        respawn_at = 0,
        next_shot_at = 0,
        connected = true,
        last_seen = time(),
        last_input_seq = -1,
        last_join_counter = -1,
        spawn_index = 1
    }
end

local function host_add_player(id, nick)
    id = tostring(id)

    if host_players[id] ~= nil then
        host_players[id].nick = tostring(nick)
        host_players[id].connected = true
        return host_players[id]
    end

    if #host_order >= MAX_PLAYERS then
        return nil
    end

    local player = new_player(id, nick)
    host_players[id] = player
    table.insert(host_order, id)
    return player
end

local function remove_host_player(id)
    host_players[id] = nil
    for i = #host_order, 1, -1 do
        if host_order[i] == id then
            table.remove(host_order, i)
            break
        end
    end
end

local function choose_respawn(player)
    local best_spawn = spawn_points[1]
    local best_distance = -1

    for i = 1, #spawn_points do
        local spawn = spawn_points[i]
        local nearest = 999999

        for j = 1, #host_order do
            local other = host_players[host_order[j]]
            if other ~= nil and other.alive and other.id ~= player.id then
                local dx = spawn.x - other.x
                local dy = spawn.y - other.y
                local d = dx * dx + dy * dy
                if d < nearest then
                    nearest = d
                end
            end
        end

        if nearest > best_distance and not collides_world(spawn.x, spawn.y, PLAYER_RADIUS) then
            best_distance = nearest
            best_spawn = spawn
            player.spawn_index = i
        end
    end

    player.x = best_spawn.x
    player.y = best_spawn.y
    player.render_x = best_spawn.x
    player.render_y = best_spawn.y
    player.alive = true
    player.respawn_at = 0
    player.aim_x = 1
    player.aim_y = 0
end

local function start_match()
    if role ~= "host" or phase ~= "lobby" then
        return
    end

    phase = "match"
    match_started_at = time()
    match_id = self_id_short .. "_" .. tostring(math.floor(match_started_at * 100))
    bullets = {}
    next_bullet_id = 1
    PERF.rejected_join_counters = {}

    -- Не ждём старых интервалов: первый MATCH beacon и STATE уходят сразу.
    last_beacon_send_at = -100
    last_state_send_at = -100

    local active_index = 1
    for i = #host_order, 1, -1 do
        local id = host_order[i]
        local player = host_players[id]

        if player == nil then
            table.remove(host_order, i)
        elseif id ~= self_id and time() - player.last_seen > CLIENT_TIMEOUT then
            remove_host_player(id)
        end
    end

    for i = 1, #host_order do
        local player = host_players[host_order[i]]
        local spawn = spawn_points[((active_index - 1) % #spawn_points) + 1]
        active_index = active_index + 1

        player.x = spawn.x
        player.y = spawn.y
        player.render_x = spawn.x
        player.render_y = spawn.y
        player.aim_x = 1
        player.aim_y = 0
        player.move_x = 0
        player.move_y = 0
        player.fire = false
        player.alive = true
        player.score = 0
        player.deaths = 0
        player.respawn_at = 0
        player.next_shot_at = time() + 0.5
        player.connected = true
        player.spawn_index = ((active_index - 2) % #spawn_points) + 1
    end
end

local function spawn_bullet(owner)
    if #bullets >= MAX_BULLETS then
        return
    end

    local dir_x, dir_y, dir_len = normalize(owner.aim_x, owner.aim_y)
    if dir_len < 0.2 then
        return
    end

    local muzzle_distance = PLAYER_RADIUS + 10
    local bullet = {
        id = next_bullet_id,
        owner_id = owner.id,
        x = owner.x + dir_x * muzzle_distance,
        y = owner.y + dir_y * muzzle_distance,
        vx = dir_x * BULLET_SPEED,
        vy = dir_y * BULLET_SPEED,
        life = BULLET_LIFETIME
    }

    next_bullet_id = next_bullet_id + 1
    table.insert(bullets, bullet)
end

local function kill_player(victim, killer)
    if victim == nil or not victim.alive then
        return
    end

    victim.alive = false
    victim.deaths = victim.deaths + 1
    victim.respawn_at = time() + RESPAWN_SECONDS
    victim.move_x = 0
    victim.move_y = 0
    victim.fire = false

    if killer ~= nil and killer.id ~= victim.id then
        killer.score = killer.score + 1
    end
end

local function bullet_hits_player(bullet, player)
    local dx = bullet.x - player.x
    local dy = bullet.y - player.y
    local radius = PLAYER_RADIUS + 5
    return dx * dx + dy * dy <= radius * radius
end

local function host_update_bullets(dt)
    for i = #bullets, 1, -1 do
        local bullet = bullets[i]
        local remove = false
        local total_dx = bullet.vx * dt
        local total_dy = bullet.vy * dt
        local travel = length(total_dx, total_dy)
        local steps = math.max(1, math.ceil(travel / 9))
        local step_dx = total_dx / steps
        local step_dy = total_dy / steps

        for step_index = 1, steps do
            bullet.x = bullet.x + step_dx
            bullet.y = bullet.y + step_dy

            if collides_world(bullet.x, bullet.y, 3) then
                remove = true
                break
            end

            for p = 1, #host_order do
                local player = host_players[host_order[p]]
                if player ~= nil and player.alive and player.id ~= bullet.owner_id then
                    if bullet_hits_player(bullet, player) then
                        kill_player(player, host_players[bullet.owner_id])
                        remove = true
                        break
                    end
                end
            end

            if remove then
                break
            end
        end

        bullet.life = bullet.life - dt
        if bullet.life <= 0 then
            remove = true
        end

        if remove then
            table.remove(bullets, i)
        end
    end
end

local function host_update_players(dt)
    local now = time()

    for i = 1, #host_order do
        local player = host_players[host_order[i]]

        if player ~= nil then
            if player.id ~= self_id and now - player.last_seen > CLIENT_TIMEOUT then
                player.connected = false
                player.alive = false
            end

            if not player.alive then
                if player.connected and player.respawn_at > 0 and now >= player.respawn_at then
                    choose_respawn(player)
                end
            else
                local move_x, move_y, move_len = normalize(player.move_x, player.move_y)
                local move_amount = math.min(1, move_len)
                move_with_collision(
                    player,
                    move_x * PLAYER_SPEED * move_amount * dt,
                    move_y * PLAYER_SPEED * move_amount * dt
                )

                local aim_x, aim_y, aim_len = normalize(player.aim_x, player.aim_y)
                if aim_len > 0.05 then
                    player.aim_x = aim_x
                    player.aim_y = aim_y
                end

                if player.fire and now >= player.next_shot_at then
                    spawn_bullet(player)
                    player.next_shot_at = now + FIRE_INTERVAL
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- ВИЗУАЛЬНЫЕ ОБЪЕКТЫ ИГРОКОВ И ПУЛЬ
-- ---------------------------------------------------------------------------
local player_visuals = {}
local bullet_visuals = {}
local aim_dots = {}

local function create_player_visual(id)
    local is_local = id == self_id
    local body_color = C.remote_player
    local outer_color = C.remote_outer
    local core_color = C.remote_core

    if is_local then
        body_color = C.local_player
        outer_color = C.local_outer
        core_color = C.local_core
    end

    local visual = {
        id = id,
        shadow = make_image(0, 0, 48, 48, 24, C.shadow),
        outer = make_image(0, 0, 44, 44, 22, outer_color),
        body = make_image(0, 0, 34, 34, 17, body_color),
        core = make_image(0, 0, 10, 10, 5, core_color),
        gun = make_image(0, 0, 10, 10, 5, C.aim_end),
        name = make_label("", 0, 0, 170, 24, 13, C.text, "center", "bold"),
        status = make_label("", 0, 0, 170, 18, 10, C.muted, "center", "normal"),
        cache = {},
        scale_key = nil,
        state_key = nil,
        hidden = false
    }

    player_visuals[id] = visual
    return visual
end

local function hide_player_visual(visual)
    if visual.hidden then
        return
    end
    visual.hidden = true
    hide_element(visual.shadow)
    hide_element(visual.outer)
    hide_element(visual.body)
    hide_element(visual.core)
    hide_element(visual.gun)
    hide_element(visual.name)
    hide_element(visual.status)
end

for i = 1, MAX_BULLETS do
    local bullet = make_image(OFFSCREEN, OFFSCREEN, 8, 8, 4, C.bullet)
    table.insert(bullet_visuals, bullet)
end

for i = 1, 18 do
    local dot = make_image(OFFSCREEN, OFFSCREEN, 5, 5, 3, C.aim)
    table.insert(aim_dots, dot)
end

local aim_end = make_image(OFFSCREEN, OFFSCREEN, 12, 12, 6, C.aim_end)

-- ---------------------------------------------------------------------------
-- HUD
-- ---------------------------------------------------------------------------
local hud_panel = make_image(18, 18, 420, 88, 14, C.hud)
local hud_border = make_image(18, 104, 420, 2, 1, C.hud_border)
local hud_title = make_label("CS 2D • FFA", 34, 27, 385, 26, 18, C.text, "left", "bold")
local hud_status = make_label("Поиск хоста...", 34, 56, 385, 22, 12, C.muted, "left", "normal")
local hud_stats = make_label("K 0  •  D 0", 34, 79, 385, 20, 12, C.green, "left", "bold")

local scoreboard_panel = make_image(0, 0, 340, 315, 14, C.hud)
local scoreboard_title = make_label("ТАБЛИЦА FFA", 0, 0, 308, 26, 15, C.text, "left", "bold")
local scoreboard_rows = {}

for i = 1, MAX_PLAYERS do
    local row = make_label("", 0, 0, 310, 21, 11, C.muted, "left", "normal")
    table.insert(scoreboard_rows, row)
end

local respawn_label = make_label("", 0, 0, 500, 60, 28, C.yellow, "center", "bold")
local network_label = make_label("", 0, 0, 500, 24, 11, C.muted, "center", "normal")

-- ---------------------------------------------------------------------------
-- ДЖОЙСТИКИ
-- ---------------------------------------------------------------------------
local move_joy = {
    cx = 140,
    cy = 580,
    radius = 78,
    knob_radius = 29,
    dx = 0,
    dy = 0,
    active = false,
    base = nil,
    inner = nil,
    ring = nil,
    knob = nil,
    label = nil,
    active_color = C.joy_move
}

local aim_joy = {
    cx = 1140,
    cy = 580,
    radius = 78,
    knob_radius = 29,
    dx = 0,
    dy = 0,
    active = false,
    base = nil,
    inner = nil,
    ring = nil,
    knob = nil,
    label = nil,
    active_color = C.joy_aim
}

local function create_joystick(joy, caption)
    joy.base = make_image(0, 0, 150, 150, 75, C.joy_base)
    joy.inner = make_image(0, 0, 120, 120, 60, C.joy_inner)
    joy.ring = make_image(0, 0, 92, 92, 46, C.joy_ring)
    joy.knob = make_image(0, 0, 58, 58, 29, C.joy_knob)
    joy.label = make_label(caption, 0, 0, 170, 24, 12, C.muted, "center", "bold")
end

create_joystick(move_joy, "ДВИЖЕНИЕ")
create_joystick(aim_joy, "ПРИЦЕЛ + ОГОНЬ")

local function update_joystick_visual(joy)
    local r = joy.radius
    local inner_r = r * 0.77
    local ring_r = r * 0.58
    local knob_x = joy.cx + joy.dx * r
    local knob_y = joy.cy + joy.dy * r

    joy.base:set_position(joy.cx - r, joy.cy - r)
    joy.base:set_size(r * 2, r * 2)
    joy.base:set_rounding(r)

    joy.inner:set_position(joy.cx - inner_r, joy.cy - inner_r)
    joy.inner:set_size(inner_r * 2, inner_r * 2)
    joy.inner:set_rounding(inner_r)

    joy.ring:set_position(joy.cx - ring_r, joy.cy - ring_r)
    joy.ring:set_size(ring_r * 2, ring_r * 2)
    joy.ring:set_rounding(ring_r)

    joy.knob:set_position(knob_x - joy.knob_radius, knob_y - joy.knob_radius)
    joy.knob:set_size(joy.knob_radius * 2, joy.knob_radius * 2)
    joy.knob:set_rounding(joy.knob_radius)

    if joy.active then
        set_color(joy.knob, joy.active_color)
        joy.base:set_opacity(1)
    else
        set_color(joy.knob, C.joy_knob)
        joy.base:set_opacity(0.82)
    end

    joy.label:set_position(joy.cx - r, joy.cy - r - 30 * ui_scale)
    joy.label:set_size(r * 2, 22 * ui_scale)
    joy.label:set_font_size(math.max(10, math.floor(12 * ui_scale)))
end

local function set_joystick_from_point(joy, x, y)
    local dx = x - joy.cx
    local dy = y - joy.cy
    local nx, ny, distance = normalize(dx, dy)

    if distance > joy.radius then
        dx = nx * joy.radius
        dy = ny * joy.radius
    end

    joy.dx = dx / joy.radius
    joy.dy = dy / joy.radius
    joy.active = true
    update_joystick_visual(joy)
end

local function release_joystick(joy)
    joy.dx = 0
    joy.dy = 0
    joy.active = false
    update_joystick_visual(joy)
end

local function joystick_accepts(joy, x, y)
    return length(x - joy.cx, y - joy.cy) <= joy.radius * 1.75
end

-- ---------------------------------------------------------------------------
-- ЛОББИ
-- ---------------------------------------------------------------------------
local lobby_dim = make_image(0, 0, view_w, view_h, 0, C.lobby_dim)
local lobby_panel = make_image(0, 0, 760, 580, 22, C.lobby_panel)
local lobby_header = make_label("2D CS • MULTIPLAYER FFA", 0, 0, 700, 42, 26, C.text, "center", "bold")
local lobby_role = make_label("Поиск активного хоста...", 0, 0, 700, 32, 16, C.yellow, "center", "bold")
local lobby_info = make_label("Первый запущенный ПК станет хостом", 0, 0, 700, 28, 12, C.muted, "center", "normal")
local lobby_players_panel = make_image(0, 0, 680, 330, 15, C.lobby_inner)
local lobby_players_title = make_label("ИГРОКИ В ЛОББИ", 0, 0, 640, 28, 14, C.text, "left", "bold")
local lobby_rows_bg = {}
local lobby_rows_text = {}

for i = 1, MAX_PLAYERS do
    local bg = make_image(0, 0, 640, 24, 7, C.lobby_row)
    local text = make_label("", 0, 0, 620, 24, 11, C.muted, "left", "normal")
    table.insert(lobby_rows_bg, bg)
    table.insert(lobby_rows_text, text)
end

local start_button = win:add_button("START FFA", 0, 0, 260, 54, function()
    start_match()
end)
start_button:set_font_size(18)
start_button:set_text_color(235, 255, 247, 255)
start_button:set_color(42, 164, 119, 255)
start_button:set_rounding(14)
start_button:set_transition(false)
start_button:on_press(function()
    start_button:set_color(31, 126, 91, 255)
end)
start_button:on_release(function()
    start_button:set_color(42, 164, 119, 255)
    start_button:force_normal_state()
end)

local lobby_footer = make_label("Хост запускает матч вручную. После старта новые игроки не входят.", 0, 0, 700, 26, 11, C.muted, "center", "normal")

local reject_dim = make_image(OFFSCREEN, OFFSCREEN, view_w, view_h, 0, C.lobby_dim)
local reject_panel = make_image(OFFSCREEN, OFFSCREEN, 610, 250, 20, C.lobby_panel)
local reject_title = make_label("КАТКА УЖЕ ИДЁТ", OFFSCREEN, OFFSCREEN, 560, 50, 28, C.red, "center", "bold")
local reject_text = make_label("", OFFSCREEN, OFFSCREEN, 550, 80, 14, C.text, "center", "normal")

local function show_game_ui(show)
    if show then
        -- Позиции задаются layout-функцией.
        update_joystick_visual(move_joy)
        update_joystick_visual(aim_joy)
    else
        hide_element(move_joy.base)
        hide_element(move_joy.inner)
        hide_element(move_joy.ring)
        hide_element(move_joy.knob)
        hide_element(move_joy.label)
        hide_element(aim_joy.base)
        hide_element(aim_joy.inner)
        hide_element(aim_joy.ring)
        hide_element(aim_joy.knob)
        hide_element(aim_joy.label)
    end
end

local function hide_lobby()
    hide_element(lobby_dim)
    hide_element(lobby_panel)
    hide_element(lobby_header)
    hide_element(lobby_role)
    hide_element(lobby_info)
    hide_element(lobby_players_panel)
    hide_element(lobby_players_title)
    hide_element(lobby_footer)
    hide_element(start_button)

    for i = 1, MAX_PLAYERS do
        hide_element(lobby_rows_bg[i])
        hide_element(lobby_rows_text[i])
    end
end

local function show_rejected(reason)
    phase = "rejected"
    role = "rejected"
    rejected_reason = reason or "Катка уже идёт"
    hide_lobby()
    show_game_ui(false)
end

-- ---------------------------------------------------------------------------
-- КАМЕРА И ПРЕОБРАЗОВАНИЕ КООРДИНАТ
-- ---------------------------------------------------------------------------
local camera_x = WORLD_W * 0.5
local camera_y = WORLD_H * 0.5

local function world_to_screen(world_x, world_y)
    return world_x - camera_x + view_w * 0.5,
           world_y - camera_y + view_h * 0.5
end

local function get_current_players()
    if role == "host" then
        return host_players
    end
    return client_players
end

local function get_local_player()
    local players = get_current_players()
    return players[self_id]
end

local function update_camera()
    local local_player = get_local_player()
    if local_player ~= nil then
        local target_x = local_player.render_x or local_player.x
        local target_y = local_player.render_y or local_player.y

        camera_x = lerp(camera_x, target_x, 0.18)
        camera_y = lerp(camera_y, target_y, 0.18)
    end

    local half_w = view_w * 0.5
    local half_h = view_h * 0.5

    if view_w >= WORLD_W then
        camera_x = WORLD_W * 0.5
    else
        camera_x = clamp(camera_x, half_w, WORLD_W - half_w)
    end

    if view_h >= WORLD_H then
        camera_y = WORLD_H * 0.5
    else
        camera_y = clamp(camera_y, half_h, WORLD_H - half_h)
    end
end

local function update_grid()
    local spacing = 120
    local start_world_x = math.floor((camera_x - view_w * 0.5) / spacing) * spacing
    local start_world_y = math.floor((camera_y - view_h * 0.5) / spacing) * spacing

    for i = 1, #vertical_grid do
        local world_x = start_world_x + (i - 1) * spacing
        local screen_x = world_x - camera_x + view_w * 0.5
        vertical_grid[i]:set_position(screen_x, 0)
    end

    for i = 1, #horizontal_grid do
        local world_y = start_world_y + (i - 1) * spacing
        local screen_y = world_y - camera_y + view_h * 0.5
        horizontal_grid[i]:set_position(0, screen_y)
    end
end

local function update_world_visuals()
    local zone_ax, zone_ay = world_to_screen(2920, 150)
    local zone_bx, zone_by = world_to_screen(180, 1980)
    zone_a:set_position(zone_ax, zone_ay)
    zone_b:set_position(zone_bx, zone_by)
    zone_a_label:set_position(zone_ax, zone_ay)
    zone_b_label:set_position(zone_bx, zone_by)

    for i = 1, #walls do
        local object = walls[i]
        local def = object.def
        local screen_x, screen_y = world_to_screen(def.x, def.y)
        local visible = screen_x + def.w >= -80 and screen_y + def.h >= -80 and
                        screen_x <= view_w + 80 and screen_y <= view_h + 80

        if visible then
            object.visible = true
            object.shadow:set_position(screen_x + 6, screen_y + 7)
            object.body:set_position(screen_x, screen_y)
            object.top:set_position(screen_x, screen_y)
            object.edge:set_position(screen_x, screen_y)

            if object.cross_h ~= nil then
                object.cross_h:set_position(screen_x + 12, screen_y + def.h * 0.5 - 3)
                object.cross_v:set_position(screen_x + def.w * 0.5 - 3, screen_y + 12)
            end
        elseif object.visible ~= false then
            object.visible = false
            hide_element(object.shadow)
            hide_element(object.body)
            hide_element(object.top)
            hide_element(object.edge)
            if object.cross_h ~= nil then
                hide_element(object.cross_h)
                hide_element(object.cross_v)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- СЕРИАЛИЗАЦИЯ ЛОББИ И МАТЧА
-- ---------------------------------------------------------------------------
local function serialize_lobby_players()
    local records = {}

    for i = 1, #host_order do
        local id = host_order[i]
        local player = host_players[id]
        if player ~= nil then
            table.insert(records, join({
                player.id,
                player.nick,
                bool_number(player.id == host_id),
                bool_number(player.connected)
            }, ","))
        end
    end

    return join(records, ";")
end

local function serialize_match_players()
    local records = {}
    local now = time()

    for i = 1, #host_order do
        local player = host_players[host_order[i]]
        if player ~= nil then
            local respawn_remaining = 0
            if not player.alive and player.respawn_at > 0 then
                respawn_remaining = math.max(0, player.respawn_at - now)
            end

            table.insert(records, join({
                player.id,
                player.nick,
                format_number(player.x),
                format_number(player.y),
                format_number(player.aim_x),
                format_number(player.aim_y),
                bool_number(player.alive),
                tostring(player.score),
                tostring(player.deaths),
                format_number(respawn_remaining),
                bool_number(player.connected)
            }, ","))
        end
    end

    return join(records, ";")
end

local function serialize_bullets()
    local records = {}

    for i = 1, #bullets do
        local bullet = bullets[i]
        table.insert(records, join({
            tostring(bullet.id),
            format_number(bullet.x),
            format_number(bullet.y),
            bullet.owner_id
        }, ","))
    end

    return join(records, ";")
end

local function parse_lobby_players(encoded)
    local parsed = {}
    local order = {}

    if encoded == nil or encoded == "" then
        return parsed, order
    end

    local records = split(encoded, ";")
    for i = 1, #records do
        local fields = split(records[i], ",")
        if #fields >= 4 then
            local player = {
                id = fields[1],
                nick = fields[2],
                is_host = number_bool(fields[3]),
                connected = number_bool(fields[4])
            }
            parsed[player.id] = player
            table.insert(order, player.id)
        end
    end

    return parsed, order
end

local function parse_match_players(encoded)
    local seen = {}

    if encoded == nil or encoded == "" then
        return seen
    end

    local records = split(encoded, ";")
    for i = 1, #records do
        local fields = split(records[i], ",")
        if #fields >= 11 then
            local id = fields[1]
            local player = client_players[id]

            if player == nil then
                player = new_player(id, fields[2])
                client_players[id] = player
            end

            player.nick = fields[2]
            player.x = tonumber(fields[3]) or player.x
            player.y = tonumber(fields[4]) or player.y
            player.aim_x = tonumber(fields[5]) or player.aim_x
            player.aim_y = tonumber(fields[6]) or player.aim_y
            player.alive = number_bool(fields[7])
            player.score = tonumber(fields[8]) or 0
            player.deaths = tonumber(fields[9]) or 0
            player.respawn_remaining = tonumber(fields[10]) or 0
            player.connected = number_bool(fields[11])

            if player.render_x == nil then
                player.render_x = player.x
                player.render_y = player.y
            end

            seen[id] = true
        end
    end

    for id, player in pairs(client_players) do
        if not seen[id] then
            player.connected = false
            player.alive = false
        end
    end

    return seen
end

local function parse_bullets(encoded)
    local result = {}

    if encoded == nil or encoded == "" then
        return result
    end

    local records = split(encoded, ";")
    for i = 1, #records do
        local fields = split(records[i], ",")
        if #fields >= 4 then
            table.insert(result, {
                id = tonumber(fields[1]) or 0,
                x = tonumber(fields[2]) or 0,
                y = tonumber(fields[3]) or 0,
                owner_id = fields[4]
            })
        end
    end

    return result
end

-- ---------------------------------------------------------------------------
-- СЕТЕВЫЕ ПАКЕТЫ
-- ---------------------------------------------------------------------------
local function send_host_beacon()
    if role ~= "host" then
        return
    end

    local now = time()
    if now - last_beacon_send_at < HOST_BEACON_INTERVAL then
        return
    end

    last_beacon_send_at = now
    host_heartbeat = host_heartbeat + 1

    local packet = join({
        "H",
        PROTOCOL_VERSION,
        host_session,
        host_id,
        host_nick,
        phase,
        format_number(host_started_at),
        tostring(host_heartbeat)
    }, "|")

    localhost_send(HOST_BEACON_CHANNEL, packet)
end

local function send_join()
    if role ~= "client" or phase ~= "lobby" or host_session == nil then
        return
    end

    -- Уже принятый в лобби клиент после MATCH-маяка не должен продолжать
    -- повторять JOIN. Иначе последнее JOIN-сообщение остаётся в общем канале.
    if PERF.joined_lobby and PERF.last_beacon_phase == "match" then
        return
    end

    local now = time()
    if now - last_join_send_at < JOIN_INTERVAL then
        return
    end

    last_join_send_at = now
    join_counter = join_counter + 1

    localhost_send(JOIN_CHANNEL, join({
        "J",
        PROTOCOL_VERSION,
        host_session,
        self_id,
        local_nick,
        local_nonce,
        tostring(join_counter)
    }, "|"))
end

local function send_input()
    if role ~= "client" or phase ~= "match" or host_session == nil then
        return
    end

    local now = time()
    if now - last_input_send_at < INPUT_SEND_INTERVAL then
        return
    end

    last_input_send_at = now
    input_counter = input_counter + 1

    localhost_send(channel_from_client(self_id), join({
        "I",
        PROTOCOL_VERSION,
        host_session,
        self_id,
        tostring(input_counter),
        format_number(local_input.move_x),
        format_number(local_input.move_y),
        format_number(local_input.aim_x),
        format_number(local_input.aim_y),
        bool_number(local_input.fire),
        local_nick
    }, "|"))
end

local function send_lobby_to_clients()
    if role ~= "host" or phase ~= "lobby" then
        return
    end

    local now = time()
    if now - last_lobby_send_at < LOBBY_SEND_INTERVAL then
        return
    end

    last_lobby_send_at = now
    host_packet_seq = host_packet_seq + 1
    local encoded_players = serialize_lobby_players()

    for i = 1, #host_order do
        local id = host_order[i]
        if id ~= self_id then
            localhost_send(channel_to_client(id), join({
                "L",
                PROTOCOL_VERSION,
                host_session,
                tostring(host_packet_seq),
                host_id,
                host_nick,
                encoded_players
            }, "|"))
        end
    end
end

local function send_state_to_clients()
    if role ~= "host" or phase ~= "match" then
        return
    end

    local now = time()
    if now - last_state_send_at < STATE_SEND_INTERVAL then
        return
    end

    last_state_send_at = now
    host_packet_seq = host_packet_seq + 1

    local encoded_players = serialize_match_players()
    local encoded_bullets = serialize_bullets()

    for i = 1, #host_order do
        local id = host_order[i]
        local player = host_players[id]
        if id ~= self_id and player ~= nil and player.connected then
            localhost_send(channel_to_client(id), join({
                "S",
                PROTOCOL_VERSION,
                host_session,
                tostring(host_packet_seq),
                format_number(now),
                match_id,
                encoded_players,
                encoded_bullets
            }, "|"))
        end
    end
end

local function send_reject(client_id)
    host_packet_seq = host_packet_seq + 1
    localhost_send(channel_to_client(client_id), join({
        "R",
        PROTOCOL_VERSION,
        host_session,
        tostring(host_packet_seq),
        "RUNNING",
        host_nick or "Host"
    }, "|"))
end

-- ---------------------------------------------------------------------------
-- ВЫБОР ХОСТА И ОБРАБОТКА МАЯКА
-- ---------------------------------------------------------------------------
local function become_host()
    role = "host"
    phase = "lobby"
    host_id = self_id
    host_nick = local_nick
    host_started_at = local_host_started_at
    host_session = self_id_short .. "_" .. tostring(math.floor(time() * 100)) .. "_" .. tostring(math.random(100, 999))
    host_heartbeat = 0
    last_beacon_send_at = -100
    host_players = {}
    host_order = {}
    host_add_player(self_id, local_nick)
end

local function become_client(beacon)
    role = "client"
    phase = "lobby"
    host_session = beacon.session
    host_id = beacon.host_id
    host_nick = beacon.host_nick
    host_started_at = beacon.started_at
    last_fresh_beacon_at = time()
    last_host_packet_at = time()
    last_host_packet_seq = -1
    PERF.joined_lobby = false
    PERF.last_beacon_phase = beacon.phase or "lobby"
    join_counter = 0
    last_join_send_at = -100
end

local function parse_beacon(packet)
    local fields = split(packet, "|")
    if #fields < 8 then
        return nil
    end

    if fields[1] ~= "H" or fields[2] ~= PROTOCOL_VERSION then
        return nil
    end

    return {
        session = fields[3],
        host_id = fields[4],
        host_nick = fields[5],
        phase = fields[6],
        started_at = tonumber(fields[7]) or 999999,
        heartbeat = tonumber(fields[8]) or 0
    }
end

local function other_host_has_priority(beacon)
    if host_started_at == nil then
        return true
    end

    if beacon.started_at < host_started_at - 0.05 then
        return true
    end

    if math.abs(beacon.started_at - host_started_at) <= 0.05 then
        return tostring(beacon.host_id) < tostring(host_id)
    end

    return false
end

local function process_host_beacon()
    local packet = localhost_receive(HOST_BEACON_CHANNEL)
    if packet == nil or packet == "" then
        return
    end

    local beacon = parse_beacon(packet)
    if beacon == nil then
        return
    end

    -- Свой маяк хост не считает внешним.
    if role == "host" and beacon.session == host_session then
        return
    end

    local observed = observed_beacons[beacon.session]
    if observed == nil then
        observed = {
            heartbeat = beacon.heartbeat,
            changes = 1,
            last_change_at = time()
        }
        observed_beacons[beacon.session] = observed
    elseif observed.heartbeat ~= beacon.heartbeat then
        observed.heartbeat = beacon.heartbeat
        observed.changes = observed.changes + 1
        observed.last_change_at = time()
        last_fresh_beacon_at = time()
    end

    -- Требуем минимум два разных heartbeat от одной сессии. Таблица хранит
    -- наблюдения отдельно по session, поэтому даже два одновременно стартовавших
    -- хоста со временем увидят друг друга и оставят только приоритетного.
    if observed.changes < 2 then
        return
    end

    if role == "discovering" then
        become_client(beacon)
        if beacon.phase == "match" then
            -- Всё равно посылаем JOIN: живой хост ответит отдельным REJECT.
            phase = "lobby"
        end
        return
    end

    if role == "host" then
        if other_host_has_priority(beacon) then
            become_client(beacon)
        end
        return
    end

    if role == "client" and beacon.session == host_session then
        host_nick = beacon.host_nick
        host_started_at = beacon.started_at
        PERF.last_beacon_phase = beacon.phase
    end
end

-- ---------------------------------------------------------------------------
-- ХОСТ: JOIN И INPUT
-- ---------------------------------------------------------------------------
local function host_prune_lobby()
    if role ~= "host" or phase ~= "lobby" then
        return
    end

    local now = time()
    for i = #host_order, 1, -1 do
        local id = host_order[i]
        local player = host_players[id]

        if id ~= self_id and player ~= nil then
            if now - player.last_seen > CLIENT_TIMEOUT then
                remove_host_player(id)
            end
        end
    end
end

local function host_process_join()
    if role ~= "host" then
        return
    end

    local packet = localhost_receive(JOIN_CHANNEL)
    if packet == nil or packet == "" then
        return
    end

    local fields = split(packet, "|")
    if #fields < 7 or fields[1] ~= "J" or fields[2] ~= PROTOCOL_VERSION then
        return
    end

    if fields[3] ~= host_session then
        return
    end

    local client_id = fields[4]
    local client_nick = fields[5]
    local counter = tonumber(fields[7]) or 0

    if client_id == self_id then
        return
    end

    local player = host_players[client_id]

    if phase == "match" then
        if player ~= nil then
            -- Это уже участник текущего матча. После переключения LOBBY -> MATCH
            -- в JOIN_CHANNEL мог остаться его последний JOIN. Не отклоняем его и
            -- не пишем REJECT в тот же персональный канал, где идут STATE-пакеты.
            if counter > player.last_join_counter then
                player.last_join_counter = counter
                player.nick = client_nick
            end
            return
        end

        -- Реально новый ПК, включивший скрипт во время матча. Отклоняем только
        -- один раз для нового счётчика, потому что receive может вернуть тот же
        -- пакет снова на следующем сетевом тике.
        local rejected_counter = PERF.rejected_join_counters[client_id] or -1
        if counter > rejected_counter then
            PERF.rejected_join_counters[client_id] = counter
            send_reject(client_id)
        end
        return
    end

    if player == nil then
        player = host_add_player(client_id, client_nick)
        if player == nil then
            host_packet_seq = host_packet_seq + 1
            localhost_send(channel_to_client(client_id), join({
                "R", PROTOCOL_VERSION, host_session,
                tostring(host_packet_seq), "FULL", host_nick
            }, "|"))
            return
        end
    end

    if counter ~= player.last_join_counter then
        player.last_join_counter = counter
        player.last_seen = time()
        player.connected = true
        player.nick = client_nick
    end
end

local function host_process_inputs()
    if role ~= "host" or phase ~= "match" then
        return
    end

    for i = 1, #host_order do
        local id = host_order[i]
        local player = host_players[id]

        if player ~= nil and id ~= self_id then
            local packet = localhost_receive(channel_from_client(id))
            if packet ~= nil and packet ~= "" then
                local fields = split(packet, "|")

                if #fields >= 11 and
                   fields[1] == "I" and
                   fields[2] == PROTOCOL_VERSION and
                   fields[3] == host_session and
                   fields[4] == id then

                    local seq = tonumber(fields[5]) or -1
                    if seq > player.last_input_seq then
                        player.last_input_seq = seq
                        player.last_seen = time()
                        player.connected = true
                        player.move_x = clamp(tonumber(fields[6]) or 0, -1, 1)
                        player.move_y = clamp(tonumber(fields[7]) or 0, -1, 1)

                        local aim_x = tonumber(fields[8]) or player.aim_x
                        local aim_y = tonumber(fields[9]) or player.aim_y
                        local nx, ny, aim_len = normalize(aim_x, aim_y)
                        if aim_len > 0.05 then
                            player.aim_x = nx
                            player.aim_y = ny
                        end

                        player.fire = number_bool(fields[10])
                        player.nick = fields[11]
                    end
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- КЛИЕНТ: ПАКЕТЫ ОТ ХОСТА
-- ---------------------------------------------------------------------------
local lobby_snapshot_players = {}
local lobby_snapshot_order = {}

local function client_process_host_packet()
    if role ~= "client" then
        return
    end

    local packet = localhost_receive(channel_to_client(self_id))
    if packet == nil or packet == "" then
        return
    end

    local fields = split(packet, "|")
    if #fields < 4 or fields[2] ~= PROTOCOL_VERSION then
        return
    end

    if fields[3] ~= host_session then
        return
    end

    local seq = tonumber(fields[4]) or -1
    if seq <= last_host_packet_seq then
        return
    end

    last_host_packet_seq = seq
    last_host_packet_at = time()

    if fields[1] == "L" and #fields >= 7 then
        phase = "lobby"
        PERF.joined_lobby = true
        PERF.last_beacon_phase = "lobby"
        host_id = fields[5]
        host_nick = fields[6]
        lobby_snapshot_players, lobby_snapshot_order = parse_lobby_players(fields[7])
        return
    end

    if fields[1] == "S" and #fields >= 8 then
        phase = "match"
        PERF.joined_lobby = true
        PERF.last_beacon_phase = "match"
        match_id = fields[6]
        parse_match_players(fields[7])
        bullets = parse_bullets(fields[8])
        return
    end

    if fields[1] == "R" and #fields >= 6 then
        local reason_code = fields[5]

        -- Защита от уже отправленного до фикса/переключения старого REJECT:
        -- участник, который успел получить L/S текущей сессии, не считается
        -- поздним подключением.
        if reason_code == "RUNNING" and PERF.joined_lobby then
            return
        end
        local remote_host_nick = fields[6]

        if reason_code == "FULL" then
            show_rejected("Лобби заполнено. Хост: " .. remote_host_nick)
        else
            show_rejected("Матч у хоста " .. remote_host_nick .. " уже запущен.")
        end
    end
end

-- ---------------------------------------------------------------------------
-- ЛОББИ: СПИСОК ИГРОКОВ
-- ---------------------------------------------------------------------------
local function get_lobby_list()
    local list = {}

    if role == "host" then
        for i = 1, #host_order do
            local player = host_players[host_order[i]]
            if player ~= nil then
                table.insert(list, {
                    id = player.id,
                    nick = player.nick,
                    is_host = player.id == self_id,
                    connected = player.connected
                })
            end
        end
    elseif role == "client" then
        for i = 1, #lobby_snapshot_order do
            local player = lobby_snapshot_players[lobby_snapshot_order[i]]
            if player ~= nil then
                table.insert(list, player)
            end
        end

        -- Пока первый L-пакет ещё не пришёл, показываем себя.
        if #list == 0 then
            table.insert(list, {
                id = self_id,
                nick = local_nick,
                is_host = false,
                connected = true
            })
        end
    else
        table.insert(list, {
            id = self_id,
            nick = local_nick,
            is_host = false,
            connected = true
        })
    end

    return list
end

local function update_lobby_text()
    if phase ~= "lobby" and phase ~= "discovering" then
        return
    end

    if role == "host" then
        lobby_role:set_text("ТЫ ХОСТ")
        lobby_role:set_color(C.green[1], C.green[2], C.green[3], C.green[4])
        lobby_info:set_text("Ожидаем других игроков • твой ник: " .. local_nick)
        start_button:set_interactable(true)
    elseif role == "client" then
        lobby_role:set_text("ПОДКЛЮЧЕНО К ХОСТУ: " .. tostring(host_nick or "..."))
        lobby_role:set_color(C.blue[1], C.blue[2], C.blue[3], C.blue[4])
        lobby_info:set_text("Ожидаем, пока хост запустит матч • твой ник: " .. local_nick)
        start_button:set_interactable(false)
    else
        lobby_role:set_text("ПОИСК АКТИВНОГО ХОСТА...")
        lobby_role:set_color(C.yellow[1], C.yellow[2], C.yellow[3], C.yellow[4])
        lobby_info:set_text("Если хост не найден, этот ПК создаст лобби")
        start_button:set_interactable(false)
    end

    local list = get_lobby_list()

    for i = 1, MAX_PLAYERS do
        local bg = lobby_rows_bg[i]
        local text = lobby_rows_text[i]
        local item = list[i]

        if item ~= nil then
            if item.is_host then
                set_color(bg, C.lobby_row_host)
            else
                set_color(bg, C.lobby_row)
            end

            local prefix = "PLAYER"
            if item.is_host then
                prefix = "HOST"
            end

            local status = "ONLINE"
            if not item.connected then
                status = "LOST"
            end

            text:set_text(
                prefix .. "  •  " .. item.nick ..
                "  •  PC ID: " .. item.id ..
                "  •  " .. status
            )
            text:set_color(C.text[1], C.text[2], C.text[3], C.text[4])
        else
            set_color(bg, C.lobby_row)
            text:set_text("Свободный слот")
            text:set_color(C.muted[1], C.muted[2], C.muted[3], 120)
        end
    end

    if role == "host" then
        start_button:set_text("START FFA  •  " .. tostring(#list) .. " PLAYER")
    else
        start_button:set_text("ЖДЁМ ХОСТА")
    end
end

-- ---------------------------------------------------------------------------
-- СОРТИРОВКА ДЛЯ SCOREBOARD БЕЗ table.sort
-- ---------------------------------------------------------------------------
local function sorted_player_list()
    local source = get_current_players()
    local list = {}

    for id, player in pairs(source) do
        if player ~= nil then
            local inserted = false

            for i = 1, #list do
                if player.score > list[i].score or
                   (player.score == list[i].score and player.deaths < list[i].deaths) then
                    table.insert(list, i, player)
                    inserted = true
                    break
                end
            end

            if not inserted then
                table.insert(list, player)
            end
        end
    end

    return list
end

-- ---------------------------------------------------------------------------
-- РЕНДЕР ИГРОКОВ, ПУЛЬ, ПРИЦЕЛА И HUD
-- ---------------------------------------------------------------------------
local function update_player_render_positions()
    if role == "client" then
        for id, player in pairs(client_players) do
            local render_x = player.render_x or player.x
            local render_y = player.render_y or player.y

            if id == self_id then
                -- Собственный игрок уже был мгновенно сдвинут локальным вводом.
                -- Хост только мягко исправляет небольшую ошибку. Большая ошибка
                -- (респавн, смерть, серьёзный рассинхрон) применяется сразу.
                local error_x = player.x - render_x
                local error_y = player.y - render_y
                local error_sq = error_x * error_x + error_y * error_y

                if not player.alive or error_sq > 180 * 180 then
                    player.render_x = player.x
                    player.render_y = player.y
                else
                    player.render_x = render_x + error_x * 0.075
                    player.render_y = render_y + error_y * 0.075
                end
            else
                -- Для чужих игроков остаётся дешёвое сглаживание из v5.
                player.render_x = lerp(render_x, player.x, 0.32)
                player.render_y = lerp(render_y, player.y, 0.32)
            end
        end
    else
        for id, player in pairs(host_players) do
            player.render_x = player.x
            player.render_y = player.y
        end
    end
end

local function update_player_visuals()
    local players = get_current_players()
    local seen = {}
    local scale_key = math.floor(ui_scale * 100 + 0.5)

    for id, player in pairs(players) do
        seen[id] = true
        local visual = player_visuals[id]
        if visual == nil then
            visual = create_player_visual(id)
        end

        local screen_x, screen_y = world_to_screen(player.render_x or player.x, player.render_y or player.y)
        local visible = screen_x > -120 and screen_x < view_w + 120 and
                        screen_y > -120 and screen_y < view_h + 120

        if visible and player.connected then
            visual.hidden = false
            local r = clamp(PLAYER_RADIUS * ui_scale, 15, 25)
            local gun_size = math.max(8, 10 * ui_scale)

            -- Геометрия меняется только при resize, а не каждый кадр.
            if visual.scale_key ~= scale_key then
                visual.scale_key = scale_key
                visual.shadow:set_size(r * 2 + 6, r * 2 + 6)
                visual.shadow:set_rounding(r + 3)
                visual.outer:set_size(r * 2, r * 2)
                visual.outer:set_rounding(r)
                visual.body:set_size(r * 1.48, r * 1.48)
                visual.body:set_rounding(r * 0.74)
                visual.core:set_size(r * 0.48, r * 0.48)
                visual.core:set_rounding(r * 0.24)
                visual.gun:set_size(gun_size, gun_size)
                visual.gun:set_rounding(gun_size * 0.5)
                visual.name:set_size(170, 20)
                visual.name:set_font_size(math.max(10, math.floor(12 * ui_scale)))
                visual.status:set_size(170, 17)
                visual.status:set_font_size(math.max(9, math.floor(10 * ui_scale)))
            end

            visual.shadow:set_position(screen_x - r - 3, screen_y - r + 4)
            visual.outer:set_position(screen_x - r, screen_y - r)
            visual.body:set_position(screen_x - r * 0.74, screen_y - r * 0.74)
            visual.core:set_position(screen_x - r * 0.24, screen_y - r * 0.24)

            local gun_x = screen_x + player.aim_x * (r + 7)
            local gun_y = screen_y + player.aim_y * (r + 7)
            visual.gun:set_position(gun_x - gun_size * 0.5, gun_y - gun_size * 0.5)
            visual.name:set_position(screen_x - 85, screen_y - r - 33)
            visual.status:set_position(screen_x - 85, screen_y + r + 7)

            set_text_cached(visual.name, visual.cache, "name", player.nick)

            local state_key
            local status_text
            if player.alive then
                status_text = "K " .. tostring(player.score) .. "  •  D " .. tostring(player.deaths)
                state_key = (id == self_id and "local_alive" or "remote_alive")
            else
                status_text = "RESPAWN..."
                state_key = "dead"
            end
            set_text_cached(visual.status, visual.cache, "status", status_text)

            if visual.state_key ~= state_key then
                visual.state_key = state_key
                if state_key == "local_alive" then
                    set_color(visual.outer, C.local_outer)
                    set_color(visual.body, C.local_player)
                    set_color(visual.core, C.local_core)
                    visual.status:set_color(C.muted[1], C.muted[2], C.muted[3], C.muted[4])
                elseif state_key == "remote_alive" then
                    set_color(visual.outer, C.remote_outer)
                    set_color(visual.body, C.remote_player)
                    set_color(visual.core, C.remote_core)
                    visual.status:set_color(C.muted[1], C.muted[2], C.muted[3], C.muted[4])
                else
                    set_color(visual.outer, C.dead)
                    set_color(visual.body, C.dead)
                    set_color(visual.core, C.dead)
                    visual.status:set_color(C.yellow[1], C.yellow[2], C.yellow[3], C.yellow[4])
                end
            end
        else
            hide_player_visual(visual)
        end
    end

    for id, visual in pairs(player_visuals) do
        if not seen[id] then
            hide_player_visual(visual)
        end
    end
end

function update_bullet_visuals()
    local scale_key = math.floor(ui_scale * 100 + 0.5)
    local size = math.max(6, 8 * ui_scale)

    if PERF.bullet_scale_key ~= scale_key then
        PERF.bullet_scale_key = scale_key
        for i = 1, #bullet_visuals do
            bullet_visuals[i]:set_size(size, size)
            bullet_visuals[i]:set_rounding(size * 0.5)
        end
    end

    for i = 1, #bullet_visuals do
        local visual = bullet_visuals[i]
        local bullet = bullets[i]

        if bullet ~= nil then
            local screen_x, screen_y = world_to_screen(bullet.x, bullet.y)
            visual:set_position(screen_x - size * 0.5, screen_y - size * 0.5)
        else
            hide_element(visual)
        end
    end
end

function update_aim_guide()
    local player = get_local_player()

    if phase ~= "match" or player == nil or not player.alive then
        for i = 1, #aim_dots do
            hide_element(aim_dots[i])
        end
        hide_element(aim_end)
        return
    end

    local aim_x = local_input.aim_x
    local aim_y = local_input.aim_y
    local nx, ny, aim_len = normalize(aim_x, aim_y)

    if aim_len < 0.05 then
        nx = player.aim_x
        ny = player.aim_y
    end

    -- Этот же nx/ny отправляется хосту и становится скоростью пули.
    local maximum = 650
    local distance = ray_distance_to_wall(player.x, player.y, nx, ny, maximum)
    local spacing = 34
    local scale_key = math.floor(ui_scale * 100 + 0.5)
    local dot_size = math.max(3, 5 * ui_scale)
    local end_size = math.max(9, 12 * ui_scale)

    if PERF.aim_scale_key ~= scale_key then
        PERF.aim_scale_key = scale_key
        for i = 1, #aim_dots do
            aim_dots[i]:set_size(dot_size, dot_size)
            aim_dots[i]:set_rounding(dot_size * 0.5)
        end
        aim_end:set_size(end_size, end_size)
        aim_end:set_rounding(end_size * 0.5)
    end

    for i = 1, #aim_dots do
        local d = PLAYER_RADIUS + 17 + (i - 1) * spacing
        local dot = aim_dots[i]

        if d < distance then
            local world_x = player.x + nx * d
            local world_y = player.y + ny * d
            local screen_x, screen_y = world_to_screen(world_x, world_y)
            dot:set_position(screen_x - dot_size * 0.5, screen_y - dot_size * 0.5)
        else
            hide_element(dot)
        end
    end

    local end_world_x = player.x + nx * distance
    local end_world_y = player.y + ny * distance
    local end_x, end_y = world_to_screen(end_world_x, end_world_y)
    aim_end:set_position(end_x - end_size * 0.5, end_y - end_size * 0.5)
end

local function update_scoreboard()
    local list = sorted_player_list()

    for i = 1, MAX_PLAYERS do
        local row = scoreboard_rows[i]
        local player = list[i]

        if player ~= nil then
            local marker = "  "
            if player.id == self_id then
                marker = "> "
            end

            local connection = ""
            if not player.connected then
                connection = " [OFFLINE]"
            end

            local row_text =
                marker .. tostring(i) .. ". " .. player.nick ..
                "   K " .. tostring(player.score) ..
                "   D " .. tostring(player.deaths) .. connection
            set_text_cached(row, PERF.scoreboard_cache, i, row_text)

            if player.id == self_id then
                row:set_color(C.green[1], C.green[2], C.green[3], C.green[4])
                row:set_font_style("bold")
            else
                row:set_color(C.muted[1], C.muted[2], C.muted[3], C.muted[4])
                row:set_font_style("normal")
            end
        else
            set_text_cached(row, PERF.scoreboard_cache, i, "")
        end
    end
end

local function update_hud()
    local player = get_local_player()

    if phase == "match" then
        local role_text = "CLIENT"
        if role == "host" then
            role_text = "HOST"
        end

        set_text_cached(
            hud_status, PERF.hud_cache, "status",
            role_text .. "  •  HOST: " .. tostring(host_nick or local_nick) ..
            "  •  ID: " .. self_id_short
        )

        if player ~= nil then
            set_text_cached(
                hud_stats, PERF.hud_cache, "stats",
                "K " .. tostring(player.score) ..
                "  •  D " .. tostring(player.deaths) ..
                "  •  " .. player.nick
            )

            if not player.alive then
                local remaining = player.respawn_remaining or 0
                if role == "host" and player.respawn_at ~= nil then
                    remaining = math.max(0, player.respawn_at - time())
                end
                set_text_cached(respawn_label, PERF.hud_cache, "respawn", "ТЫ УБИТ • РЕСПАВН " .. string.format("%.1f", remaining))
            else
                set_text_cached(respawn_label, PERF.hud_cache, "respawn", "")
            end
        else
            set_text_cached(hud_stats, PERF.hud_cache, "stats", "Ожидаем состояние игрока...")
            set_text_cached(respawn_label, PERF.hud_cache, "respawn", "")
        end

        set_text_cached(
            network_label, PERF.hud_cache, "network",
            "FFA • один выстрел = убийство • игроков: " .. tostring(#sorted_player_list())
        )
    end
end

-- ---------------------------------------------------------------------------
-- РАЗМЕТКА ПРИ ИЗМЕНЕНИИ РАЗМЕРА ОКНА
-- ---------------------------------------------------------------------------
local function apply_layout(w, h)
    if w == nil or h == nil or w < 500 or h < 340 then
        return
    end

    view_w = w
    view_h = h
    ui_scale = clamp(math.min(view_w / 1280, view_h / 720), 0.65, 1.55)

    floor:set_position(0, 0)
    floor:set_size(view_w, view_h)
    floor_alt:set_position(0, 0)
    floor_alt:set_size(view_w, view_h)

    for i = 1, #vertical_grid do
        vertical_grid[i]:set_size(math.max(1, ui_scale), view_h)
    end
    for i = 1, #horizontal_grid do
        horizontal_grid[i]:set_size(view_w, math.max(1, ui_scale))
    end

    local hud_w = clamp(430 * ui_scale, 345, view_w * 0.46)
    local hud_h = 88 * ui_scale

    hud_panel:set_position(18 * ui_scale, 18 * ui_scale)
    hud_panel:set_size(hud_w, hud_h)
    hud_panel:set_rounding(14 * ui_scale)

    hud_border:set_position(18 * ui_scale, 18 * ui_scale + hud_h - 2)
    hud_border:set_size(hud_w, 2)

    hud_title:set_position(34 * ui_scale, 27 * ui_scale)
    hud_title:set_size(hud_w - 32 * ui_scale, 25 * ui_scale)
    hud_title:set_font_size(math.max(13, math.floor(18 * ui_scale)))

    hud_status:set_position(34 * ui_scale, 55 * ui_scale)
    hud_status:set_size(hud_w - 32 * ui_scale, 20 * ui_scale)
    hud_status:set_font_size(math.max(10, math.floor(12 * ui_scale)))

    hud_stats:set_position(34 * ui_scale, 78 * ui_scale)
    hud_stats:set_size(hud_w - 32 * ui_scale, 20 * ui_scale)
    hud_stats:set_font_size(math.max(10, math.floor(12 * ui_scale)))

    local board_w = clamp(340 * ui_scale, 280, 380)
    local board_h = clamp(315 * ui_scale, 260, 355)
    local board_x = view_w - board_w - 18 * ui_scale
    local board_y = 18 * ui_scale

    scoreboard_panel:set_position(board_x, board_y)
    scoreboard_panel:set_size(board_w, board_h)
    scoreboard_panel:set_rounding(14 * ui_scale)

    scoreboard_title:set_position(board_x + 16 * ui_scale, board_y + 12 * ui_scale)
    scoreboard_title:set_size(board_w - 32 * ui_scale, 24 * ui_scale)
    scoreboard_title:set_font_size(math.max(11, math.floor(14 * ui_scale)))

    for i = 1, MAX_PLAYERS do
        local row = scoreboard_rows[i]
        row:set_position(board_x + 16 * ui_scale, board_y + (39 + (i - 1) * 21) * ui_scale)
        row:set_size(board_w - 32 * ui_scale, 19 * ui_scale)
        row:set_font_size(math.max(9, math.floor(10.5 * ui_scale)))
    end

    respawn_label:set_position(view_w * 0.5 - 250 * ui_scale, view_h * 0.44)
    respawn_label:set_size(500 * ui_scale, 60 * ui_scale)
    respawn_label:set_font_size(math.max(20, math.floor(28 * ui_scale)))

    network_label:set_position(view_w * 0.5 - 250 * ui_scale, 21 * ui_scale)
    network_label:set_size(500 * ui_scale, 22 * ui_scale)
    network_label:set_font_size(math.max(9, math.floor(11 * ui_scale)))

    local joy_radius = clamp(math.min(view_w, view_h) * 0.105, 58, 94)
    local side_margin = joy_radius + 31 * ui_scale
    local bottom_margin = joy_radius + 27 * ui_scale

    move_joy.radius = joy_radius
    move_joy.knob_radius = joy_radius * 0.37
    move_joy.cx = side_margin
    move_joy.cy = view_h - bottom_margin

    aim_joy.radius = joy_radius
    aim_joy.knob_radius = joy_radius * 0.37
    aim_joy.cx = view_w - side_margin
    aim_joy.cy = view_h - bottom_margin

    if phase == "match" then
        update_joystick_visual(move_joy)
        update_joystick_visual(aim_joy)
    end

    -- Лобби: во время матча его нельзя снова раскладывать на экране.
    if phase == "lobby" or phase == "discovering" then
    local panel_w = clamp(view_w * 0.66, 680, 900)
    local panel_h = clamp(view_h * 0.82, 520, 650)
    local panel_x = (view_w - panel_w) * 0.5
    local panel_y = (view_h - panel_h) * 0.5

    lobby_dim:set_position(0, 0)
    lobby_dim:set_size(view_w, view_h)

    lobby_panel:set_position(panel_x, panel_y)
    lobby_panel:set_size(panel_w, panel_h)
    lobby_panel:set_rounding(22 * ui_scale)

    lobby_header:set_position(panel_x + 30 * ui_scale, panel_y + 24 * ui_scale)
    lobby_header:set_size(panel_w - 60 * ui_scale, 42 * ui_scale)
    lobby_header:set_font_size(math.max(20, math.floor(26 * ui_scale)))

    lobby_role:set_position(panel_x + 30 * ui_scale, panel_y + 72 * ui_scale)
    lobby_role:set_size(panel_w - 60 * ui_scale, 30 * ui_scale)
    lobby_role:set_font_size(math.max(13, math.floor(16 * ui_scale)))

    lobby_info:set_position(panel_x + 30 * ui_scale, panel_y + 107 * ui_scale)
    lobby_info:set_size(panel_w - 60 * ui_scale, 26 * ui_scale)
    lobby_info:set_font_size(math.max(10, math.floor(12 * ui_scale)))

    local list_x = panel_x + 40 * ui_scale
    local list_y = panel_y + 150 * ui_scale
    local list_w = panel_w - 80 * ui_scale
    local list_h = panel_h - 270 * ui_scale

    lobby_players_panel:set_position(list_x, list_y)
    lobby_players_panel:set_size(list_w, list_h)
    lobby_players_panel:set_rounding(15 * ui_scale)

    lobby_players_title:set_position(list_x + 18 * ui_scale, list_y + 12 * ui_scale)
    lobby_players_title:set_size(list_w - 36 * ui_scale, 25 * ui_scale)
    lobby_players_title:set_font_size(math.max(11, math.floor(14 * ui_scale)))

    local row_h = math.max(20, (list_h - 53 * ui_scale) / MAX_PLAYERS)
    for i = 1, MAX_PLAYERS do
        local row_y = list_y + 42 * ui_scale + (i - 1) * row_h
        lobby_rows_bg[i]:set_position(list_x + 16 * ui_scale, row_y)
        lobby_rows_bg[i]:set_size(list_w - 32 * ui_scale, row_h - 3)
        lobby_rows_bg[i]:set_rounding(6 * ui_scale)

        lobby_rows_text[i]:set_position(list_x + 26 * ui_scale, row_y)
        lobby_rows_text[i]:set_size(list_w - 52 * ui_scale, row_h - 3)
        lobby_rows_text[i]:set_font_size(math.max(9, math.floor(10.5 * ui_scale)))
        lobby_rows_text[i]:set_align("left")
    end

    start_button:set_position(panel_x + panel_w * 0.5 - 140 * ui_scale, panel_y + panel_h - 96 * ui_scale)
    start_button:set_size(280 * ui_scale, 54 * ui_scale)
    start_button:set_font_size(math.max(14, math.floor(18 * ui_scale)))
    start_button:set_rounding(14 * ui_scale)

    lobby_footer:set_position(panel_x + 30 * ui_scale, panel_y + panel_h - 36 * ui_scale)
    lobby_footer:set_size(panel_w - 60 * ui_scale, 22 * ui_scale)
    lobby_footer:set_font_size(math.max(9, math.floor(11 * ui_scale)))
    else
        hide_lobby()
    end

    -- Экран отказа
    reject_dim:set_size(view_w, view_h)
    local reject_w = clamp(view_w * 0.52, 520, 720)
    local reject_h = 250 * ui_scale
    local reject_x = (view_w - reject_w) * 0.5
    local reject_y = (view_h - reject_h) * 0.5

    if phase == "rejected" then
        reject_dim:set_position(0, 0)
        reject_panel:set_position(reject_x, reject_y)
        reject_panel:set_size(reject_w, reject_h)
        reject_title:set_position(reject_x + 24 * ui_scale, reject_y + 30 * ui_scale)
        reject_title:set_size(reject_w - 48 * ui_scale, 48 * ui_scale)
        reject_text:set_position(reject_x + 30 * ui_scale, reject_y + 100 * ui_scale)
        reject_text:set_size(reject_w - 60 * ui_scale, 80 * ui_scale)
    end
end

win:on_resize(function(w, h)
    apply_layout(w, h)
end)

-- ---------------------------------------------------------------------------
-- УПРАВЛЕНИЕ ПАЛЬЦАМИ / МЫШЬЮ
-- ---------------------------------------------------------------------------
win:on_finger(function(x, y, state)
    if phase ~= "match" then
        return
    end

    if state == "down" then
        if x < view_w * 0.5 then
            if joystick_accepts(move_joy, x, y) or y > view_h * 0.48 then
                set_joystick_from_point(move_joy, x, y)
            end
        else
            if joystick_accepts(aim_joy, x, y) or y > view_h * 0.48 then
                set_joystick_from_point(aim_joy, x, y)
            end
        end

    elseif state == "move" then
        if x < view_w * 0.5 and move_joy.active then
            set_joystick_from_point(move_joy, x, y)
        elseif x >= view_w * 0.5 and aim_joy.active then
            set_joystick_from_point(aim_joy, x, y)
        end

    elseif state == "up" then
        if x < view_w * 0.5 then
            release_joystick(move_joy)
        else
            release_joystick(aim_joy)
        end
    end
end)

-- ---------------------------------------------------------------------------
-- ОБНОВЛЕНИЕ ЛОКАЛЬНОГО INPUT
-- ---------------------------------------------------------------------------
local function update_local_input()
    local move_x, move_y, move_len = normalize(move_joy.dx, move_joy.dy)
    local move_amount = math.min(1, move_len)
    local_input.move_x = move_x * move_amount
    local_input.move_y = move_y * move_amount

    local aim_x, aim_y, aim_len = normalize(aim_joy.dx, aim_joy.dy)
    if aim_len > 0.12 then
        local_input.aim_x = aim_x
        local_input.aim_y = aim_y
    end

    local_input.fire = aim_joy.active and aim_len > 0.42

    if role == "host" and phase == "match" then
        local player = host_players[self_id]
        if player ~= nil then
            player.move_x = local_input.move_x
            player.move_y = local_input.move_y
            player.aim_x = local_input.aim_x
            player.aim_y = local_input.aim_y
            player.fire = local_input.fire
            player.last_seen = time()
        end
    elseif role == "client" and phase == "match" then
        -- Единственное добавление к рабочему циклу v5: один локальный шаг
        -- визуальной позиции. Сеть и физика хоста остались без новых циклов.
        local player = client_players[self_id]
        if player ~= nil and player.connected and player.alive then
            move_render_with_collision(
                player,
                local_input.move_x * PLAYER_SPEED * FIXED_DT,
                local_input.move_y * PLAYER_SPEED * FIXED_DT
            )

            -- Прицел собственного игрока тоже реагирует сразу визуально.
            player.aim_x = local_input.aim_x
            player.aim_y = local_input.aim_y
        end
    end
end

-- ---------------------------------------------------------------------------
-- СОСТОЯНИЯ UI
-- ---------------------------------------------------------------------------
local previous_phase = ""

local function update_phase_visibility()
    if previous_phase == phase then
        return
    end

    previous_phase = phase

    if phase == "match" then
        hide_element(reject_dim)
        hide_element(reject_panel)
        hide_element(reject_title)
        hide_element(reject_text)
        show_game_ui(true)
        apply_layout(view_w, view_h)
        hide_lobby()
    elseif phase == "rejected" then
        hide_lobby()
        show_game_ui(false)
        apply_layout(view_w, view_h)
        reject_text:set_text(rejected_reason .. "\nЗакрой скрипт и подключись после завершения матча.")
    else
        show_game_ui(false)
        hide_element(reject_dim)
        hide_element(reject_panel)
        hide_element(reject_title)
        hide_element(reject_text)
        apply_layout(view_w, view_h)
    end
end

-- ---------------------------------------------------------------------------
-- ПРОВЕРКА СОЕДИНЕНИЙ
-- ---------------------------------------------------------------------------
local function update_connection_state()
    local now = time()

    if role == "discovering" and now - discovery_started_at >= DISCOVERY_SECONDS then
        become_host()
        return
    end

    if role == "client" then
        if phase == "lobby" then
            send_join()
        end

        -- Свежесть определяется изменением heartbeat/seq, а не повторным чтением
        -- одного старого пакета.
        local freshest = math.max(last_fresh_beacon_at, last_host_packet_at)
        if phase ~= "rejected" and now - freshest > HOST_TIMEOUT then
            show_rejected("Соединение с хостом потеряно.")
        end
    end
end

-- ---------------------------------------------------------------------------
-- ГЛАВНЫЙ ЦИКЛ
-- ---------------------------------------------------------------------------
local function tick()
    local now = time()

    -- Сеть максимум 20 раз в секунду. Внутренние send-функции дополнительно
    -- имеют свои интервалы, поэтому пустые кадры не сериализуют состояние.
    if now >= PERF.next_network then
        PERF.next_network = now + PERF.network_interval
        process_host_beacon()
        update_connection_state()

        if role == "host" then
            send_host_beacon()
            host_process_join()

            if phase == "lobby" then
                host_prune_lobby()
                send_lobby_to_clients()
            elseif phase == "match" then
                host_process_inputs()
                send_state_to_clients()
            end
        elseif role == "client" then
            client_process_host_packet()
            if phase == "match" then
                send_input()
            end
        end
    end

    update_phase_visibility()

    if phase == "lobby" or phase == "discovering" then
        if now >= PERF.next_lobby then
            PERF.next_lobby = now + PERF.lobby_interval
            update_lobby_text()
        end
        return
    end

    if phase == "rejected" then
        if now >= PERF.next_hud then
            PERF.next_hud = now + PERF.hud_interval
            reject_text:set_text(rejected_reason .. "\nНовые игроки войдут только в следующее лобби.")
        end
        return
    end

    if phase ~= "match" then
        return
    end

    -- Физика 30 Гц.
    update_local_input()
    if role == "host" then
        host_update_players(FIXED_DT)
        host_update_bullets(FIXED_DT)
    end

    -- Динамические объекты обновляются плавно.
    update_player_render_positions()
    update_camera()
    update_player_visuals()
    update_bullet_visuals()

    -- Статичная карта двигается реже и только если камера реально сместилась.
    local camera_moved = math.abs(camera_x - PERF.last_camera_x) >= PERF.camera_threshold or
                         math.abs(camera_y - PERF.last_camera_y) >= PERF.camera_threshold
    if now >= PERF.next_world and camera_moved then
        PERF.next_world = now + PERF.world_interval
        PERF.last_camera_x = camera_x
        PERF.last_camera_y = camera_y
        update_grid()
        update_world_visuals()
    end

    if now >= PERF.next_aim then
        PERF.next_aim = now + PERF.aim_interval
        update_aim_guide()
    end

    if now >= PERF.next_hud then
        PERF.next_hud = now + PERF.hud_interval
        update_scoreboard()
        update_hud()
    end
end

-- ---------------------------------------------------------------------------
-- ЗАПУСК
-- ---------------------------------------------------------------------------
apply_layout(START_W, START_H)
show_game_ui(false)
update_lobby_text()

-- Максимизация вызывается после создания всех элементов, чтобы on_resize
-- получил фактический размер тела окна и перестроил интерфейс.
win:maximize()

local main_timer = win:every(FIXED_DT, tick)

win:on_close(function()
    if main_timer ~= nil then
        main_timer:stop()
    end
end)

print("CS2D MULTIPLAYER FFA v9 JOIN-FIX started")
print("Nick: " .. local_nick)
print("PC ID: " .. self_id)
print("Protocol: " .. PROTOCOL_VERSION)

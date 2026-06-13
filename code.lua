-- ==========================================
-- LUA STORE (CLOUDD EDITION - ПОДКЛЮЧЕНО К FIREBASE)
-- ==========================================
local win = create_window("Lua Store", 700, 430)
win:set_bg_color(20, 22, 28, 255)
win:set_title_color(15, 17, 22, 255)

local FIREBASE_URL = "https://luastore-14464-default-rtdb.firebaseio.com/apps.json"

local apps = {}
local current_apps_list = {}
local cards = {}

local current_view = "store"
local current_selected_app = nil

-- ==========================================
-- ЛОГИКА ФЕЙКОВОЙ ЗАГРУЗКИ ПРИЛОЖЕНИЯ
-- ==========================================
local is_downloading = false

local function start_download(app)
    if is_downloading then return end
    
    local file_path = "Apps/" .. app.title .. ".app"
    if file_exists(file_path, 0) then
        show_message("Уже установлено", "Приложение '" .. app.title .. "' уже скачано!", "ok", "info")
        return
    end

    is_downloading = true

    local overlay = win:add_button("", 0, 0, 700, 430)
    overlay:set_color(15, 18, 22, 230)
    overlay:on_click(function() end) 

    local mx, my = 150, 150
    local modal = win:add_button("", mx, my, 400, 130)
    modal:set_color(35, 38, 45, 255)

    local lbl_text = win:add_label("Скачивание: " .. app.title, mx + 20, my + 20)
    lbl_text:set_color(255, 255, 255, 255)

    local lbl_pct = win:add_label("0%", mx + 330, my + 20)
    lbl_pct:set_color(60, 180, 80, 255)

    local bar_bg = win:add_button("", mx + 20, my + 60, 360, 20)
    bar_bg:set_color(20, 22, 28, 255)

    local bar_fg = win:add_button("", mx + 20, my + 60, 0, 20)
    bar_fg:set_color(60, 180, 80, 255)

    local step = 0
    local total_steps = 30
    local t
    
    t = win:every(0.1, function()
        step = step + 1
        local progress = step / total_steps
        local w = math.floor(360 * progress)
        local pct = math.floor(progress * 100)
        
        bar_fg:set_size(w, 20)
        lbl_pct:set_text(pct .. "%")
        
        if step >= total_steps then
            t:stop()
            overlay:destroy()
            modal:destroy()
            lbl_text:destroy()
            lbl_pct:destroy()
            bar_bg:destroy()
            bar_fg:destroy()
            
            write_file(file_path, "FAKE_APP_DATA", 0)
            is_downloading = false
            show_message("Успех", "Приложение '" .. app.title .. "' успешно установлено!", "ok", "info")
        end
    end)
end

-- ==========================================
-- ИНТЕРФЕЙС: ЭКРАН ПРИЛОЖЕНИЯ (DETAIL VIEW)
-- ==========================================
local detail_elements = {}

local btn_back = win:add_button("⬅ Назад", 20, 15, 100, 35)
btn_back:set_color(50, 55, 65, 255)
btn_back:set_text_color(255, 255, 255, 255)

local lbl_det_title = win:add_label("Название", 140, 20)
lbl_det_title:set_color(255, 255, 255, 255)
lbl_det_title:set_font_size(24)

local img_det_screen = win:add_raw_image(20, 70, 300, 200)

local inp_det_desc = win:add_input(340, 70, 340, 200)
inp_det_desc:set_multiline(true)
inp_det_desc:set_color(25, 28, 35, 255)
inp_det_desc:set_text_color(200, 200, 200, 255)

local btn_det_down = win:add_button("📥 СКАЧАТЬ ПРИЛОЖЕНИЕ", 20, 290, 660, 60)
btn_det_down:set_color(60, 160, 80, 255)
btn_det_down:set_text_color(255, 255, 255, 255)

btn_det_down:on_click(function()
    if current_selected_app then start_download(current_selected_app) end
end)

table.insert(detail_elements, btn_back)
table.insert(detail_elements, lbl_det_title)
table.insert(detail_elements, img_det_screen)
table.insert(detail_elements, inp_det_desc)
table.insert(detail_elements, btn_det_down)

for _, el in ipairs(detail_elements) do el:set_position(-1000, -1000) end

-- ==========================================
-- ИНТЕРФЕЙС: МАГАЗИН (STORE VIEW) + ПОИСК
-- ==========================================
local lbl_store_title = win:add_label("🌟 LUA STORE", 20, 15)
lbl_store_title:set_color(255, 255, 255, 255)
lbl_store_title:set_font_size(20)

local inp_search = win:add_input(240, 10, 370, 35)
inp_search:set_placeholder("Поиск приложений...")
inp_search:set_color(30, 35, 45, 255)
inp_search:set_text_color(255, 255, 255, 255)

local btn_search = win:add_button(">", 620, 10, 45, 35)
btn_search:set_color(60, 140, 80, 255)
btn_search:set_text_color(255, 255, 255, 255)

local card_w = 640
local card_h = 110 
local spacing_y = 10
local start_x = 20
local start_y = 60
local view_top = 60  
local view_bottom = 430 

-- СЛАЙДЕР
local track_x = 675
local track_y = 60
local track_w = 10
local track_h = 350

local track = win:add_button("", track_x, track_y, track_w, track_h)
track:set_color(40, 40, 45, 255)

local thumb_h = 60
local thumb_y = track_y
local thumb = win:add_button("", track_x, thumb_y, track_w, thumb_h)
thumb:set_color(100, 100, 120, 255)

local is_dragging = false
local drag_offset_y = 0
local min_thumb_y = track_y
local max_thumb_y = track_y + track_h - thumb_h
local max_scroll = 0

-- ==========================================
-- ЛОГИКА ДИНАМИЧЕСКОГО СЖАТИЯ (CLIPPING)
-- ==========================================
local function update_scroll()
    if current_view ~= "store" then return end
    
    local progress = 0
    if max_thumb_y > min_thumb_y then
        progress = (thumb_y - min_thumb_y) / (max_thumb_y - min_thumb_y)
    end
    local current_scroll = progress * max_scroll
    
    for _, card in ipairs(cards) do
        local original_y = card.base_y - current_scroll
        local render_y = original_y
        local render_h = card_h
        
        if original_y < view_top then
            local cut_amount = view_top - original_y
            render_y = view_top
            render_h = card_h - cut_amount
        end
        
        if (original_y + card_h) > view_bottom then
            local cut_amount = (original_y + card_h) - view_bottom
            render_h = card_h - cut_amount
            if render_h < 0 then render_h = 0 end 
        end
        
        if original_y > view_bottom or (original_y + card_h) < view_top then
            card.bg:set_position(-1000, -1000)
            card.icon:set_position(-1000, -1000)
            card.lbl_title:set_position(-1000, -1000)
            card.lbl_short:set_position(-1000, -1000)
            card.btn_dl:set_position(-1000, -1000)
        else
            card.bg:set_position(card.base_x, render_y)
            card.bg:set_size(card_w, render_h)
            
            if (original_y + 10) < view_top or (original_y + 100) > view_bottom then
                card.icon:set_position(-1000, -1000)
            else
                card.icon:set_position(card.base_x + 10, original_y + 10)
            end
            
            if (original_y + 10) < view_top or (original_y + 30) > view_bottom then
                card.lbl_title:set_position(-1000, -1000)
            else
                card.lbl_title:set_position(card.base_x + 120, original_y + 10)
            end
            
            if (original_y + 40) < view_top or (original_y + 60) > view_bottom then
                card.lbl_short:set_position(-1000, -1000)
            else
                card.lbl_short:set_position(card.base_x + 120, original_y + 40)
            end
            
            if (original_y + 65) < view_top or (original_y + 100) > view_bottom then
                card.btn_dl:set_position(-1000, -1000)
            else
                card.btn_dl:set_position(card.base_x + 120, original_y + 65)
            end
        end
    end
    
    thumb:set_position(track_x, thumb_y)
    track:set_position(track_x, track_y)
end

-- ==========================================
-- ЛОГИКА ПЕРЕКЛЮЧЕНИЯ ЭКРАНОВ
-- ==========================================
local function hide_store()
    lbl_store_title:set_position(-1000, -1000)
    inp_search:set_position(-1000, -1000)
    btn_search:set_position(-1000, -1000)
    track:set_position(-1000, -1000)
    thumb:set_position(-1000, -1000)
    for _, card in ipairs(cards) do
        card.bg:set_position(-1000, -1000)
        card.icon:set_position(-1000, -1000)
        card.lbl_title:set_position(-1000, -1000)
        card.lbl_short:set_position(-1000, -1000)
        card.btn_dl:set_position(-1000, -1000)
    end
end

local function open_app_page(app)
    current_view = "detail"
    current_selected_app = app
    hide_store()
    
    lbl_det_title:set_text(app.title)
    img_det_screen:set_url(app.screen)
    inp_det_desc:set_text(app.desc)
    
    btn_back:set_position(20, 15)
    lbl_det_title:set_position(140, 20)
    img_det_screen:set_position(20, 70)
    inp_det_desc:set_position(340, 70)
    btn_det_down:set_position(20, 290)
end

btn_back:on_click(function()
    current_view = "store"
    current_selected_app = nil
    for _, el in ipairs(detail_elements) do el:set_position(-1000, -1000) end
    
    lbl_store_title:set_position(20, 15)
    inp_search:set_position(240, 10)
    btn_search:set_position(620, 10)
    update_scroll() 
end)

-- ==========================================
-- ГЕНЕРАЦИЯ СПИСКА КАРТОЧЕК
-- ==========================================
local function render_cards(list_to_render)
    for _, card in ipairs(cards) do
        card.bg:destroy()
        card.icon:destroy()
        card.lbl_title:destroy()
        card.lbl_short:destroy()
        card.btn_dl:destroy()
    end
    cards = {}
    
    for i, app in ipairs(list_to_render) do
        local base_y = start_y + (i - 1) * (card_h + spacing_y)
        local base_x = start_x
        
        local bg = win:add_button("", base_x, base_y, card_w, card_h)
        bg:set_color(35, 38, 45, 255)
        bg:on_click(function() open_app_page(app) end)
        
        local icon = win:add_raw_image(base_x + 10, base_y + 10, 90, 90)
        icon:set_url(app.icon)
        
        local lbl_title = win:add_label(app.title, base_x + 120, base_y + 10)
        lbl_title:set_color(255, 255, 255, 255)
        lbl_title:set_font_size(20)
        
        local lbl_short = win:add_label(app.short_desc, base_x + 120, base_y + 40)
        lbl_short:set_color(160, 160, 170, 255)
        
        local btn_dl = win:add_button("Скачать", base_x + 120, base_y + 65, 120, 35)
        btn_dl:set_color(60, 140, 80, 255)
        btn_dl:set_text_color(255, 255, 255, 255)
        
        btn_dl:on_click(function() start_download(app) end)
        
        table.insert(cards, {
            base_x = base_x, base_y = base_y,
            bg = bg, icon = icon, lbl_title = lbl_title, lbl_short = lbl_short, btn_dl = btn_dl
        })
    end
    
    local total_content_height = #list_to_render * (card_h + spacing_y)
    max_scroll = math.max(0, total_content_height - track_h)
    thumb_y = track_y 
    update_scroll()
end

-- ==========================================
-- ЛОГИКА ПОИСКА
-- ==========================================
btn_search:on_click(function()
    local query = string.lower(inp_search:get_text())
    
    if query == "" then
        current_apps_list = apps
    else
        current_apps_list = {}
        for _, app in ipairs(apps) do
            local search_title = string.lower(app.title)
            local search_desc = string.lower(app.short_desc)
            if string.find(search_title, query) or string.find(search_desc, query) then
                table.insert(current_apps_list, app)
            end
        end
    end
    
    render_cards(current_apps_list)
end)

-- ==========================================
-- ЗАГРУЗКА БАЗЫ ИЗ ИНТЕРНЕТА (ПУЛЕНЕПРОБИВАЕМЫЙ ПАРСЕР)
-- ==========================================
local lbl_loading = win:add_label("Подключение к серверам Lua Store...", 180, 200)
lbl_loading:set_color(150, 150, 150, 255)
lbl_loading:set_font_size(20)

http_get(FIREBASE_URL, function(body, code)
    if code == 200 and body then
        lbl_loading:destroy()
        
        local parsed_apps = {}
        
        -- Новый супер-надежный парсер! 
        -- Ищет просто любые блоки {} внутри которых нет других скобок.
        for obj_str in string.gmatch(body, "%{([^{}]+)%}") do
            local app = {}
            
            local id_str = string.match(obj_str, '"id"%s*:%s*(%d+)')
            if id_str then app.id = tonumber(id_str) end
            
            app.title = string.match(obj_str, '"title"%s*:%s*"([^"]+)"') or "Без названия"
            app.short_desc = string.match(obj_str, '"short_desc"%s*:%s*"([^"]+)"') or ""
            
            local desc = string.match(obj_str, '"desc"%s*:%s*"([^"]+)"') or ""
            app.desc = string.gsub(desc, "\\n", "\n")
            
            app.icon = string.match(obj_str, '"icon"%s*:%s*"([^"]+)"') or ""
            app.screen = string.match(obj_str, '"screen"%s*:%s*"([^"]+)"') or ""
            
            -- Добавляем только если это реально карточка приложения (есть ID)
            if app.id then
                table.insert(parsed_apps, app)
            end
        end
        
        if #parsed_apps > 0 then
            table.sort(parsed_apps, function(a, b) return a.id < b.id end)
            apps = parsed_apps
            current_apps_list = apps
            render_cards(apps)
        else
            show_message("Ошибка парсинга", "База подключена, но в ней нет приложений или JSON поврежден.", "ok", "error")
        end
    else
        lbl_loading:set_text("Ошибка подключения: Код " .. tostring(code))
        lbl_loading:set_color(255, 50, 50, 255)
    end
end)

-- ==========================================
-- УПРАВЛЕНИЕ СЛАЙДЕРОМ
-- ==========================================
win:on_finger(function(x, y, state)
    if current_view ~= "store" or is_downloading then return end 
    
    if state == "down" then
        if x >= track_x - 10 and x <= track_x + track_w + 10 and y >= thumb_y and y <= thumb_y + thumb_h then
            is_dragging = true
            drag_offset_y = y - thumb_y
        end
    elseif state == "move" then
        if is_dragging then
            thumb_y = y - drag_offset_y
            if thumb_y < min_thumb_y then thumb_y = min_thumb_y end
            if thumb_y > max_thumb_y then thumb_y = max_thumb_y end
            update_scroll()
        end
    elseif state == "up" then
        is_dragging = false
    end
end)

-- View nearby traffic on scope-like display

require("graphics")

if not SUPPORTS_FLOATING_WINDOWS then
    logMsg("imgui not supported by your FlyWithLua version")
    return
end

-- CONSTANTS
local aptdat_path = SYSTEM_DIRECTORY .. "Resources" .. DIRECTORY_SEPARATOR .. "default scenery" .. DIRECTORY_SEPARATOR .. "default apt dat" .. DIRECTORY_SEPARATOR .. "Earth nav data" .. DIRECTORY_SEPARATOR .. "apt.dat"
local metar_path = SYSTEM_DIRECTORY .. "METAR.rwx"

------------------------------------------------------------------
-- apt.dat reader
------------------------------------------------------------------
-- Read airport with ICAO code from global apt.dat
-- Based on https://forums.x-plane.org/index.php?/forums/topic/194167-ambitious-read-aptdat/&tab=comments#comment-1777912
-- by RandomUser
function split_line(input,delim)
    local split_result = {}
    --print(input)
    for i in string.gmatch(input,delim) do table.insert(split_result,i) end
    --print("split_result: "..table.concat(split_result,",",1,#split_result))
    return split_result
end
    
    
function get_airport(icao)
    local apt_table = nil
    local f = io.open(aptdat_path, "r")
    if f then
        for line in f:lines() do
            if string.match(line,"^1%s%s%s(%A+)") or string.match(line,"^16%s%s(%A+)") or string.match(line,"^17%s%s(%A+)") then
                -- Found airport header
                local tokens = split_line(line, "%S+")
                if tokens[5] == icao then
                    -- Airport definition matches icao
                    local name = tokens[6]
                    for i = 7, #tokens do
                        name = name .. " " .. tokens[i]
                    end
                    apt_table = {
                        icao=tokens[5],
                        name=name,
                        runways={}
                    }
                    logMsg("Found airport " .. apt_table.icao .. " " .. apt_table.name)
                    break
                end
            end
        end
        for line in f:lines() do
            -- Parse runway lines
            if string.match(line, "^100%s") then
                -- Runway
                local rwy = nil
                local tokens = split_line(line, "%S+")
                rwy = {
                    num1=tokens[9],
                    lat1=tonumber(tokens[10]),
                    lon1=tonumber(tokens[11]),
                    num2=tokens[18],
                    lat2=tonumber(tokens[19]),
                    lon2=tonumber(tokens[20])
                }
                table.insert(apt_table.runways, rwy)
                logMsg("Found runway " .. rwy.num1 .. "/" .. rwy.num2)
            elseif string.match(line, "^101%s") then
                -- Water runway
                local rwy = nil
                local tokens = split_line(line, "%S+")
                rwy = {
                    num1=tokens[4],
                    lat1=tonumber(tokens[5]),
                    lon1=tonumber(tokens[6]),
                    num2=tokens[7],
                    lat2=tonumber(tokens[8]),
                    lon2=tonumber(tokens[9])
                }
                table.insert(apt_table.runways, rwy)
            -- elseif string.match(line, "^102%s") then
            --     -- Helipad
            --     local pad = nil
            --     local tokens = split_line(line, "%S+")
            --     table.insert(apt_table.runways, rwy)
            elseif string.match(line,"^1%s%s%s(%A+)") or string.match(line,"^16%s%s(%A+)") or string.match(line,"^17%s%s(%A+)") then
                -- Start of next airport
                -- Finalize results
                local apt_lat = 0
                local apt_lon = 0
                for i = 1, #apt_table.runways do
                    apt_lat = apt_lat + (apt_table.runways[i].lat1 + apt_table.runways[i].lat2) / (2 * #apt_table.runways)
                    apt_lon = apt_lon + (apt_table.runways[i].lon1 + apt_table.runways[i].lon2) / (2 * #apt_table.runways)
                end
                apt_table.lat = apt_lat
                apt_table.lon = apt_lon
                apt_table.metar = get_metar(icao)
                logMsg(apt_table.icao .. " lat=" .. tostring(apt_table.lat) .. ", lon=" .. tostring(apt_table.lon))
                break
            end
        end
        f:close()
    end
    if not f then
        logMsg("Unable to open " .. aptdat_path)
    end
    return apt_table
end


------------------------------------------------------------------
-- METAR.rwx reader
------------------------------------------------------------------
function get_metar(icao)
    local metar = nil
    local f = io.open(metar_path, "r")
    if f then
        for line in f:lines() do
            local len = icao:len()
            if line:sub(1, len) == icao then
                metar = line
            end
        end
    end
    return metar
end

------------------------------------------------------------------
-- Scope drawing
------------------------------------------------------------------
local dep_apt = nil
local arr_apt = nil

local scope_enabled = false

local scope_range = 50 -- nm
local pix_per_nm = SCREEN_HIGHT / (2 * scope_range)

function ltscope_toggle()
    if not scope_enabled then
        scope_enabled = true
    else
        scope_enabled = false
    end
end

function ltscope_set_icao(dep, arr)
    local msg = ""
    dep_apt = get_airport(dep)
    if dep_apt then
        msg = msg .. "Set departure to " .. dep_apt.icao .. " " .. dep_apt.name .. "; "
    else
        msg = msg .. "Could not find " .. dep .. "; "
    end
    arr_apt = get_airport(arr)
    if arr_apt then
        msg = msg .. "Set arrival to " .. arr_apt.icao .. " " .. arr_apt.name .. "."
    else
        msg = msg .. "Could not find " .. arr .. "."
    end
    return msg
end

function ltscope_clear_icao()
    dep_apt = nil
    arr_apt = nil
    return "Cleared selection"
end

function latlon_to_xypx(ref_lat, ref_lon, lat, lon)
    -- Note: approximate, only for drawing!
    -- https://blog.mapbox.com/fast-geodesic-approximations-with-cheap-ruler-106f229ad016
    local y = 10801 * (lat - ref_lat) / 180 * pix_per_nm
    local x = 21638 * (lon - ref_lon) / 360 * math.cos(math.rad(ref_lat)) * pix_per_nm
    return x, y
end

function draw_scope()
    if not scope_enabled then
        return
    end
    local vector_length = 60.0 -- seconds
    local scope_alpha = 0.3
    local marker_size = 4 -- px
    local label_length = 50 -- px
    local player_lat = get("sim/flightmodel/position/latitude")
    local player_lon = get("sim/flightmodel/position/longitude")
    local ref_lat = player_lat -- TODO set player position
    local ref_lon = player_lon
    local xc = SCREEN_WIDTH / 2
    local yc = SCREEN_HIGHT / 2
    -- Select closest airport (departure or arrival)
    local scope_apt = nil
    local dep_dist2 = 99999
    if dep_apt then
        scope_apt = dep_apt
        local x, y = latlon_to_xypx(dep_apt.lat, dep_apt.lon, player_lat, player_lon)
        dep_dist2 = x*x + y*y
    end
    if arr_apt then
        local x, y = latlon_to_xypx(dep_apt.lat, dep_apt.lon, player_lat, player_lon)
        local arr_dist2 = x*x + y*y
        if arr_dist2 < 3 * dep_dist2 then
            scope_apt = arr_apt
        end
    end
    -- Update resolution
    if scope_apt then
        ref_lat = scope_apt.lat
        ref_lon = scope_apt.lon
    end
    scope_range = 0 -- nm
    repeat
        scope_range = scope_range + 30 -- nm
        pix_per_nm = SCREEN_HIGHT / (2 * scope_range)
        local x, y = latlon_to_xypx(ref_lat, ref_lon, player_lat, player_lon)
    until math.sqrt(x*x + y*y) < (SCREEN_HIGHT / 3.5)
    -- Draw scope background
    -- glColor4f(0, 0, 0.5, scope_alpha)
    glColor4f(0, 0, 0, scope_alpha)
    glRectf(0, 0, SCREEN_WIDTH, SCREEN_HIGHT)
    glColor4f(1.0, 1.0, 1.0, 1.0)
    if scope_apt then
        local y = SCREEN_HIGHT - 60
        local skipped_first = false
        draw_string_Helvetica_18(xc - yc, y, scope_apt.icao .. " " .. scope_apt.name)
        if scope_apt.metar then
            for metar_i in string.gmatch(scope_apt.metar, "%S+") do
                y = y - 20
                if not skipped_first then
                    skipped_first = true
                else
                    draw_string_Helvetica_18(xc - yc, y, metar_i)
                end
            end
        end
    else
        draw_string_Helvetica_18(xc - yc, SCREEN_HIGHT - 60, "<No airport selected>")
    end
    -- Draw range rings
    glColor4f(0.5, 0.5, 1.0, scope_alpha)
    for r = 5, scope_range, 5 do
        graphics.draw_circle(xc, yc, r * pix_per_nm)
    end
    -- Draw runways
    if scope_apt then
        glColor4f(1.0, 1.0, 1.0, scope_alpha)
        graphics.set_width(5)
        for i = 1,#scope_apt.runways do
            local x1, y1 = latlon_to_xypx(ref_lat, ref_lon, scope_apt.runways[i].lat1, scope_apt.runways[i].lon1)
            local x2, y2 = latlon_to_xypx(ref_lat, ref_lon, scope_apt.runways[i].lat2, scope_apt.runways[i].lon2)
            graphics.draw_line(xc + x1, yc + y1, xc + x2, yc + y2)
        end
        graphics.set_width(1)
    end
    -- Draw player aircraft
    local x, y = latlon_to_xypx(ref_lat, ref_lon, player_lat, player_lon)
    glColor4f(0.0, 1.0, 0.0, 1.0)
    glRectf(xc + x - marker_size, yc + y - marker_size, xc + x + marker_size, yc + y + marker_size)
    local trk = get("sim/flightmodel/position/hpath")
    local spd = get("sim/flightmodel/position/groundspeed") * 1.944 -- kt
    local alt = get("sim/flightmodel/position/elevation") * 3.2808 -- ft
    local vspd = get("sim/flightmodel/position/vh_ind_fpm") -- ft/min
    local dx = spd * math.sin(math.rad(trk)) / 3600 * vector_length * pix_per_nm
    local dy = spd * math.cos(math.rad(trk)) / 3600 * vector_length * pix_per_nm
    graphics.draw_line(xc + x, yc + y, xc + x + dx, yc + y + dy)
    -- Draw label
    dx = label_length * math.sin(math.rad(trk + 90))
    dy = label_length * math.cos(math.rad(trk + 90))
    if spd < 1 then -- stop wobbling because of wind...
        dx = 0
        dy = -label_length
    end
    local lbl_str = tostring(math.floor(alt / 100 + 0.5))
    if vspd > 200 then
        lbl_str = lbl_str .. "^"
    elseif vspd < -200 then
        lbl_str = lbl_str .. "v"
    else
        lbl_str = lbl_str .. "-"
    end
    lbl_str = lbl_str .. " " .. tostring(math.floor(spd / 10 + 0.5))
    draw_string_Helvetica_12(xc + x + dx, yc + y + dy, lbl_str)
    -- Draw label line
    glColor4f(1.0, 1.0, 1.0, scope_alpha)
    graphics.draw_line(xc + x, yc + y, xc + x + dx, yc + y + dy)
    -- Draw livetraffic aircraft
    local player_alt = get("sim/flightmodel/position/elevation") * 3.2808 -- ft
    local num = get("livetraffic/ac/num")
    for i = 1,num do
        set("livetraffic/ac/key", i) -- Select aircraft by index
        local lat = get("livetraffic/ac/lat")
        local lon = get("livetraffic/ac/lon")
        local trk = get("livetraffic/ac/heading")
        local spd = get("livetraffic/ac/speed") -- knots?
        local active = get("livetraffic/ac/lights/strobe")
        local phase = get("livetraffic/ac/phase")
        local alt = get("livetraffic/ac/height") -- ft
        local vspd = get("livetraffic/ac/vsi") -- ft/min?
        -- Draw marker
        local x, y = latlon_to_xypx(ref_lat, ref_lon, lat, lon)
        if active > 0 and math.abs(alt - player_alt) < 10000 then
            glColor4f(1.0, 1.0, 1.0, 1.0)
        else
            glColor4f(1.0, 1.0, 1.0, scope_alpha)
        end
        glRectf(xc + x - marker_size, yc + y - marker_size, xc + x + marker_size, yc + y + marker_size)
        local dx = spd * math.sin(math.rad(trk)) / 3600 * vector_length * pix_per_nm
        local dy = spd * math.cos(math.rad(trk)) / 3600 * vector_length * pix_per_nm
        graphics.draw_line(xc + x, yc + y, xc + x + dx, yc + y + dy)
        -- Draw label
        if active > 0 then
            dx = label_length * math.sin(math.rad(trk + 90))
            dy = label_length * math.cos(math.rad(trk + 90))
            local lbl_str = tostring(math.floor(alt / 100 + 0.5))
            if vspd > 200 then
                lbl_str = lbl_str .. "^"
            elseif vspd < -200 then
                lbl_str = lbl_str .. "v"
            else
                lbl_str = lbl_str .. "-"
            end
            lbl_str = lbl_str .. " " .. tostring(math.floor(spd / 10 + 0.5))
            draw_string_Helvetica_12(xc + x + dx, yc + y + dy, lbl_str)
            -- Draw label line
            glColor4f(1.0, 1.0, 1.0, scope_alpha)
            graphics.draw_line(xc + x, yc + y, xc + x + dx, yc + y + dy)
        end
        -- Draw separation marker
        if phase >= 60 and phase < 70 then
            -- on approach
            local approach_sep_nm = 5.0
            local dx = -approach_sep_nm * math.sin(math.rad(trk)) * pix_per_nm
            local dy = -approach_sep_nm * math.cos(math.rad(trk)) * pix_per_nm
            glColor4f(0.5, 0.5, 1.0, (scope_alpha + 1.0) / 2)
            glRectf(xc + x + dx - marker_size, yc + y + dy - marker_size, xc + x + dx + marker_size, yc + y + dy + marker_size)
        end
    end
end
do_every_draw("draw_scope()")


------------------------------------------------------------------
-- Hide/show scope
------------------------------------------------------------------
add_macro("LiveTraffic Scope - Toggle", "ltscope_toggle()")
create_command("ltscope/toggle", "Toggle LiveTraffic Scope", "ltscope_toggle()", "", "")


------------------------------------------------------------------
-- Select airport window
------------------------------------------------------------------
local wnd_select = nil
local wnd_dep_icao = ""
local wnd_arr_icao = ""
local wnd_select_result_msg = ""

function wnd_select_builder()
    local dep_changed, dep_newtxt = imgui.InputText("Departure Apt", wnd_dep_icao, 8)
    if dep_changed then
        wnd_dep_icao = dep_newtxt
    end
    local arr_changed, arr_newtxt = imgui.InputText("Arrival Apt", wnd_arr_icao, 8)
    if arr_changed then
        wnd_arr_icao = arr_newtxt
    end
    imgui.SameLine()
    if imgui.Button("Set") then
        wnd_select_result_msg = ltscope_set_icao(string.upper(wnd_dep_icao), string.upper(wnd_arr_icao))
    end
    imgui.SameLine()
    if imgui.Button("Clear") then
        wnd_select_result_msg = ltscope_clear_icao()
    end
    imgui.TextUnformatted(wnd_select_result_msg)
end

function wnd_select_close()
    wnd_select = nil
end

function ltscope_select_airport()
    if wnd_select == nil then
        wnd_select_icao = ""
        wnd_select = float_wnd_create(520, 80, 1, true)
        float_wnd_set_title(wnd_select, "LiveTraffic Scope - Select airport...")
        float_wnd_set_imgui_builder(wnd_select, "wnd_select_builder")
        float_wnd_set_onclose(wnd_select, "wnd_select_close")
    end
end
add_macro("LiveTraffic Scope - Select airport...", "ltscope_select_airport()")
create_command("ltscope/select_ap", "LiveTraffic Scope Select airport", "ltscope_select_airport()", "", "")

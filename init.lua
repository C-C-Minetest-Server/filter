--[[
    Copyright (c) 2017-2018 Auke Kok <sofar@foo-projects.org>
    Copyright (c) 2018 rubenwardy <rw@rubenwardy.com>
    Copyright (c) 2023 1F616EMO <root@1f616emo.xyz>

    This mod is licensed under the conditions of the MIT License. 
    See LICENSE.txt for the license text.
]]

local WP = minetest.get_worldpath()
local S = minetest.get_translator("filter")
local F = minetest.formspec_escape
local MS = minetest.get_mod_storage()
filter = {
    registered_on_violations = {},
    words_list = {},
    muted_until = {},
    violations = {}
}


local function remove_duplications(t)
    local tmp_table = {}
    for i,v in ipairs(t) do
        tmp_table[v] = true
    end
    local rtn_table = {}
    for k,v in pairs(tmp_table) do
        if v then table.insert(rtn_table,k) end
    end
    return rtn_table
end

local last_table_hash = 0
function filter.import_file(filepath)
    local file = io.open(filepath, "r")
	if file then
		for line in file:lines() do
			line = line:trim()
			if line ~= "" then
				filter.words_list[#filter.words_list + 1] = line
			end
		end
        file:close()
        filter.words_list = remove_duplications(filter.words_list)
		return true
	else
		return false
	end
end

-- Load and migration
do
    local status = filter.import_file(WP .. "/filters.txt")
    if not status then
        minetest.log("warning", "[filter] Failed to load filters.txt. Tring to load old data from mod storage.")
        local sw = MS:get_string("words")
        if sw and sw ~= "" then
            local words = minetest.parse_json(sw)
            for _,v in ipairs(words) do
                filter.words_list[#filter.words_list + 1] = v
            end
            filter.words_list = remove_duplications(filter.words_list)
        end
    end
end

-- Save the list of filters
-- This shoudl not be called by any other mods.
function filter.save()
    minetest.log("action", "[filter] Saving filter words list.")
    local file_content = ""
    for _,w in ipairs(filter.words_list) do
        file_content = file_content .. w .. "\n"
    end
    minetest.safe_file_write(WP .. "/filters.txt", file_content)
end

local function save_loop()
    filter.save()
    minetest.after(60,save_loop)
end

minetest.after(60,save_loop)
minetest.register_on_shutdown(filter.save)

-- func(name, message, violated)
-- name: Name of the player
-- message: The message which violated the filter
-- violated: Number of violations done. It is reset after 10 minutes of last violation.
function filter.register_on_violation(func)
	table.insert(filter.registered_on_violations, func)
end

-- Check whether a message had violated the filters
-- Return false for a violated one, and true for a good one.
function filter.check_message(name,message)
    for _, w in ipairs(filter.words_list) do
        if string.sub(w,1,2) == "f+" then -- "f+" prefix to make it a Lua pattern
            w = string.sub(w,3)
        else
            w = string.gsub(w, "%p", "%%%1") -- escape special charactors for string.find
        end
        if string.find(message:lower(), w) then
            return false
        end
	end
    return true
end

local function restore_warning(name)
    if not filter.muted_until[name] then return end
    minetest.chat_send_player(name, S("Chat privilege reinstated. Please do not abuse chat."))
end

-- Mute a player in the filter system
-- This mod monitors all the chat messages and block those sent by players who are still being muted.
-- This mod also checks for chat commands using the "shout" privilege, block the use by those who are muted, and check its parameters.
function filter.mute(name, duration)
    minetest.chat_send_player(name, S("Watch your language! You have been temporarily muted)"))
    filter.muted_until[name] = os.time() + (duration * 60)
    minetest.after(duration * 60,restore_warning,name)
end

minetest.register_on_leaveplayer(function(ObjectRef, timed_out)
    local name = ObjectRef:get_player_name()
    filter.muted_until[name] = nil
end)

-- Show the warning formspec to a specific player
-- If filter.rules_backend had been defined, a "Show Rules" button will be shown.
function filter.show_warning_formspec(name)
    local formspec = "size[7,3]bgcolor[#080808BB;true]" .. 
		"image[0,0;2,2;filter_warning.png]" ..
		"label[2.3,0.5;" ..  F(S("Please watch your language!")) .."]"

    if filter.rules_backend then
        formspec = formspec .. 
				"button[0.5,2.1;3,1;rules;" .. F(S("Show Rules")) .. "]" ..
				"button_exit[3.5,2.1;3,1;close;" .. F(S("Okay")) .. "]"
	else
		formspec = formspec .. 
				"button_exit[2,2.1;3,1;close;" .. F(S("Okay")) .. "]"
    end
    minetest.show_formspec(name, "filter:warning", formspec)
end

minetest.register_on_player_receive_fields(function(player, formname, fields)
    -- filter.rules_backend should be defined by another mod. It should show the server rules to the player
    -- player is a ObjectRef of the player.
    if filter.rules_backend and formname == "filter:warning" and fields.rules then
        filter.rules_backend(player)
    end
end)

local function settings_get_int(key,default)
    local val = tonumber(minetest.settings:get(key))
    return (val or default)
end

-- Executed when a player had violated the filter.
function filter.on_violation(name, message)
    if not filter.violations[name] then
        filter.violations[name] = {
            violated = 0
        }
    end

    filter.violations[name].last_violation = os.time()
    filter.violations[name].violated = filter.violations[name].violated + 1
    local violated = filter.violations[name].violated

    local resolution
    for _, cb in ipairs(filter.registered_on_violations) do
        if cb(name, message, violated) then
            resolution = "custom"
        end
    end

    if not resolution then
        if violated <= settings_get_int("filter.max_violations_before_mute",1) then
            resolution = "warned"
            filter.show_warning_formspec(name)
        elseif violated <= settings_get_int("filter.max_violations_before_kick",3) then
            resolution = "muted"
            filter.mute(name,settings_get_int("filter.mute_duration",1))
        else
            resolution = "kicked"
            minetest.kick_player(name, "Please mind your language!")
        end
    end

    minetest.log("action",string.format("[filter] Player %s violated the filter by this message: \"%s\". %s",name,message,resolution))
end

local function violation_loop()
    local now = os.time()
    for x,y in pairs(filter.violations) do
        if (y.last_violation + ( 10 * 60 )) >= now then
            filter.violations[x] = nil
        end
    end
    minetest.after(30, violation_loop)
end

minetest.after(30, violation_loop)

minetest.register_on_mods_loaded(function()
    -- Check chat messages
    table.insert(minetest.registered_on_chat_messages, 1, function(name,message)
        if message:sub(1, 1) == "/" then
            return
        end

        if filter.muted_until[name] then
            local now = os.time()
            if filter.muted_until[name] > now then
                local time_left = filter.muted_until[name] - now
                minetest.chat_send_player(name, S("@1 seconds before unmute, Remember not to about chat.",time_left))
                return true
            else
                filter.muted_until[name] = nil
            end
        end

        if not filter.check_message(name, message) then
            filter.on_violation(name, message)
            return true
        end
    end)

    table.insert(minetest.registered_on_chatcommands, 1, function(name, command, params)
        do
            local cmd = minetest.registered_chatcommands[command]
            if not (cmd and cmd.privs and cmd.privs.shout) then return false end
        end
        if filter.muted_until[name] then
            local now = os.time()
            if filter.muted_until[name] > now then
                local time_left = filter.muted_until[name] - now
                minetest.chat_send_player(name,S("@1 seconds before unmute, Remember not to about chat.",time_left))
                return true -- Handled
            end
        end

        if not filter.check_message(name, params) then
            filter.on_violation(name, params)
            return true -- Handled
        end

        return false -- Leave everything back to the engine
    end)
end)

-- Chatcommand
local cmd = chatcmdbuilder.register("filter", {
    description = S("Manage swear word filter"),
    privs = { server = true },
    params = "list | ((add | remove) <keyword>)",
})

cmd:sub("list", function(name)
    return true, S("@1 words: @2", #filter.words_list, table.concat(filter.words_list, ", "))
end)

cmd:sub("add :keyword:word",function(name,keyword)
    for _,v in ipairs(filter.words_list) do
        if v == keyword then
            return false, S("Duplication of \"@1\" found in the list of filters.", keyword)
        end
    end
    table.insert(filter.words_list, keyword)
    return true, S("Added \"@1\" from the list of filters.", keyword)
end)

cmd:sub("remove :keyword:word", function(name,keyword)
    -- We have to iterate the reverse to workaround the impact of renumbering
    local removed = false
    local i = #filter.words_list
    repeat
        if filter.words_list[i] == keyword then
            table.remove(filter.words_list,i)
            return true, S("Removed \"@1\" from the list of filters.", keyword)
        end
        i = i - 1
    until i <= 0
    return false, S("\"@1\" not found in the list of filters.", keyword)
end)

minetest.register_chatcommand("test_filter", {
    description = S("Test the swear filter with a given prompt"),
    params = "<prompt>",
    func = function(name,param)
        local status = filter.check_message(name,param)
        if not status then
            return true, S("TThe message \"@1\" violates the filter. Do not speak it in the chatroom.",param)
        else
            return true, S("It's OK to say \"@1\" in the chatroom.",param)
        end
    end
})
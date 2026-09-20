_G.partnersAPI = {}

partnersAPI.partnerActs = partnerActs
partnersAPI.eventHooks = eventHooks

---@param charNum1 integer
---@param charNum2 integer
--- Registers two characters as an 'exclusive' duo, being automatically partnered and using one slot in the CS menu.
function partnersAPI.register_duo(charNum1, charNum2)
    gPartnerData[charNum1] = gPartnerData[charNum1] or {}
    gPartnerData[charNum2] = gPartnerData[charNum2] or {}

    gPartnerData[charNum1].partnerNum = charNum2
    gPartnerData[charNum2].partnerNum = charNum1

    charSelect.character_set_locked(charNum2, false, false)
end

function partnersAPI.set_cutscene_anim(charNum, leaderCharNum)

end

function partnersAPI.set_cutscene_anim_offset(charNum, animID, sideOffset)
    gPartnerData[charNum] = gPartnerData[charNum] or {}
    gPartnerData[charNum].animOffsets = gPartnerData[charNum].animOffsets or {}

    gPartnerData[charNum].animOffsets[animID] = sideOffset
end

---@param func fun(o:Object,m:MarioState) The action loop function. passes the Object and parent MarioState as params
---@return integer
--- Hook a custom action for partner objects. use `partnersAPI.set_partner_action()` to use your custom action.
function partnersAPI.hook_partner_action(func)
    local actId = #partnerActTable + 1
    partnerActTable[actId] = func

    return actId
end

---@param eventHook integer
---@param func function
--- Hook a function to run during certain mod events. See `partnersAPI.eventHooks`
function partnersAPI.hook_partner_event(eventHook, func)
    if not hookedFunctions[eventHook] then
        hookedFunctions[eventHook] = {}
    end
    table.insert(hookedFunctions[eventHook], func)
end

---@param behaviorId BehaviorId
---@param func fun(o:Object,o2:Object,m:MarioState) Function called on interaction
--- Hook a function to run when a partner object interacts with a given behavior ID.
function partnersAPI.hook_partner_interaction(behaviorId, func)
    if partnerIntTable[behaviorId] then
        local originalFunc = partnerIntTable[behaviorId]
        partnerIntTable[behaviorId] = function(...)
            originalFunc(...)
            func(...)
        end
    else
        partnerIntTable[behaviorId] = func
    end
end

---@param o Object
function partnersAPI.is_local_partner(o)
    return o.oBehParams == network_global_index_from_local(0)
end

partnersAPI.set_partner_action = set_partner_action
partnersAPI.partner_jump = partner_jump
partnersAPI.partner_physics_step = partner_step
partnersAPI.get_local_partner = get_local_partner

partnersAPI.set_partner_animation = charObjs.character_obj_set_animation
partnersAPI.get_partner_model_data = charObjs.character_obj_get_model_data


-- make read-only
setmetatable(partnersAPI, {
    __newindex = function(_, k, _)
        error('Attempting to modify key `' .. k .. '` of read-only table')
    end
})
setmetatable(partnerActs, {
    __newindex = function(_, k, _)
        error('Attempting to modify key `' .. k .. '` of read-only table')
    end
})
setmetatable(eventHooks, {
    __newindex = function(_, k, _)
        error('Attempting to modify key `' .. k .. '` of read-only table')
    end
})
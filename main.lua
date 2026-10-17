-- name: Partners [WIP]
-- description: Duo partner system + API ! \n\\#b0b0b0\\[requires \\#ffff80\\Character Select\\#b0b0b0\\!] \n\n \\#d0a0f0\\-wibblus

if not charSelectExists then return end

charObjs = require("libs/charObjs")

---@class Object
---@field oPartnerJumpState integer
---@field oPartnerJumpQueue integer
---@field oPartnerTorsoPitch integer
---@field oPartnerTorsoRoll integer
---@field oPartnerSquishTimer integer

define_custom_obj_fields({
    oIsChar = "u32",
    oCharNum = "u32",
    oCharAlt = "u32",
    oCharPalette = "u32",
    oCharAnim = "u32",
    oPartnerJumpState = "u32",
    oPartnerJumpQueue = "u32",
    oPartnerTorsoPitch = "s32",
    oPartnerTorsoRoll = "s32",
    oPartnerSquishTimer = "u32",
})

-- TODO LIST !!!

-- sync CS menu animation for partners

gPartnerData = {}

--gActivePartners = {}
for i = 0, MAX_PLAYERS - 1 do
    --gActivePartners[i] = { active = false, leaderChar = CT_MARIO, partnerChar = CT_LUIGI }
    local p = gPlayerSyncTable[i]
    p.active = p.active or false
    p.leaderChar = p.leaderChar or CT_MARIO
    p.partnerChar = p.partnerChar or CT_LUIGI
end

local characterTable = charSelect.character_get_full_table()
-- table to record player palette presets, won't be needed once CS API is updated to handle this
local modelPalettePresets = {}

---@type Object?
local localPartnerObj
---@type MarioState
local curParentM

local floor, abs, s16, lerp, tween = math.floor, math.abs, math.s16, math.lerp, math.tween

partnerActs = {
    WARP = 0,
    IDLE = 1,
    WALKING = 2,
    AIRBORNE = 3,
    LAVA_BOUNCE = 4,
    CUTSCENE = 5,
    ATTACKED = 6,
    SQUISHED = 7,
    ENTER_LEVEL = 8,
    AUTO = 9,
}
eventHooks = {
    -- Called before a partner's action routine.
    -- Passes partner Object `o` and parent MarioState `m`
    PARTNER_BEFORE_UPDATE = 0,
    -- Called after a partner's action routine.
    -- Passes partner Object `o` and parent MarioState `m`
    PARTNER_UPDATE = 1,
    -- Called when a partner object is spawned.
    -- Passes partner Object `o` and parent MarioState `m`
    PARTNER_SPAWNED = 2,
    -- Called when a partner object is set to despawn at the end of the frame.
    -- Passes partner Object `o` and parent MarioState `m`
    PARTNER_DESPAWNED = 3,
    -- Called when the local player tries to swap the active leader, before the swap actually occurs. return `false` to cancel the swap.
    -- Passes the character IDs of the current leader and partner.
    TRY_SWAP_LEADER = 4,
    -- Called upon the local player swapping the active leader.
    -- Passes partner Object `o` and parent MarioState `m`
    ON_SWAP_LEADER = 5,
}

hookedFunctions = {}

local function call_event_hook(eventHook, ...)
    local returnValue
    local funcTable = hookedFunctions[eventHook]
    if funcTable then
        for _, func in ipairs(funcTable) do
            returnValue = func(...) or returnValue
        end
    end
    return returnValue
end

-- UTILS

local HEX_DIGITS = "0123456789ABCDEF"
---@return string
local function hex(num, digits)
    num = math.floor(num)
    digits = digits or 4
    local result = ""
    for i = 1, digits do
        local n = num % 16
        result = HEX_DIGITS:sub(n + 1, n + 1) .. result
        num = num >> 4
    end
    return "0x" .. result
end
---@return string
local function bin(num, digits)
    num = math.floor(num)
    digits = digits or 32
    local result = ""
    for i = 1, digits do
        result = (num & 1) .. result
        num = num >> 1
    end
    return result
end


---@return integer
local function obj_find_floor_slope(o)
    local x = sins(o.oMoveAngleYaw) * 5.0
    local z = coss(o.oMoveAngleYaw) * 5.0
    local forwardYDelta = find_floor_height(o.oPosX + x, o.oPosY + 100.0, o.oPosZ + z) - o.oPosY
    local backwardYDelta = o.oPosY - find_floor_height(o.oPosX - x, o.oPosY + 100.0, o.oPosZ - z)
    return abs(forwardYDelta) < abs(backwardYDelta) and
        atan2s(5.0, forwardYDelta / 2.0) or atan2s(5.0, backwardYDelta / 2.0)
end


-- INTERACTIONS

local function int_coin(o, o2, m)
    interact_coin(m, INTERACT_COIN, o2)
end

partnerIntTable = {
    [id_bhvOneCoin] = int_coin,
    [id_bhvYellowCoin] = int_coin,
    [id_bhvSingleCoinGetsSpawned] = int_coin,
    [id_bhvRedCoin] = int_coin,
    [id_bhvHiddenBlueCoin] = int_coin,
    [id_bhvMrIBlueCoin] = int_coin
}

---@param o Object
---@return Object?
local function process_obj_interactions(o)
    local o2 = obj_get_first(OBJ_LIST_LEVEL)

    while o2 do
        if o2.activeFlags == ACTIVE_FLAG_DEACTIVATED or o2.oIntangibleTimer ~= 0 then goto Pass end
        do
            local func = partnerIntTable[get_id_from_behavior(o2.behavior)]
            if func and obj_check_hitbox_overlap(o, o2) then
                --quick_debug_log("int" .. tostring(o2),
                --    "interacted with " .. get_behavior_name_from_id(get_id_from_behavior(o2.behavior)))
                func(o, o2, curParentM)
            end
        end

        ::Pass::
        o2 = obj_get_next(o2)
    end
end

local OBJ_MOVE_MASK_IN_AIR = OBJ_MOVE_IN_AIR | OBJ_MOVE_LEFT_GROUND

---@param o Object
function partner_step(o)
    cur_obj_compute_vel_xz()
    local intendedX = o.oPosX + o.oVelX
    local intendedZ = o.oPosZ + o.oVelZ

    local intendedFloorHeight = find_floor_height(intendedX, o.oPosY, intendedZ)
    local waterLevel = find_water_level(intendedX, intendedZ)

    local moveFlags = o.oMoveFlags

    if moveFlags & OBJ_MOVE_MASK_ON_GROUND ~= 0 then
        moveFlags = (moveFlags & ~OBJ_MOVE_LANDED) | OBJ_MOVE_ON_GROUND
        local deltaFloorHeight = intendedFloorHeight - o.oFloorHeight

        if abs(deltaFloorHeight) < 50.0 then
            o.oPosY = intendedFloorHeight
        else
            moveFlags = (moveFlags & ~OBJ_MOVE_ON_GROUND) | OBJ_MOVE_LEFT_GROUND
        end
        if o.oVelY > 0.0 then
            moveFlags = (moveFlags & ~OBJ_MOVE_ON_GROUND) | OBJ_MOVE_LEFT_GROUND
        end
    elseif moveFlags & OBJ_MOVE_MASK_IN_AIR ~= 0 then
        moveFlags = (moveFlags & ~OBJ_MOVE_LEFT_GROUND) | OBJ_MOVE_IN_AIR
        o.oVelY = max(-78.0, o.oVelY + o.oGravity)
        o.oPosY = o.oPosY + o.oVelY

        if o.oPosY <= intendedFloorHeight then
            o.oPosY = intendedFloorHeight
            moveFlags = (moveFlags & ~OBJ_MOVE_IN_AIR) | OBJ_MOVE_LANDED
        end
    elseif moveFlags & OBJ_MOVE_MASK_IN_WATER ~= 0 then
        moveFlags = (moveFlags & ~OBJ_MOVE_ENTERED_WATER) | OBJ_MOVE_UNDERWATER_OFF_GROUND
    else
        moveFlags = moveFlags | OBJ_MOVE_IN_AIR
    end

    o.oPosX = intendedX
    o.oPosZ = intendedZ
    o.oMoveFlags = moveFlags
end

---@param o Object
---@param act integer
---@param subAct integer?
function set_partner_action(o, act, subAct)
    if o.oAction ~= partnerActs.AIRBORNE then
        o.oPartnerJumpState = 0
    end
    o.oFaceAnglePitch = 0
    o.oFaceAngleRoll = 0
    o.oPartnerTorsoPitch = 0
    o.oPartnerTorsoRoll = 0

    o.oPrevAction = act
    o.oAction = act
    o.oSubAction = subAct or 0
    o.oTimer = 0
end

---@param o Object
function partner_jump(o)
    if o.oTimer < 6 then
        if o.oPartnerJumpState == 1 then
            o.oVelY = 52.0 + o.oForwardVel * 0.25
            o.oForwardVel = o.oForwardVel * 0.8
            set_partner_action(o, partnerActs.AIRBORNE, 2)

            charObjs.character_obj_play_sound(o, CHAR_SOUND_HOOHOO)
            return
        elseif o.oPartnerJumpState == 2 and o.oForwardVel > 20.0 then
            o.oVelY = 69.0
            o.oForwardVel = o.oForwardVel * 0.8
            set_partner_action(o, partnerActs.AIRBORNE, 3)

            charObjs.character_obj_play_sound(o, CHAR_SOUND_YAHOO_WAHA_YIPPEE)
            return
        end
    end

    o.oVelY = 42.0 + o.oForwardVel * 0.25
    o.oForwardVel = o.oForwardVel * 0.8
    set_partner_action(o, partnerActs.AIRBORNE, 1)

    charObjs.character_obj_play_sound(o, CHAR_SOUND_YAH_WAH_HOO)
end

-- BEHAVIOR


---@param o Object
local function bhv_partner_init(o)
    o.oFlags = OBJ_FLAG_UPDATE_GFX_POS_AND_ANGLE | OBJ_FLAG_SET_FACE_YAW_TO_MOVE_YAW

    local oh = characterTable[o.oCharNum].overrideHitbox or {}

    o.hitboxRadius = oh.radius or 37.0
    o.hitboxHeight = oh.height or 160.0
    o.hurtboxRadius = o.hitboxRadius + 40.0
    o.hurtboxHeight = o.hitboxHeight

    o.oWallHitboxRadius = 50.0

    o.oGravity = -4.0
    o.oBounciness = 0.0
    o.oBuoyancy = 0.0

    charObjs.character_obj_set_animation(o, CHAR_ANIM_GENERAL_FALL)
    o.oIsChar = 1
    o.header.gfx.sharedChild.hookProcess = 1

    set_partner_action(o, partnerActs.WARP)

    network_init_object(o, true,
        { "oCharNum", "oCharAlt", "oCharPalette", "oPartnerJumpState", "oPartnerJumpQueue", "oPartnerSquishTimer",
            "oBooTargetOpacity" })

    call_event_hook(eventHooks.PARTNER_SPAWNED, o, gMarioStates[network_local_index_from_global(o.oBehParams)])
end

---@param o Object
---@param m MarioState
local function partner_act_warp(o, m)
    if o.oSubAction == 0 then
        o.oIntangibleTimer = -1
        o.oBooTargetOpacity = 0x00
        if o.oOpacity <= 0x00 then
            o.oSubAction = 1
        end
        return
    end

    if PARTNER_ACT_TRIGGERS[m.action] then
        PARTNER_ACT_TRIGGERS[m.action](o)
        o.oBooTargetOpacity = 0xFF
    end

    local offsetAngle = m.faceAngle.y
    for i = 1, 16 do
        o.oPosX = m.pos.x - sins(offsetAngle) * 150.0
        o.oPosZ = m.pos.z - coss(offsetAngle) * 150.0
        o.oPosY = find_floor_height(o.oPosX, m.pos.y + 200.0, o.oPosZ)
        if o.oPosY - m.pos.y > -200.0 then
            break
        end

        if i == 16 then
            return
        end
        offsetAngle = s16(offsetAngle + 0x1000)
    end

    o.oMoveAngleYaw = m.faceAngle.y
    o.oForwardVel = 0.0
    o.oVelY = 0.0

    charObjs.character_obj_set_animation(o, CHAR_ANIM_GENERAL_FALL)
    o.oIntangibleTimer = 0
    o.oBooTargetOpacity = 0xFF
    set_partner_action(o, partnerActs.AIRBORNE, 0)
    partner_step(o)
end

local IDLE_ANIMS = { CHAR_ANIM_IDLE_HEAD_LEFT, CHAR_ANIM_IDLE_HEAD_RIGHT, CHAR_ANIM_IDLE_HEAD_CENTER }

---@param o Object
---@param m MarioState
local function partner_act_idle(o, m)
    o.oForwardVel = 0.0
    o.oVelY = 0.0

    partner_step(o)

    if find_ceil_height(o.oPosX, o.oPosY + o.hitboxHeight, o.oPosZ) < o.oPosY + o.hitboxHeight then
        return set_partner_action(o, partnerActs.SQUISHED)
    end

    if o.oDistanceToMario > 300.0 or (m.forwardVel > 16.0 and o.oDistanceToMario > 150.0) then
        o.oMoveAngleYaw = obj_angle_to_point(o, m.pos.x, m.pos.z)
        return set_partner_action(o, partnerActs.WALKING)
    end

    if o.oSubAction < 4 then
        local deltaY = m.pos.y - o.oPosY
        if math.abs(deltaY) < 500.0 then
            local animInfo = o.header.gfx.animInfo
            if not animInfo.curAnim or (cur_obj_check_if_at_animation_end() ~= 0 and animInfo.curAnim.flags & ANIM_FLAG_NOLOOP ~= 0) then
                o.oSubAction = o.oSubAction % 3 + 1
                charObjs.character_obj_set_animation(o, IDLE_ANIMS[o.oSubAction])
            end
        else
            o.oSubAction = 0
            charObjs.character_obj_set_animation(o, CHAR_ANIM_FIRST_PERSON)

            if o.oTimer > 30 then
                return set_partner_action(o, partnerActs.WARP)
            end
        end

        if m.action == ACT_CROUCHING then
            o.oSubAction = 4
        end
    else
        if o.oSubAction == 4 then
            charObjs.character_obj_set_animation(o, CHAR_ANIM_START_CROUCHING)
            if cur_obj_check_if_near_animation_end() ~= 0 then o.oSubAction = 5 end
        elseif o.oSubAction == 5 then
            charObjs.character_obj_set_animation(o, CHAR_ANIM_CROUCHING)
            if m.action & ACT_FLAG_SHORT_HITBOX == 0 then o.oSubAction = 6 end
        elseif o.oSubAction == 6 then
            charObjs.character_obj_set_animation(o, CHAR_ANIM_STOP_CROUCHING)
            if cur_obj_check_if_near_animation_end() ~= 0 then o.oSubAction = 0 end
        end
    end

    if o.oPartnerJumpQueue == 1 then -- jump
        play_sound(SOUND_ACTION_TERRAIN_JUMP + m.terrainSoundAddend, o.header.gfx.cameraToObject)
        o.oPartnerJumpQueue = 0

        if o.oSubAction > 4 then
            charObjs.character_obj_play_sound(o, CHAR_SOUND_YAH_WAH_HOO)

            o.oVelY = 62.0
            o.oForwardVel = -16.0
            return set_partner_action(o, partnerActs.AIRBORNE, 5)
        end
        if m.action == ACT_LONG_JUMP and o.oPartnerJumpState == 4 then
            charObjs.character_obj_play_sound(o, CHAR_SOUND_YAHOO)

            o.oVelY = 30.0
            o.oForwardVel = o.oForwardVel * 1.5
            return set_partner_action(o, partnerActs.AIRBORNE, 4)
        end
        o.oMoveAngleYaw = approach_s16_symmetric(o.oMoveAngleYaw, m.faceAngle.y, 0x1000)
        return partner_jump(o)
    end

    if o.oMoveFlags & OBJ_MOVE_MASK_IN_AIR ~= 0 then
        return set_partner_action(o, partnerActs.AIRBORNE)
    end
end

---@param o Object
---@param m MarioState
local function partner_act_walking(o, m)
    local angleTo = obj_angle_to_point(o, m.pos.x, m.pos.z)
    local targetSpeed

    if o.oDistanceToMario < 400.0 then
        targetSpeed = clamp((m.forwardVel > 8.0) and m.forwardVel or o.oForwardVel, 8.0, 24.0)

        if o.oDistanceToMario < 150.0 and m.forwardVel < 8.0 then
            targetSpeed = 0.0
        end
    elseif o.oDistanceToMario < 1600.0 then
        targetSpeed = 32.0
    else
        targetSpeed = 40.0
    end

    o.oForwardVel = approach_f32(o.oForwardVel, targetSpeed, 1.5,
        (targetSpeed > 4.0 and targetSpeed < 32.0) and 1.5 or 3.0)
    o.oMoveAngleYaw = approach_s16_asymptotic(o.oMoveAngleYaw, angleTo, 8)

    partner_step(o)

    if find_ceil_height(o.oPosX, o.oPosY + o.hitboxHeight, o.oPosZ) < o.oPosY + o.hitboxHeight then
        return set_partner_action(o, partnerActs.SQUISHED)
    end

    if o.oPartnerJumpQueue == 1 then -- jump
        play_sound(SOUND_ACTION_TERRAIN_JUMP + m.terrainSoundAddend, o.header.gfx.cameraToObject)
        o.oPartnerJumpQueue = 0

        o.oMoveAngleYaw = approach_s16_symmetric(o.oMoveAngleYaw, m.faceAngle.y, 0x1000)
        if m.action == ACT_LONG_JUMP then
            charObjs.character_obj_play_sound(o, CHAR_SOUND_YAHOO)
            o.oVelY = 30.0
            o.oForwardVel = o.oForwardVel * 1.5
            return set_partner_action(o, partnerActs.AIRBORNE, 4)
        end
        return partner_jump(o)
    end

    local slopePitch = obj_find_floor_slope(o)

    local detectLength = o.oForwardVel * 8.0
    local hit = collision_find_surface_on_ray(o.oPosX, o.oPosY + 50.0, o.oPosZ, sins(angleTo) * detectLength,
        -sins(slopePitch) * detectLength, coss(angleTo) * detectLength)

    if hit and hit.surface and hit.surface.normal.y < 0.1 then
        local ledgeHeight = find_floor_height(hit.hitPos.x - hit.surface.normal.x * 32.0, hit.hitPos.y + 300.0,
            hit.hitPos.z - hit.surface.normal.z * 32.0)
        if ledgeHeight - o.oPosY > -200.0 then
            return partner_jump(o)
        end
    end

    if o.oMoveFlags & OBJ_MOVE_HIT_WALL ~= 0 then
        o.oForwardVel = min(o.oForwardVel, 16.0)
    end

    if o.oMoveFlags & OBJ_MOVE_LEFT_GROUND ~= 0 then
        if o.oPosY < m.pos.y + 200.0 then
            return partner_jump(o)
        end

        return set_partner_action(o, partnerActs.AIRBORNE)
    end

    local speedForAnim = max(2.0, (targetSpeed > o.oForwardVel) and targetSpeed or o.oForwardVel)
    local accel = floor(max(4.0, speedForAnim / 4.0 * 0x10000))

    while true do
        if o.oSubAction == 0 then
            if speedForAnim > 22.0 then
                o.oSubAction = 1
            else
                charObjs.character_obj_set_animation(o, CHAR_ANIM_WALKING, accel)

                o.oPartnerTorsoPitch = approach_s16_symmetric(o.oPartnerTorsoPitch,
                    clamp(s16(o.oForwardVel * 170.0), 0, 0x1555), 0x400)
                o.oPartnerTorsoRoll = approach_s16_symmetric(o.oPartnerTorsoRoll,
                    clamp(s16(-(o.oMoveAngleYaw - o.oFaceAngleYaw) * o.oForwardVel / 12.0), -0x1555, 0x1555), 0x400)

                o.oFaceAnglePitch = 0

                break
            end
        elseif o.oSubAction == 1 then
            if targetSpeed == 0.0 then
                o.oSubAction = 2
            elseif speedForAnim < 18.0 then
                o.oSubAction = 0
            else
                charObjs.character_obj_set_animation(o, CHAR_ANIM_RUNNING, accel)

                o.oPartnerTorsoPitch = approach_s16_symmetric(o.oPartnerTorsoPitch,
                    clamp(s16(o.oForwardVel * 170.0), 0, 0x1555), 0x400)
                o.oPartnerTorsoRoll = approach_s16_symmetric(o.oPartnerTorsoRoll,
                    clamp(s16(-(o.oMoveAngleYaw - o.oFaceAngleYaw) * o.oForwardVel / 12.0), -0x1555, 0x1555), 0x400)

                o.oFaceAnglePitch = approach_s16_symmetric(o.oFaceAnglePitch,
                    s16(slopePitch * o.oForwardVel / 40.0), 0x800)
                break
            end
        elseif o.oSubAction == 2 then
            if targetSpeed > 5.0 then
                o.oSubAction = 0
            else
                charObjs.character_obj_set_animation(o, CHAR_ANIM_STOP_SKID)

                o.oPartnerTorsoPitch = 0
                o.oPartnerTorsoRoll = 0
                o.oFaceAnglePitch = 0

                break
            end
        end
    end

    if targetSpeed <= 0.0 and o.oForwardVel < 1.0 then
        if o.oSubAction ~= 2 then
            charObjs.character_obj_set_animation(o, CHAR_ANIM_IDLE_HEAD_LEFT)
        end
        set_partner_action(o, partnerActs.IDLE)
    end
end

local AIR_ANIMS = {
    [0] = { CHAR_ANIM_GENERAL_FALL, CHAR_ANIM_GENERAL_FALL, CHAR_ANIM_GENERAL_LAND },
    { CHAR_ANIM_SINGLE_JUMP,      CHAR_ANIM_SINGLE_JUMP,      CHAR_ANIM_LAND_FROM_SINGLE_JUMP },
    { CHAR_ANIM_DOUBLE_JUMP_RISE, CHAR_ANIM_DOUBLE_JUMP_FALL, CHAR_ANIM_LAND_FROM_DOUBLE_JUMP },
    { CHAR_ANIM_TRIPLE_JUMP,      CHAR_ANIM_TRIPLE_JUMP,      CHAR_ANIM_TRIPLE_JUMP_LAND },
    { CHAR_ANIM_FAST_LONGJUMP,    CHAR_ANIM_FAST_LONGJUMP,    CHAR_ANIM_CROUCH_FROM_FAST_LONGJUMP },
    { CHAR_ANIM_BACKFLIP,         CHAR_ANIM_BACKFLIP,         CHAR_ANIM_TRIPLE_JUMP_LAND },
}

---@param o Object
---@param m MarioState
local function partner_act_airborne(o, m)
    local angleTo = obj_angle_to_point(o, m.pos.x, m.pos.z)

    local sidewaysSpeed = 0.0
    o.oForwardVel = approach_f32_symmetric(o.oForwardVel, 0.0, 0.35)

    if o.oDistanceToMario > 300.0 or (o.oVelY > 0.0 and o.oDistanceToMario > 100.0) then
        local intendedDYaw = angleTo - o.oMoveAngleYaw
        o.oForwardVel = o.oForwardVel + coss(intendedDYaw) * 1.5
        sidewaysSpeed = sins(intendedDYaw) * 10.0
    end

    if o.oForwardVel > 32.0 then
        o.oForwardVel = o.oForwardVel - 0.95
    end
    if o.oForwardVel < -16.0 then
        o.oForwardVel = o.oForwardVel + 2.0
    end

    local sideYaw = o.oMoveAngleYaw + 0x4000
    o.oPosX = o.oPosX + sidewaysSpeed * sins(sideYaw)
    o.oPosZ = o.oPosZ + sidewaysSpeed * coss(sideYaw)

    o.oGravity = (o.oSubAction == 4) and -2.0 or -4.0 -- update gravity for long jump

    partner_step(o)

    if o.oVelY < 4.0 then
        local ledgePos = {
            x = o.oPosX + sins(o.oMoveAngleYaw) * 60.0,
            y = o.oPosY + 120.0,
            z = o.oPosZ + coss(o.oMoveAngleYaw) * 60.0
        }
        ledgePos.y = find_floor_height(ledgePos.x, ledgePos.y, ledgePos.z)
        if ledgePos.y > o.oPosY + 60.0 then
            local ledgeFloor = collision_find_floor(ledgePos.x, ledgePos.y + 1, ledgePos.z)
            if ledgeFloor and ledgeFloor.normal.y > 0.9 then
                o.oPosX = ledgePos.x
                o.oPosY = ledgePos.y
                o.oPosZ = ledgePos.z
                o.oMoveAngleYaw = o.oWallAngle + 0x8000
                charObjs.character_obj_set_animation(o, CHAR_ANIM_FAST_LEDGE_GRAB)
                return set_partner_action(o, partnerActs.AUTO)
            end
        end
    else
        if o.oSubAction < 3 and o.oVelY > 20.0 and o.oPosY - o.oFloorHeight < 300.0 then -- control jump height
            --o.oVelY = o.oVelY / 4.0
        end
    end

    if o.oMoveFlags & OBJ_MOVE_MASK_ON_GROUND ~= 0 then
        charObjs.character_obj_set_animation(o, AIR_ANIMS[o.oSubAction][3])
        play_sound(SOUND_ACTION_TERRAIN_LANDING + m.terrainSoundAddend, o.header.gfx.cameraToObject)

        o.oPartnerJumpState = max(1, o.oSubAction)

        if o.oForwardVel > 16.0 and m.forwardVel > 16.0 then
            return set_partner_action(o, partnerActs.WALKING)
        else
            if o.oSubAction == 3 then
                charObjs.character_obj_play_sound(o, CHAR_SOUND_HAHA)
            end
            return set_partner_action(o, partnerActs.IDLE)
        end
    end


    if o.oVelY > 0.0 then
        charObjs.character_obj_set_animation(o, AIR_ANIMS[o.oSubAction][1])
    else
        charObjs.character_obj_set_animation(o, AIR_ANIMS[o.oSubAction][2])
    end
end

---@param o Object
---@param m MarioState
local function partner_act_lava_bounce(o, m)
    local angleTo = obj_angle_to_point(o, m.pos.x, m.pos.z)

    local targetSpeed = (o.oDistanceToMario > 300.0) and 32.0 or 16.0

    o.oForwardVel = approach_f32_symmetric(o.oForwardVel, targetSpeed, 0.5)
    o.oMoveAngleYaw = approach_s16_symmetric(o.oMoveAngleYaw, angleTo, 0x400)

    partner_step(o)

    charObjs.character_obj_set_animation(o, CHAR_ANIM_FIRE_LAVA_BURN)
    if o.oTimer & 1 == 0 then
        spawn_non_sync_object(id_bhvBlackSmokeMario, E_MODEL_BURN_SMOKE, o.oPosX, o.oPosY, o.oPosZ, function(particle)
            particle.parentObj = o
        end)
    end

    if o.oMoveFlags & (OBJ_MOVE_ON_GROUND | OBJ_MOVE_ABOVE_LAVA) == OBJ_MOVE_ON_GROUND and o.oVelY <= 0.0 then
        o.oPosY = o.oFloorHeight

        if o.oSubAction == 0 then
            o.oVelY = 24.0
            o.oSubAction = 1

            return
        end
        charObjs.character_obj_set_animation(o, CHAR_ANIM_STAND_UP_FROM_LAVA_BOOST)

        return set_partner_action(o, partnerActs.AUTO)
    end
end

---@param o Object
---@param m MarioState
local function partner_act_cutscene(o, m)
    local sideOffset = m.marioObj.hitboxRadius + o.hitboxRadius + 50.0
    local data = gPartnerData[o.oCharNum]

    if data and data.animOffsets then
        sideOffset = data.animOffsets[o.oCharAnim] or sideOffset
    end

    o.oPosX = m.pos.x + sins(m.faceAngle.y + 0x5800) * sideOffset
    o.oPosZ = m.pos.z + coss(m.faceAngle.y + 0x5800) * sideOffset
    local floorHeight = find_floor_height(o.oPosX, m.pos.y, o.oPosZ)
    if o.oSubAction == 0 and abs(floorHeight - m.pos.y) < 100.0 then
        o.oPosY = floorHeight
    else
        o.oPosY = m.pos.y
    end

    o.oIntangibleTimer = 3
    o.oMoveAngleYaw = m.faceAngle.y
    o.oForwardVel = 0.0
    o.oVelY = 0.0

    if m.action & ACT_GROUP_MASK ~= ACT_GROUP_CUTSCENE then
        set_partner_action(o, partnerActs.IDLE)
    end
    charObjs.character_obj_set_animation(o, o.oCharAnim)
end

local KB_ANIMS = { [0] = { CHAR_ANIM_BACKWARD_KB, CHAR_ANIM_BACKWARD_AIR_KB }, { CHAR_ANIM_FORWARD_KB, CHAR_ANIM_AIR_FORWARD_KB } }

---@param o Object
---@param m MarioState
local function partner_act_attacked(o, m)
    o.oIntangibleTimer = 3

    partner_step(o)

    if o.oMoveFlags & OBJ_MOVE_MASK_ON_GROUND ~= 0 then
        o.oForwardVel = approach_f32_symmetric(o.oForwardVel, o.oSubAction == 0 and -4.0 or 4.0, 4.0)
        o.oVelY = 0.0
        charObjs.character_obj_set_animation(o, KB_ANIMS[o.oSubAction][1])
        if cur_obj_check_if_at_animation_end() ~= 0 then
            return set_partner_action(o, partnerActs.IDLE)
        end
    else
        charObjs.character_obj_set_animation(o, KB_ANIMS[o.oSubAction][2])
    end
end

---@param o Object
local function partner_act_squished(o)
    charObjs.character_obj_set_animation(o, CHAR_ANIM_A_POSE)

    local ceilDelta = find_ceil_height(o.oPosX, o.oPosY, o.oPosZ) - o.oPosY

    if ceilDelta > o.hitboxHeight then return set_partner_action(o, partnerActs.IDLE) end
    if o.oFloorHeight < o.oPosY then return set_partner_action(o, partnerActs.AIRBORNE) end
    if o.oPartnerSquishTimer > 16 then ceilDelta = 0.0 end

    local scale = o.header.gfx.scale
    local t = clamp(ceilDelta / o.hitboxHeight, 0.0, 1.0)
    scale.y = lerp(0.05, 1.0, t)
    scale.x = lerp(1.6, 1.0, t)
    scale.z = scale.x
    if ceilDelta < 20.0 then
        o.oPartnerSquishTimer = 32
    end
end

---@param o Object
---@param m MarioState
local function partner_act_enter_level(o, m)
    if o.oTimer <= 4 then
        o.oMoveAnglePitch = -0x4000
        o.oForwardVel = 32.0

        charObjs.character_obj_set_animation(o, CHAR_ANIM_FORWARD_SPINNING)
    else
        o.oMoveAnglePitch = approach_s16_asymptotic(o.oMoveAnglePitch, -atan2s(o.oDistanceToMario, m.pos.y - o.oPosY), 8)
        o.oMoveAngleYaw = approach_s16_asymptotic(o.oMoveAngleYaw, atan2s(m.pos.z - o.oPosZ, m.pos.x - o.oPosX), 8)

        charObjs.character_obj_set_animation(o, CHAR_ANIM_DIVE)
        o.oFaceAnglePitch = o.oMoveAnglePitch
        --o.oFaceAngleRoll = o.oFaceAngleRoll + 0x800
        o.oBooTargetOpacity = 0x00
    end

    o.oIntangibleTimer = 3

    o.oPosX = o.oPosX + sins(o.oMoveAngleYaw) * coss(o.oMoveAnglePitch) * o.oForwardVel
    o.oPosY = o.oPosY + -sins(o.oMoveAnglePitch) * o.oForwardVel
    o.oPosZ = o.oPosZ + coss(o.oMoveAngleYaw) * coss(o.oMoveAnglePitch) * o.oForwardVel
end

---@param o Object
local function partner_act_auto(o)
    o.oForwardVel = 0.0
    o.oVelY = 0.0

    partner_step(o)

    local animInfo = o.header.gfx.animInfo
    if animInfo.curAnim and cur_obj_check_if_at_animation_end() ~= 0 then
        set_partner_action(o, partnerActs.IDLE)
    end
end

---@param m MarioState
---@param o Object
local function process_player_interactions(m, o)
    if m.playerIndex ~= 0 or o.oIntangibleTimer ~= 0 or
        m.pos.y > o.oPosY + o.hitboxHeight or m.pos.y + m.marioObj.hitboxHeight < o.oPosY then
        return
    end
    local dist = lateral_dist_between_objects(m.marioObj, o)

    if dist > m.marioObj.hitboxRadius + o.hurtboxRadius then return end

    local interaction = determine_interaction(m, o)
    if interaction & (INT_GROUND_POUND_OR_TWIRL | INT_PUNCH | INT_KICK | INT_TRIP | INT_SLIDE_KICK) ~= 0 then
        o.oIntangibleTimer = 5

        charObjs.character_obj_play_sound(o, CHAR_SOUND_OOOF)
        if abs(s16(m.faceAngle.y - o.oFaceAngleYaw)) < 0x4000 then
            o.oForwardVel = gServerSettings.playerKnockbackStrength
            o.oMoveAngleYaw = m.faceAngle.y
            set_partner_action(o, partnerActs.ATTACKED, 1)
        else
            o.oForwardVel = -gServerSettings.playerKnockbackStrength
            o.oMoveAngleYaw = m.faceAngle.y + 0x8000
            set_partner_action(o, partnerActs.ATTACKED, 0)
        end

        if interaction & INT_KICK ~= 0 then
            o.oVelY = gServerSettings.playerKnockbackStrength * 2.0
            o.oForwardVel = o.oForwardVel * 2.0
        end
        if interaction & INT_GROUND_POUND ~= 0 then
            o.oPartnerSquishTimer = 16
        end
    end

    if dist > m.marioObj.hitboxRadius + o.hitboxRadius then
        network_send_object(o, false)
        return
    end

    if interaction & INT_HIT_FROM_ABOVE ~= 0 and m.action & ACT_FLAG_INTANGIBLE == 0 then
        o.oPartnerSquishTimer = 4
        o.oIntangibleTimer = 3

        if o.oAction == partnerActs.IDLE and o.oSubAction == 5 then
            mario_stop_riding_and_holding(m)
            set_mario_action(m, ACT_TWIRLING, 0)
            m.vel.y = clamp(abs(m.vel.y) + 30.0, 80.0, 100.0)
        elseif (m.action == ACT_JUMP) then
            mario_stop_riding_and_holding(m)
            set_mario_action(m, ACT_DOUBLE_JUMP, 0)
            m.vel.y = clamp(abs(m.vel.y) + 15.0, 35.0, 55.0)
        elseif (m.action == ACT_DOUBLE_JUMP) then
            mario_stop_riding_and_holding(m)
            set_mario_action(m,
                m.specialTripleJump ~= 0 and ACT_SPECIAL_TRIPLE_JUMP or
                (m.flags & MARIO_WING_CAP ~= 0 and ACT_FLYING_TRIPLE_JUMP or ACT_TRIPLE_JUMP), 0)
            m.vel.y = clamp(abs(m.vel.y) + 20.0, 40.0, 60.0)
        elseif (m.action == ACT_LONG_JUMP) then
            m.vel.y = clamp(abs(m.vel.y) + 5.0, 30.0, 40.0)
        elseif (m.action == ACT_HOLD_JUMP or m.action == ACT_HOLD_FREEFALL) then
            set_mario_action(m, ACT_HOLD_JUMP, 0)
            m.vel.y = clamp(abs(m.vel.y) + 15.0, 25.0, 40.0)
        else
            mario_stop_riding_and_holding(m)
            set_mario_action(m, ACT_JUMP, 0)
            m.vel.y = clamp(abs(m.vel.y) + 15.0, 30.0, 50.0)
        end

        m.flags = m.flags & ~MARIO_UNKNOWN_08
        m.pos.y = o.oPosY + o.hitboxHeight
        play_sound(SOUND_ACTION_BOUNCE_OFF_OBJECT, o.header.gfx.cameraToObject)
    end

    local pushAngle = mario_obj_angle_to_object(m, o)
    o.oPosX = o.oPosX + sins(pushAngle) * 5.0
    o.oPosZ = o.oPosZ + coss(pushAngle) * 5.0

    network_send_object(o, false)
end

---@type table<integer,fun(o:Object,m:MarioState)>
partnerActTable = {
    [partnerActs.WARP] = partner_act_warp,
    [partnerActs.IDLE] = partner_act_idle,
    [partnerActs.WALKING] = partner_act_walking,
    [partnerActs.AIRBORNE] = partner_act_airborne,
    [partnerActs.LAVA_BOUNCE] = partner_act_lava_bounce,
    [partnerActs.CUTSCENE] = partner_act_cutscene,
    [partnerActs.ATTACKED] = partner_act_attacked,
    [partnerActs.SQUISHED] = partner_act_squished,
    [partnerActs.ENTER_LEVEL] = partner_act_enter_level,
    [partnerActs.AUTO] = partner_act_auto,
}

local SQUISH_FRAMES = { 0x46, 0x32, 0x32, 0x3C, 0x46, 0x50, 0x50, 0x3C, 0x28, 0x14, 0x14, 0x1E, 0x32, 0x3C, 0x3C, 0x28 }

---@param o Object
local function bhv_partner_loop(o)
    local m = gMarioStates[network_local_index_from_global(o.oBehParams)]
    curParentM = m
    o.oDistanceToMario = lateral_dist_between_objects(o, m.marioObj)
    local yDeltaToMario = m.pos.y - o.oPosY

    local model = characterTable[o.oCharNum][o.oCharAlt].model

    if obj_has_model_extended(o, model) == 0 then
        obj_set_model_extended(o, model)
        charObjs.character_obj_set_animation(o, o.oCharAnim)

        local oh = characterTable[o.oCharNum].overrideHitbox or {}
        o.hitboxRadius = oh.radius or 37.0
        o.hitboxHeight = oh.height or 160.0
        o.hurtboxRadius = o.hitboxRadius + 40.0
        o.hurtboxHeight = o.hitboxHeight
    end

    o.oMoveFlags = o.oMoveFlags & ~(OBJ_MOVE_ABOVE_LAVA | OBJ_MOVE_ABOVE_DEATH_BARRIER | OBJ_MOVE_HIT_WALL)

    local wallData = collision_get_temp_wall_collision_data()
    wallData.offsetY = 50.0
    wallData.radius = o.oWallHitboxRadius
    wallData.x = o.oPosX
    wallData.y = o.oPosY
    wallData.z = o.oPosZ

    local numWalls = find_wall_collisions(wallData)
    if numWalls ~= 0 then
        o.oPosX = wallData.x
        o.oPosY = wallData.y
        o.oPosZ = wallData.z
        local wall = wallData.walls[wallData.numWalls]

        o.oWallAngle = atan2s(wall.normal.z, wall.normal.x)
        if abs(o.oWallAngle - o.oMoveAngleYaw) > 0x4000 then
            o.oMoveFlags = o.oMoveFlags | OBJ_MOVE_HIT_WALL
        end
    end
    cur_obj_update_floor()

    if o.oAction ~= partnerActs.WARP then
        if o.oPartnerJumpQueue > 0 then
            o.oPartnerJumpQueue = o.oPartnerJumpQueue - 1
        end

        if o.oFloor and o.oPosY <= o.oFloorHeight + 20.0 then
            -- update position for moving platforms
            local floorObj = o.oFloor.object
            if floorObj then
                o.oPosX = o.oPosX + floorObj.oVelX
                o.oPosZ = o.oPosZ + floorObj.oVelZ

                local offset = {
                    x = o.oPosX - floorObj.oPosX,
                    y = o.oPosY - floorObj.oPosY,
                    z = o.oPosZ - floorObj.oPosZ,
                }
                vec3f_rotate_zxy(offset, {
                    x = floorObj.oAngleVelPitch,
                    y = floorObj.oAngleVelYaw,
                    z = floorObj.oAngleVelRoll,
                })

                o.oPosX = floorObj.oPosX + offset.x
                o.oPosY = floorObj.oPosY + offset.y
                o.oPosZ = floorObj.oPosZ + offset.z

                o.oMoveAngleYaw = o.oMoveAngleYaw + floorObj.oAngleVelYaw
            end
            if o.oMoveFlags & OBJ_MOVE_ABOVE_LAVA ~= 0 and o.oVelY <= 0.0 then
                play_sound(SOUND_MOVING_LAVA_BURN, o.header.gfx.cameraToObject)
                if o.oAction ~= partnerActs.LAVA_BOUNCE or math.random() > 0.75 then
                    charObjs.character_obj_play_sound(o, CHAR_SOUND_ON_FIRE)
                end
                o.oVelY = 70.0
                o.oForwardVel = clamp(o.oForwardVel, 0.0, 8.0)
                set_partner_action(o, partnerActs.LAVA_BOUNCE)
            elseif o.oMoveFlags & OBJ_MOVE_ABOVE_DEATH_BARRIER ~= 0 then
                set_partner_action(o, partnerActs.WARP)
            end
        end

        if o.oDistanceToMario > 4000.0 or abs(yDeltaToMario) > 2000.0 or m.controller.buttonPressed & X_BUTTON ~= 0 then
            play_sound(SOUND_ACTION_TELEPORT, o.header.gfx.cameraToObject)
            set_partner_action(o, partnerActs.WARP)
        end

        process_player_interactions(nearest_interacting_mario_state_to_object(o), o)
        process_obj_interactions(o)
    end

    call_event_hook(eventHooks.PARTNER_BEFORE_UPDATE, o, m)

    if partnerActTable[o.oAction] then
        partnerActTable[o.oAction](o, m)
    end

    call_event_hook(eventHooks.PARTNER_UPDATE, o, m)

    local modelData = charObjs.character_obj_get_model_data(o)
    modelData.modelState = m.marioBodyState.modelState
    modelData.capState = m.marioBodyState.capState
    modelData.torsoAngle = { x = o.oPartnerTorsoPitch, y = 0, z = o.oPartnerTorsoRoll }
    if o.oAction <= partnerActs.WALKING then
        modelData.headAngle.x = -atan2s(o.oDistanceToMario, yDeltaToMario) // 2
    else
        modelData.headAngle.x = 0
    end
    if m.flags & MARIO_VANISH_CAP ~= 0 then
        o.oOpacity = min(o.oOpacity, 0x80)
    end
    if o.oBooTargetOpacity ~= o.oOpacity then
        if o.oBooTargetOpacity > o.oOpacity then
            o.oOpacity = min(o.oOpacity + 32, o.oBooTargetOpacity)
        elseif o.oBooTargetOpacity < o.oOpacity then
            o.oOpacity = max(o.oOpacity - 32, o.oBooTargetOpacity)
        end
    end

    if m.playerIndex == 0 then
        local pal = modelPalettePresets[model] or 1
        if o.oCharPalette ~= pal then
            o.oCharPalette = pal
            network_send_object(o, true)
        end
    end

    local np = gNetworkPlayers[m.playerIndex]

    if o.oCharPalette == 0 then
        for i = PANTS, EMBLEM do
            modelData.palette[i] = network_player_get_palette_color(np, i)
        end
    end

    o.header.gfx.shadowInvisible = o.oOpacity < 0x80

    if o.oAction ~= partnerActs.SQUISHED then
        if o.oPartnerSquishTimer == 0 then
            cur_obj_scale(1.0)
        elseif o.oPartnerSquishTimer <= 16 then
            o.oPartnerSquishTimer = o.oPartnerSquishTimer - 1
            local scale = o.header.gfx.scale

            scale.y = 1.0 - ((SQUISH_FRAMES[16 - o.oPartnerSquishTimer] * 0.6) / 100.0)
            scale.x = ((SQUISH_FRAMES[16 - o.oPartnerSquishTimer] * 0.4) / 100.0) + 1.0
            scale.z = scale.x
        else
            o.oPartnerSquishTimer = o.oPartnerSquishTimer - 1
            local scale = o.header.gfx.scale

            scale.y = 0.4
            scale.x = 1.4
            scale.z = 1.4
        end
    end

    o.oIsChar = 1
    o.globalPlayerIndex = network_global_index_from_local(0)
    o.header.gfx.sharedChild.hookProcess = 1
    if o.header.gfx.animInfo.curAnim then
        o.header.gfx.animInfo.animYTrans = o.header.gfx.animInfo.curAnim.animYTransDivisor
    end

    if not gPlayerSyncTable[m.playerIndex].active or not np.connected or not np.currAreaSyncValid then
        obj_mark_for_deletion(o)

        call_event_hook(eventHooks.PARTNER_DESPAWNED, o, gMarioStates[network_local_index_from_global(o.oBehParams)])

        if m.playerIndex == 0 then
            localPartnerObj = nil
        end
    end
end

id_bhvPartnerFaker = hook_behavior(nil, OBJ_LIST_GENACTOR, true, bhv_partner_init, bhv_partner_loop, "bhvPartnerFaker")


-- FUNCTIONS

---@type MarioState
local m = gMarioStates[0]
local p = gPlayerSyncTable[0]

local function try_spawn_partner_obj()
    local partnerCharNum = p.partnerChar

    if not partnerCharNum then return end
    local partnerCharAlt = characterTable[partnerCharNum].currAlt or 1

    if localPartnerObj and localPartnerObj.oIsChar ~= 0 then
        localPartnerObj.oCharNum = partnerCharNum
        localPartnerObj.oCharAlt = partnerCharAlt
        network_send_object(localPartnerObj, true)
        return
    end

    local globalIndex = m.marioObj.globalPlayerIndex

    local x = m.pos.x
    local z = m.pos.z
    local y = m.pos.y + 100

    local partnerModel = characterTable[partnerCharNum][partnerCharAlt].model

    localPartnerObj = spawn_sync_object(id_bhvPartnerFaker, partnerModel, x, y, z,
        ---@param o Object
        function(o)
            o.oBehParams = globalIndex

            o.oOpacity = 0x00

            o.oCharNum = partnerCharNum
            o.oCharAlt = partnerCharAlt
            o.oCharPalette = 1
        end)
end

function swap_leader()
    if not localPartnerObj then return end

    local oldCharNum = charSelect.character_get_current_number() or 0
    local oldCharAlt = characterTable[oldCharNum].currAlt

    if gPartnerData[oldCharNum] and gPartnerData[oldCharNum].partnerNum == localPartnerObj.oCharNum then
        charSelect.character_set_locked(localPartnerObj.oCharNum, true, false)
        charSelect.character_set_locked(oldCharNum, false, false)
    end

    charSelect.character_set_current_number(localPartnerObj.oCharNum, localPartnerObj.oCharAlt)

    localPartnerObj.oCharNum = oldCharNum
    localPartnerObj.oCharAlt = oldCharAlt

    p.leaderChar, p.partnerChar = p.partnerChar, p.leaderChar

    mario_drop_held_object(m)

    if m.area.camera.cutscene == 0 then
        local oldM = {
            x = m.pos.x,
            y = m.pos.y,
            z = m.pos.z,
            yaw = m.faceAngle.y,
            fVel = m.forwardVel,
            yVel = m.vel.y
        }

        m.pos.x = localPartnerObj.oPosX
        m.pos.y = localPartnerObj.oPosY
        m.pos.z = localPartnerObj.oPosZ
        m.faceAngle.y = localPartnerObj.oMoveAngleYaw
        m.forwardVel = localPartnerObj.oForwardVel
        m.vel.y = localPartnerObj.oVelY

        vec3f_set(m.marioObj.header.gfx.prevPos, m.pos.x, m.pos.y, m.pos.z)
        vec3s_set(m.marioObj.header.gfx.prevAngle, 0, m.faceAngle.y, 0)

        localPartnerObj.oPosX = oldM.x
        localPartnerObj.oPosY = oldM.y
        localPartnerObj.oPosZ = oldM.z
        localPartnerObj.oMoveAngleYaw = oldM.yaw
        localPartnerObj.oForwardVel = oldM.fVel
        localPartnerObj.oVelY = oldM.yVel

        vec3f_set(localPartnerObj.header.gfx.prevPos, oldM.x, oldM.y, oldM.z)
        vec3s_set(localPartnerObj.header.gfx.prevAngle, 0, oldM.yaw, 0)

        local SWAP_ACTS = { ACT_IDLE, ACT_WALKING }
        set_mario_action(m, SWAP_ACTS[localPartnerObj.oAction], 0)
    end

    network_send_object(localPartnerObj, true)
    set_character_animation(m, -1)

    call_event_hook(eventHooks.ON_SWAP_LEADER, localPartnerObj, m)
end

local syncValid = false
local spawnPartnerQueued = false
local swapState = 0

local function on_character_change(prevChar, currChar)
    p.leaderChar = currChar

    if gPartnerData[currChar] and gPartnerData[currChar].partnerNum then
        p.active = true
        p.partnerChar = gPartnerData[currChar].partnerNum

        spawnPartnerQueued = true -- queue partner spawn for when we are in the proper mod context :explosion:
    elseif gPartnerData[prevChar] and gPartnerData[prevChar].partnerNum then
        p.active = false
        localPartnerObj = nil
    end
end
charSelect.hook_on_character_change(on_character_change)


local function on_sync_valid()
    syncValid = true

    if gMarioStates[0].area.camera and p.active then
        localPartnerObj = nil
        swapState = 0

        try_spawn_partner_obj()
    end
end
hook_event(HOOK_ON_SYNC_VALID, on_sync_valid)

hook_event(HOOK_ON_WARP, function()
    syncValid = false
end)

local function update()
    if syncValid then
        local csP = charSelect.gCSPlayers[0]
        modelPalettePresets[csP.modelId] = csP.presetPalette

        if spawnPartnerQueued then
            try_spawn_partner_obj()
            spawnPartnerQueued = false
        end
    end

    if localPartnerObj and localPartnerObj.oIsChar ~= 0 then
        if m.controller.buttonPressed & L_TRIG ~= 0 and swapState == 0 then
            if m.action & (ACT_FLAG_INVULNERABLE | ACT_FLAG_INTANGIBLE) ~= 0
                or localPartnerObj.oAction == partnerActs.WARP or localPartnerObj.oAction > partnerActs.AIRBORNE
                or localPartnerObj.oDistanceToMario > 600.0 or abs(m.pos.y - localPartnerObj.oPosY) > 400.0
                or localPartnerObj.oPosY - find_floor_height(localPartnerObj.oPosX, localPartnerObj.oPosY, localPartnerObj.oPosZ) > 250.0
            then
                play_sound_with_freq_scale(SOUND_MENU_CAMERA_BUZZ, gGlobalSoundSource, 1.5)
                return
            end
            play_sound_with_freq_scale(SOUND_MENU_CLICK_CHANGE_VIEW, gGlobalSoundSource, 1.5)

            if call_event_hook(eventHooks.TRY_SWAP_LEADER, p.leaderChar, p.partnerChar) ~= false then
                swapState = 1
            end
            return
        end

        if swapState == 0 then return end

        if swapState > 1 then
            swapState = swapState + 1
            if swapState > 3 then
                play_character_sound(m, CHAR_SOUND_LETS_A_GO)
                swapState = 0
            end
            return
        end

        if localPartnerObj.oAction == partnerActs.WARP or localPartnerObj.oAction >= partnerActs.AIRBORNE then return end

        swap_leader()

        set_mario_particle_flags(m, PARTICLE_SPARKLES, 0)
        swapState = 2
        return
    end
end
hook_event(HOOK_UPDATE, update)


-- CS MENU STUFF

local csMenuCamOffset = gVec3fZero()
local csMenuSwapState = 0

local function override_cs_menu()
    if charSelect.is_menu_open() then
        if csMenuSwapState > 0 then
            csMenuSwapState = csMenuSwapState - 1
        end
        if m.controller.buttonDown & Z_TRIG ~= 0 and m.controller.buttonPressed & (L_TRIG | R_TRIG) ~= 0 then
            if csMenuSwapState == 0 then
                play_sound_with_freq_scale(SOUND_MENU_CLICK_CHANGE_VIEW, gGlobalSoundSource, 1.5)
                csMenuSwapState = 10
            end

            m.controller.buttonDown = m.controller.buttonDown & ~(L_TRIG | R_TRIG)
            m.controller.buttonPressed = m.controller.buttonPressed & ~(L_TRIG | R_TRIG)
        end
    end
    return true
end
charSelect.hook_allow_menu_open(override_cs_menu) -- using this hook to override controls before CS uses them

local function mario_update(hookM)
    if hookM.playerIndex ~= 0 then return end

    if charSelect.is_menu_open() then
        if csMenuSwapState == 10 then
            local charNum = charSelect.character_get_current_number()
            if p.active then
                if p.partnerChar == charNum then
                    p.active = false
                else
                    play_sound_with_freq_scale(SOUND_MENU_CLICK_CHANGE_VIEW, gGlobalSoundSource, 1.5)
                    swap_leader()
                end
            else
                p.active = true

                local newChar = charNum
                repeat
                    newChar = (newChar % #characterTable) + 1
                until (characterTable[newChar].locked ~= 1 and not (gPartnerData[newChar] and gPartnerData[newChar].partnerNum)) or newChar == charNum

                p.leaderChar = newChar
                p.partnerChar = charNum
                charSelect.character_set_current_number(newChar)
                try_spawn_partner_obj()
            end
        end

        local targetOffsetX, targetOffsetZ = 0.0, 0.0
        if localPartnerObj and p.active then
            if localPartnerObj.oAction ~= partnerActs.CUTSCENE then
                charObjs.character_obj_set_animation(localPartnerObj, charSelect.CS_ANIM_MENU)
                set_partner_action(localPartnerObj, partnerActs.CUTSCENE)
                localPartnerObj.oBooTargetOpacity = 0xFF
                network_send_object(localPartnerObj, true)
            end
            local camAngle = m.faceAngle.y + 0x800
            local camBack = 250.0
            local char = characterTable[localPartnerObj.oCharNum][localPartnerObj.oCharAlt]
            if char then
                camBack = camBack + char.camScale
            end
            targetOffsetX = (localPartnerObj.oPosX - m.pos.x) * 0.33 + camBack * sins(camAngle)
            targetOffsetZ = (localPartnerObj.oPosZ - m.pos.z) * 0.33 + camBack * coss(camAngle)
        end

        if m.area.camera.cutscene == charSelect.CUTSCENE_CS_MENU then
            csMenuCamOffset.x = lerp(csMenuCamOffset.x, targetOffsetX, 0.1)
            csMenuCamOffset.z = lerp(csMenuCamOffset.z, targetOffsetZ, 0.1)
            vec3f_add(gLakituState.pos, csMenuCamOffset)
            vec3f_add(gLakituState.focus, csMenuCamOffset)
        end
    else
        vec3f_zero(csMenuCamOffset)
    end
end
hook_event(HOOK_MARIO_UPDATE, mario_update)

local function act_trigger_jump(o)
    if o.oPartnerJumpQueue == 0 and o.oDistanceToMario < 1000.0 then
        o.oPartnerJumpQueue = 4 + (o.oDistanceToMario // 50)
    end
end

local function act_trigger_enter_level(o)
    set_partner_action(o, partnerActs.ENTER_LEVEL)

    o.oMoveAnglePitch = -0x4000
end

local function act_trigger_star_dance(o)
    set_partner_action(o, partnerActs.CUTSCENE)
    o.oCharAnim = CHAR_ANIM_STAR_DANCE
end

local function act_trigger_death_exit(o)
    set_partner_action(o, partnerActs.ATTACKED)

    o.oForwardVel = m.forwardVel
    o.oVelY = m.vel.y
    o.oMoveAngleYaw = m.faceAngle.y
end

local function act_trigger_star_exit(o)
    set_partner_action(o, partnerActs.AIRBORNE)

    o.oForwardVel = m.forwardVel
    o.oVelY = m.vel.y + 16.0
    o.oMoveAngleYaw = m.faceAngle.y
end

PARTNER_ACT_TRIGGERS = {
    [ACT_JUMP] = act_trigger_jump,
    [ACT_DOUBLE_JUMP] = act_trigger_jump,
    [ACT_TRIPLE_JUMP] = act_trigger_jump,
    [ACT_LONG_JUMP] = act_trigger_jump,
    [ACT_BACKFLIP] = act_trigger_jump,
    [ACT_DISAPPEARED] = act_trigger_enter_level,
    [ACT_BBH_ENTER_SPIN] = act_trigger_enter_level,
    [ACT_STAR_DANCE_NO_EXIT] = act_trigger_star_dance,
    [ACT_STAR_DANCE_EXIT] = act_trigger_star_dance,
    [ACT_DEATH_EXIT] = act_trigger_death_exit,
    [ACT_SPECIAL_DEATH_EXIT] = act_trigger_death_exit,
    [ACT_EXIT_AIRBORNE] = act_trigger_star_exit,
    [ACT_SPECIAL_EXIT_AIRBORNE] = act_trigger_star_exit,
}

local function on_set_action(hookM)
    if hookM.playerIndex ~= 0 or not localPartnerObj then return end

    if PARTNER_ACT_TRIGGERS[m.action] then
        PARTNER_ACT_TRIGGERS[m.action](localPartnerObj)
        --network_send_object(localPartnerObj, false)
    end
end
hook_event(HOOK_ON_SET_MARIO_ACTION, on_set_action)

local HUD_SWAP_STEP = 1 / 6
local hudSwapProgress = 0.0

local hudPartnerIcons = {
    {
        texture = gTextures.mario_head,
        x = 0,
        y = 0,
        scale = 1.0,
        prevX = 0,
        prevY = 0,
        prevScale = 1.0
    },
    {
        texture = gTextures.luigi_head,
        x = 0,
        y = 0,
        scale = 1.0,
        prevX = 0,
        prevY = 0,
        prevScale = 1.0
    }
}
local hudArrow = {
    pos = gVec3fZero(),
    scale = 1.0,
    prevPos = gVec3fZero(),
    prevScale = 1.0,
}

local function render_partner_icon(i)
    local icon = hudPartnerIcons[i]
    local wCorrect, hCorrect = (icon.texture.width / 16.0), (icon.texture.height / 16.0)
    local fade = 0xFF * icon.scale
    djui_hud_set_color(fade, fade, fade, 0xFF)

    if hudSwapProgress == 0.0 then
        djui_hud_render_texture(icon.texture,
            icon.x, icon.y, icon.scale / wCorrect, icon.scale / hCorrect)
    else
        djui_hud_render_texture_interpolated(icon.texture,
            icon.prevX, icon.prevY, icon.prevScale / wCorrect, icon.prevScale / hCorrect,
            icon.x, icon.y, icon.scale / wCorrect, icon.scale / hCorrect)
    end

    icon.prevX = icon.x
    icon.prevY = icon.y
    icon.prevScale = icon.scale
end

local function on_hud_render()
    local charNum = charSelect.character_get_current_number()

    if p.active and localPartnerObj and localPartnerObj.oIsChar ~= 0 and m.area.camera then
        hud_set_value(HUD_DISPLAY_FLAGS, hud_get_value(HUD_DISPLAY_FLAGS) & ~HUD_DISPLAY_FLAG_LIVES)

        djui_hud_set_resolution(RESOLUTION_N64)
        djui_hud_set_font(FONT_HUD)
        djui_hud_set_color(0xFF, 0xFF, 0xFF, 0xFF)

        if hudSwapProgress > 0.0 then
            hudSwapProgress = hudSwapProgress + HUD_SWAP_STEP
            if hudSwapProgress >= 1.0 then
                hudSwapProgress = 0.99
                if swapState == 0 then
                    hudSwapProgress = 0.0
                    hudPartnerIcons[1].texture, hudPartnerIcons[2].texture = hudPartnerIcons[2].texture,
                        hudPartnerIcons[1].texture
                end
            end
        elseif swapState == 1 then
            hudSwapProgress = HUD_SWAP_STEP
            hudPartnerIcons[1].texture = characterTable[charNum][charSelect.character_get_current_costume()].lifeIcon
            hudPartnerIcons[2].texture = characterTable[localPartnerObj.oCharNum][localPartnerObj.oCharAlt].lifeIcon
        else
            hudPartnerIcons[1].texture = characterTable[charNum][charSelect.character_get_current_costume()].lifeIcon
            hudPartnerIcons[2].texture = characterTable[localPartnerObj.oCharNum][localPartnerObj.oCharAlt].lifeIcon
        end

        local keys = { { x = 30, y = 23, scale = 1.0 }, { x = 22, y = 15, scale = 0.66 } }

        for i, icon in ipairs(hudPartnerIcons) do
            local k1 = keys[i]
            local k2 = keys[i % 2 + 1]
            icon.scale = tween(IN_OUT_QUAD, k1.scale, k2.scale, hudSwapProgress)
            local posFix = -(8 * icon.scale)
            icon.x = tween(IN_CIRC, k1.x, k2.x, hudSwapProgress) + posFix
            icon.y = tween(OUT_CIRC, k1.y, k2.y, hudSwapProgress) + posFix
        end

        if hudSwapProgress < 0.5 then
            render_partner_icon(2)
            render_partner_icon(1)
        else
            render_partner_icon(1)
            render_partner_icon(2)
        end

        djui_hud_set_color(0xFF, 0xFF, 0xFF, 0xFF)

        djui_hud_print_text("@", 38, 15, 1.0, 1.0)
        djui_hud_print_text(tostring(hud_get_value(HUD_DISPLAY_LIVES)):gsub("-", "M"), 54, 15, 1.0, 1.0)

        local width = djui_hud_get_screen_width()
        local height = djui_hud_get_screen_height()
        local margin = 4

        if localPartnerObj.oOpacity < 0x10 then return end

        djui_hud_world_pos_to_screen_pos({
            x = localPartnerObj.oPosX,
            y = localPartnerObj.oPosY + localPartnerObj.hitboxHeight * 1.25,
            z = localPartnerObj.oPosZ
        }, hudArrow.pos)

        hudArrow.scale = clamp(1.0 / (-hudArrow.pos.z * 0.001), 0.25, 1.0)

        local rot = 0
        if hudArrow.pos.x < margin then
            rot = -0x4000
            hudArrow.pos.x = margin
        elseif hudArrow.pos.x > width - margin then
            rot = 0x4000
            hudArrow.pos.x = width - margin
        elseif hudArrow.pos.y < margin then
            rot = 0x8000
            hudArrow.pos.y = margin
        elseif hudArrow.pos.y > height - margin then
            hudArrow.pos.y = height - margin
        end

        djui_hud_set_rotation(rot, 0.5, 0.5)
        djui_hud_render_texture_interpolated(gTextures.arrow_down,
            hudArrow.prevPos.x - 4 * hudArrow.prevScale, hudArrow.prevPos.y - 4 * hudArrow.prevScale, hudArrow.prevScale,
            hudArrow.prevScale,
            hudArrow.pos.x - 4 * hudArrow.scale, hudArrow.pos.y - 4 * hudArrow.scale, hudArrow.scale, hudArrow.scale)

        vec3f_copy(hudArrow.prevPos, hudArrow.pos)
        hudArrow.prevScale = hudArrow.scale
        djui_hud_set_rotation(0, 0.0, 0.0)
    else
        hud_set_value(HUD_DISPLAY_FLAGS, hud_get_value(HUD_DISPLAY_FLAGS) | HUD_DISPLAY_FLAG_LIVES)
    end
end
hook_event(HOOK_ON_HUD_RENDER_BEHIND, on_hud_render)

local WAVE_SPEED = math.pi / 2.0

local partnerSign = {
    t = 0.0,
    rot = 0,
    prevX = 2000,
    prevY = 0,
}

local function render_in_cs_menu()
    local charNum = charSelect.character_get_current_number()

    djui_hud_set_font(FONT_CHARACTERISTIC)
    djui_hud_set_resolution(RESOLUTION_DJUI)
    local djuiWidth = djui_hud_get_screen_width()
    local djuiHeight = djui_hud_get_screen_height()
    djui_hud_set_resolution(RESOLUTION_N64)
    local width = math.max(djuiWidth * (240 / djuiHeight), 320) -- Get accurate, unrounded width
    local height = 240
    local widthScale = math.max(width, 320) / 320.0

    if p.active and localPartnerObj then
        local charName = (charSelect.character_get_nickname(p.partnerChar) or "?"):upper()
        local nameScale = min(width * 0.125 / djui_hud_measure_text(charName), 1.0)
        --local nameScale = 0.333
        local nameColor = characterTable[p.partnerChar][1].color or { r = 0xFF, g = 0xFF, b = 0xFF }
        local x, y = width * 0.725, 48

        djui_hud_set_color(185 + 70 * nameColor.r / 256, 185 + 70 * nameColor.g / 256, 185 + 70 * nameColor.b / 256, 0xFF)
        djui_hud_set_rotation(-0x600, 0.0, 0.0)
        djui_hud_effect_wave(0, 1, WAVE_SPEED)
        djui_hud_print_text("& " .. charName, x, y, nameScale, nameScale)

        djui_hud_set_rotation(0, 0.0, 0.0)
    end

    local zDown = charSelect.controller.buttonDown & Z_TRIG ~= 0
    if zDown or partnerSign.t > 0.01 then
        partnerSign.t = lerp(partnerSign.t, zDown and 1.0 or 0.0, 0.5)

        local x, y = lerp(width + 8, width - 24, partnerSign.t), 48

        djui_hud_set_color(0xFF, 0xFF, 0xFF, 0xFF)
        djui_hud_set_rotation(s16(lerp(0, 0x1000, partnerSign.t)), 1.0, 1.0)
        djui_hud_render_rect_interpolated(partnerSign.prevX, partnerSign.prevY, 32, 32, x, y, 32, 32)

        djui_hud_set_rotation(0, 0.0, 0.0)

        partnerSign.prevX = x
        partnerSign.prevY = y
    end
end
charSelect.hook_render_in_menu(render_in_cs_menu)


---@return Object?
function get_local_partner()
    return localPartnerObj
end

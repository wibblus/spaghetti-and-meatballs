---@diagnostic disable:missing-return-value

local function run_func_or_get_var(x, ...)
    if type(x) == "function" then
        return x(...)
    else
        return x
    end
end

---@param a Vec3f|Vec3s
---@param b? Vec3f|Vec3s
---@param def Vec3f|Vec3s
local function vec_copy_or_default(a, b, def)
    if not b then b = def end

    a.x = b.x or def.x
    a.y = b.y or def.y
    a.z = b.z or def.z
end

---@class Object
---@field oIsChar integer
---@field oCharNum integer
---@field oCharAlt integer
---@field oCharPalette integer
---@field oCharAnim integer
define_custom_obj_fields({
    oIsChar = "u32",
    oCharNum = "u32",
    oCharAlt = "u32",
    oCharPalette = "u32",
    oCharAnim = "u32",
})

---@class CharModelData
---@field handState? MarioHandGSCId
---@field eyeState? MarioEyesGSCId
---@field capState? MarioCapGSCId
---@field fadeWarpOpacity? integer
---@field modelState? integer
---@field punchState? integer
---@field torsoAngle? Vec3s
---@field headAngle? Vec3s
---@field palette? PlayerPalette

---@type table<Object,CharModelData>
local charModelData = {}

local function new_model_data()
    return { torsoAngle = {}, headAngle = {}, palette = {} }
end

local characterTable = charSelectExists and charSelect.character_get_full_table() or nil
local m = gMarioStates[0] ---@type MarioState
local np = gNetworkPlayers[0] ---@type NetworkPlayer
local varToChar = {
    [CHAR_SOUND_YAH_WAH_HOO] = "soundYahWahHoo",
    [CHAR_SOUND_HOOHOO] = "soundHoohoo",
    [CHAR_SOUND_YAHOO] = "soundYahoo",
    [CHAR_SOUND_UH] = "soundUh",
    [CHAR_SOUND_HRMM] = "soundHrmm",
    [CHAR_SOUND_WAH2] = "soundWah2",
    [CHAR_SOUND_WHOA] = "soundWhoa",
    [CHAR_SOUND_EEUH] = "soundEeuh",
    [CHAR_SOUND_ATTACKED] = "soundAttacked",
    [CHAR_SOUND_OOOF] = "soundOoof",
    [CHAR_SOUND_OOOF2] = "soundOoof2",
    [CHAR_SOUND_HERE_WE_GO] = "soundHereWeGo",
    [CHAR_SOUND_YAWNING] = "soundYawning",
    [CHAR_SOUND_SNORING1] = "soundSnoring1",
    [CHAR_SOUND_SNORING2] = "soundSnoring2",
    [CHAR_SOUND_WAAAOOOW] = "soundWaaaooow",
    [CHAR_SOUND_HAHA] = "soundHaha",
    [CHAR_SOUND_HAHA_2] = "soundHaha_2",
    [CHAR_SOUND_UH2] = "soundUh2",
    [CHAR_SOUND_UH2_2] = "soundUh2_2",
    [CHAR_SOUND_ON_FIRE] = "soundOnFire",
    [CHAR_SOUND_DYING] = "soundDying",
    [CHAR_SOUND_PANTING_COLD] = "soundPantingCold",
    [CHAR_SOUND_PANTING] = "soundPanting",
    [CHAR_SOUND_COUGHING1] = "soundCoughing1",
    [CHAR_SOUND_COUGHING2] = "soundCoughing2",
    [CHAR_SOUND_COUGHING3] = "soundCoughing3",
    [CHAR_SOUND_PUNCH_YAH] = "soundPunchYah",
    [CHAR_SOUND_PUNCH_HOO] = "soundPunchHoo",
    [CHAR_SOUND_MAMA_MIA] = "soundMamaMia",
    [CHAR_SOUND_GROUND_POUND_WAH] = "soundGroundPoundWah",
    [CHAR_SOUND_DROWNING] = "soundDrowning",
    [CHAR_SOUND_PUNCH_WAH] = "soundPunchWah",
    [CHAR_SOUND_YAHOO_WAHA_YIPPEE] = "soundYahooWahaYippee",
    [CHAR_SOUND_DOH] = "soundDoh",
    [CHAR_SOUND_GAME_OVER] = "soundGameOver",
    [CHAR_SOUND_HELLO] = "soundHello",
    [CHAR_SOUND_PRESS_START_TO_PLAY] = "soundPressStartToPlay",
    [CHAR_SOUND_TWIRL_BOUNCE] = "soundTwirlBounce",
    [CHAR_SOUND_SNORING3] = "soundSnoring3",
    [CHAR_SOUND_SO_LONGA_BOWSER] = "soundSoLongaBowser",
    [CHAR_SOUND_IMA_TIRED] = "soundImaTired",
    [CHAR_SOUND_LETS_A_GO] = "soundLetsAGo",
    [CHAR_SOUND_OKEY_DOKEY] = "soundOkeyDokey",
}

---@param o Object
---@param animID integer
---@param accel? integer
local function character_obj_set_animation(o, animID, accel)
    if not o or o.oIsChar == 0 then return end
    local anims
    local animIDFallback
    local char = characterTable[o.oCharNum][o.oCharAlt]
    if char then
        anims = charSelect.character_get_animations(char.model)
    end
    if animID == charSelect.CS_ANIM_MENU then
        animIDFallback = CHAR_ANIM_FIRST_PERSON
    end
    local animInfo = o.header.gfx.animInfo

    if anims and anims.anims then
        if anims.anims[animID] then
            smlua_anim_util_set_animation(o, anims.anims[animID])
        elseif anims.anims[animIDFallback] then
            smlua_anim_util_set_animation(o, anims.anims[animIDFallback])
        else
            animInfo.curAnim = animIDFallback and get_mario_vanilla_animation(animIDFallback) or
                get_mario_vanilla_animation(animID)
        end
    else
        animInfo.curAnim = animIDFallback and get_mario_vanilla_animation(animIDFallback) or
            get_mario_vanilla_animation(animID)
    end

    accel = accel or 0x10000
    animInfo.animAccel = accel

    if o.oCharAnim == animID or not animInfo.curAnim then return end

    o.oCharAnim = animID
    animInfo.animID = animID

    if animInfo.curAnim.flags & ANIM_FLAG_2 ~= 0 then
        animInfo.animFrameAccelAssist = (animInfo.curAnim.startFrame << 0x10)
    else
        if animInfo.curAnim.flags & ANIM_FLAG_BACKWARD ~= 0 then
            animInfo.animFrameAccelAssist = (animInfo.curAnim.startFrame << 0x10) + accel
        else
            animInfo.animFrameAccelAssist = (animInfo.curAnim.startFrame << 0x10) - accel
        end
    end

    animInfo.animFrame = animInfo.animFrameAccelAssist >> 0x10
    animInfo.animTimer = 0

    return animInfo.animFrame
end
if not charSelectExists then
    ---@param o Object
    ---@param animID integer
    ---@param accel? integer
    function character_obj_set_animation(o, animID, accel)
        if not o or o.oIsChar == 0 then return end
        local animInfo = o.header.gfx.animInfo

        animInfo.curAnim = get_mario_vanilla_animation(animID)

        accel = accel or 0x10000
        animInfo.animAccel = accel

        if o.oCharAnim == animID or not animInfo.curAnim then return end

        o.oCharAnim = animID

        if animInfo.curAnim.flags & ANIM_FLAG_2 ~= 0 then
            animInfo.animFrameAccelAssist = (animInfo.curAnim.startFrame << 0x10)
        else
            if animInfo.curAnim.flags & ANIM_FLAG_BACKWARD ~= 0 then
                animInfo.animFrameAccelAssist = (animInfo.curAnim.startFrame << 0x10) + accel
            else
                animInfo.animFrameAccelAssist = (animInfo.curAnim.startFrame << 0x10) - accel
            end
        end

        animInfo.animFrame = animInfo.animFrameAccelAssist >> 0x10
        animInfo.animTimer = 0

        return animInfo.animFrame
    end
end

---@param o Object
---@param charSound integer
local function character_obj_play_sound(o, charSound)
    if not o or o.oIsChar == 0 then return end
    local char = characterTable[o.oCharNum][o.oCharAlt]
    if charSelect.character_get_voice(char.model) then
        local p = charSelect.gCSPlayers[0]
        local prevModel = p.modelId
        local prevCamPos = gVec3fZero()
        vec3f_copy(prevCamPos, m.marioObj.header.gfx.cameraToObject)

        p.modelId = char.model
        vec3f_copy(m.marioObj.header.gfx.cameraToObject, o.header.gfx.cameraToObject)

        charSelect.voice.sound(m, charSound, { x = o.oPosX, y = o.oPosY, z = o.oPosZ })

        p.modelId = prevModel
        vec3f_copy(m.marioObj.header.gfx.cameraToObject, prevCamPos)
    else
        play_sound(gCharacters[char.baseChar][varToChar[charSound]], o.header.gfx.cameraToObject)
    end
end
if not charSelectExists then
    ---@param o Object
    ---@param charSound integer
    function character_obj_play_sound(o, charSound) end
end

---@param o Object
---@return CharModelData
-- returns the object's modifiable model data table
local function character_obj_get_model_data(o)
    if not o or o.oIsChar == 0 then return end
    if not charModelData[o] then charModelData[o] = new_model_data() end
    return charModelData[o]
end

---@param o Object
local function character_obj_loop(o)
    o.oIsChar = 1
    o.globalPlayerIndex = network_global_index_from_local(0)
    obj_set_model_extended(o, characterTable[o.oCharNum][o.oCharAlt].model)
    if o.header.gfx.sharedChild then
        o.header.gfx.sharedChild.hookProcess = 1
    end
    if o.header.gfx.animInfo.curAnim then
        o.header.gfx.animInfo.animYTrans = o.header.gfx.animInfo.curAnim.animYTransDivisor
    end
end
if not charSelectExists then
    ---@param o Object
    function character_obj_loop(o)
        o.oIsChar = 1
        o.globalPlayerIndex = network_global_index_from_local(0)
        if o.header.gfx.sharedChild then
            o.header.gfx.sharedChild.hookProcess = 1
        end
        if o.header.gfx.animInfo.curAnim then
            o.header.gfx.animInfo.animYTrans = o.header.gfx.animInfo.curAnim.animYTransDivisor
        end
    end
end

-- Handle Object Visuals
local modelRevert = {
    marioProcessed = false,
    eyeState = MARIO_EYES_OPEN,
    handState = MARIO_HAND_FISTS,
    capState = MARIO_HAS_DEFAULT_CAP_ON,
    modelState = 0,
    punchState = 0,
    fadeWarpOpacity = 255,
    allowPartRotation = 0,
    torsoAngle = gVec3sZero(),
    headAngle = gVec3sZero(),
    headPos = gVec3fZero(),
    headRotation = gVec3sZero(),
    holp = gVec3fZero(),
    heldObj = nil,
    palette = {
        [PANTS]  = { r = 0, g = 0, b = 0 },
        [SHIRT]  = { r = 0, g = 0, b = 0 },
        [GLOVES] = { r = 0, g = 0, b = 0 },
        [SHOES]  = { r = 0, g = 0, b = 0 },
        [HAIR]   = { r = 0, g = 0, b = 0 },
        [SKIN]   = { r = 0, g = 0, b = 0 },
        [CAP]    = { r = 0, g = 0, b = 0 },
        [EMBLEM] = { r = 0, g = 0, b = 0 },
    }
}

local og_network_player_get_override_palette_color = network_player_get_override_palette_color

---@param np NetworkPlayer
---@param part PlayerPart
_G.network_player_get_override_palette_color = function(np, part)
    if np.localIndex ~= 0 or not modelRevert.marioProcessed then
        return og_network_player_get_override_palette_color(np, part)
    else
        return modelRevert.palette[part]
    end
end

local blinkAnim = {
    MARIO_EYES_HALF_CLOSED,
    MARIO_EYES_CLOSED,
    MARIO_EYES_HALF_CLOSED,
    MARIO_EYES_OPEN,
    MARIO_EYES_HALF_CLOSED,
    MARIO_EYES_CLOSED,
    MARIO_EYES_HALF_CLOSED
}

local fallbackPalette = {
    [PANTS]  = { r = 0x00, g = 0x00, b = 0xff },
    [SHIRT]  = { r = 0xff, g = 0x00, b = 0x00 },
    [GLOVES] = { r = 0xff, g = 0xff, b = 0xff },
    [SHOES]  = { r = 0x72, g = 0x1c, b = 0x0e },
    [HAIR]   = { r = 0x73, g = 0x06, b = 0x00 },
    [SKIN]   = { r = 0xfe, g = 0xc1, b = 0x79 },
    [CAP]    = { r = 0xff, g = 0x00, b = 0x00 },
    [EMBLEM] = { r = 0xff, g = 0x00, b = 0x00 },
}

local function reset_mario_body_state()
    m = gMarioStates[0]
    if modelRevert.marioProcessed then
        for i = PANTS, EMBLEM do
            network_player_set_override_palette_color(np, i, modelRevert.palette[i])
        end

        m.marioBodyState.eyeState = modelRevert.eyeState
        m.marioBodyState.handState = modelRevert.handState
        m.marioBodyState.capState = modelRevert.capState
        m.marioBodyState.punchState = modelRevert.punchState
        m.marioBodyState.modelState = modelRevert.modelState
        m.fadeWarpOpacity = modelRevert.fadeWarpOpacity
        vec3f_copy(m.marioBodyState.heldObjLastPosition, modelRevert.holp)
        m.heldObj = modelRevert.heldObj
        m.marioBodyState.allowPartRotation = modelRevert.allowPartRotation
        vec3s_copy(m.marioBodyState.torsoAngle, modelRevert.torsoAngle)
        vec3s_copy(m.marioBodyState.headAngle, modelRevert.headAngle)
        vec3f_copy(m.marioBodyState.headPos, modelRevert.headPos)
        vec3s_copy(m.statusForCamera.headRotation, modelRevert.headRotation)

        modelRevert.marioProcessed = false
    end
end

local function character_obj_before_geo_process()
    local o = geo_get_current_object()
    if not o then return end
    if obj_has_behavior_id(o, id_bhvMario) ~= 0 and o.globalPlayerIndex == network_global_index_from_local(0) then
        reset_mario_body_state()
    elseif o.oIsChar ~= 0 then
        local modelData = charModelData[o] or {}
        local charPalette = modelData.palette or {}
        local anims

        if charSelectExists then
            local model = characterTable[o.oCharNum][o.oCharAlt].model
            local charSelectPalette = charSelect.character_get_current_palette(model, o.oCharPalette)
            if charSelectPalette then
                charPalette = charSelectPalette
            end
            anims = charSelect.character_get_animations(model)
        end


        if not modelRevert.marioProcessed then
            -- store revert palette AND update palette for obj
            for i = PANTS, EMBLEM do
                local playerColor = og_network_player_get_override_palette_color(np, i)
                modelRevert.palette[i] = {
                    r = playerColor.r,
                    g = playerColor.g,
                    b = playerColor.b,
                }
                network_player_set_override_palette_color(np, i, charPalette[i] or fallbackPalette[i])
            end

            modelRevert.eyeState = m.marioBodyState.eyeState
            modelRevert.handState = m.marioBodyState.handState
            modelRevert.capState = m.marioBodyState.capState
            modelRevert.punchState = m.marioBodyState.punchState
            modelRevert.modelState = m.marioBodyState.modelState
            modelRevert.fadeWarpOpacity = m.fadeWarpOpacity
            vec3f_copy(modelRevert.holp, m.marioBodyState.heldObjLastPosition)
            modelRevert.heldObj = m.heldObj
            m.heldObj = nil
            modelRevert.allowPartRotation = m.marioBodyState.allowPartRotation
            vec3s_copy(modelRevert.torsoAngle, m.marioBodyState.torsoAngle)
            vec3s_copy(modelRevert.headAngle, m.marioBodyState.headAngle)
            vec3f_copy(modelRevert.headPos, m.marioBodyState.headPos)
            vec3s_copy(modelRevert.headRotation, m.statusForCamera.headRotation)

            modelRevert.marioProcessed = true
        else
            -- only update palette for obj on subsequent models
            for i = PANTS, EMBLEM do
                network_player_set_override_palette_color(np, i, charPalette[i] or fallbackPalette[i])
            end
        end


        -- Set model data and defaults

        m.marioBodyState.eyeState = modelData.eyeState or MARIO_EYES_BLINK
        m.marioBodyState.handState = modelData.handState or MARIO_HAND_FISTS
        m.marioBodyState.capState = modelData.capState or MARIO_HAS_DEFAULT_CAP_ON
        m.marioBodyState.punchState = modelData.punchState or 0
        m.marioBodyState.modelState = ((modelData.modelState or 0) & ~0xFF) |
            (o.oOpacity < 0xFF and (0x100 | o.oOpacity) or 0)
        m.marioBodyState.allowPartRotation = 1
        vec_copy_or_default(m.marioBodyState.torsoAngle, modelData.torsoAngle, gVec3sZero)
        vec_copy_or_default(m.marioBodyState.headAngle, modelData.headAngle, gVec3sZero)
        vec_copy_or_default(m.statusForCamera.headRotation, modelData.headAngle, gVec3sZero)
        vec3f_zero(m.marioBodyState.headPos)

        if m.marioBodyState.eyeState == MARIO_EYES_BLINK then
            local blinkFrame = ((32 + (get_area_update_counter() + o.oCharNum * 32)) >> 1) & 0x1F
            if blinkFrame < 7 then
                m.marioBodyState.eyeState = blinkAnim[blinkFrame + 1]
            else
                m.marioBodyState.eyeState = MARIO_EYES_OPEN
            end
        end

        -- Find and apply any custom anims
        if anims then
            if not modelData.eyeState and anims.eyes and anims.eyes[o.oCharAnim] then
                m.marioBodyState.eyeState = run_func_or_get_var(anims.eyes[o.oCharAnim], m,
                    o.header.gfx.animInfo.animFrame)
            end
            if not modelData.handState and anims.hands and anims.hands[o.oCharAnim] then
                m.marioBodyState.handState = run_func_or_get_var(anims.hands[o.oCharAnim], m, o.header.gfx.animInfo
                    .animFrame)
            end
        end
    end
end

hook_event(HOOK_UPDATE, reset_mario_body_state)
hook_event(HOOK_BEFORE_PLAY_MODE_UPDATE, reset_mario_body_state)
hook_event(HOOK_BEFORE_GEO_PROCESS, character_obj_before_geo_process)
hook_event(HOOK_ON_GEO_PROCESS, reset_mario_body_state)

-- table cleanup
hook_event(HOOK_ON_OBJECT_UNLOAD, function(o)
    charModelData[o] = nil
end)
hook_event(HOOK_ON_LEVEL_INIT, function()
    charModelData = {}
end)

return {
    character_obj_set_animation = character_obj_set_animation,
    character_obj_play_sound = character_obj_play_sound,
    character_obj_get_model_data = character_obj_get_model_data,
    character_obj_loop = character_obj_loop,
}

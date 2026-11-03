local AddStategraphState = AddStategraphState
GLOBAL.setfenv(1, GLOBAL)

local PORTAL_PRE_STATE = "player_porkland_portal_pre"
local PORTAL_LOOP_STATE = "player_porkland_portal_loop"
local PORTAL_BUILD = "player_portal_hamlet"
local PORTAL_PRE_TIME = 3.5
local CLIENT_TIMEOUT = 30

local PORTAL_TAGS =
{
    "doing",
    "busy",
    "nopredict",
    "nomorph",
    "nodangle",
    "noattack",
    "nointerrupt",
    "noelectrocute",
}

local function StopPlayer(inst)
    inst.components.locomotor:Stop()
    inst.components.locomotor:StopMoving()
    inst.Physics:Stop()
end

local function SetInvincible(inst)
    inst.sg.statemem.was_invincible = inst.components.health.invincible
    inst.components.health:SetInvincible(true)
end

local function RestoreInvincibility(inst)
    inst.components.health:SetInvincible(inst.sg.statemem.was_invincible)
end

local function RestorePortalPresentation(inst)
    if inst.sg.statemem.portal_build then
        inst.AnimState:ClearOverrideBuild(PORTAL_BUILD)
    end
    if inst.sg.statemem.no_facing then
        inst.Transform:SetFourFaced()
    end
    if inst.sg.statemem.collision_mask ~= nil then
        inst.Physics:SetCollisionMask(inst.sg.statemem.collision_mask)
    end
    inst.DynamicShadow:Enable(true)
    if inst.sg.statemem.camera_changed then
        inst:SetCameraDistance()
    end
    RestoreInvincibility(inst)
end

local function MakePorklandPortalPreState()
    return State{
        name = PORTAL_PRE_STATE,
        tags = PORTAL_TAGS,

        onenter = function(inst, target)
            StopPlayer(inst)
            inst:ClearBufferedAction()
            inst:PushEvent("ms_closepopups")

            if inst.components.playercontroller ~= nil then
                inst.components.playercontroller:RemotePausePrediction()
            end
            if inst.components.rider ~= nil and inst.components.rider:IsRiding() then
                inst.components.rider:ActualDismount()
            end

            inst.sg.statemem.heavy = inst.components.inventory:IsHeavyLifting()
            SetInvincible(inst)

            if target ~= nil and target:IsValid() and target:HasTag("porkland_portal") then
                inst.sg.statemem.target = target
            end

            inst.AnimState:PlayAnimation(inst.sg.statemem.heavy and "heavy_idle" or "idle_loop", true)
            inst.sg:SetTimeout(PORTAL_PRE_TIME)
        end,

        timeline =
        {
            TimeEvent(30 * FRAMES, function(inst)
                inst.DynamicShadow:Enable(false)
                inst.sg.statemem.camera_changed = true
                inst:SetCameraDistance(14)
                inst.AnimState:PlayAnimation(inst.sg.statemem.heavy and "heavy_jump" or "jump")

                local fx = SpawnPrefab("wormhole_porkland_fx")
                fx.Transform:SetPosition(inst.Transform:GetWorldPosition())
            end),
        },

        ontimeout = function(inst)
            inst.sg.statemem.continue_to_portal_loop = true
            inst.sg:GoToState(PORTAL_LOOP_STATE, {
                camera_changed = inst.sg.statemem.camera_changed,
                heavy = inst.sg.statemem.heavy,
                was_invincible = inst.sg.statemem.was_invincible,
                target = inst.sg.statemem.target,
            })
        end,

        onexit = function(inst)
            if not inst.sg.statemem.continue_to_portal_loop then
                RestorePortalPresentation(inst)
            end
        end,
    }
end

local function MakePorklandPortalLoopState()
    return State{
        name = PORTAL_LOOP_STATE,
        tags = PORTAL_TAGS,

        onenter = function(inst, data)
            StopPlayer(inst)

            inst.sg.statemem.camera_changed = data.camera_changed == true
            inst.sg.statemem.heavy = data.heavy == true
            inst.sg.statemem.was_invincible = data.was_invincible
            inst.components.health:SetInvincible(true)

            inst.sg.statemem.collision_mask = inst.Physics:GetCollisionMask()
            inst.Physics:SetCollisionMask(COLLISION.GROUND)

            inst.sg.statemem.no_facing = true
            inst.Transform:SetNoFaced()
            inst.sg.statemem.portal_build = true
            inst.AnimState:AddOverrideBuild(PORTAL_BUILD)
            inst.AnimState:PlayAnimation("hamlet_portal_pre")
            inst.AnimState:PushAnimation("hamlet_portal_loop", true)

            local target = data.target
            if target ~= nil and target:IsValid() and target:HasTag("porkland_portal") then
                local x, y, z = target.Transform:GetWorldPosition()
                inst.Physics:Teleport(x, y, z)
            end
        end,

        onexit = RestorePortalPresentation,
    }
end

local function MakePorklandPortalClientState(name)
    return State{
        name = name,
        tags = { "doing", "busy" },
        server_states = { PORTAL_PRE_STATE, PORTAL_LOOP_STATE },

        onenter = function(inst)
            inst.components.locomotor:Stop()
            inst.components.locomotor:Clear()
            inst:ClearBufferedAction()
            inst.sg:SetTimeout(CLIENT_TIMEOUT)
        end,

        onupdate = function(inst)
            if inst.sg.timeinstate > 2 * FRAMES and inst.sg:ServerStateMatches() and
                inst.entity:FlattenMovementPrediction() then
                inst.sg:GoToState("idle", "noanim")
            end
        end,

        ontimeout = function(inst)
            if inst.sg:ServerStateMatches() then
                inst.sg:SetTimeout(CLIENT_TIMEOUT)
            else
                inst.sg:GoToState("idle", "cancel")
            end
        end,
    }
end

AddStategraphState("wilson", MakePorklandPortalPreState())
AddStategraphState("wilson", MakePorklandPortalLoopState())
AddStategraphState("wilson_client", MakePorklandPortalClientState(PORTAL_PRE_STATE))
AddStategraphState("wilson_client", MakePorklandPortalClientState(PORTAL_LOOP_STATE))

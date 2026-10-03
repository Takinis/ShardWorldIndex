local AddStategraphState = AddStategraphState
GLOBAL.setfenv(1, GLOBAL)

local function MakePorklandPortalPreState(server_states)
    return State{
        name = "player_porkland_portal_pre",
        tags = { "doing", "busy", "nopredict", "nomorph", "noattack", "nointerrupt" },
        server_states = server_states,

        onenter = function(inst, target)
            if server_states ~= nil then
                if inst.components.locomotor ~= nil then
                    inst.components.locomotor:Stop()
                end
                return
            end

            if inst.components.locomotor ~= nil then
                inst.components.locomotor:Stop()
                inst.components.locomotor:StopMoving()
            end
            inst:ClearBufferedAction()

            if inst.components.rider ~= nil and inst.components.rider:IsRiding() then
                inst.components.rider:ActualDismount()
            end

            inst.sg.statemem.heavy = inst.components.inventory ~= nil and
                inst.components.inventory:IsHeavyLifting()
            if inst.components.health ~= nil then
                inst.sg.statemem.was_invincible = inst.components.health.invincible
                inst.components.health:SetInvincible(true)
            end
            if target ~= nil and target:IsValid() and target:HasTag("porkland_portal") then
                inst.sg.statemem.target = target
            end

            inst.AnimState:PlayAnimation(inst.sg.statemem.heavy and "heavy_idle" or "idle_loop", true)
            inst.sg:SetTimeout(3.5)
        end,

        timeline = server_states == nil and
        {
            TimeEvent(30 * FRAMES, function(inst)
                if inst.DynamicShadow ~= nil then
                    inst.DynamicShadow:Enable(false)
                end
                inst.AnimState:PlayAnimation(inst.sg.statemem.heavy and "heavy_jump" or "jump")

                local fx = SpawnPrefab("wormhole_porkland_fx")
                if fx ~= nil then
                    fx.Transform:SetPosition(inst.Transform:GetWorldPosition())
                end
            end),
        } or nil,

        ontimeout = server_states == nil and function(inst)
            inst.sg.statemem.continue_to_portal_loop = true
            inst.sg:GoToState("player_porkland_portal_loop", {
                was_invincible = inst.sg.statemem.was_invincible,
                target = inst.sg.statemem.target,
            })
        end or nil,

        onexit = server_states == nil and function(inst)
            if not inst.sg.statemem.continue_to_portal_loop then
                if inst.DynamicShadow ~= nil then
                    inst.DynamicShadow:Enable(true)
                end
                if inst.components.health ~= nil and inst.sg.statemem.was_invincible ~= nil then
                    inst.components.health:SetInvincible(inst.sg.statemem.was_invincible)
                end
            end
        end or nil,
    }
end

local function MakePorklandPortalLoopState(server_states)
    return State{
        name = "player_porkland_portal_loop",
        tags = { "doing", "busy", "nopredict", "nomorph", "noattack", "nointerrupt" },
        server_states = server_states,

        onenter = function(inst, data)
            if server_states ~= nil then
                if inst.components.locomotor ~= nil then
                    inst.components.locomotor:Stop()
                end
                return
            end

            if inst.components.locomotor ~= nil then
                inst.components.locomotor:Stop()
                inst.components.locomotor:StopMoving()
            end
            inst.sg.statemem.was_invincible = data ~= nil and data.was_invincible or nil
            if inst.components.health ~= nil then
                inst.components.health:SetInvincible(true)
            end

            inst.Transform:SetNoFaced()
            inst.AnimState:AddOverrideBuild("player_portal_hamlet")
            inst.AnimState:PlayAnimation("hamlet_portal_pre")
            inst.AnimState:PushAnimation("hamlet_portal_loop", true)

            local target = data ~= nil and data.target or nil
            if target ~= nil and target:IsValid() and target:HasTag("porkland_portal") then
                inst.sg.statemem.target = target
                target:Hide()
                ChangeToInventoryPhysics(target)
                local x, y, z = target.Transform:GetWorldPosition()
                inst.Physics:Teleport(x, y, z)
            end
        end,

        onexit = server_states == nil and function(inst)
            inst.AnimState:ClearOverrideBuild("player_portal_hamlet")
            inst.Transform:SetFourFaced()
            local target = inst.sg.statemem.target
            if target ~= nil and target:IsValid() then
                target:Show()
                ChangeToObstaclePhysics(target, 1)
            end
            if inst.DynamicShadow ~= nil then
                inst.DynamicShadow:Enable(true)
            end
            if inst.components.health ~= nil and inst.sg.statemem.was_invincible ~= nil then
                inst.components.health:SetInvincible(inst.sg.statemem.was_invincible)
            end
        end or nil,
    }
end

local states =
{
    MakePorklandPortalPreState(),
    MakePorklandPortalLoopState(),
}

for _, state in ipairs(states) do
    AddStategraphState("wilson", state)
end

local client_states =
{
    MakePorklandPortalPreState({ "player_porkland_portal_pre" }),
    MakePorklandPortalLoopState({ "player_porkland_portal_loop" }),
}

for _, state in ipairs(client_states) do
    AddStategraphState("wilson_client", state)
end

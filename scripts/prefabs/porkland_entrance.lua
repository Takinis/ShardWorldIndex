require("prefabutil")

local assets = {
	Asset("ANIM", "anim/portal_hamlet.zip"),
	Asset("ANIM", "anim/portal_hamlet_build.zip"),
	Asset("ANIM", "anim/wormhole_hamlet.zip"),
}

local prefabs = {
	"collapse_small",
	"wormhole_porkland_fx",
}

local function GetWorldIndex()
	return ShardGameIndex ~= nil and ShardGameIndex.worldindex or nil
end

local function GetCurrentWorldType()
	local worldindex = GetWorldIndex()
	if worldindex ~= nil and worldindex.GetRuntimeWorldType ~= nil then
		return worldindex:GetRuntimeWorldType() or "forest"
	end
	if TheWorld ~= nil and TheWorld:HasTag("island") then
		return "shipwrecked"
	end
	if TheWorld ~= nil then
		for _, world_type in ipairs({ "porkland", "volcano", "shipwrecked", "forest" }) do
			if TheWorld:HasTag(world_type) then
				return world_type
			end
		end
	end
	return "forest"
end

local function Deny(doer, message)
	if doer ~= nil and doer.userid ~= nil and doer.userid ~= "" then
		SendModRPCToClient(GetClientModRPC(RPC_NAMESPACE, "WorldSwitchDenied"), doer.userid, message)
	end
end

local function RecoverPlayer(player)
	if player == nil or not player:IsValid() or not player.is_teleporting then
		return
	end

	player.is_teleporting = nil
	if player.sg ~= nil and player.sg.currentstate ~= nil then
		local state_name = player.sg.currentstate.name
		if state_name == "player_porkland_portal_pre" or
			state_name == "player_porkland_portal_loop" then
			player.sg:GoToState("idle")
		end
	end
	if player.SetCameraDistance ~= nil then
		player:SetCameraDistance()
	end
end

local function FinishFailedTransition(inst)
	if inst ~= nil and inst:IsValid() and not inst._worldindex_transitioning then
		return
	end

	if inst ~= nil and inst:IsValid() then
		inst._worldindex_transitioning = nil
		if inst.components.activatable ~= nil then
			inst.components.activatable.inactive = true
		end
		if inst.components.workable ~= nil then
			inst.components.workable:SetWorkable(true)
		end
	end

	for _, player in ipairs(AllPlayers or {}) do
		RecoverPlayer(player)
		Deny(player, STRINGS.UI.PORKLAND_ENTRANCE.TRANSITION_FAILED)
	end
end

local function StartTransitionPresentation(portal)
	for _, player in ipairs(AllPlayers or {}) do
		if player.components.health ~= nil and not player.components.health:IsDead() and
			not player:HasTag("playerghost") then
			player.is_teleporting = true
			if player.sg ~= nil then
				player.sg:GoToState("player_porkland_portal_pre", portal)
			end
		end
	end
end

local function BeginWorldSwitch(inst, target)
	local worldindex = GetWorldIndex()
	if worldindex == nil then
		FinishFailedTransition(inst)
		return
	end
	local opts = {
		kind = "world_index",
		reason = "porkland_entrance",
		file_id = target,
		reuse_existing = true,
		return_if_home = true,
		force_players_to_master_modname = RPC_NAMESPACE,
		force_players_to_master_rpcname = "ForcePlayersToMaster",
	}

	local function oncomplete(success)
		if not success then
			FinishFailedTransition(inst)
		end
	end

	local started = worldindex:RequestWorldDestination(target, opts, oncomplete)

	if started == false then
		FinishFailedTransition(inst)
	end
end

local function TravelToWorld(inst, doer, target)
	if doer == nil or not doer:IsValid() or not doer:IsNear(inst, 10) or
			type(target) ~= "string" or not PORKLAND_ENTRANCE_DESTINATIONS[target] then
		return false
	end

	local worldindex = GetWorldIndex()
	local state = worldindex ~= nil and worldindex:GetState() or nil
	if worldindex == nil then
		Deny(doer, STRINGS.UI.PORKLAND_ENTRANCE.UNAVAILABLE)
		return false
	end
	if state ~= nil and state.active == true and state.managed_externally == true then
		Deny(doer, STRINGS.UI.PORKLAND_ENTRANCE.MANAGED_EXTERNALLY)
		return false
	end
	if target == GetCurrentWorldType() then
		Deny(doer, STRINGS.UI.PORKLAND_ENTRANCE.ALREADY_THERE)
		return false
	end
	if inst._worldindex_transitioning then
		Deny(doer, STRINGS.UI.PORKLAND_ENTRANCE.IN_PROGRESS)
		return false
	end

	inst._worldindex_transitioning = true
	inst.components.activatable.inactive = false
	inst.components.workable:SetWorkable(false)
	StartTransitionPresentation(inst)
	inst:DoTaskInTime(5, BeginWorldSwitch, target)
	return true
end

local function OnActivate(inst, doer)
	local worldindex = GetWorldIndex()
	local state = worldindex ~= nil and worldindex:GetState() or nil
	if doer == nil or doer.userid == nil or doer.userid == "" then
		inst.components.activatable.inactive = true
		return false
	end
	if worldindex == nil then
		Deny(doer, STRINGS.UI.PORKLAND_ENTRANCE.UNAVAILABLE)
		inst.components.activatable.inactive = true
		return false
	end
	if state ~= nil and state.active == true and state.managed_externally == true then
		Deny(doer, STRINGS.UI.PORKLAND_ENTRANCE.MANAGED_EXTERNALLY)
		inst.components.activatable.inactive = true
		return false
	end
	if inst._worldindex_transitioning then
		Deny(doer, STRINGS.UI.PORKLAND_ENTRANCE.IN_PROGRESS)
		return false
	end

	SendModRPCToClient(
			GetClientModRPC(RPC_NAMESPACE, "PorklandEntranceDialog"),
		doer.userid,
		inst.GUID,
		GetCurrentWorldType()
	)
	inst.components.activatable.inactive = true
	return true
end

local function OnHammered(inst, worker)
	inst.components.lootdropper:DropLoot()
	local fx = SpawnPrefab("collapse_small")
	if fx ~= nil then
		fx.Transform:SetPosition(inst.Transform:GetWorldPosition())
		fx:SetMaterial("wood")
	end
	inst.SoundEmitter:PlaySound("dontstarve/common/destroy_wood")
	inst:Remove()
end

local function OnHit(inst)
	inst.AnimState:PlayAnimation("place")
	inst.AnimState:SetTime(0.65 * inst.AnimState:GetCurrentAnimationLength())
	inst.AnimState:PushAnimation("idle_off")
end

local function OnBuilt(inst)
	inst.AnimState:PlayAnimation("place")
	inst.AnimState:PushAnimation("idle_off")
	inst.SoundEmitter:PlaySound("dontstarve/common/place_structure_wood")
end

local function fn()
	local inst = CreateEntity()
	inst.entity:AddTransform()
	inst.entity:AddAnimState()
	inst.entity:AddSoundEmitter()
	inst.entity:AddMiniMapEntity()
	inst.entity:AddNetwork()

	MakeObstaclePhysics(inst, 1)

	inst.MiniMapEntity:SetIcon("portal.png")
	inst.AnimState:SetBank("hamportal")
	inst.AnimState:SetBuild("portal_hamlet_build")
	inst.AnimState:PlayAnimation("idle_off")

	inst:AddTag("porkland_portal")
	inst.no_wet_prefix = true

	inst.entity:SetPristine()

	if not TheWorld.ismastersim then
		return inst
	end

	inst:AddComponent("inspectable")
	inst.components.inspectable:RecordViews()

	inst:AddComponent("lootdropper")

	inst:AddComponent("activatable")
	inst.components.activatable.OnActivate = OnActivate
	inst.components.activatable.inactive = true
	inst.components.activatable.quickaction = true

	inst:AddComponent("workable")
	inst.components.workable:SetWorkAction(ACTIONS.HAMMER)
	inst.components.workable:SetWorkLeft(4)
	inst.components.workable:SetOnFinishCallback(OnHammered)
	inst.components.workable:SetOnWorkCallback(OnHit)

	inst.TravelToWorld = TravelToWorld
	inst:ListenForEvent("onbuilt", OnBuilt)

	return inst
end

local function wormhole_fn()
	local inst = CreateEntity()
	inst.entity:AddTransform()
	inst.entity:AddAnimState()
	inst.entity:AddNetwork()

	inst:AddTag("FX")
	inst.AnimState:SetBank("teleporter_worm")
	inst.AnimState:SetBuild("wormhole_hamlet")
	inst.AnimState:PlayAnimation("in")
	inst.AnimState:PushAnimation("out", false)
	inst.persists = false

	inst.entity:SetPristine()

	if TheWorld.ismastersim then
		inst:ListenForEvent("animqueueover", inst.Remove)
	end

	return inst
end

return Prefab("porkland_entrance", fn, assets, prefabs),
	MakePlacer("porkland_entrance_placer", "hamportal", "portal_hamlet_build", "idle_off"),
	Prefab("wormhole_porkland_fx", wormhole_fn, assets)

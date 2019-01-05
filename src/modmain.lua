-- Lua built-ins that are only accessible through GLOBAL
local require = GLOBAL.require
local setmetatable = GLOBAL.setmetatable

-- Detect Don't Starve Together
local is_dst = GLOBAL.TheSim:GetGameID() == "DST"

-- DS globals
local CreateEntity = GLOBAL.CreateEntity

local ImageButton = require("widgets/imagebutton")

local config = {
  enable_previews = GetModConfigData("enable_previews"),
  allow_equip_for_space = GetModConfigData("allow_equip_for_space"),
  reserve_saved_slots = GetModConfigData("reserve_saved_slots")
}

-- saved slot -> [item.prefab]
local items = {}

-- item.prefab -> saved slot
local slots = {}

-- item.prefab -> image button widget of item
local image_buttons = {}

-- Represents an object used to occupy an inventory slot temporarily
-- when we are moving items around
local OCCUPIED = { components = {} }
-- Another object we use to block an inventory slot, this one is used to reserve
-- saved slots when looking for an empty inventory slot for a new item
local RESERVED = { components = {} }

-- true if we are currently in the process of equipping some equipment
local is_equipping = false

-- entity to run tasks with, necessary to gain access to DoTaskInTime()
local tasker = CreateEntity()

-- Keeps track of equipment that is being manually moved,
-- in which case the saved slots might have to be updated.
local manually_moved_equipment = {}

-- Table to hold all local state of this mod.
local state = {
  inventory = nil,
  overflow = nil,

  -- When > 0, signals that this mod is moving items around.
  -- Controlled with fn.Lock() / fn.Unlock() and can be read with fn.IsLocked()
  -- Used to prevent updating saved slots during this time when items arrive in new slots.
  locks = 0,

  hud = {
    inventorybar = nil
  },

  -- true for all cases except when connected to a remote host in DST
  is_mastersim = true,

  -- cache of required prefabs
  prefab_cache = {},

  -- DST Client Mode: GUIDs of items that have already been processed
  -- when their clientside "itemget" event was raised.
  client_processed = {}
}

-- All functions will be stored in this table,
-- in this way we can bypass the Lua limitation that
-- a function X can only call other local functions that
-- are declared before X is declared.
-- When storing them all in a table, this limitation is removed.
local fn = {}

-- Table to hold the classes used by this mod;
-- MasterInventory, ClientInventory and ClientContainer
local new = {}

function fn.Lock()
  state.locks = state.locks + 1
end

function fn.Unlock()
  state.locks = state.locks - 1
end

function fn.IsLocked()
  return state.locks > 0
end

function fn.GetPlayer()
  if is_dst then
    -- It is renamed and a variable in DST
    return GLOBAL.ThePlayer
  else
    return GLOBAL.GetPlayer()
  end
end

-- Generates a table of item.prefab -> slot,
-- based on the current contents of the items variable
function fn.GetItemSlots()
  local slots = {}

  for slot, prefabs in pairs(items) do
    for _, prefab in ipairs(prefabs) do
      slots[prefab] = slot
    end
  end

  return slots
end

function fn.EachSavedSlot(callback)
  for slot, prefabs in pairs(items) do
    if #prefabs > 0 then
      callback(slot)
    end
  end
end

function fn.ReserveSavedSlots(inventory)
  fn.EachSavedSlot(function(slot)
    if not inventory.itemslots[slot] then
      inventory.itemslots[slot] = RESERVED
    end
  end)
end

function fn.UndoReserveSavedSlots(inventory)
  fn.EachSavedSlot(function(slot)
    local item = inventory.itemslots[slot]
    if item == RESERVED then
      inventory.itemslots[slot] = nil
    end
  end)
end

function fn.GetPlayerHud()
  local player = fn.GetPlayer()
  return player and player.HUD
end

function fn.GetPrefabData(prefab)
  if not state.prefab_cache[prefab] then
    GLOBAL.pcall(function()
      -- this call can fail, pcall will act as a try/catch mechanism
      state.prefab_cache[prefab] = require("prefabs/"..prefab)
    end)
  end

  return state.prefab_cache[prefab]
end

function fn.FindAtlas(prefab_data)
  if prefab_data and prefab_data.assets then
    for i, asset in ipairs(prefab_data.assets) do
      if asset.type == "ATLAS" then
        return asset.file
      end
    end
  end
end

function fn.GetAtlasAndImage(prefab)
  local prefab_data = fn.GetPrefabData(prefab)

  local image = prefab..".tex"
  local atlas

  if prefab_data then
    atlas = fn.FindAtlas(prefab_data)
  end

  return atlas or "images/inventoryimages.xml", image
end

function fn.CreateImageButton(prefab)
  if  not state.hud.inventorybar or
      not state.hud.inventorybar.toprow then
    return
  end

  local atlas, image = fn.GetAtlasAndImage(prefab)

  if not atlas or not image then
    return
  end

  local image_button = ImageButton(atlas, image)

  image_button:SetScale(0.9)

  image_button.Kill = fn.ImageButton_Kill(image_button.Kill, prefab)

  state.hud.inventorybar.toprow:AddChild(image_button)

  return image_button
end

-- Clears image_buttons cache and refreshes the preview
-- for the given prefab when the ImageButton is killed
function fn.ImageButton_Kill(original_fn, prefab)
  return function(self)
    -- Original Kill()
    original_fn(self)

    -- Clear cache
    image_buttons[prefab] = nil

    -- Refresh Preview
    fn.OnNextCycle(function()
      local slot = fn.GetSlot(prefab)
      if slot then
        fn.UpdatePreviewsForSlot(slot)
      end
    end)
  end
end

-- Runs the given function on the next processing cycle,
-- after all current threads have finished or yielded
function fn.OnNextCycle(onNextCycle)
  tasker:DoTaskInTime(0, onNextCycle)
end

function fn.UpdatePreviewsForSlot(slot)
  if not config.enable_previews or not items[slot] then
    return
  end

  if not state.hud.inventorybar then
    return
  end

  local invslot = state.hud.inventorybar.inv[slot]

  if not invslot then
    return
  end

  for item_index, prefab in ipairs(items[slot]) do
    local image_button = image_buttons[prefab]
    if not image_button then
      image_button = fn.CreateImageButton(prefab)

      if not image_button then
        return
      end

      image_buttons[prefab] = image_button
    end

    image_button:SetOnClick(function()
      fn.ClearSlot(prefab, slot)
    end)

    fn.UpdateImageButtonPosition(image_button, item_index, state.hud.inventorybar, invslot)
  end
end

function fn.UpdateImageButtonPosition(image_button, item_index, inventorybar, invslot)
  local invslot_pos = invslot:GetLocalPosition()

  if invslot_pos and invslot.bgimage then
    local _, invslot_height = invslot.bgimage:GetSize()

    if invslot_height then
      local _, image_button_height = image_button:GetSize()

      if image_button_height then
        -- Spacing between top of inventory bar and start of image button
        local spacing = 28
        image_button:SetPosition(invslot_pos.x, invslot_pos.y + invslot_height + spacing + (item_index - 1) * image_button_height)
        if image_button.o_pos then
          -- The game itself stores some "original position"
          -- when a button is focused and updates the button's position
          -- to that position when the button loses focus.
          -- However, this does not work properly in some cases when we
          -- have already shifted the button position, causing the game
          -- to move the button back to some previous position.
          -- Thus, we also update this (internal) o_pos value when
          -- it has a value.
          image_button.o_pos = image_button:GetLocalPosition()
        end
      end
    end
  end
end

function fn.RefreshImageButtons()
  for _, btn in pairs(image_buttons) do
    btn:Kill()
  end
end

function fn.ClearPreview(prefab)
  local image = image_buttons[prefab]

  if image then
    image:Kill()
    image_buttons[prefab] = nil
  end
end

function fn.RemoveFromTable(tbl, fn, one)
  if type(tbl) == "table" then
    for i = #tbl, 1, -1 do
      if fn(tbl[i]) then
        table.remove(tbl, i)
        if one then return end
      end
    end
  end
end

function fn.ClearTable(tbl)
  for k, _ in pairs(tbl) do
    tbl[k] = nil
  end
end

function fn.CallOrValue(v, ...)
  return type(v) == "function" and v(...) or v
end

function fn.GetComponent(o, component_name)
  if o then
    if state.is_mastersim then
      return o.components and o.components[component_name]
    else
      -- non mastersims only interact with the replica
      return o.replica and o.replica[component_name]
    end
  end
end

function fn.IfHasComponent(o, component_name, ifFn, ifNot)
  local component = fn.GetComponent(o, component_name)

  if component then
    return type(ifFn) == "function" and ifFn(component) or component
  else
    return fn.CallOrValue(ifNot)
  end
end

function fn.WhenFiniteUses(item, when, whenNot)
  return fn.IfHasComponent(item, "finiteuses", when, whenNot)
end

function fn.GetRemainingUses(item)
  return fn.WhenFiniteUses(item, function(fu)
    -- Never return nil, if .current is nil we return 0 instead.
    return fu.current or 0
  end,
  -- When the item does not have a finiteuses component
  -- we treat it as never used, i.e. 100.
  100)
end

function fn.IsFiniteUses(item)
  return fn.IfHasComponent(item, "finiteuses")
end

function fn.GetSlot(prefab)
  if prefab then
    return slots[prefab]
  end
end

function fn.Equals(obj)
  return function(other)
    return other == obj
  end
end

function fn.SaveSlot(prefab, slot)
  local prev_slot = fn.GetSlot(prefab)
  if prev_slot then
    fn.ClearSlot(prefab, prev_slot)
  end

  if not items[slot] then
    items[slot] = {}
  end

  table.insert(items[slot], prefab)

    -- Update slot table as items has been changed
  slots = fn.GetItemSlots()

  fn.UpdatePreviewsForSlot(slot)
end

function fn.ClearSlot(prefab, slot)
  if not prefab or not slot or not items[slot] then
    return
  end

  -- Remove from items
  fn.RemoveFromTable(items[slot], function(p) return p == prefab end, true)

  -- Remove entire key if this was the last item
  if #items[slot] == 0 then
    items[slot] = nil
  end

  fn.ClearPreview(prefab)

  -- Update slot table as items has been changed
  slots = fn.GetItemSlots()

  fn.UpdatePreviewsForSlot(slot)
end

function fn.HasSlot(prefab)
  return fn.GetSlot(prefab) ~= nil
end

function fn.GetItemOwner(item)
  return fn.IfHasComponent(item, "inventoryitem", function(inventoryitem)
    return inventoryitem:GetGrandOwner()
  end)
end

-- Specifies if item is equipment
function fn.IsEquipment(item)
  return fn.IfHasComponent(item, "equippable", true, false)
end

function fn.GetEquipSlot(item)
  return fn.WhenEquippable(item, function(eq)
    local equipslot = eq.EquipSlot and eq:EquipSlot() or eq.equipslot
    return equipslot
  end)
end

function fn.WhenEquippable(item, when, whenNot)
  return fn.IfHasComponent(item, "equippable", when, whenNot)
end

function fn.GetOverflowContainer(inventory)
  if is_dst then
    return inventory:GetOverflowContainer()
  else
    return fn.IfHasComponent(inventory.overflow, "container")
  end
end

-- Works like Inventory:GetNextAvailableSlot, but first tries to find
-- space outside of the saved slots. When that fails it will revert to the
-- default implementation
function fn.TrySkipSavedSlots(inventory, item, original_fn)
  fn.ReserveSavedSlots(inventory)
  local original_slot, original_container = original_fn(inventory, item)
  fn.UndoReserveSavedSlots(inventory)

  if original_slot == nil and original_container == inventory.itemslots then
    -- Game reports no space, but is unaware of the overflow in most scenarios
    -- so we will check it again ourselves and put the item there if possible
    local container = fn.GetOverflowContainer(inventory)
    local overflow = is_dst and container or inventory.overflow

    if container then
      for i = 1, container.numslots do
        if container.slots[i] == nil then
          if container:GiveItem(item, nil, nil, false, true) then
            return 0, overflow
          end
        end
      end
    end

    -- Try again, this time the saved slots are unblocked.
    original_slot, original_container = original_fn(inventory, item)
  end

  return original_slot, original_container
end

function fn.Inventory_GetNextAvailableSlot(original_fn)
  return function(self, item)
    local saved_slot = fn.GetSlot(item.prefab)

    if not saved_slot or not fn.IsEquipment(item) then
      if config.reserve_saved_slots then
        return fn.TrySkipSavedSlots(self, item, original_fn)
      else
        return original_fn(self, item)
      end
    end

    if not state.inventory then
      return original_fn(self, item)
    end

    local made_space = state.inventory:MakeSpace(saved_slot, item)

    if not made_space then
      if config.reserve_saved_slots then
        return fn.TrySkipSavedSlots(self, item, original_fn)
      else
        -- Let the game decide where to put the new equipment.
        -- This would be the behavior of the normal game
        return original_fn(self, item)
      end
    else
      -- saved_slot is available
      return saved_slot, self.itemslots
    end
  end
end

function fn.Inventory_Equip(original_fn)
  return function(self, item, old_to_active)
    is_equipping = true

    local original_return = original_fn(self, item, old_to_active)

    is_equipping = false

    return original_return
  end
end

function fn.Inventory_OnEquip(inst, data)
  local item = data.item
  local eslot = data.eslot

  if not fn.IsEquipment(item) then
    return
  end

  if state.is_mastersim then
    -- There is a strange bug in the base
    -- game where equipment that has ever been in
    -- your backpack will go straight back to the backback
    -- when unequipped, even if you have put it in your regular
    -- inventory afterwards. This is different from the behavior
    -- without a backpack, the game will (even without this mod)
    -- always try to put equipment back where it came from.
    -- We will fix this here by simply clearing the item's prevcontainer
    -- whenever it is equipped, which would point to the backpack when it was ever in there.
    item.prevcontainer = nil

    -- We also clear the item's prevslot to prevent the game from trying
    -- to put it there when unequipping the item, as this is not always
    -- what we would want when we have multiple copies of an equipment.
    -- For example, when we have assigned the Axe to slot 2 but have picked up
    -- a second copy that is now stored in slot 3, we do not want the game
    -- to try to put it back directly to slot 3 when unequipping, as slot 2
    -- might be available at that time. The game bypasses the GetNextAvailableSlot()
    -- function when prevslot has a value and is available, so we clear it here.
    item.prevslot = nil
  else
    fn.IfHasComponent(item, "container", function(container)
      fn.InitOverflow(inst, container)
    end)
  end
end

function fn.IsMasterSim()
  if not is_dst then
    return true
  end

  if GLOBAL.TheWorld then
    return not not GLOBAL.TheWorld.ismastersim
  else
    return true
  end
end

function fn.DebugPrintTable(tbl, prefix, depth)
  local depth = depth or 1

  if depth > 4 then
    -- prevent endless loops on recursive tables
    return
  end

  for k,v in pairs(tbl) do
    local key = (prefix or "")..tostring(k)

    if type(v) == "table" then
      fn.DebugPrintTable(v, key..".", depth + 1)
    else
      print(key.." = "..tostring(v))
    end
  end
end

function fn.Inventory_OnItemGet(inst, data)
  local item = data.item
  local slot = data.slot

  if  not state.inventory or fn.IsLocked() or
      not slot or not fn.IsEquipment(item) then
    return
  end

  if not state.is_mastersim and fn.IsDuplicateItemGetEvent(data) then
    return
  end

  local saved_slot, blocking_item, was_manually_moved = fn.GetItemMeta(item)
  local prefab_is_in_saved_slot = blocking_item and blocking_item.prefab == item.prefab

  local should_save_slot = not prefab_is_in_saved_slot and (was_manually_moved or not fn.HasSlot(item.prefab))

  if should_save_slot then
    fn.SaveSlot(item.prefab, slot)
  elseif not state.is_mastersim then
    -- DST client mode: move item to its saved slot if needed
    fn.TryMoveToSavedSlot(item, state.inventory, slot)
  end
end

function fn.IsDuplicateItemGetEvent(data)
  if not data or not data.item or not data.item.GUID then
    return false
  end

  local item = data.item
  local is_server_event = not not data.ignore_stacksize_anim

  if is_server_event then
    if state.client_processed[item.GUID] then
      state.client_processed[item.GUID] = nil
      return true
    end
  else
    state.client_processed[item.GUID] = true
  end

  return false
end

function fn.GetItemMeta(item)
  local saved_slot = fn.GetSlot(item.prefab)
  local blocking_item = saved_slot and state.inventory:GetItem(saved_slot)
  local was_manually_moved = not not manually_moved_equipment[item.GUID]

  return saved_slot, blocking_item, was_manually_moved
end

function fn.TryMoveToSavedSlot(item, container, slot)
  if  not state.inventory or fn.IsLocked() or not slot or
      not container or not fn.IsEquipment(item) then
    return
  end

  local saved_slot, blocking_item, was_manually_moved = fn.GetItemMeta(item)
  local is_correct_slot = not saved_slot or (container == state.inventory and saved_slot == slot)

  if was_manually_moved or is_correct_slot then
    -- Item will not be moved
    return false
  end

  local function move()
    container:MoveToInventory(slot, state.inventory, saved_slot)
  end

  if not blocking_item then
    move()
    return true
  else
    local should_move, action = fn.ShouldMove(saved_slot, blocking_item, item)
    if should_move then
      if action == "equip" then
        state.inventory:Equip(saved_slot, move)
        return true
      elseif action == "move" then
        container:SwapWithInventory(slot, state.inventory, saved_slot)
        return true
      end
    end
  end

  return false
end

function fn.CanEquip(item)
  if is_equipping or not fn.IsEquipment(item) then
    return false
  end

  local eslot = fn.GetEquipSlot(item)
  if not eslot then
    return false
  end

  local equipped_item = state.inventory:GetEquippedItem(eslot)
  return not equipped_item
end

function fn.Inventory_OnLoad(original_fn)
  return function(self, data, newents)
    original_fn(self, data, newents)

    if data.save_equipment_slots then
      items = data.save_equipment_slots
      slots = fn.GetItemSlots()
    end
  end
end

function fn.Inventory_OnSave(original_fn)
  return function(self)
    local data = original_fn(self)
    data.save_equipment_slots = items
    return data
  end
end

function fn.IfFn(value, ...)
  if type(value) == "function" then
    value(...)
  end
end

-- true if the blocking_item in the slot should be moved to make space for item
function fn.ShouldMove(slot, blocking_item, item)
  if not blocking_item then
    return false
  end

  if blocking_item == OCCUPIED then
    return false
  end

  local blocking_item_saved_slot = fn.GetSlot(blocking_item.prefab)

  if not fn.IsEquipment(blocking_item) or blocking_item_saved_slot ~= slot then
    return true, "move"
  end

  local equip_blocking_item =
    config.allow_equip_for_space and
    fn.CanEquip(blocking_item)

  local move_blocking_item =
    not equip_blocking_item and
    blocking_item.prefab == item.prefab and
    fn.IsFiniteUses(item) and
    fn.GetRemainingUses(item) < fn.GetRemainingUses(blocking_item)

  if equip_blocking_item then
    return true, "equip"
  elseif move_blocking_item then
    return true, "move"
  else
    return false
  end
end

function fn.CreateMasterInventory()
  local MasterInventory = {}
  MasterInventory.__index = MasterInventory

  function MasterInventory.new(inventory)
    local instance = {
      inventory = inventory
    }

    setmetatable(instance, MasterInventory)

    return instance
  end

  function MasterInventory:GetItem(slot)
    return self.inventory.itemslots[slot]
  end

  function MasterInventory:SetItem(slot, item)
    self.inventory.itemslots[slot] = item
  end

  function MasterInventory:MakeSpace(slot, item)
    local blocking_item = self:GetItem(slot)

    if not blocking_item then
      -- It's already empty
      return true
    end

    local should_move, action = fn.ShouldMove(slot, blocking_item, item)

    if not should_move then
      return false
    end

    if action == "equip" then
      self:Equip(blocking_item)
    elseif action == "move" then
      self:MoveAway(slot)
    end

    return true
  end

  function MasterInventory:MoveAway(from)
    local blocking_item = self:GetItem(from)
    if not blocking_item then
      return
    end

    -- Before moving the item, we occupy its current slot with the OCCUPIED object
    -- otherwise the game would not move blocking_item at all,
    -- presumably as it is already present in the inventory.
    -- In addition, the OCCUPIED object makes sure this slot will not be touched
    -- again in a recursive call to this method which would otherwise possibly try to
    -- move the this item again or equip it.
    self:SetItem(from, OCCUPIED)

    -- Record the fact we are automatically moving items
    fn.Lock()

    -- Find a new slot for the blocking item -- skipping the sound
    self.inventory:GiveItem(blocking_item, nil, nil, true)

    fn.Unlock()

    -- The saved_slot is cleared as we have made space by moving away blocking_item.
    -- The game will be putting item in there at a slightly later time
    self:SetItem(from, nil)
  end

  function MasterInventory:Equip(item)
    self.inventory:Equip(item)
  end

  function MasterInventory:GetEquippedItem(eslot)
    return self.inventory:GetEquippedItem(eslot)
  end

  return MasterInventory
end

function fn.CreateClientContainer()
  local ClientContainer = {}
  ClientContainer.__index = ClientContainer

  function ClientContainer.new(container)
    local instance = {
      container = container
    }

    setmetatable(instance, ClientContainer)

    return instance
  end

  local function CancelRefreshTask(container)
    if  container.classified and
        container.classified._refreshtask and
        type(container.classified._refreshtask.Cancel) == "function" then
      container.classified._refreshtask:Cancel()
      container.classified._refreshtask = nil
      container.classified._busy = false
      return true
    else
      return false
    end
  end

  function ClientContainer:IsBusy()
    return  self.container and self.container.classified and
            self.container.classified.IsBusy and self.container.classified:IsBusy()
  end

  function ClientContainer:WhenNotBusy(whenFn, skipCancel)
    if self:IsBusy() then
      local function retry()
        self:WhenNotBusy(whenFn, true)
      end

      if not skipCancel and CancelRefreshTask(self.container) then
        retry()
      else
        fn.OnNextCycle(retry)
      end
    else
      whenFn()
    end
  end

  function ClientContainer:SlotToActiveItem(from, nextFn)
    self:WhenNotBusy(function()
      self.container:TakeActiveItemFromAllOfSlot(from)
      fn.IfFn(nextFn)
    end)
  end

  function ClientContainer:ActiveItemToSlot(slot, nextFn)
    self:WhenNotBusy(function()
      self.container:PutAllOfActiveItemInSlot(slot)
      fn.IfFn(nextFn)
    end)
  end

  function ClientContainer:ReturnActiveItem(nextFn)
    self:WhenNotBusy(function()
      self.container:ReturnActiveItem()
      fn.IfFn(nextFn)
    end)
  end

  function ClientContainer:SwapActiveItemWithSlot(slot, nextFn)
    self:WhenNotBusy(function()
      self.container:SwapActiveItemWithSlot(slot)
      fn.IfFn(nextFn)
    end)
  end

  function ClientContainer:SwapWithInventory(from, inventory, to, nextFn)
    fn.Lock()
    inventory:WhenNotBusy(function()
      self:SlotToActiveItem(from, function()
        inventory:SwapActiveItemWithSlot(to, function()
          inventory:WhenNotBusy(function()
            self:ActiveItemToSlot(from, function()
              fn.Unlock()
              fn.IfFn(nextFn)
            end)
          end)
        end)
      end)
    end)
  end

  function ClientContainer:MoveToInventory(from, inventory, to, nextFn)
    fn.Lock()

    inventory:WhenNotBusy(function()
      self:SlotToActiveItem(from, function()
        inventory:ActiveItemToSlot(to, function()
          fn.Unlock()
          fn.IfFn(nextFn)
        end)
      end)
    end)
  end

  return ClientContainer
end

function fn.CreateClientInventory(ClientContainer)
  local ClientInventory = {}
  ClientInventory.__index = ClientInventory

  setmetatable(ClientInventory, ClientContainer)

  function ClientInventory.new(inventory)
    local instance = ClientContainer.new(inventory)

    instance.inventory = inventory

    setmetatable(instance, ClientInventory)

    return instance
  end

  function ClientInventory:GetEquippedItem(eslot)
    return self.inventory:GetEquippedItem(eslot)
  end

  function ClientInventory:GetItem(slot)
    return self.inventory:GetItemInSlot(slot)
  end

  function ClientInventory:Equip(slot, nextFn)
    is_equipping = true
    fn.Lock()
    self:SlotToActiveItem(slot, function()
      self:EquipActiveItem(function()
        is_equipping = false
        fn.Unlock()
        fn.IfFn(nextFn)
      end)
    end)
  end

  function ClientInventory:EquipActiveItem(nextFn)
    self:WhenNotBusy(function()
      self.inventory:EquipActiveItem()
      fn.IfFn(nextFn)
    end)
  end

  return ClientInventory
end

function fn.InitClasses()
  local MasterInventory = fn.CreateMasterInventory()
  local ClientContainer = fn.CreateClientContainer()
  local ClientInventory = fn.CreateClientInventory(ClientContainer)

  new.MasterInventory = MasterInventory.new
  new.ClientContainer = ClientContainer.new
  new.ClientInventory = ClientInventory.new
end

function fn.InitOverflow(inventory_inst, overflow)
  if  not overflow or not overflow.inst or
      type(overflow.inst.ListenForEvent) ~= "function" then
    return
  end

  state.overflow = new.ClientContainer(overflow)

  local eslot = fn.GetEquipSlot(overflow.inst)
  local evt = {}

  local function OnItemGet(...) evt.OnItemGet(...) end
  local function OnUnequip(...) evt.OnUnequip(...) end

  overflow.inst:ListenForEvent("itemget", OnItemGet)
  inventory_inst:ListenForEvent("unequip", OnUnequip)

  function evt.OnItemGet(inst, data)
    local item = data.item
    local slot = data.slot

    if  not item or not fn.IsEquipment(item) or fn.IsLocked() or
        not state.overflow or not state.inventory then
      return
    end

    if not state.is_mastersim and fn.IsDuplicateItemGetEvent(data) then
      return
    end

    fn.TryMoveToSavedSlot(item, state.overflow, slot)
  end

  function evt.OnUnequip(inst, data)
    if data and data.eslot == eslot then
      if type(overflow.inst.RemoveEventCallback) == "function" then
        overflow.inst:RemoveEventCallback("itemget", OnItemGet)
        state.overflow = nil
      end

      inventory_inst:RemoveEventCallback("unequip", OnUnequip)
    end
  end
end

function fn.Inventory_OnNewActiveItem(inst, data)
  if fn.IsLocked() then
    return
  end

  local item = data.item

  if item == nil then
    manually_moved_equipment.dirty = false
    fn.OnNextCycle(function()
      if not manually_moved_equipment.dirty then
        fn.ClearTable(manually_moved_equipment)
      end
    end)
  elseif fn.IsEquipment(item) then
    manually_moved_equipment[item.GUID] = true
    manually_moved_equipment.dirty = true
  end
end

function fn.Inventorybar_Rebuild(original_fn)
  return function(self)
    original_fn(self)
    fn.OnNextCycle(fn.RefreshImageButtons)
  end
end

function fn.InitInventorybar(inventorybar)
  state.hud.inventorybar = inventorybar

  if type(inventorybar.Rebuild) == "function" then
    inventorybar.Rebuild = fn.Inventorybar_Rebuild(inventorybar.Rebuild)
  end
end

function fn.InitInventory(inventory)
  inventory.inst:ListenForEvent("equip", fn.Inventory_OnEquip)
  inventory.inst:ListenForEvent("itemget", fn.Inventory_OnItemGet)
  inventory.inst:ListenForEvent("newactiveitem", fn.Inventory_OnNewActiveItem)

  if state.is_mastersim then
    state.inventory = new.MasterInventory(inventory)

    inventory.GetNextAvailableSlot = fn.Inventory_GetNextAvailableSlot(inventory.GetNextAvailableSlot)
    inventory.Equip = fn.Inventory_Equip(inventory.Equip)
    inventory.OnSave = fn.Inventory_OnSave(inventory.OnSave)
  else
    state.inventory = new.ClientInventory(inventory)

    local overflow = inventory:GetOverflowContainer()
    if overflow then
      fn.InitOverflow(inventory.inst, overflow)
    end
  end
end

function fn.InitSaveEquipmentSlots()
  AddSimPostInit(function()
    state.is_mastersim = fn.IsMasterSim()
  end)

  AddPlayerPostInit(function(player)
    fn.OnNextCycle(function()
      if player == fn.GetPlayer() then
        -- Only initialize for the current player
        fn.IfHasComponent(player, "inventory", fn.InitInventory)
      end
    end)
  end)

  AddComponentPostInit("inventory", function(inventory)
    -- AddPlayerPostInit triggers after Inventory.OnLoad
    -- so we use AddComponentPostInit for this specific one
    if type(inventory.OnLoad) == "function" then
      inventory.OnLoad = fn.Inventory_OnLoad(inventory.OnLoad)
    end
  end)

  AddClassPostConstruct("widgets/inventorybar", fn.InitInventorybar)

  AddClassPostConstruct("widgets/invslot", function(invslot)
    fn.OnNextCycle(function()
      fn.UpdatePreviewsForSlot(invslot.num)
    end)
  end)

  fn.InitClasses()
end

fn.InitSaveEquipmentSlots()

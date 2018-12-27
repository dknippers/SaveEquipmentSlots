-- Lua built-ins that are only accessible through GLOBAL
local require = GLOBAL.require

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

-- The equipment that was just manually moved by the player
-- by dragging it into a new inventory slot. this is used to determine
-- whether an item's slot should be updated when the inventory reports it
-- as a new item.
local manually_moved_equipment = nil

-- Represents an object used to occupy an inventory slot temporarily
-- when we are automatically rearranging items
local OCCUPIED = { components = {} }
-- Another object we use to block an inventory slot, this one is used to reserve
-- saved slots when looking for an empty inventory slot for a new item
local RESERVED = { components = {} }

-- true if we are currently in the process of equipping some equipment
local is_equipping = false

-- entity to run tasks with, necessary to gain access to DoTaskInTime()
local tasker = CreateEntity()

-- functions to be executed later, in insertion order (DoTaskInTime() does not guarantee the order)
local fns = {}

-- set to true when RunFns() has been scheduled to run using DoTaskInTime()
local runfns_scheduled = false

-- when unequipping / obtaining a piece of equipment,
-- we sometimes rearrange other items to put the new item
-- in its saved slot. when this relocation process is underway
-- (i.e., rearranging > 0), we will not be changing any of
-- the saved slots, as the player is not manually moving anything.
-- this is a number as it can be going on for more than 1
-- item at a time through recursive calls to
local rearranging = 0

-- Table to hold all local state of this mod.
local state = {
  inventory = nil,

  hud = {
    inventorybar = nil
  },

  -- true for all cases except when connected to a remote host in DST
  is_mastersim = true
}

-- All functions will be stored in this table,
-- in this way we can bypass the Lua limitation that
-- a function X can only call other local functions that
-- are declared before X is declared.
-- When storing them all in a table, this limitation is removed.
local fn = {}

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

function fn.CreateImageButton(prefab)
  if not state.hud.inventorybar then
    return
  end

  -- We used to get atlas and image info dynamically (using inventoryitem:GetAtlas() and
  -- inventoryitem:GetImage(), but in DST we could not easily create an inventoryitem based
  -- on a prefab on a non-host player, thus atlas is made a constant and image is
  -- now determined based on prefab alone.
  -- If this causes issues at some point we can revert the old behavior at least for non-DST,
  -- but this approach is more efficient anyway so if there are no reports of missing icons this
  -- will remain, and this comment will be removed at a later point.
  local atlas = "images/inventoryimages.xml"
  local image = prefab..".tex"

  local image_button = ImageButton(atlas, image)

  image_button:SetScale(0.9)

  state.hud.inventorybar:AddChild(image_button)

  return image_button
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

      -- Spacing between top of inventory bar and start of image button
      local spacing = 28
      image_button:SetPosition(invslot_pos.x, invslot_pos.y + spacing + (invslot_height * 2) + (item_index - 1) * image_button_height)
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

function fn.callOrValue(v, ...)
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
    return fn.callOrValue(ifNot)
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

-- Runs all functions in the fns table and removes them after
function fn.RunFns()
  local len = #fns

  -- Run
  for _, func in ipairs(fns) do
    func()
  end

  -- Clear
  for i = len, 1, -1 do
    table.remove(fns, i)
  end
end

-- Queues the specified function to be run on the next processing cycle
function fn.QueueFunc(func)
  table.insert(fns, func)

  if not runfns_scheduled then
    runfns_scheduled = true
    fn.OnNextCycle(function()
      fn.RunFns()
      runfns_scheduled = false
    end)
  end
end

function fn.HandleNewActiveItem(new_item)
  if fn.IsEquipment(new_item) then
    manually_moved_equipment = new_item
  else
    if manually_moved_equipment then
      manually_moved_equipment = nil
    end
  end
end

function fn.CanEquip(item, inventory)
  if is_equipping then
    -- We are currently in the process of equipping something else,
    -- we cannot equip any item now
    return false
  end

  local equipslot = fn.GetEquipSlot(item)
  if equipslot then
    return inventory.equipslots[equipslot] == nil
  else
    return false
  end
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

    local resolved = state.inventory.ResolveBlock(saved_slot, item)

    if not resolved then
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

function fn.Inventory_OnItemGet(inst, data)
  local item = data.item
  local slot = data.slot

  if not state.inventory or rearranging > 0 or not slot or not fn.IsEquipment(item) then
    return
  end

  local saved_slot = fn.GetSlot(item.prefab)
  local item_in_saved_slot = state.inventory.GetItem(saved_slot)
  local prefab_is_in_saved_slot = item_in_saved_slot and item_in_saved_slot.prefab == item.prefab

  -- Save equipment slot if the item was either manually moved
  -- or has never been picked up before.
  -- The latter case makes sure the very first time an item is picked up (or when
  -- the slot was cleared by the user later) the slot it is put in is saved so on
  -- subsequent equip / unequip actions it will already return to that first slot
  -- without the player having to put it there explicitly.
  local save_slot = not prefab_is_in_saved_slot and (manually_moved_equipment == item or not fn.HasSlot(item.prefab))

  if save_slot then
    fn.SaveSlot(item.prefab, slot)
  elseif saved_slot and slot ~= saved_slot and not state.is_mastersim then
    -- DST to remote host: make sure item returns to its slot here
    local function move()
      state.inventory.Move(slot, saved_slot)
    end

    if item_in_saved_slot then
      state.inventory.ResolveBlock(saved_slot, item, function(resolved)
        if resolved then
          move()
        end
      end)
    else
      move()
    end
  end
end

function fn.Inventory_OnNewActiveItem(inst, data)
  local item = data.item

  -- Logic itself is queued until all actions are resolved,
  -- this is necessary as the active item is first removed before
  -- it's being put in the inventory, and we do not want to clear the manually moved equipment
  -- before that has happened as we use its value there.
  -- QueueFunc will guarantee the queued functions are executed in order
  -- as opposed to DoTaskInTime.
  fn.QueueFunc(function()
    fn.HandleNewActiveItem(item)
  end)
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

function fn.MakeInventory(inventory, is_mastersim)
  -- The table representing the inventory interface
  -- we will create based on the given inventory and
  -- whether or not we are the master simulation
  local inv = {}

  function inv.GetEquippedItem(eslot)
    return inventory:GetEquippedItem(eslot)
  end

  function inv.GetItem(slot)
    return inventory:GetItemInSlot(slot)
  end

  function inv.CanEquip(item)
    if is_equipping or not fn.IsEquipment(item) then
      return false
    end

    local eslot = fn.GetEquipSlot(item)
    local equipped_item = inv.GetEquippedItem(eslot)

    return not equipped_item
  end

  function inv.GetFreeSlot(skip)
    local num_items = inventory:GetNumSlots()
    for slot = 1, num_items do
      if slot ~= skip and not inv.GetItem(slot) then
        return slot
      end
    end

    -- TODO: Look in backpack
  end

  function inv.ResolveBlock(target_slot, item, callback)
    local blocking_item = inv.GetItem(target_slot)

    local function trueCallback() fn.IfFn(callback, true) end
    local function falseCallback() fn.IfFn(callback, false) end
    local function variableCallback(success) fn.IfFn(callback, success) end

    if not blocking_item then
      trueCallback()
      return true
    end

    if blocking_item == OCCUPIED then
      falseCallback()
      return false
    end

    local blocking_item_saved_slot = fn.GetSlot(blocking_item.prefab)

    if not fn.IsEquipment(blocking_item) or blocking_item_saved_slot ~= target_slot then
      inv.Move(target_slot, variableCallback)
      return true
    end

    local equip_blocking_item =
      config.allow_equip_for_space and
      inv.CanEquip(blocking_item)

    local move_blocking_item =
      not equip_blocking_item and
      not blocking_item.prefab == item.prefab and
      fn.IsFiniteUses(item) and
      fn.GetRemainingUses(item) < fn.GetRemainingUses(blocking_item)

    if not equip_blocking_item and not move_blocking_item then
      -- Not resolved
      falseCallback()
      return false
    else
      if equip_blocking_item then
        inv.Equip(blocking_item, trueCallback)
      elseif move_blocking_item then
        inv.Move(target_slot, variableCallback)
      end

      -- It was either equipped or moved
      return true
    end
  end

  if is_mastersim then
    function inv.Move(from)
      local blocking_item = inventory.itemslots[from]
      if not blocking_item then
        return
      end

      -- Before moving the item, we occupy its current slot with the OCCUPIED object
      -- otherwise the game would not move blocking_item at all,
      -- presumably as it is already present in the inventory.
      -- In addition, the OCCUPIED object makes sure this slot will not be touched
      -- again in a recursive call to this method which would otherwise possibly try to
      -- move the this item again or equip it.
      inventory.itemslots[from] = OCCUPIED

      -- Record the fact we are automatically rearranging items
      rearranging = rearranging + 1

      -- Find a new slot for the blocking item -- skipping the sound
      inventory:GiveItem(blocking_item, nil, nil, true)

      rearranging = rearranging - 1

      -- The saved_slot is cleared as we have made space by moving away blocking_item.
      -- The game will be putting item in there at a slightly later time
      inventory.itemslots[from] = nil
    end

    function inv.Equip(item)
      inventory:Equip(item)
    end
  else
    local function CancelRefreshTask()
      inventory.classified._refreshtask:Cancel()
      inventory.classified._refreshtask = nil
      inventory.classified._busy = false
    end

    local function IsBusy()
      return inventory.classified and inventory.classified._busy
    end

    local function whenNotBusy(whenFn, triedToCancel)
      if IsBusy() then
        if not triedToCancel and inventory.classified._refreshtask then
          CancelRefreshTask()
          -- Try again immediately but when still busy we will wait till the next cycle.
          whenNotBusy(whenFn, true)
        else
          fn.OnNextCycle(function()
            whenNotBusy(whenFn)
          end)
        end
      else
        whenFn()
      end
    end

    local function ToActiveItem(from, nextFn)
      whenNotBusy(function()
        inventory:TakeActiveItemFromAllOfSlot(from)
        fn.IfFn(nextFn)
      end)
    end

    local function ActiveItemToSlot(slot, nextFn)
      whenNotBusy(function()
        inventory:PutAllOfActiveItemInSlot(slot)
        fn.IfFn(nextFn)
      end)
    end

    local function ReturnActiveItem(nextFn)
      whenNotBusy(function()
        inventory:ReturnActiveItem()
        fn.IfFn(nextFn)
      end)
    end

    local function DropItem(slot, nextFn)
      whenNotBusy(function()
        local item = inventory:GetItemInSlot(slot)
        inventory:DropItemFromInvTile(item)
        fn.IfFn(nextFn)
      end)
    end

    function inv.Move(from, nextFn)
      local free_slot = inv.GetFreeSlot(from)
      if not free_slot then
        fn.IfFn(nextFn, false)
        return false
      end

      rearranging = rearranging + 1
      whenNotBusy(function()
        ToActiveItem(from, function()
          whenNotBusy(function()
            free_slot = inv.GetFreeSlot(from)
            if not free_slot then
              rearranging = rearranging - 1
              ReturnActiveItem(function()
                fn.IfFn(nextFn, false)
              end)
              return false
            else
               ActiveItemToSlot(free_slot, function()
                rearranging = rearranging - 1
                fn.IfFn(nextFn, true)
              end)
            end
          end)
        end)
      end)
    end

    function inv.Equip(item, nextFn)
      is_equipping = true
      whenNotBusy(function()
        inventory:ControllerUseItemOnSelfFromInvTile(item)
        is_equipping = false
        fn.IfFn(nextFn)
      end)
    end
  end

  return inv
end

function fn.InitInventory(inventory)
  state.inventory = fn.MakeInventory(inventory, state.is_mastersim)

  inventory.inst:ListenForEvent("equip", fn.Inventory_OnEquip)
  inventory.inst:ListenForEvent("itemget", fn.Inventory_OnItemGet)
  inventory.inst:ListenForEvent("newactiveitem", fn.Inventory_OnNewActiveItem)

  if state.is_mastersim then
    inventory.GetNextAvailableSlot = fn.Inventory_GetNextAvailableSlot(inventory.GetNextAvailableSlot)
    inventory.Equip = fn.Inventory_Equip(inventory.Equip)
    inventory.OnSave = fn.Inventory_OnSave(inventory.OnSave)
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

  AddComponentPostInit("inventory", function(self)
    -- AddPlayerPostInit triggers after Inventory.OnLoad
    -- so we use AddComponentPostInit for this specific one
    self.OnLoad = fn.Inventory_OnLoad(self.OnLoad)
  end)

  AddClassPostConstruct("widgets/inventorybar", function(inventorybar)
    state.hud.inventorybar = inventorybar
  end)

  AddClassPostConstruct("widgets/invslot", function(invslot)
    fn.OnNextCycle(function()
      fn.UpdatePreviewsForSlot(invslot.num)
    end)
  end)
end

fn.InitSaveEquipmentSlots()

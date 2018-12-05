-- Development only
-- GLOBAL.CHEATS_ENABLED = true
-- GLOBAL.require('debugkeys')

-- Lua built-ins that are only accessible through GLOBAL
local require = GLOBAL.require
local setmetatable = GLOBAL.setmetatable
local rawset = GLOBAL.rawset

-- DS globals
local CreateEntity = GLOBAL.CreateEntity
local SpawnPrefab = GLOBAL.SpawnPrefab
local GetPlayer = GLOBAL.GetPlayer

local Image = require("widgets/image")
local ImageButton = require("widgets/imagebutton")
local Inv = require("widgets/inventorybar")
local InvSlot = require("widgets/invslot")

-- saved slot -> [item.prefab]
local items = {}

-- item.prefab => saved slot
local slots = {}

-- item.prefab => image button widget of item
local image_buttons = {}

-- equipslot (EQUIPSLOTS.HANDS / EQUIPSLOTS.HEAD / EQUIPSLOTS.BODY) => item
-- we use this information to give priority to a piece of equipment that is moved back
-- after being equipped. it will then always go back to its slot, even if another copy
-- of the same item is there currently. this is to assure you will always exhaust
-- one of your copies of one type of equipment first, rather than switching to a 100% one after
-- swapping equipment a few times.
local last_equipped_item = {}

-- the equipment that was just manually moved by the player
-- by dragging it into a new inventory slot. this is used to determine
-- whether an item's slot should be updated when the inventory reports it
-- as a new item.
local manually_moved_equipment = nil

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

-- All functions will be stored in this table,
-- in this way we can bypass the Lua limitation that
-- a function X can only call other local functions that
-- are declared before X is declared.
-- When storing them all in a table, this limitation is removed.
local fn = {}

-- Generates a table of item.prefab -> slot,
-- based on the current contents of the `items` variable
function fn.GetItemSlots()
  local slots = {}

  for slot, prefabs in pairs(items) do
    for _, prefab in ipairs(prefabs) do
      slots[prefab] = slot
    end
  end

  return slots
end

-- Returns the Inventory bar widget
function fn.GetInventorybar()
  local player = GetPlayer()
  if player and player.HUD and player.HUD.controls then
    return player.HUD.controls.inv
  end
end

function fn.CreateImageButton(prefab)
  local item = SpawnPrefab(prefab)
  local image = ImageButton(item.components.inventoryitem:GetAtlas(), item.components.inventoryitem:GetImage())

  -- Item was only used for its GetAtlas() and GetImage() functions, can be removed immediately
  item:Remove()

  image:SetScale(0.9)

  local inventorybar = fn.GetInventorybar()
  inventorybar:AddChild(image)

  return image
end

function fn.UpdateImageButtons()
  for slot, _ in pairs(items) do
    fn.UpdateImageButtonsForSlot(slot)
  end
end

function fn.UpdateImageButtonsForSlot(slot)
  local inventorybar = fn.GetInventorybar()
  local invslot = inventorybar.inv[slot]

  if not invslot or not items[slot] then
    return
  end

  for item_index, prefab in ipairs(items[slot]) do
    local image_button = image_buttons[prefab]
    if not image_button then
      image_button = fn.CreateImageButton(prefab)
      image_buttons[prefab] = image_button
    end

    image_button:SetOnClick(function()
      fn.ClearItem(prefab)
    end)

    fn.UpdateImageButtonPosition(image_button, item_index, inventorybar, invslot)
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

function fn.ClearImage(prefab)
  local image = image_buttons[prefab]

  if image then
    image:Kill()
    image_buttons[prefab] = nil
  end
end

function fn.RemoveItemFromSlot(prefab, slot)
  local items_in_slot = items[slot]

  if not items_in_slot then
    return
  end

  for i = #items_in_slot, 1, -1 do
    if prefab == items_in_slot[i] then
      table.remove(items_in_slot, i)
      return
    end
  end
end

function fn.GetSlot(prefab)
  if prefab then
    return slots[prefab]
  end
end

function fn.SaveSlot(prefab, slot)
  local prev_slot = fn.GetSlot(prefab)
  if prev_slot then
    fn.RemoveItemFromSlot(prefab, prev_slot)
    fn.UpdateImageButtonsForSlot(prev_slot)
  end

  if not items[slot] then
    items[slot] = {}
  end

  table.insert(items[slot], prefab)

  -- Update slot table as `items` has been changed
  slots = fn.GetItemSlots()

  fn.UpdateImageButtonsForSlot(slot)
end

function fn.HasSlot(prefab)
  return not fn.GetSlot(prefab) == nil
end

function fn.ClearItem(prefab)
  local slot = fn.GetSlot(prefab)
  if slot then
    fn.RemoveItemFromSlot(prefab, slot)
    fn.ClearImage(prefab)

    -- Update slot table as `items` has been changed
    slots = fn.GetItemSlots()

    fn.UpdateImageButtons()
  end
end

function fn.GetItemOwner(item)
  if item and item.components and item.components.inventoryitem then
    return item.components.inventoryitem:GetGrandOwner()
  end
end

-- Specifies if `item` is equipment
function fn.IsEquipment(item)
  return item and item.components and item.components.equippable
end

function fn.GetEquipSlot(item)
  if not fn.IsEquipment(item) then
    return nil
  end

  return item.components.equippable.equipslot
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

-- Queues the specified function to be run after the currently
-- active coroutine has yielded
function fn.QueueFunc(func)
  table.insert(fns, func)

  if not runfns_scheduled then
    runfns_scheduled = true
    tasker:DoTaskInTime(0, function()
      fn.RunFns()
      runfns_scheduled = false
    end)
  end
end

function fn.Inventory_OnEquip(inst, data)
  local item = data.item
  local eslot = data.eslot

  if not fn.IsEquipment(item) then
    return
  end

  if eslot then
    last_equipped_item[eslot] = item
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

function fn.Inventory_OnItemGet(inst, data)
  local item = data.item
  local slot = data.slot

  if not fn.IsEquipment(item) or not slot then
    return
  end

  -- If another copy of the same equipment is available in the inventory and
  -- is in its saved slot, we do NOT save the new slot of this equipment.
  -- This is to prevent unintentionally changing the saved equipment slot
  -- in cases where you pickup an additional copy of the item when you already
  -- have a copy of the item in the previously saved slot. In that case,
  -- the new copy obviously will be moved to some other slot since the saved slot
  -- is taken, but that would then update the preferred slot to the new slot which
  -- is not actually what we want.
  local saved_slot = fn.GetSlot(item.prefab)
  if saved_slot then
    local existing_item = inst.components.inventory:GetItemInSlot(saved_slot)
    if existing_item and existing_item.prefab == item.prefab then
      return
    end
  end

  -- Store equipment slot, only when not in the process of
  -- automatically rearranging items triggered by some other action
  -- and if the item was either manually moved or has never been picked up before.
  -- The latter case makes sure the very first time an item is picked up the slot
  -- it is put in is saved so on subsequent equip / unequip actions it will already
  -- return to that first slot without the player having to put it there explicitly.
  if rearranging == 0 and (manually_moved_equipment == item or not fn.HasSlot(item.prefab)) then
    fn.SaveSlot(item.prefab, slot)
  end
end

function fn.Inventory_OnNewActiveItem(inst, data)
  local item = data.item

  -- Logic itself is queued until all actions are resolved,
  -- this is necessary as the active item is first removed before
  -- it's being put in the inventory, and we do not want to clear the manually_moved_equipment
  -- before that has happened. QueueFunc will guarantee we first wait for the current
  -- chain of events to finish.
  fn.QueueFunc(function()
    if fn.IsEquipment(item) then
      manually_moved_equipment = item
    else
      if manually_moved_equipment then
        manually_moved_equipment = nil
      end
    end
  end)
end

function fn.Inventory_GetNextAvailableSlot(original_fn)
  return function(self, item)
    local saved_slot = fn.GetSlot(item.prefab)

    if not saved_slot or not fn.IsEquipment(item) then
      return original_fn(self, item)
    end

    local blocking_item = self:GetItemInSlot(saved_slot)
    if blocking_item then
      -- If the item was equipped and is now in the process of becoming
      -- unequipped we always place it back into its saved slot.
      local equipslot = fn.GetEquipSlot(item)
      local was_equipped = equipslot and last_equipped_item[equipslot] == item

      -- blocking_item is moved if any of these conditions is true
      -- 1) the new item was just unequipped
      -- 2) blocking_item is not equipment
      -- 3) blocking_item is not in its saved slot
      local move_blocking_item = was_equipped or not fn.IsEquipment(blocking_item) or fn.GetSlot(blocking_item.prefab) ~= saved_slot

      -- If we are not moving the blocking_item at all we will let the game decide where to put the
      -- new equipment.
      if not move_blocking_item then
        return original_fn(self, item)
      end

      -- Let the game move the blocking item somewhere else
      -- Before doing so we occupy its slot with our new item
      -- otherwise the game would not move blocking_item at all,
      -- presumably as it is already present in the inventory
      self.itemslots[saved_slot] = item

      -- Find a new slot for the blocking item -- skipping the sound
      rearranging = rearranging + 1
      self:GiveItem(blocking_item, nil, nil, true)
      rearranging = rearranging - 1

      -- We clear the saved_slot again, as the game will be putting
      -- item in there at a slightly later time, not right now
      self.itemslots[saved_slot] = nil
    end

    -- Ending up here means the requested slot was available
    -- or was made available
    return saved_slot, self.itemslots
  end
end

function fn.Inventory_OnLoad(original_fn)
  return function(self, data, newents)
    if data.save_equipment_slots then
      items = data.save_equipment_slots
      slots = fn.GetItemSlots()

      tasker:DoTaskInTime(0, fn.UpdateImageButtons)
    end

    return original_fn(self, data, newents)
  end
end

function fn.Inventory_OnSave(original_fn)
  return function(self)
    local data = original_fn(self)
    data.save_equipment_slots = items
    return data
  end
end

function fn.InventoryPostInit(self)
  local player = GetPlayer()

  if player.components.inventory == self then
    self.inst:ListenForEvent("equip", fn.Inventory_OnEquip)
    self.inst:ListenForEvent("itemget", fn.Inventory_OnItemGet)
    self.inst:ListenForEvent("newactiveitem", fn.Inventory_OnNewActiveItem)
    self.GetNextAvailableSlot = fn.Inventory_GetNextAvailableSlot(self.GetNextAvailableSlot)
    self.OnLoad = fn.Inventory_OnLoad(self.OnLoad)
    self.OnSave = fn.Inventory_OnSave(self.OnSave)
  end
end

function fn.InitSaveEquipmentSlots()
  AddComponentPostInit("inventory", fn.InventoryPostInit)
end

fn.InitSaveEquipmentSlots()

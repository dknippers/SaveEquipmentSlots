-- GLOBAL.CHEATS_ENABLED = true
-- GLOBAL.require('debugkeys')

local Image = GLOBAL.require("widgets/image")
local Inv = GLOBAL.require("widgets/inventorybar")
local InvSlot = GLOBAL.require("widgets/invslot")

-- saved slot -> [item.prefab]
local items = {}

-- item.prefab => saved slot
local slots = {}

-- item.prefab => image widget of item
local images = {}

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
local tasker = GLOBAL.CreateEntity()

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

-- Generates a table of item.prefab -> slot,
-- based on the current contents of the `items` variable
local function GetItemSlots()
  local slots = {}

  for slot, prefabs in pairs(items) do
    for i, prefab in ipairs(prefabs) do
      slots[prefab] = slot
    end
  end

  return slots
end

-- Returns the index of the given prefab in the slot
local function GetItemIndex(slot, item_prefab)
  if items[slot] then
    for i, prefab in ipairs(items[slot]) do
      if prefab == item_prefab then
        return i - 1
      end
    end
  end
end

local function CreateItemImage(prefab)
  local item = GLOBAL.SpawnPrefab(prefab)
  local image = Image(item.components.inventoryitem:GetAtlas(),item.components.inventoryitem:GetImage())
  item:Remove()

  image:SetScale(0.5, 0.5, 0.5)
  image:Show()

  return image
end


local function UpdateItemsInSlot(slot)
  local player = GLOBAL.GetPlayer()
  local inventorybar = player.HUD.controls.inv
  local invslot = inventorybar:GetSlotWidget(slot)

  if not invslot then
    return
  end

  for idx, prefab in ipairs(items[slot]) do
    local image = images[prefab]
    if not image then
      image = CreateItemImage(prefab)
      images[prefab] = image
    end

    local pos = invslot:GetWorldPosition()
    if pos then
      local height = invslot:GetHeight()
      if height then
        local item_index = idx - 1
        local image_width, image_height = image:GetSize()
        image:SetPosition(pos.x, pos.y + (height / 1.1) + item_index * (image_height / 1.6))
      end
    end
  end
end

local function UpdateItemImages()
  for slot, prefab in pairs(items) do
    UpdateItemsInSlot(slot)
  end
end

local function ClearImage(prefab)
  local image = images[prefab]

  if image then
    image:Kill()
    images[prefab] = nil
  end
end


local function RemoveItemFromSlot(item, slot)
  for idx, prefab in ipairs(items[slot]) do
    if prefab == item.prefab then
      table.remove(items[slot], idx)
      return
    end
  end
end

local function GetSlot(item)
  if item then
    return slots[item.prefab]
  end
end

local function SaveSlot(item, slot)
  local prev_slot = GetSlot(item)
  if prev_slot then
    RemoveItemFromSlot(item, prev_slot)
  end

  if not items[slot] then
    items[slot] = {}
  end

  table.insert(items[slot], item.prefab)

  -- Update slot table as `items` has been changed
  slots = GetItemSlots()

  -- TODO: Optimization possibility is
  -- to only update item images for the previous
  -- slot of this item (if any) and the new slot
  -- rather than all slots.
  UpdateItemImages()
end

local function HasSlot(item)
  return not GetSlot(item) == nil
end

local function ClearSlot(item)
  local slot = GetSlot(item)
  if slot then
    slots[item.prefab] = nil
    RemoveItemFromSlot(item, slot)
    ClearImage(item.prefab)
    UpdateItemImages()
  end
end

local function GetItemOwner(item)
  if item and item.components and item.components.inventoryitem then
    return item.components.inventoryitem:GetGrandOwner()
  end
end


-- Specifies if `item` is equipment
local function IsEquipment(item)
  return item and item.components and item.components.equippable
end

local function GetEquipSlot(item)
  if not IsEquipment(item) then
    return nil
  end

  return item.components.equippable.equipslot
end

-- Runs all functions in the fns table and removes them after
local function RunFns()
  for i, fn in ipairs(fns) do
    fn()
    fns[i] = nil
  end
end

-- Queues the specified function to be run after the currently
-- active coroutine has yielded
local function QueueFn(fn)
  table.insert(fns, fn)

  if not runfns_scheduled then
    runfns_scheduled = true
    tasker:DoTaskInTime(0, function()
      RunFns()
      runfns_scheduled = false
    end)
  end
end

local function Inventory_OnEquip(inst, data)
  local item = data.item
  local eslot = data.eslot

  if not IsEquipment(item) then
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

local function Inventory_OnItemGet(inst, data)
  local item = data.item
  local slot = data.slot

  if not IsEquipment(item) or not slot then
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
  local saved_slot = GetSlot(item)
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
  if rearranging == 0 and (manually_moved_equipment == item or not HasSlot(item)) then
    SaveSlot(item, slot)
  end
end

local function Inventory_OnNewActiveItem(inst, data)
  local item = data.item

  -- Logic itself is queued until all actions are resolved,
  -- this is necessary as the active item is first removed before
  -- it's being put in the inventory, and we do not want to clear the manually_moved_equipment
  -- before that has happened. QueueFn will guarantee we first wait for the current
  -- chain of events to finish.
  QueueFn(function()
    if IsEquipment(item) then
      manually_moved_equipment = item
    else
      if manually_moved_equipment then
        manually_moved_equipment = nil
      end
    end
  end)
end

local function Inventory_GetNextAvailableSlot(original_fn)
  return function(self, item)
    local saved_slot = GetSlot(item)

    if not saved_slot or not IsEquipment(item) then
      return original_fn(self, item)
    end

    local blocking_item = self:GetItemInSlot(saved_slot)
    if blocking_item then
      -- If the item was equipped and is now in the process of becoming
      -- unequipped we always place it back into its saved slot.
      local equipslot = GetEquipSlot(item)
      local was_equipped = equipslot and last_equipped_item[equipslot] == item

      -- blocking_item is moved if any of these conditions is true
      -- 1) the new item was just unequipped
      -- 2) blocking_item is not equipment
      -- 3) blocking_item is not in its saved slot
      local move_blocking_item = was_equipped or not IsEquipment(blocking_item) or GetSlot(blocking_item) ~= saved_slot

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

local function Inventory_OnLoad(original_fn)
  return function(self, data, newents)
    if data.save_equipment_slots then
      items = data.save_equipment_slots
      slots = GetItemSlots()

      tasker:DoTaskInTime(0, UpdateItemImages)
    end

    return original_fn(self, data, newents)
  end
end

local function Inventory_OnSave(original_fn)
  return function(self)
    local data = original_fn(self)
    data.save_equipment_slots = items
    return data
  end
end

local function InventoryPostInit(self)
  local player = GLOBAL.GetPlayer()

  if player.components.inventory == self then
    self.inst:ListenForEvent("equip", Inventory_OnEquip)
    self.inst:ListenForEvent("itemget", Inventory_OnItemGet)
    self.inst:ListenForEvent("newactiveitem", Inventory_OnNewActiveItem)
    self.GetNextAvailableSlot = Inventory_GetNextAvailableSlot(self.GetNextAvailableSlot)
    self.OnLoad = Inventory_OnLoad(self.OnLoad)
    self.OnSave = Inventory_OnSave(self.OnSave)
  end
end

-- Add a function to the Inventorybar which grants access
-- to a specific Slot widget.
function Inv:GetSlotWidget(slot)
  return self.inv[slot]
end

-- Returns the height of the inventory slot instance
function InvSlot:GetHeight()
  if self.bgimage then
    local width, height = self.bgimage:GetSize()
    return height
  end
end

local function InitSaveEquipmentSlots()
  AddComponentPostInit("inventory", InventoryPostInit)
end

InitSaveEquipmentSlots()

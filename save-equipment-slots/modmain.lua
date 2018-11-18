-- GLOBAL.CHEATS_ENABLED = true
-- GLOBAL.require('debugkeys')

-- item.name => saved item slot
local slots = {}

-- equipslot (EQUIPSLOTS.HANDS / EQUIPSLOTS.HEAD / EQUIPSLOTS.BODY) => item
local last_equipped_item = {}

-- the equipment which is currently the active item
local active_equipment = nil

-- the item that is currently eligible for its slot to be changed
local set_slot_candidate = nil

-- when unequipping / obtaining a piece of equipment,
-- we sometimes rearrange other items to put the new item
-- in its saved slot. when this relocation process is underway
-- (i.e., rearranging > 0), we will not be changing any of
-- the saved slots, as the player is not manually moving anything.
-- this is a number as it can be going on for more than 1
-- item at a time through recursive calls to
local rearranging = 0

local function GetSlot(item)
  return slots[item.name]
end

local function SetSlot(item, slot)
  print(item.name .. " -> " .. slot)
  slots[item.name] = slot
end

local function ClearSlot(item)
  slots[item.name] = nil
end

local function GetItemOwner(item)
  if item and item.components and item.components.inventoryitem then
    return item.components.inventoryitem:GetGrandOwner()
  end
end

-- Specifies if `item` is equipment usable by the player (i.e., it is equipment and not owned by the enemy)
local function IsEquipment(item)
  local player = GLOBAL.GetPlayer()
  local item_owner = GetItemOwner(item)

  return
    item and
    item.name and -- We use name as the key
    item.components and
    item.components.equippable and
    (not item_owner or item_owner == player)
end

local function GetEquipSlot(item)
  if not IsEquipment(item) then
    return nil
  end

  return item.components.equippable.equipslot
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
    if existing_item and existing_item.name == item.name then
      set_slot_candidate = nil
      return
    end
  end

  -- Store equipment slot, only when not in the process of
  -- automatically rearranging items triggered by some other action,
  -- and if the item is a candidate for the set slot action.
  if rearranging == 0 and set_slot_candidate == item then
    SetSlot(item, slot)
    set_slot_candidate = nil
  end
end

local function Inventory_OnNewActiveItem(inst, data)
  local item = data.item

  if active_equipment ~= nil then
    set_slot_candidate = active_equipment
  end

  if item == nil then
    active_equipment = nil
  else
    if IsEquipment(item) then
      active_equipment = item
    else
      active_equipment = nil
    end
  end
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
      slots = data.save_equipment_slots
    end

    return original_fn(self, data, newents)
  end
end

local function Inventory_OnSave(original_fn)
  return function(self)
    local data = original_fn(self)
    data.save_equipment_slots = slots
    return data
  end
end

local function InventoryPostInit(self)
  self.inst:ListenForEvent("itemget", Inventory_OnItemGet)
  self.inst:ListenForEvent("dropitem", function(inst, data) set_slot_candidate = nil end)
  self.inst:ListenForEvent("newactiveitem", Inventory_OnNewActiveItem)
  self.GetNextAvailableSlot = Inventory_GetNextAvailableSlot(self.GetNextAvailableSlot)
  self.OnLoad = Inventory_OnLoad(self.OnLoad)
  self.OnSave = Inventory_OnSave(self.OnSave)
end

local function Equippable_OnEquipped(inst, data)
  local equipslot = GetEquipSlot(inst)
  if equipslot then
    last_equipped_item[equipslot] = inst
    set_slot_candidate = nil
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
  inst.prevcontainer = nil

  -- We also clear the item's prevslot to prevent the game from trying
  -- to put it there when unequipping the item, as this is not always
  -- what we would want when we have multiple copies of an equipment.
  -- For example, when we have assigned the Axe to slot 2 but have picked up
  -- a second copy that is now stored in slot 3, we do not want the game
  -- to try to put it back directly to slot 3 when unequipping, as slot 2
  -- might be available at that time. The game bypasses the GetNextAvailableSlot()
  -- function when prevslot has a value and is available, so we clear it here.
  inst.prevslot = nil
end

local function EquippablePostInit(self)
  self.inst:ListenForEvent("equipped", Equippable_OnEquipped)
end

local function InitSaveEquipmentSlots()
  AddComponentPostInit("inventory", InventoryPostInit)
  AddComponentPostInit("equippable", EquippablePostInit)
end

InitSaveEquipmentSlots()
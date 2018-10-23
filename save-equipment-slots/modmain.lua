-- GLOBAL.CHEATS_ENABLED = true
-- GLOBAL.require('debugkeys')

local slots = {} -- Dictionary of name => slot

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

local function GetItemOwnerGuid(item)
  if not item or not item.components or not item.components.inventoryitem or not item.components.inventoryitem.owner then
    return nil
  end

  local owner = item.components.inventoryitem.owner
  -- In the case of a backpack item, the player GUID is actually
  -- the parent GUID rather than the owner GUID...
  return owner.parent and owner.parent.GUID or owner.GUID
end

-- Specifies if `item` is equipment usable by the player (i.e., it is equipment and not owned by the enemy)
local function IsEquipment(item)
  local player = GLOBAL.GetPlayer()
  local item_guid = GetItemOwnerGuid(item)

  return
    item and
    item.name and -- We use name as the key
    item.components and
    item.components.equippable and
    (not item_guid or item_guid == player.GUID)
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
      return
    end
  end

  -- Store equipment slot
  SetSlot(item, slot)
end

local function Inventory_GetNextAvailableSlot(original_fn)
  return function(self, item)
    local saved_slot = GetSlot(item)

    if not saved_slot or not IsEquipment(item) then
      return original_fn(self, item)
    end

    local blocking_item = self:GetItemInSlot(saved_slot)
    if blocking_item then
      -- If blocking_item is equipment which is currently in its
      -- preferred slot, we are not going to move it away for this new
      -- equipment that's coming in. Instead, we will move the new item
      local move_blocking_item = not IsEquipment(blocking_item) or GetSlot(blocking_item) ~= saved_slot

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
      self:GiveItem(blocking_item)
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
  self.GetNextAvailableSlot = Inventory_GetNextAvailableSlot(self.GetNextAvailableSlot)
  self.OnLoad = Inventory_OnLoad(self.OnLoad)
  self.OnSave = Inventory_OnSave(self.OnSave)
end

local function Equippable_OnEquip(inst, data)
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
  inst.prevslot = nil
end

local function EquippablePostInit(self)
  self.inst:ListenForEvent("equipped", Equippable_OnEquip)
end

local function InitSaveEquipmentSlots()
  AddComponentPostInit("inventory", InventoryPostInit)
  AddComponentPostInit("equippable", EquippablePostInit)
end

InitSaveEquipmentSlots()
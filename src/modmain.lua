-- Lua built-ins that are only accessible through GLOBAL
local require = GLOBAL.require
local setmetatable = GLOBAL.setmetatable
local unpack = GLOBAL.unpack

-- DS globals
local CreateEntity = GLOBAL.CreateEntity
local TheSim = GLOBAL.TheSim
local Ents = GLOBAL.Ents
local Prefabs = GLOBAL.Prefabs
local TheInput = GLOBAL.TheInput
local ACTIONS = GLOBAL.ACTIONS
local CONTROLS = {
  LB = GLOBAL.CONTROL_ROTATE_LEFT,
  RB = GLOBAL.CONTROL_ROTATE_RIGHT,
}

local ImageButton = require("widgets/imagebutton")
local Text = require("widgets/text")
local DisplayNames = GLOBAL.STRINGS and GLOBAL.STRINGS.NAMES
local PlayerHud = require("screens/playerhud")

-- Initialized in fn.InitConfig()
local config = {}

-- saved slot -> [item.prefab]
local items = {}

-- item.prefab -> saved slot
local slots = {}

-- Represents an object used to occupy an inventory slot temporarily
-- when we are moving items around
local OCCUPIED = { components = {} }
-- Another object we use to block an inventory slot, this one is used to reserve
-- saved slots when looking for an empty inventory slot for a new item
local RESERVED = { components = {} }

-- entity to run tasks with, necessary to gain access to DoTaskInTime()
local tasker = CreateEntity()

-- Table to hold all local state of this mod.
local state = {
  -- item.prefab -> image button widget of item
  image_buttons = {},

  -- MasterInventory or ClientInventory
  inventory = nil,
  -- Client Mode only: ClientContainer for the current backpack item
  overflow = nil,
  -- HUD inventorybar
  inventorybar = nil,

  -- When > 0, signals that this mod is moving items around.
  -- Controlled with fn.Lock() / fn.Unlock() and can be read with fn.IsLocked()
  -- Used to prevent updating saved slots during this time when items arrive in new slots.
  locks = 0,

  -- true for all cases except when connected to a remote host in DST
  is_mastersim = true,

  -- Detect Don't Starve Together
  is_dst = TheSim:GetGameID() == "DST",

  -- true if we are currently in the process of equipping some equipment
  is_equipping = false,

  -- Keeps track of equipment that is being manually moved,
  -- in which case the saved slots might have to be updated.
  manually_moved = {},

  -- DST Client Mode: GUIDs of items that have already been processed
  -- when their clientside "itemget" event was raised.
  client_processed = {},

  -- ClientMode only -- durability per item as it is only communicated through the "percentusedchange" event
  -- and not accessible anymore through a finiteuses component which is only available to the mastersim
  durability = {
    -- Durability per item, key is item.GUID
    items = {},
    -- Listener functions per item, key is item.GUID
    listeners = {}
  },

  -- Whether or not saving slots is currently disabled
  disable_save_slots = false,

  -- Text widget to display current status of Disable Save Slots option
  disable_save_slots_text_widget = nil,

  -- Animation callback
  disable_save_slots_animation = nil,

  -- List of atlas files in use by the current game
  atlas_files = {},

  -- Cache of prefab name -> { atlas, image } of icon
  atlas_image_cache = {}
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
  if state.is_dst then
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

function fn.InitAtlasFiles()
  local prefab_source = state.is_dst and Prefabs["global"] or Prefabs["hud"]
  if prefab_source ~= nil and type(prefab_source.assets) == "table" then
    for _, asset in ipairs(prefab_source.assets) do
      if asset.type == "ATLAS" and string.find(asset.file, "^images/inventoryimages[^/]*[.]xml$") then
        table.insert(state.atlas_files, asset.file)
      end
    end
  end
end

function fn.GetAtlasAndImage(prefab)
  if not prefab then
    return nil
  end

  local atlas, image = unpack(state.atlas_image_cache[prefab] or {})
  if atlas and image then
    return atlas, image
  end

  if state.is_mastersim then
    -- Our preferred way is to simply get the atlas + image
    -- from a spawned instance of the prefab
    atlas, image =  fn.FromSpawnedPrefab(prefab, function(spawn)
      local inventoryitem = fn.GetComponent(spawn, "inventoryitem", state.is_dst)
      if inventoryitem then
        return inventoryitem:GetAtlas(), inventoryitem:GetImage()
      end
    end)
  end

  if not atlas or not image then
    if not state.is_mastersim then
      -- If the above method failed and we are in DST client mode:
      -- Check the inventory for the item and read atlas and image from there
      -- as we cannot use SpawnPrefab there this is the alternative.
      atlas, image = fn.GetAtlasAndImageFromInventoryItem(prefab)
    end

    if not atlas or not image then
      -- If we still have not found it by now, determine the atlas and image
      -- in a slightly less accurate way using the global Prefabs-cache
      -- which also contains atlas files and images
      -- First try: default prefab image
      image = prefab..".tex"
      atlas = fn.GetPrefabAtlas(prefab, image)

      if not image or not atlas then
        -- Second try: alternative image name
        image = fn.GetPrefabAltImage(prefab)
        atlas = fn.GetPrefabAtlas(prefab, image)
      end
    end
  end

  if atlas and image then
    state.atlas_image_cache[prefab] = { atlas, image }
  end

  return atlas, image
end

function fn.FromSpawnedPrefab(prefab, value_fn)
  local guid = TheSim:SpawnPrefab(prefab)
  local spawn = Ents[guid]
  if spawn then
    local value = {value_fn(spawn)}
    spawn:Remove()
    spawn = nil
    return unpack(value)
  end
end

function fn.GetAtlasAndImageFromInventoryItem(prefab)
  if not state.inventory then
    return nil
  end

  local item = state.inventory:FindItem(function(possible)
    return possible and possible.prefab == prefab
  end)

  if not item then
    return nil
  end

  local inventoryitem = fn.GetComponent(item, "inventoryitem", state.is_dst)
  if not inventoryitem then
    return nil
  end

  return inventoryitem:GetAtlas(), inventoryitem:GetImage()
end

function fn.GetPrefabAltImage(prefab)
  -- Some prefabs declare 1 or more INV_IMAGE assets,
  -- which are alternative image names for the prefab.
  -- We simply pick the first one.
  return fn.FindPrefabAsset(prefab, function(asset)
    if asset.type == "INV_IMAGE" then
      return asset.file..".tex"
    end
  end)
end

function fn.GetPrefabAtlas(prefab, image)
  if not prefab or not image then
    return nil
  end

  -- In Hamlet and DST (as of the "Return of Them" update),
  -- there are multiple atlas files that store inventory images.
  -- That is the reason we now have a collection of atlas files to look through
  if #state.atlas_files > 0 and type(TheSim.AtlasContains) == "function" then
     -- Check built-in atlas files
    for i = 1, #state.atlas_files do
      local atlas = state.atlas_files[i]

      if TheSim:AtlasContains(atlas, image) then
        return atlas
      end
    end
  end

  -- Check the Prefab assets for an atlas file,
  -- this is used by mod weapons
  return fn.FindPrefabAsset(prefab, function(asset)
    if asset.type == "ATLAS" then
      return asset.file
    end
  end)
end

function fn.FindPrefabAsset(prefab, asset_fn)
  local results = fn.FindPrefabAssets(prefab, asset_fn, 1)
  return results[1]
end

function fn.FindPrefabAssets(prefab, asset_fn, max_results)
  local assets = {}

  local prefab_data = Prefabs and Prefabs[prefab]
  if prefab_data and type(prefab_data.assets) == "table" then
    for _, asset in ipairs(prefab_data.assets) do
      local result = asset_fn(asset)
      if result then
        table.insert(assets, result)
      end

      if type(max_results) == "number" and #assets == max_results then
        break
      end
    end
  end

  return assets
end

function fn.CreateImageButton(prefab)
  if  not state.inventorybar or
      not state.inventorybar.toprow then
    return
  end

  local atlas, image = fn.GetAtlasAndImage(prefab)

  local image_button
  if not atlas or not image then
    image_button = fn.CreateFallbackImageButton(prefab)
  else
    image_button = ImageButton(atlas, image)
    image_button:SetScale(config.slot_icon_scale)
    image_button.image:SetTint(1,1,1, config.slot_icon_opacity)
  end

  image_button.Kill = fn.ImageButton_Kill(image_button.Kill, prefab)
  state.inventorybar.toprow:AddChild(image_button)

  return image_button
end

function fn.GetPrefabDisplayName(prefab)
  if not prefab or not DisplayNames or type(DisplayNames) ~= "table" then
    return prefab
  end

  return DisplayNames[string.upper(prefab)]
end

function fn.CreateFallbackImageButton(prefab)
  local image_button = ImageButton("images/global.xml", "square.tex")
  local base_opacity = .5
  image_button.image:SetTint(0,0,0, base_opacity * config.slot_icon_opacity)
  local base_scale = .6
  image_button:SetScale(base_scale * config.slot_icon_scale)

  local display_name = fn.GetPrefabDisplayName(prefab)
  if display_name then
    image_button:SetTooltip(display_name)
  end

  return image_button
end

-- Clears image button cache for the given prefab when the ImageButton is killed
function fn.ImageButton_Kill(original_fn, prefab)
  return function(self)
    -- Original Kill()
    original_fn(self)

    -- Clear cache
    state.image_buttons[prefab] = nil
  end
end

-- Runs the given function on the next processing cycle,
-- after all current threads have finished or yielded
function fn.OnNextCycle(onNextCycle)
  tasker:DoTaskInTime(0, onNextCycle)
end

function fn.UpdateSlotIcons(slot)
  if not config.show_slot_icons or not items[slot] or not state.inventorybar then
    return
  end

  local invslot = state.inventorybar.inv[slot]
  if not invslot then
    return
  end

  for item_index, prefab in ipairs(items[slot]) do
    local image_button = state.image_buttons[prefab]
    if not image_button then
      image_button = fn.CreateImageButton(prefab)

      if not image_button then
        return
      end

      state.image_buttons[prefab] = image_button
    end

    image_button:SetOnClick(function()
      fn.ClearSlot(prefab, slot)
    end)

    fn.UpdateImageButtonPosition(image_button, item_index, state.inventorybar, invslot)
  end
end

function fn.UpdateImageButtonPosition(image_button, item_index, inventorybar, invslot)
  local invslot_pos = invslot:GetLocalPosition()

  if invslot_pos and invslot.bgimage then
    local _, invslot_height = invslot.bgimage:GetSize()

    if invslot_height then
      local _, image_button_height = image_button:GetSize()

      if image_button_height then
        -- Respect configured scale
        image_button_height = image_button_height * config.slot_icon_scale

        -- Offset between top of inventory bar and start of image button
        local offset = image_button_height / 2
        -- Vertical spacing between icons
        local spacing = image_button_height / 5

        local initial_pos_y = invslot_pos.y + invslot_height + offset
        local delta_y = (item_index - 1) * (spacing + image_button_height)

        image_button:SetPosition(invslot_pos.x, initial_pos_y + delta_y)
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
  for prefab, btn in pairs(state.image_buttons) do
    fn.ClearSlotIcon(prefab)
    fn.OnNextCycle(function()
      local slot = fn.GetSlot(prefab)
      if slot then
        fn.UpdateSlotIcons(slot)
      end
    end)
  end
end

function fn.ShowDisableStatusText(duration)
  if not state.disable_save_slots_text_widget then
    return
  end

  if state.disable_save_slots_animation ~= nil then
    state.disable_save_slots_animation:Cancel()
  end

  state.disable_save_slots_text_widget:SetString("Save Slots - "..(state.disable_save_slots and "OFF" or "ON"))
  state.disable_save_slots_text_widget:Show()

  state.disable_save_slots_animation = tasker:DoTaskInTime(duration, function()
    state.disable_save_slots_text_widget:Hide()
    state.disable_save_slots_animation = nil
  end)
end

function fn.InitDisableSaveSlotsStatusText()
  if not state.inventorybar then return end

  local text = Text(GLOBAL.UIFONT, 42, nil)
  text:Hide()
  text:SetVAlign(GLOBAL.ANCHOR_MIDDLE)
  text:SetHAlign(GLOBAL.ANCHOR_TOP)
  text:SetVAnchor(GLOBAL.ANCHOR_TOP)
  text:SetHAnchor(GLOBAL.ANCHOR_MIDDLE)
  text:SetPosition(0,-100,0)

  state.inventorybar:AddChild(text)

  state.disable_save_slots_text_widget = text
end

function fn.ClearSlotIcon(prefab)
  local image = state.image_buttons[prefab]

  if image then
    image:Kill()
    state.image_buttons[prefab] = nil
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
  if type(v) == "function" then
    return v(...)
  else
    return v
  end
end

function fn.GetComponent(o, component_name, get_replica)
  if o then
    if state.is_mastersim and not get_replica then
      return o.components and o.components[component_name]
    else
      return o.replica and o.replica[component_name]
    end
  end
end

function fn.IfHasComponent(o, component_name, ifFn, ifNot)
  local component = fn.GetComponent(o, component_name)

  if component then
    if type(ifFn) == "function" then
      return ifFn(component)
    else
      return component
    end
  else
    return fn.CallOrValue(ifNot)
  end
end

function fn.GetDurability(item)
  local percent

  if state.is_mastersim then
    percent = fn.IfHasComponent("finiteuses", function(fu)
      return fu:GetPercent()
    end)
  else
    local key = item and item.GUID
    percent = key and state.durability.items[key]
  end

  -- Never return nil, if no percentage is available we treat it as
  -- an item with infinite durability (e.g., Lucy)
  return percent or 1
end

function fn.GetSlot(prefab)
  if prefab then
    return slots[prefab]
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

  fn.UpdateSlotIcons(slot)
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

  fn.ClearSlotIcon(prefab)

  -- Update slot table as items has been changed
  slots = fn.GetItemSlots()

  fn.UpdateSlotIcons(slot)
end

function fn.ClearEntireSlot(slot)
  if type(items[slot]) ~= "table" then return end

  for i = #items[slot], 1, -1 do
    fn.ClearSlot(items[slot][i], slot)
  end
end

function fn.HasSlot(prefab)
  return fn.GetSlot(prefab) ~= nil
end

function fn.ApplyToItem(item)
  local apply = config.apply_to_items
  if apply == "all" then return true end

  if apply.equipment and fn.IsEquipment(item) then return true end
  if apply.food and fn.IsFood(item) then return true end
  if apply.healer and fn.IsHealer(item) then return true end

  return false
end

function fn.IsEquipment(item)
  return fn.GetComponent(item, "equippable") ~= nil
end

function fn.IsFood(item)
  if not item then return false end

  if state.is_mastersim then
    local edible = fn.GetComponent(item, "edible")
    if not edible then return false end
    local player = fn.GetPlayer()
    local eater = player and fn.GetComponent(player, "eater")
    if not eater or type(eater.CanEat) ~= "function" then return false end
    return eater:CanEat(item)
  else
    return fn.ItemHasAction(item, ACTIONS.EAT)
  end
end

function fn.IsHealer(item)
  if state.is_mastersim then
    return fn.GetComponent(item, "healer") ~= nil
  else
    return fn.ItemHasAction(item, ACTIONS.HEAL)
  end
end

function fn.ItemHasAction(item, target_action)
  if not item or type(item.CollectActions) ~= "function" then
    return false
  end

  local player = fn.GetPlayer()
  if not player then return false end

  local actions = {}
  item:CollectActions("INVENTORY", player, actions, true)
  for _, action in ipairs(actions) do
    if action == target_action then
      return true
    end
  end

  return false
end

function fn.GetEquipSlot(item)
  return fn.IfHasComponent(item, "equippable", function(eq)
    local equipslot = eq.EquipSlot and eq:EquipSlot() or eq.equipslot
    return equipslot
  end)
end

function fn.GetOverflowContainer(inventory)
  if state.is_dst then
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
    local overflow = state.is_dst and container or inventory.overflow

    if container then
      for i = 1, container.numslots do
        if container.slots[i] == nil then
          if container:GiveItem(item, nil, nil, false, true) then
            return 0, overflow
          end
        end
      end
    end

    -- When reserve saved slots is set to "If Free Slots"
    -- we try again since there appear to be no free slots.
    -- The previously reserved saved slots are already unblocked now.
    if config.reserve_saved_slots == "if_free_slots" then
      original_slot, original_container = original_fn(inventory, item)
    end
  end

  return original_slot, original_container
end

function fn.Inventory_GetNextAvailableSlot(original_fn)
  return function(self, item)
    local saved_slot = fn.GetSlot(item.prefab)

    if not saved_slot or not fn.ApplyToItem(item) then
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
    state.is_equipping = true
    local original_return = original_fn(self, item, old_to_active)
    state.is_equipping = false
    return original_return
  end
end

function fn.Player_OnEquip(inst, data)
  local item = data.item
  local eslot = data.eslot

  if not fn.ApplyToItem(item) then
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
    -- Client Mode: If we just equipped a container component this is some kind of backpack
    -- so we initialize the proper logic to handle it
    fn.IfHasComponent(item, "container", fn.InitOverflow)
    fn.ListenForDurabilityChanges(item)
  end
end

function fn.IsMasterSim()
  if not state.is_dst then
    return true
  end

  if GLOBAL.TheWorld then
    return not not GLOBAL.TheWorld.ismastersim
  else
    return true
  end
end

function fn.DumpTable(tbl, levels, prefix)
  if type(tbl) ~= "table" then
    print(tostring(tbl))
    return
  end

  local levels = levels or 2

  if levels < 1 then
    -- prevent endless loops on recursive tables
    return
  end

  for k,v in pairs(tbl) do
    local key = (prefix or "")..tostring(k)

    if type(v) == "table" and levels > 1 then
      fn.DumpTable(v, levels - 1, key..".")
    else
      print(key.." = "..tostring(v))
    end
  end
end

function fn.ListenForAllDurabilityChanges(items)
  if type(items) ~= "table" then
    return
  end

  for _, item in ipairs(items) do
    fn.ListenForDurabilityChanges(item)
  end
end

function fn.ListenForDurabilityChanges(item)
  local key = item and item.GUID
  if not key then
    return
  end

  if state.durability.listeners[key] ~= nil then
    -- Already listening
    return
  end

  if not fn.ApplyToItem(item) then
    return
  end

  local function listener(inst, data)
    if data and data.percent then
      state.durability.items[key] = data.percent
    end
  end

  item:ListenForEvent("percentusedchange", listener)
  state.durability.listeners[key] = listener

  -- Stop listening and clean up when item is destroyed
  item:ListenForEvent("onremove", function()
    item:RemoveEventCallback("percentusedchange", listener)

    state.durability.listeners[key] = nil
    state.durability.items[key] = nil
  end)
end

function fn.Player_OnItemGet(inst, data)
  local item = data.item
  local slot = data.slot

  if not state.is_mastersim then
    if fn.IsDuplicateItemGetEvent(data) then
      -- Client Mode receives some events twice (raised by client and server).
      -- If we have already processed the client version (which is always earlier) we stop.
      return
    end

    if fn.IsEquipment(item) then
      fn.ListenForDurabilityChanges(item)
    end
  end

  if not slot or not state.inventory or fn.IsLocked() then
    return
  end

  if state.is_mastersim then
    fn.MaybeSaveSlot(item, slot, state.inventory)
  else
    fn.MaybeMove(item, slot, state.inventory, function(new_slot, new_container)
      fn.MaybeSaveSlot(item, new_slot, new_container)
    end)
  end
end

function fn.MaybeSaveSlot(item, slot, container)
  if container ~= state.inventory then
    return
  end

  if state.disable_save_slots then
    return
  end

  if not fn.ApplyToItem(item) then
    return
  end

  local saved_slot, blocking_item, was_manually_moved = fn.GetItemMeta(item)
  local prefab_is_in_saved_slot = blocking_item and blocking_item.prefab == item.prefab
  local should_save_slot = not prefab_is_in_saved_slot and (was_manually_moved or not fn.HasSlot(item.prefab))

  if should_save_slot then
    fn.SaveSlot(item.prefab, slot)
  end
end

function fn.MaybeMove(item, slot, container, nextFn)
  local should_move = fn.ShouldMove(item, slot, container)
  if not should_move then
    fn.IfFn(nextFn, slot, container)
  else
    fn.Lock()

    local active_item = state.inventory:GetActiveItem()
    container:MoveAway(item, slot, function(new_slot, new_container)
      fn.Unlock()

      local ai_container, ai_slot = state.inventory:FindItemLocation(active_item)
      if ai_container ~= nil and ai_slot ~= nil then
        -- Take back our previously active item
        ai_container:Grab(ai_slot, function()
          fn.IfFn(nextFn, new_slot, new_container)
        end)
      else
        fn.IfFn(nextFn, new_slot, new_container)
      end
    end)
  end
end

function fn.ShouldMove(item, slot, container)
  local saved_slot, blocking_item, was_manually_moved = fn.GetItemMeta(item)

  if was_manually_moved then
    return false
  elseif saved_slot then
    if saved_slot == slot and container == state.inventory then
      return false
    end

    local should_move_blocking_item, action = fn.ShouldMakeSpace(saved_slot, blocking_item, item)
    if not blocking_item or should_move_blocking_item then
      return true
    end
  end

  -- All other cases: only move when reserving a saved slot
  if not config.reserve_saved_slots then
    return false
  else
    local is_in_saved_slot = container == state.inventory and items[slot] ~= nil
    if not is_in_saved_slot then
      return false
    elseif config.reserve_saved_slots == "always" then
      return true
    elseif config.reserve_saved_slots == "if_free_slots" then
      -- Only move if there is a free slot available
      local free_slot = state.inventory:GetFreeSlot() or (state.overflow and state.overflow:GetFreeSlot())
      return free_slot ~= nil
    end
  end
end

function fn.IsDuplicateItemGetEvent(data)
  if not data or not data.item or not data.item.GUID then
    return false
  end

  local item = data.item
  local slot = data.slot
  local is_server_event = not not data.ignore_stacksize_anim

  if is_server_event then
    local processed = state.client_processed[item.GUID]
    if processed and processed.slot == data.slot then
      state.client_processed[item.GUID] = nil
      return true
    end
  else
    state.client_processed[item.GUID] = { slot = slot }
  end

  return false
end

function fn.GetItemMeta(item)
  local saved_slot = fn.GetSlot(item.prefab)
  local blocking_item = saved_slot and state.inventory:GetItem(saved_slot)
  local was_manually_moved = not not state.manually_moved[item.GUID]

  return saved_slot, blocking_item, was_manually_moved
end

function fn.CanEquip(item)
  if state.is_equipping or not fn.IsEquipment(item) then
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
function fn.ShouldMakeSpace(slot, blocking_item, item)
  if not blocking_item then
    return false
  end

  if blocking_item == OCCUPIED then
    return false
  end

  local blocking_item_saved_slot = fn.GetSlot(blocking_item.prefab)

  if not fn.ApplyToItem(blocking_item) or blocking_item_saved_slot ~= slot then
    return true, "move"
  end

  local equip_blocking_item =
    config.allow_equip_for_space and
    fn.CanEquip(blocking_item)

  local move_blocking_item =
    not equip_blocking_item and
    blocking_item.prefab == item.prefab and
    fn.GetDurability(item) < fn.GetDurability(blocking_item)

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

    local should_move, action = fn.ShouldMakeSpace(slot, blocking_item, item)

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

  function ClientContainer:MoveAway(item, slot, nextFn)
    local new_slot, new_container = state.inventory:FindNewSlot(item, slot, self)

    local function callback()
      fn.IfFn(nextFn, new_slot, new_container)
    end

    local dont_move = new_slot == slot and new_container == self
    local move_to_active = new_slot == nil and new_container == nil
    if dont_move then
      callback()
    elseif move_to_active then
      self:Grab(slot, callback)
    else
      -- Moving to new_slot, new_container.
      -- First grab the item so our old slot is made available
      self:Grab(slot, function()
        if new_slot == "equip" then
          state.inventory:EquipActiveItem(callback)
        elseif new_slot then
          local blocking_item = new_container:GetItem(new_slot)
          if blocking_item then
            new_container:MoveAway(blocking_item, new_slot, callback)
          else
            new_container:Put(new_slot, callback)
          end
        else
          callback()
        end
      end)
    end
  end

  function ClientContainer:Grab(slot, nextFn)
    fn.Lock()

    self:WhenNotBusy(function()
      state.inventory:WhenNotBusy(function()
        local item = self:GetItem(slot)
        local active_item = state.inventory:GetActiveItem()

        if active_item then
          self.container:SwapActiveItemWithSlot(slot)
        else
          self.container:TakeActiveItemFromAllOfSlot(slot)
        end

        fn.Unlock()
        fn.IfFn(nextFn)
      end)
    end)
  end

  function ClientContainer:Put(slot, nextFn)
    fn.Lock()

    self:WhenNotBusy(function()
      state.inventory:WhenNotBusy(function()
        local item = self:GetItem(slot)
        local active_item = state.inventory:GetActiveItem()

        if item then
          self.container:SwapActiveItemWithSlot(slot)
        else
          self.container:PutAllOfActiveItemInSlot(slot)
        end

        fn.Unlock()
        fn.IfFn(nextFn)
      end)
    end)
  end

  function ClientContainer:SwapActiveItemWithSlot(slot, nextFn)
    self:WhenNotBusy(function()
      self.container:SwapActiveItemWithSlot(slot)
      fn.IfFn(nextFn)
    end)
  end

  function ClientContainer:Move(from, to, nextFn)
    fn.Lock()
    self:Grab(from, function()
      self:Put(to, function()
        fn.Unlock()
        fn.IfFn(nextFn)
      end)
    end)
  end

  function ClientContainer:Swap(slotA, slotB, nextFn)
    fn.Lock()
    self:Grab(slotA, function()
      self:SwapActiveItemWithSlot(slotB, function()
        self:Put(slotA, function()
          fn.Unlock()
          fn.IfFn(nextFn)
        end)
      end)
    end)
  end

  function ClientContainer:SwapWithInventory(from, inventory, to, nextFn)
    fn.Lock()
    inventory:WhenNotBusy(function()
      self:Grab(from, function()
        inventory:SwapActiveItemWithSlot(to, function()
          inventory:WhenNotBusy(function()
            self:Put(from, function()
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
      self:Grab(from, function()
        inventory:Put(to, function()
          fn.Unlock()
          fn.IfFn(nextFn)
        end)
      end)
    end)
  end

  function ClientContainer:GetFreeSlot()
    local numslots = self.container:GetNumSlots()
    if numslots then
      for slot = 1, numslots do
        local item = self:GetItem(slot)
        if not item then
          return slot
        end
      end
    end
  end

  function ClientContainer:GetItem(slot)
    return self.container:GetItemInSlot(slot)
  end

  function ClientContainer:FindItemLocation(target_item)
    if target_item == nil then
      return nil
    end

    local numslots = self.container:GetNumSlots()
    if numslots then
      for slot = 1, numslots do
        local item = self:GetItem(slot)
        if item == target_item then
          return self, slot
        end
      end
    end

    if self == state.inventory and state.overflow ~= nil then
      -- Look in overflow
      return state.overflow:FindItemLocation(target_item)
    end
  end

  function ClientContainer:FindItem(predicate)
    if predicate == nil then
      return nil
    end

    local numslots = self.container:GetNumSlots()
    if numslots then
      for slot = 1, numslots do
        local item = self:GetItem(slot)
        if predicate(item) then
          return item
        end
      end
    end

    if self == state.inventory and state.overflow ~= nil then
      -- Look in overflow
      return state.overflow:FindItem(predicate)
    end
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

  function ClientInventory:GetActiveItem()
    return self.inventory:GetActiveItem()
  end

  function ClientInventory:EquipActiveItem(nextFn)
    self:WhenNotBusy(function()
      self.inventory:EquipActiveItem()
      fn.IfFn(nextFn)
    end)
  end

  function ClientInventory:Equip(slot, nextFn)
    state.is_equipping = true
    fn.Lock()
    self:Grab(slot, function()
      self:EquipActiveItem(function()
        state.is_equipping = false
        fn.Unlock()
        fn.IfFn(nextFn)
      end)
    end)
  end

  function ClientInventory:FindNewSlot(item, slot, container)
    local saved_slot, blocking_item, was_manually_moved = fn.GetItemMeta(item)
    if saved_slot and (saved_slot ~= slot or container ~= state.inventory)  then
      local should_move, action = fn.ShouldMakeSpace(saved_slot, blocking_item, item)
      if not blocking_item or should_move then
        return saved_slot, self
      end
    end

    if config.allow_equip_for_space and fn.CanEquip(item) then
      return "equip", self
    end

    local free_slot = self:GetFreeSlot(config.reserve_saved_slots)
    if free_slot then
      return free_slot, self
    elseif state.overflow then
      free_slot = state.overflow:GetFreeSlot()
      if free_slot then
        return free_slot, state.overflow
      end
    elseif config.reserve_saved_slots == "if_free_slots" then
      -- When we were reserving saved slots only when we have free slots
      -- we will try again at this point, as there were no free slots available
      free_slot = self:GetFreeSlot(false)
      if free_slot then
        return free_slot, self
      end
    end

    -- No free slot available
    return nil, nil
  end

  function ClientInventory:EquipActiveItem(nextFn)
    state.is_equipping = true
    self:WhenNotBusy(function()
      self.inventory:EquipActiveItem()
      state.is_equipping = false
      fn.IfFn(nextFn)
    end)
  end

  function ClientInventory:GetFreeSlot(skip_saved_slots)
    local numslots = self.inventory:GetNumSlots()
    if numslots then
      for slot = 1, numslots do
        if not skip_saved_slots or not items[slot] then
          local item = self:GetItem(slot)
          if not item then
            return slot
          end
        end
      end
    end
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

function fn.InitOverflow(overflow)
  if  not overflow or not overflow.inst or
      type(overflow.inst.ListenForEvent) ~= "function" then
    return
  end

  local player = fn.GetPlayer()
  if not player then
    return
  end

  local items = overflow:GetItems()
  fn.ListenForAllDurabilityChanges(items)

  state.overflow = new.ClientContainer(overflow)

  local eslot = fn.GetEquipSlot(overflow.inst)

  local function OnItemGet(inst, data)
    local item = data.item
    local slot = data.slot

    if  not item or not fn.ApplyToItem(item) or fn.IsLocked() or
        not state.overflow or not state.inventory then
      return
    end

    if not state.is_mastersim and fn.IsDuplicateItemGetEvent(data) then
      return
    end

    fn.MaybeMove(item, slot, state.overflow)
  end

  local function OnUnequip(inst, data)
    if data and data.eslot == eslot then
      if type(overflow.inst.RemoveEventCallback) == "function" then
        overflow.inst:RemoveEventCallback("itemget", OnItemGet)
        state.overflow = nil
      end

      player:RemoveEventCallback("unequip", OnUnequip)
    end
  end

  overflow.inst:ListenForEvent("itemget", OnItemGet)
  player:ListenForEvent("unequip", OnUnequip)
end

function fn.Player_OnNewActiveItem(inst, data)
  if fn.IsLocked() then
    return
  end

  local item = data.item

  if item == nil then
    state.manually_moved.dirty = false
    fn.OnNextCycle(function()
      if not state.manually_moved.dirty then
        fn.ClearTable(state.manually_moved)
      end
    end)
  else
    state.manually_moved[item.GUID] = true
    state.manually_moved.dirty = true
  end
end

function fn.Inventorybar_Rebuild(original_fn)
  return function(self)
    original_fn(self)
    fn.OnNextCycle(fn.RefreshImageButtons)
  end
end

function fn.InitInventorybar(inventorybar)
  state.inventorybar = inventorybar

  fn.InitDisableSaveSlotsStatusText()

  if type(inventorybar.Rebuild) == "function" then
    inventorybar.Rebuild = fn.Inventorybar_Rebuild(inventorybar.Rebuild)
  end
end

function fn.InitInventory(inventory)
  if state.is_mastersim then
    state.inventory = new.MasterInventory(inventory)

    inventory.GetNextAvailableSlot = fn.Inventory_GetNextAvailableSlot(inventory.GetNextAvailableSlot)
    inventory.Equip = fn.Inventory_Equip(inventory.Equip)
    inventory.OnSave = fn.Inventory_OnSave(inventory.OnSave)
  else
    state.inventory = new.ClientInventory(inventory)

    -- Client Mode needs custom logic for overflow containers (backpack and the like)
    local overflow = inventory:GetOverflowContainer()
    fn.InitOverflow(overflow)

    -- Client Mode cannot directly access item durability but has to use events
    local items = inventory:GetItems()
    fn.ListenForAllDurabilityChanges(items)

    local equips = inventory:GetEquips()
    fn.ListenForAllDurabilityChanges(equips)
  end
end

function fn.PlayerHud_OnControl(base_fn)
  return function(self, control, down)
    local base_val = base_fn(self, control, down)

    if not base_val then
      local handlers = {
        -- Controller Clear Slot
        fn.HandleControllerKey,
      }

      for _, handler in ipairs(handlers) do
        if handler(self, control, down) then
          return true
        end
      end
    end

    return base_val
  end
end

function fn.PlayerHud_OnRawKey(base_fn)
  return function(self, key, down)
    local base_val = base_fn(self, key, down)

    if not base_val then
      local handlers = {
        -- Disable Save Slots
        fn.HandleDisableSaveSlots,
      }

      for _, handler in ipairs(handlers) do
        if handler(self, key, down) then
          return true
        end
      end
    end

    return base_val
  end
end

function fn.HandleControllerKey(hud, control, down)
  if not hud:IsControllerInventoryOpen() then
    return false
  end

  local is_lb = control == CONTROLS.LB
  local is_rb = control == CONTROLS.RB

  if down and state.inventorybar and (is_lb or is_rb) then
    local is_both =
      (is_lb and TheInput:IsControlPressed(CONTROLS.RB)) or
      (is_rb and TheInput:IsControlPressed(CONTROLS.LB))

    if is_both then
      local active_slot = state.inventorybar.active_slot

      if active_slot and active_slot.num and state.inventory then
        local is_inventory = false

        if state.is_dst and state.is_mastersim then
          -- In DST, active_slot.container points to the inventory replica
          -- but when we also run the Master Simulation our state.inventory.inventory
          -- is the actual inventory, not the replica.
          local player = fn.GetPlayer()
          is_inventory = player and player.replica and player.replica.inventory == active_slot.container
        else
          is_inventory = active_slot.container == state.inventory.inventory
        end

        if is_inventory then
          fn.ClearEntireSlot(active_slot.num)
          return true
        end
      end
    end
  end

  return false
end

function fn.HandleDisableSaveSlots(hud, key, down)
  if down and config.disable_save_slots_toggle and key == config.disable_save_slots_toggle and  TheInput:IsKeyDown(GLOBAL.KEY_CTRL) then
    state.disable_save_slots = not state.disable_save_slots
    fn.ShowDisableStatusText(3)
    return true
  end
end

function fn.InitPlayerHud()
  if not PlayerHud then return end
  PlayerHud.OnControl = fn.PlayerHud_OnControl(PlayerHud.OnControl)
  PlayerHud.OnRawKey = fn.PlayerHud_OnRawKey(PlayerHud.OnRawKey)
end

function fn.InitConfig()
  local function ParseBitFlags(flags, values)
    if #flags ~= #values or not string.find(flags, "^[01]+$") then
      return flags
    end

    local map = {}
    for i = 1, #flags do
      map[values[i]] = string.sub(flags, i, i) == "1"
    end
    return map
  end

  config.apply_to_items = ParseBitFlags(GetModConfigData("apply_to_items"), { "equipment", "food", "healer" })
  config.show_slot_icons = GetModConfigData("show_slot_icons")
  config.slot_icon_opacity = GetModConfigData("slot_icon_opacity")
  config.slot_icon_scale = GetModConfigData("slot_icon_scale")
  config.allow_equip_for_space = GetModConfigData("allow_equip_for_space")
  config.reserve_saved_slots = GetModConfigData("reserve_saved_slots")
  config.disable_save_slots_toggle = GetModConfigData("disable_save_slots_toggle")
  config.save_slots_initial_state = GetModConfigData("save_slots_initial_state")

  -- Apply Save Slots initial state to the state table
  -- Only applied when a toggle key is configured
  if config.disable_save_slots_toggle then
    state.disable_save_slots = not config.save_slots_initial_state
  end
end

function fn.InitPlayerEvents(player)
  player:ListenForEvent("equip", fn.Player_OnEquip)
  player:ListenForEvent("itemget", fn.Player_OnItemGet)
  player:ListenForEvent("newactiveitem", fn.Player_OnNewActiveItem)
end

function fn.InitSaveEquipmentSlots()
  AddSimPostInit(function()
    state.is_mastersim = fn.IsMasterSim()
    fn.InitAtlasFiles()
  end)

  AddPlayerPostInit(function(player)
    fn.OnNextCycle(function()
      -- Make sure it is the current player
      if player == fn.GetPlayer() then
        fn.InitPlayerEvents(player)
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
      fn.UpdateSlotIcons(invslot.num)
    end)
  end)

  fn.InitPlayerHud()
  fn.InitClasses()
  fn.InitConfig()
end

fn.InitSaveEquipmentSlots()

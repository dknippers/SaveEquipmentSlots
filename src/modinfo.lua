name = "Save Equipment Slots"
description = "Saves the inventory slots of equipment items and makes sure they always return to their saved slot. If a saved slot is occupied items will be rearranged automatically to make space."
author = "dani"
version = "1.8.3"
forumthread = ""
api_version = 6
api_version_dst = 10

dont_starve_compatible = true
reign_of_giants_compatible = true
shipwrecked_compatible = true
hamlet_compatible = true
dst_compatible = true

all_clients_require_mod = false
client_only_mod = true

icon_atlas = "modicon.xml"
icon = "modicon.tex"

local disable_save_slot_toggle_options = {
  { description = "- none -", data = false },
}

for i = 0, 25 do
  disable_save_slot_toggle_options[i + 2] = {
    description = "Control + " .. ("").char(65 + i),
    data = 97 + i
  }
end

-- 5% to 100% with steps of 5
local percentage_options = {}
for i = 1, 20 do
  local percentage = i * 5
  local data = percentage / 100
  percentage_options[i] = {
    description = percentage .. "%",
    data = data
  }
end

local offset_options = {}
for i = 0, 16 do
  local data = 1 + (i * .25)
  local extra_offset = (data - 1) * 100
  offset_options[i+1] = {
    description = i == 0 and "Default" or "+" .. extra_offset .. "%",
    data = data
  }
end

configuration_options =
{
  {
    name = "apply_to_items",
    label = "Apply To Items",
    hover = "Configure which item types should be saved.",

    options = {
      { description = "Equipment", data = "100" },
      { description = "Eq. + Food", data = "110" },
      { description = "Eq. + Healing", data = "101" },
      { description = "Eq. + Fo. + He.", data = "111" },
      { description = "All items", data = "all" },
    },

    default = "100"
  },

  {
    name = "show_slot_icons",
    label = "Show Slot Icons",
    hover = "Shows an icon of a saved item above its saved slot.\n"..
            "Click the icon to clear the saved slot of that item.",

    options = {
      { description = "Show", data = true },
      { description = "Hide", data = false },
    },

    default = true
  },

  {
    name = "slot_icon_opacity",
    label = "Slot Icon Opacity",
    hover = "Set the opacity of the slot icons.",

    options = percentage_options,
    default = .75
  },

  {
    name = "slot_icon_scale",
    label = "Slot Icon Scale",
    hover = "Set the scale of the slot icons.",

    options = percentage_options,
    default = .75
  },

  {
    name = "slot_icon_offset",
    label = "Slot Icon Vertical Offset",
    hover = "Set the vertical offset of the slot icons\n" ..
            "expressed as a percentage of 1 inventory slot height.",

    options = offset_options,
    default = 1
  },

  {
    name = "disable_save_slots_toggle",
    label = "Disable Save Slots Toggle",
    hover = "Key combination that will toggle saving slots on/off.",
    options = disable_save_slot_toggle_options,
    default = false
  },

  {
    name = "save_slots_initial_state",
    label = "Save Slots Initial State",
    hover = "The initial state of the Save Slots behavior.\n"..
            "Only used when a toggle key is configured.",

    options = {
      { description = "On", data = true },
      { description = "Off", data = false },
    },

    default = true
  },

  {
    name = "disable_slot_icon_click_when_save_slots_off",
    label = "Disable Slot Icon Click",
    hover = "Controls when clicking slot icons is disabled.",
    options = {
      { description = "Never", data = false },
      { description = "If Save Slots: Off", data = true },
    },
    default = false
  },

  {
    name = "allow_equip_for_space",
    label = "Allow Equip For Space",
    hover = "Allows an item to be equipped in order to make space for an incoming item.",
    options = {
      { description = "Enabled", data = true },
      { description = "Disabled", data = false },
    },

    default = true
  },

  {
    name = "reserve_saved_slots",
    label = "Reserve Saved Slots",
    hover = "Determines if saved slots will be reserved for their items\n"..
            "and if this only happens when there are other slots available.",

    options = {
      { description = "Never", data = false },
      { description = "If Free Slots", data = "if_free_slots" },
      { description = "Always", data = "always" },
    },

    default = false
  },

  {
    name = "dst_save_items_on_spawn",
    label = "DST: Save Items on Spawn",
    hover = "Saves the slots of all items in the inventory when spawned.\n "..
            "Helps to restore saved slots when resuming or going to Caves.\n",

    options = {
      { description = "Enabled", data = true },
      { description = "Disabled", data = false },
    },

    default = true
  },

}

name = "Save Equipment Slots"
description = "Saves the inventory slots of equipment items and makes sure they always return to their saved slot. If a saved slot is occupied items will be rearranged automatically to make space."
author = "dani"
version = "1.4.0"
forumthread = ""
api_version = 6
api_version_dst = 10

dont_starve_compatible = true
reign_of_giants_compatible = true
shipwrecked_compatible = true
dst_compatible = true

all_clients_require_mod = false
client_only_mod = true

icon_atlas = "modicon.xml"
icon = "modicon.tex"

configuration_options =
{
  {
    name = "enable_previews",
    label = "Slot Previews",
    hover = "Shows a preview of the saved equipment above each inventory slot.\n"..
            "Click a preview to clear the saved slot of that equipment.",

    options = {
      { description = "Enabled", data = true },
      { description = "Disabled", data = false },
    },

    default = true
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
      { description = "If Free Slots", data = "if_free_slots" },
      { description = "Always", data = "always" },
      { description = "Never", data = false },
    },

    default = false
  },

  {
    name = "disable_save_slots_key",
    label = "Disable Save Slots Key",
    hover = "Key that will disable saving any slots when held down while\n"..
            "picking up items or moving them around.",

    options = {
      { description = "- none -", data = false },
      { description = "alt", data = 400 },
      { description = "ctrl", data = 401 },
      { description = "shift", data = 402 },
    },

    default = false
  },

  {
    name = "apply_to_items",
    label = "Apply To Items",
    hover = "Save slots of these item types",

    options = {
      { description = "Equipment", data = "100" },
      { description = "Eq. + Food", data = "110" },
      { description = "Eq. + Healing", data = "101" },
      { description = "Eq. + Fo. + He.", data = "111" },
      { description = "All items", data = "all" },
    },

    default = "100"
  },
}

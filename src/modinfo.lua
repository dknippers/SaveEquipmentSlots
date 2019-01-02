name = "Save Equipment Slots"
description = "Saves the inventory slots of equipment items and makes sure they always return to their saved slot. If a saved slot is occupied items will be rearranged automatically to make space."
author = "dani"
version = "1.3.5"
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
    hover = "Only put new items in saved slots when there is no other alternative slot\n"..
            "available in the inventory or backpack.",

    options = {
      { description = "Enabled", data = true },
      { description = "Disabled", data = false },
    },

    default = false
  }
}

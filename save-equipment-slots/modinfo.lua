name = "Save Equipment Slots"
description = "Saves the inventory slots of equipment items and makes sure they always return to their saved slot. If a saved slot is occupied items will be rearranged automatically to make space."
author = "dani"
version = "1.0.0"
forumthread = ""
api_version = 6

dont_starve_compatible = true
reign_of_giants_compatible = true
shipwrecked_compatible = true

restart_required = false
standalone = false

icon_atlas = "modicon.xml"
icon = "modicon.tex"

configuration_options =
{
  {
    name = "enable_previews",
    label = "Slot Previews",
    hover = "Shows a preview of the saved equipment above each inventory slot",

    options = {
      { description = "Enabled", data = true },
      { description = "Disabled", data = false },
    },

    default = true
  },

  {
    name = "allow_equip_for_space",
    label = "Allow Equip For Space",
    hover = "Allows an item to be equipped in order to make space for an incoming item.\n"..
            "This will only happen when the incoming item and the blocking item share a saved slot.",

    options = {
      { description = "Enabled", data = true },
      { description = "Disabled", data = false },
    },

    default = true
  }
}
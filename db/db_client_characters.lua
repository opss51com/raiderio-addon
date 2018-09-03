--
-- RaiderIO Client Data. Generated on 2018-09-03T19:30:47Z
--
local _, ns = ...
ns.CLIENT_CHARACTERS = {
  ["Voidzone-Ravencrest"] = {
    ["profile"] = {
      ["name"] = "Voidzone",
      ["realm"] = "Ravencrest",
      ["faction"] = "alliance",
      ["race"] = 4,
      ["class"] = 12
    },
    ["mythic_keystone"] = {
      ["all"] = {
        ["score"] = 0,
        ["best"] = nil,
        ["runs"] = {

        }
      }
    }
  }
}

if RaiderIO then RaiderIO.AddClientCharacters(ns.CLIENT_CHARACTERS) end

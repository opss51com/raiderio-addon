--
-- RaiderIO Client Data. Generated on 2018-09-03T19:30:46Z
--
local _, ns = ...
ns.GUILD_BEST_DATA = {
  ["Eight Days A Week-Auchindoun"] = {
    ["profile"] = {
      ["name"] = "Eight Days A Week",
      ["realm"] = "Auchindoun",
      ["faction"] = "alliance"
    },
    ["season_best"] = {

    },
    ["weekly_best"] = {

    }
  },
  ["Overcharged-Ravencrest"] = {
    ["profile"] = {
      ["name"] = "Overcharged",
      ["realm"] = "Ravencrest",
      ["faction"] = "alliance"
    },
    ["season_best"] = {

    },
    ["weekly_best"] = {

    }
  }
}

if RaiderIO then RaiderIO.AddClientGuilds(ns.GUILD_BEST_DATA) end

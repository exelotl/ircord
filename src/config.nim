import parsetoml
import regex

type
  IrcConfig* = object
    server*: string
    port*: int
    nickname*: string
    password*: string
    adminList*: seq[string]
    ignoreList*: seq[string]
    opPatterns*: seq[Regex]
  
  DiscordConfig* = object
    token*: string
    guild*: string

  ChannelMapping* = object
    name*, irc*, discord*, webhook*: string
  
  Config* = object
    irc*: IrcConfig
    discord*: DiscordConfig
    mapping*: seq[ChannelMapping]

proc findByName*(c: Config, name: string): ChannelMapping =
  for entry in c.mapping:
    if entry.name == name: return entry

proc findIrc*(c: Config, ircChan: string): ChannelMapping = 
  for entry in c.mapping:
    if entry.irc == ircChan: return entry

proc findDiscord*(c: Config, discordId: string): ChannelMapping = 
  for entry in c.mapping:
    if entry.discord == discordId: return entry

proc parseConfig*(filename = "ircord.toml"): Config = 
  try:
    let data = parseFile(filename)

    let irc = data["irc"]
    result.irc = IrcConfig(
      server: irc["server"].getStr(),
      port: irc["port"].getInt(),
      nickname: irc["nickname"].getStr(),
      password: irc["password"].getStr(),
    )
    for admin in irc["adminList"].getElems():
      result.irc.adminList.add(admin.getStr())
    for nick in irc["ignoreList"].getElems():
      result.irc.ignoreList.add(nick.getStr())
    for pattern in irc["opPatterns"].getElems():
      result.irc.opPatterns.add(re(pattern.getStr()))

    let discord = data["discord"]
    result.discord = DiscordConfig(
      token: discord["token"].getStr(),
      guild: discord["guild"].getStr()
    )

    let mappings = data["mapping"]
    result.mapping = newSeqOfCap[ChannelMapping](mappings.len)

    for mapping in mappings.getElems():
      result.mapping.add ChannelMapping(
        name: if "name" in mapping: (mapping["name"].getStr()) else: "",
        irc: mapping["irc"].getStr(),
        discord: mapping["discord"].getStr(),
        webhook: mapping["webhook"].getStr()
      )
  
  except:
    raise newException(ValueError, "Can't parse the configuration file!")

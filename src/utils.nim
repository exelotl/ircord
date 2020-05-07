import asyncdispatch, strutils, tables, options
import dimscord
import npeg

proc getUsers*(s: DiscordClient, guild, part: string): Future[seq[User]] {.async.} = 
  ## Get all users whose usernames contain `part` string
  result = @[]
  var data = await s.api.getGuildMembers(guild, 1000, "0")
  for member in data:
    if part in $member.user:
      let user = member.user
      result.add(user)

proc handleObjects*(s: DiscordClient, msg: Message, content: string): string = 
  result = content
  type
    Kind = enum Emote, Mention, Channel
    Data = object
      kind: Kind
      r: tuple[old, id: string]

  # A simple NPEG parser, done with the help of leorize from IRC
  let objParser = peg("discord", d: seq[Data]):
    # Emotes like <:nim1:321515212521> <a:monakSHAKE:472058550164914187>
    emote <- "<" * ?"a" * >(":" * +Alnum * ":") * +Digit * ">":
      d.add Data(kind: Emote, r: (old: $0, id: $1))

    # User mentions like <@!2315125125> <@408815590170689546>
    mention <- "<@" * ?"!" * >(+Digit) * ">":
      # logic for handling mentions
      d.add Data(kind: Mention, r: (old: $0, id: $1))

    # Channel mentions like <#125125125215>
    channel <- "<#" * >(+Digit) * ">":
      # logic for handling channels
      d.add Data(kind: Channel, r: (old: $0, id: $1))

    matchone <- channel | emote | mention

    discord <- +@matchone
  
  var data = newSeq[Data]()
  let match = objParser.match(result, data)
  if not match.ok: 
    return
  
  for obj in data:
    case obj.kind
    of Emote: result = result.replace(obj.r.old, obj.r.id)
    of Mention:
      # Iterate over all mentioned users and find the one we need
      for user in msg.mention_users:
        if user.id == obj.r.id:
          result = result.replace(obj.r.old, "@" & $user.username)
    of Channel:
      let chan = s.cache.guildChannels.getOrDefault(obj.r.id)
      if not chan.isNil():
        result = result.replace(obj.r.old, "#" & chan.name)
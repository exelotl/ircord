import discordnim/discordnim, asyncdispatch, strutils, options




proc getUserID*(s: Shard, guild, username: string): Future[string] {.async.} = 
  ## Gets user ID from `username` (which is Discord username with # and discriminator)
  result = ""
  var data = await s.guildMembers(guild, 1000, 0)
  for member in data:
    if member.user.isSome() and $member.user.get() == username:
      let user = member.user.get()
      return user.id
  
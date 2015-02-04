# B.Y.O.C (Bring Your Own Code)

Q = require 'q'
F = require 'fb'
s = require 'slack-node'
M = require 'moment'
_ = require 'underscore'

# secrets
FB_ACCESS_TOKEN = process.env.FACEBOOK_ACCESS_TOKEN
SL_ACCESS_TOKEN = process.env.SLACK_ACCESS_TOKEN

MAP_FB_SL = [
  {fb: 'Hwanki Kang'   , sl: 'kangki'  }, {fb: '윤정부'      , sl: 'coma333'},
  {fb: 'Juntai Park'   , sl: 'rkjun'   }, {fb: 'Cheol Ho Lee', sl: 'zziro'  },
  {fb: '김태원'        , sl: 'mniktw'  }, {fb: '전성균'      , sl: 'mohwa'  },
  {fb: 'YongHun Byun'  , sl: 'river'   }, {fb: 'Sungjin Kang', sl: 'ujuc'   },
  {fb: 'Kyung Yeol Kim', sl: 'chitacan'}, {fb: 'IMa ZiNel'   , sl: 'imazine'},
  {fb: '김정호' }, { fb: 'Jajung Kim' }, { fb: '김진우' },
]

F.setAccessToken FB_ACCESS_TOKEN
S = new s SL_ACCESS_TOKEN

FB_API = Q.nbind F.napi
SL_API = Q.nbind S.api

PAGE_URL = "https://www.facebook.com/events/"
MAP_URL  = "https://maps.googleapis.com/maps/api/staticmap?" +
           "zoom=17&size=500x500&maptype=roadmap&markers=color:red|"

getEventDetail = (id) ->
  FB_API '', 'post', {
    batch : [
      { method: 'get', relative_url: id }
      { method: 'get', relative_url: "#{id}/attending" }
      { method: 'get', relative_url: "#{id}/noreply" }
      { method: 'get', relative_url: "#{id}/maybe" }
    ]
    include_headers : false
  }
  .then (res) -> res.map (item) -> JSON.parse item.body
  .then (res) -> res.map (item) -> if item.data then item.data else item
  .then (res) ->
    rest = _.rest res
    {
      meta     : _.first(res),
      maybe    : rest.pop(),
      noreply  : rest.pop(),
      attending: rest.pop()
    }

channelName = (event) ->
  name = event.meta.name.split /(\s|-|_)/i, 1
  name = name.slice 0, 12
  date = M(event.meta.start_time).format('YY-M-D')
  "#{name}_#{date}".toLowerCase()

# create a channel & set topic, invite users
#
# @param {Object[]}
# @param {Object} event[].meta - event detail info contains name, owner, venue.
# @param {Object[] event[].noreply - 
# @param {Object[] event[].maybe - 
# @param {Object[] event[].attending - 
# @return
#
createChannel = (event) ->
  eventUrl = (id  ) -> "Event Page - #{PAGE_URL}#{id}"
  mapUrl   = (addr) -> "Event Map - #{MAP_URL}#{addr.replace /\s/g, '+'}"

  # max channel name length : 21
  Q.all([ event, SL_API('channels.create', {name: channelName event}) ])
    .spread (event, res) ->
      throw {name: "ChannelCreateException", message: res.error} unless res.ok
      event.channel = res.channel
      event
    .then (event) ->
      topic = event.meta.description
      id    = event.channel.id
      map   = mapUrl event.meta.venue.street
      eurl  = eventUrl event.meta.id
      [
        event
        SL_API('channels.setTopic', {channel: id, topic: topic})
        SL_API('chat.postMessage' , {channel: id, text: map   })
        SL_API('chat.postMessage' , {channel: id, text: eurl  })
      ]
    .spread (event, topic, map, page) ->
      throw {name: "TopicException", message: topic.error} unless topic.ok
      throw {name: "MapException"  , message: map.error  } unless map  .ok
      throw {name: "PageException" , message: page.error } unless page .ok
      event
    .then (event) ->
      id = event.channel.id
      invitees_fb = _.chain event.attending
        .concat event.maybe
        .pluck 'name'
        .value()
      invitees = _.chain MAP_FB_SL
        .filter (item) -> _.contains invitees_fb, item.fb
        .pluck 'sl'
        .value()
      [event, invitees, SL_API 'users.list']
    .spread (event, invitees, users) ->
      throw {name: "UserListException", message: users.error} unless users.ok
      res = _.chain users.members
        .filter (member) -> _.contains invitees, member.name
        .pluck 'id'
        .value()
        .map (id) -> SL_API 'channels.invite', {channel: event.channel.id, user:id}
      [event, res]
    .spread (event) -> event
    .fail (err) ->
      console.error event.meta
      throw err

# open channels based on given events
#
# @param {Object[]} - facebook events containing id, start_time.
# @param {string} event[].id - event id.
# @param {string} event[].start_time - event start time.
# @return
#
openChannels = (events) ->
  return 'no need to open channel' unless events and events.length

  Q.allSettled(events.map (event) -> getEventDetail event.id)
    .then   (result) -> _.pluck result, 'value'
    .then   (events) -> events.map (event) -> createChannel event
    .spread (      ) ->
      console.log 'channel opened'
      console.log _(arguments).value()
    .fail   (err   ) -> throw err

closeChannels = (events) ->
  return 'no need to close channel' unless events and events.length

  # finish url http://pds9.egloos.com/pds/200808/08/41/a0007341_489b91fd0caf0.jpg
  Q.allSettled(events.map (event) -> getEventDetail event.id)
    .then   (result) -> _.pluck result, 'value'
    .then   (events) -> events.map (event) -> channelName event
    .then   (names ) -> [names, SL_API 'channels.list', {exclude_archived:1}]
    .spread (names, res) ->
      throw {name: "ChannelListException", message: res.error} unless res.ok
      channels = res.channels
      ids = _.chain channels
        .filter (channel) -> _.contains names, channel.name
        .pluck 'id'
        .value()
      [channels, ids]
    .spread (channels, ids) ->
      ids.map (id) -> SL_API 'channels.archive', {channel:id}
    .spread (   ) ->
      console.log 'channel archived'
      console.log _(arguments).values()
    .fail   (err) -> throw err

getEvents = () ->
  # get redribbon facebook group events
  FB_API '258059967652595/events', {limit : 10, fields: 'id,start_time,end_time'}
  .then (event) ->
    today = M()
    [
      event.data.filter (e) ->  6 > M(e.start_time).diff(today, 'hours') >= 0
      event.data.filter (e) -> -4 > M(e.end_time  ).diff(today, 'hours') >= -12
    ]
  .fail (err) ->
    throw {
      name    : "Exception on getEvents"
      message : err.message
    }

poll = () ->
  defer = Q.defer()
  delay = M.duration(2, 'hours').asMilliseconds()
  interval = setInterval () ->
    defer.notify()
  , delay
  defer.promise

start = () ->
  poll().progress () -> 
    getEvents()
    .spread (future, past) ->
      [openChannels(future), closeChannels(past)]
    .spread (created, archived) ->
      console.log created
      console.log archived
    .fail (err) -> console.error err

module.exports = (robot) -> start()

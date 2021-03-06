debug   = require('debug')('emojitrack-sse:server')
app     = require('express')()
http    = require('http')
server  = http.Server(app)

config         = require('./lib/config')
ScorePacker    = require('./lib/scorePacker')
ConnectionPool = require('./lib/connectionPool')
Monitor        = require('./lib/monitor')

###
# stand up services
###

if config.ENV is 'staging' or config.ENV is 'production'
  # trust x forwarded for headers from proxy (heroku routing)
  app.enable('trust proxy')
  # enable new relic reporting
  require('newrelic')

server.listen config.PORT, ->
  console.log('Listening on ' + config.PORT)

###
# routing event stuff
###
clients = new ConnectionPool()

app.get '/subscribe/:namespace*', (req, res) ->
  namespace = '/' + req.params.namespace + req.params[0]
  clients.provision req,res,namespace


###
# redis event stuff
###
redisStreamClient = config.redis_connect()
scorepacker = new ScorePacker(17) #17ms

redisStreamClient.subscribe('stream.score_updates')
redisStreamClient.psubscribe('stream.tweet_updates.*')
# redisStreamClient.psubscribe('stream.interaction.*')

redisStreamClient.on 'message', (channel, msg) ->
  # in theory we could check the channel, but since we are only subscribed to one
  # let's not bother and save an unncessary comparison operation.  in future may be necessary.
  clients.broadcast {data: msg, event: null, namespace: '/raw'}
  scorepacker.increment(msg) #send to score packer for eps rollup stream

redisStreamClient.on 'pmessage', (pattern, channel, msg) ->
  if pattern == 'stream.tweet_updates.*'
    id = channel.split('.')[2]
    clients.broadcast {
                        data: msg
                        event: channel
                        namespace: "/details/#{id}"
                      }
  # else if pattern == 'stream.interaction.*'
  #TODO: reimplement me when we need kiosk mode again

scorepacker.on 'expunge', (scores) ->
  clients.broadcast {data: JSON.stringify(scores), event: null, namespace: '/eps'}


###
# monitoring
###
monitor = new Monitor(clients)
app.get '/admin/status.json', (req, res) ->
  res.json monitor.status_report()

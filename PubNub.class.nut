// Copyright (c) 2014 Electric Imp
// This file is licensed under the MIT License
// http://opensource.org/licenses/MIT

// Wrapper Class for PubNub, a publish-subscribe service
// REST documentation for PubNub is at http://www.pubnub.com/http-rest-push-api/
class PubNub {

    static version = [1, 1, 0];

    static PUBNUB_BASE = "https://pubsub.pubnub.com";
    static PRESENCE_BASE = "https://pubsub.pubnub.com/v2/presence";

    _publishKey = null;
    _subscribeKey = null;
    _authKey = null;
    _uuid = null;

    _subscribe_request = null;

    // Class ctor. Specify your publish key, subscribe key, secret key, and optional UUID
    // If you do not provide a UUID, the Agent ID will be used
    //
    // This class has no need of secretKey, we are keeping it as a constructor param
    // to prevent existing code from breaking
    constructor(publishKey, subscribeKey, secretKey = null, uuid = null) {
        this._publishKey = publishKey;
        this._subscribeKey = subscribeKey;

        if (uuid == null) uuid = split(http.agenturl(), "/").top();
        this._uuid = uuid;
    }


    /******************** PRIVATE FUNCTIONS (DO NOT CALL) *********************/
    function _defaultPublishCallback(err, data) {
        if (err) {
            server.log(err);
            return;
        }
        if (data[0] != 1) {
            server.log("Error while publishing: " + data[1]);
        } else {
            server.log("Published data at " + data[2]);
        }
    }

    /******************* PUBLIC MEMBER FUNCTIONS ******************************/

    // Set auth parameters
    // Input: options (optional) - table
    //      may contain (auth_key, value), (publish_key, value), and/or (subscribe_key, value) pairs
    //      calling auth() clears auth data
    function auth(options = {}) {
        // grab any keys that were included
        if ("auth_key" in options) this._authKey = options.auth_key;
        if ("publish_key" in options) this._pubKey = options.publish_key;
        if ("subscribe_key" in options) this._subKey = options.subscribe_key;

        // calling auth() clears auth data
        if (options == {}) {
            _authKey = null;
            _pubKey = null;
            _subKey = null;
        }
    }

    // Publish a message to a channel
    // Input:   channel (string)
    //          data - squirrel object, will be JSON encoded
    //          callback (optional) - to be called when publish is complete
    //      Callback takes two parameters:
    //          err - null if successful
    //          data - squirrel object; JSON-decoded response from server
    //              Ex: [ 1, "Sent", "14067353030261382" ]
    //      If no callback is provided, _defaultPublishCallback is used
    function publish(channel, data, callback = null) {

        local msg = http.urlencode({m=http.jsonencode(data)}).slice(2);
        local url = format("%s/publish/%s/%s/%s/%s/%s/%s?uuid=%s", PUBNUB_BASE, _publishKey, _subscribeKey, "0", channel, "0", msg, _uuid);

        if (_authKey != null) {
            url += format("&auth=%s", _authKey);
        }

        http.get(url).sendasync(function(resp) {
            local err = null;
            local data = null;

            // process data
            if (resp.statuscode != 200) {
                err = format("%i - %s", resp.statuscode, resp.body);
            } else {
                try {
                    data = http.jsondecode(resp.body);
                } catch (ex) {
                    err = ex;
                }
            }

            // callback
            if (callback != null) callback(err, data);
            else _defaultPublishCallback(err, data);
        }.bindenv(this));
    }

    // Subscribe to one or more channels
    // Input:
    //      channelsArray - array of channels to subscribe to
    //      callback      - onData callback with three parameters:
    //          err           - A string containing the error, or null on success
    //          result        - A table containing (channel, value) pairs for each message
    //          timetoken     - nanoseconds since UNIX epoch, (from PubNub service)
    //      [timetoken]   - callback with any new value since (timetoken).
    //
    // NOTE1: The callback will be initially called once with result = {} and tt = 0 after first subscribing
    // NOTE2: Subscribe should generally be called with the timetoken parameter ommited
    function subscribe(channelsArray, callback, tt = 0) {

        // Build the URL
        local channels = "";
        foreach (idx, channel in channelsArray) {
            channels += channel + ",";
        }
        if (channels.len() > 0) channels = channels.slice(0, channels.len() - 1);

        local url = format("%s/subscribe/%s/%s/0/%s?uuid=%s", PUBNUB_BASE, _subscribeKey, channels, tt.tostring(), _uuid);

        if (_authKey != null) {
            url += format("&auth=%s", _authKey);
        }

        // Build and send the subscribe request
        if (_subscribe_request) _subscribe_request.cancel();
        _subscribe_request = http.get(url);
        _subscribe_request.sendasync(function(resp) {

            _subscribe_request = null;
            local err = null;
            local data = null;
            local messages = null;
            local rxchannels = null;
            local result = {};
            local timeout = 0.0;

            // process data
            if (resp.statuscode != 200) {
                err = format("%i - %s", resp.statuscode, resp.body);
                timeout = 0.5;
            } else {
                try {
                    data = http.jsondecode(resp.body);
                    messages = data[0];
                    tt = data[1];

                    if (data.len() > 2) {
                        rxchannels = split(data[2],",");
                        local chidx = 0;
                        foreach (ch in rxchannels) {
                            result[ch] <- messages[chidx++]
                        }
                    } else {
                        if (messages.len() == 0) {
                            // successfully subscribed; no data yet
                        } else  {
                            // no rxchannels, so we have to fall back on the channel we called with
                            result[channelsArray[0]] <- messages[0];
                        }
                    }
                } catch (ex) {
                    err = ex;
                }
            }

            // callback
            callback(err, result, tt);

            imp.wakeup(timeout, function() { this.subscribe(channelsArray,callback,tt) }.bindenv(this));
        }.bindenv(this));
    }

     // Get historical data from a channel
    // Input:
    //      channel (string)
    //      limit - max number of historical messages to receive
    //      callback - called on response from PubNub, takes two parameters:
    //          err - null on success
    //          data - array of historical messages
    function history(channel, limit, callback) {
        local url = format("%s/history/%s/%s/0/%d", PUBNUB_BASE, _subscribeKey, channel, limit);

        if (_authKey != null) {
            url += format("?auth=%s", _authKey);
        }

        http.get(url).sendasync(function(resp) {
            local err = null;
            local data = null;

            // process data
            if (resp.statuscode != 200) {
                err = format("%i - %s", resp.statuscode, resp.body);
            } else {
                data = http.jsondecode(resp.body);
            }
            callback(err, data);
        }.bindenv(this));
    }

    // Inform Presence Server that this UUID is leaving a given channel
    // UUID will no longer be returned in results for other presence services (whereNow, hereNow, globalHereNow)
    // Input:
    //      channel (string)
    // Return: None
    function leave(channel) {
        local url = format("%s/sub_key/%s/channel/%s/leave?uuid=%s",PRESENCE_BASE,_subscribeKey,channel,_uuid);

        if (_authKey != null) {
            url += format("&auth=%s", _authKey);
        }

        http.get(url).sendasync(function(resp) {
            local err = null;
            local data = null;

            if (resp.statuscode != 200) {
                err = format("%i - %s", resp.statuscode, resp.body);
                throw "Error Leaving Channel: "+err;
            }
        });
    }

    // Get list of channels that this UUID is currently marked "present" on
    // UUID is "present" on channels to which it is currently subscribed or publishing
    // Input:
    //      callback (function) - called when results are returned, takes two parameters
    //          err - null on success
    //          channels (array) - list of channels for which this UUID is "present"
    function whereNow(callback, uuid=null) {
        if (uuid == null) uuid=_uuid;

        local url = format("%s/sub-key/%s/uuid/%s",PRESENCE_BASE,_subscribeKey,uuid);

        http.get(url).sendasync(function(resp) {
            local err = null;
            local data = null;

            if (resp.statuscode != 200) {
                err = format("%i - %s", resp.statuscode, resp.body);
                throw err;
            } else {
                try {
                    data = http.jsondecode(resp.body);
                    if (!("channels" in data.payload)) {
                        err = "Channel list not found: "+resp.body;
                        throw err;
                    }
                    data = data.payload.channels;
                } catch (err) {
                    callback(err,data);
                }
                callback(err,data);
            }
        });
    }

    // Get list of UUIds that are currently "present" on this channel
    // UUID is "present" on channels to which it is currently subscribed or publishing
    // Input:
    //      channel (string)
    //      callback (function) - called when results are returned, takes two parameters
    //          err - null on success
    //          result - table with two entries:
    //              occupancy - number of UUIDs present on channel
    //              uuids - array of UUIDs present on channel
    function hereNow(channel, callback) {
        local url = format("%s/sub-key/%s/channel/%s",PRESENCE_BASE,_subscribeKey,channel);

        if (_authKey != null) {
            url += format("?auth=%s", _authKey);
        }

        http.get(url).sendasync(function(resp) {
            //server.log(resp.body);
            local data = null;
            local err = null;
            local result = {};

            if (resp.statuscode != 200) {
                err = format("%i - %s", resp.statuscode, resp.body);
                throw err;
            } else {
                try {
                    data = http.jsondecode(resp.body);
                    if (!("uuids" in data)) {
                        err = "UUID list not found: "+resp.body;
                    }
                    if (!("occupancy" in data)) {
                        err = "Occpancy not found"+resp.body;
                    }
                    result.uuids <- data.uuids;
                    result.occupancy <- data.occupancy;
                } catch (err) {
                    callback(err,result);
                }
                callback(err,result);
            }
        });
    }

    // Get list of UUIds that are currently "present" on this channel
    // UUID is "present" on channels to which it is currently subscribed or publishing
    // Input:
    //      channel (string)
    //      callback (function) - called when results are returned, takes two parameters
    //          err - null on success
    //          result - table with two entries:
    //              occupancy - number of UUIDs present on channel
    //              uuids - array of UUIDs present on channel
    function globalHereNow(callback) {
        local url = format("%s/sub-key/%s",PRESENCE_BASE,_subscribeKey);
        http.get(url).sendasync(function(resp) {
            //server.log(resp.body);
            local err = null;
            local data = null;
            local result = {};

            if (resp.statuscode != 200) {
                err = format("%i - %s", resp.statuscode, resp.body);
                throw err;
            } else {
                try {
                    data = http.jsondecode(resp.body);
                    if (!("channels" in data.payload)) {
                        err = "Channel list not found: "+resp.body.payload;
                    }
                    result = data.payload.channels;
                } catch (err) {
                    callback(err,result);
                }
                callback(err,result);
            }
        });
    }
}

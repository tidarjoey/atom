_ = require 'underscore-plus'
fs = require 'fs-plus'
{Emitter} = require 'emissary'
CSON = require 'season'
path = require 'path'
async = require 'async'
pathWatcher = require 'pathwatcher'

# Public: Used to access all of Atom's configuration details.
#
# A global instance of this class is available to all plugins which can be
# referenced using `atom.config`
#
# ### Best practices
#
# * Create your own root keypath using your package's name.
# * Don't depend on (or write to) configuration keys outside of your keypath.
#
# ### Example
#
# ```coffeescript
# atom.config.set('myplugin.key', 'value')
# atom.config.observe 'myplugin.key', ->
#   console.log 'My configuration changed:', atom.config.get('myplugin.key')
# ```
module.exports =
class Config
  Emitter.includeInto(this)

  defaultSettings: null
  settings: null
  configFileHasErrors: null

  # Private: Created during initialization, available as `global.config`
  constructor: ({@configDirPath, @resourcePath}={}) ->
    @bundledKeymapsDirPath = path.join(@resourcePath, "keymaps")
    @bundledMenusDirPath = path.join(resourcePath, "menus")
    @nodeModulesDirPath = path.join(@resourcePath, "node_modules")
    @bundledPackageDirPaths = [@nodeModulesDirPath]
    @packageDirPaths = [path.join(@configDirPath, "packages")]
    if atom.getLoadSettings().devMode
      @packageDirPaths.unshift(path.join(@configDirPath, "dev", "packages"))
    @userPackageDirPaths = _.clone(@packageDirPaths)

    @defaultSettings =
      core: _.clone(require('./root-view').configDefaults)
      editor: _.clone(require('./editor').configDefaults)
    @settings = {}
    @configFilePath = fs.resolve(@configDirPath, 'config', ['json', 'cson'])
    @configFilePath ?= path.join(@configDirPath, 'config.cson')

  # Private:
  initializeConfigDirectory: (done) ->
    return if fs.existsSync(@configDirPath)

    fs.makeTreeSync(@configDirPath)

    queue = async.queue ({sourcePath, destinationPath}, callback) =>
      fs.copy(sourcePath, destinationPath, callback)
    queue.drain = done

    templateConfigDirPath = fs.resolve(@resourcePath, 'dot-atom')
    onConfigDirFile = (sourcePath) =>
      relativePath = sourcePath.substring(templateConfigDirPath.length + 1)
      destinationPath = path.join(@configDirPath, relativePath)
      queue.push({sourcePath, destinationPath})
    fs.traverseTree(templateConfigDirPath, onConfigDirFile, (path) -> true)

  # Private:
  load: ->
    @initializeConfigDirectory()
    @loadUserConfig()
    @observeUserConfig()

  # Private:
  loadUserConfig: ->
    unless fs.existsSync(@configFilePath)
      fs.makeTreeSync(path.dirname(@configFilePath))
      CSON.writeFileSync(@configFilePath, {})

    try
      userConfig = CSON.readFileSync(@configFilePath)
      _.extend(@settings, userConfig)
      @configFileHasErrors = false
      @emit 'updated'
    catch e
      @configFileHasErrors = true
      console.error "Failed to load user config '#{@configFilePath}'", e.message
      console.error e.stack

  # Private:
  observeUserConfig: ->
    @watchSubscription ?= pathWatcher.watch @configFilePath, (eventType) =>
      @loadUserConfig() if eventType is 'change' and @watchSubscription?

  # Private:
  unobserveUserConfig: ->
    @watchSubscription?.close()
    @watchSubscription = null

  # Private:
  setDefaults: (keyPath, defaults) ->
    keys = keyPath.split('.')
    hash = @defaultSettings
    for key in keys
      hash[key] ?= {}
      hash = hash[key]

    _.extend hash, defaults
    @update()

  # Public: Returns a new {Object} containing all of settings and defaults.
  getSettings: ->
    _.deepExtend(@settings, @defaultSettings)

  # Public: Retrieves the setting for the given key.
  #
  # keyPath - The {String} name of the key to retrieve
  #
  # Returns the value from Atom's default settings, the user's configuration file,
  # or `null` if the key doesn't exist in either.
  get: (keyPath) ->
    value = _.valueForKeyPath(@settings, keyPath) ? _.valueForKeyPath(@defaultSettings, keyPath)
    _.deepClone(value)

  # Public: Retrieves the setting for the given key as an integer.
  #
  # keyPath - The {String} name of the key to retrieve
  #
  # Returns the value from Atom's default settings, the user's configuration file,
  # or `NaN` if the key doesn't exist in either.
  getInt: (keyPath) ->
    parseInt(@get(keyPath))

  # Public: Retrieves the setting for the given key as a positive integer.
  #
  # keyPath - The {String} name of the key to retrieve
  # defaultValue - The integer {Number} to fall back to if the value isn't
  #                positive
  #
  # Returns the value from Atom's default settings, the user's configuration file,
  # or `defaultValue` if the key value isn't greater than zero.
  getPositiveInt: (keyPath, defaultValue) ->
    Math.max(@getInt(keyPath), 0) or defaultValue

  # Public: Sets the value for a configuration setting.
  #
  # This value is stored in Atom's internal configuration file.
  #
  # keyPath - The {String} name of the key
  # value - The value of the setting
  #
  # Returns the `value`.
  set: (keyPath, value) ->
    if @get(keyPath) != value
      value = undefined if _.valueForKeyPath(@defaultSettings, keyPath) == value
      _.setValueForKeyPath(@settings, keyPath, value)
      @update()
    value

  # Public: Toggle the value at the key path.
  #
  # The new value will be `true` if the value is currently falsy and will be
  # `false` if the value is currently truthy.
  #
  # Returns the new value.
  toggle: (keyPath) ->
    @set(keyPath, !@get(keyPath))

  # Public: Push the value to the array at the key path.
  #
  # keyPath - The {String} key path.
  # value - The value to push to the array.
  #
  # Returns the new array length of the setting.
  pushAtKeyPath: (keyPath, value) ->
    arrayValue = @get(keyPath) ? []
    result = arrayValue.push(value)
    @set(keyPath, arrayValue)
    result

  # Public: Add the value to the beginning of the array at the key path.
  #
  # keyPath - The {String} key path.
  # value - The value to shift onto the array.
  #
  # Returns the new array length of the setting.
  unshiftAtKeyPath: (keyPath, value) ->
    arrayValue = @get(keyPath) ? []
    result = arrayValue.unshift(value)
    @set(keyPath, arrayValue)
    result

  # Public: Remove the value from the array at the key path.
  #
  # keyPath - The {String} key path.
  # value - The value to remove from the array.
  #
  # Returns the new array value of the setting.
  removeAtKeyPath: (keyPath, value) ->
    arrayValue = @get(keyPath) ? []
    result = _.remove(arrayValue, value)
    @set(keyPath, arrayValue)
    result

  # Public: Establishes an event listener for a given key.
  #
  # `callback` is fired whenever the value of the key is changed and will
  #  be fired immediately unless the `callNow` option is `false`.
  #
  # keyPath - The {String} name of the key to observe
  # options - An optional {Object} containing the `callNow` key.
  # callback - The {Function} that fires when the. It is given a single argument, `value`,
  #            which is the new value of `keyPath`.
  observe: (keyPath, options={}, callback) ->
    if _.isFunction(options)
      callback = options
      options = {}

    value = @get(keyPath)
    previousValue = _.clone(value)
    updateCallback = =>
      value = @get(keyPath)
      unless _.isEqual(value, previousValue)
        previous = previousValue
        previousValue = _.clone(value)
        callback(value, {previous})

    eventName = "updated.#{keyPath.replace(/\./, '-')}"
    subscription = { cancel: => @off eventName, updateCallback  }
    @on eventName, updateCallback
    callback(value) if options.callNow ? true
    subscription

  # Public: Unobserve all callbacks on a given key
  #
  # keyPath - The {String} name of the key to unobserve
  unobserve: (keyPath) ->
    @off("updated.#{keyPath.replace(/\./, '-')}")

  # Private:
  update: ->
    return if @configFileHasErrors
    @save()
    @emit 'updated'

  # Private:
  save: ->
    CSON.writeFileSync(@configFilePath, @settings)

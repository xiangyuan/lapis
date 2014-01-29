
logger = require "lapis.logging"
url = require "socket.url"
session = require "lapis.session"

import Router from require "lapis.router"
import html_writer from require "lapis.html"

import parse_cookie_string, to_json, build_url, auto_table from require "lapis.util"

json = require "cjson"

local capture_errors, capture_errors_json, respond_to

set_and_truthy = (val, default=true) ->
  return default if val == nil
  val

run_before_filter = (filter, r) ->
  _write = r.write
  written = false
  r.write = (...) ->
    written = true
    _write ...

  filter r
  r.write = nil
  written

class Request
  new: (@app, @req, @res) =>
    @buffer = {} -- output buffer
    @params = {}
    @options = {}

    @cookies = auto_table -> parse_cookie_string @req.headers.cookie
    @session = session.lazy_session @

  add_params: (params, name) =>
    self[name] = params
    for k,v in pairs params
      -- expand nested[param][keys]
      if front = k\match "^([^%[]+)%["
        curr = @params
        for match in k\gmatch "%[(.-)%]"
          new = curr[front]
          if new == nil
            new = {}
            curr[front] = new
          curr = new
          front = match
        curr[front] = v
      else
        @params[k] = v

  -- render the request into the response
  -- do this last
  render: (opts=false) =>
    @options = opts if opts

    session.write_session @
    @write_cookies!

    if @options.status
      @res.status = @options.status

    if obj = @options.json
      @res.headers["Content-type"] = "application/json"
      @res.content = to_json obj
      return

    if ct = @options.content_type
      @res.headers["Content-type"] = ct

    if not @res.headers["Content-type"]
      @res.headers["Content-type"] = "text/html"

    if redirect_url = @options.redirect_to
      if redirect_url\match "^/"
        redirect_url  = @build_url redirect_url

      @res\add_header "Location", redirect_url
      @res.status or= 302

    has_layout = @app.layout and set_and_truthy(@options.layout, true)
    @layout_opts = if has_layout
      { inner: nil }


    widget = @options.render
    widget = @route_name if widget == true

    if widget
      if type(widget) == "string"
        widget = require "#{@app.views_prefix}.#{widget}"

      view = widget @options.locals
      view\include_helper @

      @write view

    if has_layout
      inner = @buffer
      @buffer = {}

      layout_path = @options.layout
      layout_cls = if type(layout_path) == "string"
         require "#{@app.views_prefix}.#{layout_path}"
      else
        @app.layout

      @layout_opts.inner or= -> raw inner

      layout = layout_cls @layout_opts
      layout\include_helper @
      layout\render @buffer

    if next @buffer
      content = table.concat @buffer
      @res.content = if @res.content
        @res.content .. content
      else
        content

  html: (fn) => html_writer fn

  url_for: (first, ...) =>
    if type(first) == "table"
      @app.router\url_for first\url_params @, ...
    else
      @app.router\url_for first, ...

  -- @build_url! --> http://example.com:8080
  -- @build_url "hello_world" --> http://example.com:8080/hello_world
  -- @build_url "hello_world?color=blue" --> http://example.com:8080/hello_world?color=blue
  -- @build_url "cats", host: "leafo.net", port: 2000 --> http://leafo.net:2000/cats
  -- Where example.com is the host of the request, and 8080 is current port
  build_url: (path, options) =>
    return path if path and path\match "^%a+:"

    parsed = { k,v for k,v in pairs @req.parsed_url }
    parsed.query = nil

    if path
      _path, query = path\match("^(.-)%?(.*)$")
      path = _path or path
      parsed.query = query

    parsed.path = path

    if parsed.port == "80"
      parsed.port = nil

    if options
      for k,v in pairs options
        parsed[k] = v

    build_url parsed

  write: (...) =>
    for thing in *{...}
      t = type(thing)
      -- is it callable?
      if t == "table"
        mt = getmetatable(thing)
        if mt and mt.__call
          t = "function"

      switch t
        when "string"
          table.insert @buffer, thing
        when "table"
          -- see if there are options
          for k,v in pairs thing
            if type(k) == "string"
              @options[k] = v
            else
              @write v
        when "function"
          @write thing @buffer
        when "nil"
          nil -- ignore
        else
          error "Don't know how to write: (#{t}) #{thing}"

  write_cookies: =>
    return unless next @cookies
    extra = @app.cookie_attributes

    if extra
      extra = "; " .. table.concat @app.cookie_attributes, "; "

    for k,v in pairs @cookies
      cookie = "#{url.escape k}=#{url.escape v}; Path=/; HttpOnly"
      cookie ..= extra if extra
      @res\add_header "Set-cookie", cookie


class Application
  Request: Request
  layout: require"lapis.views.layout"
  error_page: require"lapis.views.error"

  -- find action for named route in this application
  @find_action: (name) =>
    @_named_route_cache or= {}
    route = @_named_route_cache[name]

    -- update the cache
    unless route
      for app_route in pairs @__base
        if type(app_route) == "table"
          app_route_name = next app_route
          @_named_route_cache[app_route_name] = app_route
          route = app_route if app_route_name == name

    route and @[route], route

  views_prefix: "views"

  new: =>
    @build_router!

  enable: (feature) =>
    fn = require "lapis.features.#{feature}"
    fn @

  match: (route_name, path, handler) =>
    if handler == nil
      handler = path
      path = route_name
      route_name = nil

    key = if route_name
      {[route_name]: path}
    else
      path

    @[key] = handler

    @router = nil
    handler

  for meth in *{"get", "post", "delete", "put"}
    upper_meth = meth\upper!
    @__base[meth] = (route_name, path, handler) =>
      if handler == nil
        handler = path
        path = route_name
        route_name = nil

      @responders or= {}
      existing = @responders[route_name or path]
      tbl = { [upper_meth]: handler }

      if existing
        setmetatable tbl, __index: (key) =>
          existing if key\match "%u"

      responder = respond_to tbl
      @responders[route_name or path] = responder
      @match route_name, path, responder

  build_router: =>
    @router = Router!
    @router.default_route = => false

    add_route = (path, handler) ->
      t = type path
      if t == "table" or t == "string" and path\match "^/"
        @router\add_route path, @wrap_handler handler

    add_routes = (cls) ->
      for path, handler in pairs cls.__base
        add_route path, handler

      for path, handler in pairs @
        add_route path, handler

      if parent = cls.__parent
        add_routes parent

    add_routes @@

  wrap_handler: (handler) =>
    (params, path, name, r) ->
      with r
        .route_name = name

        \add_params r.req.params_get, "GET"
        \add_params r.req.params_post, "POST"
        \add_params params, "url_params"

        if @before_filters
          for filter in *@before_filters
            return r if run_before_filter filter, r

        \write handler r

  dispatch: (req, res) =>
    local err, trace, r
    success = xpcall (->
        r = @.Request self, req, res

        unless @router\resolve req.parsed_url.path, r
          -- run default route if nothing matched
          handler = @wrap_handler self.default_route
          handler {}, nil, "default_route", r

        r\render!
        logger.request r),
      (_err) ->
        err = _err
        trace = debug.traceback "", 2

    unless success
      self.handle_error r, err, trace

    res

  serve: => -- TODO: alias to lapis.serve

  @before_filter: (fn) =>
    @__base.before_filters or= {}
    table.insert @before_filters, fn

  -- copies all actions into this application, preserves before filters
  -- @inclue other_app, path: "/hello", name: "hello_"
  @include: (other_app, opts, into=@__base) =>
    if type(other_app) == "string"
      other_app = require other_app

    path_prefix = opts and opts.path or other_app.path
    name_prefix = opts and opts.name or other_app.name

    for path, action in pairs other_app.__base
      t = type path
      if t == "table"
        if path_prefix
          name = next path
          path[name] = path_prefix .. path[name]

        if name_prefix
          name = next path
          path[name_prefix .. name] = path[name]
          path[name] = nil
      elseif t == "string" and path\match "^/"
        if path_prefix
          path = path_prefix .. path
      else
        continue

      if before_filters = other_app.before_filters
        fn = action
        action = (r) ->
          for filter in *before_filters
            return if run_before_filter filter, r
          fn r

      into[path] = action

  -- Callbacks
  -- run with Request as self, instead of application

  default_route: =>
    -- strip trailing /
    if @req.parsed_url.path\match "./$"
      stripped = @req.parsed_url.path\match "^(.+)/+$"
      redirect_to: @build_url(stripped, query: @req.parsed_url.query), status: 301
    else
      @app.handle_404 @

  handle_404: =>
    error "Failed to find route: #{@req.cmd_url}"

  handle_error: (err, trace, error_page=@app.error_page) =>
    r = @app.Request self, @req, @res
    r\write {
      status: 500
      layout: false
      content_type: "text/html"
      error_page { status: 500, :err, :trace }
    }
    r\render!
    logger.request r
    r

respond_to = do
  default_head = -> layout: false -- render nothing

  (tbl) ->
    tbl.HEAD = default_head unless tbl.HEAD

    out = =>
      fn = tbl[@req.cmd_mth]
      if fn
        if before = tbl.before
          return if run_before_filter before, @
        fn @
      else
        error "don't know how to respond to #{@req.cmd_mth}"

    if error_response = tbl.on_error
      out = capture_errors out, error_response

    out, tbl

default_error_response = -> { render: true }
capture_errors = (fn, error_response=default_error_response) ->
  if type(fn) == "table"
    error_response = fn.on_error or error_response
    fn = fn[1]

  (...) =>
    co = coroutine.create fn
    out = { coroutine.resume co, @ }

    unless out[1] -- error
      error debug.traceback co, out[2]

    -- { status, "error", error_msgs }
    if coroutine.status(co) == "suspended"
      if out[2] == "error"
        @errors = out[3]
        error_response @
      else -- yield to someone else
        error "Unknown yield"
    else
      unpack out, 2

capture_errors_json = (fn) ->
  capture_errors fn, => {
    json: { errors: @errors }
  }

yield_error = (msg) ->
  coroutine.yield "error", {msg}

assert_error = (thing, msg) ->
  yield_error msg unless thing
  thing

json_params = (fn) ->
  (...) =>
    if content_type = @req.headers["content-type"]
      -- Header often ends with ;UTF-8
      if string.find content_type\lower!, "application/json", nil, true
        local obj
        pcall -> obj, err = json.decode ngx.req.get_body_data!
        @add_params obj, "json" if obj

    fn @, ...

{
  :Request, :Application, :respond_to
  :capture_errors, :capture_errors_json
  :json_params, :assert_error, :yield_error
}

